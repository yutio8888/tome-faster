-- GPL-3.0-or-later. Pinned class/Savefile methods and actual C serialization.
assert(_VERSION == "Lua 5.1", "Lua 5.1 / LuaJIT required")
local root, repo = arg[1] or ".", assert(arg[2], "pass local engine Git clone")
local commit = "624a67329fe2ad440c5b344785a9c73fcf22ae63"
local function quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
local function output(command)
    local p = assert(io.popen(command)); local s = p:read("*a"); assert(p:close()); return s
end
local function pinned(path) return output("git -C " .. quote(repo) .. " show " .. quote(commit .. ":" .. path)) end
local function section(source, first, last)
    local a = assert(source:find(first, 1, true)); local b = assert(source:find(last, a, true))
    local _, lines = source:sub(1, a - 1):gsub("\n", "")
    return string.rep("\n", lines) .. source:sub(a, b - 1)
end
local function write(path, s) local f = assert(io.open(path, "wb")); assert(f:write(s)); assert(f:close()) end
local checks = 0
local function check(ok, why) assert(ok, why); checks = checks + 1 end
local function run(source, name, env) return setfenv(assert(loadstring(source, name)), env)() end
local classCode = section(pinned("game/engines/default/engine/class.lua"), "__zipname_zf_store = {}", "_M.LOAD_SELF = {}")
local saveCode = pinned("game/engines/default/engine/Savefile.lua")
local build = output("mktemp -d /tmp/tome-save-followup.XXXXXX"):gsub("\n$", "")
assert(build:match("^/tmp/tome%-save%-followup%.[%w]+$"))
write(build .. "/pinned_serial.c", section(pinned("src/serial.c"), "static int serial_new(lua_State *L)", "static int serial_order_realsave"))
write(build .. "/pinned_worker.c", section(pinned("src/serial.c"), "int thread_save(void *data)", "// Runs on main thread"))
local flags = output("if pkg-config --exists luajit; then pkg-config --cflags luajit; else pkg-config --cflags lua5.1; fi"):gsub("\n", " ")
local status = os.execute(quote(os.getenv("CC") or "cc") .. " -shared -fPIC -O2 " .. flags .. " -I" .. quote(build) .. " " ..
    quote(root .. "/tests/save_callbacks_fixture.c") .. " -o " .. quote(build .. "/serial_fixture.so"))
assert(status == 0 or status == true, "native fixture compilation failed")
local native = assert(package.loadlib(build .. "/serial_fixture.so", "luaopen_serial_fixture"))()
local Faster = assert(loadfile(root .. "/overload/engine/FasterSaveFollowup.lua"))()
local function world(optimized)
    local Class, Savefile = {}, {}
    local events = {}
    local env = setmetatable({_M = Class, engine = {Savefile = Savefile}, core = {serial = {new = native.new}},
        table = setmetatable({merge = function(dest, src) for k, v in pairs(src) do dest[k] = v end end}, {__index = table})}, {__index = _G})
    run(classCode, "@/engine/class.lua", env)
    local saveEnv = setmetatable({_M = Savefile, module = function() end, class = {}, require = function() return {} end,
        print = function() end, core = {wait = {manualTick = function() events[#events + 1] = "tick" end}},
        savefile_pipe = {current_nb = 0}}, {__index = _G})
    run(saveCode, "@/engine/Savefile.lua", saveEnv)
    local save = setmetatable({}, {__index = Savefile}); save:init("test", true)
    -- Stable entry names make byte comparison possible across independent graphs.
    function save:getFileName(o) return o == self.current_save_main and "main" or o.id end
    local original = Class.save
    if optimized then check(Faster.installClass(Class), "install actual pinned class.save") end
    return {class = Class, save = save, env = env, saveEnv = saveEnv, events = events, original = original}
end
local function graph(w, count)
    local mt = {__index = {save = function(o)
        w.events[#w.events + 1] = "save:" .. o.id
        return w.class.save(o)
    end, onSaving = function(o) w.events[#w.events + 1] = "on:" .. o.id end}}
    local first = setmetatable({id = "root", __CLASSNAME = "Fixture", value = "save\0\n\r\"\\payload"}, mt)
    local previous = first
    for i = 1, count do
        local o = setmetatable({id = "child" .. i, __CLASSNAME = "Fixture", n = i, root = first}, mt)
        previous.child = o; previous = o
    end
    previous.child = first
    first.shared = previous
    return first
end
local function serialize(w, obj, zip)
    local co = coroutine.create(function() return w.save:saveObject(obj, zip or "fixture.tmp") end)
    local resumes, result = 0
    repeat
        local ok, value = coroutine.resume(co); assert(ok, value); result = value; resumes = resumes + 1
    until coroutine.status(co) == "dead"
    return resumes, result
end
local function collect() collectgarbage("collect"); collectgarbage("collect") end
local function compare(a, b, label)
    check(#a == #b, label .. " length")
    for i = 1, #a do
        for _, key in ipairs{"zip", "file", "data"} do check(a[i][key] == b[i][key], label .. " " .. i .. "." .. key) end
    end
end
local oldEntries, oldEvents
for _, optimized in ipairs{false, true} do
    collect(); native.reset(); collectgarbage("stop")
    local w = world(optimized); local obj = graph(w, 160)
    local resumes, result = serialize(w, obj)
    check(result == 161 and resumes == 162 and w.saveEnv.savefile_pipe.current_nb == 161,
        "original object count and every coroutine yield retained")
    local entries = native.entries()
    local created, freed, names, adds = native.stats()
    check(created == 161 and freed == 0, "same native userdata count/lifetime before original GC")
    check(names == (optimized and 1 or 161) and adds == names, "native receives one callback pair per Savefile")
    if optimized then
        compare(oldEntries, entries, "pinned serializer bytes")
        check(table.concat(w.events, ",") == oldEvents, "onSaving/save/manualTick and LIFO order identical")
    else oldEntries, oldEvents = entries, table.concat(w.events, ",") end
    collect(); local _, released = native.stats(); check(released == 161, "all original serializer finalizers still execute")
    collectgarbage("restart")
end

-- Filters deliberately preserve the C disallow2 override and inherited/raw split.
for _, mode in ipairs{"deny", "allow", "raw_override", "inherited"} do
    local expected
    for _, optimized in ipairs{false, true} do
        collect(); native.reset()
        local w = world(optimized)
        local obj = {id = "root", __CLASSNAME = "Fixture", kept = 5, excluded = 9, other = 17}
        local mt = {}
        if mode == "raw_override" then obj._no_save_fields = {excluded = true}
        elseif mode == "inherited" then mt.__index = {_no_save_fields = {excluded = true}} end
        setmetatable(obj, mt)
        local filter = mode == "deny" and {excluded = true} or {kept = true}
        w.save.current_save_zip, w.save.current_save_main = "filter.tmp", obj
        check(select("#", w.class.save(obj, filter, mode ~= "deny")) == 0, "class.save zero return values")
        check(getmetatable(obj) == mt, "original metatable restored")
        local data = native.entries()
        if expected then compare(expected, data, "filter " .. mode) else expected = data end
    end
end

-- Interleaved Savefiles and method changes still resolve against the captured
-- Savefile, including a second save after the first userdata have been finalized.
do
    collect(); native.reset(); collectgarbage("stop")
    local w = world(true); local first = w.save
    serialize(w, graph(w, 3), "first.tmp")
    local second = setmetatable({}, getmetatable(first)); second:init("second", true)
    second.getFileName = first.getFileName; w.save = second
    serialize(w, graph(w, 4), "second.tmp")
    local _, _, names, adds = native.stats(); check(names == 2 and adds == 2, "independent callback pairs per Savefile")
    w.env.engine.Savefile.current_save = first; w.save = first
    first.getFileName = function(_, o) return "renamed-" .. o.id end
    serialize(w, graph(w, 2), "again.tmp")
    local entries = native.entries(); check(entries[#entries].file:match("^renamed%-"), "dynamic method lookup survives cached callbacks")
    collect(); collectgarbage("restart")
    serialize(w, graph(w, 1), "after-gc.tmp")
    check(native.entries()[#native.entries()].zip == "after-gc.tmp", "second save after GC works")
end

-- No extra roots survive the native userdata: weak values must not leak a
-- Savefile through the module cache (Lua 5.1 lacks ephemeron weak-key semantics).
do
    collect(); native.reset(); collectgarbage("stop")
    local weak = setmetatable({}, {__mode = "v"})
    local w = world(true)
    do
        local s = w.save; weak[1] = s; serialize(w, graph(w, 5))
        w.env.engine.Savefile.current_save = false; w.save = nil
    end
    check(weak[1] ~= nil, "native callback retains Savefile before finalization")
    collect(); collect(); check(weak[1] == nil, "cache releases Savefile after native finalizers")
    collectgarbage("restart")
end

do
    local w = world(false); local original = w.class.save
    check(not Faster.installClass(w.class, {save_callbacks = false}) and w.class.save == original, "opt out")
    w.class.save = function() return "addon" end
    check(not Faster.installClass(w.class) and w.class.save() == "addon", "unknown class override retained")
    w.class.save = original; w.env.core.serial.new = function() end
    check(not Faster.installClass(w.class), "unknown serializer retained")
    w = world(true); local method = w.class.save
    check(Faster.installClass(w.class) and w.class.save == method, "idempotent install")
    local calls, seen = 0, {}
    w.env.core.serial.new = function(zip, name, add, ...)
        calls = calls + 1; seen[#seen + 1] = name
        return native.new(zip, name, add, ...)
    end
    serialize(w, graph(w, 5))
    check(calls == 6 and seen[1] ~= seen[2], "late replacement falls back with original distinct callbacks")
    local failure = {}; w.env.core.serial.new = function() error(failure) end
    local obj = graph(w, 0)
    local ok, err = pcall(w.class.save, obj)
    check(not ok and err == failure, "original serializer error identity retained")
    check(next(getmetatable(obj)) == nil, "original empty metatable on serialization error retained")
    w.env.core.serial.new = native.new
    serialize(w, graph(w, 3), "retry.tmp")
    check(native.entries()[#native.entries()].zip == "retry.tmp", "retry after error")
end

do
    collect(); native.reset(); collectgarbage("stop")
    local w = world(true)
    check(not Faster.getDiagnostics().enabled, "diagnostics default off")
    Faster.enableDiagnostics(true)
    serialize(w, graph(w, 5))
    local stats = Faster.getDiagnostics()
    check(stats.calls == 6 and stats.optimized == 6 and stats.fallbacks == 0 and stats.callback_pairs == 1,
        "aggregate diagnostics observe real native guard hits without replacing factory")
    w.env.core.serial.new = function(...) return native.new(...) end
    serialize(w, graph(w, 2))
    stats = Faster.getDiagnostics()
    check(stats.calls == 9 and stats.optimized == 6 and stats.fallbacks == 3 and stats.callback_pairs == 1,
        "diagnostics distinguish guard fallback")
    Faster.enableDiagnostics(false)
    check(not Faster.getDiagnostics().enabled, "diagnostics disable and release state")
    collectgarbage("restart")
end

-- A direct counterexample to merging adjacent full collections. An A finalizer
-- drops the last strong registry reference to B; the second cycle observes it.
local function gcBarrier(cycles)
    collect(); collectgarbage("stop")
    local registry, order, weak = {}, {}, setmetatable({}, {__mode = "v"})
    do
        local b = newproxy(true); getmetatable(b).__gc = function() order[#order + 1] = "B" end
        registry[1] = b; weak[1] = b
        local a = newproxy(true); getmetatable(a).__gc = function() order[#order + 1] = "A"; registry[1] = nil end
    end
    for i = 1, cycles do collectgarbage("collect") end
    check(registry[1] == nil, "A drops the final strong reference")
    local result = table.concat(order, ",") .. ":weak=" .. tostring(weak[1] ~= nil)
    collect(); collectgarbage("restart"); return result
end
check(gcBarrier(1) == "A:weak=true" and gcBarrier(2) == "A,B:weak=false",
    "adjacent GC merge is observably different before serialization")

-- Finishing a cycle begun before the barrier may retain an object which a new
-- full collection removes. Search for a partial marking point through the
-- public step API; the precise step index depends on the LuaJIT root set.
local function partialBarrier(steps, full)
    collect(); collectgarbage("stop")
    local strong = {value = {sentinel = true}}
    local weak = setmetatable({strong.value}, {__mode = "v"})
    local noise = {}; for i = 1, 5000 do noise[i] = {i} end
    local finished = false
    for i = 1, steps do if collectgarbage("step", 1) then finished = true; break end end
    strong.value = nil
    if full then collectgarbage("collect")
    else while not collectgarbage("step", 1) do end end
    local alive = weak[1] ~= nil
    assert(#noise == 5000)
    collect(); collectgarbage("restart"); return alive, finished
end
do
    local witnessed
    for steps = 1, 2000 do
        local alive, finished = partialBarrier(steps, false)
        if alive and not finished and not partialBarrier(steps, true) then witnessed = steps; break end
    end
    check(witnessed, "step-until-first-true is not a fresh full GC barrier")
    print("GC_STEP_COUNTEREXAMPLE partial_steps=" .. witnessed)
end

-- Queue starvation is an end-of-archive signal in the actual pinned worker.
-- Waking it after each object closes/reports an incomplete archive and the
-- next serial_new opens it again with APPEND_STATUS_CREATE (truncation).
do
    collect(); native.reset(); native.protocol(true)
    local w = world(true); w.save.current_save_zip = "partial.tmp"
    w.class.save({id = "first", __CLASSNAME = "Fixture"})
    local opens, closes, completed = native.worker()
    check(opens == 1 and closes == 1 and completed == 1, "worker closes/reports completion at first queue starvation")
    w.class.save({id = "second", __CLASSNAME = "Fixture"})
    opens, closes, completed = native.worker()
    check(opens == 2 and closes == 2 and completed == 2, "late object reopens archive in create mode after partial completion")
    native.protocol(false)
    collect(); native.reset(); native.protocol(true)
    w = world(true); w.save.current_save_zip = "whole.tmp"
    w.class.save({id = "first", __CLASSNAME = "Fixture"})
    w.class.save({id = "second", __CLASSNAME = "Fixture"})
    opens, closes, completed = native.worker()
    check(opens == 1 and closes == 1 and completed == 1, "original enqueue-all protocol opens/closes/completes once")
    native.protocol(false)
end

-- Execute the real exporter log block: uiset is absent from Game's persistence
-- allowlist but remains a concrete snapshot consumer in online character data.
do
    local source = pinned("game/modules/tome/class/interface/PlayerDumpJSON.lua")
    local a = assert(source:find('local log = js:newSection("last_messages")', 1, true))
    local b = assert(source:find("\n", assert(source:find('log.text = ', a, true)), true))
    local data = {}
    local env = setmetatable({js = {newSection = function(_, name) data[name] = {}; return data[name] end},
        game = {uiset = {logdisplay = {getLines = function(_, n) assert(n == 30); return {"A", "B"} end}}}}, {__index = _G})
    local block = assert(loadstring(source:sub(a, b), "@pinned-export-log")); setfenv(block, env)
    block(); check(data.last_messages.text == "A#LAST#\nB", "actual exporter consumes uiset log")
    env.game.uiset = nil
    check(not pcall(block), "save-whitelist-only root breaks actual online exporter")
end

if os.getenv("TOME_SAVE_FOLLOWUP_BENCH") == "1" then
    -- Turn off identity tracking so its weak-table storage does not inflate
    -- the measured allocation saving. Warm up twice and alternate A/B order.
    native.tracking(false)
    for sample = -1, 9 do
        local order = sample % 2 == 1 and {false, true} or {true, false}
        for _, optimized in ipairs(order) do
            collect(); native.reset(); local w = world(optimized); local obj = graph(w, 2852)
            collect(); collectgarbage("stop")
            local memory, start = collectgarbage("count"), os.clock()
            serialize(w, obj)
            local elapsed, allocated = (os.clock() - start) * 1000, collectgarbage("count") - memory
            local created = native.stats()
            if sample > 0 then print(("BENCH mode=%s sample=%d ms=%.3f lua_kib=%.3f objects=%d"):format(
                optimized and "after" or "before", sample, elapsed, allocated, created)) end
            collectgarbage("restart")
        end
    end
end
collect(); assert(os.execute("rm -rf -- " .. quote(build)) == 0)
print("PASS save followup: " .. checks .. " checks; pinned C bytes/filtering, ordering/yields, callbacks, weak lifetime, errors/retry, GC/worker/root counterexamples")
