-- GPL-3.0-or-later. Added 2026-09-12; see COPYING.
local Game = loadPrevious(...)
-- The original Game has finished requiring Actor, Player and NPC here. These
-- installers are enabled by default; explicit opt-outs remain unloaded.
local options = config.settings.faster_tome
if not options or options.compact_inventory == nil or options.compact_inventory == true then
    local inventory_ok, inventory_reason = require("engine.FasterInventory").install(
        require "engine.interface.ActorInventory", require "mod.class.Actor", require "mod.class.Player", options)
    if not inventory_ok then print("[Faster ToME4] Compact inventory records skipped:", inventory_reason) end
end
if not options or options.fearscape_cleanup == nil or options.fearscape_cleanup == true then
    local fearscape_ok, fearscape_reason = require("engine.FasterFearscape").installTalents(require "engine.interface.ActorTalents", options)
    if not fearscape_ok then print("[Faster ToME4] Fearscape reference cleanup skipped:", fearscape_reason) end
end
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
