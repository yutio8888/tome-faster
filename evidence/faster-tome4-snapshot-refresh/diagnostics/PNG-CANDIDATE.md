# Lossless save screenshot candidate

The observed `stutter-snapshot-attribution-01` capture took 50.505 ms:
force redraw 6.364 ms, native capture 44.129 ms. Inside native capture,
`glReadPixels` took 0.729 ms wall / 0.163 ms CPU and `png_write_png` took
43.244 ms wall / 43.168 ms CPU, for 256,000 pixels. These are nested timings,
not additive independent stages.

`overload/engine/FasterScreenshot.lua` targets that PNG cost. Integrate with:

```lua
local fast, reason = require('engine.FasterScreenshot').prepareScreenshot(
    Game.takeScreenshot, options)
if fast then Game.takeScreenshot = fast end
```

`options.screenshot_png=false` disables preparation. Unknown source methods,
native bindings, platforms and unavailable public APIs retain the original.
`stats()` returns capture/bypass/failure totals, raw and PNG byte totals, and
retained buffer size. No state is stored on the game or save graph.

The prepared method is a private bytecode copy of the pinned, zero-upvalue
`Game.takeScreenshot` at `/mod/class/Game.lua:2890–2903`. Its only changed
global lookup is `core.display.getScreenshot`; its original force-redraw call
and crop calculations are intact. The original function environment and public
`core.display` table are unchanged. Only `for_savefile == true` is eligible;
other arguments execute the original method directly.

The candidate reads RGB/unsigned-byte pixels through public GL and SDL APIs,
uses the same SDL window height and `ah-(y+height)` origin as native capture,
and reverses rows exactly as the native encoder does. PNG output is RGB8,
noninterlaced, with IHDR/IDAT/IEND only, no gamma or ICC metadata. Each scanline
uses filter None and embedded lzlib compresses with level 1, method 8,
windowBits 15, memLevel 8, strategy 0. PNG compressed bytes are expected to
differ; decoded RGB pixels and format metadata must match.

The implementation accepts Linux and Windows x64/x86 with desktop GL 3 or newer.
Linux uses the existing global symbol namespace. Windows obtains handles for
the already-loaded `SDL2.dll` and `opengl32.dll`, then resolves the six public
functions by name. No new DLL is loaded. Missing modules/exports fall back.
SDL functions use cdecl; Win32 lookup and GL functions use explicit stdcall,
which Windows x64 ignores. Windows `ffi.C` already includes kernel32, so it can
resolve the module lookup functions. These declarations follow the
[LuaJIT namespace documentation](https://luajit.org/ext_ffi_api.html),
[Windows GL prototype](https://learn.microsoft.com/en-us/windows/win32/opengl/glreadpixels)
and [Windows calling convention documentation](https://learn.microsoft.com/en-us/cpp/cpp/stdcall).

**Windows has not been tested on a Windows machine.** The resolver tests below
exercise Linux fixture functions and do not establish Windows loader/ABI,
driver correctness or performance. The same capability checks apply there.

Before readback it requires the original current SDL window, unchanged window
dimensions, default read framebuffer, FRONT/BACK read buffer, no pixel-pack
buffer, and zero pack row length/skip rows/skip pixels. GL 3 guarantees these
query enums; older and ES contexts fall back before those queries. Native
`redrawingForSavefileScreenshot()` must still report save mode: a nested user
redraw requires the original gamma-aware path. Binding/table changes also
delegate. No GL error flag is queried or cleared.

Buffer allocation precedes the final window/mode/GL checks. A shared busy guard
prevents a nested screenshot from overwriting the outer capture. Allocation or
encoding failure clears that guard and retries the original capture at the
same already-rendered observation point. The optimized call leaves pack
alignment at 1, matching the original. It adds no `glFinish`, GPU query, frame
reuse, random calls, scene redraw, or native binary.

One reusable FFI buffer contains both RGB input and filtered scanlines, capped
at 2,097,152 pixels / 12,587,008 retained bytes. Larger or fractional geometry
falls back. Temporary Lua strings for compression and PNG assembly add peak
allocation beyond that retained-buffer limit; they are not cached.

## Verification completed without starting the game

```sh
luajit tests/test_screenshot.lua . /workspace/t-engine4/tmp/worktrees/yron-profile-20260912
luajit -joff tests/test_screenshot.lua . /workspace/t-engine4/tmp/worktrees/yron-profile-20260912
```

Both modes passed 1,229 checks on 2026-09-13. The fixture compiles the exact
pinned screenshot and lzlib sources, supplies controlled public GL/SDL
functions, and decodes both outputs with independent libpng calls. Coverage
includes odd widths, crop edges, RGB row orientation, buffer resizing/reuse,
PNG chunk CRCs/metadata, user gamma, nested redraw gamma, GL/platform/capacity
fallback, high-bit CRC seeds, dynamic bindings, exact fallback return arity,
encoding errors, allocation-triggered GL changes, and reentrant captures.
The Windows resolver fixture additionally checks both module names, every
missing export, explicit calling-convention declarations, no DLL loading,
shared pixel/state guards after resolution, and the x86 high-bit CRC preflight.

The synthetic 640×400 gradient fixture grew from 3,595 bytes to 15,073 bytes
(4.193×). That deliberately compressible gradient is not a forecast for real
save images. Real Yron screenshot bytes, decoded equality and total screenshot
time must be measured in the runtime session.

The separate native screenshot profiler wraps public screenshot functions and
therefore deliberately triggers this candidate's unknown-binding fallback.
Use its `screenshots=false` presentation-only mode for optimized A/B timing,
with the driver's ordinary `Game.takeScreenshot` timer. For pixel validation,
capture a fast save PNG and immediately capture the same crop through the
unchanged native `core.display.getScreenshot`, without another redraw, then
compare decoded pixels offline.
