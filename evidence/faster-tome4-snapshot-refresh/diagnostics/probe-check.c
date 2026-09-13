/* Headless interposition check. BUILD_STUB supplies known GL/SDL callees;
 * the executable uses real libpng to verify byte identity and nesting. */
#define _GNU_SOURCE
#include <assert.h>
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <GL/gl.h>
#include <SDL2/SDL.h>
#include <png.h>

#ifdef BUILD_STUB
static int reads, swaps;
int probe_fixture_reads(void) { return reads; }
int probe_fixture_swaps(void) { return swaps; }
void glReadPixels(GLint x, GLint y, GLsizei w, GLsizei h, GLenum fmt, GLenum type, GLvoid *data) {
    assert(x == 3 && y == 5 && w == 8 && h == 8 && fmt == GL_RGB && type == GL_UNSIGNED_BYTE);
    unsigned char *p = data;
    for (int i = 0; i < 8*8*3; i++) p[i] = (i*37) & 255;
    reads++;
}
void SDL_GL_SwapWindow(SDL_Window *window) {
    assert(window == (SDL_Window *)0x1234);
    swaps++;
}
#else
extern int probe_fixture_reads(void);
extern int probe_fixture_swaps(void);
typedef struct { unsigned char bytes[4096]; size_t size; int fail; } output;
static void write_bytes(png_structp png, png_bytep bytes, png_size_t size) {
    output *out = png_get_io_ptr(png);
    if (out->fail) png_error(png, "intentional fixture failure");
    assert(out->size + size <= sizeof out->bytes);
    memcpy(out->bytes + out->size, bytes, size); out->size += size;
}
static void png_failure(png_structp png, png_const_charp message) {
    (void)message; png_longjmp(png, 1);
}
static int encode(unsigned char *pixels, output *out) {
    png_structp png = png_create_write_struct(PNG_LIBPNG_VER_STRING, NULL, png_failure, NULL);
    png_infop info = png_create_info_struct(png);
    assert(png && info);
    if (setjmp(png_jmpbuf(png))) { png_destroy_write_struct(&png, &info); return 0; }
    png_set_write_fn(png, out, write_bytes, NULL);
    png_set_IHDR(png, info, 8, 8, 8, PNG_COLOR_TYPE_RGB, PNG_INTERLACE_NONE,
                 PNG_COMPRESSION_TYPE_DEFAULT, PNG_FILTER_TYPE_DEFAULT);
    png_bytep rows[8];
    for (int i = 0; i < 8; i++) rows[i] = pixels + i*8*3;
    png_set_rows(png, info, rows);
    png_write_png(png, info, PNG_TRANSFORM_IDENTITY, NULL);
    png_destroy_write_struct(&png, &info); return 1;
}
static void pause_ms(int ms) {
    struct timespec t = {0, ms*1000000L}; nanosleep(&t, NULL);
}
int main(void) {
    int (*scope)(int) = dlsym(RTLD_DEFAULT, "faster_screenshot_scope");
    void (*reset)(void) = dlsym(RTLD_DEFAULT, "faster_screenshot_reset");
    double (*stat)(int,int,int) = dlsym(RTLD_DEFAULT, "faster_screenshot_stat");
    int (*begin)(int) = dlsym(RTLD_DEFAULT, "faster_screenshot_swap_begin");
    void (*end)(void) = dlsym(RTLD_DEFAULT, "faster_screenshot_swap_end");
    double (*swap_stat)(int,int) = dlsym(RTLD_DEFAULT, "faster_screenshot_swap_stat");
    assert(scope && reset && stat && begin && end && swap_stat);
    unsigned char pixels[8*8*3], expected[8*8*3];
    glReadPixels(3,5,8,8,GL_RGB,GL_UNSIGNED_BYTE,expected);
    output baseline = {0}, measured = {0}, failed = {.fail=1}, recovered = {0};
    assert(encode(expected, &baseline));
    assert(stat(3,0,0) == 0 && stat(3,1,0) == 0);
    scope(3);
    glReadPixels(3,5,8,8,GL_RGB,GL_UNSIGNED_BYTE,pixels);
    assert(!memcmp(expected,pixels,sizeof pixels));
    assert(encode(pixels, &measured));
    assert(measured.size == baseline.size && !memcmp(measured.bytes,baseline.bytes,baseline.size));
    assert(stat(3,0,0) == 1 && stat(3,0,1) == 1 && stat(3,0,6) == 64);
    assert(stat(3,1,0) == 1 && stat(3,1,1) == 1); /* No nested png_write_image double count. */
    assert(stat(3,1,2) >= 0 && stat(3,1,3) >= 0);
    assert(!encode(pixels, &failed));
    assert(stat(3,1,0) == 2 && stat(3,1,1) == 1);
    scope(0); scope(3);
    assert(encode(pixels, &recovered));
    assert(stat(3,1,0) == 3 && stat(3,1,1) == 2);
    assert(recovered.size == baseline.size && !memcmp(recovered.bytes,baseline.bytes,baseline.size));
    scope(0);
    reset();
    assert(begin(1)); pause_ms(5);
    SDL_GL_SwapWindow((SDL_Window *)0x1234); pause_ms(8);
    SDL_GL_SwapWindow((SDL_Window *)0x1234); pause_ms(11);
    end();
    assert(swap_stat(1,0) == 2 && swap_stat(1,1) == 1 && swap_stat(1,6) == 3);
    assert(swap_stat(1,2) >= 24 && swap_stat(1,4) >= 11);
    assert(swap_stat(1,10) >= 5 && swap_stat(1,11) >= 11);
    assert(swap_stat(1,5) >= 0 && swap_stat(1,3) >= 0);
    assert(stat(3,0,0) == 0 && stat(3,1,0) == 0); /* Swap-only path. */
    assert(begin(2)); pause_ms(3);
    double snapshot_ms = swap_stat(2,2);
    assert(swap_stat(2,0) == 0 && swap_stat(2,6) == 1 && snapshot_ms >= 3);
    end();
    assert(swap_stat(2,0) == 0 && swap_stat(2,6) == 1 && swap_stat(2,2) >= snapshot_ms);
    assert(probe_fixture_reads() == 2 && probe_fixture_swaps() == 2);
    puts("PASS: GL passthrough, identical PNG bytes, nested PNG exclusion, PNG failure recovery,");
    puts("      swap-only isolation, first/middle/tail gaps, zero-swap scope, live snapshot.");
    return 0;
}
#endif
