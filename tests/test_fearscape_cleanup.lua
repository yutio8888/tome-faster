-- GPL-3.0-or-later. Differential tests use the actual pinned Fearscape talent
-- (including activation and both on_die wrappers) and engine tick scheduler.
assert(_VERSION == "Lua 5.1", "Lua 5.1 / LuaJIT required")
local root = arg[1] or "."
local repo = assert(arg[2], "pass a local ToME source Git clone as argument 2")
local commit = "624a67329fe2ad440c5b344785a9c73fcf22ae63"
local function quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
local function pinned(path)
    local pipe = assert(io.popen("git -C " .. quote(repo) .. " show " .. quote(commit .. ":" .. path), "r"))
    local text = pipe:read("*a"); assert(pipe:close()); assert(#text > 0)
    return text
end
local talent_source = pinned("game/modules/tome/data/talents/corruptions/shadowflame.lua")
local game_source = pinned("game/engines/default/engine/Game.lua")
local first = assert(game_source:find("function _M:onTickEndExecute()", 1, true))
local last = assert(game_source:find("--- Returns a registered function", first, true))
local _, lines = game_source:sub(1, first - 1):gsub("\n", "")
local scheduler_source = string.rep("\n", lines) .. game_source:sub(first, last - 1)
local Faster = assert(loadfile(root .. "/overload/engine/FasterFearscape.lua"))()
local checks, cases = 0, 0
local function check(ok, message) assert(ok, message); checks = checks + 1 end
local function pack(...) return {n = select("#", ...), ...} end
local function run(source, name, env) return setfenv(assert(loadstring(source, name)), env)() end

local function world(optimized, options)
    options = options or {}
    local w = {trace = {}, tags = {}, phase = "setup", grids = 0, methods = {}, failure = {}, original_deaths = {}}
    local env = setmetatable({}, {__index = _G}); env._G = env
    w.env, w.options = env, options
    w.tags[w.failure] = "failure"
    local function token(value)
        if type(value) ~= "table" then return type(value) .. ":" .. tostring(value) end
        if w.tags[value] then return w.tags[value] end
        local keys, values = {}, {}
        for key in pairs(value) do keys[#keys+1] = key end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        for _, key in ipairs(keys) do values[#values+1] = tostring(key) .. "=" .. token(value[key]) end
        return "{" .. table.concat(values, ",") .. "}"
    end
    local function record(name, ...)
        local values = {w.phase .. ":" .. name}
        for i = 1, select("#", ...) do values[#values+1] = token(select(i, ...)) end
        w.trace[#w.trace+1] = table.concat(values, "|")
        if w.phase == "exit" and options.fail == name then error(w.failure, 0) end
    end
    w.record = record
    env.Map = {ACTOR = 4, TERRAIN = 1}
    env.core = {game = {requestNextTick = function() record("request-tick") end},
        shader = {active = function(n) record("shader", n); return options.shader end}}
    env.Particles = {new = function(...)
        record("new-particles", ...)
        return w.particle
    end}
    w.particle = {}; w.tags[w.particle] = "wings"
    local Game = {TICK_RESCHEDULE = {}}
    env._M = Game
    run(scheduler_source, "@/engine/Game.lua", env)
    local game = setmetatable({zone_name_s = "cached-zone-name"}, {__index = Game})
    w.game, env.game = game, game
    w.tags[game] = "game"
    game.logPlayer = function(player, text)
        record(text:find("brought back", 1, true) and "exit-log" or "entry-log", player, text)
        if w.phase == "exit" and options.during == "log-other-trapper" then
            w.target.demon_plane_trapper = w.other
        elseif w.phase == "exit" and options.during == "log-other-level" then
            game.level, game.zone = w.historical, w.historical_zone
        elseif w.phase == "exit" and options.during == "log-target-wrapper" then
            w.target.on_die = w.unknown
        elseif w.phase == "exit" and options.during == "log-other-sustain" then
            w.caster.sustain_talents.T_DEMON_PLANE = {target = w.other}
        elseif w.phase == "exit" and options.during == "log-target-dies" then
            w.target.dead = true
        end
    end
    function game:playSoundNear(...) record("sound", ...) end
    function game:getPlayer(...) record("get-player", ...); return self.player end
    game.party = {members = {}}
    function game.party:hasMember(actor) record("party-member", actor); return self.members[actor] end
    function game.party:learnLore(...) record("lore", ...) end
    env.world = {gainAchievement = function(_, ...) record("achievement", ...) end}
    game.uiset = {setupMinimap = function(_, ...) record("minimap", ...) end}
    game.nicer_tiles = {postProcessLevelTilesOnLoad = function(_, ...) record("tiles", ...) end}

    local function level(name)
        local map = {w = 12, h = 12, objects = {}, particles = {{active = true}}}
        local lv = {map = map, entities = {}, level = 2}
        w.tags[map], w.tags[lv] = name .. "-map", name .. "-level"
        setmetatable(map, {__call = function(_, x, y, layer)
            record(name .. ":map-get", x, y, layer)
            return w.target
        end})
        function map:getObjectTotal(x, y)
            record(name .. ":object-count", x, y)
            return #(self.objects[x + y * self.w] or {})
        end
        function map:getObject(x, y, z) record(name .. ":get-object", x, y, z); return self.objects[x + y * self.w][z] end
        function map:removeObject(x, y, z) record(name .. ":remove-object", x, y, z); table.remove(self.objects[x + y * self.w], z) end
        function map:addObject(x, y, object)
            record(name .. ":add-object", x, y, object)
            local key = x + y * self.w
            self.objects[key] = self.objects[key] or {}
            self.objects[key][#self.objects[key]+1] = object
        end
        function map:particleEmitter(...) record(name .. ":emitter", ...); self.particles[#self.particles+1] = {active = true} end
        function map:redisplay() record(name .. ":redisplay") end
        function map:recreate() record(name .. ":recreate") end
        function map:checkEntity(...) record(name .. ":check-entity", ...); return options.wall end
        function lv:hasEntity(actor) record(name .. ":has-entity", actor); return self.entities[actor.uid] == actor end
        function lv:removeEntity(actor, ...) record(name .. ":remove-entity", actor, ...); self.entities[actor.uid] = nil end
        function lv:addEntity(actor) record(name .. ":add-entity", actor); self.entities[actor.uid] = actor end
        return lv
    end
    w.source, w.plane, w.historical = level("source"), level("plane"), level("historical")
    w.source_zone, w.plane_zone, w.historical_zone = {short_name = "source", levels = {}},
        {short_name = "demon-plane-spell", is_demon_plane = true}, {short_name = "historical"}
    w.tags[w.source_zone], w.tags[w.plane_zone], w.tags[w.historical_zone] = "source-zone", "plane-zone", "historical-zone"
    w.source_zone.levels[2], w.source_zone.levels[3] = w.source, w.historical
    function w.plane_zone:getLevel(g, ...) record("get-plane-level", g, ...); return w.plane end
    env.mod = {class = {Zone = {new = function(name) record("new-zone", name); return w.plane_zone end}}}
    game.zone, game.level = w.source_zone, w.source
    env.util = {findFreeGrid = function(x, y, ...)
        w.grids = w.grids + 1
        record("grid:" .. w.grids, x, y, ...)
        if w.phase == "exit" and (options.no_grid == w.grids or options.no_grid == "both") then return nil end
        return x, y
    end}

    local function actor(name, uid, x, y)
        local a = {name = name, uid = uid, x = x, y = y, sustain_talents = {}, T_DEMON_PLANE = "T_DEMON_PLANE"}
        w.tags[a] = name
        function a:attr(key, delta)
            record(name .. ":attr", key, delta)
            if delta then self[key] = (self[key] or 0) + delta end
            return self[key]
        end
        function a:canBe(key) record(name .. ":can-be", key); return true end
        function a:getTalentTarget(t) record(name .. ":talent-target", t); return {talent = t} end
        function a:getTarget(tg) record(name .. ":get-target", tg); return w.target.x, w.target.y, w.target end
        function a:canProject(tg, tx, ty) record(name .. ":project", tg, tx, ty); return true, tx, ty end
        function a:combatTalentSpellDamage(t, low, high) record(name .. ":damage", t, low, high); return 25 end
        function a:move(...) record(name .. ":move", ...); self.x, self.y = ... end
        function a:setTarget(target) record(name .. ":set-target", target); self.ai_target = {actor = target} end
        function a:attachementSpot(...) record(name .. ":spot", ...); return 1, 2 end
        function a:addParticles(p) record(name .. ":add-particles", p); return p end
        function a:removeParticles(p) record(name .. ":remove-particles", p) end
        function a:teleportRandom(...) record(name .. ":teleport", ...); self.x, self.y = 6, 6 end
        function a:forceUseTalent(id, args)
            record(name .. ":force-talent", id, args)
            local t, state = w.talent, self.sustain_talents[id]
            local result = t.deactivate(self, t, state)
            if result then self.sustain_talents[id] = nil end
            return result
        end
        function a:die(...) record(name .. ":die", ...); self.dead = true end
        a.on_die = function(self, ...)
            record(name .. ":original-on-die", self, ...)
            w.original_deaths[name] = pack(...)
            if name == "target" then check(self.demon_plane_trapper == w.caster, "target death callback retains its original trapper") end
        end
        return a
    end
    w.caster, w.target, w.other = actor("caster", 1, 2, 3), actor("target", 2, 5, 7), actor("other", 3, 10, 10)
    w.original_caster_die, w.original_target_die = w.caster.on_die, w.target.on_die
    if options.no_original_caster_die then w.caster.on_die, w.original_caster_die = nil, nil end
    if options.no_original_target_die then w.target.on_die, w.original_target_die = nil, nil end
    w.unknown = function() record("unknown-callback") end
    w.target.player, w.target.game_ender = true, true
    game.player = w.target; game.party.members[w.target] = true
    if options.caster_party then game.party.members[w.caster] = true end
    w.source.entities[w.caster.uid], w.source.entities[w.target.uid] = w.caster, w.target
    w.plane.entities[w.other.uid] = w.other
    w.object1, w.object2 = {name = "loot-1"}, {name = "loot-2"}
    w.tags[w.object1], w.tags[w.object2] = "loot-1", "loot-2"
    w.plane.map.objects[13] = {w.object1, w.object2}
    w.historical.map.objects[7] = {{name = "historical-loot"}}
    w.target.ai_actors_seen = {[w.caster] = 97}
    w.target.distance_map = {[1] = 123}
    w.caster.ai_state = {astar = {map = w.plane.map}}

    local Talents = {talents_def = {}}
    env.newTalent = function(t)
        t.id = "T_" .. (t.short_name or t.name):upper():gsub("[ ']", "_")
        Talents.talents_def[t.id] = t
    end
    run(string.rep("\n", options.source_shift or 0) .. talent_source, options.source or "@/data/talents/corruptions/shadowflame.lua", env)
    w.Talents, w.talent = Talents, Talents.talents_def.T_DEMON_PLANE
    w.tags[w.talent] = "Fearscape"
    w.original_activate, w.original_deactivate = w.talent.activate, w.talent.deactivate
    if options.before_install == "activate" then w.talent.activate = w.unknown end
    if options.before_install == "deactivate" then w.talent.deactivate = w.unknown end
    if optimized then
        w.installed, w.reason = Faster.installTalents(Talents, options.settings or {fearscape_cleanup = true})
        if options.source or options.source_shift or options.before_install or options.settings and options.settings.fearscape_cleanup == false then
            check(not w.installed, "unrecognized or disabled talent stays unchanged")
        else check(w.installed, "install the pinned Fearscape exit") end
    end
    return w
end

local function enter(w)
    w.phase, w.grids = "enter", 0
    w.state = w.talent.activate(w.caster, w.talent)
    w.caster.sustain_talents[w.talent.id] = w.state
    w.game:onTickEndExecute()
    check(w.target.demon_plane_trapper == w.caster, "actual activation records the caster")
    check(w.game.level == w.plane and w.plane.source_level == w.source, "actual activation enters the temporary plane")
    check(w.target.on_die ~= w.original_target_die and w.caster.on_die ~= w.original_caster_die, "actual activation installs both death wrappers")
    if w.options.restored_wrappers then
        -- Stock serialized functions retain their source boundaries. Loading
        -- these callbacks needs only their original environment, never Faster.
        w.target.on_die = setfenv(assert(loadstring(string.dump(w.target.on_die))), w.env)
        w.caster.on_die = setfenv(assert(loadstring(string.dump(w.caster.on_die))), w.env)
    end
    w.target_wrapper, w.caster_wrapper = w.target.on_die, w.caster.on_die
end

local function mutate(w, option)
    if option == "other-trapper" then w.target.demon_plane_trapper = w.other
    elseif option == "target-wrapper" then w.target.on_die = w.unknown
    elseif option == "caster-wrapper" then w.caster.on_die = w.unknown
    elseif option == "restored-callback" then w.target.demon_plane_on_die = w.unknown
    elseif option == "activate" then w.talent.activate = w.unknown
    elseif option == "deactivate" then w.talent.deactivate = w.unknown
    elseif option == "clone" then w.caster.on_die = nil
    elseif option == "wrong-owner" then w.plane.plane_owner = w.other
    elseif option == "wrong-zone" then w.plane_zone.short_name = "addon-plane"
    elseif option == "other-target" then w.state.target = w.other
    elseif option == "still-active" then w.caster.sustain_talents.T_DEMON_PLANE = w.state
    elseif option == "historical" then w.source_zone.levels[12] = w.plane
    elseif option then error("unknown mutation " .. tostring(option)) end
end

local function exit(w)
    w.phase, w.grids = "exit", 0
    mutate(w, w.options.before_exit)
    local invoking = w.talent.deactivate
    if w.options.later_wrapper then
        local previous = invoking
        w.talent.deactivate = function(...)
            w.record("addon-deactivate")
            return previous(...)
        end
        invoking = w.talent.deactivate
    end
    if w.options.other_talent then
        w.talent_argument = {id = "T_OTHER", activate = w.talent.activate, deactivate = invoking}
    else w.talent_argument = w.talent end
    local result
    if w.options.death then
        local actor = w.options.death == "target" and w.target or w.caster
        actor.dead = true
        result = pack(pcall(actor.on_die, actor, w.other, 17, nil, false))
    else
        result = pack(pcall(invoking, w.caster, w.talent_argument, w.state))
        if result[1] and result[2] then w.caster.sustain_talents[w.talent.id] = nil end
    end
    w.invoke_result = result
    mutate(w, w.options.pending)
    if w.options.pending == "still-active" then w.caster.sustain_talents.T_DEMON_PLANE = w.state end
    w.tick_result = pack(pcall(w.game.onTickEndExecute, w.game))
    w.after = {caster_x = w.caster.x, caster_y = w.caster.y, target_x = w.target.x, target_y = w.target.y,
        target_die = w.target.on_die, caster_die = w.caster.on_die, target_original = w.target.demon_plane_on_die,
        caster_original = w.caster.demon_plane_on_die, level = w.game.level, zone = w.game.zone}
end

local function equivalent_result(a, b)
    check(a.n == b.n and a[1] == b[1], "same success and return arity")
    if a[1] then
        for i = 2, a.n do check(a[i] == b[i], "same original return value") end
    else check(type(a[2]) == type(b[2]), "same failure kind") end
end
local function compare(options, cleans)
    cases = cases + 1
    local a, b = world(false, options), world(true, options)
    enter(a); enter(b)
    exit(a); exit(b)
    if not options.fail then
        check(a.invoke_result[1] and b.invoke_result[1], "exit invocation succeeds: " .. tostring(a.invoke_result[2]) .. " / " .. tostring(b.invoke_result[2]))
        check(a.tick_result[1] and b.tick_result[1], "exit callback succeeds: " .. tostring(a.tick_result[2]) .. " / " .. tostring(b.tick_result[2]))
    end
    if table.concat(a.trace, "\n") ~= table.concat(b.trace, "\n") then
        for i = 1, math.max(#a.trace, #b.trace) do
            if a.trace[i] ~= b.trace[i] then
                error("trace mismatch case " .. cases .. ", line " .. i .. "\nbase=" .. tostring(a.trace[i]) .. "\nfast=" .. tostring(b.trace[i]))
            end
        end
    end
    check(true, "actual callbacks retain call order and exact arguments")
    equivalent_result(a.invoke_result, b.invoke_result); equivalent_result(a.tick_result, b.tick_result)
    if options and options.fail then
        local ar = a.invoke_result[1] and a.tick_result or a.invoke_result
        local br = b.invoke_result[1] and b.tick_result or b.invoke_result
        check(not ar[1] and ar[2] == a.failure and not br[1] and br[2] == b.failure, "exact original error object propagates")
    end
    local expected
    if not cleans then expected = a.tags[a.target.demon_plane_trapper] end
    check(b.tags[b.target.demon_plane_trapper] == expected, "cleanup is bounded to the completed capture, case " .. cases)
    if cleans then check(a.target.demon_plane_trapper == a.caster and b.target.demon_plane_trapper == nil, "only successful exit drops trapper") end
    check(a.after.caster_x == b.after.caster_x and a.after.caster_y == b.after.caster_y
        and a.after.target_x == b.after.target_x and a.after.target_y == b.after.target_y, "same restored coordinates")
    check(a.tags[a.after.level] == b.tags[b.after.level] and a.tags[a.after.zone] == b.tags[b.after.zone], "same level and zone")
    check((a.after.target_die == a.original_target_die) == (b.after.target_die == b.original_target_die)
        and (a.after.caster_die == a.original_caster_die) == (b.after.caster_die == b.original_caster_die), "same restored death callback identities")
    check((a.after.target_original == nil) == (b.after.target_original == nil)
        and (a.after.caster_original == nil) == (b.after.caster_original == nil), "same saved death callbacks")
    for _, name in ipairs{"source", "plane", "historical"} do
        local la, lb = a[name], b[name]
        check(#la.map.particles == #lb.map.particles and lb.map.particles[1].active, "preserve all " .. name .. " map particle records")
        for uid = 1, 3 do check(a.tags[la.entities[uid]] == b.tags[lb.entities[uid]], "same " .. name .. " entity membership") end
        for key, objs in pairs(la.map.objects) do
            check(lb.map.objects[key] and #objs == #lb.map.objects[key], "same " .. name .. " loose-object stacks")
            for i = 1, #objs do check(objs[i].name == lb.map.objects[key][i].name, "same loose-object identity by name") end
        end
    end
    check(b.target.ai_actors_seen[b.caster] == 97 and b.target.distance_map[1] == 123,
        "AI history and distance history are not altered")
    check(b.caster.ai_state.astar.map == b.plane.map and b.source_zone.levels[3] == b.historical,
        "Astar map and persistent historical level remain untouched")
    check(#a.game.on_tick_end.fcts == #b.game.on_tick_end.fcts, "no additional deferred callbacks")
    return a, b
end

compare({}, true)
compare({shader = true}, true)
compare({wall = true}, true)
compare({no_original_target_die = true, no_original_caster_die = true}, true)
compare({death = "caster"}, true)
compare({death = "caster", caster_party = true, shader = true, wall = true}, true)
compare({death = "target"}, false)
compare({death = "target", shader = true}, false)
compare({death = "target", no_original_target_die = true}, false)
compare({restored_wrappers = true}, true)
compare({restored_wrappers = true, death = "caster"}, true)
compare({restored_wrappers = true, death = "target"}, false)
compare({before_exit = "clone"}, false)
for _, grid in ipairs{1, 2, "both"} do
    compare({no_grid = grid}, false)
    compare({no_grid = grid, death = "caster"}, false)
    compare({no_grid = grid, death = "target"}, false)
end
for _, field in ipairs{"other-trapper", "target-wrapper", "caster-wrapper", "wrong-owner", "wrong-zone", "activate", "deactivate"} do
    compare({before_exit = field}, false)
end
for _, field in ipairs{"other-trapper", "target-wrapper", "caster-wrapper", "restored-callback", "activate", "wrong-owner", "other-target", "still-active"} do
    compare({pending = field}, false)
end
compare({later_wrapper = true}, false)
compare({other_talent = true}, false)
compare({before_exit = "historical"}, true)
for _, changed in ipairs{"log-other-trapper", "log-other-level", "log-target-wrapper", "log-other-sustain", "log-target-dies"} do
    compare({during = changed}, false)
end
for _, name in ipairs{"caster:remove-particles", "plane:object-count", "plane:get-object", "plane:remove-object",
    "plane:remove-entity", "source:add-entity", "grid:1", "caster:move", "source:emitter", "grid:2", "target:move",
    "source:add-object", "other:die", "source:redisplay", "source:recreate", "minimap", "tiles", "source:check-entity",
    "target:teleport", "exit-log"} do
    compare({shader = true, wall = true, fail = name}, false)
end
compare({settings = {fearscape_cleanup = false}}, false)
compare({settings = {}}, true)
compare({source = "@/mod/addons/other/data/talents/corruptions/shadowflame.lua"}, false)
compare({source_shift = 1}, false)

do
    local w = world(true)
    local f = w.talent.deactivate
    check(Faster.installTalents(w.Talents, {fearscape_cleanup = true}), "reinstall is idempotent")
    check(w.talent.deactivate == f and w.talent.activate == w.original_activate, "idempotence leaves activation and exit identities unchanged")
    w.talent.activate = w.unknown
    check(not Faster.installTalents(w.Talents, {fearscape_cleanup = true}), "later activation override is not treated as our installation")
    check(w.talent.deactivate == f and w.talent.activate == w.unknown, "unknown activation is left untouched")
end
for _, method in ipairs{"activate", "deactivate"} do
    local w = world(true, {before_install = method})
    check(w.talent[method] == w.unknown, "unknown " .. method .. " remains installed")
end
check(not Faster.installTalents({talents_def = {}}, {fearscape_cleanup = true}), "missing talent safely skipped")
for _, omitted in ipairs{"settings", "field"} do
    local w = world(false)
    check(not Faster.installTalents(w.Talents, {fearscape_cleanup = "true"}) and w.talent.deactivate == w.original_deactivate, "invalid Fearscape option keeps original method")
    check(Faster.installTalents(w.Talents, omitted == "field" and {} or nil), "omitted " .. omitted .. " installs Fearscape cleanup")
    check(w.talent.deactivate ~= w.original_deactivate and w.talent.activate == w.original_activate, "default install preserves original activation")
end

do
    local w = world(true)
    w.env.game = nil
    local clone = {on_die = nil}
    local result = pack(pcall(w.talent.deactivate, clone, nil, nil))
    check(result.n == 2 and result[1] and result[2], "stock clone early return needs no game or talent state")
end

-- Loading an old, already-ended capture supplies no proof that its exit and
-- death callbacks completed. Merely installing the module must not edit it.
do
    local w = world(false)
    w.caster.dead, w.target.demon_plane_trapper = true, w.caster
    w.caster.ai_state.astar.map = w.historical.map
    check(Faster.installTalents(w.Talents, {fearscape_cleanup = true}), "module can install alongside an old save")
    check(w.target.demon_plane_trapper == w.caster and w.caster.ai_state.astar.map == w.historical.map,
        "old detached reference and legitimate historical map are not migrated")
end

-- Repeat a completed activation/exit with the same actors. A new capture must
-- work after clearing the old field, and callback identity must remain stock.
do
    local a, b = compare({}, true)
    for _, w in ipairs{a, b} do
        enter(w); exit(w)
        check(w.target.on_die == w.original_target_die, "second exit restores original target callback")
    end
    check(a.target.demon_plane_trapper == a.caster and b.target.demon_plane_trapper == nil, "cleanup is repeatable across independent captures")
    check(table.concat(a.trace, "\n") == table.concat(b.trace, "\n"), "second capture retains the actual callback trace")
end

do
    local weak = setmetatable({}, {__mode = "v"})
    do
        local w = world(true)
        enter(w); exit(w)
        weak[1], weak[2], weak[3] = w.target, w.caster, w.talent
    end
    collectgarbage("collect"); collectgarbage("collect")
    check(weak[1] == nil and weak[2] == nil and weak[3] == nil,
        "installation tokens retain no completed actors or talent environments")
end
print(("Fearscape cleanup: %d scenarios, %d checks passed"):format(cases, checks))
