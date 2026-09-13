-- GPL-3.0-or-later. Resource lifecycle fixture.
local Guard = dofile("overload/engine/FBOGCGuard.lua")
local state = assert(Guard.install())
local outer = make_fbo()
outer:use(true)
local target = get_binding()
do local first = make_fbo() end
collectgarbage("collect")
assert(state.pending_count() == 1 and get_freed() == 0)
collectgarbage("stop")
do local second = make_fbo() end
-- The C host forces another collection while manually releasing the first
-- batch. This new finalizer must survive in the other queue until next bind.
arm_collect()
outer:use(true)
assert(get_binding() == target)
assert(state.pending_count() == 1 and get_freed() == 1)
outer:use(false)
assert(state.pending_count() == 0 and get_freed() == 2)
_G.keep_alive = outer
