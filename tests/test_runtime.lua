-- GPL-3.0-or-later; added 2026-09-12. See COPYING.
assert(_VERSION == "Lua 5.1", "Lua 5.1 / LuaJIT required")
local root, engineRoot, dlcRoot = arg[1] or ".", assert(arg[2], "engine clone required"), arg[3]
local commit = "624a67329fe2ad440c5b344785a9c73fcf22ae63"
local function quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
local function read(path) local f = assert(io.open(path, "rb")); local s = f:read("*a"); f:close(); return s end
local function pinned(path)
    local p = assert(io.popen("git -C " .. quote(engineRoot) .. " show " .. quote(commit .. ":" .. path)))
    local s = p:read("*a"); assert(p:close()); assert(#s > 0); return s
end
local function env(t) return setmetatable(t or {}, {__index = _G}) end
local function run(s, name, e) return setfenv(assert(loadstring(s, name)), e)() end
local function section(s, first, last)
    local a = assert(s:find(first, 1, true)); local b = assert(s:find(last, a, true))
    local _, n = s:sub(1, a - 1):gsub("\n", "")
    return string.rep("\n", n) .. s:sub(a, b - 1)
end
local checks = 0
local function check(ok, message) assert(ok, message); checks = checks + 1 end
local function helper(e) return setfenv(assert(loadfile(root .. "/overload/engine/FasterRuntime.lua")), e or env())() end
local function trace()
    local out = {}
    local function record(...)
        local values = {}
        for i = 1, select("#", ...) do
            local v = select(i, ...)
            values[i] = type(v) == "table" and tostring(v.id or v.uid or "table") or tostring(v)
        end
        out[#out + 1] = table.concat(values, "|")
    end
    return out, record
end
local mapSource = pinned("game/engines/default/engine/Map.lua")
local function mapWorld(optimized)
    local Map = {}
    local events, record = trace()
    local metrics = {concat = 0, sorts = 0, compile = 0}
    local e = env{_M = Map, table = setmetatable({
        concat = function(t, ...) metrics.concat = metrics.concat + 1; return table.concat(t, ...) end,
        sort = function(t, f) metrics.sorts = metrics.sorts + 1; return table.sort(t, f) end,
    }, {__index = table}), loadstring = function(s)
        metrics.compile = metrics.compile + 1; return loadstring(s)
    end}
    run(section(mapSource, "TERRAIN = 1", "color_shown"), "@/engine/Map.lua", e)
    run(section(mapSource, "function _M:updateMap(x, y)", "--- Sets/gets a value from the map"), "@/engine/Map.lua", e)
    if optimized then check(helper(e).installMap(Map), "install pinned Map update") end
    local map = setmetatable({w = 4, h = 4, map = {}, _check_entities = {}, _check_entities_store = {},
        path_strings = {}, path_strings_computed = {}, _map = {}, _fovcache = {path_caches = {}}},
        {__index = Map, __call = function(self, x, y, layer) return self.map[x + y * self.w][layer] end})
    for i = 0, 15 do map.map[i] = {} end
    map._map.setImportant = function(_, x, y, value) record("important", x, y, value) end
    map._map.setGrid = function(_, x, y, mos)
        local keys = {}; for k in pairs(mos) do keys[#keys + 1] = k end; table.sort(keys)
        record("grid", x, y, #keys)
        for _, k in ipairs(keys) do record("mo", k, mos[k]) end
    end
    for _, kind in ipairs{"block_sight", "block_esp", "block_sense"} do
        map._fovcache[kind] = {set = function(_, x, y, value) record(kind, x, y, value) end}
    end
    function map:checkAllEntities(x, y, what, ...) return self._check_entities[x + y * self.w](self, x, y, what, ...) end
    local function entity(id, response)
        return {id = id, _mo = id, knownBy = function() record("known", id); return true end,
            getMapObjects = function(_, tiles, mos, slot) record("objects", id, slot); mos[slot] = id end,
            setupMinimapInfo = function() record("minimap", id) end,
            getMapStackMO = function() record("stack", id); return "stack" end,
            check = function(self, what, x, y, ...)
                record("check", id, what, x, y, select("#", ...), ...)
                if self.onCheck then self:onCheck(what, x, y) end
                return response and response[what]
            end}
    end
    return {map = map, class = Map, events = events, metrics = metrics, entity = entity, env = e, record = record}
end
local function mapScenario(optimized)
    local w = mapWorld(optimized); local m = w.map
    m.map[5] = {[1] = w.entity("terrain"), [50] = w.entity("trap"), [100] = w.entity("actor", {block_esp = "blocked"}),
        [500] = w.entity("projectile"), [1000] = w.entity("object"), [9999] = w.entity("extra")}
    m.actor_player = {id = "player", canSee = function(_, actor) w.record("canSee", actor); return true end}
    m.object_stack_count = true
    m.path_strings = {"walk"}
    m._fovcache.path_caches.walk = {set = function(_, x, y, blocked) w.record("path", x, y, blocked) end}
    m:updateMap(1, 1); m:updateMap(1, 1)
    m._check_entities_store = {} -- Source cache must not retain compiled functions.
    m:updateMap(1, 1)
    m.map[5][100] = w.entity("replacement")
    m:updateMap(1, 1)
    m.map[5][100].onCheck = function(_, what)
        if what == "custom" then m.map[5][50] = nil end
    end
    m:checkAllEntities(1, 1, "custom", nil, "tail")
    m.updateMapDisplay = function(self, x, y, mos)
        w.record("custom-display", x, y); self.map[5][10000] = w.entity("added-by-display")
    end
    m:updateMap(1, 1); m:checkAllEntities(1, 1, "custom2")
    m:updateMap(0, 0); m:updateMap(-1, 0); m:updateMap(nil, 0)
    local sources = {}; for code in pairs(m._check_entities_store) do sources[#sources + 1] = code end; table.sort(sources)
    return table.concat(w.events, "\n"), table.concat(sources, "\n")
end
do
    local a, ac = mapScenario(false); local b, bc = mapScenario(true)
    check(a == b, "Map rendering, path/FOV checks, layer order, mutations and varargs parity")
    check(ac == bc, "generated checker source matches upstream byte for byte")
    local original, optimized = mapWorld(false), mapWorld(true)
    for _, w in ipairs{original, optimized} do
        w.map.updateMapDisplay = function() end
        w.map.map[0] = {[1] = w.entity("ground"), [100] = w.entity("actor"), [1000] = w.entity("object")}
        for i = 1, 2000 do w.map:updateMap(0, 0) end
    end
    check(original.metrics.concat == 2000 and optimized.metrics.concat == 1, "reuse checker syntax for repeated layer layout")
    check(original.metrics.sorts == optimized.metrics.sorts and original.metrics.compile == optimized.metrics.compile,
        "sorting and existing compiled-function cache preserved")
    print("PASS Map: 2000 repeated layouts; source builds 2000 -> 1, sorts and compilations unchanged")
    local unknown = function() end; local fake = {updateMap = unknown}
    check(not helper().installMap(fake) and fake.updateMap == unknown, "unknown Map override retained")
    local off = mapWorld(false); local previous = off.class.updateMap
    check(not helper().installMap(off.class, {map_checker_source = false}) and off.class.updateMap == previous, "Map opt-out")
    -- More unique layouts than the cache budget must still generate correct code.
    local w = mapWorld(true); w.map.updateMapDisplay = function() end
    for i = 1, 140 do
        w.map.map[0] = {[i + 20000] = w.entity("custom" .. i)}
        w.map:updateMap(0, 0)
        check(w.map:checkAllEntities(0, 0, "empty") == nil, "bounded source cache eviction preserves checker")
    end
end

if not dlcRoot or dlcRoot == "" then
    print("SKIP DLC fixtures: pass the DLC source parent directory as argument 3")
    print("PASS " .. checks .. " runtime checks (core only)")
    return
end
local function dlcSource(component, path, hash)
    local real = dlcRoot .. "/" .. component .. "/tome-" .. component .. "/" .. path
    local p = assert(io.popen("sha256sum -- " .. quote(real))); local output = p:read("*a"); assert(p:close())
    assert(output:sub(1, 64) == hash, "DLC source differs from reviewed fixture: " .. path)
    return read(real)
end
local ashes = dlcSource("ashes-urhrok", "data/talents/corruptions/heart-of-fire.lua", "9169ec6910a96af6ce469ef88c4b257165955f96ce7828c8508e2d36372a92b5")
local function talents(source, path, e)
    local definitions = {talents_def = {}}
    e.require = function(name)
        if name == "engine.Map" then return e.Map or e.engine.Map end
        error("unexpected DLC require " .. name)
    end
    e.newTalent = function(t)
        t.id = "T_" .. (t.short_name or t.name):upper():gsub("[ ']", "_")
        definitions.talents_def[t.id] = t
    end
    run(source, "@" .. path, e)
    return definitions
end
local function ashesScenario(optimized, roll)
    local events, record = trace(); local effects, visits, pending = {}, 0, {}
    local actors = {}
    local function actor(id, cursed)
        local tmp, defs = {}, {}
        for i = 1, 30 do tmp[i] = {power = i}; defs[i] = {subtype = {fire = i % 2 == 0}, status = "detrimental"} end
        effects[tmp] = true
        local a = {id = id, x = id, y = 1, tmp = tmp, tempeffect_def = defs, turn_procs = {}, EFF_CURSED_FLAMES = "curse", cursed = cursed}
        function a:hasEffect(effect) record("has", self.id, effect); return self.cursed end
        function a:setEffect(effect, duration, params) record("effect", self.id, effect, duration, params.heal, params.vim, params.src); self.cursed = true end
        actors[id] = a; return a
    end
    actor(1, true); actor(2, false); actor(3, true); actor(4, false).turn_procs.doombringer_burnt = true; actor(5, false)
    local e = env{engine = {Map = {ACTOR = 100}}, rng = {percent = function(n) record("rng", n, roll); return roll end},
        pairs = function(t)
            local iter, state, key = pairs(t)
            return function(s, k)
                local nk, v = iter(s, k); if nk and effects[t] then visits = visits + 1 end; return nk, v
            end, state, key
        end}
    local player = {id = "player", x = 0, y = 0, EFF_CURSED_FLAMES = "curse"}
    function player:project(tg, x, y, callback)
        record("project", tg.radius, x, y, tg.friendlyfire)
        for i = 1, 6 do record("projected", i); callback(i, 1) end
    end
    e.game = {level = {map = function(x, y) return actors[x] end}, onTickEnd = function(_, f) record("enqueue"); pending[#pending + 1] = f end}
    e.DamageType = {FIREBURN = "fireburn", FIRE = "fire", get = function(_, kind)
        return {projector = function(src, x, y, typ, damage) record("damage", kind, src, x, y, typ, damage); actors[x].dead = true end}
    end}
    local all = talents(ashes, "/data-ashes-urhrok/talents/corruptions/heart-of-fire.lua", e)
    local t = all.talents_def.T_INFERNO_NEXUS
    t.getHeal, t.getVim, t.getDam = function() return 2 end, function() return 3 end, function() return 17 end
    if optimized then check(helper().installTalents(all).inferno_nexus, "install inspected Ashes callback") end
    local result = t.callbackOnActBase(player, t)
    for _, f in ipairs(pending) do f() end
    record("return", result)
    return table.concat(events, "\n"), visits
end
for _, roll in ipairs{false, true} do
    local a, av = ashesScenario(false, roll); local b, bv = ashesScenario(true, roll)
    check(a == b, "Ashes RNG, projections, damage, turn procs, pending effects and return parity")
    check(bv == 0 and (not roll or av > 0), "unused effect scans eliminated")
    if roll then print("PASS Ashes: effect-entry visits " .. av .. " -> " .. bv .. "; full ordered event trace identical") end
end

check(not next(helper().installTalents({talents_def = {}})), "absent DLCs safely ignored")
do
    local all = talents(ashes, "/data-ashes-urhrok/talents/corruptions/heart-of-fire.lua", env{engine = {Map = {ACTOR = 100}}})
    local inferno = all.talents_def.T_INFERNO_NEXUS
    local previous = inferno.callbackOnActBase
    check(not next(helper().installTalents(all, {inferno_nexus = false})) and inferno.callbackOnActBase == previous, "Ashes opt-out")
    local wrapped = function() end
    inferno.callbackOnActBase = wrapped
    check(not next(helper().installTalents(all)) and inferno.callbackOnActBase == wrapped, "unknown DLC callback retained")
end
do
    -- Execute the real hook file with a preloaded Map and delayed DLC loader.
    local w = mapWorld(false)
    local originalMap = w.class.updateMap
    local runtime, definitions = helper(), {talents_def = {}}
    local callbacks = {}
    local e = env{config = {settings = {}}, class = {bindHook = function(_, name, f) callbacks[name] = f end},
        print = function() end, get_printlog = function() return {} end, truncate_printlog = function() end}
    e._G = e
    e.require = function(name)
        if name == "engine.FasterRuntime" then return runtime end
        if name == "engine.FasterEffectMask" then return {install=function() return true end} end
        if name == "engine.FasterSaveFollowup" then return {installClass=function() return true end} end
        if name == "engine.class" then return e.class end
        if name == "engine.Map" then return w.class end
        if name == "engine.interface.ActorTalents" then return definitions end
        if name == "engine.FasterSave" then return {installSavefile = function() return true end} end
        if name == "engine.Savefile" then return {} end
        if name == "engine.CacheList" then return {new = function() return {enumerate = function() return {} end, truncate = function() end} end} end
        if name == "engine.Particles" or name == "engine.Shader" then return {loaded = setfenv(function() end, e)} end
        error(name)
    end
    setfenv(assert(loadfile(root .. "/hooks/load.lua")), e)()
    check(w.class.updateMap == originalMap and callbacks["ToME:load"], "runtime work is deferred until ToME load hook")
    definitions = talents(ashes, "/data-ashes-urhrok/talents/corruptions/heart-of-fire.lua", env{engine = {Map = {ACTOR = 100}}})
    local previous = definitions.talents_def.T_INFERNO_NEXUS.callbackOnActBase
    callbacks["ToME:load"]()
    check(w.class.updateMap ~= originalMap, "late hook patches already-cached Map")
    check(definitions.talents_def.T_INFERNO_NEXUS.callbackOnActBase ~= previous, "late hook sees newly loaded DLC talents")
    local installedMap = w.class.updateMap
    check(runtime.installMap(w.class) and w.class.updateMap == installedMap, "Map installation is idempotent")
end
print("PASS all " .. checks .. " runtime checks; " .. _VERSION .. " / " .. (jit and jit.version or "no JIT"))
