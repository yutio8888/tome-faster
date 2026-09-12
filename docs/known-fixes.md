# Known addon fixes

Modified 2026-09-12. Scope: Faster ToME4 0.0.1 at
`ded93e38c34af1584224717250c7015295249dd2`; engine source verified against
ToME 1.7.6 commit `624a67329fe2ad440c5b344785a9c73fcf22ae63`.
Original addon author: Yutio888. Engine-derived code retains Nicolas Casalini's
copyright and GPL-3.0-or-later notices. This work is GPL-3.0-or-later.

- `overload/engine/CacheList.lua`: explicit count and correct modulo indexing
  use every requested slot, including capacity one. `enumerate(nb)` returns
  chronological entries, limiting to the oldest `nb` when supplied;
  `truncate(nb)` removes oldest entries and retains the newest `nb`. Truncating
  does not resize capacity. Empty peeks return index zero and nil. Capacity
  must be a finite positive integer; nil entries are rejected.
- `hooks/load.lua`: keep the original print function for stdout and argument
  stringification. Import its startup backlog, then transfer newly buffered
  entries into a 5,000-entry ring. No ring enumeration, argument reformatting,
  or duplicate log construction occurs per print. Getters drain pending entries
  too, including entries left when stdout throws. Explicit truncation works,
  including zero; enumeration is performed only on `get_printlog()`. The pinned
  upstream buffer normally has one entry to clear per call. Importing a large
  startup backlog still uses upstream's potentially quadratic clearing once.
- `superload/engine/Map.lua`: retain the original particle emitter; ranged-hit
  direction indicators and all emitter arguments/returns work upstream-style.
  Version 0.2.0 also installs the separately documented map-checker source cache.
- `superload/mod/dialogs/ShowChatLog.lua`: each dialog owns a strong FIFO cache
  of at most 128 generated text entries. Font identity or rendering width changes
  discard cached textures and old wrapping measurements, even at the same
  scroll position. Unchanged rendering parameters retain the pinned scroll,
  clipping, line-size adjustment, source metadata, and shifty-scroll behavior.
- `hooks/load.lua`: the two `loaded` methods each receive a local `loadfile`
  override whose environment inherits their original environment via `__index`.
  Each cache holds at most 256 successfully compiled definitions, FIFO. Bytecode
  is cached; a fresh closure is produced on each hit, preserving independently
  assigned environments and callbacks retained by earlier instances. Loader
  return counts, nil holes, errors, and extra return values are preserved.
  Failed compilations are retried. Custom closures with upvalues or functions
  that cannot be dumped are uncached. Non-string paths and extra loader arguments
  bypass and clear the cache. `config.settings.cheat` (the pinned engine's debug
  setting) also bypasses and clears it. Global `loadfile` is unchanged.

## Regression command and result

From this checkout, run in one shell invocation (the second test argument may
point to another local clone containing the pinned engine object):

```bash
TOME_LUAJIT="${TOME_LUAJIT:-$(command -v luajit)}"
TOME_LUAROCKS_ROOT="${TOME_LUAROCKS_ROOT:-$HOME/.local/share/tome4-luarocks}"
env \
  LUA_PATH="$TOME_LUAROCKS_ROOT/share/lua/5.1/?.lua;$TOME_LUAROCKS_ROOT/share/lua/5.1/?/init.lua;;" \
  LUA_CPATH="$TOME_LUAROCKS_ROOT/lib/lua/5.1/?.so;;" \
  "$TOME_LUAJIT" tests/test_existing.lua . "$TOME_ENGINE_ROOT"
git diff --check
```

The regression suite reads pinned source with `git show` and executes actual
addon code, the upstream print-buffer functions, upstream `setScroll`, and
upstream particle/shader methods in isolated environments with minimal native
and rendering stubs. It covers ring partial/full/wrapped states and truncation,
stdout arguments, nils, stringification, backlog, errors, reentrant logging,
loader failures/recovery/returns/environments/eviction/debug bypass, particle
and shader parameter isolation, hit warnings, scroll parity, font/width changes,
chat eviction, and survival across full GC.

Validated with Lua 5.1 / LuaJIT 2.1.1761786044: all 20,790 assertions passed.
`git diff --check` passed. Translation gates do not apply. Save/load integration is documented separately.

## Remaining limits

No full game, GPU, FPS, memory benchmark, or multi-addon compatibility run was
performed. The bounds limit entry counts, not bytes: a single generated text
entry or compiled definition can be large. Existing engine line-size metadata
and shader/GPU caches are outside these cache bounds. Mutable text objects or
in-place font changes with unchanged identity require external invalidation;
the cache assumes text keys and font objects represent stable rendering inputs.

Normal-mode resource edits or mount changes do not invalidate cached bytecode;
restart or enter debug mode before reloading edited definitions. Runtime errors
from executing successfully compiled definitions do not evict bytecode. Source
compilation is avoided on hits, but bytecode loading still allocates a fresh
closure. Native particle-thread `luaL_loadfile` and GPU shader compilation remain
unchanged. Methods that captured a loader in a local upvalue bypass this override;
subsequent addons replacing the methods may supersede it. Like the original
addon, this changes the existing method's environment, so aliases of that same
function see the scoped override too.

The print getter returns a chronological snapshot rather than upstream's live
outer buffer; callers should not mutate it to change logging. Historical entries
beyond 5,000 cannot be recovered by requesting a larger truncation count. Pending
entries during a failing print drain on the next getter, truncation, or successful
print. A separate addon replacing these global logging functions or changing
upstream buffer semantics requires integration testing.
