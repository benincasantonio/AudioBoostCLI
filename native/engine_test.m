// Compile the callback with its real processor to exercise buffer boundaries without intercepting
// playback.
#include "engine.m"
#include <assert.h>

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
    // A short input must never be read beyond its provided storage.
    in.mBuffers[0].mDataByteSize = 4;
    render(0, &time, &in, &time, &out, &time, &engine);
    assert(atomic_load(&engine.faults) == 1 && atomic_load(&engine.render_error) != 0);
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
    // Losing all output channels must release interception, not look like healthy rendering.
    out.mNumberBuffers = 0;
    render(0, &time, &in, &time, &out, &time, &engine);
    assert(atomic_load(&engine.faults) == 2);
    ab_processor_destroy(engine.processor);
}

int main(void) {
    callback_contract();
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
