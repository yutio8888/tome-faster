-- ToME - Tales of Maj'Eyal / T-Engine4
-- Copyright (C) 2009 - 2019 Nicolas Casalini
-- GPL-3.0-or-later; see COPYING. No warranty.
-- Modified 2026-09-13 by the Faster ToME4 fork maintainers.
-- Engine target: 1.7.6 commit 624a67329fe2ad440c5b344785a9c73fcf22ae63.

local M = {}
local HEAP_THRESHOLD = 64
local installed = setmetatable({}, {__mode = "k"})
local function upstream(f, path, first, last)
    if type(f) ~= "function" then return false end
    local info = debug.getinfo(f, "S")
    return info.source == path and info.linedefined == first and info.lastlinedefined == last
end

-- An indexed heap supplements, but never replaces, the original open table.
-- In particular, heap order must NOT decide between equal f_scores.
local function repair(heap, positions, scores, node)
    local i = positions[node]
    if not i then i = #heap + 1; heap[i] = node end
    local score = scores[node]
    while i > 1 do
        local parent = math.floor(i / 2)
        local other = heap[parent]
        if not (score < scores[other]) then break end
        heap[i], positions[other] = other, i
        i = parent
    end
    local size = #heap
    while i * 2 <= size do
        local child = i * 2
        if child < size and scores[heap[child + 1]] < scores[heap[child]] then child = child + 1 end
        local other = heap[child]
        if not (scores[other] < score) then break end
        heap[i], positions[other] = other, i
        i = child
    end
    heap[i], positions[node] = node, i
end

local function remove(heap, positions, scores, node)
    local i, size = positions[node], #heap
    local last = heap[size]
    heap[size], positions[node] = nil, nil
    if i < size then
        heap[i], positions[last] = last, i
        repair(heap, positions, scores, last)
    end
end

local function makeCalc(Map, adjacent, isHex, builtin_pairs, options)
    return function(self, sx, sy, tx, ty, use_has_seen, heuristic, add_check, forbid_diagonals)
        local heur = heuristic or self.heuristicCloserPath
        local w, h = self.map.w, self.map.h
        local start = self:toSingle(sx, sy)
        local stop = self:toSingle(tx, ty)
        local open = {[start]=true}
        local open_count = 1
        local closed = {}
        local g_score = {[start] = 0}
        -- h_score only fed f_score in upstream. Drop its table, but keep BOTH
        -- initial heuristic calls (custom heuristics may advance RNG/state).
        heur(self, sx, sy, sx, sy, tx, ty)
        local f_score = {[start] = heur(self, sx, sy, sx, sy, tx, ty)}
        local came_from = {}
        local heap, positions
        local heap_allowed = options.heap
        local offsets

        local function changed(node)
            if heap then
                -- NaN is unordered: continue with the original scan if a custom
                -- heuristic produces it. Never replay callbacks to fall back.
                if f_score[node] ~= f_score[node] then heap, heap_allowed = nil, false
                else repair(heap, positions, f_score, node) end
            end
        end

        local cache = self.map._fovcache.path_caches[self.actor:getPathString()]
        local checkPos
        if cache then
            if not (self.map:isBound(tx, ty) and ((use_has_seen and not self.map.has_seens(tx, ty)) or not cache:get(tx, ty))) then
                print("Astar fail: destination unreachable")
                return nil
            end
            checkPos = function(node, nx, ny)
                local nnode = self:toSingle(nx, ny)
                if not closed[nnode] and self.map:isBound(nx, ny) and ((use_has_seen and not self.map.has_seens(nx, ny)) or not cache:get(nx, ny)) and (not add_check or add_check(nx, ny)) then
                    local tent_g_score = g_score[node] + 1
                    local tent_is_better = false
                    if not open[nnode] then open[nnode] = true; open_count = open_count + 1; tent_is_better = true
                    elseif tent_g_score < g_score[nnode] then tent_is_better = true
                    end
                    if tent_is_better then
                        came_from[nnode] = node
                        g_score[nnode] = tent_g_score
                        local estimate = heur(self, sx, sy, tx, ty, nx, ny)
                        f_score[nnode] = g_score[nnode] + estimate
                        changed(nnode)
                    end
                end
            end
        else
            if not (self.map:isBound(tx, ty) and ((use_has_seen and not self.map.has_seens(tx, ty)) or not self.map:checkEntity(tx, ty, Map.TERRAIN, "block_move", self.actor, nil, true))) then
                print("Astar fail: destination unreachable")
                return nil
            end
            checkPos = function(node, nx, ny)
                local nnode = self:toSingle(nx, ny)
                if not closed[nnode] and self.map:isBound(nx, ny) and ((use_has_seen and not self.map.has_seens(nx, ny)) or not self.map:checkEntity(nx, ny, Map.TERRAIN, "block_move", self.actor, nil, true)) and (not add_check or add_check(nx, ny)) then
                    local tent_g_score = g_score[node] + 1
                    local tent_is_better = false
                    if not open[nnode] then open[nnode] = true; open_count = open_count + 1; tent_is_better = true
                    elseif tent_g_score < g_score[nnode] then tent_is_better = true
                    end
                    if tent_is_better then
                        came_from[nnode] = node
                        g_score[nnode] = tent_g_score
                        local estimate = heur(self, sx, sy, tx, ty, nx, ny)
                        f_score[nnode] = g_score[nnode] + estimate
                        changed(nnode)
                    end
                end
            end
        end

        while next(open) do
            -- Short searches are cheaper without heap bookkeeping. Build once
            -- a larger frontier justifies it; retain the same open table.
            if not heap and heap_allowed and open_count >= HEAP_THRESHOLD then
                heap, positions = {}, {}
                for n in next, open do
                    if f_score[n] ~= f_score[n] then heap, heap_allowed = nil, false; break end
                    repair(heap, positions, f_score, n)
                end
            end
            local node, lowest = nil, 999999999999999
            if heap and f_score[heap[1]] < lowest then
                node, lowest = heap[1], f_score[heap[1]]
                -- Any duplicate minimum has a parent with the same score, so
                -- it is sufficient to inspect the root's two children.
                if heap[2] and f_score[heap[2]] == lowest or heap[3] and f_score[heap[3]] == lowest then
                    node = next(open)
                    while f_score[node] ~= lowest do node = next(open, node) end
                end
            else
                -- Preserve the upstream sentinel and unordered-score behavior.
                local n = next(open)
                while n do
                    if f_score[n] < lowest then node = n; lowest = f_score[n] end
                    n = next(open, n)
                end
            end

            if node == stop then return self:createPath(came_from, stop) end

            open[node] = nil
            open_count = open_count - 1
            closed[node] = true
            if heap then remove(heap, positions, f_score, node) end
            local x, y = self:toDouble(node)

            if adjacent and util.adjacentCoords == adjacent and util.isHex == isHex and pairs == builtin_pairs and not isHex()
                and type(x) == "number" and type(y) == "number" and x % 1 == 0 and y % 1 == 0
                and x > -2147483648 and x < 2147483648 and y > -2147483648 and y < 2147483648 then
                if not offsets then
                    offsets = {}
                    -- Derive the VM's actual pairs order; do not hard-code a
                    -- direction order. No coordinates or paths survive calc.
                    for _, coord in pairs(adjacent(x, y, forbid_diagonals)) do
                        offsets[#offsets + 1] = coord[1] - x
                        offsets[#offsets + 1] = coord[2] - y
                    end
                end
                for i = 1, #offsets, 2 do checkPos(node, x + offsets[i], y + offsets[i + 1]) end
            else
                -- Hex grids and custom helpers retain their live behavior,
                -- including helpers changed by add_check during the search.
                for _, coord in pairs(util.adjacentCoords(x, y, forbid_diagonals)) do
                    checkPos(node, coord[1], coord[2])
                end
            end
        end
    end
end

function M.installAstar(Astar, options)
    options = options or {}
    if options.ai_astar == false then return false, "disabled" end
    if installed[Astar] and Astar.calc == installed[Astar] then return true end
    if not upstream(Astar.calc, "@/engine/Astar.lua", 113, 193) then return false, "unknown Astar.calc" end
    local original = Astar.calc
    local environment = getfenv(original)
    local Map
    for i = 1, math.huge do
        local name, value = debug.getupvalue(original, i)
        if not name then break end
        if name == "Map" then Map = value; break end
    end
    if not Map then return false, "missing Map upvalue" end
    local utility = environment.util
    local adjacent, isHex
    if options.ai_astar_neighbors ~= false and utility
        and upstream(utility.adjacentCoords, "@/engine/utils.lua", 2355, 2377)
        and upstream(utility.isHex, "@/engine/utils.lua", 2294, 2296)
        and type(environment.pairs) == "function" and debug.getinfo(environment.pairs, "S").what == "C" then
        adjacent, isHex = utility.adjacentCoords, utility.isHex
    end
    local replacement = makeCalc(Map, adjacent, isHex, environment.pairs, {heap = options.ai_astar_heap ~= false})
    Astar.calc = setfenv(replacement, environment)
    installed[Astar] = replacement
    return true
end

return M
