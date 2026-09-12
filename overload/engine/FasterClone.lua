-- GPL-3.0-or-later. Based on ToME 1.7.6 engine/class.lua.
-- Copyright (C) 2009 - 2019 Nicolas Casalini. See COPYING.
-- Modified 2026-09-12: avoid memo lookups for non-table keys and values.
local M = {}
local installed = setmetatable({}, {__mode = "k"})

local function makeClone(environment)
    local function copy(memo, d)
        if (d.__ATOMIC or d.__CLASSNAME) and d.__SAVEINSTEAD then
            d = d.__SAVEINSTEAD
            -- Preserve upstream's ORIGINAL replacement return, including count.
            if memo[d] then return d, 1 end
        end
        local n, count, add = {}, 0
        memo[d] = n
        local k, v = next(d)
        while k do
            local nk, nv = k, v
            if type(k) == "table" then
                if memo[k] then nk = memo[k]
                else nk, add = copy(memo, k); count = count + add end
            end
            if type(v) == "table" then
                if memo[v] then nv = memo[v]
                -- A previously cloned __threads value MUST still use its memo.
                elseif k ~= "__threads" then nv, add = copy(memo, v); count = count + add end
            end
            n[nk] = nv
            k, v = next(d, k)
        end
        setmetatable(n, getmetatable(d))
        if n.__ATOMIC or n.__CLASSNAME then count = count + 1 end
        return n, count
    end
    setfenv(copy, environment)
    return function(self) return copy({}, self) end
end

-- Direct entry for isolated real-save benchmarks; does not install anything.
M.cloneForSave = makeClone(_G)

local function upstream(f, first, last)
    if type(f) ~= "function" then return false end
    local info = debug.getinfo(f, "S")
    return info.source == "@/engine/class.lua" and info.linedefined == first and info.lastlinedefined == last
end

function M.installGame(Game, options)
    if options and options.save_clone == false then return false, "disabled in faster_tome settings" end
    local original = Game.cloneForSave
    if installed[original] then return true end
    if not upstream(original, 362, 366) then return false, "unknown cloneForSave; keeping existing method" end
    local name, recursive = debug.getupvalue(original, 1)
    if name ~= "clonerecursfull" or not upstream(recursive, 236, 265) then
        return false, "unknown recursive clone; keeping existing method"
    end
    local method = makeClone(getfenv(recursive))
    Game.cloneForSave = method
    installed[method] = true
    return true
end

return M
