-- GPL-3.0-or-later. Based on ToME 1.7.6 engine/Savefile.lua.
-- Copyright (C) 2009 - 2019 Nicolas Casalini. See COPYING.
-- Modified 2026-09-14: shorten archive entry names and object references.
local M = {}
local installed = setmetatable({}, {__mode = "k"})
local decimal = tostring
local floor = math.floor
local function makeBase62()
    local digits = {}
    local alphabet = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
    for i = 0, 61 do digits[i] = alphabet:sub(i + 1, i + 1) end
    return function(number)
        local id = digits[number % 62]
        number = floor(number / 62)
        while number > 0 do
            id = digits[number % 62] .. id
            number = floor(number / 62)
        end
        -- The alphabet contains no underscore, so this escape is also unique.
        if id == "main" then return "_main" end
        return id
    end
end

local function upstream(f, first, last)
    if type(f) ~= "function" then return false end
    local info = debug.getinfo(f, "S")
    return info.source == "@/engine/Savefile.lua"
        and info.linedefined == first and info.lastlinedefined == last
end

function M.installSavefile(Savefile, options)
    if options and options.compact_save_names == false then return false, "disabled in faster_tome settings" end
    local name, init, close = Savefile.getFileName, Savefile.init, Savefile.close
    local token = installed[name]
    if token and token == installed[init] and token == installed[close] then return true end
    if not upstream(name, 130, 136) or not upstream(init, 45, 58) or not upstream(close, 84, 90) then
        return false, "unknown save naming or lifecycle method; keeping existing names"
    end

    -- Neither cache values nor object-name values retain their weak keys.
    -- Savefile.tables already keeps queued objects alive until close(). The
    -- native worker receives completed bytes and never needs this cache.
    local caches = setmetatable({}, {__mode = "k"})
    -- Keep the measured 0.2.10 default. The smaller base62 representation is
    -- opt-in until complete-process user CPU satisfies the release threshold.
    local encode = options and options.compact_save_names_base62 == true and makeBase62() or decimal
    function Savefile:getFileName(object)
        if object == self.current_save_main then return "main" end
        if not self.tables or type(object) ~= "table" then return name(self, object) end
        local cache = caches[self]
        if not cache then
            cache = {count = 0, objects = setmetatable({}, {__mode = "k"})}
            caches[self] = cache
        end
        local id = cache.objects[object]
        if not id then
            cache.count = cache.count + 1
            id = encode(cache.count)
            cache.objects[object] = id
        end
        return id
    end
    function Savefile:init(...)
        init(self, ...)
        caches[self] = nil
    end
    function Savefile:close(...)
        close(self, ...)
        caches[self] = nil
    end
    -- A token contains no functions or class/instance references. Check all
    -- three methods so a later addon override is never mistaken for our install.
    token = {}
    installed[Savefile.getFileName], installed[Savefile.init], installed[Savefile.close] = token, token, token
    return true
end

return M
