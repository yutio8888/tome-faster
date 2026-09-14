# 单项优化实验协议独立评审

评审日期：2026-09-14。结论：同一 0.2.11 包、每次只改变一个新开关、五个场景各固定 30 对的设计可以区分单项效果。下面的计时、配置和状态条件应写入正式计划及验收程序。本次只读检查了已交付包、生产实现和旧 runner/probe；没有运行游戏、性能测试或修改生产文件。撰写时新 runner 和正式计划尚未交付，因此这份文件是实验设计评审，不是对最终测量程序已经通过的证明。

已独立核对 [交付包](/workspace/t-engine4/game/addons/tome-faster/dist/tome-faster.teaa)，大小 441398 字节，SHA256：

`9464fdfc425f53a238aa76ffc16853bd9c5e38df9d6e9b5519941b517f5d2f76`

## 分组与可回答的问题

基线 A 永远使用上述包，显式设置三个新开关为 `false`。候选 B 只把该场景的一项改成布尔 `true`。既有 `compact_save_names=true` 保持一致，因此 base62 的对照是已有短十进制命名。所有既有优化、游戏设置及其他 addon 保持一致。

| 场景 | B 唯一为 true 的新开关 | 两侧执行的相同工作 | 可归因的结果 |
|---|---|---|---|
| base62 普通保存 | `compact_save_names_base62` | 相同输入副本直接保存 | base62 相对短十进制命名的保存 CPU / 文件大小变化 |
| 库存开启、无新增事件 | `compact_inventory` | 加载后不新增库存事件，直接保存 | 安装库存优化后的该次普通保存变化 |
| 库存 24 件事件 | `compact_inventory` | 预建相同 24 个标准 Object，以实际库存表为参数调用 `player:addObject`，然后保存 | 24 次入包阶段成本与后续保存变化，分别报告 |
| Fearscape 开启、无退出事件 | `fearscape_cleanup` | 加载后不触发新的 Fearscape，直接保存 | 安装清理优化后的该次普通保存变化 |
| Fearscape casterdead | `fearscape_cleanup` | 相同真实进入、NPC `die(nil)`、原 tick 完成退出、随后保存 | 进入、同步退出调用、完整退出观察区间、后续保存分别变化 |

每个场景的 A 都要重新测量，不共享某一个普通基线值，也不与先前 0.2.10/混合开关数据合并。固定 30 对意味着每场景 60 会话、全实验 300 会话。每个 pair 的 A/B 必须相邻。已讨论的 30 轮交错方案可用：每轮各场景一对、循环轮换场景起点，每场景奇数对 AB、偶数对 BA。应在首个正式会话前冻结完整 300 会话顺序，而不只记录生成规则。

这五个场景不测三个开关一起启用时的交互效果，也不测安装/首次加载模块的启动 CPU。库存事件仅覆盖 Player 的标准对象、库存表参数路径；原生 `pickupFloor` 使用数字库存 ID，还包括地图移除/排序等步骤，不能把本场景描述成所有拾取路径的完整成本。Fearscape 性能结论限定为本次 casterdead 路径；其他退出分支的正确性验证仍是独立事项。

## 计时字段与边界

所有阶段保留同一套原始采样值：`RUSAGE_SELF` 的 user/system，主线程 `RUSAGE_THREAD` 的 user/system，`CLOCK_THREAD_CPUTIME_ID` 的主线程总 CPU，以及 `CLOCK_MONOTONIC` 墙钟。字段名称应同时写明 scope、user/system/total 和单位。SELF 包含进程内全部线程，THREAD 仅包含调用线程；它们不是可以互换的指标。参见 [Linux getrusage 手册](https://man7.org/linux/man-pages/man2/getrusage.2.html)。

保存唯一主指标仍是 **完整保存区间的 SELF user CPU**。其他保存指标及全部事件指标分别报告；不能把主线程总 CPU、wall 或同步快照时间改称完整 user CPU。事件同样报告 SELF user 的绝对差，主线程总 CPU 用于观察很短的同步调用，不能替代保存主指标。

| 阶段 | 开始 | 结束 | 口径说明 |
|---|---|---|---|
| `save_full` | fixture、状态校验完成后，紧邻 `game:saveGame()` 前 | 该次原 `SavefilePipe.doThread` 返回，保存队列、waiton、saving、on_done 全部清空 | SELF user 主指标；包括快照、序列化、保存线程、完成回调及区间内其他进程线程工作 |
| `save_sync` | 同一次调用前 | `game:saveGame()` 返回 | `save_full` 的子区间，不能与之相加 |
| `inventory_add24` | 24 个对象已经创建、解析（若 fixture 使用解析）并验证；返回值存储也预分配；紧邻第一个 addObject 前 | 第 24 个 addObject 返回之后、任何断言/遍历/输出之前 | 24 次完整调用及固定循环/返回值记录的整批成本；创建对象、前后校验不包含在内 |
| `fear_entry_sync` | `entry_call_begin`：紧邻原 `forceUseTalent` 前 | `entry_call_return`：调用返回后、断言之前 | 原进入调用的同步成本 |
| `fear_entry_full` | 同一 `entry_call_begin` | `entry_complete`：helper 首次观察到已进入正确 plane 且所需原 tick 已完成 | 包含同步进入、回调执行、调度、渲染与观察延迟；完成采样先于 token 创建和大范围状态扫描 |
| `fear_exit_sync` | `exit_call_begin`：紧邻真实 `caster:die(nil)` 前 | `exit_call_return`：原调用返回后、断言之前 | 包含原 NPC 死亡流程及由原 on_die 触发的退出请求，不能称为 cleanup 函数独占 CPU |
| `fear_exit_full` | 同一 `exit_call_begin` | `exit_complete`：helper 首次观察到回到原 source 且所需原 tick 已完成 | 包含同步退出及后续自然游戏循环工作；不是仅异步回调函数本体的 CPU |

六个 Fearscape 标记只由诊断 helper 采样，不能包装/替换 talent.activate、talent.deactivate、actor.on_die，不能捕获后手动执行/重排原 tick 回调，也不能额外插入“完成”回调。这些函数的身份正是生产清理保护条件的一部分。首次完整观察可用固定轮询；要记录 frame/poll 数和 wall，按预定边界保留所有有效会话，不能事后挑选观察更快的样本。

特别注意：[原 onTickEndExecute](/workspace/t-engine4/game/engines/default/engine/Game.lua:321) 在运行旧 `fs` 批次之前就把 `set.fcts` 置空，所以 `pending()==0` 本身不能证明当前批次已结束。必须确保 helper 的观察顺序在所需退出/死亡恢复回调之后，并结合 source/target 身份、sustain 已取消、caster/target 原死亡回调已恢复等最小状态证据；更完整的 token/地图校验随后执行，失败则该会话无效。这个边界应称为“首次观察确认完成”，而不是精确的原 tick 返回时刻。

`fear_entry_sync` 包含在 `fear_entry_full`，`fear_exit_sync` 包含在 `fear_exit_full`。若需要“返回后的区间”，应明确计算 return→complete；不能把 sync+full 当成总成本。可以另列 `add24+save_full` 或 `entry_full+exit_full+save_full` 的非重叠阶段和，必须标为“所测阶段之和”，其中不含 fixture、校验及阶段间空隙。这样的派生指标及其推断用途也要事前冻结，不能在主指标失败后改用它作为通过条件。

实现边界时还应满足：

- 采样方法和读数顺序在 A/B 完全一致；采样结果只存预分配记录，阶段中不做 JSON、print、地图扫描、文件 IO 或 hash。多个 scope 的读取不是同时发生，保留原始时间值和固定顺序；用空 bracket 记录这项开销，不假装采样无成本。
- 保存 SELF 主计时尽量紧贴被测边界；边界检查的工作量相同且很小。终点仅记录一次，并硬性验证 `save_sync_return <= save_full_complete`。如果某路径在 saveGame 内 forceWait 导致旧终点先于同步返回，应判定协议边界不成立，而不能静默使用提前的结果。
- 原 `doThread` 返回是完成边界，不能提前在 queue 变空、`saveGame()` 返回或 save:close 返回时结束。检查 `on_done` 也为空；初始时同样不得存在其他保存任务。生产调用发生内部有效性重试时，应记录并按预声明规则处理，不能因其时间较大而事后删除。
- Fearscape 只做最小完成条件判断后立即采样，再验证大范围状态及生成报告。helper 的 live caster/plane 引用、轮询闭包在下一次保存前释放；诊断数据不挂到 game、actor、Object 或其保存回调上。
- 24 次入包必须执行相同 API 和参数，包括 `no_unstack` 等既有参数；所有返回值在结束后统一检查。不能直接调用 compact/helper、修改 ownership 字段或先创建部分对象再把创建成本混入循环。
- 保持同一 warmup、JIT、GC、显示、线程与 shader-cache 准备策略。不为候选单独预热、主动 GC 或暂停粒子。普通库存场景应验证加载后没有发生预期外的 ownership 表示变化，否则要准确说明加载本身触发了事件，不能仍称为纯粹的无事件对照。

## 置信区间与小事件精度

每个场景的保存指标独立使用原来预声明的方法。对 30 个完整配对，令 `d_i = log(B_i / A_i)`，主结果是 `100 * expm1(mean(d))`。一侧 95% 上界为 `100 * expm1(mean(d) + t(0.95,29) * sd(d)/sqrt(30))`；两侧 95% 区间用 `t(0.975,29)`。分别为 1.6991270265 和 2.0452296421。若继续使用原 CPU 门槛，通过条件应原样冻结为“一侧上界严格小于 +1%”，否则为未证明满足；均值接近零不等于通过。配对后对均值使用 t 区间的公式见 [NIST 均值置信区间](https://www.itl.nist.gov/div898/handbook/eda/section3/eda352.htm)。

保存主计时必须有限且为正。不能因某个事件阶段的 user 读数为零而把有效保存会话删除。所有微小事件阶段统一采用 **配对绝对差** `e_i = B_i - A_i`：报告 mean(e)、以 30 个差值计算的两侧 95% t 区间，以及两侧原始均值/中位数/范围/零值个数。可在事前确定了绝对开销预算时另给一侧上界；不能看到结果后发明预算。即使某阶段恰好没有零值，也保持绝对差口径，不能改选百分比获得更好的结论。

一次 24 件整批入包仍只产生一个样本；30 对就是 n=30。每件平均值如需显示，可把批次均值和区间端点除以 24，但不能把 720 件或同一事件的多个子阶段当成独立重复样本。

`getrusage` 的 timeval 使用微秒字段，这仅说明 **1µs 表示粒度**，没有证明本机 user/system 划分的实际误差不超过 1µs。`clock_getres` 可以报告所选 CPU clock 的分辨率，不能用它宣称 getrusage user 的精度；CPU clock 的结果也不是 user-only。参见 [Linux clock_gettime/clock_getres 手册](https://man7.org/linux/man-pages/man3/clock_gettime.3.html)。

建议正式计划固定：每个会话 warmup 后、被测事件前，以同一采样顺序执行 64 个空 bracket，记录每种计时的零值比例、median、p95、最大值，以及 CPU clock 的 clock_getres。统一预热采样函数、预分配缓冲。此校准不重复实际事件，不进入正式 30 对，不从每次事件值中扣除；它给出本次观测的仪器成本/低值表现，**观测最大值或 p95 都不是严格误差上界**。

若 30 对事件值全零，或者差值恒定导致名义 t 区间退化，仍保留原始数据，但推断标注“当前 user 计量无法分辨该成本”，不能输出“零开销/已证明无影响”。高分辨率 thread-total 可补充说明同一阶段是否确实消耗了可观察的 CPU。若希望给出严格精度范围，需要另有本机计量误差依据：仅在每次时间读数误差已知不超过 epsilon 时，单次阶段差的误差最多 2 epsilon，A/B 差最多 4 epsilon；目前 1µs 字段粒度和空 bracket 不足以证明这个 epsilon。

主 t 区间假设配对差/对数比均值近似正态且配对重复足够独立。AB/BA 和场景轮换有助于时间漂移平衡，但不保证这一假设。保留全配对值、AB 与 BA 描述统计和执行顺序；不修剪异常大但有效的 CPU，不在看过结果后换更有利的 CI 方法。若需要 block/bootstrap 敏感性分析，先冻结方法、seed 和用途，并让它保留全部配对。

五组分别给出的 95% 区间不是覆盖五组参数的联合 95% 区间。若要依据“哪些组通过”分别做多项选择，并希望给所有保存上界同时 95% 的覆盖保证，可预声明额外的 Bonferroni 一侧 99% 上界（每组 alpha=0.05/5）；它不要求组间独立。不能看完结果才决定是否做校正。另一方面，若唯一决策预先固定为“五项原门槛全部通过才接受整体结论”，那是所有子检验都需通过的交并检验，不应误称必须将每项 alpha 再除以五；它与“五个数值区间同时覆盖”的要求不同。事件指标建议保持描述性，避免从多个阶段中挑一项显著变化作为优化总收益。

保存通过只支持本场景的保存门槛；事件的绝对成本必须同时公开。事件读数为零或 CI 很宽，不足以支持“该优化在整个生命周期内的总 user CPU 增加小于 1%”。

## 必须机器校验的条件

### 唯一开关与生效路径

- 每次启动保存完整最终生产配置及类型；A 的三个值严格为布尔 false，B 仅对应字段为布尔 true。删除该字段后，A/B 生产配置的规范化内容必须相同。不能只依赖 session 名或 `cfg.candidate`。诊断期望字段可随场景/变体变化，但不得静默改变别的生产选项。
- 两侧 `compact_save_names` 都启用，其他既有优化、profiler、显示/后台保存/联网等设置一致。安装发生在启动时，所以不能在游戏加载之后切换开关并据此认定实际函数已切换。
- 库存开关 false 时两个类层面的 stock 方法和库存接口源码均正确，`engine.FasterInventory` 未加载；true 时 Inventory、Actor、Player 三个 onAddObject 都为目标安装函数，getInven 为受支持的原方法。只检查 Player 一个来源不足以覆盖 installer 的完整保护条件。
- Fearscape 开关 false 时 `engine.FasterFearscape` 未加载且 deactivate 为 stock；true 时 deactivate 为冻结目标实现，activate 始终为同一个 stock 实现。Fearscape 事件期间原 actor 死亡包装器和恢复后的 callback 必须继续通过身份验证。
- base62 两侧 getFileName 源路径相同，来源检查本身不能证明选择了何种 encoder。可在正式计时/预热前以隔离的临时 Savefile 命名缓存检查第 62 个 ID：A 为 `62`，B 为 `10`；释放该诊断 fixture，不触碰真实保存的命名缓存。最终存档还要验证所保存 archive 的名字/引用一致、条目名唯一、main 语义和预期编码，而不是只接受都允许的 `[A-Za-z0-9_]+` 正则。

### 冻结来源与输入

- 全部 300 会话使用上面的同一包 SHA，不得再按 baseline/candidate 替换不同包。运行时须明确实际加载该 teaa，不能被同名解包目录或其他 addon 的 overload/superload 遮蔽。
- 固定 engine 二进制、引擎/模块源码、其他 addon 列表和顺序、原始 save 压缩包、profile/shader-cache seed、相关渲染库/环境。记录依赖指纹，不能只 hash 新 addon 后假定 native 保存实现一致。
- 以相同 source-key 集合比较生产与诊断文件 hashes；本实验生产源码不只要在每个 variant 内不变，而是 A/B 及全部场景都相同。正式 plan、runner、probe、CPU 模块、Fearscape helper、统计分析代码都在首次正式测量前 hash 冻结，并把 plan hash 写入每份 input。
- 每会话新进程、新 save/home/cache 副本，使用原始输入而非上次输出；保存前输入文件清单仅允许已预声明的诊断 addon/配置差异。真实用户 save 不参与写入。
- 记录实际开始/结束、全局序号、场景和 pair 序号；全局顺序必须等于计划，前后会话不能重叠。性能任务使用共同排他机制；单个目录锁不能阻止其他 benchmark 同时跑。把 host load 作为诊断，不按结果或事后 load 门槛剔除会话。

本次已核对以下包内文件与工作区现有生产文件逐字节一致：

| 文件 | 包内 SHA256 |
|---|---|
| `init.lua` | `562725e2692c413c07bb6bc1bf6f2529a19f6553c25fe8036ab3dbdddf3752fc` |
| `overload/engine/FasterSaveNames.lua` | `b28e253404cb3bc9991ae15ca535ae4da49dc24961ea5bf30db9c2cdf7928c21` |
| `overload/engine/FasterInventory.lua` | `a4b96229c4c1d4d5388dede0550beb93317b59070cc3f485119d4e5e530dab2d` |
| `overload/engine/FasterFearscape.lua` | `f27af6223f04c02064f3ecaf09d12d7ab3b496788c641436d0981152a3681312` |
| `superload/mod/class/Game.lua` | `312229b62cc677d615d5ff7666ec69934f4c0a53eb9dee9280aa1d7e6ce4db87` |

### 配对状态与有效会话

- 每会话一次受控保存，正常 exit、无 Lua/coroutine 错误、无 timeout，唯一完整结果，原完成条件全部满足。每个 pair 两侧场景与 seed 相同，玩家 paused/enoughEnergy、turn 不推进、保存前无并发保存或未完成相关 tick。
- 不只验证各自 `before==after`，还要验证 A/B 配对语义状态相等：玩家身份、位置、资源、状态、库存内容/数量/顺序/owner 别名、当前 level/zone、相关 actor 的生死/位置以及地面对象。对象 UID 可按明确的双射规范化，但必须保留 alias 关系；不能直接删除所有 UID 字段，也不能通过过度排序掩盖库存顺序变化。
- 库存 fixture 两侧恰好相同的 24 个 Object、相同进入顺序、真实成功返回、无意外堆叠/转移/回调。A 保持 owner.id 对同一库存表的身份引用，B 的 owner.id 为正确 numeric ID；owner.actor 是同一玩家。仅允许这一预声明表示差异，不把它扩展为忽略整个 ownership record。
- Fearscape 需保留进入 source/target/caster/plane 的真实身份、原 source 关联、原 capture/on_die 包装器及其恢复身份；通过 stock NPC.die(nil) 触发 casterdead，sustain 已取消，返回原 source，活 target 在 source，死 caster 不在 source，marker token 恰好一次且位置/身份正确。A 保留原 trapper 边，B 按生产条件清除它；这是允许的图差异。两侧都不得由诊断代码清边。相关玩法状态除此之外保持一致。
- 在每次保存前后比较游戏语义状态；结束后离线验证 ZIP 完整性、文件字节/条目统计和变化档案清单。不要把未重写的旧 archive 纳入编码生效验证后误判。对本冻结包预选兼容性会话做原 reader / 无 Faster reload 验证；这些语义验证会话不混入 30 对 CPU。
- 保留所有固定正式样本。预先规定硬失败处理：保留失败证据，停止受影响场景，先查明代码/输入/计时问题；需要重启时另立全 30 对计划，不以一个“更好”的会话替换失败/慢会话。若共同 probe 或输入需改变，所有受影响场景重新冻结，不能混用旧 hash 的结果。仅 CPU 大、上界不通过或某事件读零都不是重启/删样理由。

最后，旧 probe 的 `cfg.candidate` 同时断言 Inventory/Fearscape 安装、旧 analyzer 允许两种生产包、旧结果的 `game_state_equal` 只检查本会话保存前后；三者都不够用于本实验。新实现需要分别落实上述唯一开关、共同来源与跨变体状态条件后，才可以开始正式 300 会话。
