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
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

enum { AB_CAPACITY = 16384 };

struct ABEngine {
    AudioObjectID device, tap, aggregate;
    AudioDeviceIOProcID io;
    ABProcessor *processor;
    float *input, *output;
    double rate, host_seconds, limiter_latency;
    uint32_t data_source;
    UInt32 original_buffer_frames, adjusted_buffer_frames;
    bool active, wanted, sleeping, fatal, device_listener, system_listener;
    IONotificationPortRef power_port;
    io_connect_t power_connection;
    io_object_t power_notifier;
    _Atomic float gain;
    _Atomic int dirty, render_error;
    _Atomic uint64_t callbacks, faults, last_callback;
    _Atomic uint64_t latency_nanoseconds;
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
    if (AudioObjectGetPropertyDataSize(object, &property, 0, NULL, &size) ||
        size < sizeof(AudioBufferList))
        return 0;
    AudioBufferList *list = calloc(1, size);
    if (!list)
        return UINT32_MAX;
    UInt32 channels = 0;
    if (AudioObjectGetPropertyData(object, &property, 0, NULL, &size, list))
        channels = UINT32_MAX;
    else
        for (UInt32 i = 0; i < list->mNumberBuffers; i++)
            channels += list->mBuffers[i].mNumberChannels;
    free(list);
    return channels;
}

static OSStatus route(AudioObjectID *device, double *rate, uint32_t *source) {
    OSStatus error =
        read_property(kAudioObjectSystemObject, kAudioHardwarePropertyDefaultOutputDevice,
                      kAudioObjectPropertyScopeGlobal, sizeof(*device), device);
    if (error || !*device)
        return error ? error : kAudioHardwareBadDeviceError;
    error = read_property(*device, kAudioDevicePropertyNominalSampleRate,
                          kAudioObjectPropertyScopeGlobal, sizeof(*rate), rate);
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
    (void)count;
    (void)properties;
    ABEngine *engine = context;
    atomic_store_explicit(&engine->dirty, 1, memory_order_relaxed);
    return noErr;
}

static const AudioObjectPropertySelector device_properties[] = {
    kAudioDevicePropertyNominalSampleRate, kAudioDevicePropertyDeviceIsAlive,
    kAudioDevicePropertyBufferFrameSize, kAudioDevicePropertyDataSource};

static void remove_device_listeners(ABEngine *engine) {
    if (!engine->device_listener)
        return;
    for (unsigned i = 0; i < sizeof(device_properties) / sizeof(device_properties[0]); i++) {
        AudioObjectPropertyScope scope = device_properties[i] == kAudioDevicePropertyDataSource
                                             ? kAudioObjectPropertyScopeOutput
                                             : kAudioObjectPropertyScopeGlobal;
        AudioObjectPropertyAddress property = address(device_properties[i], scope);
        AudioObjectRemovePropertyListener(engine->device, &property, changed, engine);
    }
    engine->device_listener = false;
}

static bool close_graph(ABEngine *engine) {
    engine->active = false;
    remove_device_listeners(engine);
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

static bool valid_buffers(const AudioBufferList *buffers, UInt32 frames) {
    if (buffers->mNumberBuffers == 1)
        return buffers->mBuffers[0].mNumberChannels == 2 && buffers->mBuffers[0].mData &&
               buffers->mBuffers[0].mDataByteSize >= frames * 2 * sizeof(float);
    if (buffers->mNumberBuffers != 2)
        return false;
    for (int c = 0; c < 2; c++)
        if (buffers->mBuffers[c].mNumberChannels != 1 || !buffers->mBuffers[c].mData ||
            buffers->mBuffers[c].mDataByteSize < frames * sizeof(float))
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
    if (!output->mNumberBuffers || !output->mBuffers[0].mNumberChannels)
        goto fail;
    UInt32 frames =
        output->mBuffers[0].mDataByteSize / (sizeof(float) * output->mBuffers[0].mNumberChannels);
    if (!frames || frames > AB_CAPACITY || !valid_buffers(output, frames))
        goto fail;
    if (input->mNumberBuffers == 0)
        memset(engine->input, 0, frames * 2 * sizeof(float));
    else {
        if (!valid_buffers(input, frames))
            goto fail;
        if (input->mNumberBuffers == 1)
            memcpy(engine->input, input->mBuffers[0].mData, frames * 2 * sizeof(float));
        else
            for (UInt32 i = 0; i < frames; i++)
                for (int c = 0; c < 2; c++)
                    engine->input[2 * i + c] = ((const float *)input->mBuffers[c].mData)[i];
    }
    error = ab_processor_process(engine->processor, engine->input, engine->output, frames,
                                 atomic_load_explicit(&engine->gain, memory_order_relaxed));
    if (error)
        goto fail;
    if (output->mNumberBuffers == 1)
        memcpy(output->mBuffers[0].mData, engine->output, frames * 2 * sizeof(float));
    else
        for (UInt32 i = 0; i < frames; i++)
            for (int c = 0; c < 2; c++)
                ((float *)output->mBuffers[c].mData)[i] = engine->output[2 * i + c];
    if ((input_time->mFlags & kAudioTimeStampHostTimeValid) &&
        (output_time->mFlags & kAudioTimeStampHostTimeValid) &&
        output_time->mHostTime >= input_time->mHostTime) {
        double seconds = (output_time->mHostTime - input_time->mHostTime) * engine->host_seconds +
                         engine->limiter_latency;
        atomic_store_explicit(&engine->latency_nanoseconds, (uint64_t)(seconds * 1e9),
                              memory_order_relaxed);
    }
    return noErr;
fail:
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
    if (!atomic_is_lock_free(&engine->gain) || !atomic_is_lock_free(&engine->callbacks)) {
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

int32_t ab_engine_start(ABEngine *engine, float gain) {
    @autoreleasepool {
        NSString *uid = nil, *name = nil;
        CATapDescription *description = nil;
        NSDictionary *composition = nil;
        if (!engine || !isfinite(gain) || gain < 0 || gain > 12)
            return kAudio_ParamError;
        if (engine->fatal || engine->sleeping)
            return kAudioHardwareNotRunningError;
        if (!close_graph(engine))
            return kAudioHardwareUnspecifiedError;
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
        operation = "unsupported output; use built-in speakers or wired headphones";
        error = read_property(engine->device, kAudioDevicePropertyTransportType,
                              kAudioObjectPropertyScopeGlobal, sizeof(transport), &transport);
        if (error || transport != kAudioDeviceTransportTypeBuiltIn ||
            channel_count(engine->device, kAudioObjectPropertyScopeOutput) != 2 ||
            channel_count(engine->device, kAudioObjectPropertyScopeInput) != 0) {
            error = kAudioHardwareUnsupportedOperationError;
            goto fail;
        }
        // Restrict the physical stream to Float32 stereo; no silent reinterpretation of PCM
        // formats.
        AudioObjectPropertyAddress streams =
            address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput);
        UInt32 size = 0;
        error = AudioObjectGetPropertyDataSize(engine->device, &streams, 0, NULL, &size);
        if (error || size != sizeof(AudioStreamID)) {
            error = kAudioHardwareUnsupportedOperationError;
            goto fail;
        }
        AudioStreamID stream = 0;
        error = AudioObjectGetPropertyData(engine->device, &streams, 0, NULL, &size, &stream);
        if (error)
            goto fail;
        AudioStreamBasicDescription output_format = {0};
        error =
            read_property(stream, kAudioStreamPropertyVirtualFormat,
                          kAudioObjectPropertyScopeGlobal, sizeof(output_format), &output_format);
        if (error || output_format.mFormatID != kAudioFormatLinearPCM ||
            !(output_format.mFormatFlags & kAudioFormatFlagIsFloat) ||
            output_format.mBitsPerChannel != 32 || output_format.mChannelsPerFrame != 2) {
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
                 name ? name.UTF8String : "Built-in output");
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
        if (error || tap_format.mFormatID != kAudioFormatLinearPCM ||
            !(tap_format.mFormatFlags & kAudioFormatFlagIsFloat) ||
            tap_format.mBitsPerChannel != 32 || tap_format.mChannelsPerFrame != 2 ||
            tap_format.mSampleRate != engine->rate) {
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
        if (channel_count(engine->aggregate, kAudioObjectPropertyScopeInput) != 2 ||
            channel_count(engine->aggregate, kAudioObjectPropertyScopeOutput) != 2) {
            error = kAudioHardwareUnsupportedOperationError;
            goto fail;
        }
        operation = "could not configure low-latency playback buffers";
        AudioObjectPropertyAddress buffer_frames =
            address(kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal);
        UInt32 original_frames = 0, adjusted_frames = 0;
        error = read_property(engine->device, buffer_frames.mSelector, buffer_frames.mScope,
                              sizeof(original_frames), &original_frames);
        if (error)
            goto fail;
        UInt32 requested_frames = original_frames < 256 ? original_frames : 256;
        error = AudioObjectSetPropertyData(engine->aggregate, &buffer_frames, 0, NULL,
                                           sizeof(requested_frames), &requested_frames);
        if (error)
            goto fail;
        if (!read_property(engine->device, buffer_frames.mSelector, buffer_frames.mScope,
                           sizeof(adjusted_frames), &adjusted_frames) &&
            adjusted_frames != original_frames) {
            engine->original_buffer_frames = original_frames;
            engine->adjusted_buffer_frames = adjusted_frames;
        }
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
        // A tap can otherwise deliver silence without authorization. Reapply its public
        // description to check access before allowing muted playback interception.
        AudioObjectPropertyAddress tap_description =
            address(kAudioTapPropertyDescription, kAudioObjectPropertyScopeGlobal);
        void *description_pointer = (__bridge void *)description;
        operation = "audio capture is not authorized; allow AudioBoost in Privacy & Security > "
                    "Screen & System Audio Recording, then start again";
        error = AudioObjectSetPropertyData(engine->tap, &tap_description, 0, NULL,
                                           sizeof(description_pointer), &description_pointer);
        if (error)
            goto fail;
        operation = "could not start playback; check system-audio recording permission";
        atomic_store(&engine->last_callback, mach_absolute_time());
        error = AudioDeviceStart(engine->aggregate, engine->io);
        if (error)
            goto fail;
        engine->active = true;
        for (unsigned i = 0; i < sizeof(device_properties) / sizeof(device_properties[0]); i++) {
            AudioObjectPropertyScope scope = device_properties[i] == kAudioDevicePropertyDataSource
                                                 ? kAudioObjectPropertyScopeOutput
                                                 : kAudioObjectPropertyScopeGlobal;
            AudioObjectPropertyAddress property = address(device_properties[i], scope);
            if (AudioObjectHasProperty(engine->device, &property))
                AudioObjectAddPropertyListener(engine->device, &property, changed, engine);
        }
        engine->device_listener = true;
        return noErr;
    fail:
        record_error(engine, operation, error);
        close_graph(engine);
        return error;
    }
}

void ab_engine_set_gain(ABEngine *engine, float gain) {
    if (isfinite(gain) && gain >= 0 && gain <= 12)
        atomic_store_explicit(&engine->gain, gain, memory_order_relaxed);
}

int32_t ab_engine_poll(ABEngine *engine) {
    if (engine->fatal)
        return kAudioHardwareUnspecifiedError;
    if (!engine->wanted || engine->sleeping)
        return noErr;
    int error = atomic_exchange(&engine->render_error, 0);
    if (error) {
        record_error(engine, "audio processing failed; normal playback restored", error);
        close_graph(engine);
        engine->wanted = false;
        return engine->fatal ? kAudioHardwareUnspecifiedError : noErr;
    }
    bool reconfigure = atomic_exchange(&engine->dirty, 0);
    if (engine->active &&
        (mach_absolute_time() - atomic_load(&engine->last_callback)) * engine->host_seconds > 2)
        reconfigure = true;
    if (!reconfigure)
        return noErr;
    AudioObjectID device = 0;
    double rate = 0;
    uint32_t source = 0;
    OSStatus route_error = route(&device, &rate, &source);
    bool different = device != engine->device || source != engine->data_source;
    if (reconfigure) {
        float gain = different ? 0 : atomic_load(&engine->gain);
        if (route_error) {
            record_error(engine, "output unavailable", route_error);
            close_graph(engine);
            return engine->fatal ? kAudioHardwareUnspecifiedError : noErr;
        }
        ab_engine_start(engine, gain);
    }
    return engine->fatal ? kAudioHardwareUnspecifiedError : noErr;
}

void ab_engine_status(ABEngine *engine, ABStatus *status) {
    memset(status, 0, sizeof(*status));
    status->sample_rate = engine->rate;
    status->gain_db = atomic_load(&engine->gain);
    status->active = engine->sleeping ? 2 : engine->active;
    status->callbacks = atomic_load(&engine->callbacks);
    status->faults = atomic_load(&engine->faults);
    uint64_t latency = atomic_load(&engine->latency_nanoseconds);
    status->latency_ms = latency ? latency / 1e6 : -1;
    snprintf(status->device, sizeof(status->device), "%s", engine->device_name);
    snprintf(status->error, sizeof(status->error), "%s", engine->error);
}

int32_t ab_engine_stop(ABEngine *engine) {
    engine->wanted = false;
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
    }
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
