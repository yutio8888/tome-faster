-- GPL-3.0-or-later. Based on ToME 1.7.6 data/talents/corruptions/shadowflame.lua.
-- Copyright (C) 2009 - 2019 Nicolas Casalini. See COPYING.
-- Modified 2026-09-14: release the target's completed Fearscape capture edge.
local M = {}
local installed = setmetatable({}, {__mode = "k"})
local source = "@/data/talents/corruptions/shadowflame.lua"

local function upstream(f, first, last)
    if type(f) ~= "function" then return false end
    local info = debug.getinfo(f, "S")
    return info.source == source and info.linedefined == first and info.lastlinedefined == last
end

function M.installTalents(Talents, options)
    if options and options.fearscape_cleanup ~= nil and options.fearscape_cleanup ~= true then return false, "fearscape_cleanup disabled" end
    local talent = Talents.talents_def and Talents.talents_def.T_DEMON_PLANE
    if not talent then return false, "Fearscape talent is unavailable" end
    local original, activate = talent.deactivate, talent.activate
    local token = installed[original]
    if token and token == installed[activate] then return true end
    if not upstream(activate, 177, 285) or not upstream(original, 286, 368) then
        return false, "unknown Fearscape activation or exit; keeping existing methods"
    end

    local deactivate
    deactivate = function(self, t, p)
        if not self.on_die then return original(self, t, p) end
        -- Only an observed, stock capture can authorize cleanup. Old detached
        -- references cannot establish that the deferred exit succeeded, so no
        -- loaded()/save() migration or graph scan is installed here.
        local target = type(p) == "table" and p.target
        if t ~= talent or t.activate ~= activate or t.deactivate ~= deactivate
            or type(target) ~= "table" or target.dead
            or not upstream(self.on_die, 255, 263) or not upstream(target.on_die, 245, 252)
            or target.demon_plane_trapper ~= self
        then return original(self, t, p) end
        local current = game
        if type(current) ~= "table" then return original(self, t, p) end
        local plane, zone = current.level, current.zone
        if type(plane) ~= "table" or type(zone) ~= "table" or zone.short_name ~= "demon-plane-spell" or not zone.is_demon_plane
            or plane.plane_owner ~= self or type(plane.source_level) ~= "table" or type(plane.source_zone) ~= "table"
            or plane.source_level == plane or plane.source_zone == zone
        then return original(self, t, p) end

        local destination, destination_zone = plane.source_level, plane.source_zone
        local target_wrapper, caster_wrapper = target.on_die, self.on_die
        local restored = target.demon_plane_on_die

        -- The fixed upstream deactivate body follows, preserving its clone,
        -- particle, movement, death and item callback order. No actor receives
        -- an addon closure; the original activation/death wrappers are intact.
        if not self.on_die then return true end

        if p.particle then self:removeParticles(p.particle) end

        game:onTickEnd(function()
            local eligible = game == current and game.level == plane and game.zone == zone
                and plane.source_level == destination and plane.source_zone == destination_zone
                and plane.plane_owner == self and p.target == target and not target.dead
                and target.demon_plane_trapper == self and target.on_die == target_wrapper
                and self.on_die == caster_wrapper and target.demon_plane_on_die == restored
                and t == talent and t.activate == activate and t.deactivate == deactivate

            -- Collect objects
            local objs = {}
            for i = 0, game.level.map.w - 1 do for j = 0, game.level.map.h - 1 do
                for z = game.level.map:getObjectTotal(i, j), 1, -1 do
                    objs[#objs+1] = game.level.map:getObject(i, j, z)
                    game.level.map:removeObject(i, j, z)
                end
            end end

            local oldzone = game.zone
            local oldlevel = game.level
            local zone = game.level.source_zone
            local level = game.level.source_level

            if not self.dead then
                oldlevel:removeEntity(self, true)
                level:addEntity(self)
            end

            game.zone = zone
            game.level = level
            game.zone_name_s = nil

            local x1, y1 = util.findFreeGrid(p.x, p.y, 20, true, {[Map.ACTOR]=true})
            if x1 then
                if not self.dead then
                    self:move(x1, y1, true)
                    self.on_die, self.demon_plane_on_die = self.demon_plane_on_die, nil
                    game.level.map:particleEmitter(x1, y1, 1, "demon_teleport")
                else
                    self.x, self.y = x1, y1
                end
            end
            local x2, y2 = util.findFreeGrid(p.target_x or p.x, p.target_y or p.y, 20, true, {[Map.ACTOR]=true})
            if not p.target.dead then
                if x2 then
                    p.target:move(x2, y2, true)
                    p.target.on_die, p.target.demon_plane_on_die = p.target.demon_plane_on_die, nil
                    game.level.map:particleEmitter(x2, y2, 1, "demon_teleport")
                end
                if oldlevel:hasEntity(p.target) then oldlevel:removeEntity(p.target, true) end
                level:addEntity(p.target)
            else
                p.target.x, p.target.y = x2, y2
            end

            -- Add objects back
            for i, o in ipairs(objs) do
                if self.dead then
                    game.level.map:addObject(p.target.x, p.target.y, o)
                else
                    game.level.map:addObject(self.x, self.y, o)
                end
            end

            -- Remove all npcs in the fearscape
            for uid, e in pairs(oldlevel.entities) do
                if e ~= self and e ~= p.target and e.die then e:die() end
            end

            -- Reload MOs
            game.level.map:redisplay()
            game.level.map:recreate()
            game.uiset:setupMinimap(game.level)
            game.nicer_tiles:postProcessLevelTilesOnLoad(game.level)

            if game.level.map:checkEntity(game.player.x, game.player.y, Map.TERRAIN, "block_move") then
                -- Emergency teleport in case we somehow end up in a wall
                game.player:teleportRandom(math.floor(game.level.map.w / 2), math.floor(game.level.map.h / 2), 100)
            end

            game.logPlayer(game.player, "#LIGHT_RED#You are brought back from the Fearscape!")

            -- This is reached only after the entire original exit returned
            -- normally. A missing placement or any changed capture stays as-is.
            -- In particular, dead targets use a later original death callback;
            -- leave their edge intact rather than add another deferred callback.
            if eligible and x1 and x2 and game == current and game.level == destination
                and game.zone == destination_zone and p.target == target and not target.dead
                and plane.source_level == destination and plane.source_zone == destination_zone
                and plane.plane_owner == self and target.demon_plane_trapper == self
                and target.on_die == restored and target.demon_plane_on_die == nil
                and type(self.sustain_talents) == "table" and self.sustain_talents[t.id] == nil
                and t == talent and t.activate == activate and t.deactivate == deactivate
            then target.demon_plane_trapper = nil end
        end)

        return true
    end
    talent.deactivate = setfenv(deactivate, getfenv(original))
    -- Tokens contain no functions, environments, talents or actor references.
    token = {}
    installed[deactivate], installed[activate] = token, token
    return true
end

return M
