-- GPL-3.0-or-later. Pinned exporter and C implementations, no spoofed metadata.
assert(_VERSION == "Lua 5.1", "Lua 5.1 / LuaJIT required")
local root = arg[1] or "."
local repo = assert(arg[2], "pass a local ToME source Git clone as argument 2")
local commit = "624a67329fe2ad440c5b344785a9c73fcf22ae63"
local function quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
local function output(command)
    local p = assert(io.popen(command, "r"))
    local result = p:read("*a"); assert(p:close()); return result
end
local function pinned(path)
    local source = output("git -C " .. quote(repo) .. " show " .. quote(commit .. ":" .. path))
    assert(#source > 0); return source
end
local function section(source, first, last)
    local a = assert(source:find(first, 1, true))
    local b = last and assert(source:find(last, a, true)) or #source + 1
    local _, lines = source:sub(1, a - 1):gsub("\n", "")
    return string.rep("\n", lines) .. source:sub(a, b - 1)
end
local function run(source, name, env) return setfenv(assert(loadstring(source, name)), env)() end
local function write(path, source)
    local f = assert(io.open(path, "wb")); assert(f:write(source)); assert(f:close())
end
local function success(status) return status == 0 or status == true end
local build = output("mktemp -d /tmp/tome-gzip-tests.XXXXXX"):gsub("\n$", "")
assert(build:match("^/tmp/tome%-gzip%-tests%.[%w]+$"), "unexpected temporary directory")
local checks = 0
local function check(ok, message) assert(ok, message); checks = checks + 1 end
local function pack(...) return {n = select("#", ...), ...} end
local function main()
    write(build .. "/pinned_lzlib.c", pinned("src/lzlib/lzlib.c"))
    write(build .. "/pinned_core_compress.c", section(pinned("src/core_lua.c"),
        "static int lua_zlib_compress(lua_State *L)", "static const struct luaL_Reg zliblib[]"))
    -- Modules resolve Lua symbols from the running interpreter. Lua 5.1 headers
    -- are ABI compatible here; do not link another Lua runtime into LuaJIT.
    local headers = os.getenv("TOME_LUA_INCLUDE")
    local cflags = headers and ("-I" .. quote(headers)) or output(
        "if pkg-config --exists luajit; then pkg-config --cflags luajit; else pkg-config --cflags lua5.1; fi")
    cflags = cflags:gsub("\n", " ")
    local command = quote(os.getenv("CC") or "cc") .. " -shared -fPIC -O2 " .. cflags ..
        " -I" .. quote(build) .. " " .. quote(root .. "/tests/gzip_fixture.c") ..
        " -o " .. quote(build .. "/gzip_fixture.so") .. " -lz"
    assert(success(os.execute(command)), "native gzip fixture build failed (requires C compiler, Lua 5.1 headers and zlib)")
    local native = assert(package.loadlib(build .. "/gzip_fixture.so", "luaopen_gzip_fixture"))()
    local globalZlib, loadedZlib = _G.zlib, package.loaded.zlib
    _G.zlib, package.loaded.zlib = nil, nil
    local actualZlib = native.register_zlib()
    _G.zlib, package.loaded.zlib = globalZlib, loadedZlib
    check(type(actualZlib) == "table" and actualZlib._VERSION == nil,
        "actual pinned luaopen_zlib publishes no _VERSION (metadata table is discarded)")
    local Faster = assert(loadfile(root .. "/overload/engine/FasterGzip.lua"))()
    local engineSource = pinned("game/engines/default/engine/interface/PlayerDumpJSON.lua")
    local profileSource = pinned("game/engines/default/engine/PlayerProfile.lua")
    local engineCode = section(engineSource, "function _M:getUUID()")

    local function world(optimized)
        native.reset()
        local w = {orders = {}, pushes = {}, encoded = {}, calls = {}, dumps = 0, payload = string.rep("character-data", 100)}
        local Player, Profile = {}, {}
        local env = setmetatable({print = function() end, config = {settings = {}}}, {__index = _G})
        env._G = env
        env.core = {zlib = {compress = native.core}, profile = {pushOrder = function(order)
            w.orders[#w.orders + 1] = order
        end}, display = {forceRedraw = function() end}}
        env.zlib = {}
        for key, value in pairs(actualZlib) do env.zlib[key] = value end
        env.zlib.compress, env.zlib.decompress = native.compress, native.decompress
        env.json = {encode = function(data) w.encoded[#w.encoded + 1] = data; return w.payload end}
        env.table = setmetatable({serialize = function(data) return data end}, {__index = table})
        env._t = function(s) return s end
        env.Dialog = {simpleWaiter = function() w.waits = (w.waits or 0) + 1; return {done = function() end} end}
        env.savefile_pipe = {push = function(_, name, kind, object, saveclass, callback)
            w.pushes[#w.pushes + 1] = {name, kind, object, saveclass}
            callback({nameSaveEntity = function() return "party.teac" end})
        end}
        env.fs = {open = function(path)
            w.path = path
            local read = false
            return {read = function() if not read then read = true; return "charball-data" end end, close = function() end}
        end}
        env._M = Player
        run(engineCode, "@/engine/interface/PlayerDumpJSON.lua", env)
        env._M = Profile
        run(section(profileSource, "function _M:registerNewCharacter(", "function _M:getCharball("), "@/engine/PlayerProfile.lua", env)
        run(section(profileSource, "function _M:registerSaveCharball(", "function _M:setSaveID("), "@/engine/PlayerProfile.lua", env)
        env.profile = setmetatable({auth = {}, hash_valid = true, waitEvent = function(_, _, callback)
            callback({uuid = "registered-uuid"})
        end}, {__index = Profile})
        env.game = {__mod_info = {short_name = "tome"}, allowJSONDump = function() return true end,
            isTainted = function() return false end}
        local player = setmetatable({__te4_uuid = "existing-uuid", allow_late_uuid = true}, {__index = Player})
        function player:dumpToJSON(js)
            w.dumps = w.dumps + 1; w.dump_game = env.game
            js:version("fixture-v1")
            js:hiddenData("secret", "hidden-value")
            js:newSection("character", {name = "Yron", uuid = self.__te4_uuid})
            js:subsheet("companion"):newSection("details", {level = 9})
            return "Yron title", {level = 34}
        end
        w.original, w.env, w.player, w.Player, w.Profile = Player.saveUUID, env, player, Player, Profile
        if optimized then
            local exporter, reason = Faster.prepareExporter(w.original)
            check(type(exporter) == "function", "prepare actual pinned exporter: " .. tostring(reason))
            Player.saveUUID = exporter
        end
        return w
    end
    local function observed(w)
        w.env.profile.registerSaveChardump = function(_, ...)
            local call = pack(...); w.calls[#w.calls + 1] = call
        end
    end

    -- A C fixture calls the real pinned algorithms. Short/random input exposes
    -- the old fixed output buffer; byte equality applies whenever it succeeds.
    local random, seed = {}, 413
    for i = 1, 40000 do seed = (seed * 48271) % 2147483647; random[i] = string.char(seed % 256) end
    local noise = table.concat(random)
    for _, payload in ipairs{"", "a", "short-json", noise:sub(1, 47), noise, string.rep("repeat", 10000)} do
        local w = world(true); observed(w); w.payload = payload
        local beforeCore, beforeFast = native.stats()
        check(beforeCore == 0 and beforeFast > 0, "preflight uses lzlib without leaking core compressor")
        check(pack(w.player:saveUUID()).n == 0, "export retains zero return values")
        local call = w.calls[1]
        check(call.n == 5 and type(call[5]) == "string", "success passes exactly one compressed value")
        local decoded, status = native.raw_decompress(call[5], 31)
        check(status == 1 and decoded == payload, "actual gzip round trip including empty/short/random data")
        check(call[5]:sub(1, 3) == "\31\139\8", "gzip wrapper retained")
        local old = pack(native.core(payload))
        if old.n == 1 then check(old[1] == call[5], "byte equality with successful pinned core compressor")
        else check(old.n == 0 and #payload < 100, "known old fixed-buffer failure on short input") end
    end
    print("PASS gzip: pinned native codecs, gzip bytes, empty/short/random round trips and no core preflight")

    for _, optimized in ipairs{false, true} do
        for _, connected in ipairs{false, true} do
            local w = world(optimized); if not connected then w.env.profile.auth = false end
            check(pack(w.player:saveUUID()).n == 0 and w.dumps == 1, "export body runs exactly once")
            check(#w.orders == (connected and 1 or 0), "real online/offline consumer retained")
            local js = w.encoded[1]
            check(js.version == "fixture-v1" and js.hidden.secret == "hidden-value" and js.sections[1] == "character",
                "all original JSON builder helpers retained")
            check(js.subsheets[1].sheet.details.level == 9 and js.character.uuid == "existing-uuid", "nested JSON and UUID retained")
            if connected then
                local order = w.orders[1]
                check(order.o == "SaveChardump" and order.uuid == "existing-uuid" and order.module == "tome", "actual upload identity")
                check(order.metadata.title == "Yron title" and order.metadata.tags.level == 34, "actual upload metadata")
                check(native.raw_decompress(order.data, 31) == w.payload, "actual upload payload")
            end
            local ball = {name = "party"}; w.player:saveUUID(ball)
            check(#w.pushes == 1 and w.pushes[1][3] == ball and w.path == "/charballs/party.teac", "original charball save callback")
            check(#w.orders == (connected and 3 or 0), "original charball consumer authorization")
            if connected then check(w.orders[3].o == "SaveCharball" and w.orders[3].data == "charball-data", "charball payload untouched") end
            local late = world(optimized); if not connected then late.env.profile.auth = false end
            late.player.__te4_uuid = nil; late.player:saveUUID()
            check(late.player.__te4_uuid == (connected and "registered-uuid" or nil), "late UUID registration retained")
            check(late.dumps == (connected and 1 or 0), "late UUID eligibility retained")
        end
        for _, rejection in ipairs{"allow", "tainted", "uuid", "no-data", "no-title"} do
            local w = world(optimized)
            if rejection == "allow" then w.env.game.allowJSONDump = function() return false end end
            if rejection == "tainted" then w.env.game.isTainted = function() return true end end
            if rejection == "uuid" then w.player.__te4_uuid = nil; w.player.allow_late_uuid = false end
            if rejection == "no-data" then w.env.json.encode = function() return nil end end
            if rejection == "no-title" then w.player.dumpToJSON = function() return nil end end
            local core, fast = native.stats(); w.player:saveUUID()
            local afterCore, afterFast = native.stats()
            check(#w.orders == 0 and core == afterCore and fast == afterFast, rejection .. " never compresses")
        end
    end
    print("PASS gzip: online/offline, charball, late UUID, original JSON helpers and early returns")

    for _, mode in ipairs{1, 2, 3, 4, 5, 8} do
        local w = world(true); observed(w); native.set_mode(mode)
        w.player:saveUUID()
        check(w.calls[1].n == 4, "failed status/type returns no values rather than nil or partial bytes (mode " .. mode .. ")")
    end
    do
        local w = world(true); observed(w); local marker = {}; native.set_mode(6, marker)
        local ok, err = pcall(w.player.saveUUID, w.player)
        check(not ok and err == marker and #w.calls == 0, "native compression error identity retained")
        for _, stage in ipairs{"allowJSONDump", "isTainted", "dumpToJSON", "encode", "registerSaveChardump"} do
            local broken = world(true); local failure = {}
            local target = stage == "dumpToJSON" and broken.player or stage == "encode" and broken.env.json
                or stage == "registerSaveChardump" and broken.env.profile or broken.env.game
            target[stage] = function() error(failure) end
            local success, reason = pcall(broken.player.saveUUID, broken.player)
            check(not success and reason == failure, stage .. " error identity preserved")
        end
    end

    for _, change in ipairs{"core-compress", "core-zlib-table", "core-table", "zlib-compress", "zlib-decompress", "zlib-table", "missing-zlib"} do
        local w = world(true); observed(w)
        local originalCore = w.env.core.zlib.compress
        local sentinel = function(value) check(value == w.payload, "fallback receives JSON data"); return nil, "custom", 9 end
        if change == "core-compress" then w.env.core.zlib.compress = sentinel end
        if change == "core-zlib-table" then w.env.core.zlib = {compress = originalCore} end
        if change == "core-table" then w.env.core = {zlib = w.env.core.zlib} end
        if change == "zlib-compress" then w.env.zlib.compress = native.raw_compress end
        if change == "zlib-decompress" then w.env.zlib.decompress = native.raw_decompress end
        if change == "zlib-table" then w.env.zlib = {compress = native.compress, decompress = native.decompress, _VERSION = "lzlib 0.3"} end
        if change == "missing-zlib" then w.env.zlib = false end
        local core, fast = native.stats(); w.player:saveUUID()
        local afterCore, afterFast = native.stats()
        check(afterFast == fast, change .. " dynamically disables prepared compression")
        if change == "core-compress" then
            check(w.calls[1].n == 7 and w.calls[1][5] == nil and w.calls[1][6] == "custom" and w.calls[1][7] == 9,
                "fallback preserves custom compression return arity")
        else check(afterCore == core + 1, change .. " falls back to current core compressor") end
    end
    do
        local w = world(true); local marker = {}; w.env.core.zlib.compress = function() error(marker) end
        local ok, err = pcall(w.player.saveUUID, w.player)
        check(not ok and err == marker, "later custom core error retained")
        local scoped = world(true)
        check(getfenv(scoped.original) == scoped.env and scoped.env.core.zlib.compress == native.core
            and scoped.env.zlib.compress == native.compress and scoped.env.zlib.decompress == native.decompress,
            "preparation never patches original environment or public APIs")
        local before = native.stats(); scoped.original(scoped.player)
        check(native.stats() == before + 1, "direct original exporter still uses original core API")
        local replacement = {__mod_info = {short_name = "snapshot"}, isTainted = function() return false end}
        scoped.env.game = replacement
        scoped.player:saveUUID()
        check(scoped.dump_game == replacement and scoped.orders[2].module == "snapshot" and scoped.env.game == replacement,
            "prepared exporter follows dynamic game environment without replacing it")
        local consumerCalls = 0
        scoped.env.profile = {registerSaveChardump = function() consumerCalls = consumerCalls + 1 end}
        scoped.env.json = {encode = function() return string.rep("replacement-json", 30) end}
        scoped.player:saveUUID()
        check(consumerCalls == 1, "prepared exporter follows replaced profile and JSON environment")
    end
    for _, payload in ipairs{123456789, true, {}} do
        local w = world(true); observed(w); w.payload = payload
        local beforeCore, beforeFast = native.stats()
        local ok, err = pcall(w.player.saveUUID, w.player)
        local afterCore, afterFast = native.stats()
        check(afterCore == beforeCore + 1 and afterFast == beforeFast, "non-string JSON preserves core coercion/errors")
        if type(payload) == "number" then check(ok and #w.calls == 1, "numeric input reaches original core coercion")
        else check(not ok and tostring(err):find("string expected", 1, true), "invalid input retains native type error") end
    end
    for _, stage in ipairs{"dump", "json"} do
        local w = world(true); observed(w)
        local function replace() w.env.core.zlib.compress = function() return "inside-hook", 17 end end
        if stage == "dump" then
            local originalDump = w.player.dumpToJSON
            w.player.dumpToJSON = function(...) replace(); return originalDump(...) end
        else w.env.json.encode = function() replace(); return w.payload end end
        local core, fast = native.stats(); w.player:saveUUID()
        local afterCore, afterFast = native.stats()
        check(core == afterCore and fast == afterFast and w.calls[1].n == 6 and w.calls[1][5] == "inside-hook",
            stage .. " override detected at actual compression call site")
    end
    print("PASS gzip: strict native status/arity, errors, scope and dynamic compressor/environment fallback")

    local function rejected(w, message, options)
        local original, env = w.original, getfenv(w.original)
        local exporter, reason = Faster.prepareExporter(original, options)
        check(exporter == nil and type(reason) == "string", message .. " reports unavailable")
        check(getfenv(original) == env and w.Player.saveUUID == original, message .. " leaves original intact")
        check(native.stats() == 0, message .. " does not call leaky core preflight")
    end
    rejected(world(false), "explicit opt-out", {export_gzip = false})
    for _, mode in ipairs{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11} do
        local w = world(false); native.set_mode(mode, {})
        rejected(w, "failed native preflight " .. mode)
    end
    do
        local w = world(false); w.env.zlib._VERSION = "lzlib 0.3"
        local exporter = Faster.prepareExporter(w.original)
        check(type(exporter) == "function", "explicit known lzlib version is compatible")
        check(Faster.prepareExporter(exporter) == exporter, "prepared exporter preparation is idempotent")
        check(Faster.prepareExporter(exporter, {export_gzip = false}) == nil, "opt-out takes precedence for prepared exporter")
    end

    -- Execute the shipped superload with all independent settings. Use real
    -- module dumper/eligibility/hook bodies to satisfy the offline guard.
    local dumpSource = pinned("game/modules/tome/class/interface/PlayerDumpJSON.lua")
    local gameSource = pinned("game/modules/tome/class/Game.lua")
    local classSource = pinned("game/engines/default/engine/class.lua")
    local function startup(w, options)
        local chardump = assert(loadfile(root .. "/overload/engine/FasterChardump.lua"))()
        w.env.config.settings.faster_tome = options
        w.env.loadPrevious = function() return w.Player end
        w.env.require = function(name)
            if name == "engine.FasterGzip" then return Faster end
            assert(name == "engine.FasterChardump"); return chardump
        end
        check(setfenv(assert(loadfile(root .. "/superload/mod/class/Player.lua")), w.env)() == w.Player,
            "real Player superload returns original class")
    end
    for _, offline in ipairs{false, true} do
        for _, gzip in ipairs{false, true} do
            local w = world(false)
            startup(w, {offline_chardump = offline, export_gzip = gzip})
            local beforeCore, beforeFast = native.stats(); w.player:saveUUID()
            local afterCore, afterFast = native.stats()
            check(afterCore - beforeCore == (gzip and 0 or 1) and afterFast - beforeFast == (gzip and 1 or 0),
                "superload respects independent gzip switch")
            check(#w.orders == 1 and native.raw_decompress(w.orders[1].data, 31) == w.payload,
                "superload online export survives every switch combination")
            local Dump, Game, Class = {}, {}, {}
            w.env.Base = w.Player; w.env._M = Dump
            run(section(dumpSource, "function _M:dumpToJSON("), "@/mod/class/interface/PlayerDumpJSON.lua", w.env)
            w.env._M = Game
            run(section(gameSource, "function _M:isTainted()", "--- Sets the player name"), "@/mod/class/Game.lua", w.env)
            run(section(gameSource, "function _M:allowJSONDump()", "function _M:saveVersion("), "@/mod/class/Game.lua", w.env)
            w.env._M = Class
            run(section(classSource, "local _hooks =", "-- LOAD & SAVE"), "@/engine/class.lua", w.env)
            w.player.dumpToJSON, w.player.triggerHook = Dump.dumpToJSON, Class.triggerHook
            w.env.game = setmetatable({player = w.player, party = {}, __mod_info = {short_name = "tome"}}, {__index = Game})
            w.env.profile.auth = false
            local encoded = #w.encoded; w.player:saveUUID()
            check(#w.encoded - encoded == (offline and 0 or 1), "superload respects independent offline switch")
            local ball = {name = "party"}; w.player:saveUUID(ball)
            check(#w.encoded - encoded == (offline and 1 or 2), "charball always retains original export entry")
        end
    end
    do
        local w = world(false); w.env.zlib = false
        startup(w, {})
        w.player:saveUUID()
        check(#w.orders == 1 and native.stats() == 1, "unavailable gzip binding preserves superload export")
        local unknown = world(false)
        unknown.Player.saveUUID = function(_, ...) return nil, "custom", select("#", ...) end
        local original = unknown.Player.saveUUID
        startup(unknown, {})
        local result = pack(unknown.player:saveUUID(nil, "extra"))
        check(unknown.Player.saveUUID == original and result.n == 3 and result[2] == "custom" and result[3] == 2,
            "superload retains unknown exporter arguments and returns")
    end
    print("PASS gzip: real Player superload, independent settings and conservative startup fallback")
    for _, change in ipairs{"version", "lua-core", "lua-compress", "lua-decompress", "missing-core", "missing-zlib"} do
        local w = world(false)
        if change == "version" then w.env.zlib._VERSION = "unknown version" end
        if change == "lua-core" then w.env.core.zlib.compress = function() end end
        if change == "lua-compress" then w.env.zlib.compress = function() end end
        if change == "lua-decompress" then w.env.zlib.decompress = function() end end
        if change == "missing-core" then w.env.core = false end
        if change == "missing-zlib" then w.env.zlib = false end
        rejected(w, change)
    end
    for _, variant in ipairs{"line", "source", "custom"} do
        local w = world(false); w.env._M = w.Player
        if variant == "line" then run("\n" .. engineCode, "@/engine/interface/PlayerDumpJSON.lua", w.env) end
        if variant == "source" then run(engineCode, "@/custom/PlayerDumpJSON.lua", w.env) end
        if variant == "custom" then w.Player.saveUUID = function() return "custom" end end
        w.original = w.Player.saveUUID
        rejected(w, "unknown exporter " .. variant)
    end
    -- Derive a genuine closure from the pinned body, preserving its source
    -- lines. Only this guard-negative fixture adds an actual captured local.
    do
        local w = world(false); w.env._M = w.Player
        local closure = engineCode:gsub("^\n", "local captured = 1\n", 1):gsub(
            "function _M:saveUUID%(do_charball%)", "function _M:saveUUID(do_charball) if captured == 0 then return end", 1)
        run(closure, "@/engine/interface/PlayerDumpJSON.lua", w.env)
        w.original = w.Player.saveUUID
        check(debug.getinfo(w.original, "u").nups == 1 and debug.getinfo(w.original, "S").linedefined == 41,
            "negative fixture has a real upvalue with genuine source metadata")
        rejected(w, "exporter upvalue")
    end
    print("PASS all " .. checks .. " gzip export checks; " .. _VERSION .. " / " .. (jit and jit.version or "no JIT"))
end
local ok, err = xpcall(main, debug.traceback)
assert(success(os.execute("rm -rf -- " .. quote(build))), "temporary native fixture cleanup failed")
if not ok then error(err, 0) end
