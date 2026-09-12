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

local _M = loadPrevious(...)
-- Strong FIFO cache, bounded to 128 generated text entries per dialog.
local CACHE_LIMIT = 128

function _M:setScroll(i, do_shifty_thing)
    local cache = self._faster_text_cache
    if not cache or cache.font ~= self.font or cache.width ~= self.iw - 10 then
        if cache then
            -- Wrapping measurements belong to the previous rendering setup.
            self.line_size = {}
            self.max = #self.lines
            self.scrollbar.max = math.max(0, self.max - self.max_display)
            self.scroll = nil
        end
        cache = {font = self.font, width = self.iw - 10, entries = {}, order = {}, next_slot = 1}
        self._faster_text_cache = cache
    end
    local old = self.scroll
    self.scroll = util.bound(i, 0, self.scrollbar.max)

    if self.scroll == old then return end
    self.dlist = {}
    local cur = 0
    local shift = 0
    for i = 1, #self.lines do
        local str = self.lines[i].str
        local size = self.line_size[str] or 1
        if cur + size > self.scroll then
            local gen
            if cache.entries[str] then
                gen = cache.entries[str]
            else
                gen = self.font:draw(str, self.iw - 10, 255, 255, 255, false, true)
                local slot = cache.next_slot
                if cache.order[slot] then cache.entries[cache.order[slot]] = nil end
                cache.entries[str] = gen
                cache.order[slot] = str
                cache.next_slot = slot % CACHE_LIMIT + 1
            end
            if size ~= #gen then
                self.line_size[str] = #gen
                shift = shift + #gen - size
                if do_shifty_thing then
                    -- drop lines!
                    local delta = #gen - size
                    if delta > 0 then
                        for i = 1, #self.dlist do self.dlist[i] = self.dlist[i + delta] end -- this fills the end with nils, too
                    end
                end
                size = #gen
            end
            local stop
            for _, tex in pairs(gen) do
                if cur >= self.scroll then
                    local dtex = {t=tex._tex, w=tex.w, h=tex.h, tw = tex._tex_w, th = tex._tex_h, dduids = tex._dduids}
                    self.dlist[#self.dlist+1] = {d=dtex, src=self.lines[i].src}
                    if #self.dlist > self.max_display then stop=true break end
                end
                cur = cur + 1
            end
            if stop then break end
        else
            cur = cur + size
        end
    end
    self.max = self.max + shift
    if do_shifty_thing then self.scroll = self.scroll + shift end
    self.scrollbar.max = math.max(0, self.max - self.max_display)
end


return _M