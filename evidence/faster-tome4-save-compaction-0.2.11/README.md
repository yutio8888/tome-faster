# Save compaction 0.2.11 evidence

The three new experiments are disabled by default. Inventory saves passed the
predeclared CPU bound; ordinary saves did not establish it. No general CPU pass
or new default size reduction is claimed. See the [report](../../docs/save-compaction.md)
and [machine-readable summary](../../docs/save-compaction-results.json).

## Fixed cohorts

Each directory has its original 30-pair plan, runner, probe, analyzer, complete CPU
results, size results and all 60 session metric rows. The supplied character and
full game-state records are intentionally excluded. `input_sha256` and
`result_sha256` identify the untouched local records from which rows were derived.

- [base62-candidate](base62-candidate/cpu-results.json): base62 and both event
  experiments enabled; ordinary saves. NOTPROVEN, upper bound +2.645285%.
- [decimal-candidate](decimal-candidate/cpu-results.json): decimal retained,
  both event experiments enabled; ordinary saves. NOTPROVEN, +1.550054%.
- [inventory-candidate](inventory-candidate/cpu-results.json): same second
  candidate, following 24 original add-object calls. PASS for saving in this
  workload, +0.086030%. The additions happened before the measured interval.

All 180 sessions were valid, with no trimming, extension or pooling. The primary
metric is RUSAGE_SELF user CPU across the complete save, including worker,
render and particle threads. Main-thread user CPU is secondary. Linux x64 ABI
checks are recorded in [independent-results.json](independent-results.json).

The independent initial review hashes describe the reviewed prototype stage.
Formal authority belongs to the fully populated plans in the three cohort
directories, not to the initial advisor's plan template. The final disposition
is reviewed in [final-review.md](final-review.md).

## Behavior and final code

- [fearscape-results.json](fearscape-results.json) records the actual original
  activation and caster-death exit, native save and no-Faster reload. It removes
  one NPC entry (1,738 B), not a demonstrated whole plane. The inaccurate
  `astar_map_present` fixture field is excluded from conclusions.
- [release-compatibility.json](release-compatibility.json) records all 9 final
  default/explicit-opt-in/old-reader/stock-reader/resave checks. The final stock
  runtime removes every nonofficial gameplay addon, keeps the original official
  DLCs and a diagnostic probe, and adjusts only dependency names in the copied
  `desc.lua`. Archive contents are untouched before loading.
- [candidate-to-release.diff](candidate-to-release.diff) shows the final opt-in
  guards and description changes relative to the measured decimal candidate.
  The event implementation and save algorithm were not otherwise changed.
- [final-production-manifest.json](final-production-manifest.json) identifies
  the code used in those 9 checks. Documentation-only packaging can change the
  archive hash; [package-check.json](package-check.json) verifies final source bytes.
- [regression-final.log](regression-final.log) and the four `final-*-jit-off.log`
  files cover the final source. `regression.log` is the earlier full run.
- [failure-analysis.md](failure-analysis.md) separates the failed base62
  process metric from main-thread and standalone-compressor diagnostics.

Real-save state checks use a bounded projection and UID alias normalization;
they are not a full hidden-object-graph equivalence proof. Complete graph
comparisons occur in the pinned native-writer/stock-reader unit fixtures.

## Reproduction and retained failures

`collect_results.py` produces aggregate artifacts from the existing private
sessions under the workspace's `tmp` directory. It publishes no save archives,
player inventories, screenshots, runtime binaries or complete serialized graphs.
`recompute_cpu.py` recalculates the paired statistics from public metric rows.
The original analyzers additionally check private input hashes, actual execution
order, frozen source and plan consistency. Full gameplay reproduction requires
the pinned engine, dependencies, original DLCs and the local source save.

An early inventory preflight falsely differed because its validator omitted
owner UID normalization and sorted by transient UID. A separate early Fearscape
preflight reentered its scenario during forced redraw and timed out. These
preflights were never formal samples. Their records remain in the original
local directories; the corrected validators/scenario scheduling passed new
sessions. Production logic was not altered to conceal either diagnostic failure.

The initial attempt to start Xvfb also failed to bind its local socket in the
sandbox before any game ran; the permitted local-display run then succeeded.
All owned displays and game processes were closed at completion.
