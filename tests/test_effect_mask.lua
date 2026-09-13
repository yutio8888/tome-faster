-- GPL-3.0-or-later. Differential tests against fixed Lua and actual native GL
-- bindings, using a separate surfaceless EGL context (no game/save/network).
assert(_VERSION == "Lua 5.1", "Lua 5.1 / LuaJIT required")
local root, repo = arg[1] or ".", assert(arg[2], "pass fixed engine Git clone")
local commit = "624a67329fe2ad440c5b344785a9c73fcf22ae63"
local function quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
local function output(command)
    local p = assert(io.popen(command, "r")); local s = p:read("*a"); assert(p:close()); return s
end
local function pinned(path) return output("git -C " .. quote(repo) .. " show " .. quote(commit .. ":" .. path)) end
local function write(path, s) local f = assert(io.open(path, "wb")); assert(f:write(s)); assert(f:close()) end
local function section(s, first, last)
    local a = assert(s:find(first, 1, true)); local b = last and assert(s:find(last, a, true)) or #s + 1
    local _, lines = s:sub(1, a - 1):gsub("\n", "")
    return string.rep("\n", lines) .. s:sub(a, b - 1)
end
local function run(s, name, env) return setfenv(assert(loadstring(s, name)), env)() end
local checks = 0
local function check(ok, why) assert(ok, why); checks = checks + 1 end
local build = output("mktemp -d /tmp/tome-mask-tests.XXXXXX"):gsub("\n$", "")
assert(build:match("^/tmp/tome%-mask%-tests%.[%w]+$"))
local function main()
    local source = pinned("src/core_lua.c")
    write(build .. "/pinned_tgl.h", pinned("src/tgl.h"))
    write(build .. "/tgl.h", pinned("src/tgl.h"))
    write(build .. "/pinned_core_lua.h", pinned("src/core_lua.h"))
    write(build .. "/pinned_auxiliar.c", pinned("src/auxiliar.c"))
    write(build .. "/auxiliar.h", pinned("src/auxiliar.h"))
    write(build .. "/pinned_fbo.c", section(source, "static int gl_new_fbo(lua_State *L)", "static int gl_fbo_posteffects(lua_State *L)"))
    write(build .. "/pinned_texture.c", section(source, "static int sdl_free_texture(lua_State *L)", "static int sdl_texture_toscreen_highlight_hex(lua_State *L)"))
    write(build .. "/pinned_vertex.c", section(source, "static void update_vertex_size(lua_vertexes *vx, int size)", "static int gl_counts_draws(lua_State *L)"))
    local headers = os.getenv("TOME_LUA_INCLUDE")
    local cflags = headers and ("-I" .. quote(headers)) or output("if pkg-config --exists luajit; then pkg-config --cflags luajit; else pkg-config --cflags lua5.1; fi")
    local status = os.execute(quote(os.getenv("CC") or "cc") .. " -shared -fPIC -O2 " .. cflags:gsub("\n", " ") ..
        " -I" .. quote(build) .. " " .. quote(root .. "/tests/effect_mask_fixture.c") ..
        " -o " .. quote(build .. "/effect_mask_fixture.so") .. " -lEGL -lGL")
    assert(status == 0 or status == true, "native mask fixture requires C compiler, Lua 5.1, EGL and GL headers")
    local native = assert(package.loadlib(build .. "/effect_mask_fixture.so", "luaopen_effect_mask_fixture"))()
    print("EGL mask renderer: " .. native.init())
    local env = setmetatable({core = {display = native}}, {__index = _G})
    local Faster = setfenv(assert(loadfile(root .. "/overload/engine/FasterEffectMask.lua")), env)()
    local Tiles = {use_images = true}
    env._M = Tiles
    run(section(pinned("game/engines/default/engine/Tiles.lua"), "function _M:get(char", "function _M:clean()"), "@/engine/Tiles.lua", env)
    -- Real fixed class constructors, MapEffect.init and Entity.init. Ordinary
    -- game overlays are MapEffect instances, not unadorned fixture tables.
    -- engine.class's module adapter removes the _G __index but retains an
    -- empty terminal metatable on the class module itself.
    local classEnv = setmetatable({_M = setmetatable({}, {})}, {__index = _G})
    local classSource = pinned("game/engines/default/engine/class.lua")
    run(section(classSource, "function make(c)", "--- Inherit"), "@/engine/class.lua", classEnv)
    run(section(classSource, "local skip_key =", "function _M:importInterface"), "@/engine/class.lua", classEnv)
    local Entity, MapEffect = {_NAME = "engine.Entity"}, {_NAME = "engine.MapEffect"}
    classEnv.make(Entity); classEnv.inherit(Entity)(MapEffect)
    local entityEnv = setmetatable({_M = Entity, __uids = {}, config = {settings = {}}}, {__index = env})
    local entityCode = section(pinned("game/engines/default/engine/Entity.lua"), "function _M:init(t, no_default)", "function _M:getName()")
    run(entityCode:gsub("\n", " local next_uid = 1\n", 1), "@/engine/Entity.lua", entityEnv)
    local overlayEnv = setmetatable({_M = MapEffect}, {__index = env})
    local overlayCode = section(pinned("game/engines/default/engine/MapEffect.lua"), "function _M:init(t, no_default)")
    setfenv(assert(loadstring(overlayCode:gsub("\n", " local Entity = ...\n", 1), "@/engine/MapEffect.lua")), overlayEnv)(Entity)
    env.package = {loaded = setmetatable({["engine.MapEffect"] = MapEffect}, {__index = package.loaded})}
    local function texture(seed)
        local pixels = {}
        for y = 0, 15 do for x = 0, 15 do
            pixels[#pixels + 1] = string.char((x * 17 + seed) % 256, (y * 17 + seed) % 256, ((x + y) * 9 + seed) % 256, (x * 13 + y * 19 + seed) % 256)
        end end
        return native.newTexture(16, 16, table.concat(pixels))
    end
    local tex, tex2 = texture(0), texture(17)
    local function world()
        local map = {mx = 0, my = 0, tile_w = 16, tile_h = 16, zoom = 1, display_x = 0, display_y = 0,
            viewport = {width = 64, height = 64, mwidth = 4, mheight = 4}, fbo = native.newFBO(64, 64),
            tilesEffects = setmetatable({repo = {mask = {[16777215] = {none = {tex}}}}}, {__index = Tiles})}
        local e = {seen_grids = {[0] = {[0] = true, [1] = 0}, [1] = {[0] = false, [1] = true}},
            overlay = MapEffect.new{image = "mask", color_r = 255, color_g = 255, color_b = 255, color_br = -1, color_bg = -1, color_bb = -1, zdepth = 1}}
        return map, e
    end
    local function original(map, e, s)
        for lx, ys in pairs(e.seen_grids) do for ly in pairs(ys) do
            s:toScreen((lx - map.mx) * map.tile_w * map.zoom, (ly - map.my) * map.tile_h * map.zoom, map.tile_w * map.zoom, map.tile_h * map.zoom)
        end end
    end
    local function draw(map, e, s, optimize)
        map.fbo:use(true, 0, 0, 0, 0)
        local batched = optimize and Faster.draw(map, e, s)
        if not batched then original(map, e, s) end
        map.fbo:use(false)
        return native.pixels(map.fbo), native.state(), batched
    end
    local function parity(map, e, s, expectBatch, why)
        local a, sa = draw(map, e, s, false)
        local b, sb, batched = draw(map, e, s, true)
        check(a == b, why .. ": full RGBA mask equality")
        for _, key in ipairs{"fbo", "mode", "unit", "texture", "blend", "error", "model", "projection", "clear", "color", "viewport"} do
            check(sa[key] == sb[key], why .. ": GL " .. key .. " equality")
        end
        check(sa.error == 0, why .. ": GL_NO_ERROR")
        check(batched == expectBatch, why .. ": expected batch/fallback")
    end
    local map, e = world()
    check(getmetatable(e.overlay).__index == MapEffect and e.overlay.__CLASSNAME == "engine.MapEffect", "actual MapEffect constructor inheritance fixture")
    check(type(getmetatable(classEnv._M)) == "table" and next(getmetatable(classEnv._M)) == nil, "engine class empty terminal metatable")
    parity(map, e, tex, true, "first mask")
    parity(map, e, tex, true, "repeated mask including false/zero grid values")
    check(Faster.stats().hits == 1 and Faster.stats().misses == 1, "stable ordered geometry hit")
    for _, zoom in ipairs{0.1, 0.6, 1, 1.01, 1.75, 4} do
        for _, scroll in ipairs{-1.7, -0.01, 0, 0.01, 0.3333, 1.6} do
            map.zoom, map.mx, map.my = zoom, scroll, -scroll
            parity(map, e, tex, true, "fractional zoom/scroll " .. zoom .. "/" .. scroll)
        end
    end
    map.zoom, map.mx, map.my = 1, 0, 0
    e.seen_grids = {[0] = {[0] = true, [0.2] = true, [0.3] = false}, [0.1] = {[0] = true, [0.2] = true}, [1] = {[1] = 0}}
    parity(map, e, tex, true, "ordered partially transparent overlapping primitives")
    native.blend(false)
    parity(map, e, tex, true, "inherited blend disabled")
    native.blend(true)
    parity(map, e, tex2, true, "replacement texture")
    e.seen_grids[0][0.2] = nil
    parity(map, e, tex2, true, "in place FOV removal")
    e.seen_grids[0][2.6] = true
    parity(map, e, tex2, true, "in place FOV insertion")
    e.overlay.alpha = 0.25
    parity(map, e, tex2, true, "overlay parameter invalidation")
    map.tile_w, map.tile_h = 8.1, 12.7
    parity(map, e, tex2, true, "independent tile integer truncation")
    map.fbo = native.newFBO(64, 64)
    parity(map, e, tex2, true, "FBO resource replacement")
    map.tilesEffects.repo = {}
    parity(map, e, tex2, true, "Tiles generation replacement")
    local get = map.tilesEffects.get
    map.tilesEffects.get = function() return tex end
    parity(map, e, tex2, false, "unknown Tiles:get")
    map.tilesEffects.get = get
    setmetatable(e.seen_grids, {})
    parity(map, e, tex2, false, "unknown grid metatable")
    setmetatable(e.seen_grids, nil)
    e.seen_grids = {[0] = {[0] = true}}
    parity(map, e, tex2, false, "single tile avoids batching overhead")
    e.seen_grids = {[0] = {[0] = true, [1] = true}}
    parity(map, e, tex2, true, "stable two tile cache")
    local newvo = native.newVO
    native.newVO = native.unavailable
    parity(map, e, tex2, false, "late native C allocator replacement")
    native.newVO = newvo
    local textureMethods = getmetatable(tex2).__index
    local drawTexture = textureMethods.toScreen
    textureMethods.toScreen = native.unavailable
    parity(map, e, tex2, false, "late native C texture draw replacement")
    textureMethods.toScreen = drawTexture
    local voMethods = debug.getregistry()["gl{vertexes}"].__index
    local drawVO = voMethods.toScreen
    voMethods.toScreen = native.unavailable
    parity(map, e, tex2, false, "late native C VO draw replacement on a hit")
    voMethods.toScreen = drawVO
    e.overlay.image = map
    parity(map, e, tex2, false, "overlay value referring back to map")
    e.overlay.image = "mask"
    local overlayMT = getmetatable(e.overlay)
    setmetatable(e.overlay, {__index = function() error("unknown overlay callback") end})
    check(Faster.draw(map, e, tex2) == false, "unknown overlay callback bypasses without invoking it")
    setmetatable(e.overlay, overlayMT)
    local classMT = getmetatable(MapEffect)
    setmetatable(MapEffect, {__index = function() error("unknown inherited callback") end})
    check(Faster.draw(map, e, tex2) == false, "unknown MapEffect class inheritance bypasses")
    setmetatable(MapEffect, classMT)
    setmetatable(e, {})
    parity(map, e, tex2, false, "unknown effect metatable")
    setmetatable(e, nil)
    local proxy = newproxy(true)
    getmetatable(proxy).__index = function() error("unexpected userdata index") end
    check(Faster.draw(map, e, proxy) == false, "unknown userdata rejected without indexing metamethod")
    e.seen_grids = {[0] = {}}
    for i = 1, 4097 do e.seen_grids[0][i] = true end
    check(Faster.draw(map, e, tex2) == false, "oversized geometry takes original path")
    Faster.clear(); Faster.resetStats()
    local owners = {}
    for i = 1, 40 do
        local m, effect = world(); owners[i] = {m, effect}
        effect.seen_grids = {}
        for x = 0, 31 do effect.seen_grids[x] = {}; for y = 0, 31 do effect.seen_grids[x][y] = true end end
        draw(m, effect, tex, true)
        local stats = Faster.stats()
        check(stats.entries <= stats.max_entries and stats.native_bytes <= stats.max_native_bytes, "global entry and native byte budgets")
    end
    local before = Faster.stats().entries
    Faster.clear(owners[40][1])
    check(Faster.stats().entries == before - 1, "map-specific invalidation")
    Faster.clear()
    check(Faster.stats().entries == 0 and Faster.stats().native_bytes == 0, "all cached resources released")
    local weak = setmetatable({}, {__mode = "v"})
    do
        local m, effect = world()
        local target = m.fbo
        m.fbo = {map = m, use = function(_, ...) return target:use(...) end}
        m.tilesEffects.repo.map = m
        m.fbo:use(true, 0, 0, 0, 0); check(Faster.draw(m, effect, tex), "weak back-reference fixture batches"); m.fbo:use(false)
        weak[1], weak[2] = m, effect
    end
    collectgarbage("collect"); collectgarbage("collect")
    check(weak[1] == nil and weak[2] == nil, "cache owners do not retain map or effect/save graph")

    -- Entire pinned displayEffects function: mock only the final shader so
    -- native masks and every semantic call/animation can be compared together.
    local source = pinned("game/engines/default/engine/Map.lua")
    local function scenario(optimize, forceGC, customFBO)
        Faster.clear(); Faster.resetStats()
        local m, effect = world(); local events = {}
        local function record(...) local out = {}; for i = 1, select("#", ...) do out[i] = tostring(select(i, ...)) end; events[#events + 1] = table.concat(out, "|") end
        local Class, shaders = {}, {}
        function Tiles:loadImage(name)
            record("load", name)
            return {glTexture = function() return {bind = function(_, unit, extra) record("bind", name, unit, extra) end} end}
        end
        local shad = {use = function(_, on) record("shader", on) end, uniTileSize = function(_, w, h) record("tile", w, h) end, uniScrollOffset = function(_, x, y) record("scroll", x, y) end}
        local testenv = setmetatable({_M = Class, util = {boundWrap = function(n, lo, hi) return n > hi and lo or n end}}, {__index = env})
        -- Preserve exact line metadata while capturing the real Tiles upvalue.
        local code = section(source, "function _M:displayEffects(z", "--- Process the overlay effects")
        code = code:gsub("\n", " local Tiles = ...\n", 1)
        setfenv(assert(loadstring(code, "@/engine/Map.lua")), testenv)(Tiles)
        local delegate = Class.displayEffects
        if optimize then check(Faster.install(Class), "install exact pinned displayEffects") end
        local realfbo = m.fbo
        if customFBO then
            m.fbo = {use = function(_, active, ...)
                    record("custom-fbo", active)
                    if active then effect.seen_grids[2] = {[2] = true} end
                    return realfbo:use(active, ...)
                end,
                toScreen = function(_, ...) record("custom-composite"); return realfbo:toScreen(...) end}
        end
        m._map = {getScroll = function() record("getScroll"); return 0.3, -0.7 end}
        m.fbo_shader = {shad = shad}; m.z_effects = {[1] = {[effect] = true}, [2] = {}}
        effect.x, effect.y, effect.radius, effect.seen = 1, 1, 3, true
        effect.overlay.effect_shader = {"anim1", "anim2", max = 3}
        setmetatable(m, {__index = Class})
        local scene, sceneID, savedPrepare
        if forceGC then
            scene = native.newFBO(64, 64)
            scene:use(true); sceneID = native.state().fbo; scene:use(false)
            savedPrepare = Faster.prepare
            Faster.prepare = function(...)
                check(native.state().fbo == sceneID, "geometry preparation occurs before binding mask FBO")
                collectgarbage("collect"); collectgarbage("collect")
                check(native.state().fbo == 0, "pinned FBO finalizer really unbinds the active scene")
                return savedPrepare(...)
            end
        end
        local function orphanFBO() native.newFBO(2, 2) end
        for _, frames in ipairs{0, 1, 2, 0, 7, 1} do
            if forceGC then
                collectgarbage("stop")
                -- No retained userdata: force its actual gl_free_fbo during
                -- prepare while the scene is bound, before the mask is bound.
                orphanFBO()
                scene:use(true, 0, 0, 0, 0)
            end
            m:displayEffects(1, scene, frames)
            if forceGC then
                check(native.state().fbo == sceneID, "draw restores scene FBO despite preparation GC")
                scene:use(false)
            end
            shaders[#shaders + 1] = native.pixels(realfbo)
            record("animation", effect.overlay.effect_shader_tex.cnt, effect.overlay.effect_shader_tex.cur)
        end
        if forceGC then Faster.prepare = savedPrepare; collectgarbage("restart") end
        m:displayEffects(2, nil, 1)
        local off = {}; local old = Class.displayEffects
        check(not Faster.install(off), "unknown method not installed")
        check(not Faster.install({displayEffects = delegate}, {effect_mask_batch = false}), "disabled installation")
        check(Class.displayEffects == old, "unrelated install retains existing method")
        return table.concat(events, "\n"), table.concat(shaders), Faster.stats()
    end
    local a, ap = scenario(false)
    local b, bp, counts = scenario(true)
    check(a == b, "full function call order and dynamic shader/animation parity")
    check(ap == bp, "all successive animation masks RGBA equal")
    check(counts.hits == 5 and counts.misses == 1, "full renderer uses the batch cache")
    local gcCalls, gcPixels, gcCounts = scenario(true, true)
    check(a == gcCalls and ap == gcPixels and gcCounts.hits == 5, "forced native FBO GC during preparation preserves every mask and animation")
    local customCalls, customPixels = scenario(false, false, true)
    local customAfter, customAfterPixels, customCounts = scenario(true, false, true)
    check(customCalls == customAfter and customPixels == customAfterPixels and customCounts.draws == 0,
        "unknown custom FBO callbacks mutate grids in original order and bypass preparation")
    Faster.clear()
    print("PASS effect mask: " .. checks .. " checks; actual pinned native GL masks/state and ordered animation calls")
end
local ok, err = xpcall(main, debug.traceback)
os.execute("rm -rf " .. quote(build))
if not ok then error(err, 0) end
