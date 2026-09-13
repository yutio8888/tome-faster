# 0.2.6 保存截图与快照刷新证据

主结论与功能边界见 [报告](../../docs/snapshot-refresh.md)，完整三组 A/B 聚合见
[JSON](../../docs/snapshot-refresh-results.json)。固定引擎为
`624a67329fe2ad440c5b344785a9c73fcf22ae63`，本目录不进入安装包。

这里只存诊断源码、脱敏统计和测试输出。临时 session home、原始游戏日志、玩家状态全文、
存档、DLC、图片及编译后的 `.so`/可执行文件均留在本地实验目录。

## 入口

- [tests-jit-on.log](tests-jit-on.log)：最后一次完整套件，包含既有功能回归。
- [clone-refresh-jitoff-final-review.log](clone-refresh-jitoff-final-review.log)、
  [snapshot-runner-jit-off.log](snapshot-runner-jit-off.log)、
  [tests-native-jit-off.txt](tests-native-jit-off.txt)、
  [screenshot-jit-off.log](screenshot-jit-off.log)：新增五套测试的 JIT-off 输出。
- [save-integrity.json](save-integrity.json)、[audit-integrity.py](audit-integrity.py)：18 场正式保存、
  414 ZIP 与 18 PNG 的独立验证；程序只输出聚合、计数和哈希。
- [roundtrip-integrity.json](roundtrip-integrity.json)、[audit-roundtrip.py](audit-roundtrip.py)：
  真实图差分场、移动前后重复保存、完整重载/forceWait 再保存，额外 69 ZIP / 3 PNG。
  [reload-state-validation.json](reload-state-validation.json) 单独验证跨重载的 UID 双射与选定内容。
  比较器为 [compare-reload-state.py](compare-reload-state.py)，`--self-test` 验证 UTF-8 字节长度、
  键类型、业务字段差异、引用别名冲突、未知 UID 和无法消歧的实体组。
- [FasterSnapshotRefreshCheck.lua](diagnostics/FasterSnapshotRefreshCheck.lua)：真实 Game 快照
  全图差分和原生等待刷新。只在此图比较中停止 GC，不作为正式性能样本。
- [FasterScreenshotCheck.lua](diagnostics/FasterScreenshotCheck.lua)、
  [compare-png.c](diagnostics/compare-png.c)：同一帧两个编码器输出，经独立 libpng 解码比较。
- [原生测量说明](diagnostics/README.md)、[PNG 实现审计](diagnostics/PNG-CANDIDATE.md)。

## 正式实验

`FasterStutterSession-formal.lua` 是 18 场共同使用的精确驱动副本，安装到运行副本时命名为
`overload/engine/FasterStutterSession.lua`。`run-stutter-batch.py` 依赖历史 `prepare-home.py` 与
`run-session.py`（见 [HANDOFF](../../HANDOFF.md) 环境段），每次创建原始 ZIP 的新副本。
`run-ab.py` 记录实际交替顺序和开关；每次启动都串行等待完成，已有 session 名不能重用。

配置 `detail=false`，只包装原 Game 方法计时；native probe 只记录保存阶段的 swap scope。
不能打开 `screenshot_attribution` 混入正式对照，它包装原生 API 会使 PNG 优化回退。
生产文件在全部 18 场中保持不变，manifest 哈希由汇总与完整性脚本分别复核。

```sh
python3 evidence/faster-tome4-snapshot-refresh/diagnostics/summarize.py \
  /workspace/t-engine4/tmp/worktrees/yron-profile-20260912/tmp/profile/sessions \
  . docs/snapshot-refresh-results.json
```

有效正式 prefix 为 `stutter-save-refresh-v1-{snapshot,png,combined}-{before,after}-pair{1,2,3}-01`。
旧 `stutter-snapshot-v1` 使用了已放弃的整段 wait 原型，`stutter-snapshot-v2` 的生产文件中途变化，
均不纳入。`stutter-snapshot-attribution-01` 仅提供原截图耗时归因。

最终真实图验证为 `stutter-snapshot-refresh-final-graph-01`；最终 PNG 同帧比较为
`stutter-screenshot-pixels-v3-01`。PNG v1/v2 因本地输出 API 错误失败，不计通过。

重复保存与完整重载使用后续 `FasterStutterSession.lua`，不混入上述正式计时。它可在本地
导出选定状态，并在重载后只采集新的状态，随后由独立比较器验证。原生 Entity.loaded 会
重新分配 UID；最初 raw UID 断言失败的 `snapshot-png-full-roundtrip-20260913` 和只采样后
停止的 `snapshot-png-reload-probe-20260913` 不计成功重载。最终有效场为
`snapshot-png-full-roundtrip-v2-20260913`。状态全文只保留在临时 home，不提交 Git。

```sh
python3 evidence/faster-tome4-snapshot-refresh/compare-reload-state.py \
  "$SESSION_HOME" --reference-home "$SOURCE_HOME" --label "$SESSION_LABEL" \
  --require-complete --output "$RESULT_JSON"
```

正式重载要求 session 完成和独立比较同时通过。`reload-probe-state-validation.json` 只说明
停止 probe 采集的那一对选定投影在 UID 归一后相同，明确不计成功运行。

Windows 的符号解析、缺失导出与调用约定仅由 Linux fixture 模拟，不能据此宣称 Windows
实机、ABI、驱动或性能验证通过。所有真实窗口实验均为本机 Linux llvmpipe。
