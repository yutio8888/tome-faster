-- GPL-3.0-or-later. Resource lifecycle fixture.
local Guard = dofile("overload/engine/FBOGCGuard.lua")
-- Include objects created before installation, as happens in the real loader.
local old = make_fbo()
local state = assert(Guard.install())
assert(Guard.install() == state)
local outer, inner = make_fbo(), make_fbo()
outer:use(true)
local target = get_binding()
old = nil
collectgarbage("collect")
assert(state.pending_count() == 1 and get_freed() == 0)
assert(get_binding() == target, "collection changed a live drawing target")
inner:use(true)
assert(get_freed() == 1 and state.pending_count() == 0)
local nested = get_binding()
assert(nested ~= target and nested ~= 0)
for i = 1, 512 do local unused = make_fbo() end
collectgarbage("collect")
collectgarbage("collect")
assert(get_binding() == nested and state.pending_count() == 512)
inner:use(false, outer)
assert(get_binding() == target and get_freed() == 513)
outer:use(false)
collectgarbage("collect")
assert(get_freed() == 513, "finalized objects were destroyed twice")
-- Leave both pending and reachable resources at lua_close, without another
-- use call. The C host verifies that every resource is destroyed exactly once.
for i = 1, 17 do local unused = make_fbo() end
collectgarbage("collect")
assert(state.pending_count() == 17)
_G.keep_alive = {outer, inner, make_fbo()}
