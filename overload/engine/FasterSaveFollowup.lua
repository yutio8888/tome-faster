-- GPL-3.0-or-later. Based on ToME 1.7.6 engine/class.lua.
-- Copyright (C) 2009 - 2019 Nicolas Casalini. See COPYING.
-- Modified 2026-09-13: reuse native serializer callbacks within a Savefile.
local M = {}
local installed = setmetatable({}, {__mode = "k"})
local diagnostics

local function makeSave(environment, original, serialNew)
    -- Both sides must be weak: each pair closes over its Savefile. In Lua 5.1
    -- weak keys alone would keep that Savefile alive through the value.
    local callbacks = setmetatable({}, {__mode = "kv"})
    local function save(self, filter, allow)
        local stats = diagnostics
        if stats then stats.calls = stats.calls + 1 end
        -- Late instrumentation and replacement serializers retain their exact
        -- callback identity/lifetime contract by using the original method.
        if core.serial.new ~= serialNew then
            if stats then stats.fallbacks = stats.fallbacks + 1 end
            return original(self, filter, allow)
        end
        filter = filter or {}
        if self._no_save_fields then table.merge(filter, self._no_save_fields) end
        if not allow then
            filter.new = true
            filter._no_save_fields = true
            filter._mo = true
            filter._last_mo = true
            filter._mo_final = true
            filter._hooks = true
        else
            filter.__CLASSNAME = true
        end
        local mt = getmetatable(self)
        setmetatable(self, {})
        local savefile = engine.Savefile.current_save
        local pair = callbacks[savefile]
        if not pair then
            if stats then stats.callback_pairs = stats.callback_pairs + 1 end
            pair = {}
            -- The native userdata keeps both callbacks, and therefore this
            -- pair and the Savefile, alive until its original __gc runs.
            pair.name = function(t)
                local keepalive = pair
                return savefile:getFileName(t)
            end
            pair.add = function(t)
                local keepalive = pair
                savefile:addToProcess(t)
            end
            callbacks[savefile] = pair
        end
        if stats then stats.optimized = stats.optimized + 1 end
        local s = core.serial.new(
            savefile.current_save_zip,
            pair.name,
            pair.add,
            allow and filter or nil,
            not allow and filter or nil,
            self._no_save_fields
        )
        s:toZip(self)
        setmetatable(self, mt)
    end
    return setfenv(save, environment)
end

function M.installClass(Class, options)
    if options and options.save_callbacks == false then return false, "disabled in faster_tome settings" end
    local original = Class.save
    if installed[original] then return true end
    if type(original) ~= "function" then return false, "unknown class.save" end
    local info = debug.getinfo(original, "Su")
    if info.source ~= "@/engine/class.lua" or info.linedefined ~= 443
        or info.lastlinedefined ~= 477 or info.nups ~= 0 then
        return false, "unknown class.save; keeping original serializer callbacks"
    end
    local environment = getfenv(original)
    local factory = environment.core and environment.core.serial and environment.core.serial.new
    if type(factory) ~= "function" or debug.getinfo(factory, "S").what ~= "C" then
        return false, "unknown native serializer; keeping original callbacks"
    end
    local method = makeSave(environment, original, factory)
    Class.save = method
    installed[method] = true
    return true
end

-- Opt-in aggregate counters for a real save. Never wrap core.serial.new to
-- measure this optimization: that intentionally activates the fallback.
function M.enableDiagnostics(enabled)
    diagnostics = enabled and {calls = 0, optimized = 0, fallbacks = 0, callback_pairs = 0} or nil
end

function M.getDiagnostics()
    local result = {enabled = diagnostics ~= nil}
    if diagnostics then for key, value in pairs(diagnostics) do result[key] = value end end
    return result
end

return M
