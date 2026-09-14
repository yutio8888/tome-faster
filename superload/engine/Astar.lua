-- ToME - Tales of Maj'Eyal / T-Engine4
-- Copyright (C) 2009 - 2019 Nicolas Casalini
-- GPL-3.0-or-later; see COPYING.
-- Modified 2026-09-13: preserve A* paths while reducing frontier/neighbor work.
local Astar = loadPrevious(...)
local ok, reason = require("engine.FasterAI").installAstar(Astar, config.settings.faster_tome)
if not ok then print("[Faster ToME4] AI pathfinding optimization skipped:", reason) end
return Astar
