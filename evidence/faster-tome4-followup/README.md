# Follow-up evidence after 0.2.2

The production commit is `d4dbf77`. No follow-up candidate is installed by the
production addon. See [plan](../../docs/followup-plan.md),
[measured results](../../docs/followup-results.json), and
[ZIP compression proxy](../../docs/snapshot-next-measurements.json).

`diagnostics/` contains opt-in local helpers, excluded from packaged sources:

- `FasterStutterSession.lua`: isolated action/save phase driver. For the detailed
  save runs, use `detail=true, save_only=true, export_guard_preserving=true`.
  It preserves the recognized export method and records nested timing scopes;
  yielding serializer scopes are not exclusive CPU measurements.
- `FasterGzipBench.lua`: compare original and lzlib gzip output and retained
  native allocation using glibc mallinfo2. This measurement helper is Linux-specific;
  the proposed production workaround uses portable engine lzlib bindings.
- `FasterChardumpCheck.lua`: block all real profile orders, compare actual online
  character exports and recompress captured JSON with the proposed gzip parameters.
  Only summary JSON is printed. Run on a disposable offline save copy.

Expose each helper under the corresponding `engine.*` name in a local diagnostic
addon and call `run(game)` after loading, before actions. The phase driver starts
via `start()` and expects `config.settings.faster_tome.stutter=true`; it includes
automated movement/combat, so use copied saves only. `clone_bench` additionally
requires the previous round's `FasterCloneBench` helper.

The original player archive, generated saves and complete character JSON are not
included. Both gzip verification sessions ended normally without network sends.

To reproduce the compression-only proxy on an existing copied save:

```sh
python3 evidence/faster-tome4-followup/recompress.py /path/to/game.teag > results.json
```

This checks all ZIP CRCs before reading the entries into memory. It measures
compression separately from disk I/O and Lua serialization, without executing
saved Lua or modifying the input archive.
