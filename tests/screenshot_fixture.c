/* GPL-3.0-or-later. Test-only public GL/SDL stubs plus the exact pinned
 * screenshot and lzlib implementations. No live game or GL context. */
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <lua.h>
#include <lauxlib.h>
#include <SDL2/SDL.h>
#include <GL/gl.h>
#include <png.h>
#include <zlib.h>
#include "pinned_lzlib.c"

static SDL_Window *window = (SDL_Window *)0x1234;
static int window_width=1280, window_height=800, have_window=1;
static int framebuffer, pbo, row_length, skip_rows, skip_pixels, alignment=4, read_buffer=GL_BACK;
static int native_captures, redraws, reads, gets, packs, errors, compress_calls, compress_mode, crc_mode, color_offset;
static int last_x, last_y, last_w, last_h;
static int redraw_callback=LUA_NOREF, marker=LUA_NOREF;
static char gl_version[128]="4.5 Fixture desktop GL";
float gamma_correction=1.0f;
enum { redraw_type_normal, redraw_type_savefile_screenshot, redraw_type_user_screenshot };
static int redraw_type=redraw_type_normal;
static int get_current_redraw_type(void) { return redraw_type; }

SDL_Window *SDL_GL_GetCurrentWindow(void) { return have_window ? window : NULL; }
void SDL_GetWindowSize(SDL_Window *value, int *width, int *height) {
    (void)value; *width=window_width; *height=window_height;
}
const GLubyte *glGetString(GLenum name) {
    if (!have_window) return NULL;
    if (name != GL_VERSION) { errors++; return NULL; }
    return (const GLubyte *)gl_version;
}
void glGetIntegerv(GLenum name, GLint *out) {
    gets++;
    switch (name) {
    case 0x8CAA: *out=framebuffer; break;
    case 0x0C02: *out=read_buffer; break;
    case 0x88ED: *out=pbo; break;
    case 0x0D02: *out=row_length; break;
    case 0x0D03: *out=skip_rows; break;
    case 0x0D04: *out=skip_pixels; break;
    default: errors++; *out=0;
    }
}
void glPixelStorei(GLenum name, GLint value) {
    packs++; if (name == GL_PACK_ALIGNMENT) alignment=value; else errors++;
}
void glReadPixels(GLint x, GLint y, GLsizei width, GLsizei height,
                  GLenum format, GLenum type, GLvoid *data) {
    reads++; last_x=x; last_y=y; last_w=width; last_h=height;
    if (format != GL_RGB || type != GL_UNSIGNED_BYTE) { errors++; return; }
    unsigned char *out=data;
    for (int r=0; r<height; r++) for (int c=0; c<width; c++) for (int channel=0; channel<3; channel++)
        *out++=(unsigned char)(((x+c)*11+(y+r)*23+channel*83+color_offset)&255);
}
GLenum glGetError(void) { errors++; return GL_NO_ERROR; }

#include "pinned_screenshot.c"

static int capture(lua_State *L) { native_captures++; return sdl_get_png_screenshot(L); }
static int save_mode(lua_State *L) {
    lua_pushboolean(L,get_current_redraw_type() == redraw_type_savefile_screenshot); return 1;
}
static int counted_crc(lua_State *L) {
    if (crc_mode && lua_gettop(L) > 0 && lua_tonumber(L,1) != 0) { lua_pushnumber(L,0); return 1; }
    return lzlib_crc32(L);
}
static int redraw(lua_State *L) {
    redraws++;
    redraw_type=lua_toboolean(L,1) ? redraw_type_savefile_screenshot : redraw_type_user_screenshot;
    if (redraw_callback != LUA_NOREF) {
        lua_rawgeti(L,LUA_REGISTRYINDEX,redraw_callback); lua_call(L,0,0);
    }
    return 0;
}
static int counted_compress(lua_State *L) {
    compress_calls++;
    if (lua_gettop(L) != 6 || lua_tointeger(L,2) != 1 || lua_tointeger(L,3) != 8
        || lua_tointeger(L,4) != 15 || lua_tointeger(L,5) != 8 || lua_tointeger(L,6) != 0)
        return luaL_error(L,"unexpected PNG compression parameters");
    if (compress_mode == 1) { lua_pushliteral(L,"partial"); lua_pushinteger(L,0); return 2; }
    if (compress_mode == 2) { lua_rawgeti(L,LUA_REGISTRYINDEX,marker); return lua_error(L); }
    if (compress_mode == 3) { lua_pushinteger(L,123); lua_pushinteger(L,1); return 2; }
    return lzlib_compress(L);
}
static int setup(lua_State *L) {
    const char *key=luaL_checkstring(L,1);
    int value=lua_tointeger(L,2);
    if (!strcmp(key,"window_width")) window_width=value;
    else if (!strcmp(key,"window_id")) window=(SDL_Window *)(uintptr_t)value;
    else if (!strcmp(key,"window_height")) window_height=value;
    else if (!strcmp(key,"have_window")) have_window=value;
    else if (!strcmp(key,"framebuffer")) framebuffer=value;
    else if (!strcmp(key,"pbo")) pbo=value;
    else if (!strcmp(key,"row_length")) row_length=value;
    else if (!strcmp(key,"skip_rows")) skip_rows=value;
    else if (!strcmp(key,"skip_pixels")) skip_pixels=value;
    else if (!strcmp(key,"alignment")) alignment=value;
    else if (!strcmp(key,"read_buffer")) read_buffer=value;
    else if (!strcmp(key,"color_offset")) color_offset=value;
    else if (!strcmp(key,"compress_mode")) compress_mode=value;
    else if (!strcmp(key,"crc_mode")) crc_mode=value;
    else if (!strcmp(key,"gamma")) gamma_correction=luaL_checknumber(L,2);
    else if (!strcmp(key,"gl_version")) {
        const char *v=luaL_checkstring(L,2); snprintf(gl_version,sizeof gl_version,"%s",v);
    } else if (!strcmp(key,"redraw_callback") || !strcmp(key,"marker")) {
        int *ref=!strcmp(key,"marker") ? &marker : &redraw_callback;
        if (*ref != LUA_NOREF) luaL_unref(L,LUA_REGISTRYINDEX,*ref);
        if (lua_isnil(L,2)) *ref=LUA_NOREF;
        else { lua_pushvalue(L,2); *ref=luaL_ref(L,LUA_REGISTRYINDEX); }
    } else return luaL_error(L,"unknown fixture setting");
    return 0;
}
static void field(lua_State *L, const char *name, int value) {
    lua_pushinteger(L,value); lua_setfield(L,-2,name);
}
static int stats(lua_State *L) {
    lua_newtable(L);
    field(L,"captures",native_captures); field(L,"redraws",redraws); field(L,"reads",reads);
    field(L,"gets",gets); field(L,"packs",packs); field(L,"errors",errors);
    field(L,"compress_calls",compress_calls); field(L,"alignment",alignment);
    field(L,"x",last_x); field(L,"y",last_y); field(L,"w",last_w); field(L,"h",last_h);
    return 1;
}
static int reset(lua_State *L) {
    (void)L; window=(SDL_Window *)0x1234; window_width=1280; window_height=800; have_window=1;
    framebuffer=pbo=row_length=skip_rows=skip_pixels=color_offset=0;
    alignment=4; read_buffer=GL_BACK; gamma_correction=1;
    native_captures=redraws=reads=gets=packs=errors=compress_calls=compress_mode=crc_mode=0;
    strcpy(gl_version,"4.5 Fixture desktop GL"); redraw_type=redraw_type_normal;
    if (redraw_callback != LUA_NOREF) luaL_unref(L,LUA_REGISTRYINDEX,redraw_callback);
    redraw_callback=LUA_NOREF;
    return 0;
}
typedef struct { const unsigned char *data; size_t remaining; } input;
static void read_bytes(png_structp png, png_bytep bytes, png_size_t count) {
    input *in=png_get_io_ptr(png);
    if (count > in->remaining) png_error(png,"short PNG fixture");
    memcpy(bytes,in->data,count); in->data+=count; in->remaining-=count;
}
static int decode(lua_State *L) {
    input in; in.data=(const unsigned char *)luaL_checklstring(L,1,&in.remaining);
    png_structp png=png_create_read_struct(PNG_LIBPNG_VER_STRING,NULL,NULL,NULL);
    png_infop info=png_create_info_struct(png);
    if (!png || !info) return luaL_error(L,"libpng fixture allocation failed");
    if (setjmp(png_jmpbuf(png))) { png_destroy_read_struct(&png,&info,NULL); return luaL_error(L,"PNG decode failed"); }
    png_set_read_fn(png,&in,read_bytes);
    png_read_png(png,info,PNG_TRANSFORM_IDENTITY,NULL);
    png_uint_32 w,h; int depth,color,interlace,compression,filter;
    png_get_IHDR(png,info,&w,&h,&depth,&color,&interlace,&compression,&filter);
    png_bytepp rows=png_get_rows(png,info);
    luaL_Buffer result; luaL_buffinit(L,&result);
    for (unsigned int row=0; row<h; row++) luaL_addlstring(&result,(const char *)rows[row],png_get_rowbytes(png,info));
    luaL_pushresult(&result);
    lua_pushinteger(L,w); lua_pushinteger(L,h); lua_pushinteger(L,depth);
    lua_pushinteger(L,color); lua_pushinteger(L,interlace);
    png_destroy_read_struct(&png,&info,NULL); return 6;
}
static int register_zlib(lua_State *L) {
    lua_pushliteral(L,"zlib"); luaopen_zlib(L); lua_getglobal(L,"zlib"); return 1;
}
int luaopen_screenshot_fixture(lua_State *L) {
    static const luaL_Reg methods[]={
        {"capture",capture},{"redraw",redraw},{"save_mode",save_mode},{"compress",counted_compress},
        {"decompress",lzlib_decompress},{"crc32",counted_crc},{"register_zlib",register_zlib},
        {"setup",setup},{"stats",stats},{"reset",reset},{"decode",decode},{NULL,NULL}};
    lua_newtable(L); luaL_register(L,NULL,methods); return 1;
}
