-- Runs with LuaJIT and screenshot-probe.so; no game/display is started.
local root = assert(arg[1], 'pass diagnostic source directory')
local ffi = require 'ffi'
ffi.cdef[[int faster_screenshot_scope(int);]]
local marker = {}
local Game = {}
core = {display={}}
local calls = {screenshot=0, redraw=0, capture=0, save=0}
core.display.forceRedrawForScreenshot = function(flag)
    calls.redraw = calls.redraw + 1
    assert(flag == true)
    return nil, marker, nil
end
core.display.getScreenshot = function(x,y,w,h)
    calls.capture = calls.capture + 1
    assert(x==1 and y==2 and w==3 and h==4)
    return 'PNG', nil, marker
end
Game.takeScreenshot = function(self, flag)
    calls.screenshot = calls.screenshot + 1
    assert(self == Game)
    if flag == 'fail' then error(marker) end
    core.display.forceRedrawForScreenshot(flag)
    return core.display.getScreenshot(1,2,3,4)
end
Game.saveGame = function(self, flag)
    calls.save = calls.save + 1
    if flag == 'fail' then error(marker) end
    if flag == 'yield' then coroutine.yield('paused') end
    return self:takeScreenshot(true)
end
package.preload['mod.class.Game'] = function() return Game end
local screenshot, redraw, capture, save = Game.takeScreenshot,
    core.display.forceRedrawForScreenshot, core.display.getScreenshot, Game.saveGame
local M = assert(loadfile(root..'/FasterScreenshotProfile.lua'))()
local function packed(...) return {n=select('#',...), ...} end
M.start()
local r = packed(Game:saveGame())
assert(r.n == 3 and r[1] == 'PNG' and r[2] == nil and r[3] == marker)
local s = M.snapshot()
for _, key in ipairs{'takeScreenshot','forceRedrawForScreenshot','getScreenshot'} do
    assert(s.lua[key].calls == 1 and s.lua[key].wall_ms >= 0 and s.lua[key].cpu_ms >= 0)
end
assert(s.swaps.save.calls == 0 and s.swaps.save.scopes == 1 and s.swaps.save.intervals == 1)
local ok, err = pcall(Game.takeScreenshot, Game, 'fail')
assert(not ok and err == marker and M.snapshot().lua.takeScreenshot.failures == 1)
assert(ffi.C.faster_screenshot_scope(0) == 0)
ok, err = pcall(Game.saveGame, Game, 'fail')
assert(not ok and err == marker)
M.beginSwapScope('whole_save')
Game:saveGame()
M.endSwapScope()
assert(M.snapshot().swaps.whole_save.scopes == 1)
local co = coroutine.create(function() return Game:saveGame('yield') end)
ok, err = coroutine.resume(co); assert(ok and err == 'paused')
r = packed(coroutine.resume(co)); assert(r.n == 4 and r[1] and r[2]=='PNG' and r[4]==marker)
M.reset(); assert(M.snapshot().lua.takeScreenshot.calls == 0)
M.stop()
assert(Game.takeScreenshot == screenshot and core.display.forceRedrawForScreenshot == redraw)
assert(core.display.getScreenshot == capture and Game.saveGame == save)
M.start({screenshots=false, save_swaps=true})
assert(Game.takeScreenshot == screenshot and core.display.forceRedrawForScreenshot == redraw)
assert(core.display.getScreenshot == capture and Game.saveGame ~= save)
Game:saveGame(); s = M.snapshot()
assert(next(s.lua) == nil and next(s.native) == nil and s.swaps.save.scopes == 1)
M.stop()
M.start({screenshots=false, save_swaps=false})
assert(Game.saveGame == save)
M.beginSwapScope('manual'); Game:saveGame(); M.endSwapScope()
assert(M.snapshot().swaps.manual.scopes == 1)
M.stop()
print('PASS: exact Lua returns/arguments/errors, scope cleanup, nested/manual saves, coroutine yield,')
print('      wrapper restoration, reset, restart, swap-only and manual-only modes.')
