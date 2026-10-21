// Explicit hardware acceptance helper; never linked into the application.
#include <CoreAudio/CoreAudio.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static OSStatus get(AudioObjectID object, AudioObjectPropertySelector selector, void *value,
                    UInt32 size) {
    AudioObjectPropertyAddress address = {selector, kAudioObjectPropertyScopeGlobal,
                                          kAudioObjectPropertyElementMain};
    return AudioObjectGetPropertyData(object, &address, 0, NULL, &size, value);
}

int main(int argc, char **argv) {
    AudioDeviceID device = 0;
    UInt32 transport = 0, frames = 0;
    Float64 rate = 0;
    OSStatus error = get(kAudioObjectSystemObject, kAudioHardwarePropertyDefaultOutputDevice,
                         &device, sizeof(device));
    if (!error)
        error = get(device, kAudioDevicePropertyTransportType, &transport, sizeof(transport));
    if (!error && transport != kAudioDeviceTransportTypeBuiltIn)
        error = kAudioHardwareUnsupportedOperationError;
    if (!error && argc == 3 && !strcmp(argv[1], "--set-rate")) {
        if (!strcmp(argv[2], "44100"))
            rate = 44100;
        else if (!strcmp(argv[2], "48000"))
            rate = 48000;
        else
            return 2;
        AudioObjectPropertyAddress address = {kAudioDevicePropertyNominalSampleRate,
                                              kAudioObjectPropertyScopeGlobal,
                                              kAudioObjectPropertyElementMain};
        error = AudioObjectSetPropertyData(device, &address, 0, NULL, sizeof(rate), &rate);
    } else if (argc != 1)
        return 2;
    if (!error)
        error = get(device, kAudioDevicePropertyNominalSampleRate, &rate, sizeof(rate));
    if (!error)
        error = get(device, kAudioDevicePropertyBufferFrameSize, &frames, sizeof(frames));
    if (error) {
        fprintf(stderr, "device test helper: Core Audio status %d\n", (int)error);
        return 1;
    }
    printf("{\"device\":%u,\"sample_rate\":%.0f,\"buffer_frames\":%u}\n", device, rate, frames);
}
