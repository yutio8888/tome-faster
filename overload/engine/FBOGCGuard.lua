-- Experimental ToME 1.7.6 workaround. No FFI, native layouts, or GC tuning.
-- gl_free_fbo leaves framebuffer 0 bound. Defer it until immediately before
-- gl_fbo_use, which establishes its requested target before drawing resumes.
local M = {}
local marker = "__fbo_gc_guard_v1"

function M.install()
    if not debug or not debug.getregistry or not debug.getinfo or not newproxy then
        return nil, "required Lua 5.1 runtime interfaces are unavailable"
    end
    local mt = debug.getregistry()["gl{fbo}"]
    if type(mt) ~= "table" or type(mt.__index) ~= "table" then
        return nil, "framebuffer metatable is unavailable"
    end
    if mt[marker] then return mt[marker] end
    local native_gc, native_use = mt.__gc, mt.__index.use
    if type(native_gc) ~= "function" or type(native_use) ~= "function" or
        debug.getinfo(native_gc, "S").what ~= "C" or
        debug.getinfo(native_use, "S").what ~= "C" then
        return nil, "another modification has replaced the native framebuffer methods"
    end

    local pending, spare, count, shutting_down = {}, {}, 0, false
    local state = {queued = 0, released = 0, peak_pending = 0}
    local function drain()
        -- No frame hooks or GL queries: the caller must establish the next
        -- binding immediately after this function returns, or be closing Lua.
        -- Keep anything finalized during this drain in the other queue for
        -- the next bind. Both buffers are reused without per-bind allocation.
        local batch, n = pending, count
        pending, spare, count = spare, batch, 0
        for i = 1, n do
            local fbo = batch[i]
            batch[i] = nil
            native_gc(fbo)
            state.released = state.released + 1
        end
    end

    -- This userdata stays reachable for the lifetime of the Lua state. During
    -- lua_close it drains already-finalized objects and switches remaining
    -- finalizers to immediate destruction. Rebooting Lua keeps the GL context,
    -- so relying on process exit to release these resources would leak them.
    local shutdown = newproxy(true)
    getmetatable(shutdown).__gc = function()
        shutting_down = true
        drain()
    end
    state.shutdown_guard = shutdown
    function state.pending_count() return count end

    mt.__gc = function(fbo)
        if shutting_down then return native_gc(fbo) end
        count = count + 1
        pending[count] = fbo
        state.queued = state.queued + 1
        if count > state.peak_pending then state.peak_pending = count end
    end
    mt.__index.use = function(fbo, ...)
        if count > 0 then drain() end
        return native_use(fbo, ...)
    end
    mt[marker] = state
    return state
end

return M
