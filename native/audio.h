#ifndef AUDIOBOOST_AUDIO_H
#define AUDIOBOOST_AUDIO_H
#include <stdint.h>

typedef struct ABProcessor ABProcessor;
typedef struct ABEngine ABEngine;

// Creation/destruction run on the control thread; process() runs on the audio thread.
ABProcessor *ab_processor_create(double rate, uint32_t capacity, float gain_db, int32_t *error);
int32_t ab_processor_process(ABProcessor *p, const float *input, float *output, uint32_t frames,
                             float gain_db);
double ab_processor_latency(const ABProcessor *p);
void ab_processor_destroy(ABProcessor *p);

typedef struct {
    double sample_rate;
    double latency_ms;
    uint64_t callbacks;
    uint64_t faults;
    float gain_db;
    uint32_t active; // 0: idle/error, 1: active, 2: sleeping
    uint32_t buffer_frames;
    char device[256];
    char error[512];
} ABStatus;

ABEngine *ab_engine_create(void);
int32_t ab_engine_start(ABEngine *engine, float gain_db);
void ab_engine_set_gain(ABEngine *engine, float gain_db);
int32_t ab_engine_poll(ABEngine *engine);
void ab_engine_status(ABEngine *engine, ABStatus *status);
int32_t ab_engine_stop(ABEngine *engine);
void ab_engine_destroy(ABEngine *engine);
void ab_run_loop(double seconds);
#endif
