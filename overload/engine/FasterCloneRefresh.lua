-- GPL-3.0-or-later. Based on ToME 1.7.6 engine/class.lua.
-- Copyright (C) 2009 - 2019 Nicolas Casalini. See COPYING.
-- Synchronous save clone with bounded-entry checkpoints. No coroutine or GC policy.
local M = {}
local DEFAULT_STRIDE = 512

local function makeCopy(environment, stride)
    local function copy(memo, d, checkpoint, remaining)
        if (d.__ATOMIC or d.__CLASSNAME) and d.__SAVEINSTEAD then
            d = d.__SAVEINSTEAD
            -- Preserve upstream's ORIGINAL replacement return, including count.
            if memo[d] then return d, 1, remaining end
        end
        local n, count, add = {}, 0
        memo[d] = n
        local k, v = next(d)
        while k do
            local nk, nv = k, v
            if type(k) == "table" then
                if memo[k] then nk = memo[k]
                else nk, add, remaining = copy(memo, k, checkpoint, remaining); count = count + add end
            end
            if type(v) == "table" then
                if memo[v] then nv = memo[v]
                -- A previously cloned __threads value MUST still use its memo.
                elseif k ~= "__threads" then nv, add, remaining = copy(memo, v, checkpoint, remaining); count = count + add end
            end
            n[nk] = nv
            remaining = remaining - 1
            if remaining == 0 then
                if checkpoint then checkpoint() end
                remaining = stride
            end
            k, v = next(d, k)
        end
        setmetatable(n, getmetatable(d))
        if n.__ATOMIC or n.__CLASSNAME then count = count + 1 end
        return n, count, remaining
    end
    setfenv(copy, environment)
    return copy
end

-- Each invocation carries its own countdown on the recursive Lua stack, so a
-- checkpoint may reenter the method without replacing the outer clone's state.
-- Checkpoints must not mutate the source graph. Extra elapsed time/allocations can
-- change GC/finalizer/weak-table observations; this does not promise time isolation.
function M.make(environment, checkpoint, stride)
    assert(type(environment) == "table", "clone environment must be a table")
    assert(checkpoint == nil or type(checkpoint) == "function", "checkpoint must be a function or nil")
    if stride == nil then stride = DEFAULT_STRIDE end
    assert(type(stride) == "number" and stride >= 1 and stride < math.huge and stride == math.floor(stride),
        "checkpoint stride must be a positive finite integer")
    local copy = makeCopy(environment, stride)
    return function(self)
        local clone, count = copy({}, self, checkpoint, stride)
        return clone, count
    end
end

local defaultCopy = makeCopy(_G, DEFAULT_STRIDE)
function M.cloneForSave(self, checkpoint)
    assert(checkpoint == nil or type(checkpoint) == "function", "checkpoint must be a function or nil")
    local clone, count = defaultCopy({}, self, checkpoint, DEFAULT_STRIDE)
    return clone, count
end

return M
