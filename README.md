# Faster ToME4 — rendering and save optimizations

Version **0.2.5**, modified 13 September 2026. This fork fixes defects in
[Yutio888's Faster ToME4 0.0.1](https://te4.org/games/addons/tome/faster) and adds
conservative save/load and runtime optimizations for **ToME 1.7.6**.

This release adds bounded hotkey text caching, ordered effect-mask geometry
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
[follow-up plan](docs/followup-plan.md). Snapshot slicing and GC rescheduling
remain unimplemented; the new report records measured limits and counterexamples.

中文说明：[性能问题、修复方案、测量指标与文件清单](docs/faster-tome4-performance-report.md)。
Published evidence: [profile results](evidence/faster-tome4-profile/README.md).
Package build instructions and version history: [releases](releases/README.md).
Full-game save A/B and complete loaded-graph equivalence have now been tested on
one supplied save. GPU/Steam testing and automatic old-save reference migration
remain outside this release. Player archives and generated save graphs stay local.

## Changes

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
- Restore ranged-hit direction indicators (`hit_warning`).
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

With diagnostics disabled, the save format, save-version tokens, explicit manual saves, garbage collector,
scores, Steam cloud handling, and actual archive writer retain engine behavior.
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

For an A/B run, these optional engine configuration values are read at addon
startup (restart after changing them):

```lua
config.settings.faster_tome = {
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
}
```

Omitting a field enables that optimization. These are developer configuration
values, not new menu controls.

## Verify and package

Requires LuaJIT/Lua 5.1, a C compiler, Lua 5.1-compatible development headers,
zlib, OpenGL and EGL development files, `pkg-config`, and a local engine Git clone containing commit
`624a67329fe2ad440c5b344785a9c73fcf22ae63`. Tests read that commit with `git show`;
they do not use or change player saves. Gzip fixtures compile and execute the
two pinned native compressors in a temporary directory. Effect-mask fixtures execute
the pinned GL bindings in a surfaceless EGL context (Mesa software rendering);
serializer fixtures execute the pinned C writer with an in-memory ZIP sink.
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
