# 本地 profile 实验（0.2.1）

该分支包含两个有限寿命粒子修复、默认关闭的游戏计时器，以及已运行的局部 profile。
基线为 0.2.0 commit `ec0a3d1`，本体固定
`624a67329fe2ad440c5b344785a9c73fcf22ae63`。没有自动迁移玩家的 Fearscape 或背包数据。

## 当前环境与测量边界

本机是 ARM64 Linux，无 DISPLAY／Wayland；游戏附带的 LuaJIT 2.0.2 不支持该架构。
本地 LuaJIT 为 2.1.1761786044，存档包含旧格式字节码。因此本轮没有把玩家存档当作
完整游戏加载，也没有声称测到了玩家机器的 FPS、磁盘保存、Steam 或显示恢复耗时。

实际运行了两类测试：

1. 从固定源码逐字提取 `particles.c` 的初始化、发射、更新、清理和 RNG 包装函数，
   编译本地 C 测试器。使用真实 SDL mutex、SFMT、LuaJIT 回调和顶点缓冲区计算；
   不调用 OpenGL，不模拟多个线程竞争，在线程工作体外批量计时。系统粒子配置来自存档，
   瓦片尺寸设为 64，shader.active 返回 false。原版与修改版使用相同种子与配置。
2. 静态解析主档表、标量和 `loadObject` 引用，用安全生成的 Lua 构造对象图；
   原存档的 1,544 个函数表达式换成独立的无作用闭包，绝不执行存档字节码。
   恢复已知弱值／弱键表，运行固定源码的 `cloneForSave()`，测量克隆、完整 GC 和分配量。
   这个图没有原游戏的 loaded 回调、native 句柄、缓存或类元表，不能等同于原日志中
   34,235 个对象的运行中快照。Lua 堆数字还包含生成的测试构造函数及常量。

粒子测量预热 200 个关键帧，再测 3,000 个；每种条件运行 5 次，交替顺序。
克隆每条件启动 3 个进程，各测 25 次，另取 LuaJIT 每 1 ms 的调用栈样本。
克隆表格先取各进程的中位数，再取三个进程中位数的中位数。
分离测量时只在测试进程暂停自动 GC，随后立即恢复；也测了默认 GC 开启时的克隆。
完整 GC 分别在原图与快照都被持有、以及释放快照后计时。

## 结果与裁决

| 原生粒子工作负载（密度 100） | 稳态 emitter 数 | CPU 中位数／关键帧 |
| --- | ---: | ---: |
| 世界地图的 42 个 notice_enemy，原版 | 42 | 10.588 µs |
| 同上，有限寿命修复 | 0 | 空测试循环约 0.001 µs |
| 孤儿链的 135 个记录，原版预热后 | 114 | 453.720 µs |
| 同上，仅修两种一次性粒子 | 112 | 492.371 µs |
| 在测试器停止该链所有 emitter 后 | 0 | 空测试循环约 0.001 µs |

孤儿链中有限寿命的 20 个 acid 和 1 个 melee_attack 已在预热时结束；其余主要是
111 个 vapour、两个 notice_enemy 和一个 circle。仅删除两个空转 emitter 没有测出该混合
工作负载的提速；五次区间分别为原版 448.6–530.3 µs、修复后 450.2–518.2 µs，重叠明显。
“停止整条链”测的是这些 emitter 消失后的工作量上限，停止动作发生在计时前，不含迁移成本。
这些数值不能换算成整局 FPS，也不足以认定这条链是严重卡顿的主因。

| 安全解码图实验 | class／atomic 计数 | 粒子记录 | 克隆分配 MiB | 克隆 CPU 中位数 ms |
| --- | ---: | ---: | ---: | ---: |
| 基线 | 2,962 | 205 | 14.684 | 21.534 |
| 解除已核验的捕获者引用 | 2,708 | 70 | 14.212 | 20.043 |
| 按实际归属规范化 inventory 引用 | 2,821 | 205 | 14.336 | 21.044 |
| 两项同时处理 | 2,567 | 70 | 13.861 | 21.548 |

背包实验遍历玩家及种子内 NPC 的实际背包和 stacked 对象，共规范化 63 条 table id；
它比只处理玩家身上两个旧背包表更宽，不是已通过完整游戏验收的通用迁移器。
两项同时处理减少约 5.6% 克隆分配，受引用保留的 Object 数由 1,526 降至 1,449。
克隆耗时没有稳定改善；不能把减少计数宣传为已经显著加速。
持有快照时完整 GC 中位数约 5.249 → 4.993 ms，释放快照后约 4.401 → 4.195 ms，
差异较小，也不作为完整游戏 GC 提速结论。

采样热点主要位于递归克隆的 table 遍历、分配，以及测试中显式触发的 GC。
不同进程的 JIT／解释路径分布不同，进一步限制了小幅耗时差异的解释。
profile 中 GC 的占比也不能当作正常游玩时的 GC 占比。

## 在本机复现

需要本体 Git clone、Python 3、GCC、SDL2 开发文件及本机 LuaJIT 5.1 ABI 库。
下面的工具会把生成输入放在指定目录，原存档只读。生成图含玩家数据，保留本地使用。
当前准备脚本针对本次案例结构，含固定 yron 目录和捕获者链假设；不是任意存档的通用工具。
公开仓库提供[聚合测量结果](../evidence/faster-tome4-profile/README.md)，不提供玩家输入。

```sh
python3 -B tests/profile/prepare.py --engine /path/to/t-engine4 \
  --save /path/to/save.zip --out /tmp/tome-profile-data
python3 -B tests/profile/run.py --engine /path/to/t-engine4 \
  --data /tmp/tome-profile-data --results /tmp/tome-profile-results
```

run.py 给每次 Lua 调用配置 TOME_LUAROCKS_ROOT 对应的 Lua 5.1 路径，允许 TOME_LUAJIT
指定解释器。默认运行器的本机编译参数面向 Linux；Windows 不能直接使用这条编译命令。
函数体来自 pinned Git 内容；所使用的本地头文件与 SFMT 会先与同一 commit 比较。
编译日志保留上游旧代码的指针打印转换、const 指针 free 警告，没有为了计时改写核心循环。

原生回归检查包含两种粒子在 0、25、100 密度下的初始完整动画状态摘要一致，
原版持续存活、修复版最终停止。常规 Lua 测试另覆盖计时器的返回值、协程与错误语义。

## 在完整游戏中采集下一批证据

实验 addon 的 `engine.FasterProfile` 默认不安装计时包装。需要时在已安装该实验 addon
的独立游戏副本中，通过开发控制台运行：

```lua
local p = require('engine.FasterProfile'); p.start(); p.reset()
```

执行固定数量的回合／保存／切图后运行：

```lua
local p = require('engine.FasterProfile'); p.report(); p.stop()
```

日志以 `[FasterProfile]` 开头。start() 幂等，可再次调用以补充后来加载的类。
若要覆盖初始读档，在 addon 加载前的配置中设置 `config.settings.faster_tome.profile = true`，
Game superload 会在类就绪后接入；读取完成后 report()/stop()。不要在保存协程尚未完成时
reset，否则无法得到同一时间段的完整计数。

可计时的已加载方法包括 Game.tick、saveGame、save、cloneForSave、截图、成绩登记，
Savefile.loadReal／loadGame／saveGame／saveObject，管线 push／forceWait／steamCleanup，
Particles.loaded 以及显式完整 GC。计时器仅保存固定类别的数字，不保存任何对象引用。

注意解释口径：

- wall_ms 使用 SDL 毫秒时钟，单个很短调用可能记为零；process_cpu_ms 使用 os.clock，
  **可能包括同一进程内的 native 粒子线程**，不能命名为“主线程 CPU”。
- 所有方法记录包含子调用的时间；嵌套调用、协程让出后的等待也在 span 内，不能把所有行
  相加。started 多于 completed 可能是错误或尚未结束的协程。
- 包装器本身有时钟和返回值打包开销，读档尤其如此。应配对测试相同的启用状态，并额外做
  计时器关闭的对照。若为控制台启用 cheat，Faster 的部分缓存／保存合并会绕过；该结果
  只能与相同 cheat 状态比较，不能与正常模式混作 A/B。
- 原生粒子线程仍需 native CPU profiler；Lua 计时器测 Particles.loaded 只覆盖创建提交，
  不覆盖后台粒子更新。磁盘压缩／写入也不能从 Lua 时间行直接剥离。

Fearscape 与背包实验目前仅操作安全解码图，没有进入实际存档迁移流程。
下一轮应在可运行原版本、DLC 和存档依赖 addon 的环境里，再测真正保存／加载、帧时间和
切图；优先按 profile 定位，不能继续把原先的静态“首要嫌疑”当成已经测出的结论。
