#define _GNU_SOURCE
/* Local profiling only: native counters with explicit main-thread scopes.
 * No player data, GL synchronization, or changes to rendering calls. */
#include <dlfcn.h>
#include <time.h>
#include <GL/gl.h>
#include <SDL2/SDL.h>

typedef struct { unsigned long calls; double wall_ms, cpu_ms; unsigned long pixels; } sample;
static __thread int active;
static __thread sample records[4][4];
static double stamp(clockid_t id) {
    struct timespec t; clock_gettime(id, &t);
    return t.tv_sec * 1000.0 + t.tv_nsec / 1e6;
}
int faster_render_scope(int scope) { int old = active; active = scope; return old; }
void faster_render_reset(void) {
    for (int i = 0; i < 4; i++) for (int j = 0; j < 4; j++) records[i][j] = (sample){0};
}
double faster_render_stat(int scope, int kind, int metric) {
    if (scope < 0 || scope >= 4 || kind < 0 || kind >= 4) return -1;
    sample *s = &records[scope][kind];
    return metric == 0 ? s->calls : metric == 1 ? s->wall_ms : metric == 2 ? s->cpu_ms : s->pixels;
}
static void record(int scope, int kind, double wall, double cpu, unsigned long pixels) {
    sample *s = &records[scope][kind];
    s->calls++; s->wall_ms += stamp(CLOCK_MONOTONIC) - wall;
    s->cpu_ms += stamp(CLOCK_THREAD_CPUTIME_ID) - cpu; s->pixels += pixels;
}
SDL_Surface *TTF_RenderUTF8_Blended(void *font, const char *text, SDL_Color color) {
    static SDL_Surface *(*real)(void *, const char *, SDL_Color);
    if (!real) real = dlsym(RTLD_NEXT, "TTF_RenderUTF8_Blended");
    int scope = active;
    if (!scope) return real(font, text, color);
    double w = stamp(CLOCK_MONOTONIC), c = stamp(CLOCK_THREAD_CPUTIME_ID);
    SDL_Surface *s = real(font, text, color);
    record(scope, 0, w, c, s ? (unsigned long)s->w * s->h : 0); return s;
}
void glTexImage2D(GLenum target, GLint level, GLint internal, GLsizei width, GLsizei height,
                 GLint border, GLenum format, GLenum type, const GLvoid *pixels) {
    static void (*real)(GLenum, GLint, GLint, GLsizei, GLsizei, GLint, GLenum, GLenum, const GLvoid *);
    if (!real) real = dlsym(RTLD_NEXT, "glTexImage2D");
    int scope = active;
    if (!scope) { real(target, level, internal, width, height, border, format, type, pixels); return; }
    double w = stamp(CLOCK_MONOTONIC), c = stamp(CLOCK_THREAD_CPUTIME_ID);
    real(target, level, internal, width, height, border, format, type, pixels);
    record(scope, 1, w, c, (unsigned long)width * height);
}
void glTexSubImage2D(GLenum target, GLint level, GLint x, GLint y, GLsizei width, GLsizei height,
                    GLenum format, GLenum type, const GLvoid *pixels) {
    static void (*real)(GLenum, GLint, GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, const GLvoid *);
    if (!real) real = dlsym(RTLD_NEXT, "glTexSubImage2D");
    int scope = active;
    if (!scope) { real(target, level, x, y, width, height, format, type, pixels); return; }
    double w = stamp(CLOCK_MONOTONIC), c = stamp(CLOCK_THREAD_CPUTIME_ID);
    real(target, level, x, y, width, height, format, type, pixels);
    record(scope, 2, w, c, (unsigned long)width * height);
}
void glDrawArrays(GLenum mode, GLint first, GLsizei count) {
    static void (*real)(GLenum, GLint, GLsizei);
    if (!real) real = dlsym(RTLD_NEXT, "glDrawArrays");
    int scope = active;
    if (!scope) { real(mode, first, count); return; }
    double w = stamp(CLOCK_MONOTONIC), c = stamp(CLOCK_THREAD_CPUTIME_ID);
    real(mode, first, count); record(scope, 3, w, c, count);
}
