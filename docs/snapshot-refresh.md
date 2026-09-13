# 0.2.6：保存截图编码与同步快照刷新

2026-09-13。固定 ToME 1.7.6 引擎提交
`624a67329fe2ad440c5b344785a9c73fcf22ae63`，沿用 0.2.5 的所有优化。
本次交付两个可独立关闭的改动：保存截图使用较快的无损 PNG 编码；同步复制快照时定期刷新
原生等待画面。完整异步快照、GC 切片和新的后台写入事务仍未实现。

三组组合对照的中位数为保存阶段 **560.44 → 533.47 ms**，主线程 CPU
**457.47 → 425.47 ms**，最长画面提交间隔 **171.40 → 70.49 ms**。
这是本机小样本结果；画面提交间隔不等于输入响应时间或显示器实际呈现时间。

## 分项结果

每项三个交替 A/B 对，共 18 个新进程。每次从相同原始 ZIP 创建独立副本；先正常预热约两秒，
随后保存一次。`detail=false`，生产 GC 保持原状，未在正式计时中停止 GC。
三项实验使用完全相同的六个生产文件及诊断驱动 SHA256；逐次值与哈希见
[结构化结果](snapshot-refresh-results.json)。

环境为 Linux、嵌入 LuaJIT 2.0.2、Xvfb 1280×800 约 30 FPS、Mesa llvmpipe 软件渲染。
没有硬件 GPU、Windows 实机、macOS 或云存档性能验证。

| 实验与指标，中位数 | 关闭 | 开启 | 变化 |
| --- | ---: | ---: | ---: |
| 仅截图：完整 takeScreenshot wall | 50.03 ms | 24.26 ms | 少 51.5% |
| 仅截图：保存阶段 wall | 560.98 ms | 528.72 ms | 少 5.8% |
| 仅截图：保存阶段主线程 CPU | 457.86 ms | 424.55 ms | 少 7.3% |
| 仅刷新：保存阶段 wall | 542.85 ms | 571.90 ms | 多 5.4% |
| 仅刷新：同步 saveGame wall | 159.86 ms | 180.87 ms | 多 13.1% |
| 仅刷新：最长画面提交间隔 | 167.68 ms | 70.92 ms | 少 57.7% |
| 组合：保存阶段 wall | 560.44 ms | 533.47 ms | 少 4.8% |
| 组合：保存阶段主线程 CPU | 457.47 ms | 425.47 ms | 少 7.0% |
| 组合：同步 saveGame wall | 163.36 ms | 144.72 ms | 少 11.4% |
| 组合：最长 Game.display 间隔 | 171.40 ms | 152.49 ms | 少 11.0% |
| 组合：最长画面提交间隔 | 171.40 ms | 70.49 ms | 少 58.9% |

仅刷新会增加总工作：它定期复制、绘制和释放等待画面的背景纹理，并给快照遍历增加检查点。
它的目标是让同步复制期间仍有画面更新。普通 `Game.display` 不在复制间隙运行，玩家操作
仍等同步调用返回后处理。不能把 70 ms 的提交间隔写成“输入延迟降至 70 ms”。

画面指标用 `SDL_GL_SwapWindow` 调用入口测量，覆盖保存阶段开始到首次提交、相邻提交以及末次
提交到结束的间隔。没有增加 `glFinish`、GPU 查询或测量用像素读取。保存阶段含异步 coroutine
处理，但 CPU 指标只计主 Lua 线程，不包含全部 worker/渲染线程。包装原生截图 API 的详细
归因会触发兼容回退，所以正式实验只启用提交探针，保留原生截图 API 身份。

单独归因发现原截图约 50.51 ms，其中 `png_write_png` 约 43.24 ms，像素读取约 0.73 ms；
这些包含关系明确的局部计时只用于定位候选，不与正式对照混合。

## 同步快照刷新

[FasterCloneRefresh.lua](../overload/engine/FasterCloneRefresh.lua) 保留原完整图复制规则、元表、
别名、线程和 `__SAVEINSTEAD` 行为；每完成 512 个表条目检查一次时间。约 16 ms 到期后，
[FasterSnapshotRefresh.lua](../overload/engine/FasterSnapshotRefresh.lua) 短暂进入原生 wait，
利用 enable 自带的一次重绘，立即关闭 wait，随后继续同一次同步复制。
进度条只由局部绘制闭包持有，不注册 Game dialog，不进入存档图。

原生 waiting 状态只跨越绘制，不能覆盖图遍历。这样自定义 `__index` 和最终器在复制中调用
wait 或安装 hook 时仍能获得原有行为。每次刷新前重新检查 debug hook、API 身份、当前 Game、
窗口尺寸及外部服务；不满足条件则停止刷新并完成同一次复制。初始不支持时使用原 clone。
完整边界和失败反例见 [原生审计](snapshot-refresh-audit.md)。

没有 `manualTick`、SDL 事件泵、普通游戏 tick、coroutine yield、额外 full GC 或 GC 暂停。
SDL quit filter 和 web 回调可以直接运行任意 Lua，因此不能靠“暂停游戏”证明安全。
存在 `core.webview` 或 `core.steam` 的运行环境会回退；Windows Steam 客户端可能只启用本次
PNG 优化。未知 clone 覆盖和已有 debug hook 也回退。

正式优化侧每次约 994–995 个检查点，复制中刷新 6–7 次，记录的最大复制检查间隔 16–17 ms。
这不是硬上限：深递归、任意元方法、GC 和驱动阻塞仍可能更久。GC 时点及任意最终器的观察
也无法完全隔离；绘制内新建的任意 C debug hook 不能通过公开 Lua API 重建。

真实图差分 `stutter-snapshot-refresh-final-graph-01` 比较 **127,813 张复制表、509,376 个条目、
27,374 个计数对象**，逐表元数据、键值和别名一致，实际原生刷新命中，回合及 paused 不变。
仅此差分在两份观察之间停止 GC 来稳定弱引用，结束恢复；它不作为常规 GC 性能样本。

## 无损截图编码

[FasterScreenshot.lua](../overload/engine/FasterScreenshot.lua) 只处理精确的 `for_savefile == true`。
原始重绘、裁剪及调用顺序不变。普通用户截图继续走原路径，包括原 gamma 行为。
PNG 仍是 RGB8、非交错、IHDR/IDAT/IEND 格式；按原顺序读取 RGB 并翻转行，通过内置 lzlib
使用 filter None 和 level 1 编码。没有复用旧场景或缓存截图像素。

原生同帧验证 `stutter-screenshot-pixels-v3-01` 每对只重绘一次，再让两种编码器读取同一画面。
**12 对、9,216,000 个 RGB 字节**经独立 libpng 解码逐字节一致，非 IDAT 元数据一致，所有 chunk CRC
校验通过。PNG 压缩字节不同，文件变大：仅截图实验的图片大小中位数 **326,894 → 415,443 bytes**，
约多 27.1%；12 对同帧比较的实际逐图字节数也保存在结构化结果中。

实现只使用公开 SDL/GL API，不访问 userdata 内存布局，不附带原生二进制。Linux 从现有符号
空间解析，Windows x86/x64 从已加载的 SDL2.dll/opengl32.dll 解析六个导出；不加载新 DLL。
Windows 仅通过 Linux 上的解析器与失败路径模拟，未验证 Windows ABI、驱动或实际性能。

要求 desktop GL 3 及以上、默认读取 FBO、无 PBO、正常 FRONT/BACK 读取、零 pack 行偏移和裁剪偏移、
当前窗口及尺寸稳定、仍处于保存截图模式。未知 API 覆盖、重入、无法编码或不支持的上下文
回退至当前原路径。共享像素缓冲最多保留 12,587,008 bytes（2,097,152 像素），本存档的
640×400 图保留 1,536,400 bytes；压缩和组装的临时字符串另占峰值内存。

## 回归、完整性与复现

完整历史套件和新增的 91 张 clone 差分图、41 个 runner、65 个 native wait、622 个 native
刷新、1,229 个截图检查均通过；新套件 JIT 开关均通过。clone 断言数随 hash 遍历序不同，
本次完整套件为 384,684，单独 JIT-off 为 385,724。测试编译固定引擎的真实 C/Lua 源码片段，
fixture SDL/GL 端点与真实窗口验证的范围分别记录，不能混称为 Windows 实机测试。

18 次正式保存均完成，**27 个选定实体、203 个 inventory 物品条目**的保存前后状态相等、回合增量为零。
共 **414 个 ZIP、379,134 个条目**通过 CRC，18 张 cur.png 的 525 个 chunk 通过 CRC/结构和
独立 libpng 解码。诊断沿用 `actors` 计数字段，但筛选条件包括带 talents 的实体；重载样本实际为
1 Player、12 NPC、14 Object，不能把 27 全部称为角色。详见 [完整性结果](../evidence/faster-tome4-snapshot-refresh/save-integrity.json)。

`stutter-snapshot-png-repeat-save-01` 在两次保存之间执行六次正常移动，两次保存前后各自的选定
状态均相等。其完整保存目录（22 个角色归档及 world.teaw 等文件）作为新的重载输入，逐文件
字节一致。`snapshot-png-full-roundtrip-v2-20260913` 成功重载、正常空闲五秒，再经原始
`forceWait` 路径保存并退出；保存与空闲的回合增量均为零。上述两场及最终图差分场的最终输出
另有 **69 个归档和 3 张 PNG**通过校验，见 [重载完整性](../evidence/faster-tome4-snapshot-refresh/roundtrip-integrity.json)。

跨重载的选定状态也通过 [独立比较](../evidence/faster-tome4-snapshot-refresh/reload-state-validation.json)。
原始 UID 字节比较曾失败：固定引擎 `Entity:loaded()` 会重新分配 UID，不能按同号配对。
最终检查按玩家/位置、库存槽位和明确实体引用关系建立 **220 个 UID 的双射**，覆盖
**253 处 UID 字段**（36 处数值改变），并核对 party member key/order。归一后所有选定
内容相等、未映射引用为零。只含 `{uid,class}` 的投影外对象不在完整内容验证范围内；这不能
代替全部持久化字段的语义证明。最早原始 UID 断言失败的重载和采样 probe 不计成功验收。

诊断和测试日志见 [evidence 入口](../evidence/faster-tome4-snapshot-refresh/README.md)。该目录不进入
安装包；只提交源码、汇总与测试日志，不发布存档、玩家完整日志、原始截图、DLC 或本机二进制。

关闭独立选项后重启：

```lua
faster_tome = {
    snapshot_refresh = false,
    screenshot_png = false,
}
```

保留已有 `faster_tome` 设置，只加入需要关闭的键。`save_clone=false` 同时关闭同步快照刷新。
构建仍用 `python3 tools/package.py`，产物仅在忽略的 `dist/`，不提交 `.teaa`。

## 下一步

完整快照切片需要保存事务冻结、消费者边界及弱引用/最终器设计；GC 切片需要等价屏障；新 worker
需要 BEGIN/ENTRY/END/ABORT 协议与退出/错误恢复。0.2.5 已记录删除 GC、提前唤醒 worker 和裁剪
根图的实际反例，本次没有绕开这些边界。原生最终遮罩像素缓存、FBO 背景复制省略和原生等待的
GPU/驱动细分归因仍是独立候选，需在真实目标设备上继续验证。
