-- GPL-3.0-or-later. Added 2026-09-12; see COPYING.
local Player = loadPrevious(...)
local ok, reason = require("engine.FasterChardump").installPlayer(Player, config.settings.faster_tome)
if not ok then print("[Faster ToME4] Offline character export optimization skipped:", reason) end
return Player
