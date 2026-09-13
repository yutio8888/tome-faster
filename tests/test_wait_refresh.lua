-- GPL-3.0-or-later. Actual pinned native wait/redraw/web code, mock SDL and GL.
assert(_VERSION == "Lua 5.1", "Lua 5.1 / LuaJIT required")
local root, repo = arg[1] or ".", assert(arg[2], "pass local engine Git clone")
local native, cleanup = assert(loadfile(root .. "/tests/wait_refresh_build.lua"))()(root, repo)
local checks = 0
local function check(ok, why) assert(ok, why); checks = checks + 1 end
local function main()
    local wait = native.wait
    local game = {displays = 0, inputs = 0, ticks = 0, quits = 0, value = "before"}
    function game:display() self.displays = self.displays + 1 end
    function game:input() self.inputs = self.inputs + 1 end
    function game:tick() self.ticks = self.ticks + 1 end
    function game:onQuit() self.quits = self.quits + 1; self.value = "changed-by-quit" end
    native.setGame(game)
    local draws = 0
    local function draw() draws = draws + 1; wait.drawLastFrame() end
    local function factory() return draw end
    local function clean(label)
        local s = native.stats()
        check(s.waiting == 0 and s.texture == 0 and s.hook_mask == 0, label .. " native state cleaned")
        check(s.textures_created == s.textures_deleted, label .. " texture released once")
    end

    -- Nesting is balanced without invoking the nested factory or changing the
    -- outer wait's draw callback, progress count, texture, or manual mode.
    native.reset()
    local outer, depth = wait.enable(1000000000, factory)
    local s = native.stats()
    check(outer and depth == 1 and s.waiting == 1, "outer enable reports ownership")
    check(s.own_hook == 1 and s.hook_mask ~= 0 and s.hook_count == 1000000000, "native installs count hook")
    check(s.textures_created == 1 and s.copies == 1 and s.redraws == 1 and draws == 1, "one capture and initial draw")
    check(game.displays == 0 and s.particles == 0, "waiting skips actual Game.display and particle update")
    wait.enableManualTick(true); wait.manualTick(7)
    local before = native.stats()
    local inner, nestedDepth = wait.enable(3, function() error("nested factory must not run") end)
    s = native.stats()
    check(not inner and nestedDepth == 2 and s.waiting == 2, "nested enable reports no ownership")
    check(s.manual == 1 and s.hook_mask == 0 and s.redraws == before.redraws and s.textures_created == 1,
        "nested enable preserves outer mode and display")
    local stillWaiting, remaining = wait.disable()
    check(stillWaiting and remaining == 1 and native.stats().texture ~= 0, "nested disable preserves outer resources")
    check(wait.getTicks() == 7, "nested enable does not reset outer progress")
    wait.disable(); clean("nested wait")
    native.forceRedraw()
    check(game.displays == 1 and native.stats().particles == 1, "display and particles resume after cleanup")

    -- Manual ticks pump OS events without polling or dispatching Lua input/tick
    -- handlers. The actual native redraw also keeps animation time stationary.
    native.reset(); draws = 0
    wait.manualTick(5)
    check(native.stats().pumps == 0 and wait.getTicks() == 0, "manual tick outside wait is a no-op")
    wait.enable(1000000000, factory); wait.enableManualTick(true)
    local animationTime, displays = native.stats().animation_time, game.displays
    native.queueEvents(2, 3); native.advance(1000); wait.manualTick(4)
    s = native.stats()
    check(s.pumps == 1 and s.queued_inputs == 2 and s.queued_ticks == 3, "PumpEvents queues input and timer events")
    check(s.inputs == 0 and s.ticks == 0 and game.inputs == 0 and game.ticks == 0, "pumping dispatches no game events")
    check(game.displays == displays and s.particles == 0 and s.animation_time == animationTime,
        "actual native wait redraw freezes game display and animation time")
    local redraws = s.redraws
    native.advance(50); wait.manualTick(2)
    check(native.stats().redraws == redraws and native.stats().pumps == 2, "30 FPS manual hook redraw throttles at 100 ms")
    native.advance(50); wait.manualTick(1)
    check(native.stats().redraws == redraws + 1 and wait.getTicks() == 7, "next manual hook redraw and progress")
    local pumps = native.stats().pumps
    native.forceRedraw()
    check(native.stats().redraws == redraws + 2 and native.stats().pumps == pumps, "forceRedraw bypasses throttle without polling events")
    wait.addMaxTicks(12)
    local count, maximum = wait.getTicks()
    check(count == 7 and maximum == 12, "native progress remains independent of redraw")
    wait.disable(); clean("manual wait")
    native.dispatchEvents()
    check(game.inputs == 2 and game.ticks == 3, "queued events execute after caller resumes the event loop")

    -- SDL event filters run while events are added, before PollEvent. The
    -- actual engine filter calls Game.onQuit immediately for SDL_QUIT, so a
    -- manual tick is unsafe even with Steam and web completely disabled.
    native.reset(); game.value = "before"
    wait.enable(1000000000, factory); wait.enableManualTick(true)
    native.queueQuit(); wait.manualTick(0)
    s = native.stats()
    check(game.quits == 1 and game.value == "changed-by-quit" and s.filtered_quits == 1,
        "counterexample: PumpEvents invokes actual SDL_QUIT filter during wait")
    check(s.waiting == 1 and s.inputs == 0 and s.ticks == 0 and s.queued_quits == 0,
        "quit filter invokes Lua before outer event dispatch and consumes quit event")
    wait.disable(); clean("quit counterexample")
    native.reset(); game.value = "before"
    wait.enable(1000000000, factory); wait.enableManualTick(true)
    native.queueQuit(); native.forceRedraw()
    check(game.quits == 1 and game.value == "before" and native.stats().os_quits == 1,
        "redraw without manual tick leaves quit event unpumped")
    wait.disable(); clean("unpolled quit")
    native.pumpEvents()
    check(game.quits == 2 and game.value == "changed-by-quit", "quit filter runs when pumping resumes after cleanup")

    -- Native debug hooks are real LuaJIT hooks. Existing hooks must cause the
    -- addon to fall back: enableManualTick(true) otherwise erases them.
    native.reset(); wait.enable(1000000000, factory)
    wait.enableManualTick(true)
    check(native.stats().manual == 1 and native.stats().hook_mask == 0, "manual mode removes native hook")
    wait.enableManualTick(false)
    check(native.stats().manual == 0 and native.stats().own_hook == 1 and native.stats().hook_count == 1000000000,
        "disabling manual mode reinstates native count hook")
    wait.disable(); clean("hook toggle")
    native.reset()
    local function existingHook() end
    debug.sethook(existingHook, "", 1000000000)
    wait.enable(1000000000, factory)
    local hook, mask, hookCount = debug.gethook()
    check(hook == existingHook and mask == "" and hookCount == 1000000000, "first native enable leaves existing hook installed")
    wait.enableManualTick(true)
    check(native.stats().hook_mask == 0, "counterexample: native manual mode disables existing debug hook")
    debug.sethook()
    wait.disable(); clean("existing hook")
    native.reset(); wait.enable(1000000000, factory); wait.disable()
    debug.sethook(existingHook, "", 1000000000)
    wait.enable(1000000000, factory); wait.disable()
    check(native.stats().hook_mask == 0, "counterexample: stale native hook ownership also disables a later existing hook")
    debug.sethook()
    clean("stale hook ownership")

    -- Neither initial draw nor later draw errors unwind native wait ownership.
    -- The caller must disable exactly once and preserve the original error.
    for _, phase in ipairs{"factory", "first_draw", "later_draw"} do
        native.reset()
        local marker, shouldFail = {}, phase ~= "later_draw"
        local callback = function() if shouldFail then error(marker) end end
        local callbackWeak = setmetatable({callback}, {__mode = "v"})
        local getDraw = function() if phase == "factory" then error(marker) end; return callback end
        local ok, err
        if phase == "later_draw" then
            wait.enable(1000000000, getDraw); wait.enableManualTick(true)
            shouldFail = true; ok, err = pcall(native.forceRedraw)
        else ok, err = pcall(wait.enable, 1000000000, getDraw) end
        check(not ok and err == marker, phase .. " preserves exact error object")
        check(native.stats().waiting == 1 and native.stats().texture ~= 0, phase .. " native does not automatically unwind")
        wait.disable(); clean(phase)
        callback = nil; getDraw = nil
        collectgarbage("collect"); collectgarbage("collect")
        check(callbackWeak[1] == nil, phase .. " callback root is released by cleanup")
    end
    native.reset(); wait.enable(1000000000, factory); wait.enableManualTick(true)
    local marker = {}
    local ok, err = pcall(function()
        local owned = wait.enable(1000000000, factory)
        if not owned then wait.disable() end
        error(marker)
    end)
    check(not ok and err == marker and native.stats().waiting == 1 and native.stats().manual == 1,
        "nested fallback error leaves outer waiter alive")
    wait.disable(); clean("nested fallback error")
    check(native.stats().draw_ref ~= -2, "native disable retains stale registry number: always supply a factory next time")

    -- Dangerous native redraw tail, reproduced from pinned web.c, is outside
    -- call_draw's wait guard. A queued RUN_LUA event can mutate the save graph.
    native.reset(); game.value = "before"
    local previousGame = _G.__wait_refresh_test_game
    _G.__wait_refresh_test_game = game
    wait.enable(1000000000, factory); wait.enableManualTick(true)
    displays = game.displays
    native.web(true, "__wait_refresh_test_game.value = 'changed-by-web'")
    native.forceRedraw()
    s = native.stats()
    check(game.value == "changed-by-web" and s.web == 1, "real native web event mutates graph during wait")
    check(game.displays == displays and s.particles == 0 and s.inputs == 0 and s.ticks == 0,
        "web mutation bypasses otherwise frozen Game.display and event processing")
    game.value = "before"
    native.web(false, "__wait_refresh_test_game.value = 'unexpected'")
    native.forceRedraw()
    check(game.value == "before" and native.stats().web == 1, "private native webcore gate suppresses dispatch when unavailable")
    wait.disable(); clean("web counterexample")
    _G.__wait_refresh_test_game = previousGame
    native.reset()
end
local ok, err = xpcall(main, debug.traceback)
cleanup()
if not ok then error(err) end
print(("native wait refresh: %d checks passed (%s)"):format(checks, jit and (jit.status() and "JIT on" or "JIT off") or "Lua 5.1"))
