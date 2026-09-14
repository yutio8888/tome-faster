# Faster ToME4 — runtime and save optimizations

Version **0.2.12**, modified 14 September 2026. This fork fixes defects in
[Yutio888's Faster ToME4 0.0.1](https://te4.org/games/addons/tome/faster) and adds
conservative save/load and runtime optimizations for **ToME 1.7.6**.

Version 0.2.12 enables **inventory ownership compaction and completed Fearscape
reference cleanup by default**. Both act at their original gameplay events;
they do not scan or migrate an old saved graph. Set `compact_inventory=false`
or `fearscape_cleanup=false` and restart to disable either feature. Short decimal
object names remain enabled; **base62 remains disabled by default** and requires
`compact_save_names_base62=true`. See the [default configuration](docs/save-defaults.md).

The [single-option measurements](docs/save-isolated.md) retain the frozen 0.2.11
results: five separate workloads, 30 pairs each, with events timed separately
from saving. Base62 did not establish the save CPU limit; the other four save
workloads passed their individual gates. These are scoped measurements, not a
new CPU benchmark of the combined 0.2.12 defaults. Implementation details and
earlier compatibility checks remain in the [0.2.11 report](docs/save-compaction.md).

Version 0.2.10 uses short decimal identifiers for internal save objects, keeping
the `main` entry, original reader, native serializer and compression level.
Existing region archives acquire the smaller names when naturally saved again;
there is no extra migration pass. Set `compact_save_names=false` and restart to
disable the writer optimization. Existing compact saves still load normally.
See the [save size analysis and production validation](docs/save-size-analysis.md).
The [save-system technical guide](docs/tome4-save-system.md) explains the pipeline,
file structure, remaining candidates, implementation costs and compatibility limits.

Version 0.2.9 reduces A* neighbor allocation and large-frontier scanning while
retaining the original path choices. Three loads of one real 50×50 map measured
13–21% less path-query CPU time, depending on path length; this is not an FPS or
whole-turn claim. It also restores effect-mask batching with the default FBO
guard and keeps chat measurement keys weak after resizing. See the
[implementation, measurements and limits](docs/ai-performance.md).

Version 0.2.8 defers framebuffer destruction until immediately before the next
normal FBO binding. This avoids the 1.7.6 native finalizer leaving framebuffer 0
bound in the middle of rendering, using pure Lua and the existing engine methods.
Set `fbo_gc_guard=false` and restart to disable it. Linux binding/pixel tests and
a small combat pilot passed; Windows and long-session behavior remain unmeasured.
See the [FBO design, tests and limitations](docs/fbo-gc.md).

Version 0.2.7 limits ranged-hit direction indicators to **one every 500 ms per
map**. The first warning appears immediately; suppressed hits do not extend the
interval, and moving or changing attack direction does not reset it. Other
particle calls pass through. Set `hit_warning_interval_ms=1000` for one per second
or `0` to disable the limit, then restart.

Version 0.2.6 refreshes a native wait screen at checkpoints during synchronous
snapshot copying and encodes save screenshots as lossless PNG with less
compression work. Input still waits for copying to return, and GC policy and
the three full GC barriers are unchanged. See the
[0.2.6 design, compatibility limits and measured results](docs/snapshot-refresh.md).

Version 0.2.5 adds bounded hotkey text caching, ordered effect-mask geometry
batching, and shared serializer callbacks. The original dynamic UI checks, effect
shader animation, save format and three full GC barriers are retained.
See the [0.2.5 design and results](docs/render-save.md).

Version 0.2.4 fixes retained native gzip allocations in the recognized character
exporter using the engine's embedded lzlib binding. The compression parameters,
successful output bytes and export callbacks are retained; empty and short inputs
also produce valid gzip streams. See the [gzip design and results](docs/gzip-export.md).

The preceding release removes the unused temporary party built and cleaned before character
export. The save queue, online export call, player control switches and Cults arena
save restriction are retained. Its discarded callbacks, RNG consumption and
temporary UID allocations are intentionally omitted; saving no longer preserves
the old random sequence. See the [cleanup design and results](docs/export-cleanup.md).

Equivalent snapshot cloning and skipping offline character sheets remain included;
their earlier results are in the [0.2.2 report](docs/save-stutter.md). The finite
`notice_enemy` / `dreamhammer` lifetimes and opt-in timer remain included.
Further measured hotspots and addon candidates are described in the
[follow-up plan](docs/followup-plan.md). Asynchronous snapshot slicing and full-collector
rescheduling remain unimplemented; checkpoint drawing keeps the copy synchronous.

中文说明：[性能问题、修复方案、测量指标与文件清单](docs/faster-tome4-performance-report.md)。
Published evidence: [profile results](evidence/faster-tome4-profile/README.md).
Package build instructions and version history: [releases](releases/README.md).
Full-game save A/B and complete loaded-graph equivalence have now been tested on
one supplied save. Hardware GPU, Steam callback and Windows runtime testing,
and automatic old-save reference migration remain outside this release.
Player archives and generated save graphs stay local.

## Changes

- Normalize a recognized inventory table reference to its numeric ID after all
  original add-object callbacks finish. Unknown ownership extensions and method
  overrides retain their existing behavior.
- Clear only the observed, completed Fearscape capture reference after the
  original exit restores a living target, its death callback and the source
  level. Keep active, failed and uncertain captures intact.
- Reuse neighbor offsets within each recognized square-grid A* search, omit an
  unused score table, and supplement large open sets with an indexed heap. Keep
  the original open-table tie order, callbacks, paths and live terrain checks.
- Recognize Faster's own FBO wrapper in effect-mask batching, including either
  initialization order. Rendering still passes through the GC guard's `use()`.
- Keep chat line measurements weakly keyed when font or width changes invalidate
  wrapping, so discarded text tables can be collected.
- Queue obsolete FBOs until the next normal `use()` call, then release them before
  that call establishes its drawing target. A Lua shutdown guard drains pending
  resources when returning to the main menu. No native library is added.
- Refresh the native wait screen and activity bar at snapshot checkpoints while
  retaining synchronous copying. Input, quit handling and game ticks wait for the
  original call to return. Existing GC pauses can still interrupt drawing.
- Preserve the original save screenshot redraw, crop and decoded RGB8 pixels,
  using a standard PNG stream with level-1 compression. Files can be larger;
  the public capture API and user-screenshot gamma path remain intact.
- Cache only stable hotkey text rasterization, with 512-entry / 4 MiB global
  limits and font, display and interface invalidation. Dynamic UI logic runs normally.
- Batch ordered effect-mask quads using the built-in vertex API. Rebuild the public
  mask FBO and run the original animated shader each frame; no extra FBO is retained.
- Reuse two serializer callbacks within each Savefile, reducing transient Lua
  allocation while retaining the original native serializer and callback ordering.
- Release gzip compression state after character exports through a local,
  guarded replacement. Keep global compression APIs and charball archives intact.
  Set `export_gzip=false` to restore the original character compressor.
- Omit the unused export party, its second object-graph copy and cleanup. Keep the
  recognized Cults save wrapper intact. Set `unused_party_cleanup=false` to restore
  the original preparation, including its random calls and temporary callbacks.
- Avoid clone memo lookups for primitive keys/values, while copying the same graph,
  in the same traversal order, with the same aliases, replacements and metadata.
- Skip dead character-sheet output only for an existing UUID, a stock logged-out
  or hash-invalid consumer, and recognized export methods without custom export
  hooks. Real charballs, late UUID registration and online exports keep their path.

- Use all 5,000 debug-log slots and honor explicit log truncation.
- Restore ranged-hit direction indicators (`hit_warning`), with a configurable
  500 ms interval to reduce repeated indicators during rapid attacks.
- Bound log-text caches per window, invalidating on font or width changes.
- Bound particle/shader bytecode caches, preserving original method environments
  and creating separate closures for independently parameterized effects.
- Combine redundant level/zone-triggered main saves in the same callback batch,
  retaining the position of the **last** request.
- Build delayed-load callbacks without repeated array head insertion, preserving
  their original execution order and the public queue table.
- Reuse generated map-checker source for repeated layer layouts, retaining the
  engine's sorting, compiled-function cache and live entity checks.
- Remove an unused effect scan in Ashes' Devouring Flames callback, when the
  inspected DLC definition is present.

With diagnostics disabled, the save format, save-version tokens, explicit manual
saves, global collector settings, scores, Steam cloud handling and archive writer
retain engine behavior. The FBO guard changes native framebuffer release timing;
it does not change the collector pause/step settings or full-GC save barriers.
This addon targets the `tome` module; it does **not** accelerate the initial boot
module's load-game menu. See [known fixes](docs/known-fixes.md) and
[save/load analysis and next steps](docs/save-load.md) (Chinese).
The [runtime review](docs/runtime-review.md) explains the base-game and three-DLC
review, adopted changes, and rejected prototypes.

## Install

Place the source tree in `game/addons/tome-faster/`, with `init.lua` directly
inside that directory, or build a package and place `tome-faster.teaa` in
`game/addons/`. Use **one copy**: move the original archive outside `game/addons/`
when using this source tree. Enable Faster ToME4 in the Addons menu for new games.
The short name remains `faster`, so existing saves requiring the original addon
resolve to the maintained copy.

Save/load installers check source paths and function line boundaries of the
verified 1.7.6 methods. Unknown earlier overrides or other source layouts are
left intact, with a `[Faster ToME4] ... skipped` log message. These checks are
compatibility guards, not cryptographic verification of installed game code.
Later addons can still replace the methods. The supplied save's nine-addon
combination was tested; arbitrary additional addons remain unverified.

Snapshot refresh falls back when Steam or webview services are present, a debug
hook or existing wait is active, or required native bindings change. It requires
the recognized `save_clone` path. Screenshot encoding requires supported public
GL/SDL APIs on Linux or Windows x86/x64, a desktop GL 3+ context and safe pixel-pack
state; unsupported cases use the original capture. The Windows resolver uses only
already-loaded `SDL2.dll` and `opengl32.dll`. Its Linux fixture checks have passed,
but Windows runtime correctness and performance have not been measured.

The FBO guard installs only when the existing FBO destructor and `use` methods
are native C functions. A prior Lua replacement leaves them intact with a skipped
message. Pending resources wait until the next `use`; if none follows, they stay
until the Lua state closes. It targets the verified finalizer binding defect and
does not eliminate every shader-compilation or waiting stall.

The warning interval uses the engine's real-time millisecond clock, including
its 32-bit wraparound. Timestamps are weakly held outside Map fields and are not
saved. A missing clock leaves emission unchanged. Suppressed warnings create no
emitter and return no values; the stock player caller ignores that return.
Direction changes inside the interval are also suppressed. Fewer visual emitters
consume fewer particle random draws; the old RNG sequence is not preserved.

For an A/B run, these optional engine configuration values are read at addon
startup (restart after changing them):

```lua
config.settings.faster_tome = {
    ai_astar = false,
    ai_astar_heap = false,
    ai_astar_neighbors = false,
    save_coalescing = false,
    load_queue = false,
    map_checker_source = false,
    inferno_nexus = false,
    save_clone = false,
    offline_chardump = false,
    unused_party_cleanup = false,
    export_gzip = false,
    hotkey_text_cache = false,
    effect_mask_batch = false,
    save_callbacks = false,
    compact_save_names = false,
    compact_save_names_base62 = false,
    compact_inventory = false,
    fearscape_cleanup = false,
    snapshot_refresh = false,
    screenshot_png = false,
    hit_warning_interval_ms = 0,
    fbo_gc_guard = false,
}
```

Omitting a boolean field enables that optimization, except
`compact_save_names_base62`, which requires explicit `true`.
Base62 also requires enabled `compact_save_names`. Inventory and Fearscape accept
omitted values or `true`; `false` and invalid nonboolean values leave them disabled.
The warning interval defaults to 500 milliseconds; zero
disables its limit, and invalid values use the default.
These are developer configuration values, not new menu controls.
`ai_astar=false` restores the original A* method. The two subordinate options
disable the heap or neighbor-offset reuse independently; the shared removal of
the unused heuristic-score table remains active while `ai_astar` is enabled.

## Verify and package

Requires LuaJIT with FFI, a C compiler, Lua 5.1-compatible development headers,
zlib, libpng, SDL2, OpenGL and EGL development files, a Lua 5.1-compatible
link library for the shutdown fixture, `pkg-config`, and a local
engine Git clone containing commit
`624a67329fe2ad440c5b344785a9c73fcf22ae63`. Tests read that commit with `git show`;
they do not use or change player saves. Gzip fixtures compile and execute the
two pinned native compressors in a temporary directory. Effect-mask fixtures execute
the pinned GL bindings in a surfaceless EGL context (Mesa software rendering);
serializer fixtures execute the pinned C writer with an in-memory ZIP sink.
Screenshot fixtures execute the pinned native capture and lzlib code and compare
independently decoded libpng pixels. Wait fixtures compile the pinned redraw,
wait and callback paths with controlled SDL/GL endpoints. These are test
dependencies; the addon contains Lua code and uses the engine's existing libraries.
Steam and engine-loading filesystem dependencies remain stubbed.

```bash
export TOME_ENGINE_ROOT=/path/to/t-engine4
export TOME_DLC_ROOT=/path/to/tome4-dlcs
bash tests/run.sh "$TOME_ENGINE_ROOT" "$TOME_DLC_ROOT"
python3 tools/package.py
```

The package is written to the ignored `dist/tome-faster.teaa`. Build and download
archives (`*.teaa`) and generated release checksums stay out of Git; use release
attachments or external artifact storage when distributing packages.
Tests validate behavior and
algorithmic work reduction, including differential clone graphs and character
export compatibility. Full-game save measurements and earlier native/static
profiles are recorded in [VALIDATION.json](VALIDATION.json); hardware GPU and
Steam-cloud timings remain unmeasured.

The 0.2.6 regression passed 384,684 checkpoint clone assertions over 91 graphs,
41 snapshot runner checks, 65 native wait checks, 622 native snapshot installation
checks and 1,229 screenshot checks. All five new suites also passed with JIT off.
The final Linux same-frame session compared 12 PNG pairs containing 9,216,000
decoded RGB bytes, all equal. Formal save timing and screenshot file-size results
are in the [0.2.6 report](docs/snapshot-refresh.md).

The 0.2.7 full regression passed, including 35 additional warning-limit checks
in the existing suite. That suite passed 20,825 assertions with JIT on and off;
see the [warning-limit verification](evidence/faster-tome4-hit-warning/README.md).

Omitting the DLC path skips the Ashes and Cults fixtures explicitly. The supplied DLC tree
uses `<component>/tome-<component>/`; fixture hashes are checked before execution.
For optional synthetic timing, run `tests/bench_runtime.lua` through the same
LuaJIT environment. Performance thresholds are not test assertions.

## Provenance and license

Original author: [yutio888](https://te4.org/users/yutio888).
Fork maintainer: [yutio8888](https://github.com/yutio8888).
Initial import `ded93e38c34af1584224717250c7015295249dd2` preserves all five upstream
Lua files byte for byte. Subsequent changes are this fork's work. The upstream
archive SHA-256 is `030d9d4c86c98986e09ac8864991b7948a84263d9c8e23020ddae266b63882ea`.
[UPSTREAM.json](UPSTREAM.json) retains the original hashes and separate fork
metadata; its import hashes are not checksums of the modified files.

**GPL-3.0-or-later**, as stated in the original addon. See [COPYING](COPYING).
Original notices credit `Copyright (C) 2009 - 2019 Nicolas Casalini`; addon
metadata credits Yutio888. Those credits are retained. No warranty is provided.
