-- GPL-3.0-or-later. Differential saveGame tests against the pinned engine body.
-- Only the discarded Party clone/cleanup and its temporary UUID lookup differ.
assert(_VERSION == "Lua 5.1", "Lua 5.1 / LuaJIT required")
local root = arg[1] or "."
local repo = assert(arg[2], "pass a local ToME source Git clone as argument 2")
local commit = "624a67329fe2ad440c5b344785a9c73fcf22ae63"
local function quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
local pipe = assert(io.popen("git -C " .. quote(repo) .. " show " ..
    quote(commit .. ":game/modules/tome/class/Game.lua"), "r"))
local source = pipe:read("*a"); assert(pipe:close()); assert(#source > 0)
local first = assert(source:find("function _M:saveGame()", 1, true))
local last = assert(source:find("--- Take a screenshot of the game", first, true))
local _, lines = source:sub(1, first - 1):gsub("\n", "")
local code = string.rep("\n", lines) .. source:sub(first, last - 1)
local cultsCode
if arg[3] and arg[3] ~= "" then
    local path = arg[3] .. "/cults/tome-cults/superload/mod/class/Game.lua"
    local digest = assert(io.popen("sha256sum -- " .. quote(path), "r"))
    local result = digest:read("*a"); assert(digest:close())
    assert(result:sub(1, 64) == "765df32782249dfb0d2db6a80a30c81052b40494456332815d95052ee0aef008",
        "Cults source differs from reviewed official fixture")
    local file = assert(io.open(path, "rb"))
    local official = file:read("*a"); file:close()
    local selected, line = {}, 0
    -- Execute the actual Dialog/loadPrevious declarations and save wrapper;
    -- preserve their real positions without running unrelated DLC methods.
    for text in official:gmatch("([^\n]*)\n") do
        line = line + 1
        if line > 41 then break end
        selected[line] = (line == 22 or line == 23 or line >= 31) and text or ""
    end
    assert(#selected == 41)
    cultsCode = table.concat(selected, "\n") .. "\n"
end
local Faster = assert(loadfile(root .. "/overload/engine/FasterExportCleanup.lua"))()
local checks, cases = 0, 0
local function check(ok, message) assert(ok, message); checks = checks + 1 end
local function pack(...) return {n = select("#", ...), ...} end
local function pinned(env, name)
    local Game = {}
    env._M = Game
    setfenv(assert(loadstring(code, name or "@/mod/class/Game.lua")), env)()
    return Game
end
local function delegate(wrapper)
    for i = 1, 20 do
        local name, value = debug.getupvalue(wrapper, i)
        if not name then break end
        if name == "saveGame" then return value, i end
    end
    error("official Cults wrapper has no saveGame delegate")
end
local function wrapCults(w, name)
    assert(cultsCode, "pass DLC source parent directory as argument 3 for Cults cases")
    local dialog = {}
    w.tags[dialog], w.fled = "cults-dialog", 0
    function dialog:yesnoPopup(title, message, callback)
        w.record("smack-popup", false, self, title, message)
        check(type(callback) == "function", "official popup receives callback")
        w.popup = callback
    end
    w.env._t = function(text) return text end
    w.env.loadPrevious = function() return w.Game end
    w.env.require = function(module)
        if module == "engine.ui.Dialog" then return dialog end
        if module == "mod.class.CultsDLC" then
            return {backFromSMACK = function(...)
                w.record("smack-back", false, ...)
                w.fled = w.fled + 1
            end}
        end
        error("unexpected DLC fixture dependency: " .. module)
    end
    setfenv(assert(loadstring(cultsCode, name or "@/mod/addons/cults/superload/mod/class/Game.lua")), w.env)()
    w.wrapper = w.Game.saveGame
    check(delegate(w.wrapper) == w.base, "actual Cults wrapper captures pinned base method")
end

local function world(optimized, options)
    options = options or {}
    local w = {trace = {}, discarded = {}, tags = {}, exports = 0, orders = 0, clones = 0}
    local env = setmetatable({}, {__index = _G})
    env._G = env
    local current = {name = "controlled", quick = 0, life = 123, __te4_uuid = "controlled-uuid"}
    local leader = {name = "leader", quick = 0, life = 456, __te4_uuid = "leader-uuid"}
    local live = {player = current, save_name = "fixture-save", creating_player = options.creating}
    w.current, w.leader, w.live, w.env = current, leader, live, env
    w.failure = {}; w.tags[w.failure] = "failure:" .. tostring(options.fail)
    w.tags[live], w.tags[current], w.tags[leader] = "live", "controlled", "leader"
    local function token(value)
        if type(value) == "table" then return assert(w.tags[value], "untagged fixture argument") end
        return type(value) .. ":" .. tostring(value)
    end
    local function record(name, discarded, ...)
        local values = {name, "global=" .. token(env.game), "player=" .. token(live.player)}
        for i = 1, select("#", ...) do values[#values + 1] = token(select(i, ...)) end
        local target = discarded and w.discarded or w.trace
        target[#target + 1] = table.concat(values, "|")
        if options.fail == name then error(w.failure, 0) end
    end
    w.record = record
    local memberOrder = {}
    env.pairs = function(t)
        if not memberOrder[t] then return pairs(t) end
        local i = 0
        return function()
            i = i + 1
            if memberOrder[t][i] then return memberOrder[t][i], true end
        end
    end
    local party = {members = {}}
    w.tags[party] = "live-party"
    party.members[current], party.members[leader] = true, true
    memberOrder[party.members] = options.empty_members and {} or {current, leader}
    if options.no_party then party = nil end
    live.party = party
    local switches = 0
    if party then
        function party:setPlayer(player, force)
            switches = switches + 1
            record("setPlayer:" .. switches, false, self, player, force)
            live.player = player
        end
    end
    function live:registerHighscore() record("score", false, self) end
    function live:getPlayer(main)
        record("get-live-player", false, self, main)
        return leader
    end
    live.log = function(...) record("log", false, ...) end
    env.config = {settings = {tome = {upload_charsheet = options.upload ~= false}}}
    env.profile = {auth = options.online and {} or false, hash_valid = true}
    env.engine = {interface = {PlayerHotkeys = {updateQuickHotkeys = function(self, actor)
        record("hotkey:" .. actor.name, false, self, actor)
        actor.quick = actor.quick + 1
    end}}}
    w.tags[env.engine.interface.PlayerHotkeys] = "hotkeys-interface"
    env.world = {saveWorld = function(self) record("world", false, self) end}
    w.tags[env.world] = "world"
    env.print = function(...) record("print", false, ...) end
    local prior = {}; w.tags[prior] = "prior-global"
    env.game = options.prior_global and prior or live
    w.prior = env.game
    env.savefile_pipe = {push = function(self, name, kind, value, ...)
        record("push", false, self, name, kind, value, ...)
        check(value == live and value.player == current, "push snapshots original controlled player")
        local snapshotPlayer = {name = current.name, quick = current.quick, life = current.life,
            __te4_uuid = current.__te4_uuid, __no_save_json = options.no_json}
        local snapshotLeader = {name = leader.name, quick = leader.quick, life = leader.life,
            __te4_uuid = leader.__te4_uuid}
        local snapshot = {player = snapshotPlayer, party = {members = {}}}
        w.snapshot, w.snapshotPlayer = snapshot, snapshotPlayer
        w.tags[snapshot], w.tags[snapshot.party] = "snapshot", "snapshot-party"
        w.tags[snapshotPlayer], w.tags[snapshotLeader] = "snapshot-controlled", "snapshot-leader"
        memberOrder[snapshot.party.members] = {snapshotPlayer, snapshotLeader}
        snapshot.party.members[snapshotPlayer], snapshot.party.members[snapshotLeader] = true, true
        function snapshot:getPlayer(main)
            record("get-discarded-uuid", true, self, main)
            return snapshotLeader
        end
        function snapshotPlayer:saveUUID(...)
            record("export", false, self, ...)
            check(env.game == snapshot and live.player == leader, "export sees snapshot and switched live party")
            check(select("#", ...) == 1 and (...) == nil, "saveUUID receives exactly one nil argument")
            w.exports = w.exports + 1
            if env.profile.auth and env.profile.hash_valid then
                record("online-consumer", false, self.__te4_uuid, self.life, self.quick)
                w.orders = w.orders + 1
            end
            return "ignored exporter result", nil, false
        end
        function snapshot.party:cloneFull()
            record("discard-clone", true, self)
            w.clones = w.clones + 1
            local disposable = {members = {}}
            w.tags[disposable] = "discarded-party"
            local order = {}
            for i = 1, 2 do
                local member = {cleanup = 0}
                w.tags[member] = "discarded-member:" .. i
                disposable.members[member], order[i] = true, member
                function member:attr(name, delta)
                    record("discard-member-attr:" .. i, true, self, name, delta)
                    self.cleanup = self.cleanup + delta
                end
                function member:stripForExport()
                    record("discard-member-strip:" .. i, true, self)
                    check(self.cleanup == 1, "baseline uses cleanup mode for discarded member")
                end
            end
            memberOrder[disposable.members] = order
            function disposable:attr(name, delta)
                record("discard-party-attr", true, self, name, delta)
            end
            function disposable:stripForExport() record("discard-party-strip", true, self) end
            return disposable
        end
        return snapshot
    end}
    w.tags[env.savefile_pipe] = "save-pipe"
    local Game = pinned(env)
    setmetatable(live, {__index = Game})
    w.Game, w.base = Game, Game.saveGame
    if options.cults then
        if options.chronoworld then live._chronoworlds = {multiverse_fight = options.smack} end
        wrapCults(w, options.cults_source)
    end
    w.original = Game.saveGame
    if optimized then check(Faster.installGame(Game), "install pinned saveGame") end
    return w
end

local function run(w)
    w.result = pack(pcall(w.live.saveGame, w.live))
    return w
end
local function sameResult(a, b)
    check(a.result.n == b.result.n and a.result[1] == b.result[1], "same success and return arity")
    if not a.result[1] then
        check(a.result[2] == a.failure and b.result[2] == b.failure, "same original error object propagates")
    else
        check(a.result.n == 1, "saveGame retains zero return values")
    end
end
local function compare(options)
    local a, b = run(world(false, options)), run(world(true, options))
    check(table.concat(a.trace, "\n") == table.concat(b.trace, "\n"),
        "same retained call order, arguments and context for " .. tostring(options and options.fail))
    sameResult(a, b)
    check(a.tags[a.env.game] == b.tags[b.env.game], "same final global game")
    check(a.tags[a.live.player] == b.tags[b.live.player], "same final controlled player")
    check(a.exports == b.exports and a.orders == b.orders, "same export and online call count")
    check(a.current.quick == b.current.quick and a.leader.quick == b.leader.quick, "same hotkey updates")
    check(a.current.life == b.current.life and a.leader.life == b.leader.life, "live actors unchanged")
    check(b.clones == 0 and #b.discarded == 0, "optimized path never builds or touches discarded party")
    if a.snapshot and b.snapshot then
        check(a.snapshotPlayer.__te4_uuid == b.snapshotPlayer.__te4_uuid and
            a.snapshotPlayer.quick == b.snapshotPlayer.quick and
            a.snapshotPlayer.life == b.snapshotPlayer.life, "same snapshot player inputs")
    end
    cases = cases + 1
    return a, b
end

for _, online in ipairs{false, true} do
    for _, flags in ipairs{{}, {creating = true}, {upload = false}, {no_json = true},
        {empty_members = true}, {prior_global = true}, {no_party = true, upload = false}} do
        local options = {online = online}
        for k, v in pairs(flags) do options[k] = v end
        local a, b = compare(options)
        check(a.result[1] and b.result[1], "normal save succeeds")
        local exporting = not options.creating and options.upload ~= false and not options.no_json
        check(b.exports == (exporting and 1 or 0), "export gating unchanged")
        check(b.orders == (exporting and online and 1 or 0), "online consumer call retained")
        check(a.clones == (exporting and 1 or 0), "baseline really executes discarded clone")
        check(b.live.player == b.current, "normal save restores controlled actor")
        local enters = not options.creating and options.upload ~= false
        check(b.env.game == (enters and b.live or b.prior), "original global restoration rule retained")
    end
end

-- The upstream pcall covers only the export block. Do not turn this into a
-- broader finally/pcall that swallows earlier failures or changes restoration.
for _, fail in ipairs{"score", "hotkey:controlled", "hotkey:leader", "push", "world",
    "get-live-player", "setPlayer:1", "export", "online-consumer", "print", "setPlayer:2", "log"} do
    local _, b = compare{fail = fail, online = true, prior_global = true}
    local swallowed = fail == "export" or fail == "online-consumer"
    check(b.result[1] == swallowed, "only export failures are swallowed: " .. fail)
    if swallowed then
        check(b.env.game == b.live and b.live.player == b.current, "export error restores both contexts")
        check(b.trace[#b.trace]:find("log|", 1, true) == 1, "export error still reaches final log")
    elseif fail == "print" then
        check(b.env.game == b.snapshot and b.live.player == b.leader, "print error retains original partial context")
    elseif fail == "setPlayer:2" then
        check(b.env.game == b.live and b.live.player == b.leader, "restore error retains original partial state")
    elseif fail == "log" then
        check(b.env.game == b.live and b.live.player == b.current, "log failure follows normal restoration")
    else
        check(b.env.game == b.prior and b.live.player == b.current, "early failure precedes context switch")
    end
end

-- Removed callbacks intentionally no longer run (including their errors).
-- This is not an assertion that temporary RNG/UID/callback side effects match.
for _, fail in ipairs{"discard-clone", "get-discarded-uuid", "discard-member-attr:1",
    "discard-member-strip:1", "discard-party-attr", "discard-party-strip"} do
    local b = run(world(true, {online = true, fail = fail}))
    check(b.result[1] and b.exports == 1 and b.orders == 1, "discarded callback cannot block export: " .. fail)
    check(#b.discarded == 0 and b.env.game == b.live and b.live.player == b.current,
        "removed callback is never invoked and context restores")
end

do
    local w = world(false)
    check(not Faster.installGame(w.Game, {unused_party_cleanup = false}) and w.Game.saveGame == w.original,
        "explicit opt-out leaves original method")
    run(w)
    check(w.clones == 1 and w.exports == 1, "opt-out retains original discarded cleanup and export")
    check(Faster.installGame(w.Game, {}), "empty options enables optimization")
    local optimized = w.Game.saveGame
    check(Faster.installGame(w.Game) and w.Game.saveGame == optimized, "install is idempotent")
    local override = function() return "other-addon", nil, false end
    w.Game.saveGame = override
    check(not Faster.installGame(w.Game) and w.Game.saveGame == override, "later addon override retained")
    local result = pack(w.Game.saveGame())
    check(result.n == 3 and result[1] == "other-addon" and result[3] == false, "unknown override remains callable")
    check(not Faster.installGame({}), "missing method skipped")
    check(not Faster.installGame({saveGame = "not a function"}), "invalid method skipped")
    check(not Faster.installGame({saveGame = print}), "native method skipped")
    local env = setmetatable({}, {__index = _G})
    local other = pinned(env, "@/another-addon/Game.lua")
    local original = other.saveGame
    check(not Faster.installGame(other) and other.saveGame == original, "same body with unknown source skipped")
    local shifted = {}
    env._M = shifted
    setfenv(assert(loadstring("\n" .. code, "@/mod/class/Game.lua")), env)()
    original = shifted.saveGame
    check(not Faster.installGame(shifted) and shifted.saveGame == original, "changed source layout skipped")
end

if cultsCode then
    for _, flags in ipairs{{}, {chronoworld = true}, {chronoworld = true, smack = false},
        {online = true}, {creating = true}, {upload = false}, {no_json = true},
        {fail = "export"}, {fail = "world"}, {fail = "setPlayer:2"}} do
        flags.cults = true
        local a, b = compare(flags)
        check(b.Game.saveGame == b.wrapper, "Cults wrapper identity retained")
        check(delegate(b.wrapper) ~= b.base, "only the base delegate is optimized")
        check(not b.popup and b.fled == 0, "ordinary saves do not enter S.M.A.C.K. handling")
        check(a.clones == ((not flags.creating and flags.upload ~= false and not flags.no_json and
            flags.fail ~= "world") and 1 or 0), "Cults baseline reaches discarded cleanup only when permitted")
    end
    for _, answer in ipairs{false, true} do
        local a, b = compare{cults = true, chronoworld = true, smack = true, online = true}
        check(a.popup and b.popup and #a.trace == 1 and #b.trace == 1, "S.M.A.C.K. only opens original popup")
        check(a.clones == 0 and b.clones == 0 and a.exports == 0 and b.exports == 0,
            "S.M.A.C.K. never enters base save or exporter")
        check(b.env.game == b.live and b.live.player == b.current, "blocked save never changes contexts")
        a.popup(answer); b.popup(answer)
        check(table.concat(a.trace, "\n") == table.concat(b.trace, "\n"), "same official cancel/confirm callback arguments")
        check(a.fled == (answer and 1 or 0) and b.fled == a.fled, "only confirmation calls backFromSMACK")
        check(b.exports == 0 and b.clones == 0, "confirmation does not resume forbidden save")
    end
    do
        local w = world(false, {cults = true})
        local wrapper, base = w.wrapper, delegate(w.wrapper)
        check(not Faster.installGame(w.Game, {unused_party_cleanup = false}), "Cults opt-out")
        check(w.Game.saveGame == wrapper and delegate(wrapper) == base, "Cults opt-out preserves both layers")
        check(Faster.installGame(w.Game), "install recognized Cults delegate")
        local optimized = delegate(wrapper)
        check(Faster.installGame(w.Game) and w.Game.saveGame == wrapper and delegate(wrapper) == optimized,
            "Cults repeated install preserves wrapper and delegate identity")
        local unknown = function() return "custom-save", nil, false end
        local _, slot = delegate(wrapper)
        debug.setupvalue(wrapper, slot, unknown)
        check(not Faster.installGame(w.Game) and w.Game.saveGame == wrapper and delegate(wrapper) == unknown,
            "later unknown Cults delegate is retained and reported as fallback")
        local values = pack(w.live:saveGame())
        check(values.n == 3 and values[1] == "custom-save" and values[3] == false,
            "official wrapper retains unknown delegate's return values")
    end
    do
        local w = world(false, {cults = true})
        local _, slot = delegate(w.wrapper)
        local unknown = function() return "custom-base" end
        debug.setupvalue(w.wrapper, slot, unknown)
        check(not Faster.installGame(w.Game) and w.Game.saveGame == w.wrapper and delegate(w.wrapper) == unknown,
            "official wrapper with initially unknown inner method is skipped")
        debug.setupvalue(w.wrapper, slot, nil)
        check(not Faster.installGame(w.Game) and delegate(w.wrapper) == nil, "missing Cults delegate is skipped")
        local other = world(false, {cults = true, cults_source = "@/another-addon/cults/Game.lua"})
        check(not Faster.installGame(other.Game) and other.Game.saveGame == other.wrapper and
            delegate(other.wrapper) == other.base, "unrecognized wrapper source is skipped")
    end
    print("PASS Cults: actual hash-verified wrapper; arena popup, callbacks, delegate identity and fallbacks")
else
    print("SKIP Cults fixtures: pass the DLC source parent directory as argument 3")
end

print(("PASS export cleanup: %d differential save scenarios, %d assertions; gating, online call, context, errors and guards")
    :format(cases, checks))
