-- GPL-3.0-or-later. Added 2026-09-12 by the Faster ToME4 fork maintainers.
-- Based on ToME 1.7.6, Copyright (C) 2009 - 2019 Nicolas Casalini.
-- See COPYING. No warranty; retain this notice in modified versions.

local M = {}
local installed = setmetatable({}, {__mode = "k"})

-- The optimizations rely on these particular upstream method bodies. Leave
-- unknown overrides and other source layouts alone, rather than replace them.
local function upstream(f, source, first, last)
    if type(f) ~= "function" then return false end
    local info = debug.getinfo(f, "S")
    return info.source == source and info.linedefined == first and info.lastlinedefined == last
end

function M.installGame(Game, options)
    if options and options.save_coalescing == false then return false, "disabled in faster_tome settings" end
    if installed[Game] then return true end
    if not upstream(Game.onSavefilePushed, "@/mod/class/Game.lua", 2818, 2821)
        or not upstream(Game.onTickEnd, "@/engine/Game.lua", 342, 353)
        or not upstream(Game.onTickEndExecute, "@/engine/Game.lua", 321, 337) then
        return false, "unknown save callback or tick scheduler; keeping existing methods"
    end
    local original = Game.onSavefilePushed
    local environment = getfenv(original)
    -- Key by the actual callback array. The engine swaps that array BEFORE
    -- running a batch, so a request made by a callback belongs to the next batch.
    -- Values must not capture keys: Lua 5.1 weak tables are not ephemerons.
    local latest = setmetatable({}, {__mode = "k"})
    function Game:onSavefilePushed(savename, kind, object, saveclass)
        if environment.config.settings.cheat then return end
        if kind ~= "zone" and kind ~= "level" then return end
        local queue
        local token = {}
        self:onTickEnd(function()
            if latest[queue] ~= token then return end
            latest[queue] = nil
            self:saveGame()
        end)
        queue = (self.on_tick_end_custom or self.on_tick_end).fcts
        latest[queue] = token
    end
    installed[Game] = true
    return true
end

function M.installSavefile(Savefile, options)
    if options and options.load_queue == false then return false, "disabled in faster_tome settings" end
    if installed[Savefile] then return true end
    if not upstream(Savefile.addDelayLoad, "@/engine/Savefile.lua", 121, 124)
        or not upstream(Savefile.loadReal, "@/engine/Savefile.lua", 465, 493) then
        return false, "unknown load method; keeping existing delay queue"
    end
    local add, load = Savefile.addDelayLoad, Savefile.loadReal
    -- Savefile is already loaded before addon superloads are registered. This
    -- installer is called from hooks/load.lua on the cached class itself.
    local active = setmetatable({}, {__mode = "k"})
    function Savefile:addDelayLoad(object)
        local batch = active[self]
        if not batch or self.delayLoad ~= batch.queue then
            return add(self, object)
        end
        batch.items[#batch.items + 1] = object
    end
    function Savefile:loadReal(name)
        if active[self] or type(self.delayLoad) ~= "table" or getmetatable(self.delayLoad) then
            return load(self, name)
        end
        local batch = {queue = self.delayLoad, items = {}}
        active[self] = batch
        local ok, result = pcall(load, self, name)
        active[self] = nil
        local queue, items = batch.queue, batch.items
        local count = #items
        -- Preserve the public array identity and head-insertion order. Pinned
        -- loadWorld/Game/Zone/Level/Entity consume it only AFTER loadReal returns.
        -- Materialize on errors as well, preserving queued warning callbacks.
        if count > 0 then
            for i = #queue, 1, -1 do queue[i + count] = queue[i] end
            for i = 1, count do queue[i] = items[count - i + 1] end
        end
        if not ok then error(result, 0) end
        return result
    end
    installed[Savefile] = true
    return true
end

return M
