-- GPL-3.0-or-later. Optional dead-output elimination for ToME 1.7.6.
-- This helper only changes dead JSON output; export preparation is separate.
local M = {}
local installed = setmetatable({}, {__mode = "k"})

local function upstream(f, source, first, last)
    if type(f) ~= "function" then return false end
    local info = debug.getinfo(f, "S")
    return info.source == source and info.linedefined == first and info.lastlinedefined == last
end

local function hasExportHook(player)
    if not upstream(player.triggerHook, "@/engine/class.lua", 430, 434) then return true end
    for i = 1, 8 do
        local name, registry = debug.getupvalue(player.triggerHook, i)
        if not name then break end
        if name == "_hooks" then
            return type(registry) ~= "table" or type(registry.hooks) ~= "table"
                or registry.hooks["ToME:PlayerDumpJSON"] ~= nil
        end
    end
    return true -- Unknown hook registry: retain the complete export path.
end

function M.installPlayer(Player, options)
    if options and options.offline_chardump == false then return false, "disabled in faster_tome settings" end
    if installed[Player] then return true end
    local original = Player.saveUUID
    if not upstream(original, "@/engine/interface/PlayerDumpJSON.lua", 41, 90) then
        return false, "unknown character export method; keeping existing export"
    end
    local environment = getfenv(original)
    function Player:saveUUID(charball, ...)
        local profile, game = environment.profile, environment.game
        -- The stock consumer discards these sheets; it does not queue them for
        -- later login. Existing UUIDs avoid changing late-registration hooks.
        -- Real charball exports and custom exporters always keep their behavior.
        if charball == nil and self.__te4_uuid and profile and game
            and (not profile.auth or not profile.hash_valid)
            and upstream(profile.registerSaveChardump, "@/engine/PlayerProfile.lua", 928, 937)
            and upstream(self.dumpToJSON, "@/mod/class/interface/PlayerDumpJSON.lua", 26, 437)
            and upstream(game.allowJSONDump, "@/mod/class/Game.lua", 2796, 2799)
            and upstream(game.isTainted, "@/mod/class/Game.lua", 197, 200)
            and not hasExportHook(self) then
            return
        end
        return original(self, charball, ...)
    end
    installed[Player] = true
    return true
end

return M
