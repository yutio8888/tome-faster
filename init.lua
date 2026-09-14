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

-- Modified 2026-09-14 by yutio8888: maintained fork, original authorship retained.
long_name = "Faster ToME4"
short_name = "faster"
for_module = "tome"
version = {1,7,6}
addon_version = {0,2,12}
tags = { "fast" }
weight = 100000
author = { "Yutio888", "yutio888@qq.com" }
homepage = "http://te4.org/"
description = [[Performance optimizations for ToME 1.7.6: inventory ownership compaction and completed Fearscape reference cleanup are enabled by default, alongside short decimal save names. Base62 save names remain opt-in. These features retain the original archive reader and compression level. Includes faster A* pathfinding, effect-mask batching with the default framebuffer GC guard, weak chat measurement caches, ranged-hit direction indicators limited to one per 500 ms per map, faster lossless save screenshots, synchronous snapshot screen refresh, bounded rendering caches, serializer callback reuse, and previous save/export fixes. Retains online exports and graphics settings. Reduced visual emitters and omitted temporary export party work also reduce RNG consumption.]]
overload = true
superload = true
hooks = true
