# 0.2.3 unused export Party validation

See [design](../../docs/export-cleanup.md) and
[sanitized measurements](../../docs/export-cleanup-results.json).
`regression.log` records the complete final fixture run, including the actual
hash-verified Cults wrapper. DLC files and player save contents are not published.

Run fixtures with a pinned engine clone and an installed DLC tree:

```sh
bash tests/run.sh /path/to/t-engine4 /path/to/dlcs
```

The Cults fixture is `cults/tome-cults/superload/mod/class/Game.lua`, SHA256
`765df32782249dfb0d2db6a80a30c81052b40494456332815d95052ee0aef008`.
Without DLC input, DLC-specific fixture sections explicitly skip.

`diagnostics/` is excluded from the installable addon. Expose the helpers under
their `engine.*` names only in a local diagnostic addon and use disposable saves:

- `FasterPartyExportCheck.run(game)` compares the original temporary-party block
  against omission before actual character export. It blocks real profile orders
  before simulating authentication and restores temporary environments afterwards.
  RNG calls and temporary UID allocation differences are allowed and counted.
- `FasterSaveState.capture(game)` and `check(before, game)` compare selected live
  business fields around an actual normal save, outside the measurement interval.
- `FasterStutterSession.start()` supplies the same phase driver used in previous
  rounds. Performance A/B uses `detail=false, save_only=true`, toggling only
  `unused_party_cleanup`. Use `export_guard_preserving=true` for detailed diagnosis.
  `validate_save_state=true` enables the separate live-state check. The
  `party_export_check` phase invokes the captured online comparison above.

The driver includes earlier optional phases whose helpers live in the preceding
evidence directories. Only summary data is published; no complete exported player
JSON, generated archive or serialized object graph is included.
