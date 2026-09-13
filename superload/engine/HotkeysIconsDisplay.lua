-- GPL-3.0-or-later; see COPYING.
local Display = loadPrevious(...)
local ok, reason = require("engine.FasterHotkeys").install(Display, config.settings.faster_tome)
if not ok then print("[Faster ToME4] Hotkey text optimization skipped:", reason) end
return Display
