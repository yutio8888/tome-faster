-- Local diagnostic only. Full snapshot graph comparison with native wait redraws.
-- GC is stopped only across the pair to stabilize weak observations; production
-- and all formal timing sessions retain the original GC behavior.
local M = {}
local function findHelper(method, source, line)
    local seen = {}
    local function visit(f)
        if type(f) ~= "function" or seen[f] then return end
        seen[f] = true
        local info = debug.getinfo(f, "S")
        if info.source == source and (line == nil or info.linedefined == line) then
            local name, recursive = debug.getupvalue(f, 1)
            if (name == "copy" or name == "clonerecursfull") and recursive == f then return f end
        end
        for i=1,30 do
            local name, value = debug.getupvalue(f,i)
            if not name then break end
            local found = visit(value)
            if found then return found end
        end
    end
    return assert(visit(method), "required clone helper not found: "..source)
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
    local baseHelper = findHelper(baseline, "@/engine/class.lua", 236)
    local fastHelper = findHelper(candidate, "@/engine/FasterCloneRefresh.lua", nil)
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

function M.run(game)
    local baseline = require("engine.class").cloneForSave
    local candidate = require("mod.class.Game").cloneForSave
    local R = require "engine.FasterSnapshotRefresh"
    R.enableDiagnostics(true)
    local turn, paused = game.turn, game.paused
    local result = verify(game, baseline, candidate)
    result.refresh = assert(R.getDiagnostics(), "native snapshot refresh did not run")
    assert(not result.refresh.fallback and result.refresh.completed and result.refresh.refreshes > 0,
        "snapshot refresh did not exercise native redraws")
    assert(not result.refresh.redraw_failed and not result.refresh.cleanup_failed, "native wait cleanup failed")
    assert(game.turn == turn and game.paused == paused, "refresh changed game time or paused state")
    assert(debug.gethook() == nil, "native wait hook was not removed")
    result.kind = "snapshot_refresh_equivalence"
    result.gc_policy = "full GC before pair; stopped during graph comparison; restarted afterward"
    print("[FasterSnapshotRefreshCheck] PASS full graph and native wait redraw")
    return result
end
return M
