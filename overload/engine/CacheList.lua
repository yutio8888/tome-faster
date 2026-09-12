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

-- Modified 2026-09-12: bounded caches and compatibility fixes.

module(..., package.seeall, class.make)

function _M:init(size)
    assert(type(size) == "number" and size >= 1 and size < math.huge and size == math.floor(size), "capacity must be a positive integer")
    self.size, self.index, self.count = size, 0, 0
end

function _M:append(values)
    for _, v in ipairs(values) do self:offer(v) end
end

function _M:offer(v)
    assert(v ~= nil, "cannot cache nil")
    self.index = self.index % self.size + 1
    self[self.index] = v
    self.count = math.min(self.count + 1, self.size)
end

function _M:peek()
    return self.index, self[self.index]
end

function _M:peekOldest()
    if self.count == 0 then return 0, nil end
    local index = (self.index - self.count) % self.size + 1
    return index, self[index]
end

-- Enumerate chronologically, optionally limiting to the oldest nb entries.
function _M:enumerate(nb)
    local ret = {}
    for offset = 1, math.min(nb or self.count, self.count) do
        ret[offset] = self[(self.index - self.count + offset - 1) % self.size + 1]
    end
    return ret
end

-- Discard oldest entries; retain the newest nb without copying survivors.
function _M:truncate(nb)
    assert(type(nb) == "number" and nb >= 0 and nb == math.floor(nb), "count must be a nonnegative integer")
    while self.count > nb do
        local index = self:peekOldest()
        self[index] = nil
        self.count = self.count - 1
    end
    if self.count == 0 then self.index = 0 end
end
