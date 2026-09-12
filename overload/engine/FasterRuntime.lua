-- ToME - Tales of Maj'Eyal / T-Engine4
-- Copyright (C) 2009 - 2019 Nicolas Casalini
-- GPL-3.0-or-later; see COPYING. No warranty.
-- Modified 2026-09-12 by the Faster ToME4 fork maintainers.
-- Engine target: 1.7.6 commit 624a67329fe2ad440c5b344785a9c73fcf22ae63.
-- DLC provenance and guarded source boundaries: docs/runtime-review.md.

local M = {}
local function upstream(f, path, first, last)
    if type(f) ~= "function" then return false end
    local info = debug.getinfo(f, "S")
    return info.source == path and info.linedefined == first and info.lastlinedefined == last
end

local sources = setmetatable({}, {__mode = "k"})
local SOURCE = {}
local function buildSource(layers)
    local pieces = {[[return function(self, x, y, what, ...) local p local m = self.map[x + y * self.w] ]]}
    local format = [[if m[%s] then p = m[%s]:check(what, x, y, ...) if p then return p end end ]]
    for i = 1, #layers do pieces[#pieces + 1] = format:format(layers[i], layers[i]) end
    pieces[#pieces + 1] = [[end]]
    return table.concat(pieces)
end

local function checkerSource(map, layers)
    -- Cache syntax only, never entities, check results or compiled functions.
    -- Bounded to 128 layouts with at most 32 layers each; unknown keys bypass.
    if #layers > 32 then return buildSource(layers) end
    for i = 1, #layers do
        if type(layers[i]) ~= "number" or layers[i] ~= layers[i] then return buildSource(layers) end
    end
    local state = sources[map]
    if not state then state = {root = {}, count = 0}; sources[map] = state end
    local node = state.root
    for i = 1, #layers do
        local key = layers[i]
        if not node[key] then node[key] = {} end
        node = node[key]
    end
    if node[SOURCE] then return node[SOURCE] end
    if state.count >= 128 then
        sources[map] = nil
        return checkerSource(map, layers)
    end
    local code = buildSource(layers)
    node[SOURCE] = code
    state.count = state.count + 1
    return code
end

local function updateMap(self, x, y)
    if not x or not y or x < 0 or y < 0 or x >= self.w or y >= self.h then return end

    -- Update minimap if any
    local mos = {}

    self._map:setImportant(x, y, false)
    if not self.updateMapDisplay then
        local g = self(x, y, TERRAIN)
        local o = self(x, y, OBJECT)
        local a = self(x, y, ACTOR)
        local t = self(x, y, TRAP)
        local p = self(x, y, PROJECTILE)

        if g then
            -- Update path caches from path strings
            for i = 1, #self.path_strings do
                local ps = self.path_strings[i]
                self._fovcache.path_caches[ps]:set(x, y, g:check("block_move", x, y, self.path_strings_computed[ps] or ps, false, true))
            end

            g:getMapObjects(self.tiles, mos, 1)
            g:setupMinimapInfo(g._mo, self)
        end
        if t then
            -- Handles trap being known
            if not self.actor_player or t:knownBy(self.actor_player) then
                t:getMapObjects(self.tiles, mos, 4)
                t:setupMinimapInfo(t._mo, self)
            else
                t = nil
            end
        end
        if o then
            o:getMapObjects(self.tiles, mos, 7)
            o:setupMinimapInfo(o._mo, self)
            if self.object_stack_count then
                local mo = o:getMapStackMO(self, x, y)
                if mo then mos[9] = mo end
            end
        end
        if a then
            -- Handles invisibility and telepathy and other such things
            if not self.actor_player or self.actor_player:canSee(a) then
                a:getMapObjects(self.tiles, mos, 10)
                a:setupMinimapInfo(a._mo, self)

--              self._map:setImportant(x, y, true)
            end
        end
        if p then
            p:getMapObjects(self.tiles, mos, 13)
            p:setupMinimapInfo(p._mo, self)
        end
    else
        self:updateMapDisplay(x, y, mos)
    end

    -- Update entities checker for this spot
    -- This is to improve speed, we create a function for each spot that checks entities it knows are there
    -- This avoid a costly for iteration over a pairs() and this allows luajit to compile only code that is needed
    local sort = {}
    for idx, e in pairs(self.map[x + y * self.w]) do sort[#sort+1] = idx end
    table.sort(sort, searchOrderSort)
    local ce = checkerSource(self, sort)
    self._check_entities[x + y * self.w] = self._check_entities_store[ce] or loadstring(ce)()
    self._check_entities_store[ce] = self._check_entities[x + y * self.w]

    -- Cache the map objects in the C map
    self._map:setGrid(x, y, mos)

    -- Update FOV caches
    if self:checkAllEntities(x, y, "block_sight", self.actor_player) then self._fovcache.block_sight:set(x, y, true)
    else self._fovcache.block_sight:set(x, y, false) end
    if self:checkAllEntities(x, y, "block_esp", self.actor_player) then self._fovcache.block_esp:set(x, y, true)
    else self._fovcache.block_esp:set(x, y, false) end
    if self:checkAllEntities(x, y, "block_sense", self.actor_player) then self._fovcache.block_sense:set(x, y, true)
    else self._fovcache.block_sense:set(x, y, false) end
end

local function infernoNexus(self, t)
    local tg = {type="ball", nolock=true, range=0, radius = 10, friendlyfire=false}
    self:project(tg, self.x, self.y, function(px, py)
        local target = game.level.map(px, py, engine.Map.ACTOR)
        if not target then return end
        if target:hasEffect(target.EFF_CURSED_FLAMES) then
            if rng.percent(50) then
                self:project({type="ball", range=0, radius = 1, friendlyfire=false, x=target.x, y=target.y}, target.x, target.y, function(px, py)
                    local target2 = game.level.map(px, py, engine.Map.ACTOR)
                    if not target2 then return end
                    if target2.turn_procs.doombringer_burnt then return end
                    if target2:hasEffect(target.EFF_CURSED_FLAMES) then return end
                    target2.turn_procs.doombringer_burnt = true
                    DamageType:get(DamageType.FIREBURN).projector(self, target2.x, target2.y, DamageType.FIRE, t.getDam(self,t))
                    game:onTickEnd(function() target2:setEffect(self.EFF_CURSED_FLAMES, 100, {heal=t.getHeal(self, t), vim=t.getVim(self, t), src=self}) end)
                end)
            end
        end
    end)
    return true
end

function M.installMap(Map, options)
    if options and options.map_checker_source == false then return false end
    if Map.updateMap == updateMap then return true end
    if not upstream(Map.updateMap, "@/engine/Map.lua", 469, 551) then return false end
    Map.updateMap = setfenv(updateMap, getfenv(Map.updateMap))
    return true
end

function M.installTalents(Talents, options)
    options = options or {}
    local installed = {}
    local inferno = Talents.talents_def.T_INFERNO_NEXUS
    if options.inferno_nexus ~= false and inferno and upstream(inferno.callbackOnActBase,
        "@/data-ashes-urhrok/talents/corruptions/heart-of-fire.lua", 116, 141) then
        inferno.callbackOnActBase = setfenv(infernoNexus, getfenv(inferno.callbackOnActBase))
        installed.inferno_nexus = true
    end
    return installed
end

return M
