-- Local, opt-in attribution. Requires screenshot-probe.so in LD_PRELOAD.
-- Lua timings are inclusive; native events belong to the innermost scope.
local M = {}
local lib, running, screenshot_enabled, save_swaps
local bindings, records, tags, next_tag, swap_depth = {}, {}, {}, 0, 0
local function pack(...) return {n = select('#', ...), ...} end
local function clock(cpu) return lib.faster_screenshot_clock(cpu and 1 or 0) end
local function newRecord()
    return {calls=0, failures=0, wall_ms=0, cpu_ms=0, max_wall_ms=0, max_cpu_ms=0}
end
local function swapRow(tag)
    local row = {}
    for i, name in ipairs{'calls', 'scopes', 'wall_ms', 'cpu_ms', 'max_interval_ms',
        'max_cpu_interval_ms', 'intervals', 'swap_wall_ms', 'swap_cpu_ms',
        'max_swap_ms', 'max_first_interval_ms', 'max_tail_interval_ms'} do
        row[name] = lib.faster_screenshot_swap_stat(tag, i-1)
    end
    return row
end
function M.beginSwapScope(name)
    assert(running, 'screenshot profile is not started')
    if swap_depth > 0 then swap_depth = swap_depth + 1; return end
    name = name or 'save'
    local tag = tags[name]
    if not tag then
        next_tag = next_tag + 1
        assert(next_tag < 16, 'too many screenshot presentation tags')
        tag = next_tag; tags[name] = tag
    end
    assert(lib.faster_screenshot_swap_begin(tag) == 1, 'native swap scope already active')
    swap_depth = 1
end
function M.endSwapScope()
    assert(swap_depth > 0, 'no screenshot swap scope is active')
    swap_depth = swap_depth - 1
    if swap_depth == 0 then lib.faster_screenshot_swap_end() end
end
local function bind(target, key, scope, presentation)
    local previous = assert(target[key], 'missing screenshot profile target: '..key)
    assert(type(previous) == 'function', 'screenshot profile target is not a function: '..key)
    local wrapper
    wrapper = function(...)
        if not running then return previous(...) end
        if presentation then M.beginSwapScope('save') end
        local old, w, c
        if scope then old = lib.faster_screenshot_scope(scope); w, c = clock(), clock(true) end
        local ret = pack(pcall(previous, ...))
        if scope then
            local dt, dc = clock()-w, clock(true)-c
            lib.faster_screenshot_scope(old)
            local row = records[key]
            row.calls = row.calls + 1
            if not ret[1] then row.failures = row.failures + 1 end
            row.wall_ms = row.wall_ms + dt; row.cpu_ms = row.cpu_ms + dc
            row.max_wall_ms = math.max(row.max_wall_ms, dt)
            row.max_cpu_ms = math.max(row.max_cpu_ms, dc)
        end
        if presentation then M.endSwapScope() end
        if not ret[1] then error(ret[2], 0) end
        return unpack(ret, 2, ret.n)
    end
    bindings[#bindings+1] = {target=target, key=key, previous=previous, wrapper=wrapper}
    target[key] = wrapper
end
function M.start(options)
    if running then return end
    options = options or {}
    local ffi = require 'ffi'
    ffi.cdef[[
        double faster_screenshot_clock(int);
        int faster_screenshot_scope(int);
        void faster_screenshot_reset(void);
        double faster_screenshot_stat(int, int, int);
        int faster_screenshot_swap_begin(int);
        void faster_screenshot_swap_end(void);
        double faster_screenshot_swap_stat(int, int);
    ]]
    lib = ffi.C
    -- Fail before installing wrappers if the preload library is absent.
    lib.faster_screenshot_scope(0)
    lib.faster_screenshot_reset()
    bindings, records, tags, next_tag, swap_depth = {}, {}, {}, 0, 0
    screenshot_enabled = options.screenshots ~= false
    save_swaps = options.save_swaps ~= false
    running = true
    local ok, err = pcall(function()
        local Game = require 'mod.class.Game'
        if screenshot_enabled then
            for _, key in ipairs{'takeScreenshot', 'forceRedrawForScreenshot', 'getScreenshot'} do
                records[key] = newRecord()
            end
            bind(Game, 'takeScreenshot', 1)
            bind(core.display, 'forceRedrawForScreenshot', 2)
            bind(core.display, 'getScreenshot', 3)
        end
        if save_swaps then bind(Game, 'saveGame', nil, true) end
    end)
    if not ok then M.stop(); error(err, 0) end
end
function M.reset()
    if not lib then return end
    for key in pairs(records) do records[key] = newRecord() end
    lib.faster_screenshot_reset()
end
function M.snapshot()
    if not lib then return nil end
    local result = {screenshots_enabled=screenshot_enabled, save_swaps_enabled=save_swaps,
        lua={}, native={}, swaps={}, presentation_measure='SDL_GL_SwapWindow call entry; not GPU completion'}
    for key, row in pairs(records) do
        result.lua[key] = {}
        for metric, value in pairs(row) do result.lua[key][metric] = value end
    end
    if screenshot_enabled then
        for scope, name in ipairs{'takeScreenshot', 'forceRedrawForScreenshot', 'getScreenshot'} do
            local row = {}
            for kind, event in ipairs{'glReadPixels', 'png_encode'} do
                local sample = {}
                for i, metric in ipairs{'calls', 'completed', 'wall_ms', 'cpu_ms',
                    'max_wall_ms', 'max_cpu_ms', 'pixels'} do
                    sample[metric] = lib.faster_screenshot_stat(scope, kind-1, i-1)
                end
                sample.incomplete = sample.calls - sample.completed
                row[event] = sample
            end
            result.native[name] = row
        end
    end
    for name, tag in pairs(tags) do result.swaps[name] = swapRow(tag) end
    return result
end
function M.stop()
    if not running then return end
    if swap_depth > 0 then lib.faster_screenshot_swap_end(); swap_depth = 0 end
    lib.faster_screenshot_scope(0)
    running = false
    for i = #bindings, 1, -1 do
        local b = bindings[i]
        if b.target[b.key] == b.wrapper then b.target[b.key] = b.previous end
    end
    bindings = {}
end
return M
