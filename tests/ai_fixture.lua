-- GPL-3.0-or-later; added 2026-09-13. Pinned Lua methods, isolated map/native stubs.
local F = {}
local commit = "624a67329fe2ad440c5b344785a9c73fcf22ae63"
local function quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
local function env(t) return setmetatable(t or {}, {__index = _G}) end
function F.load(root, engineRoot)
    F.root = root
    local function pinned(path)
        local p = assert(io.popen("git -C " .. quote(engineRoot) .. " show " .. quote(commit .. ":" .. path)))
        local s = p:read("*a"); assert(p:close()); assert(#s > 0); return s
    end
    F.astar = pinned("game/engines/default/engine/Astar.lua")
    F.utils = pinned("game/engines/default/engine/utils.lua")
    F.simple = pinned("game/engines/default/engine/ai/simple.lua")
    F.actorAI = pinned("game/modules/tome/class/interface/ActorAI.lua")
end
function F.section(source, first, last)
    local lines, n = {}, 0
    for line in (source .. "\n"):gmatch("(.-)\n") do
        n = n + 1
        if n > last then break end
        lines[n] = n >= first and line or ""
    end
    return table.concat(lines, "\n") .. "\n"
end
function F.run(source, path, e) return setfenv(assert(loadstring(source, path)), e)() end
function F.helper() return assert(loadfile(F.root .. "/overload/engine/FasterAI.lua"))() end
function F.random(seed)
    return function(n) seed = seed * 48271 % 2147483647; return seed % n end
end
function F.path(path)
    if path == nil then return "nil" end
    local out = {}
    for i = 1, #path do out[i] = path[i].x .. "," .. path[i].y end
    return table.concat(out, ";")
end

function F.world(spec, optimized, traced, options)
    spec = spec or {}
    local w = {events = {}, metrics = {next = 0, checks = 0, paths = 0, expanded = 0}, spec = spec}
    function w.record(...)
        if not traced then return end
        local row = {}
        for i = 1, select("#", ...) do row[i] = tostring(select(i, ...)) end
        w.events[#w.events + 1] = table.concat(row, "|")
    end
    local tables = setmetatable({readonly = function(t) return t end}, {__index = table})
    local e = env{_M = {}, util = {}, table = tables, print = function(...) w.record("print", ...) end,
        module = function() end, class = {make = function() end}, config = {settings = {log_detail_ai = 0}}}
    e.core = {fov = {distance = function(x, y, tx, ty) return math.max(math.abs(x-tx), math.abs(y-ty)) end}}
    if traced then
        e.next = function(t, key) w.metrics.next = w.metrics.next + 1; return next(t, key) end
    end
    -- Include the actual direction tables and both square/hex adjacency code.
    F.run(F.section(F.utils, 2025, 2410), "@/engine/utils.lua", e)
    function w.setHex(value)
        for i = 1, 10 do
            local name = debug.getupvalue(e.util.isHex, i)
            if name == "is_hex" then debug.setupvalue(e.util.isHex, i, value and 1 or 0); return end
        end
        error("missing is_hex upvalue")
    end
    w.setHex(spec.hex)
    local Map = {TERRAIN = 1, ACTOR = 100}
    e.engine = {Map = Map}
    e.require = function(name)
        if name == "engine.class" then return e.class end
        if name == "engine.Map" then return Map end
        if name == "engine.Astar" then return w.Astar end
        error("unexpected require: " .. name)
    end
    F.run(F.astar, "@/engine/Astar.lua", e)
    w.Astar, w.env = e._M, e
    w.original = w.Astar.calc
    w.helper = F.helper()
    if optimized then assert(w.helper.installAstar(w.Astar, options)) end
    function w.Astar.new(map, actor)
        w.metrics.paths = w.metrics.paths + 1
        local a = setmetatable({}, {__index = w.Astar}); a:init(map, actor); return a
    end
    local originalDouble = w.Astar.toDouble
    if traced then
        w.Astar.toDouble = function(self, node)
            w.metrics.expanded = w.metrics.expanded + 1
            w.record("toDouble", node)
            return originalDouble(self, node)
        end
    end
    local n = spec.n or 16
    local map = {w = n, h = spec.h or n, walls = {}, _fovcache = {path_caches = {}}}
    w.map = map
    local random = F.random(spec.seed or 1)
    for y = 0, map.h - 1 do
        for x = 0, n - 1 do
            if spec.density then map.walls[x+y*n] = random(100) < spec.density end
            if spec.shape == "blocked" or spec.shape == "gap" then
                map.walls[x+y*n] = x == math.floor(n/2) and (spec.shape == "blocked" or y ~= map.h-2)
            end
        end
    end
    function map:isBound(x, y)
        w.record("bound", x, y); return x >= 0 and y >= 0 and x < self.w and y < self.h
    end
    map.has_seens = function(x, y) w.record("seen", x, y); return (x*3+y) % 4 == 0 end
    local function blocked(x, y) return map.walls[x+y*map.w] end
    if spec.cache ~= false then
        map._fovcache.path_caches.walk = {get = function(_, x, y) w.record("cache", x, y); return blocked(x, y) end}
    end
    function map:checkEntity(x, y, layer, what, actor, unused, fake)
        w.record("terrain", x, y, layer, what, actor == w.actor, unused, fake)
        return blocked(x, y)
    end
    local actor = {x = 1, y = 1, uid = 1, name = "fixture", ai_state = {}, energy = {}, sight = 10}
    w.actor = actor
    function actor:getPathString() w.record("pathString"); return "walk" end
    w.instance = w.Astar.new(map, actor)
    e.game = {level = {map = map}, turn = 1}
    if spec.heuristic then
        local roll = F.random(spec.seed or 1)
        local calls = 0
        w.heuristic = function(self, sx, sy, cx, cy, tx, ty)
            calls = calls + 1
            local value
            if spec.heuristic == "zero" then value = 0
            elseif spec.heuristic == "random" then value = roll(31) - 15
            elseif spec.heuristic == "nan" then
                value = calls == (spec.nan_at or 8) and 0/0 or 0
                if value ~= value then w.metrics.nan_next = w.metrics.next end
            elseif spec.heuristic == "infinity" then value = math.huge
            elseif spec.heuristic == "negative_infinity" then value = -math.huge
            elseif spec.heuristic == "sentinel" then value = 999999999999999
            else error("unknown heuristic") end
            w.record("heuristic", sx, sy, cx, cy, tx, ty, value)
            return value
        end
    end
    if spec.dynamic then
        local randomCheck = F.random((spec.seed or 1) + 193)
        w.add_check = function(x, y)
            w.metrics.checks = w.metrics.checks + 1
            local roll = randomCheck(100)
            w.record("add_check", x, y, roll)
            if w.metrics.checks == 8 then
                map.walls[math.floor(n/2)+2*n] = true
                map.walls[math.floor(n/2)+3*n] = false
                if spec.switch_hex then w.setHex(true) end
                if spec.switch_adjacent then
                    local previous = e.util.adjacentCoords
                    e.util.adjacentCoords = function(cx, cy, diagonal)
                        w.record("customAdjacent", cx, cy, diagonal)
                        return previous(cx, cy, diagonal)
                    end
                end
                if spec.reenter then
                    w.record("nested", F.path(w.instance:calc(0, 0, 2, 2)))
                end
            end
            return roll >= 12
        end
    end
    function w.query(sx, sy, tx, ty)
        return w.instance:calc(sx, sy, tx, ty, spec.use_seen, w.heuristic, w.add_check, spec.no_diagonals)
    end
    return w
end

return F
