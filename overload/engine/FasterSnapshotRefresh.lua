-- GPL-3.0-or-later. See COPYING.
-- Keep save cloning synchronous, with short native wait pulses only for redraw.
-- No game tick, event dispatch, coroutine yield, dialog registration or GC change.
local M = {}
local installed = setmetatable({}, {__mode = "k"})
local diagnostics, last_result = false, nil
local FRAME_MS = 16

function M.enableDiagnostics(value)
    diagnostics = value and true or false
    last_result = nil
end

function M.getDiagnostics()
    if not last_result then return nil end
    local result = {}
    for k, v in pairs(last_result) do result[k] = v end
    return result
end

-- The backend interface also permits deterministic failure/reentrancy tests.
-- begin() owns cleanup even if enable() throws before returning its depth.
function M.makeRunner(original, factory, backend)
    local active, refreshing, checkpoints, refreshes, started, previous, longest
    local failure
    local function checkpoint()
        if not refreshing then return end
        checkpoints = checkpoints + 1
        local current = backend.clock()
        if current - previous < FRAME_MS and current >= previous then return end
        longest = math.max(longest, current - previous)
        local ok, continuing = pcall(backend.refresh)
        if not ok or continuing == false then
            pcall(backend.finish)
            refreshing = false
            failure = not ok and "wait redraw failed" or "runtime changed"
            return
        end
        refreshes = refreshes + 1
        previous = backend.clock()
    end
    local copy = factory(checkpoint)
    return function(self)
        if active or not backend.supported(self) then
            if diagnostics then last_result = {fallback = true, reason = active and "reentrant clone" or "unsupported runtime"} end
            return original(self)
        end
        active, refreshing = true, false
        checkpoints, refreshes, longest, failure = 0, 0, 0, nil
        started = backend.clock()
        local ready, entered = pcall(backend.begin, self)
        if not ready or not entered then
            pcall(backend.finish)
            active = false
            if diagnostics then last_result = {fallback = true, reason = ready and "existing wait" or "wait setup failed"} end
            return original(self)
        end
        previous, refreshing = backend.clock(), true
        local ok, clone, count = pcall(copy, self)
        local ended = backend.clock()
        if refreshing then longest = math.max(longest, ended - previous) end
        local finished = pcall(backend.finish)
        active, refreshing = false, false
        if diagnostics then
            last_result = {fallback = false, completed = ok, checkpoints = checkpoints,
                refreshes = refreshes, max_copy_interval_ms = longest,
                total_ms = backend.clock() - started, counted_objects = ok and count or nil,
                redraw_failed = failure == "wait redraw failed", refresh_stopped = failure ~= nil,
                stopped_reason = failure, cleanup_failed = not finished}
        end
        if not ok then error(clone, 0) end
        return clone, count
    end
end

local function native(f)
    return type(f) == "function" and debug.getinfo(f, "S").what == "C"
end

local function nativeBackend(environment)
    local globals = environment._G
    if type(globals) ~= "table" then return nil end
    local core = rawget(globals, "core")
    if type(core) ~= "table" or getmetatable(core) ~= nil then return nil end
    local wait, display, gamecore = core.wait, core.display, core.game
    if type(wait) ~= "table" or type(display) ~= "table" or type(gamecore) ~= "table" then return nil end
    if getmetatable(wait) or getmetatable(display) or getmetatable(gamecore) then return nil end
    -- on_redraw dispatches these services after draw_waiting, and their Lua
    -- callbacks cannot be deferred with the public API. Never hide the tables.
    if core.webview ~= nil or core.steam ~= nil then return nil end
    local enable, disable = wait.enable, wait.disable
    local draw_last, quad, clock = wait.drawLastFrame, display.drawQuad, gamecore.getTime
    if not (native(enable) and native(disable) and native(draw_last) and native(quad) and native(clock)) then return nil end
    local owned, owner, width, height, offset = false, nil, 0, 0, 0
    local function draw()
        draw_last()
        local bar_width = math.min(240, width - 32)
        local x, y = (width - bar_width) / 2, height - 36
        quad(x - 4, y - 4, bar_width + 8, 16, 16, 16, 16, 224)
        quad(x, y, bar_width, 8, 64, 64, 64, 255)
        quad(x + offset % (bar_width - 32), y, 32, 8, 220, 210, 150, 255)
        offset = offset + 16
    end
    local function factory() return draw end
    local function supported(self)
        if rawget(globals, "game") ~= self or type(self) ~= "table" then return false end
        if getmetatable(core) or getmetatable(wait) or getmetatable(display) or getmetatable(gamecore) then return false end
        if rawget(core, "webview") ~= nil or rawget(core, "steam") ~= nil or rawget(globals, "core") ~= core then return false end
        if rawget(core, "wait") ~= wait or rawget(core, "display") ~= display or rawget(core, "game") ~= gamecore then return false end
        if rawget(wait, "enable") ~= enable or rawget(wait, "disable") ~= disable
            or rawget(wait, "drawLastFrame") ~= draw_last
            or rawget(display, "drawQuad") ~= quad or rawget(gamecore, "getTime") ~= clock then return false end
        if debug.gethook() ~= nil then return false end
        local w, h = rawget(self, "w"), rawget(self, "h")
        return type(w) == "number" and type(h) == "number" and w >= 96 and h >= 64
            and w < 65536 and h < 65536
    end
    local function close()
        if not owned then return end
        owned = false
        local hook, mask, count = debug.gethook()
        disable()
        -- Native disable clears its own count hook. Do not discard a Lua hook
        -- installed by a finalizer/extension while the redraw was in progress.
        if type(hook) == "function" then debug.sethook(hook, mask, count) end
    end
    local function pulse()
        if not supported(owner) then return false end
        owned = true -- native enable increments before invoking our factory.
        -- enable captures the last frame and redraws it once. Its native count
        -- hook cannot reach this budget during our small allocation-free draw.
        local first = enable(1000000000, factory)
        close()
        return first
    end
    return {
        supported = supported,
        clock = clock,
        begin = function(self)
            owner = self
            width, height, offset = rawget(self, "w"), rawget(self, "h"), 0
            return pulse()
        end,
        -- No native waiting state spans source traversal, including __index and
        -- finalizers. No manualTick: its SDL pump can call Game.onQuit directly.
        refresh = pulse,
        finish = function()
            close()
            owner = nil
        end,
    }
end

function M.installGame(Game, options)
    if options and (options.snapshot_refresh == false or options.save_clone == false) then return false, "disabled in faster_tome settings" end
    local original = Game.cloneForSave
    if installed[original] then return true end
    local FasterClone = require "engine.FasterClone"
    local environment = FasterClone.getInstalledEnvironment(original)
    if not environment then return false, "unknown save clone; keeping existing method" end
    local backend = nativeBackend(environment)
    if not backend then return false, "wait redraw cannot isolate callbacks in this environment" end
    local supported = backend.supported
    backend.supported = function(self)
        return FasterClone.getInstalledEnvironment(original) == environment and supported(self)
    end
    local Clone = require "engine.FasterCloneRefresh"
    local method = M.makeRunner(original, function(checkpoint) return Clone.make(environment, checkpoint) end, backend)
    Game.cloneForSave, installed[method] = method, true
    return true
end

return M
