-- GPL-3.0-or-later. Added 2026-09-12; see COPYING.
-- Execute pinned engine methods and actual addon installers in isolated worlds.
assert(_VERSION == "Lua 5.1", "Lua 5.1 / LuaJIT required")
local root = arg[1] or "."
local repo = assert(arg[2], "pass a local ToME source Git clone as argument 2")
local commit = "624a67329fe2ad440c5b344785a9c73fcf22ae63"
local function quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
local function pinned(path)
    local p = assert(io.popen("git -C " .. quote(repo) .. " show " .. quote(commit .. ":" .. path), "r"))
    local source = p:read("*a"); assert(p:close()); assert(#source > 0)
    return source
end
local function environment(t) return setmetatable(t or {}, {__index = _G}) end
local function run(source, name, env)
    return setfenv(assert(loadstring(source, name)), env)()
end
local function section(source, first, last)
    local a = assert(source:find(first, 1, true))
    local b = assert(source:find(last, a, true))
    local _, lines = source:sub(1, a - 1):gsub("\n", "")
    return string.rep("\n", lines) .. source:sub(a, b - 1)
end
local checks = 0
local function check(ok, message) assert(ok, message); checks = checks + 1 end
local function addon() return assert(loadfile(root .. "/overload/engine/FasterSave.lua"))() end
local gameSource = pinned("game/engines/default/engine/Game.lua")
local tomeSource = pinned("game/modules/tome/class/Game.lua")
local saveSource = pinned("game/engines/default/engine/Savefile.lua")
local classSource = pinned("game/engines/default/engine/class.lua")

local function gameWorld(optimized)
    local Game = {TICK_RESCHEDULE = {}}
    local env = environment{_M = Game, config = {settings = {}}, core = {game = {requestNextTick = function() end}}}
    run(section(gameSource, "function _M:onTickEndExecute()", "--- Called when a zone leaves"), "@/engine/Game.lua", env)
    run(section(tomeSource, "function _M:onSavefilePushed(", "--- Saves the highscore"), "@/mod/class/Game.lua", env)
    if optimized then check(addon().installGame(Game), "install on real pinned Game") end
    local game = setmetatable({saves = {}, state = 0}, {__index = Game})
    function game:saveGame() self.saves[#self.saves + 1] = self.state end
    return game, env, Game
end

for _, optimized in ipairs{false, true} do
    local g = gameWorld(optimized)
    g:onSavefilePushed("character", "level")
    g:onTickEnd(function() g.state = 42 end)
    g:onSavefilePushed("character", "zone")
    g:onTickEndExecute()
    check(#g.saves == (optimized and 1 or 2), "merge only redundant main saves")
    check(g.saves[#g.saves] == 42, "save remains AFTER interleaved state mutation")
end
do
    local g, env = gameWorld(true)
    for _, kind in ipairs{"game", "world", "entity"} do g:onSavefilePushed("char", kind) end
    check(not g.on_tick_end, "no extra main save for other archive types")
    env.config.settings.cheat = true
    g:onSavefilePushed("char", "level"); check(not g.on_tick_end, "debug behavior preserved")
    env.config.settings.cheat = false
    g:saveGame(); check(#g.saves == 1, "explicit manual save untouched")
    g:onSavefilePushed("char", "level"); g:onTickEndCancelAll()
    g:onSavefilePushed("char", "zone"); g:onTickEndExecute()
    check(#g.saves == 2, "cancellation does not suppress later saves")
    g:onTickEnd(function() g:onSavefilePushed("char", "zone") end)
    g:onSavefilePushed("char", "level")
    g:onTickEndExecute(); check(#g.saves == 3, "next batch request cannot cancel current batch save")
    g:onTickEndExecute(); check(#g.saves == 4, "next batch still saves")
    local captured = {}
    g:onTickEndCapture(captured)
    g:onSavefilePushed("char", "level"); g:onSavefilePushed("char", "zone")
    g:onTickEndCapture(nil); g:onTickEndMerge(captured); g:onTickEndExecute()
    check(#g.saves == 5, "captured callback queue preserves coalescing when merged")
    local previous = g.saveGame
    g.saveGame = function() error("save failed") end
    g:onSavefilePushed("char", "level")
    check(not pcall(g.onTickEndExecute, g), "save errors propagate")
    g.saveGame = previous
    g:onSavefilePushed("char", "level"); g:onTickEndExecute()
    check(#g.saves == 6, "failed save does not leave a permanent pending flag")
end
do
    local _, _, Game = gameWorld(false)
    local method = Game.onSavefilePushed
    check(not addon().installGame(Game, {save_coalescing = false}) and Game.onSavefilePushed == method, "save opt-out leaves method intact")
    local wrapped = function() return "third party" end
    Game.onSavefilePushed = wrapped
    check(not addon().installGame(Game) and Game.onSavefilePushed == wrapped, "unknown game override retained")
end
print("PASS pinned save scheduler: last request ordering, cancellation, capture, next batch, debug and errors")

local function loadWorld(optimized, files)
    local Savefile, Class = {}, {}
    local world = {events = {}, warnings = 0, head_moves = 0, head_inserts = 0}
    local objectClass = {loaded = function(o) world.events[#world.events + 1] = o.id end}
    local Dialog = {simpleWaiter = function() return {done = function() end} end,
        simplePopup = function() world.warnings = world.warnings + 1 end}
    local fs = {
        open = function(path)
            local value = files[path]
            if value == nil then return end
            local read = false
            return {read = function()
                if read then return end
                read = true
                if value == "IO_ERROR" then error("read failed") end
                return value
            end, close = function() end}
        end,
        getRealPath = function() return "archive" end, mount = function() end, umount = function() end,
    }
    local function requireStub(name)
        if name == "engine.class" then return Class end
        if name == "engine.ui.Dialog" then return Dialog end
        if name == "TestObject" then return objectClass end
        error("unexpected require " .. name)
    end
    local env = environment{_M = Savefile, class = Class, module = function() end, require = requireStub,
        fs = fs, print = function() end, _t = function(s) return s end,
        util = {steamCanCloud = function() return false end, send_error_backtrace = function() end},
        game = {onTickEnd = function(_, f) f() end},
        core = {wait = {manualTick = function() end, enableManualTick = function() end},
            display = {forceRedraw = function() end}},
        table = setmetatable({insert = function(t, at, value)
            if at == 1 and value then
                world.head_moves = world.head_moves + #t; world.head_inserts = world.head_inserts + 1
            end
            return table.insert(t, at, value)
        end}, {__index = table}),
    }
    run(saveSource, "@/engine/Savefile.lua", env)
    local classEnv = environment{_M = Class, engine = {Savefile = Savefile}, require = requireStub}
    run(section(classSource, "_M.LOAD_SELF = {}", "--- \"Reloads\""), "@/engine/class.lua", classEnv)
    Class.load = classEnv.load
    local save = setmetatable({}, {__index = Savefile})
    save:init("test"); save.load_dir = ""
    save.md5Check = function() return function() return true end end
    for _, name in ipairs{"World", "Game", "Zone", "Level", "Entity"} do
        save["nameLoad" .. name] = function() return "archive" end
    end
    if optimized then check(addon().installSavefile(Savefile), "install on actual preloaded Savefile") end
    world.save, world.class, world.objectClass, world.env = save, Savefile, objectClass, env
    return world
end
local function object(id, expression)
    return "local o={__CLASSNAME='TestObject',id='" .. id .. "'}; setLoaded('" .. id .. "',o); " .. (expression or "") .. " return o"
end
local function order(queue)
    local ids = {}; for i, o in ipairs(queue) do ids[i] = o.id or "warning" end
    return table.concat(ids, ",")
end
local files = {
    main = object("main", "o.children={loadObject('a'),loadObject('b')}; o.self=loadObject('main');"),
    a = object("a", "o.child=loadObject('c');"), b = object("b"), c = object("c"), extra = object("extra"),
}
for _, optimized in ipairs{false, true} do
    local w = loadWorld(optimized, files); local s = w.save; local queue = s.delayLoad
    s:addDelayLoad({id = "old", loaded = function() end})
    local loaded = s:loadReal("main")
    check(loaded.self == loaded and loaded.children[1].child.id == "c", "real class.load restores graph and self references")
    check(s.delayLoad == queue and order(queue) == "main,b,a,c,old", "same public array and exact reverse registration order")
    check(#w.events == 0, "loaded callbacks are still delayed")
    check(s:loadReal("main") == loaded and #queue == 5, "cached root adds no duplicate callbacks")
    check(s:loadReal("absent") == nil and #queue == 5, "missing entry returns nil unchanged")
    s:loadReal("extra"); check(order(queue) == "extra,main,b,a,c,old", "separate roots prepend to existing queue")
    s:addDelayLoad({id = "outside"}); check(queue[1].id == "outside", "external registration remains immediate")
end
for _, method in ipairs{"loadWorld", "loadGame", "loadZone", "loadLevel", "loadEntity"} do
    local w = loadWorld(true, files)
    local result, delayed = w.save[method](w.save, {}, {})
    check(result.id == "main", method .. " returns original root")
    if method == "loadGame" then
        check(#w.events == 0 and type(delayed) == "function", "loadGame retains deferred callback closure")
        delayed()
    end
    check(table.concat(w.events, ",") == "main,b,a,c", method .. " consumes callbacks in original order")
end
for _, optimized in ipairs{false, true} do
    local w = loadWorld(optimized, {main = "loadObject('a'); error('broken archive')", a = object("a")})
    check(w.save:loadReal("main") == nil, "parse error retains upstream nil result")
    check(order(w.save.delayLoad) == "warning,a", "warning is ordered before completed child")
    for _, o in ipairs(w.save.delayLoad) do o:loaded() end
    check(w.warnings == 1 and w.events[1] == "a", "upstream warning callback survives")
end
do
    local w = loadWorld(true, {main = object("main", "o.child=loadObject('a');"), a = object("a"), bad = "IO_ERROR"})
    check(not pcall(w.save.loadReal, w.save, "bad"), "uncaught IO errors propagate")
    w.save:loadReal("main")
    check(order(w.save.delayLoad) == "main,a", "batch cleaned after outer load failure")
    -- An immediate loaded callback can run while the graph is being parsed.
    local w2 = loadWorld(true, {main = object("main", "o.loadNoDelay=true;")})
    w2.save:loadReal("main")
    check(w2.events[1] == "main" and #w2.save.delayLoad == 0, "loadNoDelay stays immediate")
    local w3 = loadWorld(true, {main = object("main", "o.child=loadObject('a');"), a = object("a")})
    local ticks, failure = 0, {}
    w3.env.core.wait.manualTick = function()
        ticks = ticks + 1
        if ticks == 2 then error(failure) end
    end
    local ok, err = pcall(w3.save.loadReal, w3.save, "main")
    check(not ok and err == failure, "uncaught error object retains identity")
    check(order(w3.save.delayLoad) == "main,a", "partially buffered graph is materialized before error propagation")
end
do
    local w = loadWorld(false, files)
    local method = w.class.loadReal
    check(not addon().installSavefile(w.class, {load_queue = false}) and w.class.loadReal == method, "load opt-out leaves method intact")
    local custom = function() end
    w.class.addDelayLoad = custom
    check(not addon().installSavefile(w.class) and w.class.addDelayLoad == custom, "third party load override retained")
end
do
    local count, many, refs = 2000, {}, {}
    for i = 1, count do
        local id = "object" .. i
        many[id] = object(id); refs[i] = "loadObject('" .. id .. "')"
    end
    many.main = object("main", "o.children={" .. table.concat(refs, ",") .. "};")
    local original, optimized = loadWorld(false, many), loadWorld(true, many)
    original.save:loadReal("main"); optimized.save:loadReal("main")
    check(order(original.save.delayLoad) == order(optimized.save.delayLoad), "large real deserialized graph order parity")
    check(original.head_moves == count * (count + 1) / 2, "baseline quadratic element movement confirmed")
    check(optimized.head_inserts == 0 and #optimized.save.delayLoad == count + 1, "optimized graph uses no head insertions")
    print("PASS 2001 queued objects: baseline " .. original.head_moves .. " shifted elements; optimized zero head insertions")
end
do
    -- Test the actual startup paths, including Savefile already being required.
    local helper = addon()
    local w = loadWorld(false, files)
    local ring = {}
    setfenv(assert(loadfile(root .. "/overload/engine/CacheList.lua")), environment{
        _M = ring, class = {}, module = function() end,
    })()
    function ring.new(n) local r = setmetatable({}, {__index = ring}); r:init(n); return r end
    local env = environment{config = {settings = {}}, print = function() end, class = {bindHook = function() end},
        get_printlog = function() return {} end, truncate_printlog = function() end}
    env._G = env
    env.require = function(name)
        if name == "engine.FasterSave" then return helper end
        if name == "engine.FasterClone" then return assert(loadfile(root .. "/overload/engine/FasterClone.lua"))() end
        if name == "engine.Savefile" then return w.class end
        if name == "engine.CacheList" then return ring end
        if name == "engine.Particles" or name == "engine.Shader" then
            return {loaded = setfenv(function() end, env)}
        end
        error(name)
    end
    setfenv(assert(loadfile(root .. "/hooks/load.lua")), env)()
    w.save:loadReal("main")
    check(w.head_inserts == 0 and order(w.save.delayLoad) == "main,b,a,c", "hooks patch an already-cached Savefile class")
    local g, ge, Game = gameWorld(false)
    ge.require = env.require
    ge.loadPrevious = function() return Game end
    local result = setfenv(assert(loadfile(root .. "/superload/mod/class/Game.lua")), ge)()
    g:onSavefilePushed("char", "level"); g:onSavefilePushed("char", "zone"); g:onTickEndExecute()
    check(result == Game and #g.saves == 1, "actual Game superload installs save coalescing")
end
print("PASS all " .. checks .. " save/load checks; " .. _VERSION .. " / " .. (jit and jit.version or "no JIT"))
