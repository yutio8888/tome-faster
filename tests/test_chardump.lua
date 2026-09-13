-- GPL-3.0-or-later. Execute pinned exporter/consumer bodies, never spoof guards.
assert(_VERSION == "Lua 5.1", "Lua 5.1 / LuaJIT required")
local root = arg[1] or "."
local repo = assert(arg[2], "pass a local ToME source Git clone as argument 2")
local commit = "624a67329fe2ad440c5b344785a9c73fcf22ae63"
local function quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
local function pinned(path)
    local p = assert(io.popen("git -C " .. quote(repo) .. " show " .. quote(commit .. ":" .. path), "r"))
    local source = p:read("*a"); assert(p:close()); assert(#source > 0)
    return source
end
local function section(source, first, last)
    local a = assert(source:find(first, 1, true))
    local b = last and assert(source:find(last, a, true)) or #source + 1
    local _, lines = source:sub(1, a - 1):gsub("\n", "")
    return string.rep("\n", lines) .. source:sub(a, b - 1)
end
local function run(source, name, env)
    return setfenv(assert(loadstring(source, name)), env)()
end
local checks = 0
local function check(ok, message) assert(ok, message); checks = checks + 1 end
local function pack(...) return {n = select("#", ...), ...} end
local function addon() return assert(loadfile(root .. "/overload/engine/FasterChardump.lua"))() end
local engineSource = pinned("game/engines/default/engine/interface/PlayerDumpJSON.lua")
local dumpSource = pinned("game/modules/tome/class/interface/PlayerDumpJSON.lua")
local gameSource = pinned("game/modules/tome/class/Game.lua")
local profileSource = pinned("game/engines/default/engine/PlayerProfile.lua")
local classSource = pinned("game/engines/default/engine/class.lua")

local function world(optimized)
    local w = {names = 0, encoded = {}, compressed = {}, orders = {}, pushes = {}, waits = 0}
    local Base, Dump, Game, Profile, Class, Player = {}, {}, {}, {}, {}, {}
    local env = setmetatable({print = function() end, config = {settings = {}}, Base = Base}, {__index = _G})
    env._G = env
    env.table = setmetatable({serialize = function(value) return value end}, {__index = table})
    env.json = {encode = function(value)
        w.encoded[#w.encoded + 1] = value
        return "encoded-sheet"
    end}
    env.core = {
        display = {forceRedraw = function() end},
        zlib = {compress = function(value)
            w.compressed[#w.compressed + 1] = value
            return "compressed-" .. value
        end},
        profile = {pushOrder = function(value) w.orders[#w.orders + 1] = value end},
    }
    env.Dialog = {simpleWaiter = function()
        w.waits = w.waits + 1
        return {done = function() end}
    end}
    env._t = function(s) return s end
    env.fs = {open = function(path)
        w.charball_path = path
        local read = false
        return {read = function()
            if not read then read = true; return "charball-data" end
        end, close = function() end}
    end}
    env.savefile_pipe = {push = function(_, name, kind, object, saveclass, callback)
        w.pushes[#w.pushes + 1] = {name = name, kind = kind, object = object, saveclass = saveclass}
        callback({nameSaveEntity = function() return "party.teac" end})
    end}
    env._M = Base
    run(section(engineSource, "function _M:getUUID()"), "@/engine/interface/PlayerDumpJSON.lua", env)
    env._M = Dump
    run(section(dumpSource, "function _M:dumpToJSON("), "@/mod/class/interface/PlayerDumpJSON.lua", env)
    env._M = Game
    run(section(gameSource, "function _M:isTainted()", "--- Sets the player name"), "@/mod/class/Game.lua", env)
    run(section(gameSource, "function _M:allowJSONDump()", "function _M:saveVersion("), "@/mod/class/Game.lua", env)
    env._M = Profile
    run(section(profileSource, "function _M:registerNewCharacter(", "function _M:getCharball("), "@/engine/PlayerProfile.lua", env)
    run(section(profileSource, "function _M:registerSaveCharball(", "function _M:setSaveID("), "@/engine/PlayerProfile.lua", env)
    env._M = Class
    run(section(classSource, "local _hooks =", "-- LOAD & SAVE"), "@/engine/class.lua", env)
    Player.saveUUID, Player.getUUID, Player.dumpToJSON = Base.saveUUID, Base.getUUID, Dump.dumpToJSON
    Player.triggerHook = Class.triggerHook
    local player = setmetatable({__te4_uuid = "existing-uuid", allow_late_uuid = true}, {__index = function(_, key)
        -- The real base dumper reads name once; nil makes the real module dumper
        -- return before requiring a complete character. Count that actual read.
        if key == "name" then w.names = w.names + 1; return nil end
        return Player[key]
    end})
    local game = setmetatable({party = {}, player = player, __mod_info = {short_name = "tome"}}, {__index = Game})
    local profile = setmetatable({auth = false, hash_valid = true, waitEvent = function(_, _, callback)
        callback({uuid = "registered-uuid"})
    end}, {__index = Profile})
    env.game, env.profile = game, profile
    w.env, w.player, w.game, w.profile, w.Player, w.Class = env, player, game, profile, Player, Class
    w.original, w.helper = Player.saveUUID, addon()
    if optimized then check(w.helper.installPlayer(Player), "install on actual pinned exporter") end
    return w
end

-- Nonempty exports use an explicitly custom dumper with the real exporter and
-- consumers. It is intentionally NOT given upstream source metadata.
local function sheet(w)
    w.player.dumpToJSON = function(self, js)
        w.dump_game = w.env.game
        js:version("fixture-v1")
        js:newSection("character", {name = "Yron", uuid = self.__te4_uuid})
        return "Yron title", {level = 34}
    end
end
local function online(w) w.profile.auth = {}; w.profile.hash_valid = true end

for _, state in ipairs{"logged-out", "invalid-hash", "both-missing"} do
    for _, optimized in ipairs{false, true} do
        local w = world(optimized)
        if state == "invalid-hash" then w.profile.auth = {}; w.profile.hash_valid = false end
        if state == "both-missing" then w.profile.auth = nil; w.profile.hash_valid = nil end
        local result = pack(w.player:saveUUID())
        check(result.n == 0, "nil export return count preserved")
        check(w.names == (optimized and 0 or 1), state .. ": skip actual module dumper only when optimized")
        check(#w.encoded == (optimized and 0 or 1), state .. ": no dead JSON encoding")
        check(#w.orders == 0 and #w.pushes == 0, state .. ": no network or charball work")
        check(w.env.game == w.game and w.player.__te4_uuid == "existing-uuid", "context and UUID unchanged")
    end
end
print("PASS offline: real pinned dump entry and encoding skipped; context unchanged")

for _, optimized in ipairs{false, true} do
    local w = world(optimized); online(w)
    w.player:saveUUID()
    check(w.names == 1 and #w.encoded == 1, "online keeps actual module dumper")
    sheet(w)
    check(pack(w.player:saveUUID()).n == 0, "online original return count")
    local order = w.orders[1]
    check(#w.orders == 1 and order.o == "SaveChardump", "real online consumer invoked exactly once")
    check(order.uuid == "existing-uuid" and order.module == "tome", "online identity preserved")
    check(order.metadata.title == "Yron title" and order.metadata.tags.level == 34, "online title and tags preserved")
    check(order.data == "compressed-encoded-sheet" and #w.compressed == 1, "online compression and payload preserved")
    check(w.encoded[2].character.uuid == "existing-uuid" and w.encoded[2].version == "fixture-v1", "original JSON builder preserved")
end

for _, optimized in ipairs{false, true} do
    for _, connected in ipairs{false, true} do
        local w = world(optimized); if connected then online(w) end; sheet(w)
        local ball = {name = "Yron party"}
        w.player:saveUUID(ball)
        check(#w.pushes == 1 and w.pushes[1].object == ball, "charball object still enters original save pipe")
        check(w.pushes[1].kind == "entity" and w.pushes[1].saveclass == "engine.CharacterBallSave", "charball archive type preserved")
        check(w.charball_path == "/charballs/party.teac", "charball original callback reads saved file")
        check(#w.orders == (connected and 2 or 0), "both actual consumers retain online checks")
        if connected then
            check(w.orders[2].o == "SaveCharball" and w.orders[2].data == "charball-data", "charball payload preserved")
        end
    end
    local w = world(optimized)
    w.player:saveUUID(false)
    check(w.names == 1, "explicit false argument conservatively keeps original method")
end
print("PASS online and charball: original export, payload, callbacks and consumers")

for _, optimized in ipairs{false, true} do
    for _, connected in ipairs{false, true} do
        local w = world(optimized); w.player.__te4_uuid = nil
        if connected then online(w) end
        w.player:saveUUID()
        check(w.player.__te4_uuid == (connected and "registered-uuid" or nil), "late UUID registration unchanged")
        check(w.waits == (connected and 1 or 0), "late registration waiter unchanged")
        check(#w.orders == (connected and 1 or 0), "late registration order unchanged")
    end
    local w = world(optimized); w.player.__te4_uuid = nil; w.player.allow_late_uuid = false; online(w)
    w.player:saveUUID()
    check(w.names == 0 and w.waits == 0 and #w.orders == 0, "late UUID opt-out unchanged")
    local custom = world(optimized); custom.player.__te4_uuid = nil
    custom.player.getUUID = function(self) self.__te4_uuid = "custom-uuid"; custom.registered = true end
    custom.player:saveUUID()
    check(custom.registered and custom.player.__te4_uuid == "custom-uuid" and custom.names == 1, "custom late registration retained")
    for _, reason in ipairs{"temporary", "no-party", "cheat", "tainted"} do
        local rejected = world(optimized)
        if reason == "temporary" then rejected.game.party.temporary_party = true end
        if reason == "no-party" then rejected.game.party = nil end
        if reason == "cheat" then rejected.env.config.settings.cheat = true end
        if reason == "tainted" then rejected.player.__cheated = true end
        rejected.player:saveUUID()
        check(rejected.names == 0 and #rejected.orders == 0, reason .. " original rejection unchanged")
    end
end

for _, overridden in ipairs{"consumer", "dump", "allow", "taint"} do
    local w = world(true)
    if overridden == "consumer" then w.profile.registerSaveChardump = function() end end
    if overridden == "dump" then
        w.player.dumpToJSON = function() w.custom_dump = true end
    end
    if overridden == "allow" then w.game.allowJSONDump = function() w.custom_allow = true; return true end end
    if overridden == "taint" then w.game.isTainted = function() w.custom_taint = true; return false end end
    w.player:saveUUID()
    check(#w.encoded == 1, overridden .. " unknown override falls back")
    check(overridden == "dump" and w.custom_dump or w.names == 1, overridden .. " original dispatch retained")
end
do
    local w = world(true)
    w.Class:bindHook("ToME:PlayerDumpJSON", function() end)
    w.player:saveUUID()
    check(w.names == 1, "registered export hook conservatively keeps original dumper")
    local unrelated = world(true)
    unrelated.Class:bindHook("Other:hook", function() end)
    unrelated.player:saveUUID()
    check(unrelated.names == 0, "unrelated hook does not disable optimization")
    local unknown = world(true)
    unknown.player.triggerHook = function() end
    unknown.player:saveUUID()
    check(unknown.names == 1, "unknown hook dispatcher keeps original dumper")
    for _, malformed in ipairs{
        {"missing hooks", {}}, {"nil registry"}, {"false registry", false},
        {"true registry", true}, {"numeric registry", 42}, {"string registry", "registry"},
        {"false hooks", {hooks = false}}, {"true hooks", {hooks = true}},
        {"numeric hooks", {hooks = 42}}, {"string hooks", {hooks = "hooks"}},
    } do
        local registry = world(true)
        local replaced = false
        for i = 1, 20 do
            local name = debug.getupvalue(registry.player.triggerHook, i)
            if not name then break end
            if name == "_hooks" then
                debug.setupvalue(registry.player.triggerHook, i, malformed[2])
                replaced = true
                break
            end
        end
        check(replaced, "test uses real hook registry upvalue")
        registry.player:saveUUID()
        check(registry.names == 1, malformed[1] .. " keeps original dumper")
    end
end
print("PASS eligibility, late registration and unknown override fallbacks")

for _, optimized in ipairs{false, true} do
    local w = world(optimized); local failure = {}
    w.player.dumpToJSON = function() error(failure) end
    local ok, err = pcall(w.player.saveUUID, w.player)
    check(not ok and err == failure and w.env.game == w.game, "dump error identity and game context preserved")
    local g = world(optimized); local marker = {}
    g.game.allowJSONDump = function() error(marker) end
    local allowed, reason = pcall(g.player.saveUUID, g.player)
    check(not allowed and reason == marker, "custom eligibility error preserved")
    local context = world(optimized); online(context); sheet(context)
    local realgame = context.game
    local clone = setmetatable({party = {}, player = context.player, __mod_info = {short_name = "clone-module"}}, getmetatable(realgame))
    context.env.game = clone
    context.player:saveUUID()
    check(context.dump_game == clone and context.orders[1].module == "clone-module", "uses exporter environment game, including save snapshot")
    check(context.env.game == clone and realgame.player == context.player, "does not replace game or control actor")
end
do
    local w = world(true)
    w.player:saveUUID(); check(w.names == 0, "initial offline state skips")
    online(w); w.player:saveUUID(); check(w.names == 1, "login after installation resumes export")
    w.profile.hash_valid = false; w.player:saveUUID(); check(w.names == 1, "later hash rejection skips again")
    w.profile.registerSaveChardump = function() end
    w.player:saveUUID(); check(w.names == 2, "later consumer override is detected dynamically")
    local shifted = world(false)
    shifted.env._M = shifted.Player
    run("\n" .. section(engineSource, "function _M:getUUID()"), "@/engine/interface/PlayerDumpJSON.lua", shifted.env)
    local method = shifted.Player.saveUUID
    check(not shifted.helper.installPlayer(shifted.Player) and shifted.Player.saveUUID == method,
        "actual method shifted by one source line fails pinned compatibility check")
end
do
    local w = world(false); local previous = w.Player.saveUUID
    check(not w.helper.installPlayer(w.Player, {offline_chardump = false}), "explicit optimization opt-out")
    check(w.Player.saveUUID == previous, "opt-out leaves original function")
    check(w.helper.installPlayer(w.Player), "install after opt-out")
    local wrapped = w.Player.saveUUID
    check(w.helper.installPlayer(w.Player) and w.Player.saveUUID == wrapped, "repeat installation is idempotent")
    local later = function() return "later exporter" end
    w.Player.saveUUID = later
    check(not w.helper.installPlayer(w.Player) and w.Player.saveUUID == later,
        "installation record does not hide a later exporter override")
    local custom = world(false)
    local method = function(_, ...) return nil, "custom", select("#", ...) end
    custom.Player.saveUUID = method
    check(not custom.helper.installPlayer(custom.Player) and custom.Player.saveUUID == method, "unknown initial exporter retained")
    local result = pack(custom.player:saveUUID(nil, "extra"))
    check(result.n == 3 and result[1] == nil and result[2] == "custom" and result[3] == 2, "unknown exporter return arity and arguments retained")
    local startup = world(false)
    startup.env.loadPrevious = function() return startup.Player end
    startup.env.require = function(name)
        if name == "engine.FasterGzip" then return assert(loadfile(root .. "/overload/engine/FasterGzip.lua"))() end
        assert(name == "engine.FasterChardump"); return startup.helper
    end
    local loaded = setfenv(assert(loadfile(root .. "/superload/mod/class/Player.lua")), startup.env)()
    startup.player:saveUUID()
    check(loaded == startup.Player and startup.names == 0, "real Player superload installs optimization")
end
print("PASS all " .. checks .. " character export checks; " .. _VERSION .. " / " .. (jit and jit.version or "no JIT"))
