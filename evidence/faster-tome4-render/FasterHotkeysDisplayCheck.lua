-- Local diagnostic only; excluded from the addon release.
-- Run after a completed Game.display, in the real engine's GL context:
--   require("engine.FasterHotkeysDisplayCheck").run(game)
-- This executes the pinned complete HotkeysIconsDisplay display/toScreen with
-- deterministic synthetic actors, real Entity icons, fonts, UI frames and GL.
-- It does not replay Game.display, game turns, player preUseTalent or particles.
local M = {}

local function upvalue(f, wanted)
    for i = 1, 64 do
        local name, value = debug.getupvalue(f, i)
        if not name then return end
        if name == wanted then return value end
    end
end
local function stock(f, first, last)
    if type(f) ~= "function" then return false end
    local info = debug.getinfo(f, "S")
    return info.source == "@/engine/HotkeysIconsDisplay.lua"
        and info.linedefined == first and info.lastlinedefined == last
end
local function findInstalled(f, seen, depth)
    if type(f) ~= "function" or depth > 8 or seen[f] then return end
    seen[f] = true
    local original, fast = upvalue(f, "original"), upvalue(f, "fast")
    if stock(original, 133, 289) and type(fast) == "function" then return f, original end
    -- The local timer wraps the production method in a function upvalue. Walk
    -- only function upvalues, not environments/classes or the live game graph.
    for i = 1, 64 do
        local name, value = debug.getupvalue(f, i)
        if not name then break end
        if type(value) == "function" then
            local wrapped, delegate = findInstalled(value, seen, depth + 1)
            if wrapped then return wrapped, delegate end
        end
    end
end

function M.run(realgame, options)
    local Cache = require "engine.FasterHotkeys"
    local Pixels = require "engine.FasterRenderPixels"
    local Display = require "engine.HotkeysIconsDisplay"
    local Entity = require "engine.Entity"
    local Shader = require "engine.Shader"
    local ffi = require "ffi"
    ffi.cdef[[
        void glReadPixels(int, int, int, int, unsigned int, unsigned int, void *);
        void glReadBuffer(unsigned int);
        void glEnable(unsigned int);
        void glDisable(unsigned int);
        void glScissor(int, int, int, int);
    ]]
    local gl = ffi.load("libGL.so.1")
    local installed, original = findInstalled(Display.display, {}, 0)
    assert(installed and original, "Hotkey cache must be installed (hotkey_text_cache=true)")
    assert(stock(Display.toScreen, 292, 333), "full UI diagnostic requires the pinned toScreen")
    local environment = getfenv(original)
    assert(getfenv(Display.toScreen) == environment, "unexpected hotkey module environments")
    local savedGame = rawget(environment, "game")
    local savedOutline = Shader.default.textoutline
    local savedGL = Pixels.state()
    local function stackDepths()
        local v = ffi.new("int[3]")
        gl.glGetIntegerv(0x0BA3, v) -- GL_MODELVIEW_STACK_DEPTH
        gl.glGetIntegerv(0x0BA4, v+1) -- GL_PROJECTION_STACK_DEPTH
        gl.glGetIntegerv(0x0BB0, v+2) -- GL_ATTRIB_STACK_DEPTH
        return {modelview = tonumber(v[0]), projection = tonumber(v[1]), attrib = tonumber(v[2])}
    end
    local savedStacks = stackDepths()
    assert(savedGL.framebuffer[1] == 0 and savedGL.program[1] == 0,
        "run full UI diagnostic after Game.display with the window framebuffer and no shader")
    assert(savedGL.active_texture[1] == 0x84C0 and savedGL.matrix_mode[1] == 0x1700,
        "full UI diagnostic expects texture unit zero and modelview mode")
    local packRow = ffi.new("int[1]")
    gl.glGetIntegerv(0x0D02, packRow) -- GL_PACK_ROW_LENGTH
    assert(packRow[0] == 0, "unexpected pixel pack row length")

    local cfg = options or (config.settings.faster_tome or {})
    local frames = cfg.hotkeys_display_frames or 120
    assert(type(frames) == "number" and frames >= 120 and frames <= 360 and frames == math.floor(frames),
        "hotkeys_display_frames must be an integer from 120 through 360")
    local target, activeTarget, pushed, scaledPush, activeWorld, gcStopped
    local worlds, width, height = {}, 640, 384
    local totals = {frames = 0, rgba_bytes_compared = 0, changed_frames = 0, unchanged_frames = 0,
        shader_shadow_frames = 0, plain_shadow_frames = 0, no_shadow_frames = 0,
        following_draw_probes = 0, business_calls = 0}
    local rgba = ffi.new("unsigned char[?]", width * height * 4)
    local stageFramebuffer = ffi.new("int[5]")
    local stageError = ffi.new("unsigned int[4]")
    local corner = ffi.new("unsigned char[16]")

    local function record(w, ...)
        local values = {}
        for i = 1, select("#", ...) do values[i] = tostring(select(i, ...)) end
        w.events[#w.events + 1] = table.concat(values, "|")
    end
    local function actor(w)
        local a = {hotkey_page = 1, changed = true, hotkey = {}, talents_cd = {}, talents = {},
            active = {}, unavailable = {}, inventory = {}, uses = 0}
        function a:getTalentFromId(id) record(w, "talent", id); return self.talents[id] end
        function a:isTalentCoolingDown(t) record(w, "cooling", t.id); return self.talents_cd[t.id] end
        function a:isTalentActive(id) record(w, "active", id); return self.active[id] end
        function a:getTalentCooldown(t) record(w, "cooldown", t.id); return t.cooldown end
        function a:preUseTalent(t, ...)
            record(w, "preUse", t.id, ...); self.uses = self.uses + 1
            return not self.unavailable[t.id]
        end
        function a:findInAllInventories(id, flags)
            record(w, "inventory", id, flags.no_add_name, flags.force_id, flags.no_count)
            return self.inventory[id]
        end
        return a
    end
    local function world(optimized)
        local w = {events = {}, entities = {}, frame = 0, optimized = optimized}
        local function icon(id, image)
            local e = Entity.new{name = "hotkeys diagnostic " .. id, image = image,
                display = "?", color = colors.WHITE}
            w.entities[e] = id
            local toScreen = e.toScreen
            e.toScreen = function(self, ...)
                record(w, "entity", id)
                return toScreen(self, ...)
            end
            return e
        end
        w.icons = {}
        for i = 1, 8 do
            w.icons[i] = icon("talent-" .. i, i % 2 == 0 and "talents/aegis.png" or "talents/anatomy.png")
        end
        w.potion = icon("potion", "talents/agony.png")
        w.wand = icon("wand", "talents/aegis.png")
        w.replacement = icon("replacement", "talents/anatomy.png")
        for _, o in ipairs{w.potion, w.wand, w.replacement} do
            local id = w.entities[o]
            o.getNumber = function(self) record(w, "number", id); return self.count end
            o.getObjectCooldown = function(self, a)
                assert(a == w.actor, "inventory callback received another actor")
                record(w, "object-cooldown", id); return self.cd
            end
        end
        w.actor = actor(w)
        w.h = Display.new(w.actor, 16, 16, 240, 80, {12, 18, 24},
            "/data/font/DroidSansMono.ttf", 10, 32, 32)
        w.h.font = core.display.newFont("/data/font/DroidSansMono.ttf", 10, true)
        w.h.fontbig = core.display.newFont("/data/font/DroidSansMono.ttf", 20, true)
        w.h.default_entity = icon("default", "talents/agony.png")
        w.h.display = optimized and installed or original
        local background = core.display.newSurface(4, 4)
        background:erase(24, 40, 56, 190)
        w.h.bg_texture, w.h.bg_texture_w, w.h.bg_texture_h = background:glTexture()
        w.h.bg_surface = background
        Cache.clear(w.h)
        return w
    end
    local proxyKey = {}
    function proxyKey:findBoundKeys(name) record(activeWorld, "bound", name); return name end
    function proxyKey:formatKeyString(name)
        local w = activeWorld
        record(w, "format", name)
        local slot = tonumber(name:match("(%d+)$")) or 1
        if w.frame % 17 == 0 then w.h.font:setStyle("underline") end
        if w.frame % 13 == 0 and slot == 3 then return "#RED#F3#LAST#" end
        if w.frame % 7 == 0 then return "控制+" .. slot end
        return (w.frame % 5 == 0 and "Shift+" or "Ctrl+") .. slot
    end
    local proxyGame = setmetatable({key = proxyKey, mouse = {}}, {__index = realgame})

    local function prepare(w, frame)
        w.frame, w.events = frame, {}
        if frame == 61 then w.actor = actor(w); w.h.actor = w.actor end
        local a, h = w.actor, w.h
        local stage = math.floor((frame - 1) / 40) % 3
        local iconSize, columns = 32 + stage * 8, ({6, 4, 8})[stage + 1]
        if h.icon_w ~= iconSize or h.max_cols ~= columns then
            h:resize(16, 16, columns * (iconSize + 8), 2 * (iconSize + 8), iconSize, iconSize)
        end
        if frame == 41 or frame == 81 then
            h.font = core.display.newFont("/data/font/DroidSansMono.ttf", 10 + stage * 2, true)
            h.fontbig = core.display.newFont("/data/font/DroidSansMono.ttf", 20 + stage * 2, true)
        end
        h.fontbig:setStyle(({"normal", "bold", "italic", "underline"})[frame % 4 + 1])
        h.orient = ({"down", "left", "up", "right"})[math.floor((frame - 1) / 30) % 4 + 1]
        h.shadow = 128
        if frame % 3 == 0 then h.shadow = nil end
        a.hotkey_page = math.floor((frame - 1) / 15) % 7 + 1
        a.hotkey, a.talents_cd, a.active, a.unavailable = {}, {}, {}, {}
        for i = 1, 8 do a.talents[i] = {id = i, cooldown = 30, display_entity = w.icons[i]} end
        for page = 1, 7 do
            for slot = 1, 8 do a.hotkey[(page - 1) * 12 + slot] = {"talent", slot} end
            a.hotkey[(page - 1) * 12 + 9] = {"inventory", "potion"}
            a.hotkey[(page - 1) * 12 + 10] = {"inventory", "wand"}
            a.hotkey[(page - 1) * 12 + 11] = {"inventory", "missing"}
        end
        a.talents_cd[1] = math.ceil((frames + 1 - frame) / 4)
        a.talents_cd[2] = frame % 11 == 0 and 0 or frame % 11 + 0.25
        a.talents_cd[3] = frame % 2 == 0 and 3 or nil
        a.unavailable[2], a.unavailable[4], a.active[5] = true, frame % 2 == 0, true
        w.potion.count, w.potion.use_power, w.potion.power, w.potion.max_power = frame % 6 == 0 and 0 or 2, true, frame % 20, 20
        w.potion.cd = frame % 12
        if frame % 8 == 0 then w.potion.cd = false end
        w.replacement.count, w.replacement.use_power = 1, true
        w.replacement.power, w.replacement.max_power, w.replacement.cd = 10, 20, 123.25
        a.inventory.potion = frame % 9 == 0 and w.replacement or w.potion
        w.wand.count, w.wand.use_talent, w.wand.talent_cooldown = 1, {id = 2}, 1
        w.wand.wielded = frame % 2 == 0
        a.inventory.wand = w.wand
        if frame % 14 == 0 then a.inventory.wand = nil end
        h.cur_sel = (a.hotkey_page - 1) * 12 + frame % 12 + 1
        a.changed = frame % 10 ~= 0
        w.scale = ({1, 0.85, 1.15})[stage + 1]
    end
    local function shape(w, value, field)
        if field == "e" then return w.entities[value] or (value and "unknown-entity" or nil) end
        if field == "_tex" then return Pixels.texture(value) end
        if type(value) ~= "table" then return value end
        local out = {}
        for k, v in pairs(value) do out[k] = shape(w, v, k) end
        return out
    end
    local function rgbaDifference(a, b)
        local changed, first = 0
        for i = 1, #a do
            if a:byte(i) ~= b:byte(i) then changed = changed + 1; first = first or i end
        end
        return " changed_bytes=" .. changed .. " first_byte=" .. tostring(first)
    end
    local function samples(pixels)
        local points = {}
        for _, xy in ipairs{{0,0},{width-1,0},{0,height-1},{width-1,height-1},{32,height-32},{600,30}} do
            local offset = (xy[2] * width + xy[1]) * 4
            points[#points + 1] = {x = xy[1], y = xy[2], rgba = {pixels:byte(offset+1, offset+4)}}
        end
        return points
    end
    local function writeMismatch(frame, a, b)
        local stateOK, stateKey = Pixels.equal(a.state, b.state)
        local report = {frame = frame, width = width, height = height, rgba_bottom_up = true,
            state_equal = stateOK, state_key = stateKey, business_equal = a.events == b.events,
            before = a.diagnostic, after = b.diagnostic,
            before_samples = samples(a.rgba), after_samples = samples(b.rgba)}
        print("[HotkeysDisplayMismatch] " .. json.encode(report))
        local prefix = cfg.hotkeys_display_output_prefix or "/tmp/faster-hotkeys-display-check"
        assert(type(prefix) == "string" and prefix:sub(1, 1) == "/", "diagnostic output prefix must be absolute")
        local ok, error = pcall(function()
            for _, item in ipairs{{"before.rgba", a.rgba}, {"after.rgba", b.rgba}, {"state.json", json.encode(report)}} do
                local path = prefix .. "-frame" .. frame .. "-" .. item[1]
                local file = assert(io.open(path, "wb")); assert(file:write(item[2])); assert(file:close())
                print("[HotkeysDisplayMismatch] wrote " .. path)
            end
        end)
        if not ok then print("[HotkeysDisplayMismatch] artifact write failed: " .. tostring(error)) end
    end
    local probe
    local function capture(w)
        activeWorld = w
        proxyGame.mouse.drag = w.frame % 4 == 0
        Shader.default.textoutline = savedOutline
        if w.frame % 3 == 1 then Shader.default.textoutline = nil end
        local entryGL = Pixels.state()
        local entryStacks = stackDepths()
        gl.glGetIntegerv(0x8CA6, stageFramebuffer)
        target:use(true, 0.0625, 0.09375, 0.125, 0)
        activeTarget = true
        gl.glGetIntegerv(0x8CA6, stageFramebuffer+1)
        gl.glReadBuffer(0x8CE0)
        gl.glReadPixels(0, 0, 1, 1, 0x1908, 0x1401, corner)
        gl.glReadPixels(width-1, 0, 1, 1, 0x1908, 0x1401, corner+4)
        gl.glReadPixels(0, height-1, 1, 1, 0x1908, 0x1401, corner+8)
        gl.glReadPixels(width-1, height-1, 1, 1, 0x1908, 0x1401, corner+12)
        local clearCorners = ffi.string(corner, 16)
        local clearGL = Pixels.state()
        local clearStacks = stackDepths()
        stageError[0] = gl.glGetError()
        -- This engine's glScale(number,...) already pushes a matrix; its
        -- no-argument call pops it. Do not add a second glPush around it.
        core.display.glScale(w.scale, w.scale, 1)
        scaledPush = true
        local function pack(...) return {n = select("#", ...), ...} end
        local result = pack(w.h:toScreen())
        gl.glGetIntegerv(0x8CA6, stageFramebuffer+2)
        local uiGL, uiBound = Pixels.state(), Pixels.boundTexture()
        local uiStacks = stackDepths()
        stageError[1] = gl.glGetError()
        core.display.glScale(); scaledPush = false
        -- A following textured/alpha draw catches leaked shader, blend or
        -- texture state which a UI-only image might not reveal.
        core.display.drawQuad(565, 325, 50, 45, 210, 60, 90, 150)
        probe:toScreenFull(585, 345, 35, 25, 8, 8, 0.8, 0.6, 1, 0.7)
        gl.glGetIntegerv(0x8CA6, stageFramebuffer+3)
        gl.glReadBuffer(0x8CE0) -- GL_COLOR_ATTACHMENT0, private diagnostic FBO.
        stageError[2] = gl.glGetError()
        gl.glReadPixels(0, 0, width, height, 0x1908, 0x1401, rgba)
        stageError[3] = gl.glGetError()
        gl.glGetIntegerv(0x8CA6, stageFramebuffer+4)
        local pixels = ffi.string(rgba, width * height * 4)
        local followingGL = Pixels.state()
        target:use(false)
        activeTarget = false
        local exitStacks = stackDepths()
        assert(Pixels.equal(entryStacks, exitStacks), "capture leaked a GL stack at frame " .. w.frame)
        local state = shape(w, {items = w.h.items, clics = w.h.clics, dragclics = w.h.dragclics,
            font_style = w.h.font:getStyle(), fontbig_style = w.h.fontbig:getStyle(), uses = w.actor.uses,
            changed = w.actor.changed, page = w.actor.hotkey_page, result = result})
        local framebuffers, errors = {}, {}
        for i = 0, 4 do framebuffers[#framebuffers+1] = tonumber(stageFramebuffer[i]) end
        for i = 0, 3 do errors[#errors+1] = tonumber(stageError[i]) end
        return {rgba = pixels, gl = uiGL, bound = uiBound, following_gl = followingGL, state = state,
            diagnostic = {entry_gl = entryGL, clear_gl = clearGL, ui_gl = uiGL, following_gl = followingGL,
                entry_stacks = entryStacks, clear_stacks = clearStacks, ui_stacks = uiStacks, exit_stacks = exitStacks,
                framebuffers_entry_clear_ui_read_readback = framebuffers,
                errors_clear_ui_readbuffer_readback = errors, clear_corner_rgba = {clearCorners:byte(1,16)}},
            events = table.concat(w.events, "\n"), calls = #w.events}
    end

    local ok, err = xpcall(function()
        -- Override only this module's environment with rawset, bypassing its
        -- engine.class proxy writer. The live game, keybinds and mouse stay put.
        rawset(environment, "game", proxyGame)
        worlds[1], worlds[2] = world(false), world(true)
        target = assert(core.display.newFBO(width, height), "full UI check requires native FBO support")
        local surface = core.display.newSurface(8, 8)
        surface:erase(40, 170, 210, 190)
        probe = surface:glTexture()
        core.display.glPush(); pushed = true
        core.display.glScissor(false)
        gl.glEnable(0x0BE2) -- GL_BLEND; restore original enable state afterwards.
        local beforeStats = Cache.stats(worlds[2].h)
        for frame = 1, frames do
            prepare(worlds[1], frame); prepare(worlds[2], frame)
            -- The pinned native FBO __gc binds its dying FBO, then binds zero
            -- without restoring an active target. Diagnostic allocations made
            -- that unrelated finalizer fire mid-capture (observed target 25 ->
            -- 0, GL_INVALID_OPERATION on read-buffer selection). Finalize at
            -- framebuffer zero, then isolate only this pair from Lua GC. This
            -- is a pixel-test barrier, never a production GC policy or timer.
            assert(Pixels.state().framebuffer[1] == 0, "GC barrier requires framebuffer zero")
            collectgarbage("collect")
            collectgarbage("stop"); gcStopped = true
            local a, b
            -- Alternate order across frames while each side retains its own
            -- previous items/cooldowns/actor state and bounded native cache.
            if frame % 2 == 0 then b = capture(worlds[2]); a = capture(worlds[1])
            else a = capture(worlds[1]); b = capture(worlds[2]) end
            if a.rgba ~= b.rgba then
                writeMismatch(frame, a, b)
                error("full hotkey UI RGBA differs at frame " .. frame .. rgbaDifference(a.rgba, b.rgba))
            end
            for _, capture in ipairs{a,b} do
                local fb = capture.diagnostic.framebuffers_entry_clear_ui_read_readback
                assert(fb[2] ~= 0 and fb[2] == fb[3] and fb[2] == fb[4] and fb[2] == fb[5],
                    "private FBO changed during isolated pixel capture at frame " .. frame)
                for _, code in ipairs(capture.diagnostic.errors_clear_ui_readbuffer_readback) do
                    assert(code == 0, "OpenGL capture error at frame " .. frame .. " code=" .. code)
                end
            end
            local stateOK, stateKey = Pixels.equal(a.state, b.state)
            assert(stateOK, "full hotkey UI state differs at frame " .. frame .. " key=" .. tostring(stateKey))
            assert(a.events == b.events, "hotkey business/draw call sequence differs at frame " .. frame)
            assert(Pixels.equal(a.gl, b.gl), "post-hotkey GL state differs at frame " .. frame)
            assert(Pixels.equal(a.bound, b.bound), "post-hotkey texture binding pixels differ at frame " .. frame)
            assert(Pixels.equal(a.following_gl, b.following_gl), "following draw GL state differs at frame " .. frame)
            Pixels.checkGL()
            totals.frames, totals.rgba_bytes_compared = frame, totals.rgba_bytes_compared + #a.rgba
            totals.business_calls, totals.following_draw_probes = totals.business_calls + a.calls, frame
            if worlds[1].actor.changed then totals.changed_frames = totals.changed_frames + 1
            else totals.unchanged_frames = totals.unchanged_frames + 1 end
            if frame % 3 == 0 then totals.no_shadow_frames = totals.no_shadow_frames + 1
            elseif frame % 3 == 1 or not savedOutline then totals.plain_shadow_frames = totals.plain_shadow_frames + 1
            else totals.shader_shadow_frames = totals.shader_shadow_frames + 1 end
            -- Both FBO.use(false) calls have completed; discard bulky RGBA and
            -- glyph readback strings and finalize only outside active targets.
            a, b = nil, nil
            assert(Pixels.state().framebuffer[1] == 0, "post-pair GC requires framebuffer zero")
            collectgarbage("restart"); gcStopped = false
            collectgarbage("collect")
        end
        local stats = Cache.stats(worlds[2].h)
        assert(stats.hits > beforeStats.hits, "full UI sequence did not exercise cache hits")
        assert(stats.entries <= stats.max_entries and Cache.stats().bytes <= stats.max_bytes, "cache exceeded global resource budget")
        totals.full_ui_rgba_equal, totals.items_and_clicks_equal = true, true
        totals.business_call_sequence_equal, totals.gl_state_equal = true, true
        totals.following_draw_rgba_equal, totals.cache = true, stats
        totals.native_outline_shader_available = savedOutline and savedOutline.shad and true or false
        totals.synthetic_actors, totals.real_native_ui = true, true
        totals.game_turns_replayed, totals.runtime = 0, jit.version
        totals.gc_pair_barriers = frames
        totals.gc_policy = "full GC at framebuffer zero before/after each pair; stopped only inside pixel comparison"
    end, debug.traceback)

    -- Keep the native GL caches coherent: restore clear color through FBO.use,
    -- and color through the engine method, instead of raw glClearColor/glColor.
    rawset(environment, "game", savedGame)
    Shader.default.textoutline = savedOutline
    if savedOutline and savedOutline.shad then savedOutline.shad:use(false) end
    if scaledPush then core.display.glScale(); scaledPush = false end
    if activeTarget then target:use(false); activeTarget = false end
    if target and pushed then
        target:use(true, unpack(savedGL.clear_color)); target:use(false)
    end
    if pushed then core.display.glPop() end
    local c = savedGL.current_color
    core.display.glColor(c[1] == 0 and 1 or 0, c[2], c[3], c[4])
    core.display.glColor(unpack(c))
    gl.glScissor(unpack(savedGL.scissor))
    if savedGL.scissor_enabled[1] ~= 0 then gl.glEnable(0x0C11) else gl.glDisable(0x0C11) end
    if savedGL.blend[1] ~= 0 then gl.glEnable(0x0BE2) else gl.glDisable(0x0BE2) end
    for _, w in ipairs(worlds) do Cache.clear(w.h) end
    activeWorld, probe, target, worlds = nil, nil, nil, nil
    collectgarbage("restart"); gcStopped = false
    -- Retire the private FBO before returning to normal game display, where its
    -- unmodified native finalizer could otherwise unbind a real scene target.
    collectgarbage("collect")
    if not ok then error(err, 0) end
    assert(Pixels.equal(Pixels.state(), savedGL), "full UI diagnostic failed to restore non-texture GL state")
    assert(Pixels.equal(stackDepths(), savedStacks), "full UI diagnostic leaked a GL stack")
    Pixels.checkGL()
    totals.gl_state_restored, totals.gc_reenabled, totals.gl_stack_depths_restored = true, true, true
    print("[HotkeysDisplayPixels] PASS " .. json.encode(totals))
    return totals
end

return M
