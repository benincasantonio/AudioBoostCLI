// Explicit hardware acceptance helper; never linked into the application.
#include <CoreAudio/CoreAudio.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static OSStatus get(AudioObjectID object, AudioObjectPropertySelector selector, void *value,
                    UInt32 size) {
    AudioObjectPropertyAddress address = {selector, kAudioObjectPropertyScopeGlobal,
                                          kAudioObjectPropertyElementMain};
    return AudioObjectGetPropertyData(object, &address, 0, NULL, &size, value);
}

static void json_string(CFStringRef string) {
    char text[1024] = {0};
    if (string) CFStringGetCString(string, text, sizeof(text), kCFStringEncodingUTF8);
    putchar('"');
    for (const unsigned char *p = (const unsigned char *)text; *p; p++) {
        if (*p == '"' || *p == '\\') putchar('\\');
        if (*p < 32) printf("\\u%04x", *p);
        else putchar(*p);
    }
    putchar('"');
}

int main(int argc, char **argv) {
    AudioDeviceID device = 0;
    UInt32 transport = 0, frames = 0;
    Float64 rate = 0;
    CFStringRef uid = NULL;
    OSStatus error = get(kAudioObjectSystemObject, kAudioHardwarePropertyDefaultOutputDevice,
                         &device, sizeof(device));
    if (!error)
        error = get(device, kAudioDevicePropertyTransportType, &transport, sizeof(transport));
    AudioObjectPropertyAddress rates_property = {kAudioDevicePropertyAvailableNominalSampleRates,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    AudioValueRange *rates = NULL;
    if (!error) error = AudioObjectGetPropertyDataSize(device, &rates_property, 0, NULL, &size);
    if (!error && size && size % sizeof(AudioValueRange) == 0) {
        rates = malloc(size);
        if (!rates) return 1;
        error = AudioObjectGetPropertyData(device, &rates_property, 0, NULL, &size, rates);
    }
    if (!rates && !error) error = kAudioHardwareUnsupportedOperationError;
    if (!error && argc == 3 && !strcmp(argv[1], "--set-rate")) {
        char *end = NULL;
        rate = strtod(argv[2], &end);
        bool supported = false;
        for (UInt32 i = 0; i < size / sizeof(*rates); i++)
            if (rate >= rates[i].mMinimum && rate <= rates[i].mMaximum) supported = true;
        if (!*argv[2] || *end || !isfinite(rate) || rate < 8000 || rate > 192000 || !supported) {
            free(rates); return 2;
        }
        AudioObjectPropertyAddress address = {kAudioDevicePropertyNominalSampleRate,
                                              kAudioObjectPropertyScopeGlobal,
                                              kAudioObjectPropertyElementMain};
        error = AudioObjectSetPropertyData(device, &address, 0, NULL, sizeof(rate), &rate);
    } else if (argc != 1) { free(rates); return 2; }
    if (!error)
        error = get(device, kAudioDevicePropertyNominalSampleRate, &rate, sizeof(rate));
    if (!error)
        error = get(device, kAudioDevicePropertyBufferFrameSize, &frames, sizeof(frames));
    if (!error)
        error = get(device, kAudioDevicePropertyDeviceUID, &uid, sizeof(uid));
    if (error) {
        fprintf(stderr, "device test helper: Core Audio status %d\n", (int)error);
        free(rates);
        return 1;
    }
    printf("{\"device\":%u,\"uid\":", device);
    json_string(uid);
    CFRelease(uid);
    printf(",\"transport\":%u,\"built_in\":%s,\"sample_rate\":%.0f,\"buffer_frames\":%u,\"sample_rate_ranges\":[",
           transport, transport == kAudioDeviceTransportTypeBuiltIn ? "true" : "false", rate, frames);
    for (UInt32 i = 0; i < size / sizeof(*rates); i++)
        printf("%s[%.0f,%.0f]", i ? "," : "", rates[i].mMinimum, rates[i].mMaximum);
    free(rates);
    puts("]}");
}
