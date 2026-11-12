// Logging, Apple's LZ4 framing, and a small thread pool.
#include "tandem.h"

#include <lz4.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

// ---- Log --------------------------------------------------------------------------------------

#define RECENT 64
static pthread_mutex_t log_lock = PTHREAD_MUTEX_INITIALIZER;
static char recent[RECENT][160];
static unsigned recent_count;
static atomic_uint generation;

double now_seconds(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (double)t.tv_sec + (double)t.tv_nsec / 1e9;
}

void log_line(const char *format, ...) {
    char message[512];
    va_list args;
    va_start(args, format);
    vsnprintf(message, sizeof message, format, args);
    va_end(args);

    // Seconds since the machine started: its clock may be wrong, or in another time zone.
    double t = now_seconds();
    pthread_mutex_lock(&log_lock);
    fprintf(stderr, "%9.3f %s\n", t, message);
    fflush(stderr);
    snprintf(recent[recent_count % RECENT], sizeof recent[0], "%9.3f %s", t, message);
    recent_count++;
    pthread_mutex_unlock(&log_lock);
    atomic_fetch_add(&generation, 1);
}

int log_recent(char lines[][160], int max) {
    pthread_mutex_lock(&log_lock);
    unsigned have = recent_count < RECENT ? recent_count : RECENT;
    unsigned take = have < (unsigned)max ? have : (unsigned)max;
    for (unsigned i = 0; i < take; i++) {
        memcpy(lines[i], recent[(recent_count - take + i) % RECENT], sizeof recent[0]);
    }
    pthread_mutex_unlock(&log_lock);
    return (int)take;
}

unsigned log_generation(void) { return atomic_load(&generation); }

// ---- Apple's LZ4 ------------------------------------------------------------------------------

// compression_encode_buffer(COMPRESSION_LZ4) writes a run of blocks of up to 64 KiB each:
//   "bv41" u32 decoded size, u32 encoded size, then that much raw LZ4 (which may refer back into
//          the blocks before it)
//   "bv4-" u32 size, then that many bytes as they are
//   "bv4$" the end
#define MAGIC_COMPRESSED 0x31347662u
#define MAGIC_STORED 0x2d347662u
#define MAGIC_END 0x24347662u

long apple_lz4_decode(uint8_t *dst, size_t capacity, const uint8_t *src, size_t count) {
    size_t in = 0, out = 0;
    while (in + 4 <= count) {
        uint32_t magic = rd32(src + in);
        if (magic == MAGIC_END) return (long)out;
        if (magic == MAGIC_COMPRESSED) {
            if (in + 12 > count) return -1;
            uint32_t raw = rd32(src + in + 4), encoded = rd32(src + in + 8);
            in += 12;
            if (encoded > count - in || raw > capacity - out || raw > 0x7fffffffu || encoded > 0x7fffffffu) return -1;
            // Matches reach back at most 64 KiB, into what's already decoded.
            size_t history = out < 65536 ? out : 65536;
            int n = LZ4_decompress_safe_usingDict((const char *)src + in, (char *)dst + out, (int)encoded, (int)raw,
                                                  (const char *)dst + out - history, (int)history);
            if (n < 0 || (uint32_t)n != raw) return -1;
            in += encoded;
            out += raw;
        } else if (magic == MAGIC_STORED) {
            if (in + 8 > count) return -1;
            uint32_t raw = rd32(src + in + 4);
            in += 8;
            if (raw > count - in || raw > capacity - out) return -1;
            memcpy(dst + out, src + in, raw);
            in += raw;
            out += raw;
        } else {
            return -1;
        }
    }
    return in == count ? (long)out : -1;
}

// ---- Thread pool ------------------------------------------------------------------------------

static pthread_mutex_t pool_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t pool_wake = PTHREAD_COND_INITIALIZER;
static pthread_cond_t pool_done = PTHREAD_COND_INITIALIZER;
static void (*pool_work)(void *, int);
static void *pool_context;
static int pool_count;
static atomic_int pool_next;
static int pool_threads;
static int pool_pending;
static unsigned pool_job;

static void pool_drain(void) {
    for (;;) {
        int i = atomic_fetch_add(&pool_next, 1);
        if (i >= pool_count) return;
        pool_work(pool_context, i);
    }
}

static void *pool_thread(void *unused) {
    (void)unused;
    unsigned seen = 0;
    pthread_mutex_lock(&pool_lock);
    for (;;) {
        while (pool_job == seen) pthread_cond_wait(&pool_wake, &pool_lock);
        seen = pool_job;
        pthread_mutex_unlock(&pool_lock);
        pool_drain();
        pthread_mutex_lock(&pool_lock);
        if (--pool_pending == 0) pthread_cond_broadcast(&pool_done);
    }
    return NULL;
}

void pool_start(int threads) {
    for (int i = 0; i < threads; i++) {
        pthread_t thread;
        if (pthread_create(&thread, NULL, pool_thread, NULL) == 0) {
            pthread_detach(thread);
            pool_threads++;
        }
    }
}

void pool_run(int count, void (*work)(void *, int), void *context) {
    if (count <= 0) return;
    if (count == 1 || pool_threads == 0) {
        for (int i = 0; i < count; i++) work(context, i);
        return;
    }
    pthread_mutex_lock(&pool_lock);
    pool_work = work;
    pool_context = context;
    pool_count = count;
    atomic_store(&pool_next, 0);
    // Every worker takes part in every job, and the job isn't over until each has finished
    // with it: none can still be looking at this job's work when the next one is set up.
    pool_pending = pool_threads;
    pool_job++;
    pthread_cond_broadcast(&pool_wake);
    pthread_mutex_unlock(&pool_lock);

    pool_drain();

    pthread_mutex_lock(&pool_lock);
    while (pool_pending > 0) pthread_cond_wait(&pool_done, &pool_lock);
    pthread_mutex_unlock(&pool_lock);
}
