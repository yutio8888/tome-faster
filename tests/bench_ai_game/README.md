# Real-map A* measurement fixture

This is a separate diagnostic addon, short name `faster-ai-bench`. Normal Faster
installation does not load it. It targets Linux ToME 1.7.6 and its embedded LuaJIT
2.0.2; it uses libc clocks, with no native preload or debug profiler.

Use an isolated runtime and a **new disposable home outside temporary storage**.
Copy this directory to that runtime's `game/addons/tome-faster-ai-bench/`, install
the candidate Faster addon and all addons required by a copy of the chosen save,
then add `faster-ai-bench` to **that copy's** `desc.lua` addon list. Preserve the
source save unchanged. Never enable this fixture in a normal playing home.

Settings in the disposable home's `.t-engine/4.0/settings/` must include:

```lua
cheat = true
disable_all_connectivity = true
allow_online_events = false
tome.upload_charsheet = false
faster_tome = {profile=false,stutter=false,session=false}
faster_ai_bench = true
```

Launch the original executable with `--no-steam --no-web --flush-stdout --home
/absolute/path/to/disposable-home -Mtome -ucharacter-directory`. Use the same
graphics settings and shader/profile seeds across sessions. The fixture waits
for 30 display calls and two seconds after load, then measures on the paused
map and exits the engine directly. It does not send gameplay input or request a
save. Verify hashes of every copied save file before and after the process.

Collect stdout lines beginning `[FasterAIBench] ` as JSON. Require exactly one
`setup` and one `complete`, no `error`, no game Lua errors, a successful process
exit and unchanged save hashes. Keep source hashes and runtime/save archive
hashes beside each session. Repeat in fresh homes; do not merge a preflight into
formal measurements.

Selection and timing are defined entirely in
[FasterAIBench.lua](overload/engine/FasterAIBench.lua). Short, medium and long
groups contain up to eight paths of length ≤3, 4–15 and >15. An unreachable
group is populated only when walkable targets return no path. Four variants use
the same actual map/actor/native cache. The production method and default FBO
guard must be installed; the fixture reports effect-mask counters separately.

The batch checksum consumes returned paths. CPU and wall time are measured only
at batch boundaries; CPU is the main Lua thread's time. GC stays enabled for
timing; memory measurements stop GC only for a separate single batch. Each
variant occupies each timing position twice over eight rounds. Store raw batch
means, summarize within each session, and report the median across sessions.
Do not interpret repeated queries as independent maps or as game-frame samples.

The published protocol and raw formal data are in
[ai-game-results.json](../../docs/ai-game-results.json). The tested map had no
unreachable walkable targets and no active effect-mask draws during this idle
window; those cases are covered by other fixtures, not by this real-map sample.
