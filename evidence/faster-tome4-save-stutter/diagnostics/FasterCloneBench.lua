-- Local diagnostic only. Never ship this module with the addon.
-- Compares the entire live snapshot, then measures the uninstrumented methods.
local M = {}

local function encode(v)
    local kind = type(v)
    if kind == "nil" then return "null" end
    if kind == "boolean" or kind == "number" then return tostring(v) end
    if kind == "string" then
        return '"' .. v:gsub('[%z\1-\31\\"]', function(c) return ('\\u%04x'):format(c:byte()) end) .. '"'
    end
    local parts = {}
    if #v > 0 then
        for i = 1, #v do parts[#parts + 1] = encode(v[i]) end
        return "[" .. table.concat(parts, ",") .. "]"
    end
    for k, item in pairs(v) do parts[#parts + 1] = encode(tostring(k)) .. ":" .. encode(item) end
    return "{" .. table.concat(parts, ",") .. "}"
end

local function recursive(method, expected)
    local name, f = debug.getupvalue(method, 1)
    assert(name == expected and type(f) == "function", "unexpected clone helper: " .. tostring(name))
    return f
end

local function capture(method, helper, game)
    local original = getfenv(helper)
    local nativeGet, nativeSet = original.getmetatable, original.setmetatable
    local copies, sources, pending = {}, {}, nil
    local proxy = setmetatable({
        getmetatable = function(source)
            local mt = nativeGet(source)
            assert(pending == nil, "unpaired clone getmetatable")
            pending = source
            return mt
        end,
        setmetatable = function(copy, mt)
            local source = assert(pending, "clone setmetatable without source")
            pending = nil
            assert(copies[source] == nil and sources[copy] == nil, "source copied twice")
            nativeSet(copy, mt)
            copies[source], sources[copy] = copy, source
            return copy
        end,
    }, {__index = original})
    setfenv(helper, proxy)
    local ok, copy, count = pcall(method, game)
    setfenv(helper, original) -- Restore before either returning or raising.
    if not ok then error(copy, 0) end
    assert(pending == nil, "unfinished clone metatable pair")
    return copy, count, copies, sources
end

local function verify(game, baseline, candidate)
    local baseHelper = recursive(baseline, "clonerecursfull")
    local fastHelper = recursive(candidate, "copy")
    local beforeTurn = game.turn
    collectgarbage("collect")
    -- Weak-value maps must not change between the two observations. This pause
    -- applies ONLY to equivalence checking, never to measured samples.
    collectgarbage("stop")
    local ok, result = pcall(function()
        local a, countA, copiesA, sourcesA = capture(baseline, baseHelper, game)
        local b, countB, copiesB = capture(candidate, fastHelper, game)
        assert(countA == countB, "clone object counts differ")
        local function corresponding(value)
            local source = sourcesA[value]
            if source then return assert(copiesB[source], "missing copied source") end
            -- This includes original __threads and __SAVEINSTEAD references.
            return value
        end
        local function equal(x, y)
            return rawequal(x, y) or (type(x) == "number" and type(y) == "number" and x ~= x and y ~= y)
        end
        assert(equal(corresponding(a), b), "snapshot roots differ")
        local tables, entries, originalTableValues = 0, 0, 0
        for source, left in pairs(copiesA) do
            local right = assert(copiesB[source], "candidate omitted a cloned table")
            assert(rawequal(getmetatable(left), getmetatable(right)), "snapshot metatables differ")
            local leftCount, rightCount = 0, 0
            for k, value in pairs(left) do
                local otherKey, otherValue = corresponding(k), corresponding(value)
                assert(equal(rawget(right, otherKey), otherValue), "snapshot key/value/alias mismatch")
                if type(value) == "table" and not sourcesA[value] then originalTableValues = originalTableValues + 1 end
                leftCount = leftCount + 1
            end
            for _ in pairs(right) do rightCount = rightCount + 1 end
            assert(leftCount == rightCount, "candidate has extra snapshot keys")
            tables, entries = tables + 1, entries + leftCount
        end
        local otherTables = 0
        for source in pairs(copiesB) do
            assert(copiesA[source], "candidate copied an extra table")
            otherTables = otherTables + 1
        end
        assert(tables == otherTables, "copied table counts differ")
        assert(game.turn == beforeTurn, "equivalence check advanced game turn")
        return {passed = true, copied_tables = tables, entries = entries,
            counted_objects = countA, original_table_values = originalTableValues, turn_delta = game.turn - beforeTurn}
    end)
    collectgarbage("restart")
    if not ok then error(result, 0) end
    return result
end

local function stats(values)
    local sorted = {}
    for i, value in ipairs(values) do sorted[i] = value end
    table.sort(sorted)
    local n = #sorted
    return {min = sorted[1], median = (sorted[math.floor((n + 1) / 2)] + sorted[math.ceil((n + 1) / 2)]) / 2,
        max = sorted[n]}
end

function M.run(game)
    local baseline = require("engine.class").cloneForSave
    local candidate = require("engine.FasterClone").cloneForSave
    local info = debug.getinfo(baseline, "S")
    assert(info.source == "@/engine/class.lua" and info.linedefined == 362 and info.lastlinedefined == 366,
        "engine.class.cloneForSave is not the pinned baseline")
    local result = {kind = "clone_benchmark", pairs = 10, warmup_pairs = 3,
        baseline_source = info.source, baseline_line = info.linedefined,
        jit = require("jit").version, turn_start = game.turn}
    result.equivalence = verify(game, baseline, candidate)
    print("[FasterCloneBench] " .. encode{kind = "equivalence", result = result.equivalence})

    local ffi = require("ffi")
    if not pcall(ffi.typeof, "struct faster_clone_timespec") then
        ffi.cdef[[struct faster_clone_timespec { long tv_sec; long tv_nsec; };]]
    end
    ffi.cdef[[int clock_gettime(int, void *);]]
    -- Other local profilers declare this symbol with their own timespec name.
    local gettime = ffi.cast("int (*)(int, struct faster_clone_timespec *)", ffi.C.clock_gettime)
    local ts = ffi.new("struct faster_clone_timespec[1]")
    local function clock(id)
        assert(gettime(id, ts) == 0, "clock_gettime failed")
        return tonumber(ts[0].tv_sec) * 1000 + tonumber(ts[0].tv_nsec) / 1e6
    end
    local function sample(method)
        -- Previous snapshots/maps live only in completed calls and are released.
        collectgarbage("collect")
        local heap = collectgarbage("count")
        local wall, cpu = clock(1), clock(3)
        local copy, count = method(game)
        local cpuMs, wallMs = clock(3) - cpu, clock(1) - wall
        local allocation = collectgarbage("count") - heap
        assert(copy ~= game, "snapshot must be a copy")
        copy = nil
        return {wall_ms = wallMs, thread_cpu_ms = cpuMs, counted_objects = count, heap_delta_kib = allocation}
    end
    -- Restore ordinary environments and warm their JIT paths after proxies.
    for _ = 1, result.warmup_pairs do sample(baseline); sample(candidate) end
    local groups = {baseline = {samples = {}}, candidate = {samples = {}}}
    local differences = {}
    result.counts_match = true
    for pair = 1, result.pairs do
        local order = pair % 2 == 1 and {"baseline", "candidate"} or {"candidate", "baseline"}
        for position, name in ipairs(order) do
            local value = sample(name == "baseline" and baseline or candidate)
            value.pair, value.position = pair, position
            groups[name].samples[#groups[name].samples + 1] = value
        end
        local a, b = groups.baseline.samples[pair], groups.candidate.samples[pair]
        if a.counted_objects ~= b.counted_objects then result.counts_match = false end
        differences[pair] = a.wall_ms - b.wall_ms
    end
    for name, group in pairs(groups) do
        for _, field in ipairs{"wall_ms", "thread_cpu_ms", "heap_delta_kib", "counted_objects"} do
            local values = {}
            for _, value in ipairs(group.samples) do values[#values + 1] = value[field] end
            group[field] = stats(values)
        end
        result[name] = group
    end
    result.paired_wall_reduction_ms = stats(differences)
    result.turn_delta = game.turn - result.turn_start
    result.valid = result.counts_match and result.turn_delta == 0
    result.gc = "full collection before each sample excluded; automatic GC enabled during cloning"
    print("[FasterCloneBench] " .. encode(result))
    return result
end

return M
