/* GPL-3.0-or-later. Compile the pinned serializer unchanged with an in-memory
 * sink instead of the SDL/ZIP worker. The serializer userdata and __gc are real. */
#include <lua.h>
#include <lauxlib.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <stdio.h>
#include <setjmp.h>
typedef void zipFile;
typedef struct {
    zipFile *zf; const char *zfname; char *buf; long bufpos, buflen;
    int fname, fadd, allow, disallow, disallow2;
} serial_type;
static char *last_zipname;
static zipFile *last_zf;
static lua_State *fixture_L;
static int entries_ref, names_ref, adds_ref;
static int created, freed, unique_names, unique_adds;
static int tracking = 1;
static int protocol_enabled, protocol_opens, protocol_closes, protocol_completions;
typedef struct save_queue {
    zipFile *zf; char *zfname, *filename, *payload; size_t payload_len;
    struct save_queue *next;
} save_queue;
static save_queue *protocol_head, *protocol_tail;
#define APPEND_STATUS_CREATE 0
#define TRUE true
#define FALSE false
static zipFile *zipOpen(const char *name, int mode) {
    if (protocol_enabled) ++protocol_opens;
    return (zipFile *)1;
}
static void auxiliar_setclass(lua_State *L, const char *name, int index) {
    luaL_getmetatable(L, name); lua_setmetatable(L, index < 0 ? index - 1 : index);
}
static void *auxiliar_checkclass(lua_State *L, const char *name, int index) {
    return luaL_checkudata(L, index, name);
}
static void push_save(zipFile *zf, const char *zip, const char *file, char *payload, size_t length) {
    if (protocol_enabled) {
        save_queue *q = calloc(1, sizeof(*q));
        q->zf = zf; q->zfname = strdup(zip); q->filename = strdup(file);
        q->payload = malloc(length); memcpy(q->payload, payload, length); q->payload_len = length;
        if (protocol_tail) protocol_tail->next = q; else protocol_head = q;
        protocol_tail = q;
    }
    lua_State *L = fixture_L;
    lua_rawgeti(L, LUA_REGISTRYINDEX, entries_ref);
    size_t n = lua_objlen(L, -1);
    lua_createtable(L, 0, 3);
    lua_pushstring(L, zip); lua_setfield(L, -2, "zip");
    lua_pushstring(L, file); lua_setfield(L, -2, "file");
    lua_pushlstring(L, payload, length); lua_setfield(L, -2, "data");
    lua_rawseti(L, -2, n + 1); lua_pop(L, 1);
    free(payload);
}
#include "pinned_serial.c"
/* Run the actual worker one semaphore wake at a time with deterministic queue
 * starvation. No OS thread or filesystem is needed to expose premature close. */
typedef struct { void *wait_iqueue; } fixture_save_type;
static fixture_save_type fixture_save, *main_save = &fixture_save;
static jmp_buf worker_done;
static int worker_waits;
static int SDL_SemWait(void *unused) { if (worker_waits++) longjmp(worker_done, 1); return 0; }
typedef struct {
    struct { int tm_sec, tm_min, tm_hour, tm_mday, tm_mon, tm_year; } tmz_date;
    unsigned long dosDate, internal_fa, external_fa;
} zip_fileinfo;
#define ZIP_OK 0
#define Z_DEFLATED 8
#define MAX_WBITS 15
#define DEF_MEM_LEVEL 8
#define Z_DEFAULT_STRATEGY 0
static int zipOpenNewFileInZip3(zipFile *zf, ...) { return ZIP_OK; }
static int zipWriteInFileInZip(zipFile *zf, ...) { return ZIP_OK; }
static int zipCloseFileInZip(zipFile *zf) { return ZIP_OK; }
static int zipClose(zipFile *zf, void *unused) { ++protocol_closes; return ZIP_OK; }
static void finish_zip(const char *name) { ++protocol_completions; }
static save_queue *pop_save(void) {
    save_queue *q = protocol_head;
    if (q) { protocol_head = q->next; if (!protocol_head) protocol_tail = NULL; }
    return q;
}
#define printf(...) ((void)0)
#include "pinned_worker.c"
#undef printf
static int fixture_worker(lua_State *L) {
    worker_waits = 0;
    if (setjmp(worker_done) == 0) thread_save(NULL);
    lua_pushnumber(L, protocol_opens); lua_pushnumber(L, protocol_closes);
    lua_pushnumber(L, protocol_completions); return 3;
}
static int fixture_protocol(lua_State *L) {
    protocol_enabled = lua_toboolean(L, 1);
    protocol_opens = protocol_closes = protocol_completions = 0;
    if (last_zipname) free(last_zipname);
    last_zipname = NULL; last_zf = NULL;
    return 0;
}
static void track(lua_State *L, int argument, int ref, int *count) {
    lua_rawgeti(L, LUA_REGISTRYINDEX, ref);
    lua_pushvalue(L, argument); lua_rawget(L, -2);
    if (lua_isnil(L, -1)) {
        ++*count; lua_pop(L, 1); lua_pushvalue(L, argument); lua_pushboolean(L, 1); lua_rawset(L, -3);
    } else lua_pop(L, 1);
    lua_pop(L, 1);
}
static int fixture_new(lua_State *L) {
    fixture_L = L;
    if (tracking) { track(L, 2, names_ref, &unique_names); track(L, 3, adds_ref, &unique_adds); }
    ++created; return serial_new(L);
}
static int fixture_free(lua_State *L) { ++freed; return serial_free(L); }
static int new_weak_keys(lua_State *L) {
    lua_newtable(L); lua_newtable(L); lua_pushliteral(L, "k"); lua_setfield(L, -2, "__mode");
    lua_setmetatable(L, -2); return luaL_ref(L, LUA_REGISTRYINDEX);
}
static int fixture_reset(lua_State *L) {
    if (entries_ref) luaL_unref(L, LUA_REGISTRYINDEX, entries_ref);
    if (names_ref) luaL_unref(L, LUA_REGISTRYINDEX, names_ref);
    if (adds_ref) luaL_unref(L, LUA_REGISTRYINDEX, adds_ref);
    lua_newtable(L); entries_ref = luaL_ref(L, LUA_REGISTRYINDEX);
    names_ref = new_weak_keys(L); adds_ref = new_weak_keys(L);
    created = freed = unique_names = unique_adds = 0;
    return 0;
}
static int fixture_entries(lua_State *L) { lua_rawgeti(L, LUA_REGISTRYINDEX, entries_ref); return 1; }
static int fixture_stats(lua_State *L) {
    lua_pushnumber(L, created); lua_pushnumber(L, freed);
    lua_pushnumber(L, unique_names); lua_pushnumber(L, unique_adds); return 4;
}
static int fixture_tracking(lua_State *L) { tracking = lua_toboolean(L, 1); return 0; }
int luaopen_serial_fixture(lua_State *L) {
    fixture_L = L;
    luaL_newmetatable(L, "core{serial}");
    lua_pushcfunction(L, fixture_free); lua_setfield(L, -2, "__gc");
    lua_pushcfunction(L, serial_tozip); lua_setfield(L, -2, "toZip");
    lua_pushvalue(L, -1); lua_setfield(L, -2, "__index"); lua_pop(L, 1);
    fixture_reset(L);
    lua_newtable(L);
    lua_pushcfunction(L, fixture_new); lua_setfield(L, -2, "new");
    lua_pushcfunction(L, fixture_reset); lua_setfield(L, -2, "reset");
    lua_pushcfunction(L, fixture_entries); lua_setfield(L, -2, "entries");
    lua_pushcfunction(L, fixture_stats); lua_setfield(L, -2, "stats");
    lua_pushcfunction(L, fixture_tracking); lua_setfield(L, -2, "tracking");
    lua_pushcfunction(L, fixture_worker); lua_setfield(L, -2, "worker");
    lua_pushcfunction(L, fixture_protocol); lua_setfield(L, -2, "protocol");
    return 1;
}
