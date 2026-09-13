-- GPL-3.0-or-later. Synchronous checkpoint clone tests against pinned ToME.
assert(_VERSION == "Lua 5.1", "Lua 5.1 / LuaJIT required")
local root = arg[1] or "."
local repo = assert(arg[2], "pass a local ToME source Git clone as argument 2")
local commit = "624a67329fe2ad440c5b344785a9c73fcf22ae63"
local function quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
local p = assert(io.popen("git -C " .. quote(repo) .. " show " .. quote(commit .. ":game/engines/default/engine/class.lua"), "r"))
local source = p:read("*a"); assert(p:close()); assert(#source > 0)
local first = assert(source:find("local function clonerecursfull(", 1, true))
local last = assert(source:find("--- Replaces the object with an other", first, true))
local code = source:sub(first, last - 1)
local function pinned(checkpoint, stride)
    local Class = {}
    local env = setmetatable({_M = Class}, {__index = _G})
    local body = code
    if checkpoint then
        -- The separate GC/scheduling oracle inserts only a call immediately after
        -- the pinned assignment. Ordinary graph comparisons use unmodified code.
        local substitutions
        body, substitutions = body:gsub("n%[nk%] = ne", "n[nk] = ne; __clone_after_assignment()", 1)
        assert(substitutions == 1, "pinned assignment found once")
        local remaining = stride
        env.__clone_after_assignment = function()
            remaining = remaining - 1
            if remaining == 0 then checkpoint(); remaining = stride end
        end
    end
    setfenv(assert(loadstring(body, "@pinned-class-clone-refresh-test.lua")), env)()
    return Class.cloneForSave, env
end
local original = pinned()
local Refresh = assert(loadfile(root .. "/overload/engine/FasterCloneRefresh.lua"))()
local checks, cases = 0, 0
local function check(ok, message) assert(ok, message); checks = checks + 1 end

local function withControlledGC(test)
    collectgarbage("collect")
    collectgarbage("stop")
    local ok, err = pcall(test)
    collectgarbage("restart")
    collectgarbage("collect")
    if not ok then error(err, 0) end
end

-- Run this mode in its own process: the differential suite deliberately changes
-- helper environments and JIT traces, which is not a production benchmark setup.
if arg[3] == "--bench" then
    local Faster = assert(loadfile(root .. "/overload/engine/FasterClone.lua"))()
    local callbackCalls = 0
    local method = Refresh.make(_G, function() callbackCalls = callbackCalls + 1 end)
    local function bench(label, graph, repetitions)
        for i = 1, 12 do Faster.cloneForSave(graph); method(graph) end
        local totals, methods = {0, 0}, {Faster.cloneForSave, method}
        for pair = 1, 8 do
            for j = 1, 2 do
                local index = pair % 2 == 1 and j or 3 - j
                withControlledGC(function()
                    local start = os.clock()
                    for i = 1, repetitions do methods[index](graph) end
                    totals[index] = totals[index] + os.clock() - start
                end)
            end
        end
        print(("BENCH %s: clone %.3f ms, checkpoint %.3f ms, overhead %.2f%%"):format(
            label, totals[1] * 1000 / (8 * repetitions), totals[2] * 1000 / (8 * repetitions), 100 * (totals[2] / totals[1] - 1)))
    end
    local flat = {}; for i = 1, 100000 do flat[i] = i end
    local wide = {}; for i = 1, 10000 do wide[i] = {a = i, b = "text", c = i % 3, __CLASSNAME = "Class"} end
    local graph = {}
    for i = 1, 5000 do local child = {n = i, s = "x"}; graph[i] = child; graph[child] = graph; child.root = graph end
    bench("flat", flat, 15)
    bench("wide", wide, 10)
    bench("aliases and table keys", graph, 10)
    check(callbackCalls > 0, "benchmark invoked checkpoints")
    return
end

-- This helper intentionally pins the original graph and only proves ordinary
-- graph equivalence. The separate weak/GC fixtures below never enumerate/pin it.
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
    local calls = 0
    local function checkpoint(...) check(select("#", ...) == 0, "checkpoint has no arguments"); calls = calls + 1 end
    local b, countB = Refresh.cloneForSave(value, checkpoint)
    check(countA == countB, "same default object count")
    equalGraph(a, b, originals)
    for _, stride in ipairs{1, 7, 512, 1024} do
        calls = 0
        b, countB = Refresh.make(_G, checkpoint, stride)(value)
        check(countA == countB, "same configured object count")
        equalGraph(a, b, originals)
        local expected = 0
        pinned(function() expected = expected + 1 end, stride)(value)
        check(calls == expected, "one checkpoint per completed stride across recursive frames")
    end
    cases = cases + 1
    return a, b, countA
end

do
    local f, thread = function() return "unchanged" end, coroutine.create(function() end)
    compare{label = "primitives", str = "string", number = 12.5, [17] = true,
        [true] = false, func = f, thread = thread, userdata = io.stdout, nan = 0 / 0}
    compare{[false] = "false key", after = "possibly unvisited"}
    local graph = {label = "root", __CLASSNAME = "Game"}
    local key = {label = "key", __ATOMIC = true}
    graph.self, graph.a, graph.b, graph[key] = graph, key, key, graph
    graph.cloned = function() error("cloneForSave must not call cloned") end
    setmetatable(key, {__index = {inherited = 7}})
    local a, b, count = compare(graph)
    check(count == 2 and a.a == a.b and b.a == b.b, "class count and shared value")
    check(a.self == a and b.self == b, "root cycle")
    compare{label = "weak graph", strong = key, weak = setmetatable({label = "weak pinned", value = key}, {__mode = "v"})}

    local threads = {label = "threads"}
    a, b = compare{label = "unvisited threads", __threads = threads}
    check(a.__threads == threads and b.__threads == threads, "unvisited __threads retained")
    a, b = compare{label = "visited threads", [1] = threads, __threads = threads}
    check(a.__threads == a[1] and b.__threads == b[1] and b[1] ~= threads, "visited __threads uses memo")

    local replacement = {label = "replacement", __CLASSNAME = "Replacement"}
    local wrapper = {label = "wrapper", __ATOMIC = true, __SAVEINSTEAD = replacement}
    a, b, count = compare{label = "root", [1] = replacement, [2] = wrapper}
    check(a[2] == replacement and b[2] == replacement and count == 2,
        "memoized __SAVEINSTEAD returns original replacement and adds one")
    compare{label = "root", [1] = wrapper, [2] = wrapper, [3] = replacement}
    compare(wrapper)
    compare{label = "unmarked replacement", __SAVEINSTEAD = replacement}
    local cycle = {label = "replacement cycle", __ATOMIC = true}
    cycle.__SAVEINSTEAD = cycle
    compare(cycle)
end

local seed = 12345
local function random(n) seed = (seed * 48271) % 2147483647; return seed % n + 1 end
for trial = 1, 80 do
    local nodes = {}
    for i = 1, 24 do nodes[i] = {label = "node" .. i, __ATOMIC = i % 3 == 0 or nil} end
    for i = 1, #nodes do
        for j = 1, 6 do
            local choice = random(4)
            nodes[i]["k" .. j] = choice == 1 and random(100) or choice == 2 and ("s" .. random(20)) or nodes[random(#nodes)]
        end
        nodes[i][nodes[random(#nodes)]] = nodes[random(#nodes)]
        if i % 5 == 0 then nodes[i].__threads = nodes[random(#nodes)] end
    end
    compare(nodes[1])
end

-- Opaque __index can be stateful: preserve every read, including the two reads
-- of __SAVEINSTEAD and the key-before-value recursive traversal.
do
    local trace, saveReads = {}, 0
    local function label(v) return type(v) == "table" and (rawget(v, "label") or "table") or tostring(v) end
    local unused, replacement = {label = "unused"}, {label = "replacement", __ATOMIC = true}
    local wrapper = setmetatable({label = "wrapper"}, {__index = function(t, k)
        trace[#trace + 1] = "index:" .. label(t) .. ":" .. label(k)
        if k == "__ATOMIC" then return true end
        if k == "__SAVEINSTEAD" then saveReads = saveReads + 1; return saveReads % 2 == 1 and unused or replacement end
    end})
    local child = setmetatable({label = "child"}, {__index = function(t, k)
        trace[#trace + 1] = "index:" .. label(t) .. ":" .. label(k)
        if k == "__CLASSNAME" then return "InheritedClass" end
    end})
    local graph = {label = "trace", [1] = replacement, [2] = wrapper, [child] = wrapper, child = child, __threads = child}
    local function decorate(env)
        env.next = function(t, k)
            trace[#trace + 1] = "next:" .. label(t) .. ":" .. label(k)
            return next(t, k)
        end
        env.getmetatable = function(t)
            trace[#trace + 1] = "getmetatable:" .. label(t)
            return getmetatable(t)
        end
        env.setmetatable = function(t, mt)
            trace[#trace + 1] = "setmetatable:" .. label(t)
            return setmetatable(t, mt)
        end
    end
    local method, env = pinned()
    decorate(env)
    method(graph)
    local plainExpected = table.concat(trace, "\n")
    check(saveReads == 4, "opaque replacement read twice per wrapper visit")
    for _, stride in ipairs{1, 3, 512} do
        local function checkpoint() trace[#trace + 1] = "checkpoint" end
        trace, saveReads = {}, 0
        local reference, referenceEnv = pinned(checkpoint, stride)
        decorate(referenceEnv)
        reference(graph)
        local expected = table.concat(trace, "\n")
        trace, saveReads = {}, 0
        Refresh.make(env, checkpoint, stride)(graph)
        check(table.concat(trace, "\n") == expected, "same complete next/index/metatable/checkpoint trace")
        local filtered = {}
        for _, event in ipairs(trace) do if event ~= "checkpoint" then filtered[#filtered + 1] = event end end
        check(table.concat(filtered, "\n") == plainExpected, "same opaque access trace as unmodified pinned clone")
    end
end

do
    local calls = 0
    local flat = {}; for i = 1, 1025 do flat[i] = i end
    local result = {Refresh.cloneForSave(flat, function(...) check(select("#", ...) == 0, "default callback is argument-free"); calls = calls + 1 end)}
    check(#result == 2 and result[2] == 0 and result[1][1025] == 1025, "public method returns only clone and count")
    check(calls == 2, "default stride is 512")
    local a, count = Refresh.cloneForSave(flat)
    check(count == 0 and a ~= flat and a[1025] == flat[1025], "nil checkpoint supported")
    a, count = Refresh.make(_G, nil, 3)(flat)
    check(count == 0 and a[1025] == 1025, "factory nil checkpoint supported")
    for _, stride in ipairs{false, 0, -1, 0.5, math.huge, 0 / 0, "2"} do
        check(not pcall(Refresh.make, _G, function() end, stride), "invalid stride rejected")
    end
    check(not pcall(Refresh.make, false, nil), "invalid environment rejected")
    check(not pcall(Refresh.make, _G, true), "invalid factory callback rejected")
    check(not pcall(Refresh.cloneForSave, {}, true), "invalid direct callback rejected")
end

-- Neither callback failure nor reentry may reset a different invocation's budget.
do
    local outerCalls, innerCalls, inside, nested = 0, 0, false
    local method
    method = Refresh.make(_G, function()
        if inside then innerCalls = innerCalls + 1; return end
        outerCalls = outerCalls + 1
        if outerCalls == 1 then
            inside = true
            nested = method({11, 12, 13, 14, 15})
            inside = false
        end
    end, 2)
    local a = method({1, 2, 3, 4, 5, 6, 7})
    check(a[7] == 7 and nested[5] == 15, "reentrant copies complete")
    check(outerCalls == 3 and innerCalls == 2, "reentrant countdowns remain independent")

    local marker, callbackCalls, nextCalls, shouldFail = {}, 0, 0, true
    local env = setmetatable({next = function(t, k) nextCalls = nextCalls + 1; return next(t, k) end}, {__index = _G})
    method = Refresh.make(env, function()
        callbackCalls = callbackCalls + 1
        if shouldFail and callbackCalls == 2 then error(marker, 0) end
    end, 2)
    local ok, err = pcall(method, {1, 2, 3, 4, 5, 6})
    check(not ok and err == marker, "callback error identity propagates")
    check(callbackCalls == 2 and nextCalls == 4, "callback failure immediately stops traversal without retry")
    shouldFail, callbackCalls, nextCalls = false, 0, 0
    a = method({1, 2, 3, 4, 5, 6})
    check(a[6] == 6 and callbackCalls == 3 and nextCalls == 7, "fresh invocation after error gets a fresh budget")

    outerCalls, innerCalls, inside = 0, 0, false
    method = Refresh.make(_G, function()
        if inside then innerCalls = innerCalls + 1; error(marker, 0) end
        outerCalls = outerCalls + 1
        if outerCalls == 1 then
            inside = true
            local nestedOk, nestedErr = pcall(method, {8, 9})
            inside = false
            check(not nestedOk and nestedErr == marker, "nested callback error can be caught by its caller")
        end
    end, 2)
    a = method({1, 2, 3, 4, 5, 6})
    check(a[6] == 6 and outerCalls == 3 and innerCalls == 1, "caught reentrant error preserves outer progress")
end

-- GC is deliberately controlled by these fixtures, not by the clone module.
-- The oracle gets the same forced collections at the same assignment boundaries.
-- No graph prewalk or original-reference set is allowed in these tests. They show
-- behavior under this schedule, not exact identity under different GC timings.
local function gcMethod(kind, checkpoint)
    if kind == "pinned" then return pinned(checkpoint, 1) end
    return Refresh.make(_G, checkpoint, 1)
end
for _, kind in ipairs{"pinned", "refresh"} do
    for _, mode in ipairs{"k", "v", "kv"} do
        withControlledGC(function()
            local weak = setmetatable({}, {__mode = mode})
            local key, value = {label = "weak key"}, {label = "weak value"}
            weak[mode == "v" and "value" or key] = mode == "k" and "value" or value
            key, value = nil, nil
            local graph = {1, weak}
            local calls = 0
            local method = gcMethod(kind, function()
                calls = calls + 1
                if calls == 1 then collectgarbage("collect"); collectgarbage("collect") end
            end)
            local clone, count = method(graph)
            check(next(weak) == nil and next(clone[2]) == nil, kind .. " does not pin unvisited weak " .. mode .. " members")
            check(count == 0 and calls == 2 and getmetatable(clone[2]) == getmetatable(weak), "weak container metadata and checkpoint count")
        end)
    end
    withControlledGC(function()
        local value = {label = "strong alias"}
        local weak = setmetatable({value = value}, {__mode = "v"})
        local graph = {value, weak}
        local method = gcMethod(kind, function() collectgarbage("collect") end)
        local clone = method(graph)
        check(clone[1] ~= value and clone[2].value == clone[1] and weak.value == value,
            kind .. " forced GC preserves strongly reachable weak aliases")
    end)
    withControlledGC(function()
        local finalized, calls = 0, 0
        local weak = setmetatable({}, {__mode = "v"})
        local dying = newproxy(true)
        getmetatable(dying).__gc = function() finalized = finalized + 1 end
        weak.value = dying
        dying = nil
        local method = gcMethod(kind, function()
            calls = calls + 1
            if calls == 1 then collectgarbage("collect"); collectgarbage("collect") end
        end)
        local clone = method({1, weak})
        check(finalized == 1 and calls == 2, kind .. " checkpoint can run a finalizer once")
        check(weak.value == nil and clone[2].value == nil, kind .. " finalized unvisited weak value is omitted")
    end)
end
withControlledGC(function()
    local finalized, outerCalls, innerCalls, inside, nested = 0, 0, 0, false
    local method
    method = Refresh.make(_G, function()
        if inside then innerCalls = innerCalls + 1; return end
        outerCalls = outerCalls + 1
        if outerCalls == 1 then collectgarbage("collect") end
    end, 2)
    local dying = newproxy(true)
    getmetatable(dying).__gc = function()
        finalized, inside = finalized + 1, true
        nested = method({10, 20, 30, 40})
        inside = false
    end
    dying = nil
    local clone = method({1, 2, 3, 4, 5, 6})
    check(finalized == 1 and nested[4] == 40 and clone[6] == 6, "GC finalizer can reenter clone")
    check(outerCalls == 3 and innerCalls == 2, "GC finalizer reentry retains separate counters")
end)

print(("PASS clone refresh: %d differential graphs, %d assertions; traversal/checkpoint order, weak GC, finalizers, reentry and errors"):format(cases, checks))
