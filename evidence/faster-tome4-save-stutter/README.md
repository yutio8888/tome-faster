# 0.2.2 full-game validation

See [design](../../docs/save-stutter.md) and [sanitized samples](../../docs/save-stutter-results.json).
The latter records six independent save sessions, ten alternating clone pairs,
complete loaded-graph equivalence, captured character-export equality, and a
save/load/save roundtrip. No player archive or serialized character sheet is published.

`regression.log` is the final complete fixture run with Ashes installed. The engine
commit is pinned in each test. Clone assertion counts vary with hash iteration.

`diagnostics/` contains local verification helpers, excluded from the installable
addon. To reproduce on a disposable offline copy in the pinned engine, expose a
helper as `engine.FasterCloneBench` or `engine.FasterChardumpCheck`, then call its
`run(game)` after loading and before taking any turns. The clone helper compares
the complete live graph and times ten alternating pairs. The export helper blocks
profile orders before simulating authentication, captures two online outputs,
compares decoded content, and restores authentication, function environments and
RNG entry points even if a check fails. Both print summary JSON only.

Save timings use normal `game:saveGame()` with two seconds of warmup and unchanged
graphics/character-sheet settings, alternating fresh processes with
`faster_tome.save_clone` and `faster_tome.offline_chardump` both false or both true.
Measure the synchronous call separately from eventual save-pipe completion.
Do not wrap `dumpToJSON` for those timings: an unknown wrapper intentionally makes
the conservative export optimization fall back to the original path.

These measurements are specific to the supplied save, offline LuaJIT 2.0.2 and
llvmpipe. They do not measure hardware GPU rendering or Steam cloud behavior.
