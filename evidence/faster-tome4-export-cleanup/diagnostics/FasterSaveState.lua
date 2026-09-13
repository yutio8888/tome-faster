-- Local diagnostic only. Compare selected live state around a normal save.
-- No RNG/next_uid checks, getters, callbacks, animation or cache snapshots.
local M = {}

local function scalar(v)
    local t = type(v)
    return t == "string" or t == "number" or t == "boolean"
end

local function canonical(v)
    local t = type(v)
    if t == "string" then return "s" .. #v .. ":" .. v end
    if t == "number" then return "n" .. string.format("%.17g", v) end
    if t ~= "table" then return t .. ":" .. tostring(v) end
    local items = {}
    for k, value in pairs(v) do
        items[#items + 1] = canonical(k) .. "=" .. canonical(value)
    end
    table.sort(items)
    return "{" .. table.concat(items, ";") .. "}"
end

local ignored = {
    particles = true, particle = true, particle_id = true, ps = true,
    shader = true, animation = true, anim = true, display = true,
    last_update = true, real_starttime = true, total_playtime = true,
}

-- Bounded projection of small business-data tables; class references become
-- UID/class pairs, never a traversal into the world or a metatable mutation.
local function data(v, depth, seen)
    if scalar(v) then return v end
    if type(v) ~= "table" then return nil end
    if rawget(v, "__CLASSNAME") or rawget(v, "uid") then
        return {uid = rawget(v, "uid"), class = rawget(v, "__CLASSNAME")}
    end
    if depth <= 0 then return {__omitted_deeper_table = true} end
    seen = seen or {}
    if seen[v] then return {__cycle = true} end
    seen[v] = true
    local out = {}
    for k, value in pairs(v) do
        if scalar(k) and not ignored[k] and not (type(k) == "string" and k:find("cache", 1, true)) then
            out[k] = data(value, depth - 1, seen)
        end
    end
    seen[v] = nil
    return out
end

local function fields(object, keys)
    local out = {}
    for _, key in ipairs(keys) do
        local value = object[key]
        if scalar(value) then out[key] = value end
    end
    return out
end

local function questState(quests)
    local out = {}
    for id, quest in pairs(quests or {}) do
        if scalar(id) and type(quest) == "table" then
            local q = fields(quest, {"id", "status", "gained_turn", "completed_turn", "failed_turn"})
            q.objectives = data(quest.objectives, 4)
            out[id] = q
        end
    end
    return out
end

local function inventoryState(actor)
    local out, count = {}, 0
    for slot, inventory in pairs(actor.inven or {}) do
        if scalar(slot) and type(inventory) == "table" then
            local items = {}
            for index, object in pairs(inventory) do
                if type(index) == "number" and type(object) == "table" then
                    local item = fields(object, {
                        "uid", "name", "type", "subtype", "number", "stack_count", "quantity",
                        "power", "max_power", "charges", "use_power", "encumber", "cost",
                        "material_level", "unique", "egoed", "identified", "cursed",
                        "__transmo", "__new_pickup", "wielder_inven", "wielder_slot",
                    })
                    for _, key in ipairs{"combat", "wielder", "carrier", "talents_cd", "use_talent", "use_power"} do
                        item[key] = data(object[key], 3)
                    end
                    items[index] = item -- Preserve numeric slot indices and holes.
                    count = count + 1
                end
            end
            out[slot] = items
        end
    end
    return out, count
end

local function actorState(actor)
    local out = fields(actor, {
        "uid", "__CLASSNAME", "x", "y", "level", "exp", "money", "life", "min_life", "max_life",
        "life_regen", "dead", "die_at", "player", "player_control", "faction", "rank", "size_category",
        "unused_stats", "unused_talents", "unused_generics", "unused_talents_types", "unused_prodigies",
        "fatigue", "combat_atk", "combat_dam", "combat_def", "combat_armor", "combat_physresist",
        "combat_spellresist", "combat_mentalresist", "global_speed", "movement_speed", "combat_physspeed",
        "combat_spellspeed", "combat_mindspeed", "summon_time", "summoner_gain_exp",
    })
    out.energy = actor.energy and fields(actor.energy, {"value", "mod", "used"})
    out.resources = {}
    for _, def in ipairs(actor.resources_def or {}) do
        if type(def.short_name) == "string" then
            local name = def.short_name
            out.resources[name] = fields(actor, {name, "min_" .. name, "max_" .. name, def.regen_prop or name .. "_regen"})
        end
    end
    for _, key in ipairs{
        "stats", "inc_stats", "talents", "talents_types", "talents_types_mastery", "talents_cd",
        "sustain_talents", "tmp", "inscriptions", "inscriptions_data", "resists", "resists_cap",
        "resists_pen", "inc_damage", "affinity", "status_effect_immune",
    } do
        out[key] = data(actor[key], 4)
    end
    out.quests = questState(actor.quests)
    local count
    out.inventory, count = inventoryState(actor)
    return out, count
end

function M.capture(g)
    assert(type(g) == "table", "FasterSaveState.capture requires the live game")
    local sections, actorCount, itemCount = {}, 0, 0
    sections.game = canonical({
        turn = g.turn, paused = g.paused,
        player_uid = g.player and g.player.uid,
        player_class = g.player and g.player.__CLASSNAME,
        zone = g.zone and g.zone.short_name,
        level = g.level and g.level.level, sublevel = g.level and g.level.sublevel_id,
    })
    local actors, members, order = {}, {}, {}
    local function addActor(actor)
        if type(actor) == "table" and actor.uid and (actor.talents or actor == g.player) then
            actors[actor] = true
        end
    end
    addActor(g.player)
    for _, actor in pairs(g.level and g.level.entities or {}) do addActor(actor) end
    for _, actor in pairs(g.entities or {}) do addActor(actor) end
    for actor, def in pairs(g.party and g.party.members or {}) do
        addActor(actor)
        members[actor.uid] = data(def, 3)
    end
    for index, actor in ipairs(g.party and g.party.m_list or {}) do order[index] = actor.uid end
    sections.party = canonical({members = members, order = order})
    for actor in pairs(actors) do
        local state, count = actorState(actor)
        sections["actor:" .. tostring(actor.uid)] = canonical(state)
        actorCount, itemCount = actorCount + 1, itemCount + count
    end
    return {schema = 1, sections = sections, actors = actorCount, items = itemCount}
end

function M.check(before, g)
    assert(type(before) == "table" and before.schema == 1, "invalid FasterSaveState capture")
    local after = M.capture(g)
    local changed, added, removed = 0, 0, 0
    for key, value in pairs(before.sections) do
        if after.sections[key] == nil then removed = removed + 1
        elseif after.sections[key] ~= value then changed = changed + 1 end
    end
    for key in pairs(after.sections) do
        if before.sections[key] == nil then added = added + 1 end
    end
    local ok = changed == 0 and added == 0 and removed == 0
    -- Counts only: never print canonical sections or private character data.
    print(("[FasterSaveState] equal=%s actors=%d items=%d changed_sections=%d added_sections=%d removed_sections=%d"):format(
        tostring(ok), after.actors, after.items, changed, added, removed))
    return ok
end

return M
