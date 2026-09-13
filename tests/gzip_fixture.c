/* GPL-3.0-or-later. Test-only native entry points. The two included files are
 * extracted verbatim from the pinned engine by test_gzip.lua at build time. */
#include <stdlib.h>
#include <string.h>
#include <lua.h>
#include <lauxlib.h>
#include <zlib.h>
#include "pinned_lzlib.c"
#include "pinned_core_compress.c"

static int core_calls, compress_calls, decompress_calls, mode;
static int marker = LUA_NOREF;

static int counted_core(lua_State *L)
{
    core_calls++;
    return lua_zlib_compress(L);
}

static int counted_compress(lua_State *L)
{
    compress_calls++;
    if (lua_gettop(L) != 6 || lua_tointeger(L, 2) != 9 ||
        lua_tointeger(L, 3) != 8 || lua_tointeger(L, 4) != 31 ||
        lua_tointeger(L, 5) != 8 || lua_tointeger(L, 6) != 0)
        return luaL_error(L, "gzip compression parameters changed");
    switch (mode) {
    case 1: lua_pushliteral(L, "partial"); lua_pushinteger(L, 0); return 2;
    case 2: lua_pushnil(L); lua_pushinteger(L, -2); return 2;
    case 3: lua_pushinteger(L, 42); lua_pushinteger(L, 1); return 2;
    case 4: lua_pushliteral(L, "partial"); return 1;
    case 5: lua_pushliteral(L, "partial"); lua_pushliteral(L, "1"); return 2;
    case 6: lua_rawgeti(L, LUA_REGISTRYINDEX, marker); return lua_error(L);
    case 7: lua_pushliteral(L, "not gzip"); lua_pushinteger(L, 1); return 2;
    case 8: return 0;
    }
    return lzlib_compress(L);
}

static int counted_decompress(lua_State *L)
{
    decompress_calls++;
    if (mode == 9) { lua_pushliteral(L, "wrong data"); lua_pushinteger(L, 1); return 2; }
    if (mode == 10) {
        lzlib_decompress(L); lua_pop(L, 1); lua_pushinteger(L, 0); return 2;
    }
    if (mode == 11) { lua_rawgeti(L, LUA_REGISTRYINDEX, marker); return lua_error(L); }
    return lzlib_decompress(L);
}

static int register_zlib(lua_State *L)
{
    /* Reproduce the upstream module initialization, including its metadata
     * table being discarded separately from the published zlib table. */
    lua_pushliteral(L, "zlib");
    luaopen_zlib(L);
    lua_getglobal(L, "zlib");
    return 1;
}

static int set_mode(lua_State *L)
{
    mode = luaL_checkint(L, 1);
    if (marker != LUA_NOREF) luaL_unref(L, LUA_REGISTRYINDEX, marker);
    lua_pushvalue(L, 2);
    marker = luaL_ref(L, LUA_REGISTRYINDEX);
    return 0;
}

static int stats(lua_State *L)
{
    lua_pushinteger(L, core_calls);
    lua_pushinteger(L, compress_calls);
    lua_pushinteger(L, decompress_calls);
    return 3;
}

static int reset(lua_State *L)
{
    core_calls = compress_calls = decompress_calls = mode = 0;
    return 0;
}

int luaopen_gzip_fixture(lua_State *L)
{
    static const luaL_Reg methods[] = {
        {"core", counted_core}, {"compress", counted_compress},
        {"decompress", counted_decompress}, {"raw_compress", lzlib_compress},
        {"raw_decompress", lzlib_decompress}, {"set_mode", set_mode},
        {"stats", stats}, {"reset", reset}, {"register_zlib", register_zlib}, {NULL, NULL}
    };
    lua_newtable(L);
    luaL_register(L, NULL, methods);
    return 1;
}
