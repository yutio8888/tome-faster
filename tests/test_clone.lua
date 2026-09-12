-- GPL-3.0-or-later. Differential tests against the pinned engine implementation.
assert(_VERSION == "Lua 5.1", "Lua 5.1 / LuaJIT required")
local root = arg[1] or "."
local repo = assert(arg[2], "pass a local ToME source Git clone as argument 2")
local commit = "624a67329fe2ad440c5b344785a9c73fcf22ae63"
local function quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
local p = assert(io.popen("git -C " .. quote(repo) .. " show " .. quote(commit .. ":game/engines/default/engine/class.lua"), "r"))
local source = p:read("*a"); assert(p:close()); assert(#source > 0)
local first = assert(source:find("local function clonerecursfull(", 1, true))
local last = assert(source:find("--- Replaces the object with an other", first, true))
local _, lines = source:sub(1, first - 1):gsub("\n", "")
local code = string.rep("\n", lines) .. source:sub(first, last - 1)
local function pinned()
    local Class = {}
    local env = setmetatable({_M = Class}, {__index = _G})
    setfenv(assert(loadstring(code, "@/engine/class.lua")), env)()
    return Class.cloneForSave, env
end
local original = pinned()
local Faster = assert(loadfile(root .. "/overload/engine/FasterClone.lua"))()
local checks, cases = 0, 0
local function check(ok, message) assert(ok, message); checks = checks + 1 end

-- Labels disambiguate copied table keys. Original references must remain original,
-- so graph isomorphism cannot hide an accidentally cloned __threads/replacement.
local function equalGraph(a, b, originals)
    local forward, reverse = {}, {}
    local function equal(x, y)
        check(type(x) == type(y), "same value type")
        if type(x) ~= "table" then
            check(rawequal(x, y) or (x ~= x and y ~= y), "same primitive value")
            return
        end
        if originals[x] or originals[y] then check(rawequal(x, y), "original reference preserved"); return end
        if forward[x] then check(rawequal(forward[x], y), "alias/cycle preserved"); return end
        check(not reverse[y], "distinct copied tables remain distinct")
        forward[x], reverse[y] = y, x
        check(rawequal(getmetatable(x), getmetatable(y)), "original metatable preserved")
        local visited = {}
        for k, v in pairs(x) do
            local other = k
            if type(k) == "table" and not originals[k] then
                other = forward[k]
                if not other then
                    for candidate in pairs(y) do
                        if type(candidate) == "table" and not originals[candidate]
                            and not reverse[candidate] and rawget(candidate, "label") == rawget(k, "label") then
                            check(not other, "unambiguous table-key labels")
                            other = candidate
                        end
                    end
                end
                check(other ~= nil, "table key exists")
                equal(k, other)
            end
            check(rawget(y, other) ~= nil, "same keys")
            visited[other] = true
            equal(v, rawget(y, other))
        end
        for k in pairs(y) do check(visited[k], "no extra keys") end
    end
    equal(a, b)
end

local function compare(value)
    local originals = {}
    local function mark(t)
        if type(t) ~= "table" or originals[t] then return end
        originals[t] = true
        for k, v in pairs(t) do mark(k); mark(v) end
    end
    mark(value)
    local a, countA = original(value)
    local b, countB = Faster.cloneForSave(value)
    check(countA == countB, "same object count")
    equalGraph(a, b, originals)
    cases = cases + 1
    return a, b, countA
end

do
    local f, thread = function() return "unchanged" end, coroutine.create(function() end)
    compare{label = "primitives", str = "string", number = 12.5, [17] = true,
        [true] = false, func = f, thread = thread, userdata = io.stdout, nan = 0 / 0}
    -- Upstream stops its next loop at a false key; retain even that behavior.
    compare{[false] = "false key", after = "possibly unvisited"}
    local root = {label = "root", __CLASSNAME = "Game"}
    local key = {label = "key", __ATOMIC = true}
    root.self, root.a, root.b, root[key] = root, key, key, root
    root.cloned = function() error("cloneForSave must not call cloned") end
    setmetatable(key, {__index = {inherited = 7}})
    local a, b, count = compare(root)
    check(count == 2 and a.a == a.b and b.a == b.b, "class count and shared value")
    check(a.self == a and b.self == b, "root cycle")
    compare(setmetatable({label = "weak", value = key}, {__mode = "v"}))
end

do
    local threads = {label = "threads"}
    local a, b = compare{label = "unvisited threads", __threads = threads}
    check(a.__threads == threads and b.__threads == threads, "unvisited __threads retained")
    local t = {label = "visited threads"}
    a, b = compare{label = "root", [1] = t, __threads = t}
    check(a.__threads == a[1] and b.__threads == b[1], "visited __threads uses copied alias")
    check(a.__threads ~= t and b.__threads ~= t, "visited __threads is not original")
end

do
    local replacement = {label = "replacement", __CLASSNAME = "Replacement"}
    local wrapper = {label = "wrapper", __ATOMIC = true, __SAVEINSTEAD = replacement}
    local a, b, count = compare{label = "root", [1] = replacement, [2] = wrapper}
    check(a[2] == replacement and b[2] == replacement and count == 2,
        "memoized __SAVEINSTEAD returns original replacement and adds one")
    compare{label = "root", [1] = wrapper, [2] = wrapper, [3] = replacement}
    compare(wrapper)
    compare{label = "unmarked replacement", __SAVEINSTEAD = replacement}
    local cycle = {label = "replacement cycle", __ATOMIC = true}
    cycle.__SAVEINSTEAD = cycle
    compare(cycle)
end

-- Deterministic, mixed graphs exercise JIT traces with repeated aliases and keys.
local seed = 12345
local function random(n) seed = (seed * 48271) % 2147483647; return seed % n + 1 end
for trial = 1, 80 do
    local nodes = {}
    for i = 1, 24 do nodes[i] = {label = "node" .. i, __ATOMIC = i % 3 == 0 or nil} end
    for i = 1, #nodes do
        local node = nodes[i]
        for j = 1, 6 do
            local choice = random(4)
            node["k" .. j] = choice == 1 and random(100) or choice == 2 and ("s" .. random(20)) or nodes[random(#nodes)]
        end
        node[nodes[random(#nodes)]] = nodes[random(#nodes)]
        if i % 5 == 0 then node.__threads = nodes[random(#nodes)] end
    end
    compare(nodes[1])
end

do
    local method, env = pinned()
    local trace = {}
    local function label(v) return type(v) == "table" and rawget(v, "label") or tostring(v) end
    env.next = function(t, k)
        trace[#trace + 1] = "next:" .. label(t) .. ":" .. label(k)
        return next(t, k)
    end
    local child = setmetatable({label = "child"}, {__index = function(t, k)
        trace[#trace + 1] = "index:" .. label(t) .. ":" .. label(k)
        if k == "__CLASSNAME" then return "InheritedClass" end
    end})
    local root = {label = "trace", [1] = child, [2] = child, __threads = child}
    method(root)
    local expected = table.concat(trace, "\n")
    trace = {}
    local Game = {cloneForSave = method}
    check(Faster.installGame(Game), "install with original helper environment")
    Game.cloneForSave(root)
    check(table.concat(trace, "\n") == expected, "same next traversal and metatable lookup order")
end

do
    local method = pinned()
    local Game = {cloneForSave = method}
    check(not Faster.installGame(Game, {save_clone = false}) and Game.cloneForSave == method, "opt-out")
    check(Faster.installGame(Game), "install pinned method")
    local optimized = Game.cloneForSave
    check(Faster.installGame(Game) and Game.cloneForSave == optimized, "idempotent")
    local instance = {label = "installed", self = nil}; instance.self = instance
    local a, n = Game.cloneForSave(instance)
    check(a.self == a and a ~= instance and n == 0, "installed real-save entry")
    Game.cloneForSave = function() return "other addon" end
    check(not Faster.installGame(Game) and Game.cloneForSave() == "other addon", "later override preserved")
    check(not Faster.installGame({}), "missing method skipped")
    local replaced = pinned()
    debug.setupvalue(replaced, 1, function() return "other recursive clone" end)
    check(not Faster.installGame({cloneForSave = replaced}), "modified recursive helper skipped")
end
print(("PASS cloneForSave: %d differential graphs, %d assertions; aliases, replacements, threads, metadata and guards"):format(cases, checks))
