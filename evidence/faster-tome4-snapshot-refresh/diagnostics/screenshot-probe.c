#define _GNU_SOURCE
/* Opt-in local attribution only. Every intercepted call executes unchanged.
 * No GL queries, glFinish, pixel inspection, PNG configuration, or I/O. */
#include <dlfcn.h>
#include <stdint.h>
#include <string.h>
#include <time.h>
#include <GL/gl.h>
#include <SDL2/SDL.h>
#include <png.h>

enum { SCOPES = 4, TAGS = 16, READ_PIXELS = 0, PNG_ENCODE = 1 };
typedef struct {
    uint64_t calls, completed, pixels;
    double wall_ms, cpu_ms, max_wall_ms, max_cpu_ms;
} sample;
typedef struct {
    uint64_t calls, scopes, intervals;
    double wall_ms, cpu_ms, max_gap_ms, max_cpu_gap_ms;
    double swap_wall_ms, swap_cpu_ms, max_swap_ms;
    double max_first_gap_ms, max_tail_gap_ms;
} swaps;
static __thread int active, png_depth, swap_tag;
static __thread sample records[SCOPES][2];
static __thread swaps presentations[TAGS];
static __thread double swap_start_wall, swap_start_cpu, swap_last_wall, swap_last_cpu;
static __thread uint64_t scope_swaps;

static double stamp(clockid_t id) {
    struct timespec t;
    clock_gettime(id, &t);
    return t.tv_sec * 1000.0 + t.tv_nsec / 1e6;
}
static double max(double a, double b) { return a > b ? a : b; }
double faster_screenshot_clock(int cpu) {
    return stamp(cpu ? CLOCK_THREAD_CPUTIME_ID : CLOCK_MONOTONIC);
}
int faster_screenshot_scope(int scope) {
    int old = active;
    active = scope > 0 && scope < SCOPES ? scope : 0;
    /* libpng can longjmp past an interposer. Its incomplete call remains
     * visible in calls-completed; do not suppress the next screenshot. */
    if (!active) png_depth = 0;
    return old;
}
static void completed(sample *s, double wall, double cpu) {
    double w = stamp(CLOCK_MONOTONIC) - wall;
    double c = stamp(CLOCK_THREAD_CPUTIME_ID) - cpu;
    s->completed++;
    s->wall_ms += w; s->cpu_ms += c;
    s->max_wall_ms = max(s->max_wall_ms, w);
    s->max_cpu_ms = max(s->max_cpu_ms, c);
}
static void gap(swaps *s, double wall, double cpu, int first, int tail) {
    s->intervals++;
    s->max_gap_ms = max(s->max_gap_ms, wall);
    s->max_cpu_gap_ms = max(s->max_cpu_gap_ms, cpu);
    if (first) s->max_first_gap_ms = max(s->max_first_gap_ms, wall);
    if (tail) s->max_tail_gap_ms = max(s->max_tail_gap_ms, wall);
}
void faster_screenshot_swap_end(void) {
    if (!swap_tag) return;
    double w = stamp(CLOCK_MONOTONIC), c = stamp(CLOCK_THREAD_CPUTIME_ID);
    swaps *s = &presentations[swap_tag];
    gap(s, w - swap_last_wall, c - swap_last_cpu, !scope_swaps, 1);
    s->wall_ms += w - swap_start_wall;
    s->cpu_ms += c - swap_start_cpu;
    swap_tag = 0;
}
int faster_screenshot_swap_begin(int tag) {
    if (swap_tag || tag <= 0 || tag >= TAGS) return 0;
    swap_tag = tag; scope_swaps = 0;
    swap_start_wall = swap_last_wall = stamp(CLOCK_MONOTONIC);
    swap_start_cpu = swap_last_cpu = stamp(CLOCK_THREAD_CPUTIME_ID);
    presentations[tag].scopes++;
    return 1;
}
void faster_screenshot_reset(void) {
    memset(records, 0, sizeof records);
    memset(presentations, 0, sizeof presentations);
    if (swap_tag) {
        scope_swaps = 0;
        swap_start_wall = swap_last_wall = stamp(CLOCK_MONOTONIC);
        swap_start_cpu = swap_last_cpu = stamp(CLOCK_THREAD_CPUTIME_ID);
        presentations[swap_tag].scopes = 1;
    }
}
double faster_screenshot_stat(int scope, int kind, int metric) {
    if (scope <= 0 || scope >= SCOPES || kind < 0 || kind >= 2) return -1;
    sample *s = &records[scope][kind];
    switch (metric) {
    case 0: return s->calls;
    case 1: return s->completed;
    case 2: return s->wall_ms;
    case 3: return s->cpu_ms;
    case 4: return s->max_wall_ms;
    case 5: return s->max_cpu_ms;
    case 6: return s->pixels;
    default: return -1;
    }
}
double faster_screenshot_swap_stat(int tag, int metric) {
    if (tag <= 0 || tag >= TAGS) return -1;
    swaps s = presentations[tag];
    if (swap_tag == tag) {
        /* A read-only snapshot includes the current trailing interval. */
        double w = stamp(CLOCK_MONOTONIC), c = stamp(CLOCK_THREAD_CPUTIME_ID);
        gap(&s, w - swap_last_wall, c - swap_last_cpu, !scope_swaps, 1);
        s.wall_ms += w - swap_start_wall;
        s.cpu_ms += c - swap_start_cpu;
    }
    switch (metric) {
    case 0: return s.calls;
    case 1: return s.scopes;
    case 2: return s.wall_ms;
    case 3: return s.cpu_ms;
    case 4: return s.max_gap_ms;
    case 5: return s.max_cpu_gap_ms;
    case 6: return s.intervals;
    case 7: return s.swap_wall_ms;
    case 8: return s.swap_cpu_ms;
    case 9: return s.max_swap_ms;
    case 10: return s.max_first_gap_ms;
    case 11: return s.max_tail_gap_ms;
    default: return -1;
    }
}
void glReadPixels(GLint x, GLint y, GLsizei width, GLsizei height,
                  GLenum format, GLenum type, GLvoid *pixels) {
    static void (*real)(GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, GLvoid *);
    if (!real) real = dlsym(RTLD_NEXT, "glReadPixels");
    int scope = active;
    if (!scope) { real(x, y, width, height, format, type, pixels); return; }
    sample *s = &records[scope][READ_PIXELS];
    s->calls++;
    if (width > 0 && height > 0) s->pixels += (uint64_t)width * height;
    double w = stamp(CLOCK_MONOTONIC), c = stamp(CLOCK_THREAD_CPUTIME_ID);
    real(x, y, width, height, format, type, pixels);
    completed(s, w, c);
}
void png_write_png(png_structrp png, png_inforp info, int transforms, png_voidp params) {
    static void (*real)(png_structrp, png_inforp, int, png_voidp);
    if (!real) real = dlsym(RTLD_NEXT, "png_write_png");
    int scope = active;
    if (!scope || png_depth) { real(png, info, transforms, params); return; }
    sample *s = &records[scope][PNG_ENCODE];
    s->calls++; png_depth++;
    double w = stamp(CLOCK_MONOTONIC), c = stamp(CLOCK_THREAD_CPUTIME_ID);
    real(png, info, transforms, params);
    completed(s, w, c); png_depth--;
}
void png_write_image(png_structrp png, png_bytepp rows) {
    static void (*real)(png_structrp, png_bytepp);
    if (!real) real = dlsym(RTLD_NEXT, "png_write_image");
    int scope = active;
    if (!scope || png_depth) { real(png, rows); return; }
    sample *s = &records[scope][PNG_ENCODE];
    s->calls++; png_depth++;
    double w = stamp(CLOCK_MONOTONIC), c = stamp(CLOCK_THREAD_CPUTIME_ID);
    real(png, rows);
    completed(s, w, c); png_depth--;
}
void SDL_GL_SwapWindow(SDL_Window *window) {
    static void (*real)(SDL_Window *);
    if (!real) real = dlsym(RTLD_NEXT, "SDL_GL_SwapWindow");
    int tag = swap_tag;
    if (!tag) { real(window); return; }
    swaps *s = &presentations[tag];
    double w = stamp(CLOCK_MONOTONIC), c = stamp(CLOCK_THREAD_CPUTIME_ID);
    /* Intervals end at call entry: this measures frame submission, not GPU
     * completion. Prior swap blocking is naturally included in the next gap. */
    gap(s, w - swap_last_wall, c - swap_last_cpu, !scope_swaps, 0);
    swap_last_wall = w; swap_last_cpu = c; scope_swaps++; s->calls++;
    real(window);
    double dt = stamp(CLOCK_MONOTONIC) - w;
    s->swap_wall_ms += dt;
    s->swap_cpu_ms += stamp(CLOCK_THREAD_CPUTIME_ID) - c;
    s->max_swap_ms = max(s->max_swap_ms, dt);
}
