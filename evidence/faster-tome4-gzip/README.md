# 0.2.4 character gzip verification

See [design and limitations](../../docs/gzip-export.md) and
[sanitized results](../../docs/gzip-export-results.json). Player JSON, raw logs,
player saves and DLC fixtures remain local and are not published.

`regression.log` records the full suite, including the hash-verified Ashes and
Cults fixtures; `gzip-jit-off.log` records the additional interpreter run.
`tests/test_gzip.lua` compiles the pinned native implementations to a temporary
directory using `tests/gzip_fixture.c`. It requires a C compiler, Lua 5.1 ABI
headers and zlib development files; `pkg-config` discovers headers by default,
or set `TOME_LUA_INCLUDE`. The compiled module is test-only and is deleted.

`diagnostics/` is excluded from the installable addon. Its helpers require the
existing local profiling environment and disposable copies of the original save:

- `FasterGzipCheck` exercises the actual installed exporter on a game snapshot,
  captures online orders behind two barriers, compares gzip bytes and selected
  state, then measures two batches of 50 complete exports. Linux `mallinfo2`
  measures native allocations after full Lua GC; no RSS claim is made.
- `FasterChardumpCheck` and `FasterPartyExportCheck` retain earlier output/state
  comparisons and now follow the installed gzip delegate. The old historical
  helpers expect an earlier wrapper upvalue and should not be used with 0.2.4.
- `FasterStutterSession` provides the `gzip_check` phase plus previous phases.
  Copy `FasterSaveState.lua` from the preceding export-cleanup evidence directory
  alongside these helpers. They are not production hooks.

Six successful sessions are `stutter-gzip-v3-{before,after}-pair{1,2,3}-01`.
Configuration: `detail=false, export_gzip=false/true,
phases={"gzip_check","save"}, validate_save_state=true`. Pair order was
after/before, before/after, after/before. The following offline save is a
functional smoke check after extensive warmup/GC, not a cold-save benchmark.

Compatibility sessions are `stutter-gzip-export-compat-{before,after}-01`, using
`detail=false, export_guard_preserving=true, offline_chardump=true,
export_gzip=false/true, phases={"chardump_check","party_export_check"}`.
`gzip-roundtrip-20260913` reloads the optimized third-pair save and saves again.

Excluded initial attempts: `stutter-gzip-after-pair1-01` failed during native
engine startup in the restricted sandbox; `stutter-gzip-v2-after-pair1-01` and
`stutter-gzip-binding-probe-01` rejected the original overly strict `_VERSION`
guard. None is counted as a successful measurement. Xvfb and game execution
required tool-level sandbox escalation for this local environment.
