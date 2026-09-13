-- Local diagnostic: report the first few mask guard inputs without changing
-- the native texture/VO methods or retaining maps/effects in the log.
local M = {}
function M.start()
    local Cache = require "engine.FasterEffectMask"
    local method = Cache.prepare and "prepare" or "draw"
    local original, count = Cache[method], 0
    local upvalues = {}
    for i = 1, 60 do local name, value = debug.getupvalue(original, i); if not name then break end; upvalues[name] = value end
    local function describe(value)
        local mt = getmetatable(value)
        local index = type(mt) == "table" and rawget(mt, "__index")
        return {kind = type(value), metatable = type(mt), index = type(index),
            class = type(value) == "table" and rawget(value, "__CLASSNAME") or nil,
            index_name = type(index) == "table" and rawget(index, "_NAME") or nil,
            native_class = type(index) == "table" and rawget(index, "class") or nil}
    end
    local function fn(f)
        if type(f) ~= "function" then return {kind = type(f)} end
        local i = debug.getinfo(f, "S")
        return {what = i.what, source = i.source, first = i.linedefined, last = i.lastlinedefined}
    end
    Cache[method] = function(map, effect, texture)
        local result = original(map, effect, texture)
        count = count + 1
        if count <= 8 then
            local guards, chain = {}, {}
            local function guard(label, name, ...)
                local f = upvalues[name]
                if type(f) ~= "function" then guards[label] = "missing upvalue " .. name; return end
                local ok, value = pcall(f, ...)
                if ok then guards[label] = not not value else guards[label] = "error: " .. tostring(value) end
            end
            guard("effect_plain", "plain", effect)
            guard("overlay_allowed", "overlayTable", effect.overlay)
            guard("grids_plain", "plain", effect.seen_grids)
            guard("viewport_plain", "plain", map.viewport)
            guard("tiles_get", "upstream", map.tilesEffects.get, "@/engine/Tiles.lua", 103, 175)
            guard("texture_native_identity", "nativeObject", texture, "gl{texture}", "toScreen")
            guard("allocator_native", "native", core.display.newVO)
            guards.allocator_identity = core.display.newVO == upvalues.originalNewVO
            for _, key in ipairs{"mx", "my", "tile_w", "tile_h", "zoom"} do guard("finite_" .. key, "finite", map[key]) end
            guard("finite_width", "finite", map.viewport.width); guard("finite_height", "finite", map.viewport.height)
            guard("finite_scaled_w", "finite", map.tile_w * map.zoom); guard("finite_scaled_h", "finite", map.tile_h * map.zoom)
            local node = effect.overlay
            for depth = 1, 10 do
                local mt = getmetatable(node)
                local keys = {}; if type(mt) == "table" then for key in pairs(mt) do keys[#keys+1] = tostring(key) end end
                chain[#chain+1] = {name = type(node) == "table" and rawget(node, "_NAME") or nil, mt_kind = type(mt), keys = keys}
                node = type(mt) == "table" and rawget(mt, "__index")
                if type(node) ~= "table" then break end
            end
            local loaded = package.loaded["engine.MapEffect"]
            local mt = getmetatable(effect.overlay)
            guards.overlay_class_identity = type(mt) == "table" and rawget(mt, "__index") == loaded
            guards.overlay_class_init = type(loaded) == "table" and fn(rawget(loaded, "init")) or {kind = type(loaded)}
            print("[EffectMaskGuard] " .. json.encode{method = method, accepted = not not result, guards = guards, overlay_chain = chain,
                effect = describe(effect), overlay = describe(effect.overlay),
                grids = describe(effect.seen_grids), viewport = describe(map.viewport), texture = describe(texture),
                tiles_get = fn(map.tilesEffects.get), allocator = fn(core.display.newVO),
                texture_draw = fn(texture.toScreen), mx = map.mx, my = map.my, tile_w = map.tile_w, tile_h = map.tile_h,
                zoom = map.zoom, width = map.viewport.width, height = map.viewport.height})
        end
        return result
    end
    return function() Cache[method] = original end
end
return M
