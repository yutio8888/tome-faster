# Save-size analysis evidence — 2026-09-14

This preserves the isolated prototype measured before production integration.
The later 0.2.10 feature has separate [production evidence](../faster-tome4-save-names-0.2.10/README.md);
these prototype timings are not substituted for the production measurements.

- [Report](../../docs/save-size-analysis.md): conclusions, results and limits.
- [game-results.json](game-results.json): five pairs of full saves, raw timings,
  archive sizes, source hashes and the two original-loader reload checks.
- [offline-results.json](offline-results.json): read-only file/class inventory,
  reversible name changes and seven rounds of compression measurements.
- [source-manifest.json](source-manifest.json): fixed engine and diagnostic hashes.
- [probe](probe/): opt-in diagnostic addon `save-size-probe`; never install it in
  an ordinary playing home. The only candidate change is `Savefile.getFileName`.
- [audit_size.py](audit_size.py): portable offline audit. It does not execute Lua,
  alter the source directory, or write a converted save.
- [run-local.py](run-local.py): the exact local measurement driver, retained for
  audit. Its runtime, Xvfb, seed and source-save paths describe the local test
  layout; adapt those paths before reuse. It was run as `tmp/save-size-20260913/run.py`
  below the engine workspace, with homes in `test-saves/save-size-20260914/`.

The offline audit can be repeated with:

```sh
python3 audit_size.py /path/to/read-only/character-directory /path/to/results.json
```

Use a fresh disposable home for each full-game save, preserve the source save,
and keep the same 0.2.9 addon, original 1.7.6 binary, graphics settings and profile/
shader seeds on both sides. Formal order is recorded in `game-results.json`.
There is one normal save per fresh load after two seconds and at least 30 display
calls; no gameplay input or turns are advanced. The two reload checks disable
compact naming and `faster_tome.load_queue` so the original loader is exercised.

The initial reload preflight failed a too-strict numeric UID check on both sides.
`engine.Entity.loaded` assigns new UIDs, so the final comparison preserves the
bijection and repeated-ID aliases instead. Other recorded state remains exact.
The offline measurement completed and wrote its JSON; its first console summary
then failed because a loop variable shadowed Python's `round`. The reporting
variable was renamed without changing the measurements. Neither preflight was
silently included in the formal five-pair result.

Player save archives, detailed actor/inventory state, game logs, DLC assets and
shader/profile seed data remain local. The archived results are aggregates and
timing samples, not player object graphs. No live test processes remain.
