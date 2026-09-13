-- GPL-3.0-or-later. Synchronous snapshot refresh transactions and fallbacks.
local root = arg[1] or "."
local M = assert(loadfile(root .. "/overload/engine/FasterSnapshotRefresh.lua"))()
local Clone = assert(loadfile(root .. "/overload/engine/FasterCloneRefresh.lua"))()
local checks = 0
local function check(ok, message) assert(ok, message); checks = checks + 1 end
local function backend()
    local b = {time = 0, opens = 0, closes = 0, frames = 0, owner = false, allowed = true}
    function b.supported() return b.allowed end
    function b.clock() return b.time end
    function b.begin()
        b.opens, b.owner = b.opens + 1, true
        if b.begin_error then error(b.begin_error, 0) end
        if b.nested then return false end
        return true
    end
    function b.refresh()
        check(b.owner, "redraw within owned wait")
        b.frames = b.frames + 1
        if b.draw_error then error(b.draw_error, 0) end
    end
    function b.finish()
        if b.owner then b.closes = b.closes + 1; b.owner = false end
    end
    return b
end

do
    local b, delegated, copies = backend(), 0, 0
    local original = function(self) delegated = delegated + 1; return self, 29 end
    local runner = M.makeRunner(original, function(checkpoint)
        return function(self)
            copies = copies + 1
            local copy = {value = self.value}
            for _ = 1, 100 do b.time = b.time + 1; checkpoint() end
            return copy, 7
        end
    end, b)
    M.enableDiagnostics(true)
    local source = {value = 42}
    local copy, count = runner(source)
    check(copy ~= source and copy.value == 42 and count == 7, "returns clone and count")
    check(b.frames == 6 and b.opens == 1 and b.closes == 1 and not b.owner, "16ms refresh budget and balanced wait")
    check(delegated == 0 and copies == 1, "no duplicate clone")
    local s = M.getDiagnostics()
    check(s.completed and s.checkpoints == 100 and s.refreshes == 6 and s.max_copy_interval_ms == 16, "diagnostic counts")
    s.refreshes = -1
    check(M.getDiagnostics().refreshes == 6, "diagnostics do not expose internal table")
    check(select("#", runner(source)) == 2, "exact return arity")
    b.allowed = false
    copy, count = runner(source)
    check(copy == source and count == 29 and delegated == 1 and copies == 2 and b.opens == 2, "unsupported path delegates directly")
    b.allowed, b.nested = true, true
    copy, count = runner(source)
    check(copy == source and delegated == 2 and b.opens == b.closes and not b.owner, "nested wait is balanced before fallback")
    b.nested, b.begin_error = false, {}
    copy, count = runner(source)
    check(copy == source and delegated == 3 and b.opens == b.closes and not b.owner, "setup failure cleans up before original clone")
end

do
    local b, failure, calls = backend(), {}, 0
    local runner = M.makeRunner(function() error("unexpected fallback") end, function(checkpoint)
        return function()
            calls = calls + 1
            b.time = b.time + 20; checkpoint()
            if calls == 1 then error(failure, 0) end
            return {}, 5
        end
    end, b)
    local ok, err = pcall(runner, {})
    check(not ok and err == failure and b.opens == b.closes and not b.owner, "clone error identity and cleanup")
    local copy, count = runner({})
    check(type(copy) == "table" and count == 5 and calls == 2, "retry enters a fresh transaction")
    check(b.opens == b.closes and not b.owner, "retry restores wait")
end

do
    local b, copy_calls = backend(), 0
    b.draw_error = {}
    local runner = M.makeRunner(function() error("must not restart clone") end, function(checkpoint)
        return function()
            copy_calls = copy_calls + 1
            for _ = 1, 10 do b.time = b.time + 20; checkpoint() end
            return {finished = true}, 3
        end
    end, b)
    M.enableDiagnostics(true)
    local copy, count = runner({})
    check(copy.finished and count == 3 and copy_calls == 1, "optional redraw failure continues the same clone")
    check(b.frames == 1 and b.closes == 1 and not b.owner, "redraw failure disables further redraws and balances wait")
    check(M.getDiagnostics().redraw_failed and M.getDiagnostics().completed, "redraw failure reported separately")
end

do
    local b, nested_calls, runner = backend(), 0
    runner = M.makeRunner(function(self) nested_calls = nested_calls + 1; return {original = self}, 11 end,
        function(checkpoint)
            return function(self)
                b.time = b.time + 20; checkpoint()
                local nested, count = runner(self)
                check(count == 11 and nested.original == self, "reentrant clone delegates without wait manipulation")
                return {done = true}, 8
            end
        end, b)
    local copy, count = runner({})
    check(copy.done and count == 8 and nested_calls == 1, "outer return remains intact after reentry")
    check(b.opens == 1 and b.closes == 1, "single wait owner under reentry")
end

do
    local b, source = backend(), {label = "source"}
    source.self, source.child = source, {__CLASSNAME = "Child"}
    source.alias, source[source.child] = source.child, source
    local mt = {__index = function(t, key)
        if key == "__ATOMIC" then b.time = b.time + 17 end
    end}
    setmetatable(source.child, mt)
    local clone_runner = M.makeRunner(Clone.cloneForSave, function(checkpoint) return Clone.make(_G, checkpoint, 1) end, b)
    local copy, count = clone_runner(source)
    check(copy.self == copy and copy.child == copy.alias and copy[copy.child] == copy, "actual recursive clone preserves graph aliases")
    check(getmetatable(copy.child) == mt and count == 1 and b.frames > 0, "actual clone metadata and checkpoint integration")
    check(source.self == source and source.alias == source.child and source[source.child] == source, "source graph unchanged")
    check(b.opens == b.closes, "actual clone closes native wait boundary")
end

M.enableDiagnostics(false)
check(M.getDiagnostics() == nil, "diagnostics disabled and cleared")
print(("PASS snapshot refresh: %d checks; synchronous ownership, returns, failures, reentry and graph integrity"):format(checks))
