/* GPL-3.0-or-later. Test the pinned native wait, redraw and web dispatch code.
 * test_wait_refresh.lua extracts these engine functions verbatim. SDL/GL and
 * worker entry points below are deterministic stubs; no window is created. */
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include <stdbool.h>
#include <stdio.h>
#include <math.h>
#include <string.h>

#define TRUE true
#define FALSE false
typedef unsigned int GLuint;
typedef float GLfloat;
typedef struct { int unused; } SDL_Window;
typedef struct { int w, h; } SDL_Surface;
typedef struct { int type; } SDL_Event;
#define SDL_QUIT 256
typedef enum { redraw_type_normal, redraw_type_user_screenshot,
    redraw_type_savefile_screenshot } redraw_type_t;
static SDL_Window fixture_window;
static SDL_Surface fixture_screen = {800, 600};
SDL_Window *window = &fixture_window;
SDL_Surface *screen = &fixture_screen;
float screen_zoom = 1;
int requested_fps = 30;
long draw_tick_skip = 0;
static lua_State *L;
static int current_game = LUA_NOREF;
static int anims_paused, cur_frame_tick, frame_tick_paused_time;
static GLuint mouse_drag_tex;
static int mousex, mousey, mouse_drag_w, mouse_drag_h;
static int fake_time = 10000;
static int redraws, swaps, pumps, textures_created, textures_deleted, copies;
static int frame_draws, particle_updates, web_updates, steam_updates, discord_updates;
static int os_inputs, os_ticks, queued_inputs, queued_ticks, inputs_dispatched, ticks_dispatched;
static int os_quits, queued_quits, filtered_quits;
static int web_code_ref = LUA_NOREF;
static int clock_step, quad_calls, quad_error_at, quad_error_ref = LUA_NOREF;
static int quad_callback_ref = LUA_NOREF;
static bool webcore;
static bool no_steam = TRUE;

#define GL_FLOAT 1
#define GL_TEXTURE_2D 2
#define GL_QUADS 3
#define GL_TEXTURE_WRAP_S 4
#define GL_TEXTURE_WRAP_T 5
#define GL_REPEAT 6
#define GL_TEXTURE_MIN_FILTER 7
#define GL_LINEAR 8
#define GL_RGBA 9
#define GL_UNSIGNED_BYTE 10
#define GL_COLOR_BUFFER_BIT 16
#define GL_DEPTH_BUFFER_BIT 32
#define glTexCoordPointer(...) ((void)0)
#define glColorPointer(...) ((void)0)
#define tglBindTexture(...) ((void)0)
#define glVertexPointer(...) ((void)0)
#define glTexParameteri(...) ((void)0)
#define glTexImage2D(...) ((void)0)
#define glCopyTexSubImage2D(...) (++copies)
#define glDrawArrays(...) (++frame_draws)
#define glClear(...) ((void)0)
#define glLoadIdentity(...) ((void)0)
static void glGenTextures(int n, GLuint *texture) { *texture = ++textures_created; }
static void glDeleteTextures(int n, GLuint *texture) { ++textures_deleted; }
static int SDL_GetTicks(void) { return fake_time; }
static void SDL_GL_SwapWindow(SDL_Window *unused) { ++swaps; }
/* Pumping makes OS events available; dispatch remains in the outer event loop. */
static int event_filter(void *userdata, SDL_Event *event);
static void SDL_PumpEvents(void) {
    ++pumps; queued_inputs += os_inputs; queued_ticks += os_ticks;
    os_inputs = os_ticks = 0;
    while (os_quits) {
        SDL_Event event = {SDL_QUIT}; --os_quits; ++filtered_quits;
        if (event_filter(NULL, &event)) ++queued_quits;
    }
}
static int docall(lua_State *state, int nargs, int nresults) {
    lua_call(state, nargs, nresults); return 0;
}
static void thread_particle_new_keyframes(int n) { ++particle_updates; }
static void te4_steam_callbacks(void) { ++steam_updates; }
void te4_discord_update(void) { ++discord_updates; }
static void redraw_now(redraw_type_t type);
#define printf(...) ((void)0)
#include "pinned_event_filter.c"
#include "pinned_wait.c"
#include "pinned_web_external.h"
static void dispatch_web(void (*callback)(WebEvent *event)) {
    ++web_updates;
    if (web_code_ref == LUA_NOREF) return;
    int ref = web_code_ref;
    web_code_ref = LUA_NOREF;
    lua_rawgeti(L, LUA_REGISTRYINDEX, ref);
    WebEvent event;
    memset(&event, 0, sizeof(event));
    event.kind = TE4_WEB_EVENT_RUN_LUA;
    event.data.run_lua.code = lua_tostring(L, -1);
    callback(&event);
    lua_pop(L, 1);
    luaL_unref(L, LUA_REGISTRYINDEX, ref);
}
static void (*te4_web_do_update)(void (*callback)(WebEvent *event)) = dispatch_web;
#include "pinned_web_dispatch.c"
#define STEAM_TE4
#define DISCORD_TE4
#include "pinned_redraw.c"
#undef printf
static void redraw_now(redraw_type_t type) {
    ++redraws;
    current_redraw_type = type;
    on_redraw();
}

static int fixture_force_redraw(lua_State *state) { redraw_now(redraw_type_normal); return 0; }
static int fixture_get_time(lua_State *state) {
    lua_pushinteger(state, fake_time); fake_time += clock_step; return 1;
}
static int fixture_draw_quad(lua_State *state) {
    int i;
    for (i = 1; i <= 8; ++i) luaL_checknumber(state, i);
    ++quad_calls;
    if (quad_callback_ref != LUA_NOREF) {
        int ref = quad_callback_ref; quad_callback_ref = LUA_NOREF;
        lua_rawgeti(state, LUA_REGISTRYINDEX, ref); luaL_unref(state, LUA_REGISTRYINDEX, ref);
        lua_call(state, 0, 0);
    }
    if (quad_error_at && quad_calls == quad_error_at) {
        lua_rawgeti(state, LUA_REGISTRYINDEX, quad_error_ref); return lua_error(state);
    }
    ++frame_draws;
    return 0;
}
static int fixture_clock_step(lua_State *state) { clock_step = luaL_checkint(state, 1); return 0; }
static void fixture_external_hook(lua_State *state, lua_Debug *ar) { }
static int fixture_set_external_hook(lua_State *state) {
    lua_sethook(state, fixture_external_hook, LUA_MASKCOUNT, 1000000000); return 0;
}
static int fixture_quad_error(lua_State *state) {
    quad_error_at = luaL_checkint(state, 1);
    if (quad_error_ref != LUA_NOREF) luaL_unref(state, LUA_REGISTRYINDEX, quad_error_ref);
    quad_error_ref = LUA_NOREF;
    if (quad_error_at) { lua_pushvalue(state, 2); quad_error_ref = luaL_ref(state, LUA_REGISTRYINDEX); }
    return 0;
}
static int fixture_on_quad(lua_State *state) {
    if (quad_callback_ref != LUA_NOREF) luaL_unref(state, LUA_REGISTRYINDEX, quad_callback_ref);
    quad_callback_ref = LUA_NOREF;
    if (lua_isfunction(state, 1)) {
        lua_pushvalue(state, 1); quad_callback_ref = luaL_ref(state, LUA_REGISTRYINDEX);
    }
    return 0;
}
static int fixture_advance(lua_State *state) { fake_time += luaL_checkint(state, 1); return 0; }
static int fixture_queue_events(lua_State *state) {
    os_inputs += luaL_checkint(state, 1); os_ticks += luaL_checkint(state, 2); return 0;
}
static int fixture_queue_quit(lua_State *state) { ++os_quits; return 0; }
static int fixture_pump_events(lua_State *state) { SDL_PumpEvents(); return 0; }
static void dispatch_game_event(const char *method) {
    lua_rawgeti(L, LUA_REGISTRYINDEX, current_game);
    lua_getfield(L, -1, method); lua_pushvalue(L, -2); lua_remove(L, -3);
    lua_call(L, 1, 0);
}
static int fixture_dispatch_events(lua_State *state) {
    while (queued_inputs) { --queued_inputs; ++inputs_dispatched; dispatch_game_event("input"); }
    while (queued_ticks) { --queued_ticks; ++ticks_dispatched; dispatch_game_event("tick"); }
    return 0;
}
static int fixture_set_game(lua_State *state) {
    if (current_game != LUA_NOREF) luaL_unref(state, LUA_REGISTRYINDEX, current_game);
    lua_pushvalue(state, 1); current_game = luaL_ref(state, LUA_REGISTRYINDEX); return 0;
}
static int fixture_web(lua_State *state) {
    webcore = lua_toboolean(state, 1);
    if (web_code_ref != LUA_NOREF) luaL_unref(state, LUA_REGISTRYINDEX, web_code_ref);
    web_code_ref = LUA_NOREF;
    if (lua_isstring(state, 2)) {
        lua_pushvalue(state, 2); web_code_ref = luaL_ref(state, LUA_REGISTRYINDEX);
    }
    return 0;
}
#define FIELD(name, value) lua_pushinteger(state, value); lua_setfield(state, -2, name)
static int fixture_stats(lua_State *state) {
    lua_newtable(state);
    FIELD("waiting", waiting); FIELD("manual", manual_ticks_enabled);
    FIELD("hook_mask", lua_gethookmask(state)); FIELD("hook_count", lua_gethookcount(state));
    FIELD("own_hook", lua_gethook(state) == hook_wait_display);
    FIELD("remembered_hook", wait_hooked); FIELD("draw_ref", wait_draw_ref);
    FIELD("texture", bkg_t); FIELD("redraws", redraws); FIELD("swaps", swaps);
    FIELD("pumps", pumps); FIELD("textures_created", textures_created);
    FIELD("textures_deleted", textures_deleted); FIELD("copies", copies);
    FIELD("frame_draws", frame_draws); FIELD("particles", particle_updates);
    FIELD("quads", quad_calls);
    FIELD("web", web_updates); FIELD("steam", steam_updates); FIELD("discord", discord_updates);
    FIELD("queued_inputs", queued_inputs); FIELD("queued_ticks", queued_ticks);
    FIELD("inputs", inputs_dispatched); FIELD("ticks", ticks_dispatched);
    FIELD("os_quits", os_quits); FIELD("queued_quits", queued_quits); FIELD("filtered_quits", filtered_quits);
    FIELD("time", fake_time); FIELD("animation_time", cur_frame_tick);
    return 1;
}
static int fixture_reset(lua_State *state) {
    if (waiting || bkg_t || lua_gethookmask(state))
        return luaL_error(state, "clean up wait and debug hook before fixture reset");
    /* Test isolation only. Native disable leaves these values behind. */
    wait_draw_ref = LUA_NOREF;
    wait_hooked = 0; manual_ticks_enabled = FALSE;
    waited_count = waited_count_max = 0; waited_ticks = 0;
    redraws = swaps = pumps = textures_created = textures_deleted = copies = 0;
    frame_draws = particle_updates = web_updates = steam_updates = discord_updates = 0;
    os_inputs = os_ticks = queued_inputs = queued_ticks = inputs_dispatched = ticks_dispatched = 0;
    os_quits = queued_quits = filtered_quits = 0;
    fake_time += 10000;
    clock_step = quad_calls = quad_error_at = 0;
    if (quad_error_ref != LUA_NOREF) luaL_unref(state, LUA_REGISTRYINDEX, quad_error_ref);
    quad_error_ref = LUA_NOREF;
    if (quad_callback_ref != LUA_NOREF) luaL_unref(state, LUA_REGISTRYINDEX, quad_callback_ref);
    quad_callback_ref = LUA_NOREF;
    webcore = FALSE;
    if (web_code_ref != LUA_NOREF) luaL_unref(state, LUA_REGISTRYINDEX, web_code_ref);
    web_code_ref = LUA_NOREF;
    return 0;
}
static int fixture_core(lua_State *state) {
    lua_newtable(state);
    lua_newtable(state); luaL_register(state, NULL, mainlib); lua_setfield(state, -2, "wait");
    lua_newtable(state);
    lua_pushcfunction(state, fixture_force_redraw); lua_setfield(state, -2, "forceRedraw");
    lua_pushcfunction(state, fixture_draw_quad); lua_setfield(state, -2, "drawQuad");
    lua_setfield(state, -2, "display");
    lua_newtable(state);
    lua_pushcfunction(state, fixture_get_time); lua_setfield(state, -2, "getTime");
    lua_setfield(state, -2, "game");
    return 1;
}
int luaopen_wait_refresh_fixture(lua_State *state) {
    L = state;
    static const luaL_Reg methods[] = {
        {"forceRedraw", fixture_force_redraw}, {"advance", fixture_advance},
        {"queueEvents", fixture_queue_events}, {"dispatchEvents", fixture_dispatch_events},
        {"queueQuit", fixture_queue_quit}, {"pumpEvents", fixture_pump_events},
        {"setGame", fixture_set_game}, {"web", fixture_web},
        {"core", fixture_core}, {"clockStep", fixture_clock_step}, {"quadError", fixture_quad_error},
        {"onQuad", fixture_on_quad},
        {"externalHook", fixture_set_external_hook},
        {"stats", fixture_stats}, {"reset", fixture_reset}, {NULL, NULL}
    };
    lua_newtable(state); luaL_register(state, NULL, methods);
    lua_newtable(state); luaL_register(state, NULL, mainlib); lua_setfield(state, -2, "wait");
    return 1;
}
