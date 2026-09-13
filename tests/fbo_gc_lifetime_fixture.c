/* GPL-3.0-or-later. Test-only resource counters; no native addon dependency. */
#include <stdio.h>
#include <stdlib.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

typedef struct { int id; int freed; } Object;
static int created, freed, duplicate, binding, collect_on_destroy;
static int destroy(lua_State *L) {
    Object *p = luaL_checkudata(L, 1, "gl{fbo}");
    if (p->freed) { duplicate++; return luaL_error(L, "double destruction"); }
    p->freed = 1; freed++; binding = 0;
    if (collect_on_destroy) { collect_on_destroy = 0; lua_gc(L, LUA_GCCOLLECT, 0); }
    return 0;
}
static int use(lua_State *L) {
    Object *p = luaL_checkudata(L, 1, "gl{fbo}");
    if (p->freed) return luaL_error(L, "use after destruction");
    binding = lua_toboolean(L, 2) ? p->id : 0;
    if (!lua_toboolean(L, 2) && lua_isuserdata(L, 3))
        binding = ((Object *)luaL_checkudata(L, 3, "gl{fbo}"))->id;
    return 0;
}
static int make(lua_State *L) {
    Object *p = lua_newuserdata(L, sizeof(*p));
    p->id = ++created; p->freed = 0;
    luaL_getmetatable(L, "gl{fbo}"); lua_setmetatable(L, -2);
    return 1;
}
static int get_binding(lua_State *L) { lua_pushnumber(L, binding); return 1; }
static int get_freed(lua_State *L) { lua_pushnumber(L, freed); return 1; }
static int arm_collect(lua_State *L) { collect_on_destroy = 1; return 0; }
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    lua_State *L = luaL_newstate(); luaL_openlibs(L);
    luaL_newmetatable(L, "gl{fbo}");
    lua_pushcfunction(L, destroy); lua_setfield(L, -2, "__gc");
    lua_newtable(L); lua_pushcfunction(L, use); lua_setfield(L, -2, "use");
    lua_setfield(L, -2, "__index"); lua_pop(L, 1);
    lua_register(L, "make_fbo", make);
    lua_register(L, "get_binding", get_binding);
    lua_register(L, "get_freed", get_freed);
    lua_register(L, "arm_collect", arm_collect);
    if (luaL_dofile(L, argv[1])) { fprintf(stderr, "%s\n", lua_tostring(L, -1)); return 1; }
    lua_close(L);
    printf("{\"created\":%d,\"destroyed\":%d,\"double_destruction\":%d,\"passed\":%s}\n",
        created, freed, duplicate, created == freed && !duplicate ? "true" : "false");
    return created != freed || duplicate;
}
