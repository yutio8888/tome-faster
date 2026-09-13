# 保存快照刷新：原生边界审计

审计基线：ToME 1.7.6，引擎提交
`624a67329fe2ad440c5b344785a9c73fcf22ae63`。以下引擎路径和行号均对应此提交。

初版可在同步 `Game:cloneForSave()` 内定期重绘原生 wait 画面；键鼠、退出、游戏 tick
仍等原调用返回后处理。目标是缩短快照期间画面停更的间隔，不是让玩家在复制中继续操作，
也不保证总保存时间减少。每次刷新单独调用 `core.wait.enable()`，利用它自带的一次
redraw，立即 `disable()` 后才继续复制；不调用 manualTick、forceRedraw 或游戏事件循环。
原生 waiting 状态只存在于短暂绘制内，不跨越复制的执行段。

| 边界 | 源码证据与实现约束 |
| --- | --- |
| 保存顺序 | `game/engines/default/engine/SavefilePipe.lua:103–146` 先执行 push hook、同名保存等待和截图，再同步 clone（125），最后入队、注册保存 coroutine 和 pushed hook。`game/modules/tome/class/Game.lua:2854–2886` 随后保存 world 和导出角色。刷新不能移动这些步骤或提前入队。 |
| 游戏暂停 | `game/engines/default/engine/GameTurnBased.lua:43–52` 即使 paused 仍执行 `engine.Game.tick`；后者在 `Game.lua:292–316` 恢复 coroutines、清理资源、执行 tick-end hooks。冻结来自保留同步调用栈，不是设置 paused。 |
| 绘制 | `src/main.c:652–671` 的 `call_draw` 在 `draw_waiting` 为真时立即返回，跳过粒子新帧通知和 `Game.display`。`main.c:721–744` 同时阻止 wait 时间累积成后续动画补帧。常规游戏 display 会修改 player、控制键和 WASD 状态（模块 `Game.lua:1942–1990`），不可用于复制间隙。 |
| 输入与退出 | 普通输入、tick、音乐与窗口事件在 `src/main.c:1596–1710` 的 PollEvent 循环处理。但 `main.c:294–308` 的 SDL 事件 filter 会直接调用 `Game.onQuit`，并在 1541 注册。`src/wait.c:95–104,199–205` 的 manualTick 会 PumpEvents，可能在复制中触发该 filter；因此刷新不能调用 manualTick。模块 `Game.lua:2757–2769` 的 onQuit 会停跑/休息并写入退出 dialog。 |
| 外部回调 | `src/main.c:772–779` 在 wait 绘制之后仍运行 Steam、Discord、web。`src/web.c:280–405` 可执行 registry 中的 Lua handler，且 `385–394` 可直接执行排队的 Lua 源码；`269–275` 的公共 web API 无暂停接口。私有 `webcore` 不因清空 `core.webview` 而关闭。初版在 `core.webview` 或 `core.steam` 存在时回退。 |
| Steam 与 Discord | Steam 实现由 `build/te4core.lua:37–38` 引用未随本仓库提供的 `steamworks/luasteam.c`；`PlayerProfile.lua:114–118` 可见 Lua sessionTicket 回调，不能证明无修改。固定版本 `src/discord-te4.c:158–180` 的回调只打印，join/spectate/request 均为空。 |
| 在线 profile | `src/profile.c:143–180` 使用独立 Lua state，通过队列交付事件；主游戏在 engine `Game.lua:193–194,231–236` 的 display 中处理事件。跳过 Game.display 也避免这条 Lua 分发路径。 |
| Dialog 与快照图 | `engine/ui/Dialog.lua:30–56` 的 simpleWaiter 注册 Game dialog；`engine/Game.lua:420–428,470–483` 会改 dialogs、输入焦点并执行 hooks。初版使用仅由局部变量与原生 registry 持有的预建绘制闭包，不注册 dialog。 |

原生 wait 的所有权必须精确配对。`src/wait.c:108–163` 在运行 factory 和首次 redraw
之前增加深度；嵌套 enable 返回 false 和新深度，不执行 factory。嵌套尝试应立即 disable
一次；初始刷新失败时使用原 clone，复制中的刷新失败则停止后续刷新、完成同一次复制。
不能更改外层 manual 模式。factory、首次绘制或后续绘制报错都不会自动释放 wait 的纹理、
registry 引用和 hook，调用者必须清理并保留原始复制错误。

`src/wait.c:143–148` 仅在当前无 debug hook 时安装计数 hook；
`enableManualTick(true)`（190–195）会无条件移除当前 hook。`disable`（166–187）
不会清空 `wait_hooked` 和 `wait_draw_ref`，旧所有权还可能导致后续已有 hook 被移除。
因此每次刷新前检查 debug hook、外部服务及原生 API 身份，变化后停止刷新。每次显式传入
预建 factory，以 `1e9` 计数开启 wait，在绘制后直接 disable；这段仅执行短小绘制代码，
不需要启用 manual 模式。每次所有权只清理一次。cleanup 还保存并恢复在绘制内新安装的
Lua debug hook 的函数、mask、count；公开 Lua API 不能重建任意 C hook。

把 wait 限制在绘制内部，避免了复制中 `__index` 或最终器调用 `core.wait.enable()` 时
被误当成嵌套 wait，也避免了复制完成时误删它们新增的 hook。测试验证它们能在复制段获得
正常的外层 wait 所有权；它们主动留下的 wait 和新增 hook 会使后续刷新停止，并保留到原
调用者自行处理。每帧重新创建、复制、删除背景纹理是此设计的成本，必须由实际保存测量评估。

GC 策略保持原状，不增加 full collect，也不暂停 GC。额外执行时间、Lua 栈扩展、原复制
分配和最终器仍可能影响弱表及依赖时间的自定义代码；本方案不承诺任意最终器和弱表的时间隔离。
若任意扩展最终器恰在原生绘制内部运行，它仍可观察到短暂 wait；在此时安装的任意 C hook
也无法通过公开 Lua API 恢复。此限制不能用遍历前的图检查完全消除。
复制中的自定义元方法、深递归、GC 和驱动阻塞也意味着刷新目标间隔不是硬实时上限。

## 可重复验证

[wait_refresh_build.lua](../tests/wait_refresh_build.lua) 在临时目录直接提取并编译固定提交的
`wait.c` 全部函数，以及真实 `call_draw`、`on_redraw`、`event_filter` 和 web 分发函数；
[wait_refresh_fixture.c](../tests/wait_refresh_fixture.c) 替换 SDL/GL、计时和线程端点，并提供
可控的 C drawQuad 错误与 callback 注入。
因此测试验证原生分支、Lua hook、错误栈和引用所有权；不创建窗口，不测真实 GPU、SDL
后端事件时序、操作系统响应或端到端保存性能。

```sh
luajit tests/test_wait_refresh.lua . "$TOME_ENGINE_ROOT"
luajit -joff tests/test_wait_refresh.lua . "$TOME_ENGINE_ROOT"
luajit tests/test_snapshot_refresh_native.lua . "$TOME_ENGINE_ROOT"
luajit -joff tests/test_snapshot_refresh_native.lua . "$TOME_ENGINE_ROOT"
```

[test_wait_refresh.lua](../tests/test_wait_refresh.lua) 两种模式各 **65 checks passed**。
覆盖嵌套 enable/disable、manual/hook 切换和已有 hook
被移除的反例；factory/首次绘制/后续绘制错误与引用释放；普通输入/tick 未分发；真实 quit
filter 在 manualTick 中修改图的反例；仅 redraw 时退出事件保持未 pump、清理后才处理；
实际 web RUN_LUA 在 wait 中修改图的反例。

[test_snapshot_refresh_native.lua](../tests/test_snapshot_refresh_native.lua) 两种模式各
**622 checks passed**。它从固定 class 源码安装真实 FasterClone，再调用生产
FasterSnapshotRefresh.installGame，验证五个必需原生 API 的缺失、Lua 替代及安装后身份
变化；web/Steam 先存在、稍后出现及复制中出现；已有 Lua/C hook、外层 wait、元方法新建
wait/安装 hook；真实 newproxy 最终器在复制段运行并保留新 hook；绘制内部新 Lua hook
在成功和异常 cleanup 后恢复；首次/后续绘制错误、源复制错误与延迟 quit。测试不伪造
debug.getinfo 元数据，并验证 Lua 5.1 弱引用 provenance 缓存不保留已丢弃的 Class、方法与环境。
通用 runner 状态和完整 clone 差分另由 `test_snapshot_refresh.lua`
和 `test_clone_refresh.lua` 验证。
