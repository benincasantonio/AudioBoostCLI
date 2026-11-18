#include "audio.h"
#include <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#import <CoreAudio/CoreAudio.h>
#import <Foundation/Foundation.h>
#include <IOKit/IOMessage.h>
#include <IOKit/pwr_mgt/IOPMLib.h>
#include <mach/mach_time.h>
#include <math.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

enum { AB_CAPACITY = 16384 };

struct ABEngine {
    AudioObjectID device, tap, aggregate, stream;
    AudioDeviceIOProcID io;
    ABProcessor *processor;
    float *input, *output;
    double rate, host_seconds, limiter_latency;
    uint32_t data_source;
    UInt32 original_buffer_frames, adjusted_buffer_frames;
    UInt32 tap_buffer_offset, input_channels;
    UInt32 device_buffer_frames;
    AudioStreamBasicDescription output_format;
    uint64_t last_attempt;
    bool active, wanted, sleeping, fatal, device_listener, system_listener;
    IONotificationPortRef power_port;
    io_connect_t power_connection;
    io_object_t power_notifier;
    _Atomic float gain;
    _Atomic int dirty, render_error;
    _Atomic uint64_t callbacks, faults, last_callback;
    _Atomic uint64_t latency_nanoseconds;
    _Atomic UInt32 buffer_frames;
    char uid[512], device_name[256], error[512];
};

static AudioObjectPropertyAddress address(AudioObjectPropertySelector selector,
                                          AudioObjectPropertyScope scope) {
    return (AudioObjectPropertyAddress){selector, scope, kAudioObjectPropertyElementMain};
}

static OSStatus read_property(AudioObjectID object, AudioObjectPropertySelector selector,
                              AudioObjectPropertyScope scope, UInt32 size, void *value) {
    AudioObjectPropertyAddress property = address(selector, scope);
    return AudioObjectGetPropertyData(object, &property, 0, NULL, &size, value);
}

static NSString *read_string(AudioObjectID object, AudioObjectPropertySelector selector) {
    CFStringRef value = NULL;
    if (read_property(object, selector, kAudioObjectPropertyScopeGlobal, sizeof(value), &value))
        return nil;
    return CFBridgingRelease(value);
}

static UInt32 channel_count(AudioObjectID object, AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress property = address(kAudioDevicePropertyStreamConfiguration, scope);
    UInt32 size = 0;
    if (!AudioObjectHasProperty(object, &property))
        return 0;
    if (AudioObjectGetPropertyDataSize(object, &property, 0, NULL, &size) ||
        size < offsetof(AudioBufferList, mBuffers))
        return UINT32_MAX;
    AudioBufferList *list = calloc(1, size);
    if (!list)
        return UINT32_MAX;
    UInt32 channels = 0;
    if (AudioObjectGetPropertyData(object, &property, 0, NULL, &size, list) ||
        list->mNumberBuffers > (size - offsetof(AudioBufferList, mBuffers)) / sizeof(AudioBuffer))
        channels = UINT32_MAX;
    else
        for (UInt32 i = 0; i < list->mNumberBuffers; i++) {
            if (list->mBuffers[i].mNumberChannels > UINT32_MAX - channels) {
                channels = UINT32_MAX;
                break;
            }
            channels += list->mBuffers[i].mNumberChannels;
        }
    free(list);
    return channels;
}

static bool supported_transport(UInt32 transport) {
    switch (transport) {
    case kAudioDeviceTransportTypeBuiltIn:
    case kAudioDeviceTransportTypeHDMI:
    case kAudioDeviceTransportTypeDisplayPort:
    case kAudioDeviceTransportTypeUSB:
    case kAudioDeviceTransportTypeBluetooth:
    case kAudioDeviceTransportTypeBluetoothLE:
        return true;
    default:
        return false;
    }
}

static bool stereo_format(AudioStreamBasicDescription format, double rate) {
    UInt32 flags = format.mFormatFlags & ~kAudioFormatFlagIsNonInterleaved;
    UInt32 bytes = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) ? 4 : 8;
    return isfinite(rate) && rate >= 8000 && rate <= 192000 &&
           format.mSampleRate == rate && format.mFormatID == kAudioFormatLinearPCM &&
           flags == kAudioFormatFlagsNativeFloatPacked && format.mBitsPerChannel == 32 &&
           format.mChannelsPerFrame == 2 && format.mFramesPerPacket == 1 &&
           format.mBytesPerFrame == bytes && format.mBytesPerPacket == bytes;
}

static OSStatus output_stream(AudioObjectID device, AudioObjectID *stream,
                              AudioStreamBasicDescription *format) {
    AudioObjectPropertyAddress property =
        address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput);
    UInt32 size = 0;
    OSStatus error = AudioObjectGetPropertyDataSize(device, &property, 0, NULL, &size);
    if (error)
        return error;
    if (size != sizeof(*stream))
        return kAudioHardwareUnsupportedOperationError;
    error = AudioObjectGetPropertyData(device, &property, 0, NULL, &size, stream);
    return error ? error : read_property(*stream, kAudioStreamPropertyVirtualFormat,
                                         kAudioObjectPropertyScopeGlobal, sizeof(*format), format);
}

static OSStatus route(AudioObjectID *device, double *rate, uint32_t *source) {
    OSStatus error =
        read_property(kAudioObjectSystemObject, kAudioHardwarePropertyDefaultOutputDevice,
                      kAudioObjectPropertyScopeGlobal, sizeof(*device), device);
    if (error || !*device)
        return error ? error : kAudioHardwareBadDeviceError;
    error = read_property(*device, kAudioDevicePropertyNominalSampleRate,
                          kAudioObjectPropertyScopeGlobal, sizeof(*rate), rate);
    UInt32 alive = 0;
    if (!error)
        error = read_property(*device, kAudioDevicePropertyDeviceIsAlive,
                              kAudioObjectPropertyScopeGlobal, sizeof(alive), &alive);
    if (!error && !alive)
        error = kAudioHardwareBadDeviceError;
    *source = 0;
    // A missing data-source control is normal on devices with distinct speaker/headphone IDs.
    read_property(*device, kAudioDevicePropertyDataSource, kAudioObjectPropertyScopeOutput,
                  sizeof(*source), source);
    return error;
}

static void record_error(ABEngine *engine, const char *operation, OSStatus code) {
    snprintf(engine->error, sizeof(engine->error), "%s (Core Audio status %d)", operation,
             (int)code);
}

static OSStatus changed(AudioObjectID object, UInt32 count,
                        const AudioObjectPropertyAddress *properties, void *context) {
    (void)object;
    ABEngine *engine = context;
    int flags = 1;
    for (UInt32 i = 0; i < count; i++)
        if (properties[i].mSelector == kAudioHardwarePropertyServiceRestarted)
            flags |= 2;
    atomic_fetch_or_explicit(&engine->dirty, flags, memory_order_relaxed);
    return noErr;
}

static const AudioObjectPropertyAddress device_properties[] = {
    {kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, 0},
    {kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal, 0},
    {kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal, 0},
    {kAudioDevicePropertyUsesVariableBufferFrameSizes, kAudioObjectPropertyScopeGlobal, 0},
    {kAudioDevicePropertyDataSource, kAudioObjectPropertyScopeOutput, 0},
    {kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput, 0},
    {kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput, 0},
    {kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput, 0}};

static void remove_device_listeners(ABEngine *engine) {
    if (!engine->device_listener)
        return;
    for (unsigned i = 0; i < sizeof(device_properties) / sizeof(device_properties[0]); i++) {
        AudioObjectRemovePropertyListener(engine->device, &device_properties[i], changed, engine);
    }
    AudioObjectPropertyAddress format =
        address(kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal);
    if (engine->stream)
        AudioObjectRemovePropertyListener(engine->stream, &format, changed, engine);
    engine->device_listener = false;
}

static void add_device_listeners(ABEngine *engine) {
    if (engine->device_listener || !engine->device)
        return;
    for (unsigned i = 0; i < sizeof(device_properties) / sizeof(device_properties[0]); i++)
        if (AudioObjectHasProperty(engine->device, &device_properties[i]))
            AudioObjectAddPropertyListener(engine->device, &device_properties[i], changed, engine);
    AudioObjectPropertyAddress format =
        address(kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal);
    if (engine->stream)
        AudioObjectAddPropertyListener(engine->stream, &format, changed, engine);
    engine->device_listener = true;
}

static bool close_graph(ABEngine *engine) {
    engine->active = false;
    if (engine->io) {
        AudioDeviceStop(engine->aggregate, engine->io);
        // Destroying the IOProc synchronizes with rendering; buffers stay alive until this
        // succeeds.
        OSStatus error = AudioDeviceDestroyIOProcID(engine->aggregate, engine->io);
        if (error) {
            record_error(engine, "could not stop audio callback; service must exit", error);
            engine->fatal = true;
            return false;
        }
        engine->io = NULL;
    }
    atomic_store(&engine->latency_nanoseconds, 0);
    atomic_store(&engine->buffer_frames, 0);
    if (engine->aggregate) {
        OSStatus error = AudioHardwareDestroyAggregateDevice(engine->aggregate);
        if (error) {
            record_error(engine, "could not release aggregate; service must exit", error);
            engine->fatal = true;
            return false;
        }
        engine->aggregate = 0;
    }
    if (engine->original_buffer_frames) {
        UInt32 current = 0;
        AudioObjectPropertyAddress frames =
            address(kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal);
        if (!read_property(engine->device, frames.mSelector, frames.mScope, sizeof(current),
                           &current) &&
            current == engine->adjusted_buffer_frames) {
            OSStatus error = AudioObjectSetPropertyData(
                engine->device, &frames, 0, NULL, sizeof(current), &engine->original_buffer_frames);
            if (error) {
                record_error(engine, "could not restore output buffer size", error);
                engine->fatal = true;
                return false;
            }
        }
        engine->original_buffer_frames = 0;
    }
    if (engine->tap) {
        OSStatus error = AudioHardwareDestroyProcessTap(engine->tap);
        if (error) {
            record_error(engine, "could not release tap; service must exit", error);
            engine->fatal = true;
            return false;
        }
        engine->tap = 0;
    }
    ab_processor_destroy(engine->processor);
    engine->processor = NULL;
    free(engine->input);
    engine->input = NULL;
    free(engine->output);
    engine->output = NULL;
    return true;
}

static void power_changed(void *context, io_service_t service, natural_t type, void *argument) {
    (void)service;
    ABEngine *engine = context;
    if (type == kIOMessageSystemWillSleep) {
        engine->sleeping = true;
        close_graph(engine);
    }
    if (type == kIOMessageSystemWillSleep || type == kIOMessageCanSystemSleep)
        IOAllowPowerChange(engine->power_connection, (intptr_t)argument);
    if (type == kIOMessageSystemHasPoweredOn) {
        engine->sleeping = false;
        atomic_store(&engine->dirty, 1);
    }
}

static bool stereo_layout(const AudioBuffer *buffers, UInt32 count) {
    return (count == 1 && buffers[0].mNumberChannels == 2) ||
           (count == 2 && buffers[0].mNumberChannels == 1 && buffers[1].mNumberChannels == 1);
}

static bool valid_buffers(const AudioBuffer *buffers, UInt32 count, UInt32 frames) {
    if (!stereo_layout(buffers, count))
        return false;
    for (UInt32 c = 0; c < count; c++)
        if (!buffers[c].mData ||
            buffers[c].mDataByteSize != frames * buffers[c].mNumberChannels * sizeof(float))
            return false;
    return true;
}

static OSStatus render(AudioObjectID device, const AudioTimeStamp *now,
                       const AudioBufferList *input, const AudioTimeStamp *input_time,
                       AudioBufferList *output, const AudioTimeStamp *output_time, void *context) {
    (void)device;
    (void)now;
    ABEngine *engine = context;
    OSStatus error = kAudio_ParamError;
    atomic_fetch_add_explicit(&engine->callbacks, 1, memory_order_relaxed);
    atomic_store_explicit(&engine->last_callback, mach_absolute_time(), memory_order_relaxed);
    for (UInt32 i = 0; i < output->mNumberBuffers; i++)
        if (output->mBuffers[i].mData)
            memset(output->mBuffers[i].mData, 0, output->mBuffers[i].mDataByteSize);
    if (!stereo_layout(output->mBuffers, output->mNumberBuffers))
        goto fail;
    UInt32 frames =
        output->mBuffers[0].mDataByteSize / (sizeof(float) * output->mBuffers[0].mNumberChannels);
    if (!frames || frames > AB_CAPACITY ||
        !valid_buffers(output->mBuffers, output->mNumberBuffers, frames))
        goto fail;
    if (input->mNumberBuffers == 0)
        memset(engine->input, 0, frames * 2 * sizeof(float));
    else {
        if (input->mNumberBuffers <= engine->tap_buffer_offset)
            goto fail;
        const AudioBuffer *tap = input->mBuffers + engine->tap_buffer_offset;
        UInt32 count = input->mNumberBuffers - engine->tap_buffer_offset;
        if (!valid_buffers(tap, count, frames))
            goto fail;
        if (count == 1)
            memcpy(engine->input, tap[0].mData, frames * 2 * sizeof(float));
        else
            for (UInt32 i = 0; i < frames; i++)
                for (int c = 0; c < 2; c++)
                    engine->input[2 * i + c] = ((const float *)tap[c].mData)[i];
    }
    error = ab_processor_process(engine->processor, engine->input, engine->output, frames,
                                 atomic_load_explicit(&engine->gain, memory_order_relaxed));
    if (error)
        goto processing_fail;
    if (output->mNumberBuffers == 1)
        memcpy(output->mBuffers[0].mData, engine->output, frames * 2 * sizeof(float));
    else
        for (UInt32 i = 0; i < frames; i++)
            for (int c = 0; c < 2; c++)
                ((float *)output->mBuffers[c].mData)[i] = engine->output[2 * i + c];
    atomic_store_explicit(&engine->buffer_frames, frames, memory_order_relaxed);
    uint64_t latency = 0;
    if ((input_time->mFlags & kAudioTimeStampHostTimeValid) &&
        (output_time->mFlags & kAudioTimeStampHostTimeValid) &&
        output_time->mHostTime >= input_time->mHostTime) {
        double seconds = (output_time->mHostTime - input_time->mHostTime) * engine->host_seconds +
                         engine->limiter_latency;
        latency = (uint64_t)(seconds * 1e9);
    }
    atomic_store_explicit(&engine->latency_nanoseconds, latency, memory_order_relaxed);
    return noErr;
fail:
    // A changed HAL buffer layout is recoverable; never interpret microphone data as playback.
    atomic_fetch_or_explicit(&engine->dirty, 1, memory_order_relaxed);
    error = kAudioHardwareBadDeviceError;
processing_fail:
    atomic_store_explicit(&engine->buffer_frames, 0, memory_order_relaxed);
    atomic_store_explicit(&engine->latency_nanoseconds, 0, memory_order_relaxed);
    atomic_store_explicit(&engine->render_error, error, memory_order_relaxed);
    atomic_fetch_add_explicit(&engine->faults, 1, memory_order_relaxed);
    return noErr;
}

ABEngine *ab_engine_create(void) {
    ABEngine *engine = calloc(1, sizeof(*engine));
    if (!engine)
        return NULL;
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    engine->host_seconds = (double)timebase.numer / timebase.denom / 1e9;
    atomic_init(&engine->gain, 3);
    atomic_init(&engine->dirty, 0);
    atomic_init(&engine->render_error, 0);
    atomic_init(&engine->callbacks, 0);
    atomic_init(&engine->faults, 0);
    atomic_init(&engine->last_callback, 0);
    atomic_init(&engine->latency_nanoseconds, 0);
    atomic_init(&engine->buffer_frames, 0);
    if (!atomic_is_lock_free(&engine->gain) || !atomic_is_lock_free(&engine->callbacks) ||
        !atomic_is_lock_free(&engine->buffer_frames)) {
        free(engine);
        return NULL;
    }
    AudioObjectPropertyAddress property =
        address(kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal);
    if (AudioObjectAddPropertyListener(kAudioObjectSystemObject, &property, changed, engine)) {
        free(engine);
        return NULL;
    }
    engine->system_listener = true;
    property.mSelector = kAudioHardwarePropertyServiceRestarted;
    AudioObjectAddPropertyListener(kAudioObjectSystemObject, &property, changed, engine);
    property.mSelector = kAudioHardwarePropertyDevices;
    AudioObjectAddPropertyListener(kAudioObjectSystemObject, &property, changed, engine);
    engine->power_connection = IORegisterForSystemPower(engine, &engine->power_port, power_changed,
                                                        &engine->power_notifier);
    if (!engine->power_connection) {
        ab_engine_destroy(engine);
        return NULL;
    }
    CFRunLoopAddSource(CFRunLoopGetCurrent(),
                       IONotificationPortGetRunLoopSource(engine->power_port),
                       kCFRunLoopCommonModes);
    return engine;
}

static OSStatus stream_count(AudioObjectID device, AudioObjectPropertyScope scope, UInt32 *count) {
    AudioObjectPropertyAddress property = address(kAudioDevicePropertyStreams, scope);
    UInt32 size = 0;
    OSStatus error = AudioObjectGetPropertyDataSize(device, &property, 0, NULL, &size);
    if (!error && size % sizeof(AudioStreamID))
        return kAudioHardwareUnsupportedOperationError;
    *count = size / sizeof(AudioStreamID);
    return error;
}

static bool tap_offset(const AudioBufferList *configuration, UInt32 hardware_channels,
                       UInt32 *offset) {
    UInt32 channels = 0, i = 0;
    while (i < configuration->mNumberBuffers && channels < hardware_channels) {
        UInt32 next = configuration->mBuffers[i++].mNumberChannels;
        if (next > hardware_channels - channels)
            return false;
        channels += next;
    }
    if (channels != hardware_channels ||
        !stereo_layout(configuration->mBuffers + i, configuration->mNumberBuffers - i))
        return false;
    *offset = i;
    return true;
}

static OSStatus configure_tap_input(ABEngine *engine) {
    // HAL places the physical device's inputs before the appended tap. Map the actual ABL,
    // not a guessed buffer index: stereo may be interleaved or split across two buffers.
    AudioObjectPropertyAddress property =
        address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput);
    UInt32 size = 0;
    OSStatus error = AudioObjectGetPropertyDataSize(engine->aggregate, &property, 0, NULL, &size);
    if (error || size < sizeof(AudioBufferList))
        return error ? error : kAudioHardwareUnsupportedOperationError;
    AudioBufferList *configuration = calloc(1, size);
    if (!configuration)
        return kAudioHardwareUnspecifiedError;
    error = AudioObjectGetPropertyData(engine->aggregate, &property, 0, NULL, &size, configuration);
    if (!error &&
        (configuration->mNumberBuffers > (size - offsetof(AudioBufferList, mBuffers)) / sizeof(AudioBuffer) ||
         !tap_offset(configuration, engine->input_channels, &engine->tap_buffer_offset)))
        error = kAudioHardwareUnsupportedOperationError;
    free(configuration);
    if (error)
        return error;
    UInt32 hardware_count = 0, aggregate_count = 0;
    error = stream_count(engine->device, kAudioObjectPropertyScopeInput, &hardware_count);
    if (!error)
        error = stream_count(engine->aggregate, kAudioObjectPropertyScopeInput, &aggregate_count);
    if (error)
        return error;
    if (aggregate_count <= hardware_count || aggregate_count - hardware_count > 2)
        return kAudioHardwareUnsupportedOperationError;
    if (!hardware_count)
        return noErr;
    size = (UInt32)(offsetof(AudioHardwareIOProcStreamUsage, mStreamIsOn) +
                    aggregate_count * sizeof(UInt32));
    AudioHardwareIOProcStreamUsage *usage = calloc(1, size);
    if (!usage)
        return kAudioHardwareUnspecifiedError;
    usage->mIOProc = engine->io;
    usage->mNumberStreams = aggregate_count;
    for (UInt32 i = hardware_count; i < aggregate_count; i++)
        usage->mStreamIsOn[i] = 1;
    property.mSelector = kAudioDevicePropertyIOProcStreamUsage;
    error = AudioObjectSetPropertyData(engine->aggregate, &property, 0, NULL, size, usage);
    if (!error)
        error = AudioObjectGetPropertyData(engine->aggregate, &property, 0, NULL, &size, usage);
    if (!error && usage->mNumberStreams != aggregate_count)
        error = kAudioHardwareUnsupportedOperationError;
    for (UInt32 i = 0; !error && i < aggregate_count; i++)
        if (!!usage->mStreamIsOn[i] != (i >= hardware_count))
            error = kAudioHardwareUnsupportedOperationError;
    free(usage);
    return error;
}

static OSStatus configure_buffers(ABEngine *engine, bool built_in) {
    AudioObjectPropertyAddress property =
        address(kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal);
    UInt32 original = 0, actual = 0;
    OSStatus error = read_property(engine->device, property.mSelector, property.mScope,
                                   sizeof(original), &original);
    if (error)
        return error;
    AudioValueRange range = {0};
    Boolean settable = false;
    OSStatus configured = read_property(engine->aggregate, kAudioDevicePropertyBufferFrameSizeRange,
                                        property.mScope, sizeof(range), &range);
    if (!configured)
        configured = AudioObjectIsPropertySettable(engine->aggregate, &property, &settable);
    if (!configured && (!settable || !isfinite(range.mMinimum) || !isfinite(range.mMaximum) ||
                        range.mMinimum < 1 || range.mMaximum < range.mMinimum ||
                        range.mMinimum > AB_CAPACITY))
        configured = kAudioHardwareUnsupportedOperationError;
    if (!configured) {
        UInt32 requested = (UInt32)fmax(ceil(range.mMinimum),
                                       fmin(fmin(original, 256), floor(range.mMaximum)));
        configured = AudioObjectSetPropertyData(engine->aggregate, &property, 0, NULL,
                                                 sizeof(requested), &requested);
    }
    // A failed set can still affect the underlying device. Track it before returning any error.
    error = read_property(engine->device, property.mSelector, property.mScope,
                          sizeof(engine->device_buffer_frames), &engine->device_buffer_frames);
    if (error)
        return error;
    if (engine->device_buffer_frames != original) {
        engine->original_buffer_frames = original;
        engine->adjusted_buffer_frames = engine->device_buffer_frames;
    }
    if (configured && built_in)
        return configured;
    error = read_property(engine->aggregate, property.mSelector, property.mScope,
                          sizeof(actual), &actual);
    if (error)
        return error;
    UInt32 maximum = actual;
    property.mSelector = kAudioDevicePropertyUsesVariableBufferFrameSizes;
    if (AudioObjectHasProperty(engine->aggregate, &property)) {
        error = read_property(engine->aggregate, property.mSelector, property.mScope,
                              sizeof(maximum), &maximum);
        if (error)
            return error;
        if (!maximum)
            maximum = actual;
    }
    return actual && actual <= AB_CAPACITY && maximum >= actual && maximum <= AB_CAPACITY &&
                   (!built_in || actual <= 256)
               ? noErr : kAudioHardwareUnsupportedOperationError;
}

int32_t ab_engine_start(ABEngine *engine, float gain) {
    @autoreleasepool {
        NSString *uid = nil, *name = nil;
        CATapDescription *description = nil;
        NSDictionary *composition = nil;
        bool permission_check = false;
        if (!engine || !isfinite(gain) || gain < 0 || gain > 12)
            return kAudio_ParamError;
        if (engine->fatal || engine->sleeping)
            return kAudioHardwareNotRunningError;
        remove_device_listeners(engine);
        if (!close_graph(engine))
            return kAudioHardwareUnspecifiedError;
        engine->last_attempt = mach_absolute_time();
        engine->stream = 0;
        engine->device = 0;
        engine->rate = 0;
        engine->uid[0] = 0;
        engine->device_name[0] = 0;
        engine->wanted = true;
        engine->error[0] = 0;
        atomic_store(&engine->gain, gain);
        atomic_store(&engine->render_error, 0);
        atomic_store(&engine->dirty, 0);
        atomic_store(&engine->latency_nanoseconds, 0);
        OSStatus error = route(&engine->device, &engine->rate, &engine->data_source);
        const char *operation = "could not read the default output";
        if (error)
            goto fail;
        name = read_string(engine->device, kAudioObjectPropertyName);
        snprintf(engine->device_name, sizeof(engine->device_name), "%s",
                 name ? name.UTF8String : "Unknown output");
        UInt32 transport = 0;
        operation = "unsupported output transport; use built-in, HDMI/DisplayPort, USB, or Bluetooth stereo";
        error = read_property(engine->device, kAudioDevicePropertyTransportType,
                              kAudioObjectPropertyScopeGlobal, sizeof(transport), &transport);
        if (error || !supported_transport(transport)) {
            error = kAudioHardwareUnsupportedOperationError;
            goto fail;
        }
        operation = "boosting suspended: output must provide Float32 stereo PCM; normal playback restored";
        UInt32 size = 0;
        engine->input_channels = channel_count(engine->device, kAudioObjectPropertyScopeInput);
        error = output_stream(engine->device, &engine->stream, &engine->output_format);
        if (error || !stereo_format(engine->output_format, engine->rate) ||
            channel_count(engine->device, kAudioObjectPropertyScopeOutput) != 2 ||
            engine->input_channels == UINT32_MAX) {
            error = kAudioHardwareUnsupportedOperationError;
            goto fail;
        }
        uid = read_string(engine->device, kAudioDevicePropertyDeviceUID);
        name = read_string(engine->device, kAudioObjectPropertyName);
        if (!uid) {
            error = kAudioHardwareBadDeviceError;
            goto fail;
        }
        snprintf(engine->uid, sizeof(engine->uid), "%s", uid.UTF8String);
        snprintf(engine->device_name, sizeof(engine->device_name), "%s",
                 name ? name.UTF8String : "Unknown output");
        pid_t pid = getpid();
        AudioObjectID process = kAudioObjectUnknown;
        AudioObjectPropertyAddress translation = address(
            kAudioHardwarePropertyTranslatePIDToProcessObject, kAudioObjectPropertyScopeGlobal);
        size = sizeof(process);
        operation = "could not identify AudioBoost for feedback exclusion";
        error = AudioObjectGetPropertyData(kAudioObjectSystemObject, &translation, sizeof(pid),
                                           &pid, &size, &process);
        if (error || process == kAudioObjectUnknown) {
            error = kAudioHardwareBadObjectError;
            goto fail;
        }
        description = [[CATapDescription alloc] initExcludingProcesses:@[ @(process) ]
                                                          andDeviceUID:uid
                                                            withStream:0];
        description.name = @"AudioBoost playback tap";
        description.privateTap = YES;
        description.muteBehavior = CATapMutedWhenTapped;
        operation = "could not create playback tap; allow AudioBoost in Privacy & Security > "
                    "Screen & System Audio Recording";
        error = AudioHardwareCreateProcessTap(description, &engine->tap);
        if (error)
            goto fail;
        AudioStreamBasicDescription tap_format = {0};
        error = read_property(engine->tap, kAudioTapPropertyFormat, kAudioObjectPropertyScopeGlobal,
                              sizeof(tap_format), &tap_format);
        operation = "unsupported tap format";
        if (error || !stereo_format(tap_format, engine->rate)) {
            error = kAudioHardwareUnsupportedOperationError;
            goto fail;
        }
        composition = @{
            @kAudioAggregateDeviceNameKey : @"AudioBoost Private Output",
            @kAudioAggregateDeviceUIDKey :
                [@"AudioBoost-" stringByAppendingString:NSUUID.UUID.UUIDString],
            @kAudioAggregateDeviceIsPrivateKey : @YES,
            @kAudioAggregateDeviceMainSubDeviceKey : uid,
            @kAudioAggregateDeviceSubDeviceListKey : @[
                @{@kAudioSubDeviceUIDKey : uid}
            ],
            @kAudioAggregateDeviceTapListKey : @[ @{
                @kAudioSubTapUIDKey : description.UUID.UUIDString,
                @kAudioSubTapDriftCompensationKey : @NO
            } ],
            @kAudioAggregateDeviceTapAutoStartKey : @NO
        };
        operation = "could not create private playback device";
        error = AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)composition,
                                                   &engine->aggregate);
        if (error)
            goto fail;
        if (engine->input_channels > UINT32_MAX - 2 ||
            channel_count(engine->aggregate, kAudioObjectPropertyScopeInput) != engine->input_channels + 2 ||
            channel_count(engine->aggregate, kAudioObjectPropertyScopeOutput) != 2) {
            error = kAudioHardwareUnsupportedOperationError;
            goto fail;
        }
        AudioObjectID aggregate_stream = 0;
        AudioStreamBasicDescription aggregate_format = {0};
        error = output_stream(engine->aggregate, &aggregate_stream, &aggregate_format);
        if (error || !stereo_format(aggregate_format, engine->rate)) {
            error = kAudioHardwareUnsupportedOperationError;
            goto fail;
        }
        operation = "unsupported playback buffer size";
        error = configure_buffers(engine, transport == kAudioDeviceTransportTypeBuiltIn);
        if (error)
            goto fail;
        operation = "could not initialize peak limiter";
        engine->processor = ab_processor_create(engine->rate, AB_CAPACITY, gain, &error);
        if (!engine->processor)
            goto fail;
        engine->limiter_latency = ab_processor_latency(engine->processor);
        engine->input = calloc(AB_CAPACITY * 2, sizeof(float));
        engine->output = calloc(AB_CAPACITY * 2, sizeof(float));
        if (!engine->input || !engine->output) {
            error = kAudioHardwareUnspecifiedError;
            goto fail;
        }
        operation = "could not register audio callback";
        error = AudioDeviceCreateIOProcID(engine->aggregate, render, engine, &engine->io);
        if (error)
            goto fail;
        operation = "could not isolate playback tap from microphone inputs";
        error = configure_tap_input(engine);
        if (error)
            goto fail;
        // A tap can otherwise deliver silence without authorization. Reapply its public
        // description to check access before allowing muted playback interception.
        AudioObjectPropertyAddress tap_description =
            address(kAudioTapPropertyDescription, kAudioObjectPropertyScopeGlobal);
        void *description_pointer = (__bridge void *)description;
        operation = "audio capture is not authorized; allow AudioBoost in Privacy & Security > "
                    "Screen & System Audio Recording, then start again";
        permission_check = true;
        error = AudioObjectSetPropertyData(engine->tap, &tap_description, 0, NULL,
                                           sizeof(description_pointer), &description_pointer);
        if (error)
            goto fail;
        permission_check = false;
        operation = "could not start playback; check system-audio recording permission";
        atomic_store(&engine->last_callback, mach_absolute_time());
        error = AudioDeviceStart(engine->aggregate, engine->io);
        if (error)
            goto fail;
        engine->active = true;
        add_device_listeners(engine);
        return noErr;
    fail:
        record_error(engine, operation, error);
        close_graph(engine);
        atomic_store(&engine->gain, 0);
        if (permission_check || error == kAudioDevicePermissionsError)
            engine->wanted = false;
        add_device_listeners(engine);
        return error;
    }
}

void ab_engine_set_gain(ABEngine *engine, float gain) {
    if (isfinite(gain) && gain >= 0 && gain <= 12)
        atomic_store_explicit(&engine->gain, gain, memory_order_relaxed);
}

static bool topology_changed(ABEngine *engine, double rate) {
    AudioObjectID stream = 0;
    AudioStreamBasicDescription format = {0};
    UInt32 frames = 0;
    return rate != engine->rate ||
           output_stream(engine->device, &stream, &format) || stream != engine->stream ||
           memcmp(&format, &engine->output_format, sizeof(format)) != 0 ||
           channel_count(engine->device, kAudioObjectPropertyScopeInput) != engine->input_channels ||
           channel_count(engine->device, kAudioObjectPropertyScopeOutput) != 2 ||
           read_property(engine->device, kAudioDevicePropertyBufferFrameSize,
                         kAudioObjectPropertyScopeGlobal, sizeof(frames), &frames) ||
           frames != engine->device_buffer_frames;
}

int32_t ab_engine_poll(ABEngine *engine) {
    @autoreleasepool {
        if (engine->fatal)
            return kAudioHardwareUnspecifiedError;
        if (!engine->wanted || engine->sleeping)
            return noErr;
        int error = atomic_exchange(&engine->render_error, 0);
        int dirty = atomic_exchange(&engine->dirty, 0);
        uint64_t now = mach_absolute_time();
        bool retry_due = (now - engine->last_attempt) * engine->host_seconds >= 1;
        bool stalled = engine->active &&
            (now - atomic_load(&engine->last_callback)) * engine->host_seconds > 2;
        if (!dirty && !error && !stalled && (engine->active || !retry_due))
            return noErr;
        AudioObjectID device = 0;
        double rate = 0;
        uint32_t source = 0;
        OSStatus route_error = route(&device, &rate, &source);
        NSString *uid = route_error ? nil : read_string(device, kAudioDevicePropertyDeviceUID);
        bool different = device != engine->device || source != engine->data_source ||
                         !uid || strcmp(uid.UTF8String, engine->uid);
        bool changed_route = route_error || different || (dirty & 2) || topology_changed(engine, rate);
        if (error && error != kAudioHardwareBadDeviceError && !changed_route) {
            record_error(engine, "audio processing failed; normal playback restored", error);
            close_graph(engine);
            engine->wanted = false;
            return engine->fatal ? kAudioHardwareUnspecifiedError : noErr;
        }
        if (engine->active && !changed_route && !error && !stalled)
            return noErr; // Ignore device-list notifications caused by our own private aggregate.
        float gain = different || route_error || error || stalled ? 0 : atomic_load(&engine->gain);
        atomic_store(&engine->gain, gain);
        if (!close_graph(engine))
            return kAudioHardwareUnspecifiedError;
        if (route_error) {
            record_error(engine, "output unavailable; normal playback restored", route_error);
            engine->last_attempt = now;
            return noErr;
        }
        if (!retry_due) {
            snprintf(engine->error, sizeof(engine->error), "output changed; rebuilding playback");
            return noErr;
        }
        ab_engine_start(engine, gain);
        return engine->fatal ? kAudioHardwareUnspecifiedError : noErr;
    }
}

void ab_engine_status(ABEngine *engine, ABStatus *status) {
    memset(status, 0, sizeof(*status));
    status->sample_rate = engine->rate;
    status->gain_db = atomic_load(&engine->gain);
    status->active = engine->sleeping ? 2 : engine->active;
    status->callbacks = atomic_load(&engine->callbacks);
    status->faults = atomic_load(&engine->faults);
    uint64_t latency = engine->active ? atomic_load(&engine->latency_nanoseconds) : 0;
    status->latency_ms = latency ? latency / 1e6 : -1;
    status->buffer_frames = engine->active ? atomic_load(&engine->buffer_frames) : 0;
    snprintf(status->device, sizeof(status->device), "%s", engine->device_name);
    snprintf(status->error, sizeof(status->error), "%s", engine->error);
}

int32_t ab_engine_stop(ABEngine *engine) {
    engine->wanted = false;
    remove_device_listeners(engine);
    return close_graph(engine) ? 0 : kAudioHardwareUnspecifiedError;
}

void ab_engine_destroy(ABEngine *engine) {
    if (!engine)
        return;
    if (engine->power_connection) {
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(),
                              IONotificationPortGetRunLoopSource(engine->power_port),
                              kCFRunLoopCommonModes);
        IODeregisterForSystemPower(&engine->power_notifier);
        IOServiceClose(engine->power_connection);
    }
    if (engine->power_port)
        IONotificationPortDestroy(engine->power_port);
    if (engine->system_listener) {
        AudioObjectPropertyAddress property =
            address(kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal);
        AudioObjectRemovePropertyListener(kAudioObjectSystemObject, &property, changed, engine);
        property.mSelector = kAudioHardwarePropertyServiceRestarted;
        AudioObjectRemovePropertyListener(kAudioObjectSystemObject, &property, changed, engine);
        property.mSelector = kAudioHardwarePropertyDevices;
        AudioObjectRemovePropertyListener(kAudioObjectSystemObject, &property, changed, engine);
    }
    remove_device_listeners(engine);
    // If HAL refuses to release a live IOProc, retain its memory until process exit.
    if (close_graph(engine))
        free(engine);
}

void ab_run_loop(double seconds) {
    @autoreleasepool {
        // CFRunLoop returns immediately without sources. Do not busy-spin the service in that case.
        if (CFRunLoopRunInMode(kCFRunLoopDefaultMode, seconds, false) == kCFRunLoopRunFinished) {
            struct timespec delay = {.tv_sec = 0, .tv_nsec = (long)(seconds * 1e9)};
            nanosleep(&delay, NULL);
        }
    }
}
