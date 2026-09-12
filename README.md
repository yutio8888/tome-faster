# Faster ToME4 — maintained fork

Version **0.1.0**, modified 12 September 2026. This fork fixes defects in
[Yutio888's Faster ToME4 0.0.1](https://te4.org/games/addons/tome/faster) and adds
two conservative save/load optimizations for **ToME 1.7.6**.

## Changes

- Use all 5,000 debug-log slots and honor explicit log truncation.
- Restore ranged-hit direction indicators (`hit_warning`).
- Bound log-text caches per window, invalidating on font or width changes.
- Bound particle/shader bytecode caches, preserving original method environments
  and creating separate closures for independently parameterized effects.
- Combine redundant level/zone-triggered main saves in the same callback batch,
  retaining the position of the **last** request.
- Build delayed-load callbacks without repeated array head insertion, preserving
  their original execution order and the public queue table.

The save format, save-version tokens, explicit manual saves, garbage collector,
scores, Steam cloud handling, and actual archive writer retain engine behavior.
This addon targets the `tome` module; it does **not** accelerate the initial boot
module's load-game menu. See [known fixes](docs/known-fixes.md) and
[save/load analysis and next steps](docs/save-load.md) (Chinese).

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
Later addons can still replace the methods; full multi-addon testing is pending.

For an A/B run, these optional engine configuration values are read at addon
startup (restart after changing them):

```lua
config.settings.faster_tome = {
    save_coalescing = false,
    load_queue = false,
}
```

Omitting a field enables that optimization. These are developer configuration
values, not new menu controls.

## Verify and package

Requires LuaJIT/Lua 5.1 and a local engine Git clone containing commit
`624a67329fe2ad440c5b344785a9c73fcf22ae63`. Tests read that commit with `git show`;
they do not use or change player saves. Native graphics, ZIP writing, Steam,
and filesystem access during engine loading are stubbed.

```bash
export TOME_ENGINE_ROOT=/path/to/t-engine4
bash tests/run.sh "$TOME_ENGINE_ROOT"
python3 tools/package.py
```

The package is written to `dist/tome-faster.teaa`. Tests validate behavior and
algorithmic work reduction; no full-game, real-save timing, GPU, or Steam-cloud
benchmark has been performed. See [VALIDATION.json](VALIDATION.json).

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
