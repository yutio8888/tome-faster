-- GPL-3.0-or-later. Based on ToME 1.7.6 engine/interface/PlayerDumpJSON.lua.
-- Copyright (C) 2009 - 2019 Nicolas Casalini. See COPYING.
-- Modified 2026-09-13: release gzip state in the recognized character exporter.
local M = {}
local prepared = setmetatable({}, {__mode = "k"})

local function native(f)
    return type(f) == "function" and debug.getinfo(f, "S").what == "C"
end

local function makeExporter(environment, compress)
    -- Keep the stock exporter, including its deferred charball callback and
    -- global writes. Only the character sheet compression call is changed.
    local function saveUUID(self, do_charball)
        if game.allowJSONDump and not game:allowJSONDump() then return end
        if game:isTainted() then return end
        if not self.__te4_uuid then
            if self.allow_late_uuid and not game:isTainted() then self:getUUID() end
            if not self.__te4_uuid then return end
        end
        local data = {sections={}}
        setmetatable(data, {__index={
            version = function(self, v) self.version = v end,
            hiddenData = function(self, key, value)
                self.hidden = self.hidden or {}
                self.hidden[key] = value
            end,
            newSection = function(self, table, sectable)
                self.sections[#self.sections+1] = table
                self[table] = sectable or {}
                return self[table]
            end,
            subsheet = function(self, name)
                local s = {sections={}}
                setmetatable(s, getmetatable(self))
                self.subsheets = self.subsheets or {}
                self.subsheets[#self.subsheets+1] = {name=name, sheet=s}
                return s
            end,
        }})
        local title, tags = self:dumpToJSON(data)
        data = json.encode(data)
        if not data or not title then return end

        profile:registerSaveChardump(game.__mod_info.short_name, self.__te4_uuid, title, tags, compress(data))
        if do_charball then pcall(function()
            savefile_pipe:push(do_charball.name, "entity", do_charball, "engine.CharacterBallSave", function(save)
                f = fs.open("/charballs/"..save:nameSaveEntity(do_charball), "r")
                if f then
                    local data = {}
                    while true do
                        local l = f:read()
                        if not l then break end
                        data[#data+1] = l
                    end
                    f:close()

                    profile:registerSaveCharball(game.__mod_info.short_name, self.__te4_uuid, table.concat(data))
                end
            end)
        end) end
    end
    return setfenv(saveUUID, environment)
end

function M.prepareExporter(original, options)
    if options and options.export_gzip == false then return nil, "disabled in faster_tome settings" end
    if prepared[original] then return original end
    if type(original) ~= "function" then return nil, "unknown character exporter" end
    local info = debug.getinfo(original, "Su")
    if info.source ~= "@/engine/interface/PlayerDumpJSON.lua" or info.linedefined ~= 41
        or info.lastlinedefined ~= 90 or info.nups ~= 0 then
        return nil, "unknown character exporter; keeping existing compression"
    end
    local environment = getfenv(original)
    local core, zlib = environment.core, environment.zlib
    local coreZlib = type(core) == "table" and core.zlib
    local oldCompress = type(coreZlib) == "table" and coreZlib.compress
    -- This embedded lzlib registers its functions into a fresh global table;
    -- its separate metadata table is discarded, so _VERSION is normally nil.
    if type(zlib) ~= "table" or (zlib._VERSION ~= nil and zlib._VERSION ~= "lzlib 0.3")
        or not native(oldCompress) or not native(zlib.compress) or not native(zlib.decompress) then
        return nil, "unknown native gzip binding; keeping existing compression"
    end
    local encode, decode = zlib.compress, zlib.decompress
    -- Check the embedded binding's gzip parameters and status convention without
    -- calling the leaking core compressor. No FFI or platform-specific API.
    local ok = pcall(function()
        for _, input in ipairs{"", "Faster ToME4\0gzip\255"} do
            local output, status = encode(input, 9, 8, 31, 8, 0)
            assert(type(output) == "string" and status == 1 and output:sub(1, 3) == "\31\139\8")
            local restored, finished = decode(output, 47)
            assert(restored == input and finished == 1)
        end
    end)
    if not ok then return nil, "gzip binding preflight failed; keeping existing compression" end
    local function compress(input)
        local currentCore, currentZlib = environment.core, environment.zlib
        -- Check at the call site: even a custom dump hook may replace a binding.
        if currentCore ~= core or currentCore.zlib ~= coreZlib or coreZlib.compress ~= oldCompress
            or currentZlib ~= zlib or zlib.compress ~= encode or zlib.decompress ~= decode
            or type(input) ~= "string" or #input > 2147483647 then
            return currentCore.zlib.compress(input)
        end
        local output, status = encode(input, 9, 8, 31, 8, 0)
        if status == 1 and type(output) == "string" then return output end
        -- The old core binding returns zero values on a deflate failure. Never
        -- forward a partial stream or lzlib's extra status to the consumer.
    end
    local exporter = makeExporter(environment, compress)
    prepared[exporter] = true
    return exporter
end

return M
