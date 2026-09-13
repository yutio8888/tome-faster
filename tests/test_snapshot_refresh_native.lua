-- GPL-3.0-or-later. Actual installGame + pinned clone/wait/redraw integration.
assert(_VERSION == "Lua 5.1", "Lua 5.1 / LuaJIT required")
local root, repo = arg[1] or ".", assert(arg[2], "pass local engine Git clone")
local native, cleanup, pinned, section = assert(loadfile(root .. "/tests/wait_refresh_build.lua"))()(root, repo)
local code = section(pinned("game/engines/default/engine/class.lua"),
    "local function clonerecursfull(", "--- Replaces the object with an other")
local Faster = assert(loadfile(root .. "/overload/engine/FasterClone.lua"))()
local CloneRefresh = assert(loadfile(root .. "/overload/engine/FasterCloneRefresh.lua"))()
local modules = {["engine.FasterClone"] = Faster, ["engine.FasterCloneRefresh"] = CloneRefresh}
local loader = assert(loadfile(root .. "/overload/engine/FasterSnapshotRefresh.lua"))
setfenv(loader, setmetatable({require = function(name) return assert(modules[name], name) end}, {__index = _G}))
local Snapshot = loader()
local checks = 0
local function check(ok, why) assert(ok, why); checks = checks + 1 end
local function world()
    native.reset(); native.clockStep(17)
    local Game = {}
    local globals = {core = native.core()}
    local env = setmetatable({_M = Game, _G = globals}, {__index = _G})
    setfenv(assert(loadstring(code, "@/engine/class.lua")), env)()
    local upstream = Game.cloneForSave
    assert(Faster.installGame(Game))
    local original = Game.cloneForSave
    local game = setmetatable({__CLASSNAME = "Game", w = 800, h = 600,
        displays = 0, inputs = 0, ticks = 0, quits = 0, dialogs = {}, payload = {}}, {__index = Game})
    game.self = game
    game.child = {__CLASSNAME = "Child", value = "saved"}
    game.alias = game.child
    for i = 1, 2048 do game.payload[i] = i end
    function Game:display() self.displays = self.displays + 1 end
    function Game:input() self.inputs = self.inputs + 1 end
    function Game:tick() self.ticks = self.ticks + 1 end
    function Game:onQuit() self.quits = self.quits + 1 end
    globals.game = game
    native.setGame(game)
    Snapshot.enableDiagnostics(true)
    return {Game = Game, game = game, globals = globals, env = env,
        core = globals.core, original = original, upstream = upstream}
end
local function install(w)
    local ok, reason = Snapshot.installGame(w.Game)
    check(ok, "native install succeeds: " .. tostring(reason))
    check(w.Game.cloneForSave ~= w.original, "install wraps recognized FasterClone method")
end
local function copied(w, clone, count, label)
    check(clone ~= w.game and clone.self == clone and clone.child == clone.alias and clone.child ~= w.game.child,
        label .. " graph aliases and cycles")
    check(count == 2 and clone.payload[2048] == 2048 and getmetatable(clone) == getmetatable(w.game),
        label .. " native integration preserves count, payload and metatable")
end
local function clean(label)
    local s = native.stats()
    check(s.waiting == 0 and s.texture == 0 and s.hook_mask == 0, label .. " native state clean")
    check(s.textures_created == s.textures_deleted, label .. " native texture ownership balanced")
end
local function untouched(label)
    local s = native.stats()
    check(s.redraws == 0 and s.textures_created == 0 and s.pumps == 0,
        label .. " fallback performs no native wait or redraw")
    clean(label)
end
local api = {
    {"wait", "enable"}, {"wait", "disable"}, {"wait", "drawLastFrame"},
    {"display", "drawQuad"}, {"game", "getTime"},
}
local function main()
    -- No monkey-patched debug metadata: each backend API is a real C function,
    -- and FasterClone is installed from the original pinned class source.
    do
        local w = world()
        for _, path in ipairs(api) do
            check(debug.getinfo(w.core[path[1]][path[2]], "S").what == "C", table.concat(path, ".") .. " real native identity")
        end
        check(Faster.getInstalledEnvironment(w.original) == w.env, "FasterClone exposes actual installed recursive environment")
        install(w)
        local method = w.Game.cloneForSave
        check(Snapshot.installGame(w.Game) and w.Game.cloneForSave == method, "native installation is idempotent")
        native.queueEvents(2, 3); native.queueQuit()
        local clone, count = w.game:cloneForSave()
        copied(w, clone, count, "native refresh")
        local s, d = native.stats(), Snapshot.getDiagnostics()
        check(s.redraws > 1 and s.quads == s.redraws * 3 and s.copies == s.redraws
            and s.textures_created == s.redraws and s.textures_deleted == s.redraws,
            "actual production draw callback closes every captured frame before copying resumes")
        check(d.completed and not d.fallback and d.checkpoints > 0 and d.refreshes > 0, "production diagnostics prove optimized copy ran")
        check(w.game.displays == 0 and w.game.inputs == 0 and w.game.ticks == 0 and w.game.quits == 0
            and #w.game.dialogs == 0 and s.particles == 0 and s.pumps == 0,
            "copy refresh performs no Game display, input, tick, quit, dialog or particle work")
        check(s.os_quits == 1 and s.queued_inputs == 0 and s.queued_ticks == 0, "events remain unpumped throughout actual wrapper")
        clean("native refresh")
        check(select("#", w.game:cloneForSave()) == 2, "installed native wrapper retains exact return arity")
        native.pumpEvents(); native.dispatchEvents()
        check(w.game.quits == 1 and w.game.inputs == 2 and w.game.ticks == 3,
            "queued input, timer and quit resume after actual wrapper returns")
        check(clone.quits == 0 and clone.inputs == 0 and clone.ticks == 0, "completed snapshot remains from before delayed events")
        clean("second native refresh")
    end

    -- Pulse redraw relies on native enable's own draw. Neither of the public
    -- manual/forceRedraw entry points is required or called by this backend.
    do
        local w = world()
        w.core.wait.enableManualTick = nil; w.core.wait.manualTick = nil
        w.core.display.forceRedraw = nil
        install(w)
        local clone, count = w.game:cloneForSave()
        copied(w, clone, count, "minimal native API")
        check(native.stats().redraws > 1 and native.stats().pumps == 0, "enable-only pulse draws without optional APIs")
        clean("minimal native API")
    end

    for _, path in ipairs(api) do
        for _, kind in ipairs{"missing", "Lua replacement"} do
            local w = world()
            if kind == "missing" then w.core[path[1]][path[2]] = nil
            else w.core[path[1]][path[2]] = function() error("must not call substituted API") end end
            local ok = Snapshot.installGame(w.Game)
            check(not ok and w.Game.cloneForSave == w.original, kind .. " " .. table.concat(path, ".") .. " prevents installation")
            local clone, count = w.game:cloneForSave()
            copied(w, clone, count, kind .. " API")
            untouched(kind .. " API")
        end
        for _, kind in ipairs{"missing", "Lua replacement", "different C function"} do
            local w = world(); install(w)
            local saved = w.core[path[1]][path[2]]
            w.core[path[1]][path[2]] = kind == "different C function" and math.abs or function() error("must not call changed API") end
            if kind == "missing" then w.core[path[1]][path[2]] = nil end
            local clone, count = w.game:cloneForSave()
            copied(w, clone, count, "late " .. kind)
            untouched("late " .. table.concat(path, "."))
            w.core[path[1]][path[2]] = saved
            clone, count = w.game:cloneForSave()
            copied(w, clone, count, "restored native API")
            check(native.stats().redraws > 1, "restoring exact native API makes refresh eligible again")
            clean("restored API")
        end
    end

    for _, service in ipairs{"webview", "steam"} do
        for _, late in ipairs{false, true} do
            for _, value in ipairs{{}, false} do
                local w = world()
                if late then install(w) end
                w.core[service] = value
                if not late then
                    check(not Snapshot.installGame(w.Game) and w.Game.cloneForSave == w.original,
                        service .. " presence prevents install, including false placeholder")
                end
                native.queueQuit()
                local clone, count = w.game:cloneForSave()
                copied(w, clone, count, service .. " fallback")
                check(w.game.quits == 0 and native.stats().os_quits == 1, service .. " fallback preserves delayed quit")
                untouched(service .. " fallback")
                w.core[service] = nil
                if not late then install(w) end
                clone, count = w.game:cloneForSave()
                copied(w, clone, count, service .. " absent")
                check(native.stats().redraws > 1 and w.game.quits == 0, service .. " removal permits safe native refresh")
                clean(service .. " absent")
                native.pumpEvents()
                check(w.game.quits == 1, service .. " fallback quit is delivered after completion")
            end
        end
    end

    -- Global/core namespace checks reject missing tables, table metatables,
    -- foreign game roots, and replaced namespaces without touching native wait.
    for _, component in ipairs{"core", "wait", "display", "game"} do
        for _, invalid in ipairs{"missing", "metatable"} do
            local w = world()
            if component == "core" then
                if invalid == "missing" then w.globals.core = nil else setmetatable(w.core, {}) end
            elseif invalid == "missing" then w.core[component] = nil else setmetatable(w.core[component], {}) end
            check(not Snapshot.installGame(w.Game) and w.Game.cloneForSave == w.original,
                invalid .. " " .. component .. " namespace prevents install")
            untouched("invalid namespace")
        end
    end
    for _, component in ipairs{"core", "wait", "display", "game", "root"} do
        local w = world(); install(w)
        if component == "core" then w.globals.core = native.core()
        elseif component == "root" then w.globals.game = {}
        else w.core[component] = {} end
        local clone, count = w.game:cloneForSave()
        copied(w, clone, count, "replaced namespace")
        untouched("replaced " .. component)
    end
    for _, global in ipairs{false, true, "invalid globals", io.stdout} do
        local w = world(); w.env._G = global
        local ran, installed = pcall(Snapshot.installGame, w.Game)
        check(ran and not installed and w.Game.cloneForSave == w.original, "invalid _G gracefully prevents install")
        untouched("invalid _G")
    end
    do
        local w = world(); w.env._G = nil
        check(not Snapshot.installGame(w.Game), "missing _G prevents install")
        untouched("missing _G")
    end
    for _, setting in ipairs{"snapshot_refresh", "save_clone"} do
        local w = world()
        check(not Snapshot.installGame(w.Game, {[setting] = false}) and w.Game.cloneForSave == w.original,
            setting .. " option prevents install")
        untouched("disabled option")
    end
    do
        local w = world(); w.Game.cloneForSave = w.upstream
        check(not Snapshot.installGame(w.Game) and w.Game.cloneForSave == w.upstream, "unrecognized upstream clone is left for FasterClone to install")
        w.Game.cloneForSave = w.original
        local name = debug.setupvalue(w.original, 1, function() return {}, 9 end)
        check(name == "copy" and Faster.getInstalledEnvironment(w.original) == nil, "changed recursive upvalue fails FasterClone provenance")
        check(not Snapshot.installGame(w.Game) and w.Game.cloneForSave == w.original, "changed FasterClone closure prevents refresh install")
        untouched("unknown clone")
    end

    do
        local w = world(); install(w)
        local function hook() end
        debug.sethook(hook, "", 1000000000)
        local before = native.stats()
        local clone, count = w.game:cloneForSave()
        copied(w, clone, count, "existing debug hook")
        local current, mask, hookCount = debug.gethook()
        check(current == hook and mask == "" and hookCount == 1000000000
            and native.stats().hook_mask == before.hook_mask, "existing Lua debug hook identity/mask/count preserved")
        check(native.stats().textures_created == 0 and native.stats().pumps == 0, "debug hook fallback never enables native wait")
        debug.sethook(); clean("debug hook fallback")
    end
    for _, manual in ipairs{false, true} do
        local w = world(); install(w)
        local draws = 0
        local function draw() draws = draws + 1; w.core.wait.drawLastFrame() end
        w.core.wait.enable(1000000000, function() return draw end)
        if manual then w.core.wait.enableManualTick(true) end
        w.core.wait.addMaxTicks(19)
        local before = native.stats()
        native.queueQuit()
        local clone, count = w.game:cloneForSave()
        copied(w, clone, count, "outer wait")
        local s = native.stats()
        check(s.waiting == 1 and s.texture == before.texture and s.manual == before.manual
            and s.hook_mask == before.hook_mask and s.hook_count == before.hook_count,
            "existing outer wait retains depth, texture, manual mode and native hook")
        check(draws == 1 and s.textures_created == 1 and s.textures_deleted == 0 and s.redraws == 1,
            "existing outer wait callback is neither replaced nor redrawn")
        local ticks, maximum = w.core.wait.getTicks()
        check(ticks == 0 and maximum == 19 and s.os_quits == 1 and w.game.quits == 0,
            "nested fallback preserves outer progress and delayed quit")
        w.core.wait.disable(); clean("outer wait")
        native.pumpEvents(); check(w.game.quits == 1, "outer wait quit delivered after owner cleanup")
    end

    -- The opaque source lookup occurs before the payload's first checkpoint.
    -- A native wait must never remain open while ordinary graph copying runs.
    local function sourceCallback(w, callback)
        local called = false
        w.game.payload[1] = setmetatable({__CLASSNAME = "Probe"}, {__index = function(_, key)
            if key == "__ATOMIC" and not called then called = true; callback() end
        end})
    end
    for _, keepOpen in ipairs{false, true} do
        local w = world(); install(w)
        local owned, depth, drawCalls, observedWaiting = nil, nil, 0, nil
        sourceCallback(w, function()
            observedWaiting = native.stats().waiting
            owned, depth = w.core.wait.enable(1000000000, function()
                return function() drawCalls = drawCalls + 1; w.core.wait.drawLastFrame() end
            end)
            if keepOpen then w.core.wait.enableManualTick(true) else w.core.wait.disable() end
        end)
        local clone, count = w.game:cloneForSave()
        check(observedWaiting == 0 and owned and depth == 1 and drawCalls == 1,
            "source __index opens its own outer wait and invokes its factory")
        check(clone.self == clone and count == 3, "source wait does not change clone aliases or count")
        if keepOpen then
            local s = native.stats()
            check(s.waiting == 1 and s.manual == 1 and s.textures_created == s.textures_deleted + 1,
                "source-owned wait remains open after wrapper returns")
            check(Snapshot.getDiagnostics().refresh_stopped and Snapshot.getDiagnostics().stopped_reason == "runtime changed",
                "new outer wait stops later pulses")
            w.core.wait.disable()
        else check(native.stats().waiting == 0 and Snapshot.getDiagnostics().refreshes > 0, "balanced source wait permits later pulses") end
        clean("source __index wait")
    end
    for _, kind in ipairs{"Lua", "external native"} do
        local w = world(); install(w)
        local function hook() end
        local observedWaiting
        sourceCallback(w, function()
            observedWaiting = native.stats().waiting
            if kind == "Lua" then debug.sethook(hook, "", 1000000000) else native.externalHook() end
        end)
        local clone, count = w.game:cloneForSave()
        local s = native.stats()
        check(observedWaiting == 0 and count == 3 and s.redraws == 1 and s.waiting == 0,
            kind .. " hook installed by __index runs outside wait and prevents further pulses")
        local current, mask, hookCount = debug.gethook()
        check((kind == "Lua" and current == hook or kind == "external native" and current == "external hook")
            and mask == "" and hookCount == 1000000000 and s.hook_mask ~= 0,
            kind .. " source hook identity, mask and count survive snapshot completion")
        check(Snapshot.getDiagnostics().completed and Snapshot.getDiagnostics().refresh_stopped,
            kind .. " source hook changes refresh eligibility without restarting clone")
        debug.sethook(); clean("source-installed hook")
    end
    do
        local w = world(); install(w)
        local function hook() end
        local finalized, observedWaiting, owned = 0
        local pending = newproxy(true)
        getmetatable(pending).__gc = function()
            finalized = finalized + 1; observedWaiting = native.stats().waiting
            owned = w.core.wait.enable(1000000000, function() return function() w.core.wait.drawLastFrame() end end)
            w.core.wait.disable()
            debug.sethook(hook, "", 1000000000)
        end
        sourceCallback(w, function() pending = nil; collectgarbage("collect") end)
        local clone, count = w.game:cloneForSave()
        check(finalized == 1 and observedWaiting == 0 and owned and count == 3,
            "real Lua finalizer invoked during traversal opens an outer wait")
        check(debug.gethook() == hook and native.stats().hook_mask ~= 0,
            "real finalizer-installed Lua hook survives later checkpoints and finish")
        check(Snapshot.getDiagnostics().completed and Snapshot.getDiagnostics().refresh_stopped,
            "real finalizer changes eligibility without changing the active clone")
        debug.sethook(); clean("source finalizer")
    end
    for _, change in ipairs{"webview", "steam", "API"} do
        local w = world(); install(w)
        sourceCallback(w, function()
            if change == "API" then w.core.display.drawQuad = function() error("changed API must never be called") end
            else w.core[change] = {} end
        end)
        local clone, count = w.game:cloneForSave()
        check(count == 3 and native.stats().redraws == 1 and native.stats().pumps == 0,
            change .. " changed by source __index prevents subsequent native pulse")
        check(Snapshot.getDiagnostics().completed and Snapshot.getDiagnostics().refresh_stopped,
            change .. " source mutation stops refresh while completing same copy")
        clean("source runtime change")
    end
    -- Deterministic injection at the native draw boundary models a finalizer
    -- installing a Lua hook during a pulse. It does not claim a particular GC
    -- allocation will schedule a real finalizer at this exact native instruction.
    for _, drawError in ipairs{false, true} do
        local w = world(); install(w)
        local function hook() end
        local observedWaiting
        native.onQuad(function()
            observedWaiting = native.stats().waiting
            debug.sethook(hook, "", 1000000000)
        end)
        if drawError then native.quadError(1, {}) end
        local clone, count = w.game:cloneForSave()
        copied(w, clone, count, "hook installed inside native draw")
        local current, mask, hookCount = debug.gethook()
        check(observedWaiting == 1 and current == hook and mask == "" and hookCount == 1000000000
            and native.stats().waiting == 0 and native.stats().hook_mask ~= 0,
            "pulse cleanup restores new Lua hook, including when native draw throws")
        debug.sethook(); clean("hook installed inside draw")
    end

    -- Fail actual native drawQuad, preserving the C identity checked at install.
    -- Setup errors fall back once; later redraw errors finish the current copy.
    for _, phase in ipairs{"first draw", "later draw"} do
        local w = world(); install(w)
        local marker, visits = {}, 0
        w.game.probe = setmetatable({__CLASSNAME = "Probe"}, {__index = function(_, key)
            if key == "__ATOMIC" then visits = visits + 1 end
        end})
        native.quadError(phase == "first draw" and 1 or 4, marker)
        native.queueQuit()
        local clone, count = w.game:cloneForSave()
        check(clone ~= w.game and clone.self == clone and clone.probe ~= w.game.probe and count == 3,
            phase .. " still returns complete coherent copy")
        check(visits == 2, phase .. " performs exactly one recursive copy")
        local s, d = native.stats(), Snapshot.getDiagnostics()
        local expectedPulses = phase == "first draw" and 1 or 2
        check(s.textures_created == expectedPulses and s.textures_deleted == expectedPulses and s.pumps == 0
            and s.os_quits == 1 and w.game.quits == 0, phase .. " cleans native resources without delivering quit")
        if phase == "first draw" then check(d.fallback and d.reason == "wait setup failed", "initial native draw failure records fallback")
        else check(d.completed and d.redraw_failed and not d.fallback, "later native draw failure continues current clone") end
        clean(phase)
        native.quadError(0)
        clone, count = w.game:cloneForSave()
        check(count == 3 and Snapshot.getDiagnostics().completed and not Snapshot.getDiagnostics().redraw_failed,
            phase .. " next save starts a fresh native wait")
        clean(phase .. " retry")
        native.pumpEvents(); check(w.game.quits == 1 and clone.quits == 0, phase .. " delayed quit runs only after completed snapshot")
    end
    do
        local w = world(); install(w)
        local marker, attempts = {}, 0
        w.game.trap = setmetatable({}, {__index = function(_, key)
            if key == "__ATOMIC" then attempts = attempts + 1; error(marker, 0) end
        end})
        native.queueQuit()
        local ok, err = pcall(w.game.cloneForSave, w.game)
        check(not ok and err == marker and attempts == 1, "actual source clone error preserves identity and is not retried")
        check(not Snapshot.getDiagnostics().completed and native.stats().os_quits == 1 and w.game.quits == 0,
            "clone failure is reported while quit remains pending")
        clean("source clone error")
        w.game.trap = nil
        local clone, count = w.game:cloneForSave()
        copied(w, clone, count, "retry after source error")
        check(Snapshot.getDiagnostics().completed and native.stats().textures_created > 1,
            "source error releases reentrancy guard for later save")
        clean("source error retry")
        native.pumpEvents(); check(w.game.quits == 1 and clone.quits == 0, "source-error delayed quit resumes after successful retry")
    end
    -- Lua 5.1 weak keys are not ephemerons. A strong provenance record for the
    -- recursive closure would retain its environment -> Game -> installed method.
    for _, withRefresh in ipairs{false, true} do
        local weak = setmetatable({}, {__mode = "v"})
        local function registerAndRelease()
            local Game = {}
            local globals = {core = native.core()}
            local env = setmetatable({_M = Game, _G = globals}, {__index = _G})
            setfenv(assert(loadstring(code, "@/engine/class.lua")), env)()
            assert(Faster.installGame(Game))
            local original = Game.cloneForSave
            globals.game = setmetatable({w = 800, h = 600}, {__index = Game})
            if withRefresh then assert(Snapshot.installGame(Game)) end
            weak[1], weak[2], weak[3], weak[4] = Game, Game.cloneForSave, original, env
            collectgarbage("collect"); collectgarbage("collect")
            check(Faster.getInstalledEnvironment(original) == env,
                "weak provenance record remains valid while installed method is live")
        end
        registerAndRelease()
        collectgarbage("collect"); collectgarbage("collect")
        check(weak[1] == nil and weak[2] == nil and weak[3] == nil and weak[4] == nil,
            "provenance cache releases discarded Class, methods and recursive environment")
    end
    Snapshot.enableDiagnostics(false)
    native.reset()
end
local ok, err = xpcall(main, debug.traceback)
cleanup()
if not ok then error(err) end
print(("native snapshot refresh install: %d checks passed (%s)"):format(checks,
    jit and (jit.status() and "JIT on" or "JIT off") or "Lua 5.1"))
