-- GPL-3.0-or-later. Added 2026-09-12; see COPYING.
local Game = loadPrevious(...)
local ok, reason = require("engine.FasterSave").installGame(Game, config.settings.faster_tome)
if not ok then print("[Faster ToME4] Save coalescing skipped:", reason) end
local clone_ok, clone_reason = require("engine.FasterClone").installGame(Game, config.settings.faster_tome)
if not clone_ok then print("[Faster ToME4] Save clone optimization skipped:", clone_reason) end
if config.settings.faster_tome and config.settings.faster_tome.profile then
    require('engine.FasterProfile').attachGame(Game)
end
return Game
