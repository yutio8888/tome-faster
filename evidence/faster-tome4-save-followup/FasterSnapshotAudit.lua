-- Local read-only diagnostic. Do not install in the release addon.
-- Counts raw table reachability and consumers, never removes a snapshot field.
local M = {}
local candidates = {"uiset", "calendar", "flyers", "tooltip", "target", "dialogs", "key", "mouse", "cults_book_data"}

local function roots(game, omitted)
    local pending = {}
    local k, v = next(game)
    while k ~= nil do
        if k ~= omitted then
            if type(k) == "table" then pending[#pending + 1] = k end
            if type(v) == "table" then pending[#pending + 1] = v end
        end
        k, v = next(game, k)
    end
    return pending
end

local function scan(game, pending, inspect)
    local seen, count, details = {[game] = true}, 0, {weak = 0, raw_saveinstead = 0, threads = 0, opaque_index = 0}
    while #pending > 0 do
        local d = pending[#pending]; pending[#pending] = nil
        if not seen[d] then
            seen[d] = true; count = count + 1
            if inspect then
                local mt = getmetatable(d)
                if type(mt) == "table" then
                    if rawget(mt, "__mode") then details.weak = details.weak + 1 end
                    if type(rawget(mt, "__index")) == "function" then details.opaque_index = details.opaque_index + 1 end
                elseif mt ~= nil then details.opaque_index = details.opaque_index + 1 end
                if rawget(d, "__SAVEINSTEAD") ~= nil then details.raw_saveinstead = details.raw_saveinstead + 1 end
                if rawget(d, "__threads") ~= nil then details.threads = details.threads + 1 end
            end
            local k, v = next(d)
            while k ~= nil do
                if type(k) == "table" and not seen[k] then pending[#pending + 1] = k end
                if type(v) == "table" and not seen[v] then pending[#pending + 1] = v end
                k, v = next(d, k)
            end
        end
    end
    return count, details
end

function M.run(game)
    local count, details = scan(game, roots(game), true)
    local result = {kind = "snapshot_root_audit", raw_tables = count, special_tables = details, candidates = {},
        caveat = "Raw reachability only: no clone mutation, no metamethod invocation, no weak/SAVEINSTEAD/threads equivalence claim"}
    for _, key in ipairs(candidates) do
        local value = rawget(game, key)
        local kept = scan(game, roots(game, key), false)
        local branch = type(value) == "table" and scan(game, {value}, false) or 0
        result.candidates[#result.candidates + 1] = {
            field = key, value_type = type(value), branch_tables = branch, exclusive_raw_tables = count - kept,
        }
    end
    return result
end

return M
