-- GPL-3.0-or-later. Diagnostic only: run in an expendable ToME 1.7.6 save copy.
-- This is NOT an addon and is never required by an entity or a saved callback.
-- It has not been exercised in the real game yet; the caller owns that test.
--
-- Usage (load this file through the diagnostic runtime's filesystem mapping):
--   local Scenario = assert(loadfile("/path/to/FearscapeScenario.lua"))()
--   local step = Scenario.start{mode="casterdead", seed=6140914,
--       expect_cleanup=true} -- false for the 0.2.10 / opt-out comparison
--   -- Call from the caller's frame/preparation loop, outside save CPU timing:
--   local done, report = step()
--   if done then assert(report.ok, report.error); save_report(report); step=nil end
--   -- Only after completion: normal saveGame / forceWait, then a fresh reload.
--   local reloaded = Scenario.inspect(report) -- read-only, no Faster dependency
--
-- Preconditions: paused main player with enough energy, no ongoing save or tick
-- callbacks, a normal source zone that permits plane changes, no target status
-- immunity/summon attributes, and a free visible adjacent tile. Input must be an
-- independent copy for every variant. The seed changes the process RNG on purpose.
-- Do not put step/report/module on game or an entity. Reports are scalar-only;
-- step releases its diagnostic actor/level references after success or failure.
-- Polling does not call tick(), onTickEndExecute(), save(), or forceWait(). The
-- real game loop must process the original callbacks between calls to step().
--
-- Both modes use a stock mod.class.NPC fixture and original forceUseTalent.
-- casterdead calls its stock die(nil), avoiding player XP and on-kill resources.
-- The original Fearscape lore/achievement, particles and movement still happen.
-- active leaves the living fixture on the source level, so it tests semantics;
-- do not expect its whole actor graph to disappear from a save.
local M = {}

local function checksum(text)
    local a, b = 1, 0
    for i = 1, #text do
        a = (a + text:byte(i)) % 65521
        b = (b + a) % 65521
    end
    return b * 65536 + a
end

local function callback(f)
    if type(f) ~= "function" then
        local row = {kind=type(f)}
        if type(f) == "boolean" then row.value = f end
        return row
    end
    local info = debug.getinfo(f, "Su")
    local row = {kind="function", source=info.source, first=info.linedefined,
        last=info.lastlinedefined, nups=info.nups, what=info.what}
    local ok, bytes = pcall(string.dump, f)
    if ok then row.bytes, row.adler32 = #bytes, checksum(bytes) end
    return row
end

local function identity(entity)
    if type(entity) ~= "table" then return false end
    return {uid=entity.uid, name=entity.name, class=entity.__CLASSNAME,
        define_as=entity.define_as, dead=entity.dead and true or false}
end

local function actor(entity)
    local row = identity(entity)
    if not row then return row end
    for _, key in ipairs{"x", "y", "level", "life", "max_life", "die_at", "mana", "max_mana",
        "stamina", "max_stamina", "vim", "max_vim", "psi", "max_psi", "hate", "equilibrium",
        "paradox", "positive", "negative", "soul", "air", "exp", "planetary_orbit"} do
        if type(entity[key]) == "number" then row[key] = entity[key] end
    end
    row.energy = entity.energy and entity.energy.value
    row.on_die, row.demon_plane_on_die = callback(entity.on_die), callback(entity.demon_plane_on_die)
    row.trapper = identity(entity.demon_plane_trapper)
    row.fearscape_active = entity.sustain_talents and entity.sustain_talents[entity.T_DEMON_PLANE] and true or false
    row.astar_map_present = entity.ai_state and entity.ai_state.astar and entity.ai_state.astar.map and true or false
    return row
end

local function inventory(entity)
    local rows, seen = {}, {}
    local function object(o, slot, position, parent)
        local row = {slot=slot, position=position, parent=parent, uid=o.uid, name=o.name,
            class=o.__CLASSNAME, type=o.type, subtype=o.subtype, define_as=o.define_as,
            stacked=type(o.stacked) == "table" and #o.stacked or 0}
        rows[#rows+1] = row
        if seen[o] then row.alias_to = seen[o]; return end
        seen[o] = #rows
        local owner = o.in_inven
        if type(owner) == "table" then
            row.owner = identity(owner.actor)
            row.owner_id_type = type(owner.id)
            if type(owner.id) == "number" or type(owner.id) == "string" then row.owner_id = owner.id
            elseif type(owner.id) == "table" and (type(owner.id.id) == "number" or type(owner.id.id) == "string") then row.owner_id = owner.id.id end
        end
        if type(o.stacked) == "table" then
            local parent_index = #rows
            for i, member in ipairs(o.stacked) do object(member, slot, i, parent_index) end
        end
    end
    local slots = {}
    for slot, contents in pairs(entity.inven or {}) do
        if type(contents) == "table" then slots[#slots+1] = slot end
    end
    table.sort(slots, function(a, b) return tostring(a) < tostring(b) end)
    for _, slot in ipairs(slots) do
        for i, o in ipairs(entity.inven[slot]) do object(o, tostring(slot), i, false) end
    end
    return rows
end

local function level(zone, current)
    return {zone=zone.short_name, zone_name=zone.name, level=current.level, uid=current.uid,
        w=current.map.w, h=current.map.h, is_demon_plane=zone.is_demon_plane and true or false}
end

local function loose(map)
    local rows = {}
    for y = 0, map.h - 1 do for x = 0, map.w - 1 do
        for i = 1, map:getObjectTotal(x, y) do
            local object = map:getObject(x, y, i)
            rows[#rows+1] = {x=x, y=y, position=i, uid=object.uid, name=object.name,
                class=object.__CLASSNAME, type=object.type, subtype=object.subtype,
                stacked=type(object.stacked) == "table" and #object.stacked or 0}
        end
    end end
    return rows
end

local function pending(current)
    local set = current.on_tick_end_custom or current.on_tick_end
    return set and #set.fcts or 0
end

local function saving()
    local pipe = rawget(_G, "savefile_pipe")
    return pipe and (pipe.saving or pipe.waiton or pipe.pipe and #pipe.pipe > 0) and true or false
end

local function stock(f, first, last)
    if type(f) ~= "function" then return false end
    local info = debug.getinfo(f, "S")
    return info.source == "@/data/talents/corruptions/shadowflame.lua"
        and info.linedefined == first and info.lastlinedefined == last
end

local function locateFixture(current, name)
    local found
    for _, e in pairs(current.level.entities) do
        if e.name == name then
            assert(not found, "multiple diagnostic casters share the expected name")
            found = e
        end
    end
    local trapped = current.player.demon_plane_trapper
    if type(trapped) == "table" and trapped.name == name then
        assert(not found or found == trapped, "source caster and trapper do not share identity")
        found = trapped
    end
    return found
end

function M.inspect(expected)
    assert(type(expected) == "table" and expected.fixture_name and expected.object_name, "pass the completed scalar report")
    local current = assert(game, "game is not loaded")
    local caster = locateFixture(current, expected.fixture_name)
    local rows, tokens = loose(current.level.map), {}
    for _, object in ipairs(rows) do if object.name == expected.object_name then tokens[#tokens+1] = object end end
    local row = {turn=current.turn, paused=current.paused and true or false, pending=pending(current),
        saving=saving(), source=level(current.zone, current.level), target=actor(current.player),
        caster=actor(caster), token_objects=tokens, inventory=inventory(current.player), loose_objects=rows}
    row.target_is_original_name = current.player.name == expected.before.target.name
    row.returned_to_source_description = row.source.zone == expected.before.source.zone
        and row.source.level == expected.before.source.level and row.source.w == expected.before.source.w
        and row.source.h == expected.before.source.h
    row.trapper_is_fixture = caster ~= nil and current.player.demon_plane_trapper == caster
    row.trapper_absent = current.player.demon_plane_trapper == nil
    row.target_death_wrapper_absent = not stock(current.player.on_die, 245, 252)
        and current.player.demon_plane_on_die == nil
    row.token_count = #tokens
    return row
end

function M.start(options)
    options = options or {}
    local mode, seed = options.mode or "casterdead", options.seed or 6140914
    assert(mode == "casterdead" or mode == "active", "mode must be casterdead or active")
    assert(type(seed) == "number" and seed >= 0 and seed <= 2147483647 and seed == math.floor(seed), "seed must be a nonnegative signed 32-bit integer")
    assert(options.expect_cleanup == nil or type(options.expect_cleanup) == "boolean", "expect_cleanup must be a boolean or nil")
    local report = {schema=1, mode=mode, seed=seed, ok=false, stage="waiting-idle",
        fixture_name="Fearscape acceptance caster " .. seed .. " " .. mode,
        object_name="Fearscape acceptance token " .. seed .. " " .. mode,
        expect_cleanup=options.expect_cleanup, mutates_copy=true, manually_changes_trapper=false,
        pumps_game_ticks=false}
    local live, polls, finished, begun_at
    polls, finished = 0, false

    local function assertPaused()
        assert(game == live.game and game.player == live.target, "controlled game/player changed during the diagnostic")
        assert(game.paused and game.player:enoughEnergy(), "diagnostic requires a paused player with enough energy")
        assert(game.turn == report.before.turn, "a gameplay turn advanced; do not accept this scene as a paused deterministic replay")
        assert(not game.player.dead, "target died during the diagnostic")
        assert(not saving(), "another save started during the diagnostic")
    end

    local function prepare()
        assert(config and config.settings and config.settings.cheat, "diagnostic copy must enable cheat mode")
        local current = assert(game, "game is not loaded")
        assert(current.player and current.level and current.zone and current.level.map, "game must have a current actor/level/zone")
        if pending(current) ~= 0 or saving() then return end
        local target = current.player
        assert(current.paused and target:enoughEnergy(), "pause the main player at an input boundary")
        assert(target.player and target.game_ender and not target.dead, "the controlled actor must be the living main player")
        assert(not current.zone.is_demon_plane and not current.zone.no_planechange, "source zone does not permit a fresh Fearscape")
        assert(not target.summon_time and not target.summoner, "target is a summon")
        assert(not target:attr("negative_status_effect_immune") and not target:attr("status_effect_immune"), "target is immune to the stock Fearscape entry")
        assert(not stock(target.on_die, 245, 252) and target.demon_plane_on_die == nil, "target still has a prior active Fearscape death wrapper")
        assert(not locateFixture(current, report.fixture_name), "use a fresh copy; this diagnostic caster already exists")

        local Talents, NPC, Map = require "engine.interface.ActorTalents", require "mod.class.NPC", require "engine.Map"
        local talent = assert(Talents.talents_def.T_DEMON_PLANE, "Fearscape is unavailable")
        assert(stock(talent.activate, 177, 285), "unknown Fearscape activation; diagnostic refuses to fabricate a scenario")
        local exit_info = debug.getinfo(talent.deactivate, "S")
        assert(stock(talent.deactivate, 286, 368) or exit_info.source:find("FasterFearscape.lua", 1, true), "unknown Fearscape exit")
        report.before = {turn=current.turn, paused=current.paused and true or false,
            target=actor(target), inventory=inventory(target), source=level(current.zone, current.level),
            loose_objects=loose(current.level.map), activation=callback(talent.activate), exit=callback(talent.deactivate)}
        live = {game=current, source=current.level, source_zone=current.zone, target=target,
            original_target_die=target.on_die, talent=talent, Map=Map}
        rng.seed(seed)
        local caster = NPC.new{
            name=report.fixture_name, type="humanoid", subtype="human", display="p", color=colors.VIOLET,
            image="npc/humanoid_human_alchemist.png", desc="A stock NPC fixture in a copied save.",
            faction=target.faction, level=1, rank=1, exp_worth=0,
            body={INVEN=10}, ai="none", max_life=1000, life=1000, max_vim=100, vim=100,
            stats={str=10, dex=10, mag=40, wil=40, con=10, cun=10},
            no_drops=true, no_rod_recall=true, no_difficulty_random_class=true,
            difficulty_boosted=1, _actor_adjust_level_applied=true,
        }
        live.caster, live.original_caster_die = caster, caster.on_die
        caster:resolve(); caster:resolve(nil, true)
        caster:learnTalent(caster.T_DEMON_PLANE, true, 1)
        assert(caster:getVim() > 11 and not caster:isTalentActive(caster.T_DEMON_PLANE), "fixture cannot activate Fearscape")
        local x, y
        for dy = -1, 1 do for dx = -1, 1 do
            local px, py = target.x + dx, target.y + dy
            if not x and (dx ~= 0 or dy ~= 0) and current.level.map:isBound(px, py)
                and not current.level.map(px, py, Map.ACTOR) and caster:canMove(px, py, true)
                and target:hasLOS(px, py)
            then x, y = px, py end
        end end
        assert(x and y, "no visible adjacent source tile is free; use a different copied input boundary")
        current.zone:addEntity(current.level, caster, "actor", x, y)
        -- force_target is ignored by the pinned engine for sustained talents.
        -- Use the real NPC AI target API consumed by Fearscape.onAIGetTarget.
        caster:setTarget(target)
        report.fixture = actor(caster)
        assertPaused()
        local ret = caster:forceUseTalent(caster.T_DEMON_PLANE, {ignore_energy=true, ignore_cd=true})
        assert(ret and caster:isTalentActive(caster.T_DEMON_PLANE), "stock forceUseTalent refused Fearscape")
        live.sustain = caster:isTalentActive(caster.T_DEMON_PLANE)
        assert(live.sustain.target == target, "stock sustain selected a different target")
        report.stage = "waiting-entry"
    end

    local function entered()
        assertPaused()
        if game.level == live.source then
            assert(pending(game) > 0, "Fearscape entry callback ended without entering the plane")
            return
        end
        local plane, caster, target = game.level, live.caster, live.target
        assert(game.zone.short_name == "demon-plane-spell" and game.zone.is_demon_plane, "entered a different temporary zone")
        assert(plane.plane_owner == caster and plane.source_level == live.source and plane.source_zone == live.source_zone, "Fearscape source identity mismatch")
        assert(target.demon_plane_trapper == caster and stock(target.on_die, 245, 252) and stock(caster.on_die, 255, 263), "stock capture/death wrappers are missing")
        assert(target.demon_plane_on_die == live.original_target_die and caster.demon_plane_on_die == live.original_caster_die, "stock original death callback identity mismatch")
        if pending(game) ~= 0 then return end
        live.plane, live.plane_zone = plane, game.zone
        local Object = require "mod.class.Object"
        local token = Object.new{name=report.object_name, desc="Stock object marker for the copied-save Fearscape exit test.",
            type="gem", subtype="white", display="*", color=colors.YELLOW, image="object/quartz.png",
            encumber=0, cost=0, material_level=1, identified=true, power_source={}}
        live.token = token
        token:resolve(); token:resolve(nil, true)
        game.zone:addEntity(plane, token, "object", caster.x, caster.y)
        report.entered = {turn=game.turn, source_identity=true, target=actor(target), caster=actor(caster),
            plane=level(game.zone, plane), token=identity(token), token_x=caster.x, token_y=caster.y,
            pending=pending(game), loose_objects=loose(plane.map)}
        if mode == "casterdead" then
            -- Nil killer suppresses unrelated player XP/on-kill resource changes.
            -- This still runs stock NPC.die -> ActorLife.die -> captured on_die.
            local ret = caster:die(nil)
            assert(ret and caster.dead, "stock NPC death did not complete")
        else
            assert(caster:forceUseTalent(caster.T_DEMON_PLANE, {ignore_energy=true}), "stock forceUseTalent refused deactivation")
        end
        assert(not caster:isTalentActive(caster.T_DEMON_PLANE), "stock exit did not deactivate its sustain")
        report.exit_requested = {target=actor(target), caster=actor(caster), pending=pending(game)}
        report.stage = "waiting-exit"
    end

    local function exited()
        assertPaused()
        if game.level == live.plane then
            assert(pending(game) > 0, "exit callbacks ended without returning to the source")
            return
        end
        assert(game.level == live.source and game.zone == live.source_zone, "exit returned to a different source identity")
        if pending(game) ~= 0 then return end
        local caster, target = live.caster, live.target
        assert(target.on_die == live.original_target_die and target.demon_plane_on_die == nil, "target death callback did not restore")
        assert(caster.on_die == live.original_caster_die and caster.demon_plane_on_die == nil, "caster death callback did not restore")
        assert(not caster:isTalentActive(caster.T_DEMON_PLANE), "Fearscape is still active after returning")
        assert(game.level:hasEntity(target), "living target was not returned to source entities")
        assert(mode == "casterdead" and caster.dead and not game.level:hasEntity(caster)
            or mode == "active" and not caster.dead and game.level:hasEntity(caster), "caster membership/death state differs from the requested exit")
        assert(target.demon_plane_trapper == nil or target.demon_plane_trapper == caster, "another capture replaced the diagnostic trapper")
        if options.expect_cleanup ~= nil then
            assert((target.demon_plane_trapper == nil) == options.expect_cleanup, "trapper cleanup differs from the selected comparison variant")
        end
        local found, tx, ty = 0
        for y = 0, game.level.map.h - 1 do for x = 0, game.level.map.w - 1 do
            for i = 1, game.level.map:getObjectTotal(x, y) do
                if game.level.map:getObject(x, y, i) == live.token then found, tx, ty = found + 1, x, y end
            end
        end end
        assert(found == 1, "original exit did not return the unique token object exactly once")
        local destination = mode == "casterdead" and target or caster
        assert(tx == destination.x and ty == destination.y, "token was not placed at the original exit's actor destination")
        report.after = M.inspect(report)
        report.after.caster_observed_before_release = actor(caster)
        report.after.same_target_identity, report.after.same_source_identity = true, true
        report.after.original_target_callback_identity, report.after.original_caster_callback_identity = true, true
        report.after.same_token_identity, report.after.token_x, report.after.token_y = true, tx, ty
        report.after.source_and_plane_are_distinct = live.source ~= live.plane
        report.after.plane_source_retained = live.plane.source_level == live.source and live.plane.source_zone == live.source_zone
        report.ok, report.stage = true, "complete"
        finished, live = true, nil
    end

    return function()
        if finished then return true, report end
        polls = polls + 1
        local ok, err = xpcall(function()
            local now = core.game.getTime()
            begun_at = begun_at or now
            assert(polls <= (options.max_polls or 600) and now - begun_at <= (options.timeout_ms or 30000), "Fearscape diagnostic timed out awaiting the real game loop")
            if report.stage == "waiting-idle" then prepare()
            elseif report.stage == "waiting-entry" then entered()
            elseif report.stage == "waiting-exit" then exited()
            else error("unknown diagnostic stage " .. tostring(report.stage)) end
        end, debug.traceback)
        if not ok then
            report.error, report.failed_stage, report.stage = err, report.stage, "failed"
            -- Do not force a second exit or mutate the failed game's objects.
            -- The caller must discard this copy; never save a failed result.
            finished, live = true, nil
        end
        report.polls = polls
        return finished, report
    end
end

return M
