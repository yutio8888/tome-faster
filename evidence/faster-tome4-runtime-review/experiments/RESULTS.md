# Rejected Spiderbot indexing prototype

The candidate-only index preserved ordered differential fixtures and reduced 10-bot fixture visits from 488 to 210, but the standalone membership microbenchmarks below contradicted an assumption that this makes the typical small population faster. Therefore the prototype is NOT in the addon package. The patch reconstructs the attempted implementation and differential fixtures against the pre-documentation runtime working tree; line offsets may need adjustment.

LuaJIT 2.1.1761786044 on this host; 200,000 query batches, 10 bots, 8 candidate cells. Warm JIT, then jit.off/jit.flush. Each timing is CPU seconds; this is not a whole-game benchmark. Checksums matched.

| Implementation | JIT baseline (3 runs) | JIT index (3 runs) | Interpreter baseline | Interpreter index |
| --- | --- | --- | --- | --- |
| nested x/y tables | .014306/.014369/.014390 | .060919/.060231/.060295 | .149324/.148914/.152740 | .121405/.121081/.123958 |
| flat x+y*100 table | .018190/.014607/.014665 | .044785/.044541/.044461 | .151746/.152593/.149330 | .082496/.081377/.081994 |

Both indexes were slower with JIT enabled. Larger bot/candidate populations may cross over, but their frequency and benefit were not established. No default enablement or persistent occupancy cache is justified by this experiment. Run the two Lua scripts with the project LuaJIT/Lua 5.1 search-path setup to reproduce.
