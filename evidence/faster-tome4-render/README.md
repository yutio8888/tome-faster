# 0.2.5 渲染验证与复现

本目录是本地真实引擎诊断的源码及脱敏结果入口，不进入 `.teaa`。
主报告：[render-save.md](../../docs/render-save.md)，正式聚合：[render-save-results.json](../../docs/render-save-results.json)。
固定引擎与完整游戏环境沿用根 [HANDOFF.md](../../HANDOFF.md)。

## 正式分项 A/B

`P=/workspace/t-engine4/tmp/worktrees/yron-profile-20260912/tmp/profile`，以下目录仅保留本机，不发布 `game.log`、home、存档或角色图。

- 快捷栏：`P/sessions/stutter-hotkeys-v1-{before,after}-pair{1,2,3}-01`。
  `detail=false, render_measure=true, effect_mask_batch=false, save_callbacks=false, hotkey_text_cache=false/true, phases={"move","combat"}, actions=60`。
- 地图：`P/sessions/stutter-map-v3-{before,after}-pair{1,2,3}-01`。
  `detail=false, render_measure=true, hotkey_text_cache=true, save_callbacks=true, effect_mask_batch=false/true, phases={"move","combat"}, actions=60`。
- 两项均三组交替顺序后/前、前/后、后/前；每次经现有 `run-stutter-batch.py` 从原始 ZIP 解压新的 home，完整进程结束后才运行下一次。
- 分项计时只有 Game.display/tick/saveGame 和两个 renderer 的外层 span，无 native LD_PRELOAD，也不修改 JIT 或 GC。
- 缓存 stats 是该进程累计值；移动在预热后开始，预热已产生 21 个标签 miss。不要把其后的累计命中解释为每阶段新增值。
- 实际战斗随机轨迹不同且会在低生命时提前结束，不能用总时间比值表示确定的速度收益。

可复现脱敏聚合：

```sh
python3 evidence/faster-tome4-render/diagnostics/summarize.py "$P/sessions" docs/render-save-results.json
```

脚本只输出 span、缓存计数、动作数量和帧分位数，排除角色名、敌人、坐标、生命、绝对回合、原始动作内容。

## 原生耗时归因

[`render-probe.c`](diagnostics/render-probe.c) 使用 LD_PRELOAD，限定在 Hotkeys.display / Map.displayEffects scope 内记录 `TTF_RenderUTF8_Blended`、`glTexImage2D/glTexSubImage2D` 和 `glDrawArrays`，不插入 GPU 同步。
`FasterRenderProfile.lua` 提供 scope；启用 `render_profile=true` 时必须同时加载编译后的 probe。
编译只用于本机分析，例如 `cc -shared -fPIC -O2 render-probe.c -o render-probe.so -ldl`（需要 SDL2/GL headers）。

本地 `stutter-render-native-baseline-01` 和 `stutter-render-native-optimized-01` 的稳定移动分别有 1260 / 0 次 TTF 光栅化。
这两次用于归因，不作为正式时间 A/B；优化探针时期地图 guard 尚未兼容标准 overlay，不用它证明地图批处理收益。

## 连续画面差分

- [`FasterHotkeysCheck.lua`](diagnostics/FasterHotkeysCheck.lua) 和 [`FasterRenderPixels.lua`](diagnostics/FasterRenderPixels.lua)：实际字体 draw 的完整 RGBA、三个返回值、元数据与 GL 状态；576 个组合、120 帧文字/冷却序列，并包含跨纹理单元绑定反例。
- [`FasterHotkeysDisplayCheck.lua`](FasterHotkeysDisplayCheck.lua)：原版/缓存版完整快捷栏 `display/toScreen`，使用确定性合成 actor、真实 Entity 图标、字体、UI 布局、三种阴影，连续帧检查业务调用和后续绘制。
- [`FasterEffectMaskCheck.lua`](FasterEffectMaskCheck.lua)：原版/批处理完整 Map.displayEffects，原生 target_fbo shader、真实可见性入口，比较最终 viewport 和公开 mask 的连续 RGBA、GL 状态、动画与 FOV 查询；另有关闭 readback 的受控序列提交计时。
- 运行均在一次真实 `Game.display` 返回后进入，使用独立临时资源，不再次推进游戏 display 或规则。

诊断分别使用 `hotkeys_check`、`hotkeys_display_check`、`effect_mask_check` 阶段；入口为所列模块的 `run(game)`。
最终地图全帧会话 `stutter-map-display-pixels-v5-01`：48 帧完整 shader/公共遮罩/FOV/动画/GL 状态一致；另有三组各 120 帧原/优化受控计时，无稳定 CPU 或提交 wall 改善。最终生产将顶点准备移到原生遮罩绑定前，876 个 native fixture 检查包含真实 FBO finalizer 和自定义 FBO 回调顺序。

最终快捷栏全帧会话 `stutter-hotkeys-display-pixels-v5-01`：120 帧、117,964,800 bytes RGBA、8,484 次业务调用，三种阴影各 40 帧；状态及后续绘制一致。

离屏差分在每对比较之外、FBO 为 0 时完整 GC，对内暂停 GC，结束恢复。该隔离用于已实际观察到的原生 `gl_free_fbo` 析构会绑定 FBO 0 的副作用；不改变生产 GC，也不是常规 GC 开启状态下的游戏性能测量。快捷栏诊断另修正了 `core.display.glScale` 自带入栈的调用配对，并验证三个 GL 栈深度最终恢复。

完整 driver 副本：[FasterStutterSession.lua](diagnostics/FasterStutterSession.lua)。诊断断言失败会使 `completed=false`；必须同时检查 `process.json`、PASS 和 `SESSION_COMPLETE`，不能仅看 native exit code 0。

## 回归与修复边界

[regression.log](regression.log) 是最终集成回归，包含固定哈希 Ashes/Cults fixture。
新增 JIT-off：[hotkeys](hotkeys-jit-off.log)、[effect mask](effect_mask-jit-off.log)。保存回调的 JIT 开关证据在 [save-followup](../faster-tome4-save-followup/README.md)。

`stutter-map-v1-*` 和 `stutter-map-guard-01` 是 guard 排查：先发现标准 MapEffect 实例有继承元表，逐条件探针再定位本体 class 模块保留空终端元表。生产现已接受这两种固定本体情况，并新增实际构造 fixture。早期回退样本不进入正式地图结论；v2 是已命中但尚未将准备移到绑定前的中间版本，最终正式数据使用 v3。
失败诊断和互斥锁拒绝的启动保留本地用于排查，不作为成功验收。所有生成 native 共享库、原始 RGBA 和临时 FBO 都不是生产 addon 组件。
