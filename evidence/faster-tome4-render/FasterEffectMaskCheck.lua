-- Local fixed-engine diagnostic, run only in a disposable save session after
-- Game.display has returned. No movement, processEffects, particle update or
-- second Game.display. All pairs share the real C cur_frame_tick of this call.
-- GL state uses documented APIs; exported tgl cache variables are saved/restored
-- alongside it. No userdata addresses/layouts are inspected or dereferenced.
local M = {}
function M.run(realgame)
    local Cache = require "engine.FasterEffectMask"
    local Pixels = require "engine.FasterRenderPixels"
    local Map, MapEffect, Tiles, Shader = require "engine.Map", require "engine.MapEffect", require "engine.Tiles", require "engine.Shader"
    local ffi = require "ffi"
    ffi.cdef[[
        void glReadPixels(int, int, int, int, unsigned int, unsigned int, void *);
        void glBindFramebufferEXT(unsigned int, unsigned int);
        void glPushAttrib(unsigned int); void glPopAttrib(void);
        void glPushClientAttrib(unsigned int); void glPopClientAttrib(void);
        void glMatrixMode(unsigned int); void glPopMatrix(void); void glLoadMatrixf(const float *);
        void glUseProgram(unsigned int); void glDisable(unsigned int);
        void glClearColor(float, float, float, float);
        void glPixelStorei(unsigned int, int);
        extern int cur_frame_tick;
        extern float gl_c_r, gl_c_g, gl_c_b, gl_c_a, gl_c_cr, gl_c_cg, gl_c_cb, gl_c_ca;
        extern unsigned int gl_c_texture_unit, gl_c_texture, gl_c_fbo, gl_c_shader;
        extern int gl_c_vertices_nb, gl_c_texcoords_nb, gl_c_colors_nb;
        extern float *gl_c_vertices_ptr, *gl_c_texcoords_ptr, *gl_c_colors_ptr;
        struct faster_mask_check_timespec { long tv_sec; long tv_nsec; };
        int clock_gettime(int, struct faster_mask_check_timespec *);
    ]]
    local gl = ffi.load("libGL.so.1")
    local cfg = config.settings.faster_tome or {}
    local live = assert(realgame.level and realgame.level.map)
    local beforeCollect = Pixels.state()
    assert(beforeCollect.framebuffer[1] == 0 and beforeCollect.program[1] == 0, "run mask diagnostic after the complete display callback")
    local gcQueryOK, gcWasRunning = pcall(collectgarbage, "isrunning")
    -- Embedded LuaJIT 2.0.2 has no isrunning option. The session driver runs
    -- normal automatic GC; an already-stopped custom caller can opt out here.
    if not gcQueryOK then gcWasRunning = cfg.effect_mask_gc_was_stopped ~= true end
    collectgarbage("collect"); collectgarbage("stop")
    local initial = Pixels.state()
    local tick, turn = tonumber(ffi.C.cur_frame_tick), realgame.turn
    local playerx, playery, playerlife = realgame.player.x, realgame.player.y, realgame.player.life
    local caches = {}
    local cache_names = {"gl_c_r", "gl_c_g", "gl_c_b", "gl_c_a", "gl_c_cr", "gl_c_cg", "gl_c_cb", "gl_c_ca",
        "gl_c_texture_unit", "gl_c_texture", "gl_c_fbo", "gl_c_shader", "gl_c_vertices_nb", "gl_c_texcoords_nb", "gl_c_colors_nb",
        "gl_c_vertices_ptr", "gl_c_texcoords_ptr", "gl_c_colors_ptr"}
    for _, name in ipairs(cache_names) do caches[name] = ffi.C[name] end
    local function integer(name)
        local p = ffi.new("int[1]"); gl.glGetIntegerv(name, p); return tonumber(p[0])
    end
    local modelDepth, projectionDepth = integer(0x0BA3), integer(0x0BA4)
    local attribDepth, clientAttribDepth = integer(0x0BB0), integer(0x0BB1)
    gl.glPushAttrib(0xFFFFFFFF); gl.glPushClientAttrib(0xFFFFFFFF)
    gl.glDisable(0x0C11) -- A complete offscreen viewport, independent of UI clipping.
    gl.glPixelStorei(0x0D05, 1); gl.glPixelStorei(0x0D02, 0)
    gl.glPixelStorei(0x0D03, 0); gl.glPixelStorei(0x0D04, 0)
    local resources, renders, pixelFrames, visibilityCalls = {}, 0, 0, 0
    local bench = {}
    local tempmap
    local function find(f, source, first, last, visited)
        if type(f) ~= "function" then return end
        visited = visited or {}; if visited[f] then return end; visited[f] = true
        local i = debug.getinfo(f, "S")
        if i.source == source and i.linedefined == first and i.lastlinedefined == last then return f end
        if i.what ~= "C" then
            for n = 1, 80 do
                local name, value = debug.getupvalue(f, n); if not name then break end
                if type(value) == "function" then local result = find(value, source, first, last, visited); if result then return result end end
            end
        end
    end
    local function equal(a, b, why)
        local ok, key = Pixels.equal(a, b)
        assert(ok, why .. (key and (": " .. tostring(key)) or ""))
    end
    local function readFramebuffer(id, w, h)
        local old = integer(0x8CA6)
        gl.glBindFramebufferEXT(0x8D40, id)
        local data = ffi.new("unsigned char[?]", w * h * 4)
        gl.glReadPixels(0, 0, w, h, 0x1908, 0x1401, data)
        gl.glBindFramebufferEXT(0x8D40, old)
        return ffi.string(data, w * h * 4)
    end
    local ok, err = xpcall(function()
        local original = assert(find(Map.displayEffects, "@/engine/Map.lua", 1197, 1254), "cannot recover exact original displayEffects delegate")
        local visibility = assert(find(Map.calcEffectVisibility, "@/engine/Map.lua", 1181, 1194), "unknown calcEffectVisibility")
        local isolated = {displayEffects = original}
        assert(Cache.install(isolated, {effect_mask_batch = true}), "cannot install isolated optimized renderer")
        local optimized = isolated.displayEffects
        local w, h = live.viewport.width, live.viewport.height
        assert(w > 0 and h > 0 and w * h <= 4194304, "unexpected viewport")
        local target, mask = assert(core.display.newFBO(w, h)), assert(core.display.newFBO(w, h))
        resources[#resources+1], resources[#resources+2] = target, mask
        mask:use(true, 0, 0, 0, 0); local maskid = integer(0x8CA6); mask:use(false)
        target:use(true, 0, 0, 0, 0); local targetid = integer(0x8CA6); target:use(false)
        -- Own program from the original target_fbo fragment. It has the same
        -- uniforms/entry points, without modifying live map/target uniforms.
        local shader = setmetatable({shad = assert(Shader:createProgram{frag = "target_fbo"})}, {__index = Shader})
        shader:setUniform("fboTex", {texture = 0}); shader:setUniform("targetSkin", {texture = 1}); shader:setUniform("scrollOffset", {0, 0})
        resources[#resources+1] = shader
        tempmap = setmetatable({viewport = {width = w, height = h, mwidth = live.viewport.mwidth, mheight = live.viewport.mheight},
            mx = live.mx, my = live.my, tile_w = live.tile_w, tile_h = live.tile_h, zoom = live.zoom,
            display_x = 0, display_y = 0, fbo = mask, fbo_shader = shader, _map = live._map,
            tilesEffects = Tiles.new(live.tile_w, live.tile_h, live.fontname, live.fontsize, true, true),
            z_effects = {[1] = {}, [2] = {}}, seens = live.seens}, {__index = live})
        local effects = {}
        local function effect(z, dx, dy, radius, color, skin)
            local e = {x = playerx + dx, y = playery + dy, radius = radius,
                grids = core.fov.circle_grids(playerx + dx, playery + dy, radius, true),
                overlay = MapEffect.new{zdepth = z, alpha = color[4], color_br = color[1], color_bg = color[2], color_bb = color[3], effect_shader = skin}}
            effects[#effects+1] = e; tempmap.z_effects[z][e] = true; return e
        end
        local e1 = effect(1, 0, 0, 4, {30, 60, 200, 100}, {"shader_images/water_effect1.png", "shader_images/water_effect2.png", max = 3})
        local e2 = effect(1, 1, 0, 3, {200, 60, 30, 85}, "shader_images/fire_effect.png")
        local e3 = effect(2, -1, 1, 2, {150, 255, 150, 65}, "shader_images/poison_effect.png")
        local originalGrids = {}; for i, e in ipairs(effects) do originalGrids[i] = e.grids end
        local function animation()
            local out = {}
            for i, e in ipairs(effects) do
                local tex = e.overlay.effect_shader_tex
                out[i] = tex and {cur = tex.cur, cnt = tex.cnt, max = tex.max, n = #tex} or false
            end
            return out
        end
        local function restoreAnimation(state)
            for i, e in ipairs(effects) do
                if state[i] then
                    e.overlay.effect_shader_tex.cur, e.overlay.effect_shader_tex.cnt = state[i].cur, state[i].cnt
                else e.overlay.effect_shader_tex = nil end
            end
        end
        local function fovSnapshot()
            local out = {}
            for i, e in ipairs(effects) do out[i] = {seen = e.seen, grids = e.seen_grids} end
            return out
        end
        local visits
        local function trackedSeen(x, y)
            local result = live.seens(x, y)
            visibilityCalls = visibilityCalls + 1
            visits[#visits+1] = {x, y, type(result), result == nil and "nil" or result}
            return result
        end
        local function render(fn, keyframes, pixels)
            if pixels then visits = {}; tempmap.seens = trackedSeen else tempmap.seens = live.seens end
            target:use(true, 0.09, 0.13, 0.19, 0.7)
            assert(integer(0x8CA6) == targetid, "render did not bind its target FBO")
            visibility(tempmap, 1); fn(tempmap, 1, target, keyframes)
            assert(integer(0x8CA6) == targetid, "first effect layer lost its target FBO")
            visibility(tempmap, 2); fn(tempmap, 2, target, keyframes)
            assert(integer(0x8CA6) == targetid, "second effect layer lost its target FBO")
            renders = renders + 1
            local state = pixels and Pixels.state()
            local output = pixels and readFramebuffer(targetid, w, h)
            local public = pixels and readFramebuffer(maskid, w, h)
            local anim, fov, observed = pixels and animation(), pixels and fovSnapshot(), pixels and visits
            target:use(false)
            assert(integer(0x8CA6) == 0, "render did not return to the default FBO")
            if pixels then Pixels.checkGL() end
            return {pixels = output, mask = public, state = state, animation = anim, fov = fov, seen_calls = observed}
        end
        -- Finish lazy image/texture/program setup on both paths before pairs.
        render(original, 0, false); render(optimized, 0, false)
        Cache.clear(tempmap); Cache.resetStats()
        for frame = 1, (cfg.effect_mask_pixel_frames or 48) do
            -- gl_free_fbo binds FBO 0 without restoring it. Collect only at
            -- this unbound pair boundary, then keep GC stopped for BOTH sides.
            -- This also bounds the lifetime of four full RGBA readback copies.
            assert(integer(0x8CA6) == 0, "GC boundary has an active FBO")
            collectgarbage("collect"); collectgarbage("stop")
            local block = math.floor((frame - 1) / 4)
            tempmap.mx = live.mx + ({0, 0.01, -0.333, 0.6})[block % 4 + 1]
            tempmap.my = live.my + ({0, -0.01, 0.7, -0.25})[block % 4 + 1]
            tempmap.zoom = ({live.zoom, live.zoom, 0.75, 1.25})[math.floor(block / 2) % 4 + 1]
            tempmap.display_x, tempmap.display_y = block % 3 - 1, 1 - block % 3
            e2.overlay.alpha = block % 2 == 0 and 85 or 110
            -- Repeated stable windows, moving/range-changing masks, expiry,
            -- FOV boundaries and multiple overlapping effects/layers.
            e1.grids = block % 3 == 1 and originalGrids[2] or originalGrids[1]
            if block % 4 == 3 then tempmap.z_effects[2][e3] = nil else tempmap.z_effects[2][e3] = true end
            if block % 6 == 5 then e2.overlay.effect_shader = nil else e2.overlay.effect_shader = "shader_images/fire_effect.png" end
            local keyframes = ({0, 1, 2, 7})[frame % 4 + 1]
            local start = animation()
            local before = render(original, keyframes, true)
            restoreAnimation(start)
            local after = render(optimized, keyframes, true)
            assert(before.pixels == after.pixels, "complete shader output RGBA differs at frame " .. frame)
            assert(before.mask == after.mask, "public Map.fbo RGBA differs at frame " .. frame)
            equal(before.state, after.state, "GL state at frame " .. frame)
            equal(before.animation, after.animation, "animation progression at frame " .. frame)
            equal(before.fov, after.fov, "calcEffectVisibility output at frame " .. frame)
            equal(before.seen_calls, after.seen_calls, "native FOV query order at frame " .. frame)
            assert(tonumber(ffi.C.cur_frame_tick) == tick, "comparison advanced native frame tick")
            pixelFrames = pixelFrames + 1
            before, after = nil, nil
        end
        local pixelStats = Cache.stats()
        assert(pixelStats.hits > 0 and pixelStats.draws > 0, "optimized mask guard never allowed a cache hit")
        -- Optional controlled timing: full original function and shader/FBO
        -- work, same fixed masks. No readback, finish, fence or per-frame log.
        -- wall/CPU measure submission; GPU completion is not claimed here.
        if cfg.effect_mask_bench ~= false then
            tempmap.mx, tempmap.my, tempmap.zoom = live.mx, live.my, live.zoom
            tempmap.display_x, tempmap.display_y = 0, 0
            for i, e in ipairs(effects) do e.grids = originalGrids[i]; tempmap.z_effects[e.overlay.zdepth][e] = true end
            e2.overlay.effect_shader = "shader_images/fire_effect.png"
            tempmap.seens = live.seens
            local ts = ffi.new("struct faster_mask_check_timespec[1]")
            -- The driver may already have declared the same C ABI using its
            -- own timespec tag; void* bridges those equivalent struct names.
            local function time(id) ffi.C.clock_gettime(id, ffi.cast("void *", ts)); return tonumber(ts[0].tv_sec) * 1000 + tonumber(ts[0].tv_nsec) / 1000000 end
            local function timed(fn, label, pair)
                local count = cfg.effect_mask_bench_frames or 120
                local startAnim = animation()
                for i = 1, 12 do render(fn, 1, false) end
                restoreAnimation(startAnim)
                Cache.resetStats()
                local wall, cpu = time(1), time(3)
                for frame = 1, count do render(fn, frame % 3, false) end
                local wallMs, cpuMs = time(1) - wall, time(3) - cpu
                local result = {pair = pair, variant = label, frames = count, wall_ms = wallMs, cpu_ms = cpuMs, cache = Cache.stats(), animation = animation()}
                restoreAnimation(startAnim)
                return result
            end
            for pair = 1, (cfg.effect_mask_bench_pairs or 3) do
                assert(integer(0x8CA6) == 0, "benchmark GC boundary has an active FBO")
                collectgarbage("collect"); collectgarbage("stop")
                if pair % 2 == 1 then
                    bench[#bench+1] = timed(optimized, "batch", pair); bench[#bench+1] = timed(original, "original", pair)
                else
                    bench[#bench+1] = timed(original, "original", pair); bench[#bench+1] = timed(optimized, "batch", pair)
                end
                equal(bench[#bench-1].animation, bench[#bench].animation, "benchmark animation progression")
            end
        end
        assert(realgame.turn == turn and realgame.player.x == playerx and realgame.player.y == playery and realgame.player.life == playerlife, "diagnostic advanced gameplay")
        M.result = {sequence_frames = pixelFrames, renders = renders, fov_calls = visibilityCalls,
            full_shader_pixels_equal = true, public_mask_pixels_equal = true, gl_state_equal = true,
            fov_equal = true, animation_equal = true, frozen_native_tick = tick, turn_delta = realgame.turn - turn,
            viewport = {w, h}, pixel_cache = pixelStats, benchmark = bench, runtime = jit.version}
        M.result.gc_isolation = {stopped_inside_pairs = true, full_gc_at_unbound_pair_boundaries = true,
            benchmark_excludes_gc = true, normal_game_gc_benchmark = false, original_mode_was_running = gcWasRunning}
    end, debug.traceback)
    if not ok then print("[EffectMaskPixels] INTERNAL_FAILURE " .. tostring(err)) end
    if tempmap then Cache.clear(tempmap) end
    -- Balance any FBO projection pushes even if a comparison raises midway.
    gl.glMatrixMode(0x1701)
    while integer(0x0BA4) > projectionDepth do gl.glPopMatrix() end
    gl.glLoadMatrixf(ffi.new("float[16]", initial.projection))
    gl.glMatrixMode(0x1700)
    while integer(0x0BA3) > modelDepth do gl.glPopMatrix() end
    gl.glLoadMatrixf(ffi.new("float[16]", initial.modelview))
    -- Failed inner fbo:use(true) calls also leave viewport attribute pushes.
    -- Pop every diagnostic level, not just the outermost expected level.
    while integer(0x0BB1) > clientAttribDepth do gl.glPopClientAttrib() end
    while integer(0x0BB0) > attribDepth do gl.glPopAttrib() end
    gl.glMatrixMode(initial.matrix_mode[1]); gl.glBindFramebufferEXT(0x8D40, initial.framebuffer[1]); gl.glUseProgram(initial.program[1])
    local afterPop = Pixels.state()
    if not Pixels.equal(initial.clear_color, afterPop.clear_color) then
        print("[EffectMaskPixels] RESTORE_DETAIL " .. json.encode{before = initial.clear_color, after_pop = afterPop.clear_color,
            cache = {tonumber(caches.gl_c_cr), tonumber(caches.gl_c_cg), tonumber(caches.gl_c_cb), tonumber(caches.gl_c_ca)},
            attrib_depth = integer(0x0BB0), original_attrib_depth = attribDepth})
    end
    gl.glClearColor(unpack(initial.clear_color))
    for _, name in ipairs(cache_names) do ffi.C[name] = caches[name] end
    local restored, restoreError = pcall(function()
        equal(initial, Pixels.state(), "diagnostic restored caller GL state")
        Pixels.checkGL()
    end)
    if not restored then print("[EffectMaskPixels] RESTORE_FAILURE " .. tostring(restoreError)) end
    if gcWasRunning then collectgarbage("restart") else collectgarbage("stop") end
    if not ok then error(err, 0) end
    if not restored then error(restoreError, 0) end
    print("[EffectMaskPixels] PASS " .. json.encode(M.result))
end
return M
