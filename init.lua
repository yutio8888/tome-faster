-- ToME - Tales of Maj'Eyal:
-- Copyright (C) 2009 - 2019 Nicolas Casalini
--
-- This program is free software: you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation, either version 3 of the License, or
-- (at your option) any later version.
--
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU General Public License for more details.
--
-- You should have received a copy of the GNU General Public License
-- along with this program.  If not, see <http://www.gnu.org/licenses/>.
--
-- Nicolas Casalini "DarkGod"
-- darkgod@te4.org

-- Modified 2026-09-13 by yutio8888: maintained fork, original authorship retained.
long_name = "Faster ToME4"
short_name = "faster"
for_module = "tome"
version = {1,7,6}
addon_version = {0,2,5}
tags = { "fast" }
weight = 100000
author = { "Yutio888", "yutio888@qq.com" }
homepage = "http://te4.org/"
description = [[Performance optimizations for ToME 1.7.6: cache stable hotkey text, batch effect-mask geometry, reuse serializer callbacks, release character-export gzip state, and retain existing save optimizations. Retains online exports, save format and graphics settings. Omitting the temporary party also omits its RNG consumption and temporary UID allocation.]]
overload = true
superload = true
hooks = true
