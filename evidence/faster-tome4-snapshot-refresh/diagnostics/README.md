# Local screenshot and presentation attribution

These diagnostics do not change screenshots, PNG settings, rendering calls,
save scheduling, GC, or GL synchronization. They are not addon production code.

Build from the addon worktree:

```sh
cc -shared -fPIC -O2 -Wall -Wextra -Werror \
  -o /workspace/t-engine4/tmp/worktrees/yron-profile-20260912/tmp/profile/screenshot-probe.so \
  evidence/faster-tome4-snapshot-refresh/diagnostics/screenshot-probe.c \
  $(pkg-config --cflags libpng sdl2 gl) -ldl
cp evidence/faster-tome4-snapshot-refresh/diagnostics/FasterScreenshotProfile.lua \
  /workspace/t-engine4/tmp/worktrees/yron-profile-20260912/game/addons/tome-faster/overload/engine/
```

Add `screenshot-probe.so` to the runtime process's `LD_PRELOAD`. For the final
presentation A/B, load only this probe: avoid the separate TTF/render probe.
The module must be installed after the driver's other method wrappers.

## Driver integration

Full screenshot attribution, with automatic presentation scopes around
`Game.saveGame`:

```lua
local Screenshot = require 'engine.FasterScreenshotProfile'
Screenshot.start()
-- In phase begin, after any warmup:
Screenshot.reset()
-- In phase_end output:
native_screenshot = Screenshot.snapshot()
-- At driver completion:
Screenshot.stop()
```

For the final save presentation A/B, this enables only presentation measurement
and leaves all screenshot methods unwrapped:

```lua
Screenshot.start({screenshots=false, save_swaps=true})
```

To include asynchronous save work, the driver can instead own the complete
phase boundary:

```lua
Screenshot.start({screenshots=false, save_swaps=false})
-- When the save phase starts:
Screenshot.reset()
Screenshot.beginSwapScope('save_phase')
-- Immediately before phase_end output:
Screenshot.endSwapScope()
local native_screenshot = Screenshot.snapshot()
```

Manual scopes can also surround automatically measured saves; nested scopes
retain the outer tag and boundary. Up to 15 named tags are supported per start.
Reset clears totals and restarts an active presentation interval. Snapshot
copies Lua records and does not mutate counters. During an active scope it
includes the current trailing interval; close the scope before snapshotting
when exact, mutually consistent final totals are needed.

## Interpretation

- `lua.takeScreenshot`, `lua.forceRedrawForScreenshot`, and `lua.getScreenshot`
  are inclusive main-thread wall/CPU timings. Do not add them together.
- Native `glReadPixels` and `png_encode` events belong to the innermost active
  screenshot scope, normally `getScreenshot`. PNG encoding measures the entire
  `png_write_png` call, including its Lua output-buffer callbacks. A nested
  `png_write_image` is excluded, while a standalone write-image call is counted.
  This is not a compression-only timer. Allocation, gamma adjustment and row
  setup outside these entry points remain in the Lua `getScreenshot` total.
- `calls - completed` exposes native calls escaped by a libpng longjmp; their
  incomplete durations are omitted. Leaving the screenshot scope clears the
  stale nesting marker. Lua error objects and return arity are preserved.
- `swaps.<tag>.calls` counts `SDL_GL_SwapWindow` entries, including redraws
  executed through `core.wait` that do not pass through `Game.display`.
  `max_interval_ms` and `max_cpu_interval_ms` include scope start to first swap,
  every swap-to-swap interval, and last swap to scope end. With no swaps, the
  whole scope is one interval. First/tail wall maxima are also reported.
- Swaps measure **frame submission**, not GPU completion or monitor scanout.
  No `glFinish` or GPU query is added. `swap_wall_ms` separately reports time
  inside the original swap calls; blocking there is also part of the next
  submission interval. CPU uses `CLOCK_THREAD_CPUTIME_ID`, wall uses monotonic
  time. Counters and scopes are thread local.
- No screenshot caching, scene reuse, readback replacement, or PNG compression
  setting is enabled by this probe.

## Headless checks

These use mock GL/SDL callees and real libpng; they never start the game or an
OpenGL context. The C check verifies GL arguments/data, byte-identical PNGs,
single-count nested PNG encoding, recovery after PNG failure, zero-swap and
ordinary scope boundaries, and isolation of swap-only measurement. The Lua
check verifies exact arguments/returns/error objects, coroutine yielding,
wrapper cleanup/restart, and automatic/manual/swap-only modes.

```sh
cc -shared -fPIC -O2 -Wall -Wextra -Werror -DBUILD_STUB \
  -o /tmp/screenshot-probe-fixture.so \
  evidence/faster-tome4-snapshot-refresh/diagnostics/probe-check.c \
  $(pkg-config --cflags libpng sdl2 gl)
cc -O2 -Wall -Wextra -Werror -o /tmp/screenshot-probe-check \
  evidence/faster-tome4-snapshot-refresh/diagnostics/probe-check.c \
  /tmp/screenshot-probe-fixture.so $(pkg-config --cflags --libs libpng sdl2) -ldl
LD_PRELOAD=/workspace/t-engine4/tmp/worktrees/yron-profile-20260912/tmp/profile/screenshot-probe.so \
  /tmp/screenshot-probe-check
LD_PRELOAD=/workspace/t-engine4/tmp/worktrees/yron-profile-20260912/tmp/profile/screenshot-probe.so \
  luajit evidence/faster-tome4-snapshot-refresh/diagnostics/module-check.lua \
  evidence/faster-tome4-snapshot-refresh/diagnostics
LD_PRELOAD=/workspace/t-engine4/tmp/worktrees/yron-profile-20260912/tmp/profile/screenshot-probe.so \
  luajit -joff evidence/faster-tome4-snapshot-refresh/diagnostics/module-check.lua \
  evidence/faster-tome4-snapshot-refresh/diagnostics
```

All three checks passed on 2026-09-13. The library also builds with warnings
treated as errors. Real game attribution and A/B measurements remain the
driver's responsibility.
