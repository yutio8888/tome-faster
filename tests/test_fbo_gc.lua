-- GPL-3.0-or-later. Actual pinned FBO bindings in an EGL context, plus
-- independent Lua-state lifetime fixtures. No game saves or network access.
local root, repo = arg[1] or ".", assert(arg[2], "pass the engine Git clone")
local commit = "624a67329fe2ad440c5b344785a9c73fcf22ae63"
local function quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
local function output(command)
    local p = assert(io.popen(command, "r")); local s = p:read("*a"); assert(p:close()); return s
end
local function pinned(path) return output("git -C " .. quote(repo) .. " show " .. quote(commit .. ":" .. path)) end
local function write(path, s) local f = assert(io.open(path, "wb")); assert(f:write(s)); assert(f:close()) end
local function section(s, first, last)
    local a = assert(s:find(first, 1, true)); local b = last and assert(s:find(last, a, true)) or #s + 1
    return s:sub(a, b - 1)
end
local function command(s) local ok = os.execute(s); assert(ok == 0 or ok == true, s) end
local checks = 0
local function check(ok, why) assert(ok, why); checks = checks + 1 end
local build = output("mktemp -d /tmp/tome-fbo-gc-tests.XXXXXX"):gsub("\n$", "")
assert(build:match("^/tmp/tome%-fbo%-gc%-tests%.[%w]+$"))
local function main()
    local source = pinned("src/core_lua.c")
    for _, file in ipairs({"tgl.h", "core_lua.h", "auxiliar.c"}) do
        write(build .. "/pinned_" .. file, pinned("src/" .. file))
    end
    write(build .. "/tgl.h", pinned("src/tgl.h"))
    write(build .. "/auxiliar.h", pinned("src/auxiliar.h"))
    write(build .. "/pinned_fbo.c", section(source, "static int gl_new_fbo(lua_State *L)", "static int gl_fbo_posteffects(lua_State *L)"))
    write(build .. "/pinned_texture.c", section(source, "static int sdl_free_texture(lua_State *L)", "static int sdl_texture_toscreen_highlight_hex(lua_State *L)"))
    write(build .. "/pinned_vertex.c", section(source, "static void update_vertex_size(lua_vertexes *vx, int size)", "static int gl_counts_draws(lua_State *L)"))
    local headers = os.getenv("TOME_LUA_INCLUDE")
    local flags = headers and ("-I" .. quote(headers)) or output("if pkg-config --exists luajit; then pkg-config --cflags luajit; else pkg-config --cflags lua5.1; fi")
    command(quote(os.getenv("CC") or "cc") .. " -shared -fPIC -O2 " .. flags:gsub("\n", " ") ..
        " -I" .. quote(build) .. " " .. quote(root .. "/tests/effect_mask_fixture.c") ..
        " -o " .. quote(build .. "/fixture.so") .. " -lEGL -lGL")
    local native = assert(package.loadlib(build .. "/fixture.so", "luaopen_effect_mask_fixture"))()
    print("FBO GC renderer: " .. native.init())
    local ffi = require "ffi"
    ffi.cdef[[unsigned char glIsFramebuffer(unsigned int framebuffer);]]
    local gl = ffi.load("GL")
    local Guard = assert(loadfile(root .. "/overload/engine/FBOGCGuard.lua"))()
    local mt = debug.getregistry()["gl{fbo}"]
    local use = mt.__index.use
    mt.__index.use = function() end
    check(Guard.install() == nil, "unknown Lua use override is left intact")
    mt.__index.use = use
    local no_debug = setfenv(assert(loadfile(root .. "/overload/engine/FBOGCGuard.lua")),
        setmetatable({debug = false}, {__index = _G}))()
    check(no_debug.install() == nil, "missing runtime capability falls back")

    -- Verify that the unmodified native finalizer really reproduces the bug.
    local outer, inner, doomed = native.newFBO(8,8), native.newFBO(4,4), native.newFBO(4,4)
    outer:use(true, 0.25, 0.5, 0.75, 1)
    local original = native.pixels(outer)
    check(native.state().fbo ~= 0, "outer FBO bound")
    doomed = nil; collectgarbage("collect"); collectgarbage("collect")
    check(native.state().fbo == 0, "pinned native finalizer leaves FBO 0 bound")
    outer:use(false)

    local guard = assert(Guard.install())
    check(Guard.install() == guard, "installation is idempotent")
    local wrapped_use, wrapped_gc = mt.__index.use, mt.__gc
    check(Guard.originalUse(mt, wrapped_use) == use, "owned wrapper exposes its native identity for compatibility checks")
    check(Guard.originalUse(mt, use) == nil, "native delegate is not mistaken for the live wrapper")
    mt.__index.use = function(...) return wrapped_use(...) end
    check(Guard.originalUse(mt, mt.__index.use) == nil, "unknown later use wrapper is not authorized")
    mt.__index.use = wrapped_use
    mt.__gc = function(...) return wrapped_gc(...) end
    check(Guard.originalUse(mt, wrapped_use) == nil, "unknown later finalizer invalidates the bridge")
    mt.__gc = wrapped_gc
    mt.__fbo_gc_guard_v1 = {}
    check(Guard.originalUse(mt, wrapped_use) == nil, "a registry marker alone cannot authorize a wrapper")
    mt.__fbo_gc_guard_v1 = guard
    check(Guard.originalUse(mt, wrapped_use) == use, "restoring both owned callbacks and marker restores compatibility")
    doomed = native.newFBO(4,4)
    doomed:use(true); local doomed_id = native.state().fbo; doomed:use(false)
    outer:use(true, 0.25, 0.5, 0.75, 1)
    local before = native.state()
    doomed = nil; collectgarbage("collect"); collectgarbage("collect")
    check(native.state().fbo == before.fbo, "GC preserves current actual binding")
    check(native.pixels(outer) == original, "GC preserves every target pixel")
    check(gl.glIsFramebuffer(doomed_id) ~= 0, "native resource remains until next bind")
    check(guard.pending_count() == 1, "one queued resource")
    inner:use(true, 1, 0, 0, 1)
    check(gl.glIsFramebuffer(doomed_id) == 0, "next normal bind releases native resource")
    check(guard.pending_count() == 0, "queue drained")
    inner:use(false, outer)
    local after = native.state()
    for _, key in ipairs({"fbo", "model", "projection", "viewport", "mode"}) do
        check(after[key] == before[key], "nested use restores " .. key)
    end
    check(native.pixels(outer) == original, "nested use preserves target pixels")
    outer:use(false)
    local batch = {}
    for i = 1, 64 do batch[i] = native.newFBO(4,4) end
    outer:use(true)
    batch = nil; collectgarbage("collect"); collectgarbage("collect")
    check(guard.pending_count() == 64, "batch survives multiple GC cycles")
    check(native.state().fbo == before.fbo, "batch collection preserves drawing target")
    outer:use(false)
    check(guard.pending_count() == 0 and guard.released == 65, "each queued native FBO released once")
    collectgarbage("collect")
    check(guard.released == 65 and native.state().error == 0, "no duplicate native destruction or GL error")

    -- Execute the real hook block with explicit configuration and capture its
    -- installer calls, independently of the unrelated cache/save hooks.
    local hook_file = assert(io.open(root .. "/hooks/load.lua")); local hook_source = hook_file:read("*a"); hook_file:close()
    local hook = section(hook_source, "-- The 1.7.6 native FBO finalizer", "-- DLC weights")
    for _, enabled in ipairs({false, true}) do
        local calls = 0
        local env = setmetatable({config = {settings = {faster_tome = {fbo_gc_guard = enabled}}},
            print = function() end, require = function(name)
                assert(name == "engine.FBOGCGuard")
                return {install = function() calls = calls + 1; return {} end}
            end}, {__index = _G})
        setfenv(assert(loadstring(hook)), env)()
        check(calls == (enabled and 1 or 0), "hook respects fbo_gc_guard option")
    end

    -- Separate Lua states exercise actual lua_close and object resurrection.
    -- Their C resource model deliberately reproduces the destructive binding.
    local libs = output("if pkg-config --exists luajit; then pkg-config --cflags --libs luajit; else pkg-config --cflags --libs lua5.1; fi")
    command(quote(os.getenv("CC") or "cc") .. " -O2 " .. quote(root .. "/tests/fbo_gc_lifetime_fixture.c") ..
        " " .. libs:gsub("\n", " ") .. " -lm -ldl -o " .. quote(build .. "/lifetime"))
    for _, name in ipairs({"lifetime", "reentrant"}) do
        local result = output("cd " .. quote(root) .. " && " .. quote(build .. "/lifetime") .. " " .. quote("tests/fbo_gc_" .. name .. ".lua"))
        check(result:find('"passed":true', 1, true) ~= nil, name .. " host released every resource once")
        print("FBO GC " .. name .. ": " .. result:gsub("\n$", ""))
    end
    print("PASS FBO GC guard: " .. checks .. " checks")
end
local ok, err = xpcall(main, debug.traceback)
os.execute("rm -rf " .. quote(build))
if not ok then error(err) end
