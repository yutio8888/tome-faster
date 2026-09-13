-- Local native substage attribution. Enable only in explicit diagnostic runs.
local M = {}
local ffi, lib
function M.start()
    ffi = require "ffi"
    ffi.cdef[[int faster_render_scope(int); void faster_render_reset(void);
        double faster_render_stat(int, int, int);]]
    lib = ffi.C
    local function pack(...) return {n = select("#", ...), ...} end
    local function wrap(t, key, scope)
        local previous = t[key]
        t[key] = function(self, ...)
            local old = lib.faster_render_scope(scope)
            local values = pack(pcall(previous, self, ...))
            lib.faster_render_scope(old)
            if not values[1] then error(values[2], 0) end
            return unpack(values, 2, values.n)
        end
    end
    wrap(require "engine.HotkeysIconsDisplay", "display", 1)
    wrap(require "engine.Map", "displayEffects", 2)
end
function M.reset() if lib then lib.faster_render_reset() end end
function M.snapshot()
    if not lib then return nil end
    local result = {}
    for scope, name in ipairs{"hotkeys", "map_effects"} do
        local row = {}
        for kind, event in ipairs{"ttf_raster", "texture_image", "texture_upload", "draw_arrays"} do
            row[event] = {calls = lib.faster_render_stat(scope, kind-1, 0),
                wall_ms = lib.faster_render_stat(scope, kind-1, 1),
                cpu_ms = lib.faster_render_stat(scope, kind-1, 2),
                pixels_or_vertices = lib.faster_render_stat(scope, kind-1, 3)}
        end
        result[name] = row
    end
    return result
end
return M
