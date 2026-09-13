-- GPL-3.0-or-later. Based on ToME 1.7.6 engine/HotkeysIconsDisplay.lua.
-- Copyright (C) 2009 - 2019 Nicolas Casalini. See COPYING.
-- Modified 2026-09-13: cache only the three hotkey text rasterizations.
local M = {}
local MAX_ENTRIES, MAX_BYTES, MAX_TEXT = 512, 4 * 1024 * 1024, 256
local owners = setmetatable({}, {__mode = "k"})
local installed = setmetatable({}, {__mode = "k"})
local slots, cursor, count, bytes = {}, 1, 0, 0
local binding_sentinel
local totals = {hits = 0, misses = 0, bypasses = 0, evictions = 0, invalidations = 0}

local function native(f)
    return type(f) == "function" and debug.getinfo(f, "S").what == "C"
end
local function upstream(f, first, last, nups)
    if type(f) ~= "function" then return false end
    local i = debug.getinfo(f, "Su")
    return i.source == "@/engine/HotkeysIconsDisplay.lua" and i.linedefined == first
        and i.lastlinedefined == last and (not nups or i.nups == nups)
end
local function captureBindings()
    local r = debug.getregistry()
    local fm, tm, sm = r["sdl{font}"], r["gl{texture}"], r["sdl{surface}"]
    local d = core and core.display
    if type(fm) ~= "table" or type(tm) ~= "table" or type(sm) ~= "table" or type(d) ~= "table" then return end
    local fi, ti, si = rawget(fm, "__index"), rawget(tm, "__index"), rawget(sm, "__index")
    if type(fi) ~= "table" or type(ti) ~= "table" or type(si) ~= "table"
        or fi.class ~= "sdl{font}" or ti.class ~= "gl{texture}" or si.class ~= "sdl{surface}" then return end
    local b = {fm = fm, tm = tm, sm = sm, fi = fi, ti = ti, si = si, display = d, fonts = {}, display_methods = {}}
    -- engine.utils replaces size with its own Lua measurement cache. Size is
    -- still called by the untouched stock body and its actual width is keyed;
    -- it is not an input to the native draw implementation itself.
    for _, name in ipairs{"draw", "getStyle", "setStyle"} do
        if not native(rawget(fi, name)) then return end
        b.fonts[name] = rawget(fi, name)
    end
    for _, name in ipairs{"size", "getBreakTextAllCharacter", "getTextBlended", "newSurface"} do
        if not native(rawget(d, name)) then return end
        b.display_methods[name] = rawget(d, name)
    end
    if not native(rawget(ti, "bind")) or not native(rawget(si, "glTexture")) then return end
    b.bind, b.glTexture = rawget(ti, "bind"), rawget(si, "glTexture")
    return b
end
local bindings = captureBindings()

local function validBindings(font)
    local b = bindings
    if not b or type(font) ~= "userdata" or getmetatable(font) ~= b.fm or not core or core.display ~= b.display
        or rawget(b.fm, "__index") ~= b.fi or rawget(b.tm, "__index") ~= b.ti
        or rawget(b.sm, "__index") ~= b.si or rawget(b.si, "glTexture") ~= b.glTexture
        or rawget(b.ti, "bind") ~= b.bind then return false end
    for name, f in pairs(b.fonts) do if rawget(b.fi, name) ~= f then return false end end
    for name, f in pairs(b.display_methods) do if rawget(b.display, name) ~= f then return false end end
    return true
end

local function bump(state, name)
    totals[name] = totals[name] + 1
    if state then state[name] = (state[name] or 0) + 1 end
end
local function remove(entry, evicted)
    if not entry or slots[entry.slot] ~= entry then return end
    slots[entry.slot] = nil
    entry.bucket[entry.key] = nil
    entry.bucket.count = entry.bucket.count - 1
    if entry.bucket.count == 0 then entry.state.cache[entry.font] = nil end
    count, bytes = count - 1, bytes - entry.bytes
    entry.state.entries = entry.state.entries - 1
    entry.state.bytes = entry.state.bytes - entry.bytes
    if evicted then bump(entry.state, "evictions") end
end
local function empty(state)
    for i = 1, MAX_ENTRIES do
        local entry = slots[i]
        if entry and entry.state == state then remove(entry) end
    end
end

-- Explicit resource-reload hook. No cache or diagnostics field is put on a
-- display, actor or game. FIFO entries retain only native resources/scalars and
-- an owner token, never an owner reference, even in Lua 5.1 weak tables.
function M.clear(owner)
    if owner then
        local state = owners[owner]
        if state then empty(state); owners[owner] = nil end
    else
        owners = setmetatable({}, {__mode = "k"})
        slots, cursor, count, bytes = {}, 1, 0, 0
        binding_sentinel = nil
        for name in pairs(totals) do totals[name] = 0 end
    end
end
function M.stats(owner)
    local state = owner and owners[owner]
    local source = owner and (state or {}) or totals
    local out = {entries = owner and (state and state.entries or 0) or count,
        bytes = owner and (state and state.bytes or 0) or bytes + (binding_sentinel and 4 or 0),
        max_entries = MAX_ENTRIES, max_bytes = MAX_BYTES}
    for name in pairs(totals) do out[name] = source[name] or 0 end
    return out
end

local signature_fields = {"surface", "font", "fontbig", "w", "h", "icon_w", "icon_h", "fontsize", "fontname"}
local function generation(owner, state)
    local changed = false
    for _, name in ipairs(signature_fields) do
        local value = rawget(owner, name)
        -- Avoid retaining arbitrary addon tables (which could refer to owner).
        if type(value) == "table" or type(value) == "function" or type(value) == "thread" then return false end
        if state[name] ~= value then state[name], changed = value, true end
    end
    local settings = config and config.settings or {}
    local sw, sh, fullscreen, borderless, rw, rh = bindings.display_methods.size()
    local signature = {sw, sh, rw, rh, fullscreen, borderless, settings.screen_zoom, settings.font_scale, settings.locale,
        bindings.display_methods.getBreakTextAllCharacter(), bindings.display_methods.getTextBlended()}
    for i = 1, 11 do
        local value = signature[i]
        if value ~= nil and type(value) ~= "number" and type(value) ~= "string" and type(value) ~= "boolean" then return false end
        if state.signature[i] ~= value then state.signature[i], changed = value, true end
    end
    if changed then empty(state); bump(state, "invalidations") end
    return true
end
local function integer(v, min, max) return type(v) == "number" and v >= min and v <= max and v == math.floor(v) end
local function copy(line)
    local fresh = {}
    for k, v in pairs(line) do fresh[k] = v end
    return fresh
end
local function bindResult(texture)
    local b = bindings
    if not binding_sentinel then
        local ok, sentinel = pcall(function()
            return b.glTexture(b.display_methods.newSurface(1, 1))
        end)
        if not ok or type(sentinel) ~= "userdata" or getmetatable(sentinel) ~= b.tm then return false end
        binding_sentinel = sentinel
    end
    -- font_make_texture_line forces glBindTexture. The public bind method
    -- instead uses a single cached texture ID, even across texture units.
    -- Bind a distinct private 1x1 texture first so the final bind cannot be
    -- skipped when a callback previously bound this result on another unit.
    -- Both binds use the current unit and leave every other GL state alone.
    b.bind(binding_sentinel, 0)
    b.bind(texture, 0)
    return true
end

-- Public for native pixel/GL-state diagnostics. The optimized stock display
-- uses this exact path; arbitrary formatted/dynamic/UID text always delegates.
function M.draw(owner, font, text, width, r, g, b, no_linefeed, direct_uid_draw)
    local state = owners[owner]
    if type(owner) ~= "table" or not validBindings(font) then
        if state then empty(state) end
        bump(state, "bypasses")
        return font:draw(text, width, r, g, b, no_linefeed, direct_uid_draw)
    end
    if not state then
        state = {cache = {}, signature = {}, entries = 0, bytes = 0}
        owners[owner] = state
    end
    if not generation(owner, state) then
        empty(state)
        bump(state, "bypasses")
        return font:draw(text, width, r, g, b, no_linefeed, direct_uid_draw)
    end
    if type(text) ~= "string" or #text > MAX_TEXT
        or text:find("[#%c]") or not integer(width, 1, 4096) or not integer(r, 0, 255)
        or not integer(g, 0, 255) or not integer(b, 0, 255) or no_linefeed ~= true
        or (direct_uid_draw ~= nil and direct_uid_draw ~= false) then
        bump(state, "bypasses")
        return font:draw(text, width, r, g, b, no_linefeed, direct_uid_draw)
    end
    -- Read on EVERY call, including fontbig: native setStyle mutates a shared
    -- font in place. Its public setter supports precisely these four styles.
    local style = bindings.fonts.getStyle(font)
    if style ~= "normal" and style ~= "bold" and style ~= "italic" and style ~= "underline" then
        bump(state, "bypasses")
        return font:draw(text, width, r, g, b, no_linefeed, direct_uid_draw)
    end
    local key = text .. "\0" .. style .. ":" .. width .. ":" .. r .. ":" .. g .. ":" .. b
        .. ":" .. tostring(direct_uid_draw)
    local bucket = state.cache[font]
    local entry = bucket and bucket[key]
    if entry then
        if not bindResult(entry.line._tex) then
            empty(state)
            bump(state, "bypasses")
            return font:draw(text, width, r, g, b, no_linefeed, direct_uid_draw)
        end
        bump(state, "hits")
        -- The original single-line draw leaves its generated texture bound on
        -- the current unit. Preserve that state without an extra screen draw.
        return {copy(entry.line)}, entry.lines, entry.realw
    end
    bump(state, "misses")
    local lines, n, realw = font:draw(text, width, r, g, b, no_linefeed, direct_uid_draw)
    local line = type(lines) == "table" and getmetatable(lines) == nil and rawget(lines, 1)
    if n ~= 1 or type(line) ~= "table" or getmetatable(line) ~= nil
        or type(line._tex) ~= "userdata" or getmetatable(line._tex) ~= bindings.tm
        or not integer(line._tex_w, 1, 8192) or not integer(line._tex_h, 1, 8192) then return lines, n, realw end
    for k, v in pairs(line) do
        if type(k) ~= "string" or (k ~= "_tex" and type(v) ~= "number" and type(v) ~= "string" and type(v) ~= "boolean") then
            return lines, n, realw
        end
    end
    local cost = line._tex_w * line._tex_h * 4
    -- Reserve four bytes for the 1x1 binding sentinel, even before first hit.
    if cost > MAX_BYTES - 4 then return lines, n, realw end
    while slots[cursor] or bytes + cost > MAX_BYTES - 4 do
        remove(slots[cursor], true)
        cursor = cursor % MAX_ENTRIES + 1
    end
    bucket = state.cache[font]
    if not bucket then bucket = {count = 0}; state.cache[font] = bucket end
    entry = {key = key, font = font, bucket = bucket, state = state, slot = cursor,
        line = copy(line), lines = n, realw = realw, bytes = cost}
    bucket[key], bucket.count = entry, bucket.count + 1
    slots[cursor] = entry
    cursor = cursor % MAX_ENTRIES + 1
    count, bytes = count + 1, bytes + cost
    state.entries, state.bytes = state.entries + 1, state.bytes + cost
    return lines, n, realw
end

-- The body below is stock 624a673, changing ONLY three font:draw expressions.
local function makeDisplay(environment, page_to_hotkey)
    local cachedDraw = M.draw
local function display(self)
	local a = self.actor
	if not a or not a.changed then return self.surface end

	local bpage = a.hotkey_page
	local spage = bpage
--	if bpage == 1 and core.key.modState("ctrl") then spage = 2 if self.max_cols < 24 then bpage = 2 end
--	elseif bpage == 1 and core.key.modState("shift") then spage = 3 if self.max_cols < 36 then bpage = 3 end
--	end

	self.surface:erase(self.bgcolor[1], self.bgcolor[2], self.bgcolor[3])
	if self.bg_surface then self.surface:merge(self.bg_surface, 0, 0) end

	local orient = self.orient or "down"
	local x = 0
	local y = 0
	local col, row = 0, 0
	self.dragclics = {}
	self.clics = {}
	self.items = {}
	local w, h = self.frames.w, self.frames.h

	for page = bpage, #page_to_hotkey do for i = 1, 12 do
		local ts = nil
		local bi = i
		local j = i + (12 * (page - 1))
		if a.hotkey[j] and a.hotkey[j][1] == "talent" then
			ts = {a.hotkey[j][2], j, "talent", i, page, i + (12 * (page - bpage))}
		elseif a.hotkey[j] and a.hotkey[j][1] == "inventory" then
			ts = {a.hotkey[j][2], j, "inventory", i, page, i + (12 * (page - bpage))}
		end

		x = self.frames.w * col
		y = self.frames.h * row
		self.dragclics[j] = {x,y,w,h}

		if ts then
			local s
			local i = ts[2]
			local lpage = ts[5]
			local color, angle, txt = nil, 0, nil
			local display_entity = nil
			local frame = "ok"
			if ts[3] == "talent" then
				local tid = ts[1]
				local t = a:getTalentFromId(tid)
				if t then
					display_entity = t.display_entity
					if a:isTalentCoolingDown(t) then
						if not a:preUseTalent(t, true, true) then
							color = {190,190,190}
							frame = "disabled"
						else
							frame = "cooldown"
							color = {255,0,0}
							angle = 360 * (1 - (a.talents_cd[t.id] / a:getTalentCooldown(t)))
						end
						txt = tostring(math.ceil(a:isTalentCoolingDown(t)))
					elseif a:isTalentActive(t.id) then
						color = {255,255,0}
						frame = "sustain"
					elseif not a:preUseTalent(t, true, true) then
						color = {190,190,190}
						frame = "disabled"
					end
				end
			elseif ts[3] == "inventory" then
				local o = a:findInAllInventories(ts[1], {no_add_name=true, force_id=true, no_count=true})
				local cnt = 0
				if o then cnt = o:getNumber() end
				if cnt == 0 then
					color = {190,190,190}
					frame = "disabled"
				end
				display_entity = o
				if o and o.use_talent and o.use_talent.id then
					local t = a:getTalentFromId(o.use_talent.id)
					display_entity = t and t.display_entity
				end
				if o and o.talent_cooldown then
					local t = a:getTalentFromId(o.talent_cooldown)
					angle = 360
					if t and a:isTalentCoolingDown(t) then
						color = {255,0,0}
						angle = 360 * (1 - (a.talents_cd[t.id] / a:getTalentCooldown(t)))
						frame = "cooldown"
						txt = tostring(math.ceil(a:isTalentCoolingDown(t)))
					end
				elseif o and (o.use_talent or o.use_power) then
					angle = 360 * ((o.power / o.max_power))
					color = {255,0,0}
					local cd = o:getObjectCooldown(a)
					if cd and cd > 0 then
						frame = "cooldown"
						txt = tostring(cd)
					elseif not cd then
						frame = "disabled"
					end
				end
				if o and o.wielded then
					frame = "sustain"
				end
				if o and o.wielded and o.use_talent and o.use_talent.id then
					local t = a:getTalentFromId(o.use_talent.id)
					if not a:preUseTalent(t, true, true, true) then
						angle = 0
						color = {190,190,190}
						frame = "disabled"
					end
				end
			end

			self.font:setStyle("bold")
			local ks = game.key:formatKeyString(game.key:findBoundKeys("HOTKEY_"..page_to_hotkey[page]..bi))
			local key = cachedDraw(self, self.font, ks, self.font:size(ks), colors.ANTIQUE_WHITE.r, colors.ANTIQUE_WHITE.g, colors.ANTIQUE_WHITE.b, true)[1]
			self.font:setStyle("normal")

			local gtxt = nil
			if txt then
				gtxt = cachedDraw(self, self.fontbig, txt, w, colors.WHITE.r, colors.WHITE.g, colors.WHITE.b, true)[1]
				gtxt.fw, gtxt.fh = self.fontbig:size(txt)
			end

			self.items[#self.items+1] = {i=i, x=x, y=y, e=display_entity or self.default_entity, color=color, angle=angle, key=key, gtxt=gtxt, frame=frame, pagesel=lpage==spage}
			self.clics[i] = {x,y,w,h}
		else
			local i = i + (12 * (page - 1))
			local angle = 0
			local color = {190,190,190}
			local frame = "disabled"

			self.font:setStyle("bold")
			local ks = game.key:formatKeyString(game.key:findBoundKeys("HOTKEY_"..page_to_hotkey[page]..bi))
			local key = cachedDraw(self, self.font, ks, self.font:size(ks), colors.ANTIQUE_WHITE.r, colors.ANTIQUE_WHITE.g, colors.ANTIQUE_WHITE.b, true)[1]
			self.font:setStyle("normal")

			self.items[#self.items+1] = {show_on_drag=true, i=i, x=x, y=y, e=nil, color=color, angle=angle, key=key, gtxt=nil, frame=frame}
			self.clics[i] = {x,y,w,h, fake=true}
		end

		if orient == "down" or orient == "up" then
			col = col + 1
			if col >= self.max_cols then
				col = 0
				row = row + 1
				if row >= self.max_rows then return end
			end
		elseif orient == "left" or orient == "right" then
			row = row + 1
			if row >= self.max_rows then
				row = 0
				col = col + 1
				if col >= self.max_cols then return end
			end
		end
	end end
end
    return setfenv(display, environment)
end

function M.install(Display, options)
    if options and options.hotkey_text_cache == false then return false, "disabled in faster_tome settings" end
    if type(Display) ~= "table" then return false, "unknown hotkey display" end
    local original = Display.display
    if installed[original] then return true end
    if not upstream(original, 133, 289, 1) or not upstream(Display.toScreen, 292, 333) then
        return false, "unknown hotkey display override; keeping original"
    end
    if not bindings then return false, "unknown native font/texture bindings; keeping original" end
    local name, pages = debug.getupvalue(original, 1)
    if name ~= "page_to_hotkey" or type(pages) ~= "table" then return false, "unknown hotkey pages" end
    local fast = makeDisplay(getfenv(original), pages)
    local toScreen = Display.toScreen
    local function display(self, ...)
        -- Unknown per-instance or late toScreen overrides can consume/mutate
        -- public text textures. Keep their original fresh-resource behavior.
        if self.toScreen ~= toScreen then M.clear(self); return original(self, ...) end
        return fast(self, ...)
    end
    installed[display] = true
    Display.display = display
    return true
end

return M
