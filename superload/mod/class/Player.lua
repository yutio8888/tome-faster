-- GPL-3.0-or-later. Added 2026-09-12; see COPYING.
local Player = loadPrevious(...)
local options = config.settings.faster_tome
local exporter, reason = require("engine.FasterGzip").prepareExporter(Player.saveUUID, options)
if not exporter then print("[Faster ToME4] Character gzip optimization skipped:", reason) end
local ok
ok, reason = require("engine.FasterChardump").installPlayer(Player, options, exporter)
if not ok then
    print("[Faster ToME4] Offline character export optimization skipped:", reason)
    if exporter then Player.saveUUID = exporter end
end
return Player
