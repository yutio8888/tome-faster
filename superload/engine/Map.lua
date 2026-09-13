-- ToME - Tales of Maj'Eyal:
-- Copyright (C) 2009 - 2019 Nicolas Casalini
--
-- This program is free software: you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation, either version 3 of the License, or
-- (at your option) any later version.
--
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU General Public License for more details.
--
-- You should have received a copy of the GNU General Public License
-- along with this program.  If not, see <http://www.gnu.org/licenses/>.
--
-- Nicolas Casalini "DarkGod"
-- darkgod@te4.org

-- Modified 2026-09-13: bounded caches and ranged-hit warning rate limiting.

local Map = loadPrevious(...)
local interval = (config.settings.faster_tome or {}).hit_warning_interval_ms
local clock = core and core.game and core.game.getTime
local tick_period = 4294967296 -- SDL_GetTicks returns unsigned 32-bit milliseconds.
if type(interval) ~= "number" or interval ~= interval or interval < 0 or interval >= tick_period then
    interval = 500
end
if interval > 0 and type(clock) == "function" and type(Map.particleEmitter) == "function" then
    local emit = Map.particleEmitter
    -- Keep transient timestamps outside the saved Map; values cannot retain owners.
    local last_warning = setmetatable({}, {__mode = "k"})
    function Map:particleEmitter(...)
        if select(4, ...) == "hit_warning" then
            local now = clock()
            if type(now) == "number" and now >= 0 and now < tick_period then
                local last = last_warning[self]
                if last and (now - last) % tick_period < interval then return end
                last_warning[self] = now
            end
        end
        return emit(self, ...)
    end
end
if not require("engine.FasterRuntime").installMap(Map, config.settings.faster_tome) then
    print("[Faster ToME4] Map source cache skipped (disabled or unknown override)")
end
if not require("engine.FasterEffectMask").install(Map, config.settings.faster_tome) then
    print("[Faster ToME4] Map effect mask batching skipped (disabled or unknown override)")
end
return Map
