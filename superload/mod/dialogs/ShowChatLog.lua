local _M = loadPrevious(...)
local cache = {}
setmetatable(cache, {__mode="v"})

function _M:setScroll(i, do_shifty_thing)
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
            if cache[str] then
                gen = cache[str]
            else
                gen = self.font:draw(str, self.iw - 10, 255, 255, 255, false, true)
                cache[str] = gen
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