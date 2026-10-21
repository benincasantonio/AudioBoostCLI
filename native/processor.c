#include "audio.h"
#include <AudioToolbox/AudioToolbox.h>
#include <errno.h>
#include <math.h>
#include <stdlib.h>

struct ABProcessor {
    AudioUnit limiter;
    double rate, latency, sample_time;
    uint32_t capacity, prepared, remaining;
    float current, target, step;
    float *input[2], *output[2];
};

static OSStatus supply(void *context, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time,
                       UInt32 bus, UInt32 frames, AudioBufferList *buffers) {
    (void)flags;
    (void)time;
    (void)bus;
    ABProcessor *p = context;
    if (frames != p->prepared || buffers->mNumberBuffers != 2)
        return kAudio_ParamError;
    for (int c = 0; c < 2; c++) {
        buffers->mBuffers[c].mNumberChannels = 1;
        buffers->mBuffers[c].mDataByteSize = frames * sizeof(float);
        buffers->mBuffers[c].mData = p->input[c];
    }
    return noErr;
}

ABProcessor *ab_processor_create(double rate, uint32_t capacity, float gain, int32_t *error) {
    *error = kAudio_ParamError;
    if (!isfinite(rate) || rate < 8000 || rate > 192000 || !capacity || capacity > 16384 ||
        !isfinite(gain) || gain < 0 || gain > 12)
        return NULL;
    ABProcessor *p = calloc(1, sizeof(*p));
    if (!p) {
        *error = -ENOMEM;
        return NULL;
    }
    p->rate = rate;
    p->capacity = capacity;
    // +1 dB before and -1 dB after the limiter lower its ceiling without losing requested gain.
    p->current = p->target = powf(10, (gain + 1) / 20);
    for (int c = 0; c < 2; c++) {
        p->input[c] = calloc(capacity, sizeof(float));
        p->output[c] = calloc(capacity, sizeof(float));
        if (!p->input[c] || !p->output[c]) {
            *error = -ENOMEM;
            goto fail;
        }
    }
    AudioComponentDescription description = {.componentType = kAudioUnitType_Effect,
                                             .componentSubType = kAudioUnitSubType_PeakLimiter,
                                             .componentManufacturer = kAudioUnitManufacturer_Apple};
    AudioComponent component = AudioComponentFindNext(NULL, &description);
    if (!component) {
        *error = kAudioUnitErr_InvalidProperty;
        goto fail;
    }
    if ((*error = AudioComponentInstanceNew(component, &p->limiter)))
        goto fail;
    AudioStreamBasicDescription format = {.mSampleRate = rate,
                                          .mFormatID = kAudioFormatLinearPCM,
                                          .mFormatFlags = kAudioFormatFlagsNativeFloatPacked |
                                                          kAudioFormatFlagIsNonInterleaved,
                                          .mBytesPerPacket = 4,
                                          .mFramesPerPacket = 1,
                                          .mBytesPerFrame = 4,
                                          .mChannelsPerFrame = 2,
                                          .mBitsPerChannel = 32};
    if ((*error = AudioUnitSetProperty(p->limiter, kAudioUnitProperty_StreamFormat,
                                       kAudioUnitScope_Input, 0, &format, sizeof(format))))
        goto fail;
    if ((*error = AudioUnitSetProperty(p->limiter, kAudioUnitProperty_StreamFormat,
                                       kAudioUnitScope_Output, 0, &format, sizeof(format))))
        goto fail;
    if ((*error = AudioUnitSetProperty(p->limiter, kAudioUnitProperty_MaximumFramesPerSlice,
                                       kAudioUnitScope_Global, 0, &capacity, sizeof(capacity))))
        goto fail;
    AURenderCallbackStruct callback = {.inputProc = supply, .inputProcRefCon = p};
    if ((*error = AudioUnitSetProperty(p->limiter, kAudioUnitProperty_SetRenderCallback,
                                       kAudioUnitScope_Input, 0, &callback, sizeof(callback))))
        goto fail;
    if ((*error = AudioUnitSetParameter(p->limiter, kLimiterParam_AttackTime,
                                        kAudioUnitScope_Global, 0, 0.005f, 0)))
        goto fail;
    if ((*error = AudioUnitSetParameter(p->limiter, kLimiterParam_DecayTime, kAudioUnitScope_Global,
                                        0, 0.050f, 0)))
        goto fail;
    if ((*error = AudioUnitSetParameter(p->limiter, kLimiterParam_PreGain, kAudioUnitScope_Global,
                                        0, 0, 0)))
        goto fail;
    if ((*error = AudioUnitInitialize(p->limiter)))
        goto fail;
    UInt32 size = sizeof(p->latency);
    if ((*error = AudioUnitGetProperty(p->limiter, kAudioUnitProperty_Latency,
                                       kAudioUnitScope_Global, 0, &p->latency, &size)))
        goto fail;
    return p;
fail:
    ab_processor_destroy(p);
    return NULL;
}

int32_t ab_processor_process(ABProcessor *p, const float *input, float *output, uint32_t frames,
                             float gain) {
    if (!p || !input || !output || !frames || frames > p->capacity || !isfinite(gain) || gain < 0 ||
        gain > 12)
        return kAudio_ParamError;
    for (uint32_t i = 0; i < frames * 2; i++)
        if (!isfinite(input[i]))
            return kAudio_ParamError;
    float target = powf(10, (gain + 1) / 20);
    if (target != p->target) {
        p->target = target;
        p->remaining = (uint32_t)llround(p->rate * 0.020);
        p->step = (target - p->current) / (float)p->remaining;
    }
    for (uint32_t i = 0; i < frames; i++) {
        if (p->remaining && --p->remaining)
            p->current += p->step;
        else
            p->current = p->target;
        p->input[0][i] = input[2 * i] * p->current;
        p->input[1][i] = input[2 * i + 1] * p->current;
    }
    struct {
        UInt32 count;
        AudioBuffer buffer[2];
    } buffers = {.count = 2,
                 .buffer = {{1, frames * 4, p->output[0]}, {1, frames * 4, p->output[1]}}};
    AudioTimeStamp time = {.mSampleTime = p->sample_time, .mFlags = kAudioTimeStampSampleTimeValid};
    AudioUnitRenderActionFlags flags = 0;
    p->prepared = frames;
    OSStatus error =
        AudioUnitRender(p->limiter, &flags, &time, 0, frames, (AudioBufferList *)&buffers);
    p->sample_time += frames;
    if (error)
        return error;
    const float headroom = 0.891250938f;
    for (uint32_t i = 0; i < frames; i++)
        for (int c = 0; c < 2; c++) {
            float value = ((float *)buffers.buffer[c].mData)[i] * headroom;
            if (!isfinite(value))
                return kAudio_ParamError;
            output[2 * i + c] = value;
        }
    return noErr;
}

double ab_processor_latency(const ABProcessor *p) {
    return p ? p->latency : 0;
}

void ab_processor_destroy(ABProcessor *p) {
    if (!p)
        return;
    if (p->limiter) {
        AudioUnitUninitialize(p->limiter);
        AudioComponentInstanceDispose(p->limiter);
    }
    for (int c = 0; c < 2; c++) {
        free(p->input[c]);
        free(p->output[c]);
    }
    free(p);
}
