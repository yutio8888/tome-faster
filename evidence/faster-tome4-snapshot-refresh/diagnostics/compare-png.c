/* GPL-3.0-or-later. Independent libpng comparison of local diagnostic images. */
#include <png.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv) {
    png_image a, b;
    memset(&a, 0, sizeof a); memset(&b, 0, sizeof b);
    a.version = b.version = PNG_IMAGE_VERSION;
    if (argc != 3) return 2;
    if (!png_image_begin_read_from_file(&a, argv[1]) ||
        !png_image_begin_read_from_file(&b, argv[2])) return 3;
    if (a.width != b.width || a.height != b.height || a.format != b.format ||
        a.width > 8192 || a.height > 8192) return 4;
    a.format = b.format = PNG_FORMAT_RGB;
    size_t size = PNG_IMAGE_SIZE(a);
    unsigned char *left = malloc(size), *right = malloc(size);
    if (!left || !right) return 5;
    if (!png_image_finish_read(&a, NULL, left, 0, NULL) ||
        !png_image_finish_read(&b, NULL, right, 0, NULL)) return 6;
    int equal = memcmp(left, right, size) == 0;
    printf("{\"width\":%u,\"height\":%u,\"rgb_bytes\":%zu,\"pixels_equal\":%s}\n",
        a.width, a.height, size, equal ? "true" : "false");
    free(left); free(right); png_image_free(&a); png_image_free(&b);
    return equal ? 0 : 1;
}
