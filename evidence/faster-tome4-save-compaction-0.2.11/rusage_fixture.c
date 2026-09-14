#define _GNU_SOURCE
#include <assert.h>
#include <pthread.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/resource.h>
#include <time.h>

size_t fixture_sizeof_rusage(void) { return sizeof(struct rusage); }
size_t fixture_sizeof_timeval(void) { return sizeof(struct timeval); }
size_t fixture_offset_stime(void) { return offsetof(struct rusage, ru_stime); }
size_t fixture_offset_nivcsw(void) { return offsetof(struct rusage, ru_nivcsw); }
int fixture_self(void) { return RUSAGE_SELF; }
int fixture_thread(void) { return RUSAGE_THREAD; }

int fixture_sample(int who, double *out) {
    struct rusage ru;
    int ret = getrusage(who, &ru);
    if (ret != 0) return ret;
    out[0] = ru.ru_utime.tv_sec * 1000.0 + ru.ru_utime.tv_usec / 1000.0;
    out[1] = ru.ru_stime.tv_sec * 1000.0 + ru.ru_stime.tv_usec / 1000.0;
    return 0;
}

static int64_t ns(void) {
    struct timespec ts;
    assert(clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts) == 0);
    return (int64_t)ts.tv_sec * 1000000000 + ts.tv_nsec;
}
static void *worker(void *arg) {
    volatile uint64_t n = 17;
    int64_t start = ns();
    do {
        for (int i=0; i<100000; ++i) n = n * 2862933555777941757ULL + 3037000493ULL;
    } while (ns() - start < 30000000);
    (void)arg;
    return NULL;
}
int fixture_worker(void) {
    pthread_t thread;
    int ret = pthread_create(&thread, NULL, worker, NULL);
    return ret == 0 ? pthread_join(thread, NULL) : ret;
}
