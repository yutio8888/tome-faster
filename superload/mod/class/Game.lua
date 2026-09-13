-- GPL-3.0-or-later. Added 2026-09-12; see COPYING.
local Game = loadPrevious(...)
local ok, reason = require("engine.FasterSave").installGame(Game, config.settings.faster_tome)
if not ok then print("[Faster ToME4] Save coalescing skipped:", reason) end
local clone_ok, clone_reason = require("engine.FasterClone").installGame(Game, config.settings.faster_tome)
if not clone_ok then print("[Faster ToME4] Save clone optimization skipped:", clone_reason) end
local refresh_ok, refresh_reason = require("engine.FasterSnapshotRefresh").installGame(Game, config.settings.faster_tome)
if not refresh_ok then print("[Faster ToME4] Snapshot refresh skipped:", refresh_reason) end
local screenshot, screenshot_reason = require("engine.FasterScreenshot").prepareScreenshot(Game.takeScreenshot, config.settings.faster_tome)
if screenshot then Game.takeScreenshot = screenshot
else print("[Faster ToME4] Screenshot PNG optimization skipped:", screenshot_reason) end
local cleanup_ok, cleanup_reason = require("engine.FasterExportCleanup").installGame(Game, config.settings.faster_tome)
if not cleanup_ok then print("[Faster ToME4] Unused export party cleanup skipped:", cleanup_reason) end
if config.settings.faster_tome and config.settings.faster_tome.profile then
    require('engine.FasterProfile').attachGame(Game)
end
return Game
