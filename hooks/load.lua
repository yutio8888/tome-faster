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

-- Modified 2026-09-12: bounded caches and compatibility fixes.

-- Each method keeps its own loader and original environment. Cache bytecode,
-- not environment-bearing closures: every request gets a fresh function.
local function cacheLoader(method)
    local original = getfenv(method)
    local loader = original.loadfile
    local cache, order, next_slot = {}, {}, 1
    local function cachedLoadfile(path, ...)
        local config = original.config
        if (config and config.settings and config.settings.cheat) or
            type(path) ~= "string" or select("#", ...) ~= 0 then
            cache, order, next_slot = {}, {}, 1
            return loader(path, ...)
        end
        local entry = cache[path]
        if entry then
            local f = assert(loadstring(entry.code, "@" .. path))
            setfenv(f, entry.environment)
            return f, unpack(entry.extra, 1, entry.extra.n)
        end
        local function pack(...) return {n = select("#", ...), ...} end
        local result = pack(loader(path))
        if type(result[1]) == "function" then
            -- A custom loader may return a closure with upvalues. Dumping would
            -- lose those values, so leave such loaders entirely uncached.
            local ok, code = pcall(string.dump, result[1])
            if ok and not debug.getupvalue(result[1], 1) then
                local extra = {n = result.n - 1}
                for i = 2, result.n do extra[i - 1] = result[i] end
                if order[next_slot] then cache[order[next_slot]] = nil end
                cache[path] = {code = code, environment = getfenv(result[1]), extra = extra}
                order[next_slot] = path
                next_slot = next_slot % 256 + 1
            end
        end
        return unpack(result, 1, result.n)
    end
    return setfenv(method, setmetatable({loadfile = cachedLoadfile}, {__index = original}))
end

local Particles = require "engine.Particles"
local Shader = require "engine.Shader"
Particles.loaded = cacheLoader(Particles.loaded)
Shader.loaded = cacheLoader(Shader.loaded)

local CacheList = require "engine.CacheList"
local printlog = CacheList.new(5000)
local oprint, oget_printlog, otruncate_printlog = print, get_printlog, truncate_printlog
-- The pinned getter returns its buffer directly. Drain only newly logged
-- entries; do not re-stringify arguments or enumerate the ring per print.
local function drain()
    local pending = oget_printlog()
    if #pending > 0 then
        printlog:append(pending)
        otruncate_printlog(0)
    end
end
drain() -- Include the backlog accumulated before this addon loaded.
_G.print = function(...)
    oprint(...)
    drain()
end
_G.get_printlog = function()
    drain() -- Also recover entries if the original stdout function raised.
    return printlog:enumerate()
end
_G.truncate_printlog = function(nb)
    drain()
    printlog:truncate(nb)
end

-- Savefile is required by engine.Module before addon superloads are installed.
local ok, reason = require("engine.FasterSave").installSavefile(require "engine.Savefile", config.settings.faster_tome)
if not ok then print("[Faster ToME4] Load queue optimization skipped:", reason) end

-- DLC weights are 2/3/10; Faster's 100000 registers this after their loaders.
class:bindHook("ToME:load", function()
    local Runtime = require "engine.FasterRuntime"
    -- Also cover an engine.Map required before addon superloads were registered.
    Runtime.installMap(require "engine.Map", config.settings.faster_tome)
    Runtime.installTalents(require "engine.interface.ActorTalents", config.settings.faster_tome)
end)

-- Explicit opt-in only. Game superload attaches once that class becomes available.
if config.settings.faster_tome and config.settings.faster_tome.profile then
    require('engine.FasterProfile').start()
end
