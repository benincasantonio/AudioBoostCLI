#include "audio.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

static void test_rate(double rate) {
    int32_t error = 0;
    const uint32_t n = 256;
    float in[512] = {0}, out[512] = {0};
    ABProcessor *p = ab_processor_create(rate, n, 6, &error);
    if (!p || error)
        fprintf(stderr, "create processor at %.0f Hz: OSStatus %d\n", rate, error);
    assert(p && error == 0);
    assert(ab_processor_latency(p) >= 0 && ab_processor_latency(p) < 0.020);
    for (int block = 0; block < 30; block++) {
        assert(ab_processor_process(p, in, out, n, 6) == 0);
        for (int i = 0; i < 512; i++)
            assert(fabsf(out[i]) < 1e-7f);
    }
    // Opposite channels must retain their relationship and low-level gain.
    for (int i = 0; i < 256; i++) {
        in[i * 2] = 0.01f;
        in[i * 2 + 1] = -0.005f;
    }
    for (int block = 0; block < 40; block++)
        assert(ab_processor_process(p, in, out, n, 6) == 0);
    for (int i = 0; i < 256; i++) {
        assert(fabsf(out[2 * i] - 0.019952623f) < 0.00002f);
        assert(fabsf(out[2 * i] + 2 * out[2 * i + 1]) < 1e-6f);
    }
    // A 20 ms gain ramp must not jump immediately to its destination.
    int ramp_samples = 0;
    float previous = out[510];
    for (int block = 0; block < 10; block++) {
        assert(ab_processor_process(p, in, out, n, 12) == 0);
        for (int i = 0; i < 512; i += 2) {
            assert(fabsf(out[i] - previous) < 0.00003f);
            if (out[i] > 0.019953623f && out[i] < 0.039809717f)
                ramp_samples++;
            previous = out[i];
        }
    }
    assert(ramp_samples > rate * 0.019 && ramp_samples < rate * 0.021);
    for (int block = 0; block < 40; block++)
        assert(ab_processor_process(p, in, out, n, 12) == 0);
    assert(fabsf(out[510] - 0.039810717f) < 0.00002f);
    // Abrupt transients and sustained over-ceiling material must remain finite and bounded.
    for (int block = 0; block < 300; block++) {
        for (int i = 0; i < 256; i++) {
            float x = (block % 3 == 0) ? (i % 37 == 0 ? 1.0f : 0)
                                       : sinf((float)(block * 256 + i) * 0.17f);
            in[i * 2] = x;
            in[i * 2 + 1] = -x;
        }
        assert(ab_processor_process(p, in, out, n, 12) == 0);
        for (int i = 0; i < 512; i++)
            assert(isfinite(out[i]) && fabsf(out[i]) <= 0.891251f);
    }
    assert(ab_processor_process(p, in, out, n + 1, 3) != 0);
    assert(ab_processor_process(p, in, out, n, NAN) != 0);
    in[0] = NAN;
    assert(ab_processor_process(p, in, out, n, 3) != 0);
    ab_processor_destroy(p);
}

int main(void) {
    test_rate(44100);
    test_rate(48000);
    int32_t error = 0;
    assert(!ab_processor_create(0, 256, 3, &error));
    assert(!ab_processor_create(48000, 0, 3, &error));
    ab_processor_destroy(NULL);
    puts("offline native audio: 44.1/48 kHz gain, silence, smoothing, stereo, transients, bounds "
         "passed");
}
