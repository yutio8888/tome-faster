# Production compact save names — 0.2.10

The production helper is `overload/engine/FasterSaveNames.lua`, loaded by the
normal addon startup hook. The diagnostic probe only verifies that helper (or
the opt-out upstream method) and records the normal save pipeline; it does not
replace the namer or serializer.

- [Report](../../docs/save-size-analysis.md): prototype and production results, separately labelled.
- [Production raw results](../../docs/save-names-results.json): all 20 balanced pairs, timings, archive sizes, source hashes and round trips.
- [Source manifest](source-manifest.json): measured production Lua, package and diagnostic hashes.
- [Full regression](regression.log) and [new JIT-off checks](save-names-jit-off.log).
- [Integrity checks](integrity.json): source files untouched, repeated-save state and owned Xvfb cleanup.
- [Probe](probe/), [local runner](run-local.py) and [summary generator](summarize-local.py).

Both variants use the same 0.2.10 package, toggling only
`faster_tome.compact_save_names`. The unchanged 1.7.6 binary runs embedded LuaJIT
2.0.2 on Linux with Xvfb/llvmpipe. FBO protection remains on and the hit-warning
interval stays at its 500 ms default. The built-in profiler is off.

The first five pairs showed substantial timing variance. A fixed additional
15 balanced pairs were then run, and all 20 are reported together; no timing
outliers were discarded. Three preflight sessions are excluded. Each save
starts from the same source ZIP in a fresh home after two seconds and at least
30 display calls. Original-loader checks disable both compact naming and the
addon load queue. One compact save is reloaded and saved again, then reloaded
once more with the original reader. The 40 formal saves and four round-trip
sessions exit normally with no Lua error, matching selected state and valid
archive CRCs. Numeric UIDs are compared by bijection across original-engine
reloads because `Entity.loaded` regenerates them.

The native C fixture checks complete synthetic object graphs. Actual-game
state comparison is a bounded projection of player, actors and inventory, not
a full graph audit. Windows, Steam/cloud saves, other characters/maps and
third-party nested saving are unmeasured.

The runner was executed as `tmp/save-names-20260914/run.py` under the engine
workspace. Its runtime, Xvfb, seed and dependency paths describe that local
layout; adapt them before reuse. Homes reside outside tmp in
`test-saves/save-names-20260914/`. The summary tool accepts the local trial root
as its first argument. The measured package precedes documentation updates;
final package validation checks every production Lua file against the measured
manifest. Runtime code is unchanged between measurement and delivery.

An initial full-suite command used the wrong local DLC path and stopped at the
fixture's source hash check. The corrected invocation used `/workspace/tome4-dlcs`
and passed the whole suite; the initial log remains local. Save archives, raw
object projections, runtime assets and full game logs remain local. Neither
engine source nor protected player-save baselines were changed.
