-- Local diagnostic only: compare dead Party export work on disposable saves.
-- RNG/temporary UID differences are measured and allowed; no profile order is sent.
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

local function targetState(g)
    local target = g.target and g.target.target
    return {x = target and target.x, y = target and target.y,
        entity_uid = target and type(target.entity) == "table" and target.entity.uid or nil,
        has_entity = target and target.entity ~= nil or false}
end

function M.run(realgame)
    local Player = require "mod.class.Player"
    local Entity = require "engine.Entity"
    local Class = require "engine.class"
    local originalExport = assert(upvalue(Player.saveUUID, "original"), "expected Faster saveUUID wrapper")
    local exportenv = getfenv(originalExport)
    local profile = assert(exportenv.profile)
    local consumer = profile.registerSaveChardump
    local info = debug.getinfo(consumer, "S")
    assert(info.source == "@/engine/PlayerProfile.lua" and info.linedefined == 928,
        "expected pinned profile consumer")
    assert(realgame.player.__te4_uuid, "existing UUID required; never register test characters")
    local jsonlib = assert(exportenv.json)
    local encode, decode = assert(jsonlib.encode), assert(jsonlib.decode)
    local consumerenv = getfenv(consumer)
    local oldgame, oldauth, oldhash = _G.game, profile.auth, profile.hash_valid
    local oldpush = core.profile.pushOrder
    local rngmethods, oldrandom, oldrandomseed = {}, math.random, math.randomseed
    local liveBefore, liveTarget = selectedState(realgame), canonical(targetState(realgame))
    local active, unexpected = nil, 0
    local results = {}

    local function uid() return assert(upvalue(Entity.cloned, "next_uid"), "next_uid unavailable") end
    local function captureOrder(serialized)
        assert(active and type(serialized) == "string", "unexpected profile capture context")
        local order = serialized:unserialize()
        assert(order.o == "SaveChardump", "unexpected order type")
        active.orders[#active.orders + 1] = order
    end
    local function wrapRandom(name, method)
        return function(...)
            if active then
                active.rng_calls = active.rng_calls + 1
                active.rng_methods[name] = (active.rng_methods[name] or 0) + 1
            end
            return method(...)
        end
    end
    local function restore()
        -- Revert simulated authentication before reopening any original sender.
        profile.auth, profile.hash_valid = oldauth, oldhash
        setfenv(consumer, consumerenv)
        setfenv(originalExport, exportenv)
        core.profile.pushOrder = oldpush
        for key, method in pairs(rngmethods) do rng[key] = method end
        math.random, math.randomseed = oldrandom, oldrandomseed
        _G.game = oldgame
    end
    local ok, err = pcall(function()
        -- Barrier 1 rejects any unrelated outgoing request. Barrier 2 captures
        -- only the actual consumer's local order without changing its identity.
        core.profile.pushOrder = function()
            unexpected = unexpected + 1
            error("unexpected real profile request blocked by Party export check")
        end
        local captureProfile = setmetatable({pushOrder = captureOrder}, {__index = core.profile})
        local captureCore = setmetatable({profile = captureProfile}, {__index = core})
        setfenv(consumer, setmetatable({core = captureCore, print = function() end}, {__index = consumerenv}))
        local countedJSON = setmetatable({encode = function(value)
            local text = encode(value)
            assert(active, "JSON outside test case")
            active.encodes = active.encodes + 1
            active.json_bytes = active.json_bytes + #text
            return text
        end}, {__index = jsonlib})
        setfenv(originalExport, setmetatable({json = countedJSON}, {__index = exportenv}))
        for _, key in ipairs{"__call", "range", "avg", "dice", "seed", "chance", "percent", "normal", "normalFloat", "float"} do
            if type(rng[key]) == "function" then
                rngmethods[key] = rng[key]
                rng[key] = wrapRandom("rng." .. key, rng[key])
            end
        end
        math.random = wrapRandom("math.random", oldrandom)
        math.randomseed = wrapRandom("math.randomseed", oldrandomseed)

        local snapshots = {Class.cloneForSave(realgame), Class.cloneForSave(realgame)}
        for i, name in ipairs{"original_party_export", "without_party_export"} do
            local snapshot = snapshots[i]
            assert(snapshot.player.__te4_uuid == realgame.player.__te4_uuid, "snapshot UUID mismatch")
            local before = selectedState(snapshot)
            local beforeUID = uid()
            _G.game = snapshot
            profile.auth, profile.hash_valid = {login = "local-capture-only"}, true
            active = {orders = {}, encodes = 0, json_bytes = 0, rng_calls = 0, rng_methods = {},
                target_before = targetState(snapshot)}
            assert(not snapshot.player.__no_save_json, "saved player disables JSON export")
            if i == 1 then
                -- Verbatim original Game.saveGame temporary-party block. This
                -- party is intentionally not used by saveUUID(nil).
                local party = game.party:cloneFull()
                party.__te4_uuid = game:getPlayer(true).__te4_uuid
                for m, _ in pairs(party.members) do
                    m:attr("save_cleanup", 1)
                    m:stripForExport()
                    m:attr("save_cleanup", -1)
                end
                party:attr("save_cleanup", 1)
                party:stripForExport()
                party:attr("save_cleanup", -1)
            end
            active.rng_calls_before_export = active.rng_calls
            active.uid_delta_before_export = uid() - beforeUID
            snapshot.player:saveUUID(nil)
            active.uid_delta = uid() - beforeUID
            active.target_after = targetState(snapshot)
            active.target_changed = canonical(active.target_before) ~= canonical(active.target_after)
            active.selected_state_unchanged = selectedState(snapshot) == before
            assert(active.selected_state_unchanged, name .. " changed selected snapshot character state")
            assert(active.encodes == 1 and #active.orders == 1, name .. " must export exactly once")
            local order = active.orders[1]
            local rawJSON, status = zlib.decompress(order.data, 47)
            assert(type(rawJSON) == "string" and status == 1, "gzip decode failed")
            local metadata, decoded = order.metadata:unserialize(), decode(rawJSON)
            assert(decoded.character and decoded.character.name == realgame.player.name, "wrong exported character")
            sorted(metadata.tags.addon)
            active.comparable = canonical{module = order.module, uuid = order.uuid,
                metadata = metadata, sheet = normalize(decoded)}
            results[name] = active
            active = nil
        end
        assert(results.original_party_export.comparable == results.without_party_export.comparable,
            "dead Party removal changed real online character JSON or metadata")
        assert(unexpected == 0, "unexpected network order was blocked")
        assert(selectedState(realgame) == liveBefore, "test changed selected live character state")
        assert(canonical(targetState(realgame)) == liveTarget, "test changed live targeting state")
    end)
    restore()
    if not ok then error(err, 0) end
    local summary = {online_equal = true, captured_online_orders = 2, real_network_calls = 0,
        selected_state_unchanged = true, live_target_unchanged = true, rng_and_uid_changes_allowed = true}
    for name, result in pairs(results) do
        summary[name] = {json_bytes = result.json_bytes, encodes = result.encodes,
            rng_calls = result.rng_calls, rng_methods = result.rng_methods,
            rng_calls_before_export = result.rng_calls_before_export,
            uid_delta = result.uid_delta, uid_delta_before_export = result.uid_delta_before_export,
            target_before = result.target_before, target_after = result.target_after,
            target_changed = result.target_changed, selected_state_unchanged = result.selected_state_unchanged}
    end
    print("[PartyExportCheck] PASS " .. encode(summary))
    return summary
end

return M
