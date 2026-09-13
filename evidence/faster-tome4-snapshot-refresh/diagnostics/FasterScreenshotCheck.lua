-- Local diagnostic only. Keep image files in the disposable profile home.
-- Compare two encoders after ONE original screenshot redraw per pair.
local M = {}
function M.run(game)
    local Faster = require "engine.FasterScreenshot"
    local before = Faster.stats()
    local state = require("engine.FasterSaveState").capture(game)
    local directory = "faster-screenshot-check"
    fs.mkdir(directory)
    local rows = {}
    local turn = game.turn
    for i = 1, 12 do
        local candidate = game:takeScreenshot(true)
        assert(core.display.redrawingForSavefileScreenshot(), "capture mode changed")
        local x, y = game.w/4, game.h/4
        if game.level then
            x, y = game.level.map:getTileToScreen(game.player.x, game.player.y, true)
            x, y = util.bound(x-game.w/4,0,game.w/2), util.bound(y-game.h/4,0,game.h/2)
        end
        local original = core.display.getScreenshot(x,y,game.w/2,game.h/2)
        assert(type(candidate)=="string" and type(original)=="string", "PNG encoder returned no data")
        for _, item in ipairs{{"candidate",candidate},{"original",original}} do
            local file=assert(fs.open(directory..("/screenshot-check-%02d-%s.png"):format(i,item[1]),"w"))
            file:write(item[2]); file:close()
        end
        rows[#rows+1]={candidate_bytes=#candidate,original_bytes=#original,width=game.w/2,height=game.h/2}
    end
    local after = Faster.stats()
    assert(after.captures-before.captures == #rows, "real screenshot candidate bypassed")
    assert(after.failures==before.failures and after.bypasses==before.bypasses, "real screenshot guard/error fallback")
    assert(game.turn==turn, "screenshots advanced game turn")
    assert(require("engine.FasterSaveState").check(state,game), "screenshot business state changed")
    return {kind="screenshot_encoder_pairs",pairs=rows,optimized_captures=after.captures-before.captures,
        retained_buffer_bytes=after.buffer_bytes,turn_delta=game.turn-turn,
        pixel_validation="Decode paired PNGs independently outside the game; not asserted by this Lua module."}
end
return M
