-- Isolated Lua 5.1 / LuaJIT checks of the unmodified downloaded addon.
-- No game session, graphics context, or performance benchmark is simulated.
local addon = assert(arg[1], "addon source directory required")
local pinned = assert(arg[2], "pinned engine snapshot directory required")
local host_loadfile = loadfile
local function read(path)
    local f = assert(io.open(path, "rb"))
    local s = f:read("*a")
    f:close()
    return s
end
local function check(name, condition, detail)
    assert(condition, name .. ": unexpected result")
    print("REPRODUCED", name, detail)
end
local function environment(extra)
    return setmetatable(extra or {}, {__index = _G})
end

-- Syntax-only compilation: these calls do not run the addon hooks.
for _, name in ipairs({"init.lua", "hooks/load.lua", "overload/engine/CacheList.lua",
    "superload/engine/Map.lua", "superload/mod/dialogs/ShowChatLog.lua"}) do
    assert(host_loadfile(addon .. "/" .. name))
end
print("PASS", "all 5 addon files compile", _VERSION, jit.version)

-- Execute the actual ring implementation, stubbing only class registration.
local ring = {}
local ring_env = environment({_M = ring, class = {make = function() end},
    module = function() end})
setfenv(assert(host_loadfile(addon .. "/overload/engine/CacheList.lua")), ring_env)()
function ring.new(size)
    local obj = setmetatable({}, {__index = ring})
    obj:init(size)
    return obj
end
local q = ring.new(3)
for i = 1, 3 do q:offer(i) end
check("ring loses one capacity slot", table.concat(q:enumerate(), ",") == "2,3",
    "capacity=3, offer 1/2/3 -> [2,3]")
local _, oldest = q:peekOldest()
check("peekOldest returns wrong element", oldest == 3,
    "oldest=3, expected=2")
local large = ring.new(5000)
local input = {}
for i = 1, 5001 do input[i] = i end
large:append(input)
local out = large:enumerate()
check("production ring capacity", #out == 4999 and out[1] == 3 and out[#out] == 5001,
    "capacity=5000, append 1..5001 -> 4999 entries, oldest=3")

-- Use the pinned engine's real print-buffer functions with only stdout stubbed.
local pre = read(pinned .. "/game/loader/pre-init.lua")
local first = assert(pre:find("local printlog = {}", 1, true))
local last = assert(pre:find("local rngavg =", first, true))
local stdout_calls = 0
local world = environment({print = function() stdout_calls = stdout_calls + 1 end})
world._G = world
setfenv(assert(loadstring(pre:sub(first, last - 1), "@pinned-print-buffer")), world)()
local particles = {loaded = setfenv(function(self) return loadfile(self.file) end, world)}
local shader = {loaded = setfenv(function(self) return loadfile(self.file) end, world)}
local revision, disk_calls = 1, 0
world.loadfile = function(path)
    disk_calls = disk_calls + 1
    if path == "missing.lua" then return nil, "missing file" end
    return assert(loadstring("return " .. revision, "@" .. path))
end
world.require = function(name)
    if name == "engine.Particles" then return particles end
    if name == "engine.Shader" then return shader end
    if name == "engine.CacheList" then return ring end
    error("unexpected require: " .. name)
end
setfenv(assert(host_loadfile(addon .. "/hooks/load.lua")), world)()
world.print("a", 1)
world.print("b", 2)
check("stdout and log order preserved", stdout_calls == 2 and
    world.get_printlog()[1][1] == "a" and world.get_printlog()[2][2] == "2",
    "original print still called; argument formatting retained")
world.truncate_printlog(0)
check("truncate_printlog is disabled", #world.get_printlog() == 2,
    "truncate(0) leaves 2 log entries")

local f1 = assert(particles.loaded({file = "effect.lua"}))
revision = 2
local f2 = assert(particles.loaded({file = "effect.lua"}))
check("loadfile cache reuses compiled function", f1 == f2 and disk_calls == 1 and f2() == 1,
    "two requests, one underlying load; changed file still returns old revision")
local failed, message = shader.loaded({file = "missing.lua"})
check("cached loadfile failure remains an error", failed == nil and message == "missing file",
    "nil/error return preserved on this LuaJIT")

-- Map stub records delegation; no damage calculations are needed here.
local delegated = 0
local map = {particleEmitter = function() delegated = delegated + 1; return "emitter" end}
local map_env = environment({loadPrevious = function() return map end})
setfenv(assert(host_loadfile(addon .. "/superload/engine/Map.lua")), map_env)()
local warning = map:particleEmitter(1, 1, 1, "hit_warning", {})
local other = map:particleEmitter(1, 1, 1, "other_effect", {})
check("hit warning completely suppressed", warning == nil and other == "emitter" and delegated == 1,
    "hit_warning never reaches original particleEmitter; other effects do")

-- Actual addon and pinned setScroll bodies; font:draw is an instrumented stub.
local util_stub = {bound = function(i, lo, hi) return math.max(lo, math.min(i, hi)) end}
local chat = {}
local chat_env = environment({util = util_stub, loadPrevious = function() return chat end})
setfenv(assert(host_loadfile(addon .. "/superload/mod/dialogs/ShowChatLog.lua")), chat_env)()
local original_text = read(pinned .. "/game/modules/tome/dialogs/ShowChatLog.lua")
local start = assert(original_text:find("function _M:setScroll", 1, true))
local finish = assert(original_text:find("function _M:innerDisplay", start, true))
local original = {}
setfenv(assert(loadstring(original_text:sub(start, finish - 1), "@pinned-setScroll")),
    environment({_M = original, util = util_stub}))()
local function dialog(methods, width, font_id, text)
    local obj = {iw = width, scroll = nil, scrollbar = {max = 0},
        max = 1, max_display = 10, line_size = {}, lines = {{str = text}}, draws = 0}
    obj.font = {draw = function(_, str, w)
        obj.draws = obj.draws + 1
        return {{_tex = font_id .. ":" .. str, w = w, h = 12, _tex_w = w, _tex_h = 12}}
    end}
    return setmetatable(obj, {__index = methods})
end
collectgarbage("stop")
local a = dialog(chat, 300, "font-A", "same text")
a:setScroll(0)
local b = dialog(chat, 150, "font-B", "same text")
b:setScroll(0)
local baseline = dialog(original, 150, "font-B", "same text")
baseline:setScroll(0)
check("text cache ignores width and font", b.draws == 0 and b.dlist[1].d.w == 290 and
    b.dlist[1].d.t == "font-A:same text" and baseline.dlist[1].d.w == 140,
    "new dialog expects width=140/font-B; addon reuses width=290/font-A")
local c = dialog(chat, 200, "font-C", "weak cache text")
c:setScroll(0)
c.scroll = nil
c:setScroll(0)
assert(c.draws == 1)
collectgarbage("restart")
collectgarbage("collect")
c.scroll = nil
c:setScroll(0)
check("weak cache is lost after full GC", c.draws == 2,
    "same text needs font:draw again after full collection")
print("PASS", "all reproduction assertions matched; no game/FPS benchmark performed")
