-- GPL-3.0-or-later. Based on ToME 1.7.6 mod/class/Game.lua.
-- Copyright (C) 2009 - 2019 Nicolas Casalini. See COPYING.
-- Modified 2026-09-13: omit the unused temporary export party.
-- This intentionally removes its callbacks, temporary UID allocation and RNG
-- consumption; it does not preserve the original random sequence after saving.
local M = {}
local installed = setmetatable({}, {__mode = "k"})

local function upstream(f, source, first, last)
    if type(f) ~= "function" then return false end
    local info = debug.getinfo(f, "S")
    return info.source == source and info.linedefined == first and info.lastlinedefined == last
end

function M.installGame(Game, options)
    if options and options.unused_party_cleanup == false then return false, "disabled in faster_tome settings" end
    local original = Game.saveGame
    if installed[original] then return true end
    local wrapper, slot
    -- Cults rejects saves inside S.M.A.C.K. Keep that wrapper intact and only
    -- replace its recognized base-game delegate. Never unwrap arbitrary addons.
    if upstream(original, "@/mod/addons/cults/superload/mod/class/Game.lua", 32, 41) then
        wrapper = original
        for i = 1, 8 do
            local name, value = debug.getupvalue(wrapper, i)
            if not name then break end
            if name == "saveGame" then original, slot = value, i; break end
        end
        if not slot then return false, "unknown Cults save delegate; keeping existing method" end
    end
    if installed[original] then return true end
    if not upstream(original, "@/mod/class/Game.lua", 2854, 2886) then
        return false, "unknown saveGame; keeping existing export preparation"
    end

    local function saveGame(self)
        self:registerHighscore()
        if self.party then
            for actor in pairs(self.party.members) do engine.interface.PlayerHotkeys:updateQuickHotkeys(actor) end
        end
        local clone = savefile_pipe:push(self.save_name, "game", self)
        world:saveWorld()
        if not self.creating_player and config.settings.tome.upload_charsheet then
            local oldplayer = self.player
            self.party:setPlayer(self:getPlayer(true), true)
            _G.game = clone
            print("Saving JSON", pcall(function()
                if not game.player.__no_save_json then game.player:saveUUID(nil) end
            end))
            _G.game = self
            self.party:setPlayer(oldplayer, true)
        end
        self.log("Saving game...")
    end
    setfenv(saveGame, getfenv(original))
    if wrapper then debug.setupvalue(wrapper, slot, saveGame)
    else Game.saveGame = saveGame end
    installed[saveGame] = true
    return true
end

return M
