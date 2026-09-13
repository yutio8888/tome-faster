-- Local diagnostic only: run on a disposable save, never send profile orders.
local M = {}

local function upvalue(f, wanted)
    for i = 1, 40 do
        local name, value = debug.getupvalue(f, i)
        if not name then break end
        if name == wanted then return value end
    end
end

-- Preserve array positions; sort dictionary keys only. The delimiter and type
-- tags make this an unambiguous comparison, not a JSON pretty-printer.
local function canonical(value)
    local kind = type(value)
    if kind == "string" then return "s" .. #value .. ":" .. value end
    if kind ~= "table" then return kind .. ":" .. tostring(value) end
    local entries = {}
    for key, item in pairs(value) do
        entries[#entries + 1] = canonical(key) .. "=" .. canonical(item)
    end
    table.sort(entries)
    return "{" .. table.concat(entries, ";") .. "}"
end

local function sorted(values)
    if values then table.sort(values, function(a, b) return canonical(a) < canonical(b) end) end
end

-- These specific arrays are built from pairs in the upstream exporter. Do not
-- reorder inventory slots, talent lists, inscription slots or section order.
local function normalize(sheet)
    sorted(sheet.effects)
    if sheet.vision then sorted(sheet.vision.esp) end
    if sheet.subsheets then
        for _, sub in ipairs(sheet.subsheets) do normalize(sub.sheet) end
        sorted(sheet.subsheets)
    end
    return sheet
end

local function selectedState(g)
    local result = {turn = g.turn, paused = g.paused, player_uid = g.player.uid, party = {}}
    for actor in pairs(g.party.members) do
        local state = {resources = {}, talents = actor.talents, cooldowns = actor.talents_cd,
            inscriptions = actor.inscriptions, sustains = {}, effects = {}, inventory = {}}
        for _, key in ipairs{"uid", "x", "y", "life", "max_life", "money", "exp", "level", "dead", "__te4_uuid"} do
            state[key] = actor[key]
        end
        state.energy = actor.energy and actor.energy.value
        for _, def in ipairs(actor.resources_def or {}) do
            state.resources[def.short_name] = actor[def.short_name]
        end
        for tid, value in pairs(actor.sustain_talents or {}) do state.sustains[tid] = not not value end
        for effect, value in pairs(actor.tmp or {}) do
            local fields = {}
            for key, item in pairs(value) do
                if type(item) == "number" or type(item) == "boolean" or type(item) == "string" then fields[key] = item end
            end
            state.effects[effect] = fields
        end
        for id, inventory in pairs(actor.inven or {}) do
            local objects = {}
            for i, object in ipairs(inventory) do
                local fields = {}
                for _, key in ipairs{"uid", "name", "number", "stack_count", "power", "max_power", "charges", "quantity", "__transmo", "__new_pickup"} do
                    fields[key] = object[key]
                end
                objects[i] = fields
            end
            state.inventory[id] = objects
        end
        result.party[actor.uid] = state
    end
    return canonical(result)
end

function M.run(realgame)
    local Player = require "mod.class.Player"
    local Entity = require "engine.Entity"
    local Class = require "engine.class"
    local optimized = Player.saveUUID
    local original = require("engine.interface.PlayerDumpJSON").saveUUID
    local delegate = assert(upvalue(optimized, "delegate") or upvalue(optimized, "original"),
        "installed offline saveUUID wrapper is required")
    local info = debug.getinfo(original, "S")
    assert(info.source == "@/engine/interface/PlayerDumpJSON.lua" and info.linedefined == 41
        and info.lastlinedefined == 90,
        "expected pinned original saveUUID")
    local delegateInfo = debug.getinfo(delegate, "S")
    assert(delegate == original or delegateInfo.source:find("FasterGzip.lua", 1, true),
        "unknown installed export delegate")
    assert(realgame.player.saveUUID == optimized, "player does not use the installed exporter")
    assert(realgame.player.__te4_uuid, "existing character UUID required; never register a test character")

    local exportenv = getfenv(original)
    local delegateenv = getfenv(delegate)
    local profile = assert(exportenv.profile)
    local consumer = profile.registerSaveChardump
    local consumerinfo = debug.getinfo(consumer, "S")
    assert(consumerinfo.source == "@/engine/PlayerProfile.lua" and consumerinfo.linedefined == 928,
        "expected pinned profile consumer")
    local consumerenv = getfenv(consumer)
    local jsonlib = assert(exportenv.json)
    local encode, decode = assert(jsonlib.encode), assert(jsonlib.decode)
    -- core.zlib exposes compression only, using a gzip header (windowBits 31).
    -- The separately registered lzlib module accepts windowBits 47 to decode
    -- either gzip or zlib. Its second result is an inflate status, not a JSON
    -- offset; keep it out of the call to json.decode.
    local inflate = assert(zlib and zlib.decompress, "lzlib decompressor required")
    local function decompress(data)
        local value, status = inflate(data, 47)
        assert(type(value) == "string" and status == 1, "character gzip did not reach Z_STREAM_END")
        return value
    end
    local probeLines = string.rep("test\n\"quote\"", 100)
    local probe = encode({character = {name = "Yron"}, lines = probeLines})
    local compressedProbe = assert(core.zlib.compress(probe), "gzip encoder preflight failed")
    assert(decompress(compressedProbe) == probe, "gzip decoder preflight failed")
    local decodedProbe = decode(probe)
    assert(decodedProbe.character.name == "Yron" and decodedProbe.lines == probeLines,
        "JSON decoder preflight failed")
    local oldgame, oldauth, oldhash = _G.game, profile.auth, profile.hash_valid
    local oldpush = core.profile.pushOrder
    local rngmethods, oldrandom, oldrandomseed = {}, math.random, math.randomseed
    local uidBefore = assert(upvalue(Entity.cloned, "next_uid"), "cannot inspect next_uid")
    local liveBefore = selectedState(realgame)
    local active, unexpected, rngcalls = nil, 0, 0
    local results = {}

    local function unexpectedOrder()
        unexpected = unexpected + 1
        error("unexpected profile order blocked by chardump check")
    end
    local function captureOrder(serialized)
        assert(active, "profile output outside a test case")
        assert(type(serialized) == "string", "expected serialized profile order")
        local order = serialized:unserialize()
        assert(order.o == "SaveChardump", "unexpected order type in character exporter")
        active.orders[#active.orders + 1] = order
    end
    local function blockRandom()
        rngcalls = rngcalls + 1
        error("unexpected Lua RNG call blocked during character export")
    end
    local function restore()
        -- Restore authentication before reconnecting any original consumer.
        profile.auth, profile.hash_valid = oldauth, oldhash
        setfenv(consumer, consumerenv)
        setfenv(original, exportenv)
        if delegate ~= original then setfenv(delegate, delegateenv) end
        core.profile.pushOrder = oldpush
        for key, method in pairs(rngmethods) do rng[key] = method end
        math.random, math.randomseed = oldrandom, oldrandomseed
        _G.game = oldgame
    end

    local ok, err = pcall(function()
        -- Install both barriers BEFORE pretending to be authenticated. The
        -- private consumer still has its real source identity for addon guards.
        core.profile.pushOrder = unexpectedOrder
        local isolatedProfile = setmetatable({pushOrder = captureOrder}, {__index = core.profile})
        local isolatedCore = setmetatable({profile = isolatedProfile}, {__index = core})
        setfenv(consumer, setmetatable({core = isolatedCore}, {__index = consumerenv}))
        local countedJSON = setmetatable({encode = function(value)
            assert(active, "JSON encoding outside a test case")
            local encoded = encode(value)
            active.encodes = active.encodes + 1
            active.json_bytes = active.json_bytes + #encoded
            return encoded
        end}, {__index = jsonlib})
        setfenv(original, setmetatable({json = countedJSON}, {__index = exportenv}))
        -- Instrument both the baseline and the real installed delegate while
        -- retaining their identities, so the offline source guard still runs.
        if delegate ~= original then
            setfenv(delegate, setmetatable({json = countedJSON}, {__index = delegateenv}))
        end

        -- Catch Lua-visible RNG entry points without advancing the generator.
        -- An unexpected call fails validation even if a tooltip catches errors.
        for _, key in ipairs{"__call", "range", "avg", "dice", "seed", "chance", "percent", "normal", "normalFloat", "float"} do
            if type(rng[key]) == "function" then rngmethods[key] = rng[key]; rng[key] = blockRandom end
        end
        math.random, math.randomseed = blockRandom, blockRandom

        local snapshots = {}
        for i = 1, 4 do snapshots[i] = Class.cloneForSave(realgame) end
        for i, name in ipairs{"online_original", "online_optimized", "offline_original", "offline_optimized"} do
            local snapshot = snapshots[i]
            assert(snapshot.player.__te4_uuid == realgame.player.__te4_uuid, "snapshot UUID changed")
            _G.game = snapshot
            profile.auth = i <= 2 and {login = "local-capture-only"} or false
            profile.hash_valid = true
            local before, uid = selectedState(snapshot), upvalue(Entity.cloned, "next_uid")
            active = {orders = {}, encodes = 0, json_bytes = 0}
            assert(snapshot.player.saveUUID == optimized, "snapshot lost installed exporter")
            local method = i % 2 == 1 and original or optimized
            method(snapshot.player, nil)
            assert(selectedState(snapshot) == before, name .. " changed selected character state")
            assert(upvalue(Entity.cloned, "next_uid") == uid, name .. " allocated entity UIDs")
            assert(rngcalls == 0, name .. " attempted to use RNG")
            results[name] = active
            active = nil
        end

        for _, name in ipairs{"online_original", "online_optimized"} do
            local result = results[name]
            assert(result.encodes == 1 and #result.orders == 1, name .. " did not generate exactly one sheet")
            local order = result.orders[1]
            local metadata = order.metadata:unserialize()
            sorted(metadata.tags.addon)
            local rawJSON = decompress(order.data)
            local replacement, status = zlib.compress(rawJSON, 9, 8, 31, 8, 0)
            assert(status == 1 and replacement == order.data, "replacement gzip differs on real character JSON")
            local decoded = decode(rawJSON)
            assert(decoded.character and decoded.character.name == realgame.player.name,
                "decoded character sheet does not describe the saved player")
            result.comparable = canonical{module = order.module, uuid = order.uuid,
                metadata = metadata, sheet = normalize(decoded)}
        end
        assert(results.online_original.comparable == results.online_optimized.comparable,
            "online original and optimized sheets differ")
        assert(results.offline_original.encodes == 1 and #results.offline_original.orders == 0,
            "offline original must generate and discard one sheet")
        assert(results.offline_optimized.encodes == 0 and #results.offline_optimized.orders == 0,
            "offline optimization did not skip dead JSON")
        assert(unexpected == 0, "unexpected profile request was blocked")
        assert(upvalue(Entity.cloned, "next_uid") == uidBefore, "validation changed global UID sequence")
        assert(selectedState(realgame) == liveBefore, "validation changed live character state")
    end)
    restore()
    if not ok then error(err, 0) end
    local summary = {online_equal = true, captured_online_orders = 2, real_network_calls = 0,
        offline_original_encodes = results.offline_original.encodes,
        offline_optimized_encodes = results.offline_optimized.encodes,
        online_json_bytes = results.online_original.json_bytes,
        lua_rng_calls = rngcalls, uid_delta = 0, selected_state_unchanged = true,
        replacement_gzip_byte_equal = true, installed_exporter_source = delegateInfo.source}
    print("[ChardumpCheck] PASS " .. encode(summary))
    return summary
end

return M
