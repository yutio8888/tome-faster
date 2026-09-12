# 下一轮：快照与保存管线的 addon 优化可行性

分析日期：2026-09-12。基线为 Faster ToME4 0.2.2（`d4dbf77`）及 ToME 1.7.6 引擎提交 `624a67329fe2ad440c5b344785a9c73fcf22ae63`。本文件是后续方案评估，**所列候选尚未加入生产 addon，也不代表已经取得对应游戏性能收益**。讨论不以代码复杂度为否决理由；验收标准是存档和游戏状态等价。

最值得先做的是**按明确依赖缩小 Game 根快照，并继续使用本体序列化/写盘管线**。第二条可行路线是**保持保存时点一致、将快照工作切片，允许界面刷新**。现有后台线程不能直接承担任意 Lua 对象复制，也不能安全地每生成一个对象就提前唤醒；更彻底的流水保存需要 addon 自己实现写入协议。

## 现有工作实际发生在哪里

| 阶段 | 源码入口 | 执行位置与约束 |
| --- | --- | --- |
| 截图、完整对象图快照 | `engine/SavefilePipe.lua:110–166` 的 `push`，`engine/class.lua:236–265,362–366` | 同步主线程；`push` 返回完整 clone，ToME 随后还用它进行 Party/export 处理 |
| 保存前回调和对象序列化 | `engine/Savefile.lua:142–160` 的 `saveObject`，`engine/class.lua:443–478`，`src/serial.c:444–511` | 主线程 coroutine；每个对象调用 `onSaving`、`save`，整次 C `toZip` 不可中断，然后 yield |
| ZIP 压缩和落盘 | `src/serial.c:160–224` 的 `thread_save` | SDL 后台线程；只收到文件名与已生成的字节 buffer，不接收 Lua 表或 Lua 函数 |
| 完成、校验、回调 | `engine/SavefilePipe.lua:186–287` | 生产所有请求后调用 `threadSave`，等待文件完成，再做校验、`on_end`、`on_done` |

`engine/Game.lua:292–310` 每次 tick 恢复保存 coroutine；tick 不等于显示帧，因此“每对象 yield”并非“每对象等待下一帧”。`core.wait.manualTick(1)` 只是等待界面计数，不是将对象搬到工作线程。

本轮新增三次真实存档细分测试中，0.2.2 首次保存的 `cloneForSave` 为 **114.50 / 112.87 / 103.92 ms**，截图约 **49–51 ms**。这些包含首次运行和当时 GC/JIT 状态，不能拿上一轮充分预热的 **73.08 ms** 克隆微基准替代。`saveObject` 跨 yield 的 wall time 也不能当作其独占 CPU 时间；应另外记录每个 `save`/`toZip` 的原子执行片段。

## 已得到的文件与压缩证据

读取上一轮 `stutter-opt-after-pair3-01` 生成的 `game.teag`，没有启动或推进游戏。结果见 [snapshot-next-measurements.json](snapshot-next-measurements.json)。

- 2,853 个 ZIP 条目，未压缩 **6,630,308 bytes**，ZIP 总长 **2,657,469 bytes**。
- Object：1,526 条，2,466,381 bytes；Map：10 条，1,937,829 bytes；NPC：67 条，585,477 bytes；Particles：205 条，445,835 bytes。这是实际保存内容，不能仅凭“地图已离开”或“粒子属于显示”直接删除。
- 真实完整快照中的 127,833 张表与 ZIP 条目计数不同：普通表内联写入，一个类对象才通常形成独立条目，两个数字不能直接相减作为可裁剪数量。
- 文件确实包含 Dialog、Button、Textzone、KeyBind、Mouse。反向引用发现 Dialog 从 Player 的一个 `dialog` 字段可达；不能在克隆时将所有 UI 类型整体排除。

把每条原始未压缩数据预先读到内存，用系统 zlib 1.2.13 单独重压缩（raw deflate、memLevel 8、默认 strategy，2 次预热、9 次交替测量）：

| 压缩等级 | 压缩 wall 中位数 | 压缩数据总长 |
| --- | ---: | ---: |
| 1 | 53.69 ms | 2,398,680 bytes |
| 4（本体默认） | 62.38 ms | 2,292,601 bytes |
| 6 | 79.24 ms | 2,231,979 bytes |

这是**压缩代理实验**，不含 Lua 序列化、CRC、ZIP 头、磁盘、线程调度、云同步，也不是游戏内保存 A/B。等级 4 的压缩字节总长与原 ZIP 完全一致。等级 1 约节约 **8.69 ms**，压缩数据增加 **4.63%**；即使能直接配置，也主要缩短后台尾部，不能消除约百毫秒的同步快照。

## 方案 A：依赖明确的根快照裁剪，优先级最高

本体 `mod/class/Game.lua:744–748` 使用 `defaultSavedFields(...), true` 保存 Game 根字段；默认集合在 `engine/Game.lua:123–137`。完整 `cloneForSave` 则不看这些限制，连不会直接写入 Game 根对象的界面、临时数据等也会遍历。

可做一个限定版本的 `FasterSnapshot`，首先只缩小 **Game 根边**，保留所选根字段之下的完整图；先不叠加几十种类的递归黑名单。目标是减少遍历和表分配，也间接减轻快照后的 GC。实际可裁掉的表数及时间需要测量，暂不能给出收益百分比。

具体实现顺序：

1. 建立“保存消费者依赖”描述，不只抄 `defaultSavedFields`。除写入字段，还保留 `Game:save` 读取的 `real_starttime`/`last_update`，后续 metadata 读取的 `__mod_info`，以及 `getSaveDescription`、`isLoadable`、`isTainted`、Party/export、保存 hook 会读取的根字段。对所有受支持版本逐个列明来源。
2. 在独立诊断中统计各根字段可达表、共享表、元表及异常引用；以集合差计算独占可省部分，不能把多个子树表数相加。测试时同时跑完整 clone 和候选，对本体实际产生的保存条目进行图级比较。
3. 通过 `Game` superload 安装，保存源方法、必要 helper 和 hook 分发器均匹配时启用。遇到未知 `Game:save`、`onSaving`、`defaultSavedFields`、保存 hook 或依赖描述时整次退回完整快照。未知方法只有方法来源相同仍不够；可随包固定源码哈希或版本清单。
4. 普通值与对象引用使用统一 memo，原键遍历顺序保留；保留元表和继承方法，不能把对象改成只含数据的普通表。返回值仍满足 `SavefilePipe.push` 和 `Game.saveGame` 的完整下游合同。
5. 首阶段默认关闭，至少覆盖当前存档的正常保存、战斗中保存、切层、角色死亡和在线导出；对同一输入执行一段确定回放，再分别保存、重载和继续回放。

有三处不能省略的陷阱：

**实际 C 过滤规则并不等于 Lua 代码看起来表达的规则。** `src/serial.c:473–486` 先读取 allow/disallow，然后 `disallow2` 存在时重新赋值 `skip`，会覆盖前面的判断，而不是与它合并。这里还有一层细节：`class.save` 先通过继承读取 `self._no_save_fields` 合并 filter，然后临时清空对象元表，才再次读取 `self._no_save_fields` 作为 disallow2。因此仅从类继承该表通常不会触发覆盖，而实例持有自己的表时会触发。不能据此推断所有 Actor 的默认过滤均已失效。过滤表里的值是否为 nil 也比布尔真假更重要。不能顺手修正这个行为后声称存档等价，更不能按想象中的 allow 白名单裁掉实际被写出的字段。

**序列化不读取的字段，`save`/`onSaving` 仍可能读取。** 例如 Level 的 `onSaving` 会清空 `last_iteration`；Projectile 的 `save` 会借助 `game.level.map` 以及 line userdata 导出线路并写回临时数据。任意 addon 的 Lua 回调依赖不能静态从最终 ZIP 推出。为此可以设计 addon 可选的依赖注册接口，例如每种 class 声明 clone 时额外保留字段及其回调来源；未声明的扩展回退完整图。不要为了发现过滤器而在活跃对象上“试调用一次 save”，那会重复副作用。

**删边会改变克隆顺序语义。** 本体 `__SAVEINSTEAD` 若遇到已在 memo 的 replacement，会返回原 replacement，而不返回 memo 中的克隆；此前恰好经过的“不保存边”可能决定这个分支。`__threads` 若值此前已经被 memo 记录，也不是简单保留原引用。第一阶段应审计这些特殊引用是否跨越裁剪边；不能证明等价的图直接退回完整 clone。单纯保证最终数值相同不足以证明后续回调操作的是同一类引用。

进一步按类字段缩小图仍然可行，但需要扩大上述依赖描述到每个 `save`/`onSaving` 实现；收益应先由诊断确认。`_no_save_fields` 表本身及方法可以从类元表继承，须分别建模清空元表前的继承读取与清空后的 raw 读取。

## 方案 B：冻结逻辑、切片快照，优先级第二

可以保持一份完整图的语义，将递归改成显式工作栈，每片执行约 1–3 ms，然后允许界面处理和重绘。这条路线主要降低最长停顿，**不减少总工作量**。

需要把“保存事务”做完整，而不是只在递归中插入 `coroutine.yield()`：

- `SavefilePipe.push` 必须同步返回 clone，`Game.saveGame` 当场使用它；普通同步调用也不能任意跨 C 边界 yield。因此 addon 需要接管保存事务调度，或者在受控等待界面内推进状态机，直到快照完成才回到原调用者。
- 在第一片前记录保存时点，停止 run/rest，锁住会改变角色、世界、物品、任务、保存 token 的输入和定时回调。只读显示可继续，但 `display` 也可能更新 Lua 动画状态/粒子状态；所有会影响候选保存图的写入都须延后或从一开始快照化。单设 `game.paused=true` 不是写屏障。
- 必须保存并恢复原 paused 状态、键鼠处理器、tick-end 队列顺序；失败、退出、第二次保存、切层和 `forceWait` 都要通过同一个事务状态机，不得丢弃回调或将 autosave 合并到不同回合。
- 元表、弱表、别名和原遍历顺序须与完整 clone 保持一致；分片期间 GC 可能清掉弱键/弱值，从而改变下一片看到的图。强引用暂存可稳定图，但本身改变弱可达性；需要明确界定基线时点，做受控 GC 差分测试，而非只看最终 ZIP 能否打开。

对于回合制游戏，短时间冻结规则推进、持续刷新保存进度，有机会把约 100 ms 连续停顿拆成多个小片；这不意味着可以一边战斗改变对象一边读取同一份未冻结图。后者需要可靠的写屏障。

通用 Lua `__newindex` 不能提供这种写屏障：已有键的赋值、`rawset`、`table.insert/remove`、C 函数写表都可能绕开它。把每张表替换为代理还会改变 `pairs`/`next`、表身份、C API 和 userdata 消费者。因此“允许游戏继续推进 + 延迟复制”需要经过审计的所有修改入口、版本化数据结构或原生运行时支持；不能将一个元表补丁当成完整 copy-on-write。

## 方案 C：序列化与写入管线重做，可行但应先量化收益

### 继续使用原 C serializer 的范围

已有 `Savefile:saveObject` 每对象 yield。可通过 addon 把调度改为时间预算的批处理：保持同样 LIFO 顺序、同样 `onSaving/save` 调用次序，一个 tick 内处理若干对象，到预算后让出。它可能减少 2,853 次 coroutine 恢复开销，也可能增大尾部帧；应同时测每片 p95/p99 和总完成时间。大型对象的一次 C `toZip` 仍不可抢占，单个调用超过预算时该方案无能为力。

先记录每个类、每个对象的 `toZip` 时长和大小，再决定是否值得写 Lua encoder。当前 `saveObject` 外层跨 yield 的 126–130 ms wall 不能证明某个 `Map` 的 C 原子调用很长。

### 不能直接提前唤醒本体线程

`core.serial` 只公开 `new`、`threadSave`、`popSaveReturn`，没有 `appendBuffer`、结束 archive 标记或压缩参数。线程发现队列暂空就关闭 ZIP，清空 `last_zipname/last_zf` 并报告完成；这些全局状态同时参与主线程 `serial_new` 创建后续对象。

因此每对象调用一次 `threadSave()` 会把“暂时没生产完”误当作“文件已完成”。即使只在一个 archive 序列化结束时唤醒，然后立刻生产下一个 archive，也会让主线程修改全局 writer 状态与线程清理竞争。需要明确的生产者/消费者协议，不能靠“通常生产得比压缩快”规避。

### 纯 Lua addon 自己写兼容 ZIP

纯 addon 确实可以另建 writer，而不改存档格式：

1. 接管 `class.save` 使用的 serializer 工厂，按原 `loadObject`/`setLoaded` 格式生成同样的 Lua entry；复用原 `Savefile` 的对象队列、文件命名和自定义 `save` 入口。
2. 保持 class 对象引用、普通表的内联行为、self 占位符、函数字节码和 `_no_save_fields` 的实际语义。不能将普通表的共享引用“改进”为新协议：原加载结果及 addon 兼容性可能因此变化。
3. 通过公开 `fs.zipOpen` 与 `zip:add(name, data, level)` 写 `.tmp`。这支持指定压缩等级（`src/physfs.c:235–276`），但压缩发生在调用它的主线程，可按条目切片。它是可实现的兼容方案，性能是否更好尚无证据。
4. 关闭后验证所有条目、CRC、交叉引用以及 metadata，再发布正式文件，保留旧存档到成功阶段。接回 `pipe_types`、重复保存、saveversion、`on_end`、md5、Steam cloud 和退出等待；不能只更换一个 ZIP 函数。

纯 Lua encoder 可以使用 `table.concat` 和批量字符串转义，避开 `src/serial.c:338–363` 逐字符写入；也可能因 Lua 分配和函数 dump 更慢。它值得做独立字节/加载差分及局部基准，不能因本体是 C 就假定没有空间。

已有本体 `checkValidity` 只验证 `main` 能打开（`engine/Savefile.lua:747–765`），这不足以验收新 writer；应补充全条目检查和完整重载。`.tmp` 到正式文件的替换还要分别验证 Windows/macOS/Linux 及文件占用，不能假定任意平台具有相同的 rename 语义。

### 真正重叠序列化与压缩

若想保留后台 CPU 并逐批释放 buffer，需要原生 worker 接口或可用的独立进程桥。正确协议至少含 `BEGIN_ARCHIVE`、`ENTRY`、`END_ARCHIVE`、`ABORT`、有界队列背压和完成/错误回传；worker 只接收不可变字节，不得访问主 Lua VM 的表。

技术上可把这样的库与 addon 配套分发，而不编辑引擎源码；但它不再是“只安装一个可移植 Lua .teaa 就能工作”的方案，需要实际验证引擎允许的动态库加载方式、LuaJIT/SDL/PhysFS ABI、Windows/Linux/macOS 二进制和游戏完整性/云保存流程。现成公开 `core.serial` API 不提供这些能力；不应通过硬编码地址、修改 C 静态全局或跨线程调用同一个 Lua state 冒充可维护实现。

缓存已序列化条目/增量保存也不是无条件复用：文件名含表地址，新快照地址会变化，加载引用需一致；本体 `save/onSaving` 仍要保持调用及副作用，且对象内部嵌套表可能原地变更，class 对象上的 dirty 标记捕获不全。可在新 writer 内缓存规范化结构与引用 ID，但必须建立完整失效策略，并比较 hash/规范化成本与重新序列化成本。

## 推荐验证与落地顺序

| 顺序 | 工作 | 通过后才实施的条件 |
| --- | --- | --- |
| 1 | 真图根字段可达性与每对象原子序列化计时 | 找到确实可省的子图/长片段；确认首存与热存差别 |
| 2 | 根级依赖快照原型 | 图别名、特殊引用、消费者输出、在线资料、重载后回放全部等价 |
| 3 | 同一保存点的切片事务 | 保存期间无回合/规则状态推进，输入/退出/错误处理完整，长帧改善 |
| 4 | 原 C serializer 时间预算调度 | 总耗时与最长片段一起测量，保持回调次序 |
| 5 | Lua encoder + 标准 ZIP writer 或配套原生 worker | 文件级差分、故障注入、三平台、云保存与 DLC/addon 组合通过 |

回归矩阵至少涵盖循环与共享 class 引用、表键、弱 k/v/kv 表、元表访问、`__SAVEINSTEAD` 先后访问和交叉别名、`__threads` 先后访问、自定义 `save/onSaving/loaded`、Projectile 导出、跨层保存队列和失败重试。比较对象 UID/RNG/turn、任务、背包、地图效果和后续确定动作结果；仅做 ZIP CRC 或成功加载一次不能证明游戏逻辑不变。

这一轮压缩代理结果将“调低压缩等级”排在后面：它有明确可行路径，但测得的潜在收益只有约 9 ms 后台 CPU，远小于首次快照和截图的同步成本。根快照裁剪与冻结后的切片复制更贴近当前卡顿，值得以 addon 原型继续验证。
