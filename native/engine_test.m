// Compile the callback with its real processor to exercise buffer boundaries without intercepting
// playback.
#import <CoreAudio/CoreAudio.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#include <assert.h>
#include <stdbool.h>
#include <string.h>
#include <stddef.h>

// Only enabled by the offline scenarios below. No process tap or playback is started.
static struct {
    bool enabled, reject_buffer, deny_permission, refuse_destroy;
    UInt32 transport, channels, inputs, frames, maximum, device, tap_creations, starts;
    UInt32 input_usage[2];
    double rate;
} hal;

static AudioStreamBasicDescription test_format(void) {
    return (AudioStreamBasicDescription){.mSampleRate = hal.rate,
        .mFormatID = kAudioFormatLinearPCM, .mFormatFlags = kAudioFormatFlagsNativeFloatPacked,
        .mBytesPerPacket = hal.channels * 4, .mFramesPerPacket = 1,
        .mBytesPerFrame = hal.channels * 4, .mChannelsPerFrame = hal.channels, .mBitsPerChannel = 32};
}

static OSStatus test_get_size(AudioObjectID object, const AudioObjectPropertyAddress *property,
                              UInt32 qualifier_size, const void *qualifier, UInt32 *size) {
    if (!hal.enabled)
        return AudioObjectGetPropertyDataSize(object, property, qualifier_size, qualifier, size);
    bool input = property->mScope == kAudioObjectPropertyScopeInput;
    UInt32 count = input ? (hal.inputs ? 1 : 0) + (object == 30 ? 1 : 0) : 1;
    if (property->mSelector == kAudioDevicePropertyStreams)
        *size = count * sizeof(AudioStreamID);
    else if (property->mSelector == kAudioDevicePropertyStreamConfiguration)
        *size = (UInt32)(offsetof(AudioBufferList, mBuffers) + count * sizeof(AudioBuffer));
    else
        return kAudioHardwareUnknownPropertyError;
    return noErr;
}

static OSStatus test_get(AudioObjectID object, const AudioObjectPropertyAddress *property,
                         UInt32 qualifier_size, const void *qualifier, UInt32 *size, void *data) {
    if (!hal.enabled)
        return AudioObjectGetPropertyData(object, property, qualifier_size, qualifier, size, data);
    UInt32 value = 0;
    switch (property->mSelector) {
    case kAudioHardwarePropertyDefaultOutputDevice: value = hal.device; break;
    case kAudioDevicePropertyDeviceIsAlive: value = 1; break;
    case kAudioDevicePropertyDataSource: value = 0; break;
    case kAudioDevicePropertyTransportType: value = hal.transport; break;
    case kAudioDevicePropertyBufferFrameSize: value = hal.frames; break;
    case kAudioDevicePropertyUsesVariableBufferFrameSizes: value = hal.maximum; break;
    case kAudioHardwarePropertyTranslatePIDToProcessObject: value = 50; break;
    case kAudioDevicePropertyStreams: value = 40; break;
    case kAudioDevicePropertyNominalSampleRate:
        memcpy(data, &hal.rate, sizeof(hal.rate)); return noErr;
    case kAudioDevicePropertyBufferFrameSizeRange: {
        AudioValueRange range = {16, 32768};
        memcpy(data, &range, sizeof(range)); return noErr;
    }
    case kAudioObjectPropertyName:
    case kAudioDevicePropertyDeviceUID: {
        CFStringRef name = CFStringCreateWithFormat(NULL, NULL, CFSTR("Test device %u"), hal.device);
        memcpy(data, &name, sizeof(name)); return noErr;
    }
    case kAudioStreamPropertyVirtualFormat:
    case kAudioTapPropertyFormat: {
        AudioStreamBasicDescription format = test_format();
        memcpy(data, &format, sizeof(format)); return noErr;
    }
    case kAudioDevicePropertyStreamConfiguration: {
        AudioBufferList *list = data;
        memset(data, 0, *size);
        if (property->mScope == kAudioObjectPropertyScopeOutput) {
            list->mNumberBuffers = 1;
            list->mBuffers[0].mNumberChannels = hal.channels;
        } else {
            if (hal.inputs)
                list->mBuffers[list->mNumberBuffers++].mNumberChannels = hal.inputs;
            if (object == 30)
                list->mBuffers[list->mNumberBuffers++].mNumberChannels = hal.channels;
        }
        return noErr;
    }
    case kAudioDevicePropertyIOProcStreamUsage: {
        AudioHardwareIOProcStreamUsage *usage = data;
        memcpy(usage->mStreamIsOn, hal.input_usage, usage->mNumberStreams * sizeof(UInt32));
        return noErr;
    }
    default: return kAudioHardwareUnknownPropertyError;
    }
    memcpy(data, &value, sizeof(value));
    return noErr;
}

static OSStatus test_set(AudioObjectID object, const AudioObjectPropertyAddress *property,
                         UInt32 qualifier_size, const void *qualifier, UInt32 size, const void *data) {
    if (!hal.enabled)
        return AudioObjectSetPropertyData(object, property, qualifier_size, qualifier, size, data);
    switch (property->mSelector) {
    case kAudioDevicePropertyBufferFrameSize:
        if (hal.reject_buffer) return kAudioHardwareUnsupportedOperationError;
        hal.frames = *(const UInt32 *)data; return noErr;
    case kAudioDevicePropertyIOProcStreamUsage: {
        const AudioHardwareIOProcStreamUsage *usage = data;
        assert(usage->mNumberStreams == 2);
        memcpy(hal.input_usage, usage->mStreamIsOn, sizeof(hal.input_usage)); return noErr;
    }
    case kAudioTapPropertyDescription:
        return hal.deny_permission ? kAudioDevicePermissionsError : noErr;
    default: return kAudioHardwareUnknownPropertyError;
    }
}

static Boolean test_has(AudioObjectID object, const AudioObjectPropertyAddress *property) {
    return hal.enabled ? true : AudioObjectHasProperty(object, property);
}
static OSStatus test_settable(AudioObjectID object, const AudioObjectPropertyAddress *property,
                              Boolean *settable) {
    if (!hal.enabled) return AudioObjectIsPropertySettable(object, property, settable);
    *settable = true; return noErr;
}
static OSStatus test_add_listener(AudioObjectID object, const AudioObjectPropertyAddress *property,
                                  AudioObjectPropertyListenerProc proc, void *context) {
    return hal.enabled ? noErr : AudioObjectAddPropertyListener(object, property, proc, context);
}
static OSStatus test_remove_listener(AudioObjectID object, const AudioObjectPropertyAddress *property,
                                     AudioObjectPropertyListenerProc proc, void *context) {
    return hal.enabled ? noErr : AudioObjectRemovePropertyListener(object, property, proc, context);
}
static OSStatus test_tap(CATapDescription *description, AudioObjectID *tap) {
    (void)description;
    assert(hal.enabled); hal.tap_creations++; *tap = 20; return noErr;
}
static OSStatus test_aggregate(CFDictionaryRef description, AudioObjectID *aggregate) {
    (void)description;
    assert(hal.enabled); *aggregate = 30; return noErr;
}
static OSStatus test_create_io(AudioObjectID device, AudioDeviceIOProc proc, void *context,
                               AudioDeviceIOProcID *io) {
    (void)device; (void)context;
    assert(hal.enabled); *io = proc; return noErr;
}
static OSStatus test_start(AudioObjectID device, AudioDeviceIOProcID io) {
    (void)device; (void)io;
    assert(hal.enabled); hal.starts++; return noErr;
}
static OSStatus test_stop(AudioObjectID device, AudioDeviceIOProcID io) {
    (void)device; (void)io;
    assert(hal.enabled); return noErr;
}
static OSStatus test_destroy_io(AudioObjectID device, AudioDeviceIOProcID io) {
    (void)device; (void)io;
    assert(hal.enabled); return hal.refuse_destroy ? kAudioHardwareUnspecifiedError : noErr;
}
static OSStatus test_destroy(AudioObjectID object) {
    (void)object;
    assert(hal.enabled); return noErr;
}

#define AudioObjectGetPropertyDataSize test_get_size
#define AudioObjectGetPropertyData test_get
#define AudioObjectSetPropertyData test_set
#define AudioObjectHasProperty test_has
#define AudioObjectIsPropertySettable test_settable
#define AudioObjectAddPropertyListener test_add_listener
#define AudioObjectRemovePropertyListener test_remove_listener
#define AudioHardwareCreateProcessTap test_tap
#define AudioHardwareCreateAggregateDevice test_aggregate
#define AudioDeviceCreateIOProcID test_create_io
#define AudioDeviceStart test_start
#define AudioDeviceStop test_stop
#define AudioDeviceDestroyIOProcID test_destroy_io
#define AudioHardwareDestroyAggregateDevice test_destroy
#define AudioHardwareDestroyProcessTap test_destroy
#include "engine.m"

static void callback_contract(void) {
    ABEngine engine = {0};
    float input[512] = {0}, output[512] = {0}, scratch_in[512], scratch_out[512];
    int32_t error = 0;
    engine.processor = ab_processor_create(48000, 256, 3, &error);
    assert(engine.processor && !error);
    engine.input = scratch_in;
    engine.output = scratch_out;
    atomic_init(&engine.gain, 3);
    atomic_init(&engine.callbacks, 0);
    atomic_init(&engine.last_callback, 0);
    atomic_init(&engine.render_error, 0);
    atomic_init(&engine.faults, 0);
    atomic_init(&engine.latency_nanoseconds, 0);
    atomic_init(&engine.buffer_frames, 0);
    atomic_init(&engine.dirty, 0);
    AudioBufferList in = {1, {{2, sizeof(input), input}}};
    AudioBufferList out = {1, {{2, sizeof(output), output}}};
    AudioTimeStamp time = {0};
    for (int cycle = 0; cycle < 40; cycle++) {
        assert(render(0, &time, &in, &time, &out, &time, &engine) == noErr);
        for (int i = 0; i < 512; i++)
            assert(output[i] == 0);
    }
    for (int i = 0; i < 256; i++) {
        input[2 * i] = 0.01;
        input[2 * i + 1] = -0.01;
    }
    for (int cycle = 0; cycle < 40; cycle++)
        render(0, &time, &in, &time, &out, &time, &engine);
    assert(fabsf(output[510] - 0.014125375f) < 1e-6f);
    assert(fabsf(output[510] + output[511]) < 1e-6f);
    assert(atomic_load(&engine.buffer_frames) == 256);
    // A disabled microphone buffer precedes the tap on duplex outputs. Never read it.
    struct {
        UInt32 count;
        AudioBuffer buffers[2];
    } duplex = {2, {{1, 0, NULL}, {2, sizeof(input), input}}};
    assert(tap_offset((AudioBufferList *)&duplex, 1, &engine.tap_buffer_offset));
    assert(engine.tap_buffer_offset == 1);
    render(0, &time, (AudioBufferList *)&duplex, &time, &out, &time, &engine);
    assert(fabsf(output[510] - 0.014125375f) < 1e-6f);
    assert(!tap_offset((AudioBufferList *)&duplex, 2, &engine.tap_buffer_offset));
    engine.tap_buffer_offset = 0;
    // A short input must never be read beyond its provided storage.
    in.mBuffers[0].mDataByteSize = 4;
    render(0, &time, &in, &time, &out, &time, &engine);
    assert(atomic_load(&engine.faults) == 1 && atomic_load(&engine.render_error) != 0);
    assert(atomic_load(&engine.buffer_frames) == 0);
    for (int i = 0; i < 512; i++)
        assert(output[i] == 0);
    // Noninterleaved output uses the same stereo sample ordering.
    float left[256], right[256];
    struct {
        UInt32 count;
        AudioBuffer buffers[2];
    } planar = {2, {{1, sizeof(left), left}, {1, sizeof(right), right}}};
    in.mBuffers[0].mDataByteSize = sizeof(input);
    render(0, &time, &in, &time, (AudioBufferList *)&planar, &time, &engine);
    assert(fabsf(left[255] - 0.014125375f) < 1e-6f);
    assert(fabsf(left[255] + right[255]) < 1e-6f);
    // Both input and output can be planar, including after a disabled microphone buffer.
    float source_left[256], source_right[256];
    for (int i = 0; i < 256; i++) { source_left[i] = 0.01f; source_right[i] = -0.01f; }
    struct {
        UInt32 count;
        AudioBuffer buffers[3];
    } duplex_planar = {3, {{1, 0, NULL}, {1, sizeof(source_left), source_left},
                          {1, sizeof(source_right), source_right}}};
    assert(tap_offset((AudioBufferList *)&duplex_planar, 1, &engine.tap_buffer_offset));
    render(0, &time, (AudioBufferList *)&duplex_planar, &time, (AudioBufferList *)&planar, &time, &engine);
    assert(fabsf(left[255] - 0.014125375f) < 1e-6f && atomic_load(&engine.faults) == 1);
    // Losing all output channels must release interception, not look like healthy rendering.
    out.mNumberBuffers = 0;
    render(0, &time, &in, &time, &out, &time, &engine);
    assert(atomic_load(&engine.faults) == 2);
    ab_processor_destroy(engine.processor);
}

static void format_contract(void) {
    hal.rate = 48000; hal.channels = 2;
    AudioStreamBasicDescription format = test_format();
    assert(stereo_format(format, 48000));
    format.mFormatFlags |= kAudioFormatFlagIsNonInterleaved;
    format.mBytesPerFrame = format.mBytesPerPacket = 4;
    assert(stereo_format(format, 48000));
    format.mFormatFlags |= kAudioFormatFlagIsBigEndian;
    assert(!stereo_format(format, 48000));
    format = test_format(); format.mChannelsPerFrame = 1;
    assert(!stereo_format(format, 48000));
    format = test_format(); format.mBitsPerChannel = 16;
    assert(!stereo_format(format, 48000));
    format = test_format(); format.mBytesPerFrame = 4;
    assert(!stereo_format(format, 48000));
    assert(!stereo_format(test_format(), 44100));
    for (unsigned i = 0; i < 6; i++) {
        UInt32 transports[] = {kAudioDeviceTransportTypeBuiltIn, kAudioDeviceTransportTypeHDMI,
            kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeUSB,
            kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE};
        assert(supported_transport(transports[i]));
    }
    assert(!supported_transport(kAudioDeviceTransportTypeVirtual));
    assert(!supported_transport(kAudioDeviceTransportTypeAggregate));
    assert(!supported_transport(kAudioDeviceTransportTypeAirPlay));
}

static void callback_capacity_contract(void) {
    ABEngine engine = {0};
    int32_t error = 0;
    engine.processor = ab_processor_create(48000, AB_CAPACITY, 0, &error);
    engine.input = calloc(AB_CAPACITY * 2, sizeof(float));
    engine.output = calloc(AB_CAPACITY * 2, sizeof(float));
    float *samples = calloc((AB_CAPACITY + 1) * 2, sizeof(float));
    assert(engine.processor && engine.input && engine.output && samples && !error);
    AudioBufferList input = {1, {{2, AB_CAPACITY * 2 * sizeof(float), samples}}};
    AudioBufferList output = input;
    AudioTimeStamp time = {0};
    render(0, &time, &input, &time, &output, &time, &engine);
    assert(atomic_load(&engine.buffer_frames) == AB_CAPACITY && !atomic_load(&engine.faults));
    output.mBuffers[0].mDataByteSize += 2 * sizeof(float);
    render(0, &time, &input, &time, &output, &time, &engine);
    assert(atomic_load(&engine.buffer_frames) == 0 && atomic_load(&engine.faults) == 1);
    free(samples);
    assert(close_graph(&engine));
}

static void recovery_contract(void) {
    memset(&hal, 0, sizeof(hal));
    hal.enabled = true; hal.rate = 48000; hal.channels = 2; hal.inputs = 1;
    hal.transport = kAudioDeviceTransportTypeUSB; hal.frames = 512; hal.device = 10;
    ABEngine engine = {0};
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    engine.host_seconds = (double)timebase.numer / timebase.denom / 1e9;
    assert(ab_engine_start(&engine, 6) == noErr);
    assert(engine.active && hal.input_usage[0] == 0 && hal.input_usage[1] == 1);
    assert(hal.frames == 256);
    atomic_store(&engine.buffer_frames, 256);
    atomic_store(&engine.latency_nanoseconds, 17170000);
    ABStatus status;
    ab_engine_status(&engine, &status);
    assert(status.buffer_frames == 256 && fabs(status.latency_ms - 17.17) < 0.001);
    atomic_store(&engine.dirty, 1);
    assert(ab_engine_poll(&engine) == noErr && hal.starts == 1); // own aggregate notification
    hal.rate = 44100; engine.last_attempt = 0; atomic_store(&engine.dirty, 1);
    assert(ab_engine_poll(&engine) == noErr && hal.starts == 2);
    assert(atomic_load(&engine.gain) == 6 && engine.rate == 44100);
    ab_engine_status(&engine, &status);
    assert(status.buffer_frames == 0 && status.latency_ms < 0);
    hal.channels = 1; engine.last_attempt = 0; atomic_store(&engine.dirty, 1);
    atomic_store(&engine.render_error, kAudio_ParamError); // format change can also break the DSP call
    assert(ab_engine_poll(&engine) == noErr && !engine.active && engine.wanted);
    assert(atomic_load(&engine.gain) == 0);
    UInt32 creations = hal.tap_creations;
    hal.channels = 2;
    assert(ab_engine_poll(&engine) == noErr && hal.tap_creations == creations); // retry is bounded
    engine.last_attempt = 0;
    assert(ab_engine_poll(&engine) == noErr && engine.active && atomic_load(&engine.gain) == 0);
    ab_engine_set_gain(&engine, 6);
    hal.device = 11; engine.last_attempt = 0; atomic_store(&engine.dirty, 1);
    assert(ab_engine_poll(&engine) == noErr && engine.active && atomic_load(&engine.gain) == 0);
    hal.device = 0; atomic_store(&engine.dirty, 1);
    assert(ab_engine_poll(&engine) == noErr && !engine.active && engine.wanted);
    hal.device = 11; engine.last_attempt = 0;
    assert(ab_engine_poll(&engine) == noErr && engine.active);
    // True DSP errors do not repeatedly restart the graph.
    atomic_store(&engine.render_error, kAudio_ParamError);
    assert(ab_engine_poll(&engine) == noErr && !engine.active && !engine.wanted);
    hal.deny_permission = true;
    assert(ab_engine_start(&engine, 3) != noErr && !engine.wanted);
    creations = hal.tap_creations; engine.last_attempt = 0; hal.deny_permission = false;
    assert(ab_engine_poll(&engine) == noErr && hal.tap_creations == creations);
    assert(ab_engine_start(&engine, 3) == noErr);
    hal.refuse_destroy = true;
    assert(ab_engine_stop(&engine) != noErr && engine.fatal && engine.processor && engine.io);
    ab_engine_status(&engine, &status);
    assert(!status.active && !status.buffer_frames && status.latency_ms < 0);
    hal.refuse_destroy = false;
    assert(ab_engine_stop(&engine) == noErr && !engine.processor && hal.frames == 512);
    engine.fatal = false;
    hal.reject_buffer = true;
    assert(ab_engine_start(&engine, 0) == noErr && hal.frames == 512);
    assert(ab_engine_stop(&engine) == noErr);
    hal.transport = kAudioDeviceTransportTypeBuiltIn;
    assert(ab_engine_start(&engine, 0) != noErr && !engine.active);
    hal.transport = kAudioDeviceTransportTypeUSB; hal.maximum = AB_CAPACITY + 1;
    assert(ab_engine_start(&engine, 0) != noErr && !engine.active);
    hal.maximum = AB_CAPACITY;
    assert(ab_engine_start(&engine, 0) == noErr);
    assert(ab_engine_stop(&engine) == noErr);
    hal.enabled = false;
}

int main(void) {
    format_contract();
    callback_contract();
    callback_capacity_contract();
    recovery_contract();
    for (int iteration = 0; iteration < 20; iteration++) {
        ABEngine *engine = ab_engine_create();
        assert(engine);
        ABStatus status;
        ab_engine_status(engine, &status);
        assert(!status.active && status.callbacks == 0);
        assert(ab_engine_stop(engine) == 0);
        assert(ab_engine_stop(engine) == 0);
        ab_engine_destroy(engine);
    }
    puts("native engine: callback buffers, stereo, error silencing, repeated lifecycle passed (no "
         "capture)");
}
