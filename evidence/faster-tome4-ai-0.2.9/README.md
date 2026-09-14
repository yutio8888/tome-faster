# 0.2.9 validation evidence

`regression-implementation.log` is the successful complete regression after the
A*, FBO/mask compatibility and weak chat-key changes. It includes 1,243 A*
differential searches with JIT enabled and disabled. `ai-puc51.log` adds 622
searches on PUC Lua 5.1.5.

`effect-guard-first-before.log`, `effect-mask-first-before.log` and
`chat-before.log` are expected failures against the unmodified 0.2.8 production
methods with the new regression assertions. Both FBO/mask load orders now pass
889 native checks each. The complete suite also passes 31 FBO checks, the
533-resource shutdown model and the three-resource reentrant model.

Formal real-game raw batches and source hashes are in
[ai-game-results.json](../../docs/ai-game-results.json); balanced synthetic batches
are in [ai-benchmark.csv](../../docs/ai-benchmark.csv). Details and limitations are
in the [report](../../docs/ai-performance.md). Player save archives, shader/profile
seeds and DLC assets remain local.
