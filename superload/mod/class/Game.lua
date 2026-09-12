-- GPL-3.0-or-later. Added 2026-09-12; see COPYING.
local Game = loadPrevious(...)
local ok, reason = require("engine.FasterSave").installGame(Game, config.settings.faster_tome)
if not ok then print("[Faster ToME4] Save coalescing skipped:", reason) end
return Game
