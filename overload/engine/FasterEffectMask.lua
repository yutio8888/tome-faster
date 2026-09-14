-- ToME / T-Engine4, GPL-3.0-or-later; see COPYING. No warranty.
-- 2026-09-13. Fixed engine: 624a67329fe2ad440c5b344785a9c73fcf22ae63.
-- Cache ordered mask geometry, not pixels: the public Map.fbo is rebuilt on
-- every frame, and the original dynamic shader/animation path stays intact.
local M = {}
local FBOGuard = require "engine.FBOGCGuard"
local MAX_ENTRIES, MAX_BYTES, MAX_GRIDS = 32, 4 * 1024 * 1024, 4096
local entries, bytes = {}, 0
local counters = {hits = 0, misses = 0, skips = 0, draws = 0, saved_draws = 0}
local overlay_fields = {"display", "color_r", "color_g", "color_b", "color_br", "color_bg", "color_bb", "image", "alpha", "zdepth"}
local metadata = setmetatable({}, {__mode = "k"})
local function info(f)
    if type(f) ~= "function" then return nil end
    local value = metadata[f]
    if not value then value = debug.getinfo(f, "S"); metadata[f] = value end
    return value
end
local function upstream(f, source, first, last)
    local i = info(f)
    return i and i.source == source and i.linedefined == first and i.lastlinedefined == last
end
local function native(f) local i = info(f); return i and i.what == "C" end
local originalNewVO = core and core.display and core.display.newVO
local native_methods = {}
for class, names in pairs({["gl{texture}"] = {"toScreen"}, ["gl{vertexes}"] = {"addPoint", "toScreen"}, ["gl{fbo}"] = {"use", "toScreen"}}) do
    local mt = debug.getregistry()[class]
    local index = type(mt) == "table" and rawget(mt, "__index")
    local methods = {metatable = mt}
    if type(index) == "table" then
        for _, name in ipairs(names) do
            local method = rawget(index, name)
            if native(method) then methods[name] = method
            elseif class == "gl{fbo}" and name == "use" then
                methods[name] = FBOGuard.originalUse(mt, method)
            end
        end
    end
    native_methods[class] = methods
end
local function nativeObject(object, class, method)
    if type(object) ~= "userdata" then return false end
    local mt = getmetatable(object)
    local index = type(mt) == "table" and rawget(mt, "__index")
    local expected = native_methods[class]
    if mt ~= expected.metatable or type(index) ~= "table" or rawget(index, "class") ~= class
        or expected[method] == nil then return false end
    local current = rawget(index, method)
    return current == expected[method] or
        (class == "gl{fbo}" and method == "use" and FBOGuard.originalUse(mt, current) == expected[method])
end
local function finite(n) return type(n) == "number" and n == n and n > -1000000 and n < 1000000 end
local function plain(t) return type(t) == "table" and getmetatable(t) == nil end
local function overlayTable(t)
    if plain(t) then return true end
    if type(t) ~= "table" then return false end
    local class = package.loaded["engine.MapEffect"]
    if type(class) ~= "table" or not upstream(rawget(class, "init"), "@/engine/MapEffect.lua", 30, 34) then return false end
    local mt = getmetatable(t)
    if type(mt) ~= "table" or rawget(mt, "__index") ~= class then return false end
    -- class.new uses {__index=class}. Follow only ordinary table inheritance;
    -- custom __index callbacks or any other instance/class metamethod bypass.
    for depth = 1, 8 do
        for key in pairs(mt) do if key ~= "__index" then return false end end
        local index = rawget(mt, "__index")
        if index == nil then return true end
        if type(index) ~= "table" then return false end
        mt = getmetatable(index)
        if mt == nil then return true end
        if type(mt) ~= "table" then return false end
    end
    return false
end
local function trunc(n) return n < 0 and math.ceil(n) or math.floor(n) end
local function evict(i)
    bytes = bytes - entries[i].bytes
    table.remove(entries, i)
end
function M.clear(map)
    for i = #entries, 1, -1 do
        if map == nil or entries[i].owners[1] == map then evict(i) end
    end
end
function M.stats()
    local out = {entries = #entries, native_bytes = bytes, max_entries = MAX_ENTRIES, max_native_bytes = MAX_BYTES, max_grids = MAX_GRIDS, extra_fbos = 0}
    for k, v in pairs(counters) do out[k] = v end
    return out
end
function M.resetStats() for k in pairs(counters) do counters[k] = 0 end end

-- Prepare BEFORE binding the public mask FBO: creating a VO/Lua metadata may
-- trigger GC, and fixed-engine gl_free_fbo binds FBO 0 without restoring it.
-- No scene draws happen between preparation and the original fbo:use(true).
function M.prepare(map, effect, texture)
    if not plain(effect) then counters.skips = counters.skips + 1; return false end
    local tiles, overlay, grids = map.tilesEffects, effect.overlay, effect.seen_grids
    if not tiles or not upstream(tiles.get, "@/engine/Tiles.lua", 103, 175)
        or not nativeObject(texture, "gl{texture}", "toScreen")
        or not core or not core.display or core.display.newVO ~= originalNewVO or not native(originalNewVO)
        or not overlayTable(overlay) or not plain(grids) or not plain(map.viewport)
        or not finite(map.mx) or not finite(map.my) or not finite(map.tile_w) or not finite(map.tile_h) or not finite(map.zoom)
        or not finite(map.viewport.width) or not finite(map.viewport.height)
        or not finite(map.tile_w * map.zoom) or not finite(map.tile_h * map.zoom) then
        counters.skips = counters.skips + 1; return false
    end
    for i = 1, #overlay_fields do
        local value = overlay[overlay_fields[i]]
        local kind = type(value)
        if kind ~= "nil" and kind ~= "number" and kind ~= "string" and kind ~= "boolean" then
            counters.skips = counters.skips + 1; return false
        end
    end
    local entry
    for i = #entries, 1, -1 do
        local candidate = entries[i]
        if not candidate.owners[1] or not candidate.owners[2] then evict(i)
        elseif candidate.owners[1] == map and candidate.owners[2] == effect then entry = candidate end
    end
    if entry and not nativeObject(entry.vo, "gl{vertexes}", "toScreen") then counters.skips = counters.skips + 1; return false end
    local same = entry and entry.texture == texture and entry.owners[3] == map.fbo
        and entry.mx == map.mx and entry.my == map.my and entry.tw == map.tile_w and entry.th == map.tile_h
        and entry.zoom == map.zoom and entry.vw == map.viewport.width and entry.vh == map.viewport.height
        and entry.owners[4] == tiles.repo
    if same then
        for i = 1, #overlay_fields do
            if entry.overlay[i] ~= overlay[overlay_fields[i]] then same = false; break end
        end
    end
    -- Compare the actual ordered traversal, including false/zero valued grids:
    -- upstream draws every key, regardless of its visibility value.
    local count = 0
    for lx, ys in pairs(grids) do
        if not finite(lx) or not plain(ys) then counters.skips = counters.skips + 1; return false end
        for ly in pairs(ys) do
            count = count + 1
            if not finite(ly) or count > MAX_GRIDS
                or not finite((lx - map.mx) * map.tile_w * map.zoom)
                or not finite((ly - map.my) * map.tile_h * map.zoom) then
                counters.skips = counters.skips + 1; return false
            end
            if same and (entry.coords[2 * count - 1] ~= lx or entry.coords[2 * count] ~= ly) then same = false end
        end
    end
    if count < 2 then counters.skips = counters.skips + 1; return false end
    same = same and #entry.coords == 2 * count
    if same then counters.hits = counters.hits + 1
    else
        counters.misses = counters.misses + 1
        local ok, vo = pcall(core.display.newVO, count * 4)
        if not ok or not nativeObject(vo, "gl{vertexes}", "addPoint") or not nativeObject(vo, "gl{vertexes}", "toScreen") then
            counters.skips = counters.skips + 1; return false
        end
        local coords, values = {}, {}
        -- C sdl_texture_toscreen converts x/y/w/h separately to int before
        -- adding them. In particular floor() is wrong for negative scroll.
        local w, h = trunc(map.tile_w * map.zoom), trunc(map.tile_h * map.zoom)
        for lx, ys in pairs(grids) do
            for ly in pairs(ys) do
                coords[#coords + 1], coords[#coords + 2] = lx, ly
                local x, y = trunc((lx - map.mx) * map.tile_w * map.zoom), trunc((ly - map.my) * map.tile_h * map.zoom)
                vo:addPoint(x, y, 0, 0, 1, 1, 1, 1)
                vo:addPoint(x, y + h, 0, 1, 1, 1, 1, 1)
                vo:addPoint(x + w, y + h, 1, 1, 1, 1, 1, 1)
                vo:addPoint(x + w, y, 1, 0, 1, 1, 1, 1)
            end
        end
        for i = 1, #overlay_fields do values[i] = overlay[overlay_fields[i]] end
        -- Eight floats per vertex, plus a conservative 64-byte struct budget
        -- (the fixed 64-bit lua_vertexes is 32 bytes). Lua keys are also bounded
        -- by the same grid/entry limits; allocator/driver overhead is separate.
        local size = count * 4 * 8 * 4 + 64
        if entry then
            for i = #entries, 1, -1 do if entries[i] == entry then evict(i); break end end
        end
        while #entries >= MAX_ENTRIES or bytes + size > MAX_BYTES do evict(1) end
        entry = {owners = setmetatable({map, effect, map.fbo, tiles.repo}, {__mode = "v"}), vo = vo, texture = texture,
            coords = coords, overlay = values, bytes = size,
            mx = map.mx, my = map.my, tw = map.tile_w, th = map.tile_h, zoom = map.zoom,
            vw = map.viewport.width, vh = map.viewport.height}
        entries[#entries + 1], bytes = entry, bytes + size
    end
    return entry
end
local function drawEntry(entry, texture)
    -- This bound-FBO path constructs no Lua tables and performs no pcall or
    -- metadata introspection. Only immutable native method identity checks,
    -- the original vertex binding/draw, and existing numeric counters remain.
    if not nativeObject(texture, "gl{texture}", "toScreen") or not nativeObject(entry.vo, "gl{vertexes}", "toScreen") then return false end
    native_methods["gl{vertexes}"].toScreen(entry.vo, 0, 0, texture)
    counters.draws = counters.draws + 1
    counters.saved_draws = counters.saved_draws + #entry.coords / 2 - 1
    return true
end
-- Direct test/embedding convenience. Production uses prepare before binding;
-- callers of draw must likewise account for native finalizers during prepare.
function M.draw(map, effect, texture)
    local entry = M.prepare(map, effect, texture)
    if not entry then return false end
    return drawEntry(entry, texture)
end

local installed = setmetatable({}, {__mode = "k"})
function M.install(Map, options)
    if options and options.effect_mask_batch == false then return false end
    if installed[Map.displayEffects] then return true end
    local delegate = Map.displayEffects
    if not upstream(delegate, "@/engine/Map.lua", 1197, 1254) then return false end
    local Tiles
    for i = 1, 20 do
        local name, value = debug.getupvalue(delegate, i)
        if not name then break end
        if name == "Tiles" then Tiles = value end
    end
    if not Tiles or not upstream(Tiles.get, "@/engine/Tiles.lua", 103, 175) then return false end
    local function displayEffects(self, z, prevfbo, nb_keyframes)
        if options and options.effect_mask_batch == false then return delegate(self, z, prevfbo, nb_keyframes) end
        local sx, sy = self._map:getScroll()
        for e, _ in pairs(self.z_effects[z]) do
            if e.seen and e.overlay and e.overlay.zdepth == z and e.x + e.radius >= self.mx and e.x - e.radius < self.mx + self.viewport.mwidth and e.y + e.radius >= self.my and e.y - e.radius < self.my + self.viewport.mheight then
                local s = self.tilesEffects:get(e.overlay.display, e.overlay.color_r, e.overlay.color_g, e.overlay.color_b, e.overlay.color_br, e.overlay.color_bg, e.overlay.color_bb, e.overlay.image, e.overlay.alpha)
                if not self.fbo or not e.overlay.effect_shader then
                    for lx, ys in pairs(e.seen_grids) do
                        for ly, _ in pairs(ys) do
                            s:toScreen(self.display_x + sx + (lx - self.mx) * self.tile_w * self.zoom, self.display_y + sy + (ly - self.my) * self.tile_h * self.zoom, self.tile_w * self.zoom, self.tile_h * self.zoom)
                        end
                    end
                else
                    if not e.overlay.effect_shader_tex then
                        e.overlay.effect_shader_tex = {}
                        if type(e.overlay.effect_shader) == "table" then
                            for i = 1, #e.overlay.effect_shader do e.overlay.effect_shader_tex[i] = Tiles:loadImage(e.overlay.effect_shader[i]):glTexture() end
                            e.overlay.effect_shader_tex.cur = 1
                            e.overlay.effect_shader_tex.cnt = 0
                            e.overlay.effect_shader_tex.max = e.overlay.effect_shader.max
                        else
                            e.overlay.effect_shader_tex[1] = Tiles:loadImage(e.overlay.effect_shader):glTexture()
                            e.overlay.effect_shader_tex.cur = 1
                            e.overlay.effect_shader_tex.cnt = 0
                            e.overlay.effect_shader_tex.max = 1
                        end
                    end
                    local entry
                    if nativeObject(self.fbo, "gl{fbo}", "use") and nativeObject(self.fbo, "gl{fbo}", "toScreen") then
                        entry = M.prepare(self, e, s)
                    end
                    self.fbo:use(true, 0, 0, 0, 0)
                    if not entry or not drawEntry(entry, s) then
                        for lx, ys in pairs(e.seen_grids) do
                            for ly, _ in pairs(ys) do
                                s:toScreen((lx - self.mx) * self.tile_w * self.zoom, (ly - self.my) * self.tile_h * self.zoom, self.tile_w * self.zoom, self.tile_h * self.zoom)
                            end
                        end
                    end
                    self.fbo:use(false, prevfbo)
                    e.overlay.effect_shader_tex[e.overlay.effect_shader_tex.cur]:bind(1, false)
                    self.fbo_shader.shad:use(true)
                    self.fbo_shader.shad:uniTileSize(self.tile_w, self.tile_h)
                    self.fbo_shader.shad:uniScrollOffset(0, 0)
                    self.fbo:toScreen(self.display_x + sx, self.display_y + sy, self.viewport.width, self.viewport.height, self.fbo_shader.shad, 1, 1, 1, 1, true)
                    self.fbo_shader.shad:use(false)
                    e.overlay.effect_shader_tex.cnt = e.overlay.effect_shader_tex.cnt + nb_keyframes
                    if e.overlay.effect_shader_tex.cnt >= e.overlay.effect_shader_tex.max then
                        e.overlay.effect_shader_tex.cnt = e.overlay.effect_shader_tex.cnt - e.overlay.effect_shader_tex.max
                        e.overlay.effect_shader_tex.cur = util.boundWrap(e.overlay.effect_shader_tex.cur + 1, 1, #e.overlay.effect_shader_tex)
                    end
                end
            end
        end
    end
    setfenv(displayEffects, getfenv(delegate))
    Map.displayEffects = displayEffects
    installed[displayEffects] = true
    return true
end
return M
