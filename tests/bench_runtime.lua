-- GPL-3.0-or-later; added 2026-09-12. Synthetic CPU timing, NOT FPS.
assert(_VERSION == "Lua 5.1" and jit, "LuaJIT required")
local root, repo = arg[1] or ".", assert(arg[2], "engine clone required")
local function quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
local function pinned(path)
    local p = assert(io.popen("git -C " .. quote(repo) .. " show 624a67329fe2ad440c5b344785a9c73fcf22ae63:" .. quote(path)))
    local s = p:read("*a"); assert(p:close()); return s
end
local function section(s, first, last)
    local a = assert(s:find(first, 1, true)); local b = assert(s:find(last, a, true))
    local _, lines = s:sub(1, a - 1):gsub("\n", "")
    return string.rep("\n", lines) .. s:sub(a, b - 1)
end
local function run(s, name, e) return setfenv(assert(loadstring(s, name)), e)() end
local mapSource = pinned("game/engines/default/engine/Map.lua")
local actorSource = pinned("game/modules/tome/class/Actor.lua")
local function map(optimized)
    local methods = {}
    local e = setmetatable({_M = methods}, {__index = _G})
    run(section(mapSource, "TERRAIN = 1", "color_shown"), "@/engine/Map.lua", e)
    run(section(mapSource, "function _M:updateMap(x, y)", "--- Sets/gets a value from the map"), "@/engine/Map.lua", e)
    if optimized then assert(assert(loadfile(root .. "/overload/engine/FasterRuntime.lua"))().installMap(methods)) end
    local empty = function() end
    local entity = {check = empty}
    local m = setmetatable({w = 1, h = 1, map = {[0] = {[1] = entity, [100] = entity, [1000] = entity}},
        _check_entities = {}, _check_entities_store = {}, updateMapDisplay = empty,
        _map = {setGrid = empty, setImportant = empty}, _fovcache = {
            block_sight = {set = empty}, block_esp = {set = empty}, block_sense = {set = empty},
        }}, {__index = methods})
    function m:checkAllEntities(x, y, what, ...) return self._check_entities[0](self, x, y, what, ...) end
    return function() m:updateMap(0, 0) end
end
local function visibility(optimized)
    local methods = {}
    run(section(actorSource, "function _M:canSee(actor, def, def_pct)", "--- Reset our own seeing cache"),
        "@/mod/class/Actor.lua", setmetatable({_M = methods}, {__index = _G}))
    local old = methods.canSee
    if optimized then
        -- A measured prototype only: it is deliberately not installed by addon.
        methods.canSee = function(self, actor, def, pct)
            if actor and def == nil and pct == nil then
                local seen = self.can_see_cache and self.can_see_cache[actor]
                local cached = seen and seen["nil/nil"]
                if cached then return cached[1], cached[2] end
            end
            return old(self, actor, def, pct)
        end
    end
    local a = setmetatable({canSeeNoCache = function() return true, 100 end}, {__index = methods})
    local targets = {}; for i = 1, 32 do targets[i] = {}; a:canSee(targets[i]) end
    return function(i) local yes, chance = a:canSee(targets[i % 32 + 1]); return chance end
end
local function timed(f, n)
    local sum, started = 0, os.clock()
    for i = 1, n do sum = sum + (f(i) or 0) end
    return os.clock() - started, sum
end
for _, mode in ipairs{"jit", "interpreter"} do
    if mode == "interpreter" then jit.off(); jit.flush() end
    for _, item in ipairs{{"map-cached-layout", map, 150000}, {"canSee-default-hit-prototype", visibility, 1000000}} do
        local baseline, optimized = item[2](false), item[2](true)
        timed(baseline, 10000); timed(optimized, 10000)
        for repetition = 1, 3 do
            collectgarbage("collect"); local a, x = timed(baseline, item[3])
            collectgarbage("collect"); local b, y = timed(optimized, item[3])
            assert(x == y, "result checksum mismatch")
            print(mode, item[1], repetition, item[3], a, b, b / a)
        end
    end
end
