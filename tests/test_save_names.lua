-- GPL-3.0-or-later. Compact names with the pinned native writer and stock reader.
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
local classSource, saveCode = pinned("game/engines/default/engine/class.lua"), pinned("game/engines/default/engine/Savefile.lua")
local build = output("mktemp -d /tmp/tome-save-names.XXXXXX"):gsub("\n$", "")
assert(build:match("^/tmp/tome%-save%-names%.[%w]+$"))
write(build .. "/pinned_serial.c", section(pinned("src/serial.c"), "static int serial_new(lua_State *L)", "static int serial_order_realsave"))
write(build .. "/pinned_worker.c", section(pinned("src/serial.c"), "int thread_save(void *data)", "// Runs on main thread"))
local flags = output("if pkg-config --exists luajit; then pkg-config --cflags luajit; else pkg-config --cflags lua5.1; fi"):gsub("\n", " ")
local status = os.execute(quote(os.getenv("CC") or "cc") .. " -shared -fPIC -O2 " .. flags .. " -I" .. quote(build) .. " " ..
    quote(root .. "/tests/save_callbacks_fixture.c") .. " -o " .. quote(build .. "/serial_fixture.so"))
assert(status == 0 or status == true, "native fixture compilation failed")
local native = assert(package.loadlib(build .. "/serial_fixture.so", "luaopen_serial_fixture"))()
local Names = assert(loadfile(root .. "/overload/engine/FasterSaveNames.lua"))()
local Followup = assert(loadfile(root .. "/overload/engine/FasterSaveFollowup.lua"))()
local function world(compact, callbacks, files, decimalNames)
    local Class, Savefile, events = {}, {}, {}
    local objectClass = {loaded = function(o) events[#events + 1] = "loaded:" .. o.id end}
    local function requireStub(name)
        if name == "engine.class" then return Class end
        if name == "Fixture" then return objectClass end
        if name == "engine.ui.Dialog" then return {} end
        error(name)
    end
    local env = setmetatable({_M = Class, engine = {Savefile = Savefile}, require = requireStub,
        core = {serial = {new = native.new}}, table = setmetatable({merge = function(dest, src)
            for k, v in pairs(src) do dest[k] = v end
        end}, {__index = table})}, {__index = _G})
    run(section(classSource, "__zipname_zf_store = {}", "--- \"Reloads\""), "@/engine/class.lua", env)
    Class.load = env.load
    local saveEnv = setmetatable({_M = Savefile, module = function() end, class = Class, require = requireStub,
        print = function() end, core = {wait = {manualTick = function() events[#events + 1] = "tick" end}},
        savefile_pipe = {current_nb = 0}, fs = {open = function(path)
            local data = files and files[path]; if not data then return end
            local read = false
            return {read = function() if read then return end; read = true; return data end, close = function() end}
        end}}, {__index = _G})
    run(saveCode, "@/engine/Savefile.lua", saveEnv)
    local originalName = Savefile.getFileName
    if compact then check(Names.installSavefile(Savefile, {compact_save_names_base62 = not decimalNames}), "install on actual pinned Savefile") end
    if callbacks then check(Followup.installClass(Class), "compose with callback reuse") end
    local save = setmetatable({}, {__index = Savefile}); save:init("test", true); save.load_dir = ""
    return {class = Class, Savefile = Savefile, save = save, env = env, events = events, originalName = originalName}
end
local function graph(w, count)
    local mt = {__index = {save = function(o)
        w.events[#w.events + 1] = "save:" .. o.id; return w.class.save(o)
    end, onSaving = function(o) w.events[#w.events + 1] = "on:" .. o.id end}}
    local first = setmetatable({id = "root", __CLASSNAME = "Fixture", value = "save\0\n\r\"\\payload"}, mt)
    local previous = first
    for i = 1, count do
        local o = setmetatable({id = "child" .. i, __CLASSNAME = "Fixture", n = i, root = first}, mt)
        previous.child = o; previous = o
    end
    previous.child = first; first.shared = previous
    first.details = {empty = {}, [false] = true, [3] = -1.25, text = "loadObject('123') / setLoaded('456',o)"}
    first.keys = {[first.child] = previous}
    return first
end
local function serialize(w, obj, zip)
    w.Savefile.current_save = w.save
    local co = coroutine.create(function() return w.save:saveObject(obj, zip or "fixture.tmp") end)
    local resumes, result = 0
    repeat
        local ok, value = coroutine.resume(co); assert(ok, value); result = value; resumes = resumes + 1
    until coroutine.status(co) == "dead"
    return resumes, result
end
local function collect() collectgarbage("collect"); collectgarbage("collect") end
local function equalGraph(a, b)
    local forward, backward = {}, {}
    local function walk(x, y)
        check(type(x) == type(y), "field type")
        if type(x) ~= "table" then check(x == y, "field value"); return end
        if forward[x] then check(forward[x] == y, "shared/cyclic reference"); return end
        check(not backward[y], "distinct objects stay distinct"); forward[x], backward[y] = y, x
        local xn, yn = 0, 0
        for k, v in pairs(x) do
            xn = xn + 1
            local target = k
            if type(k) == "table" then
                target = forward[k]
                if not target then
                    for candidate in pairs(y) do
                        if type(candidate) == "table" and candidate.id == k.id then target = candidate; break end
                    end
                end
                check(target ~= nil, "object table key"); walk(k, target)
            end
            walk(v, y[target])
        end
        for _ in pairs(y) do yn = yn + 1 end
        check(xn == yn, "no lost or extra fields")
    end
    walk(a, b)
end

-- Both callback implementations, all class fields, aliases, cycles and object
-- keys pass through the actual C encoder and unmodified engine.class/Savefile reader.
local originalEvents
for _, callbacks in ipairs{false, true} do
    for _, mode in ipairs{"original", "decimal", "base62"} do
        local compact = mode ~= "original"
        collect(); native.reset()
        local w = world(compact, callbacks, nil, mode == "decimal"); local obj = graph(w, 160)
        local resumes, count = serialize(w, obj)
        check(count == 161 and resumes == 162, "original object count and coroutine yields")
        local eventText = table.concat(w.events, ",")
        if originalEvents then check(eventText == originalEvents, "same callbacks and processing order") else originalEvents = eventText end
        local files, entries = {}, native.entries()
        check(#entries == count, "one entry per object")
        for _, entry in ipairs(entries) do
            check(files[entry.file] == nil, "unique archive names")
            files[entry.file] = entry.data
            check(entry.file == "main" or (compact and entry.file:match("^[%w_]+$"))
                or (not compact and entry.file:match("^Fixture%-")), "expected filename scheme")
        end
        check(files.main ~= nil, "reserved main entry")
        local reader = world(false, false, files)
        check(reader.Savefile.getFileName == reader.originalName, "reader has no compact naming code")
        local loaded = reader.save:loadReal("main"); check(loaded ~= nil, "stock reader loads root")
        equalGraph(obj, loaded)
        check(#reader.save.delayLoad == count, "all original loaded callbacks queued")
        for _, o in ipairs(reader.save.delayLoad) do o:loaded() end
        check(#reader.events == count * 2, "all original loaded callbacks execute")
    end
end

do
    local w = world(true); local s = w.save
    local seen, names = {}, {}
    for i = 1, 10000 do
        local object = {__CLASSNAME = "Fixture"}
        local id = s:getFileName(object)
        check(id ~= "main" and not seen[id], "base62 IDs remain unique across digit boundaries")
        check(id:match("^[0-9a-zA-Z]+$") ~= nil, "portable archive filename")
        seen[id], names[i] = true, id
    end
    check(names[9] == "9" and names[10] == "a" and names[61] == "Z" and names[62] == "10", "first carry")
    check(names[3843] == "ZZ" and names[3844] == "100", "second carry")
    -- Advance only the allocator counter to exercise the root-name collision
    -- without retaining millions of objects in this regression test.
    local caches
    for i = 1, 20 do
        local name, value = debug.getupvalue(s.getFileName, i)
        if name == "caches" then caches = value; break end
    end
    check(caches and caches[s], "per-Savefile allocator available")
    local alphabet, reserved = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ", 0
    for character in ("main"):gmatch(".") do
        reserved = reserved * 62 + assert(alphabet:find(character, 1, true)) - 1
    end
    caches[s].count = reserved - 1
    local object = {__CLASSNAME = "Fixture"}
    check(s:getFileName(object) == "_main", "non-root main is escaped")
    s.current_save_main = object
    check(s:getFileName(object) == "main", "root stays main even after escape")
    local decimalWorld = world(true, false, nil, true)
    local id
    for i = 1, 62 do id = decimalWorld.save:getFileName({}) end
    check(id == "62", "decimal opt-out preserves 0.2.10 names")
    local defaultWorld = world(false)
    check(Names.installSavefile(defaultWorld.Savefile), "default naming installation")
    for i = 1, 62 do id = defaultWorld.save:getFileName({}) end
    check(id == "62", "default retains decimal until base62 CPU acceptance passes")
end

do
    local w = world(true); local s = w.save
    local a, b = {__CLASSNAME = "Fixture"}, {__CLASSNAME = "Fixture"}
    check(s:getFileName(a) == "1" and s:getFileName(b) == "2", "monotonic distinct identifiers")
    collect(); check(s:getFileName(a) == "1", "live identity stable across GC")
    s.current_save_main = a; check(s:getFileName(a) == "main", "root always main")
    s.current_save_main = b; check(s:getFileName(a) == "1" and s:getFileName(b) == "main", "changing archive root preserves non-root IDs")
    s.current_save_main = nil
    local second = setmetatable({}, {__index = w.Savefile}); second:init("second")
    check(second:getFileName(b) == "1" and s:getFileName(b) == "2", "independent interleaved Savefiles")
    check(select("#", s:close()) == 0 and not s.tables, "original close behavior and zero returns")
    check(s:getFileName(a) == w.originalName(s, a), "closed owner uses upstream behavior")
    check(select("#", s:init("reuse")) == 0 and s:getFileName(b) == "1", "close/init resets identifiers")
    s:init("reinit"); check(s:getFileName(a) == "1", "direct reinitialization resets identifiers")
    local marker = {}; local ok, err = pcall(s.init, s, {gsub = function() error(marker) end})
    check(not ok and err == marker and s:getFileName(a) == "1", "failed init preserves error and current cache")
end

do
    collect(); native.reset(); collectgarbage("stop")
    local weak = setmetatable({}, {__mode = "v"}); local w = world(true, true)
    do
        local spare = {__CLASSNAME = "Fixture"}; weak[1] = spare; w.save:getFileName(spare)
    end
    collect(); check(weak[1] == nil, "naming cache does not retain unqueued objects")
    do
        local object = graph(w, 5); weak[2], weak[3] = object, w.save
        serialize(w, object)
        w.save:close(); w.Savefile.current_save = false; w.save = nil
    end
    collect(); collect(); check(weak[2] == nil and weak[3] == nil, "closed owner and graph released after native finalization")
    -- A forgotten close also cannot create a registry cycle through the helper.
    do
        local owner = setmetatable({}, {__index = w.Savefile}); owner:init("unclosed")
        weak[4] = owner; owner:getFileName({__CLASSNAME = "Fixture", owner = owner})
        w.Savefile.current_save = false
    end
    collect(); check(weak[4] == nil, "unclosed owner not retained by helper")
    collectgarbage("restart")
end

do
    collect(); native.reset()
    local w = world(true, true); local object = graph(w, 3)
    local expected = w.save:getFileName(object.child)
    local failure = {}; w.env.core.serial.new = function() error(failure) end
    local ok, err = pcall(serialize, w, object)
    check(not ok and err == failure, "native serialization failure propagates unchanged")
    check(w.save:getFileName(object.child) == expected, "failed serialization keeps assigned names stable")
    w.env.core.serial.new = native.new
    w.save:close(); w.save:init("retry")
    serialize(w, graph(w, 3), "retry.tmp")
    check(#native.entries() == 4 and native.entries()[1].file == "main", "fresh retry succeeds")
end

for _, field in ipairs{"getFileName", "init", "close"} do
    local w = world(false); local custom = function() return "third party" end
    w.Savefile[field] = custom
    check(not Names.installSavefile(w.Savefile) and w.Savefile[field] == custom, "unknown " .. field .. " retained")
    w = world(true); local method = w.Savefile.getFileName
    check(Names.installSavefile(w.Savefile) and method == w.Savefile.getFileName, "idempotent installation")
    w.Savefile[field] = custom
    check(not Names.installSavefile(w.Savefile) and w.Savefile[field] == custom, "late " .. field .. " retained")
end
do
    local w = world(false); local name, init, close = w.Savefile.getFileName, w.Savefile.init, w.Savefile.close
    check(not Names.installSavefile(w.Savefile, {compact_save_names = false})
        and w.Savefile.getFileName == name and w.Savefile.init == init and w.Savefile.close == close, "opt out preserves all methods")
end
collect()
assert(os.execute("rm -r -- " .. quote(build)) == 0)
print("PASS " .. checks .. " compact save name checks; native serialization, stock full-graph reload, lifecycle and guards")
