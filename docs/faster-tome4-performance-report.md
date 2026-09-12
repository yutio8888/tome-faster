# Faster ToME4 性能问题、修复方案与测量交接说明

更新日期：2026-09-12。本文汇总原插件审查、本体与 DLC review、存档只读取证及本地 profile。
本文为独立插件仓库的公开版，路径相对于仓库根目录。当前分支为
`perf-review-profile-20260912`，包含截至 0.2.1 实验版的代码、测试、测量结果及说明。

## 1. 当前结论与交付边界

已经确认几类可修复的问题：原插件缓存与日志接口缺陷、切图产生重复保存请求、延迟加载
队列反复头插、地图检查源码重复构造、Ashes 的无用效果扫描，以及存档中的失效引用和
一次性粒子不终止问题。其中一部分已进入默认交付版，另一部分处于实验或设计阶段。

最新 profile 要求收紧性能归因：**失效引用与后台粒子工作确实存在，但尚未证明它们是
该存档严重卡顿的主要来源。** 本机 42 个空转 notice_enemy 合计约 0.0106 ms／粒子关键帧，
孤儿链稳态粒子合计约 0.454 ms／关键帧。引用清理减少约 5.6% 的克隆分配，但没有证明
克隆 CPU 时间稳定改善。不能继续把静态审计中的“首要嫌疑”表述为已测出的主因。

当前没有完整游戏、GPU、真实存取档总耗时或玩家机器帧率数据。原存档未修改，也没有执行
存档中保存的 LuaJIT 字节码。已有 profile 运行的是真实 C 粒子工作代码及安全解码对象图，
不是一次完整游戏加载。

| 交付层次 | 版本／提交 | 已包含的工作 | 当前状态 |
| --- | --- | --- | --- |
| 原包导入 | 0.0.1／`ded93e3` | 保留原作者源码及版权，补充来源记录 | 历史基线；本会话已有 GitHub 上传核验记录 |
| 第一轮修复 | 0.1.0／`b8ab0c9` | 原插件缺陷、保存请求合并、延迟队列优化 | 已本地提交，包保留供对照 |
| 默认交付版 | 0.2.0／`ec0a3d1` | 第一轮内容，加地图源码缓存、Ashes 无用扫描修复 | 作为 releases/ 中的默认版历史快照保留 |
| profile 实验版 | 0.2.1／`070d3dc` | 0.2.0 内容，加两种粒子寿命修复、可关闭计时器及 profile 工具 | 本公开分支的代码基线；默认 0.2.0 快照仍保留 |
| 存档引用清理 | 无游戏内迁移版本 | 在解码图中解除捕获者引用、规范化背包归属 | 只有测量实验，未加入实际存档迁移流程 |

0.1.0、0.2.0、0.2.1 的提交均包含在本分支历史中。本次发布目标为公开仓库
[yutio8888/tome-faster](https://github.com/yutio8888/tome-faster) 的新分支，main 保留原版。
发布前已核验仓库为 PUBLIC，main 为 ded93e3；
[publication.json](../evidence/faster-tome4-review/publication.json) 保留初始导入的历史核验。

## 2. 版本和证据来源

| 输入 | 固定依据 | 使用限制 |
| --- | --- | --- |
| ToME 本体 | 1.7.6，commit `624a67329fe2ad440c5b344785a9c73fcf22ae63` | 所列本体机制以该源码为准，不泛化到任意版本／第三方覆盖 |
| 原 Faster 插件 | 作者 yutio888，包内声明插件 0.0.1、游戏 1.7.3；下载包 SHA256 见第 8 节 | 网页游戏版本与插件版本不同；上游源码 commit 未固定 |
| Ashes／Cults／Embers | 本地 init.lua 均声明游戏 1.7.4，addon 分别为 1.1.4／1.0.12／1.1.10 | 没有固定 DLC Git commit，不能称为已固定的“1.7.6 DLC 源码” |
| DLC 内容快照 | [dlc-source-manifest.json](../evidence/faster-tome4-runtime-review/dlc-source-manifest.json) | 文件哈希覆盖不等于每个文件均做过人工性能审查 |
| 用户存档 | 原始上传 ZIP，读取前后 SHA256 一致 | 原始输入和生成对象图只在本地使用，未装入 addon 包 |
| 本地 profile | ARM64 Linux、LuaJIT 2.1.1761786044；[环境与编译参数](../evidence/faster-tome4-profile/results/environment.json) | 无图形会话；游戏自带 LuaJIT 2.0.2 不支持本机架构，旧存档字节码不能直接用于本机完整加载 |

后文“已确认”表示源码机制或静态存档事实已独立核验，不代表耗时占比已经测出。
“待测”表示缺少实际性能证据；“设计”表示尚无可交付的对应修复代码。

## 3. 已发现的问题与当前处理

### 3.1 原插件及已经交付的优化

| 问题 | 已确认的影响 | 修复内容／位置 | 状态 |
| --- | --- | --- | --- |
| 环形日志少用一个槽，最旧条目索引错误 | 配置 5,000 条却只保留 4,999 条；peekOldest 不正确 | 显式计数及正确取模；`overload/engine/CacheList.lua` | 0.1.0 起已修复 |
| truncate_printlog 被改为空操作 | 无法按调用者要求清空或截断日志 | 保留原 stdout 格式与启动日志，转入 5,000 条环形缓冲并恢复截断语义；`hooks/load.lua` | 0.1.0 起已修复 |
| 完全屏蔽 hit_warning | 玩家失去远程受击方向提示 | 恢复原发射器；`superload/engine/Map.lua` | 0.1.0 起已修复 |
| 文本缓存忽略窗口字体和宽度，弱值缓存易失效 | 可错误复用纹理，GC 后又重复生成 | 每窗口 FIFO 上限 128；字体／宽度变化失效；`superload/mod/dialogs/ShowChatLog.lua` | 0.1.0 起已修复 |
| 粒子／shader 定义缓存缺少边界和可靠的失败、环境处理 | 热更新、编译失败、不同实例参数和其他包装存在兼容风险 | 每方法缓存 256 份成功字节码，命中时创建独立闭包，保留原环境及返回值；`hooks/load.lua` | 0.1.0 起已修复 |
| 同批 zone／level 请求追加多次主存档 | 重复克隆、成绩更新、World 请求，并可能等待上一轮保存 | 同一实际回调数组只让最后一项触发主存档；`overload/engine/FasterSave.lua` | 0.1.0 起已修复 |
| 延迟 loaded 队列反复头插 | M 次插入累计搬移约 M(M−1)/2 个元素 | 最外层 loadReal 收集后逆序合入，保留数组身份、回调顺序及错误路径 | 0.1.0 起已修复 |
| Map.updateMap 重复拼接同样的检查源码 | 编译已有缓存，源码格式化与拼接仍重复发生 | 按排序后的层序列复用源码；每 Map 最多 128 种布局；`overload/engine/FasterRuntime.lua` | 0.2.0 起已修复 |
| Ashes 吞噬烈焰扫描效果后只写入未使用变量 | 重复访问临时效果表 | 仅删除未使用扫描，保留投射、随机、伤害和延迟效果顺序；同上 | 0.2.0 起已修复 |

保存合并保留最后一次请求的位置，避免漏掉夹在请求间的状态变化；显式手动／退出保存
不合并，不跨独立回调队列强行去重。延迟队列优化处理单次根对象图，不声称所有加载模式
都已全局线性化。地图缓存保存源码字符串，不缓存实体或检查结果。

安装器对若干被替换方法检查来源路径与行边界，未知包装会跳过；这不是内容哈希认证。
缓存边界按条目计，不是按字节计。普通模式编辑资源后仍需重启／失效处理；native 粒子
线程的文件加载并没有被原插件的 Lua loadfile 缓存加速。

详细依据：[原插件修复](../docs/known-fixes.md)、
[保存／加载](../docs/save-load.md)、
[本体与 DLC review](../docs/runtime-review.md)。

### 3.2 存档中直接确认的失效引用和数据规模

最明确的强引用链为：

```text
Player.demon_plane_trapper
  → 已死亡 NPC
    → ai_state.safe_grid.Astar
      → 12×12 Fearscape Map（主档九个 Level 均不以它为地图）
```

进入 Fearscape 时设置 `demon_plane_trapper`，退出路径没有清除；死亡回调仍依赖该字段
触发退出，因此清理时机必须避开正在进行的 Fearscape。读档时 Particles.loaded 会创建
native emitter；线程按 alive 状态更新，没有“必须属于当前地图”的条件。

| 项目 | 独立核验结果 | 判断／状态 |
| --- | --- | --- |
| 孤儿 Fearscape 链 | 地图列表 132 个粒子，加死敌身上 3 个，共 135；含 111 个 vapour、2 个 notice_enemy、1 个 circle | 引用残留已确认；清理仅在解码图实验中 |
| 主档粒子分布 | 共 205：当前层 12、其他八层 58、孤儿链 135 | 193/205 是非当前场景的记录比例，不是 CPU 比例 |
| 一次性 emitter 不终止 | 全档 58 个 notice_enemy、2 个 dreamhammer；只发射一次却返回 no_stop=true | 0.2.1 实验版已修定义，未进入默认 0.2.0 |
| notice_enemy 区域分布 | 主档 2、世界地图 42、Heart of the Gloom 10、其他区域 4 | 区域档不会在当前主档加载时全部同时活跃 |
| dust_trail 历史记录 | 全档 212 个，属于有限寿命效果 | 重载后短时工作量候选，不列作永久空转 |
| 玩家 inventory 可达图 | 1,163 个 Object、46 个 NPC，相关条目正文 2,192,332 字节 | 是序列化可达规模，不是实际携带数量或 Lua 堆大小 |
| 玛瑙堆 | 根对象加 421 个 stacked 对象，共 422 个，正文 512,883 字节 | 大型合法实例集合；尚无简化数据模型的修复 |
| 恶魔种子 | 46 个种子，相关可达子图约 733,186 字节 | 职业机制保留完整 NPC；不能直接删 NPC 或替换为数量 |
| 旧背包表 | 移动纹身和转化箱的 in_inven.id 为内嵌背包表，额外引用 30 个不在当前直接 inventory 中的物品 | 归属记录需规范化；实际游戏迁移未实现 |
| Cloud Caller | 仅见 main.entities 和转化箱的旧背包字段引用；不在当前 inventory／Level | 全局行动表加载后是弱值表；应解除旧背包强引用，不只删除行动表条目 |
| 当前行动规模 | Level.entities／e_array 均为 13；game.entities 共 14 | 未发现行动对象数量爆炸；原分析“23 个 e_array”未复现 |

外层 ZIP 展开为 22,208,501 字节，其中 .teag/.teaz 仍是压缩容器；继续展开内部档案共
52,505,076 字节，主档正文 6,640,758 字节、2,849 个 ZIP 条目。不要把“22.2 MB”当成
全部对象正文，也不要把日志的 34,235 个克隆计数当作 ZIP 文件条目数。

原分析关于所有区域的 distance_map、任务与时间克隆等其余排除项，未全部重新统计，
不作为本报告的独立确认结论。详细字段锚点与方法见
[存档核验报告](../evidence/faster-tome4-save-forensics/README.md)及
本地 observations.json（含对象标识，未公开）。

### 3.3 保存／加载中尚未处理的结构性风险

以下机制已经在固定 1.7.6 源码确认，实际占比仍待完整游戏测量。

| 路径 | 风险 | 准备的方向／约束 |
| --- | --- | --- |
| 同步 cloneForSave | 对象图越大越慢，可能先复制最终不保存的字段 | 逐类验证保存快照所需辅助字段，再缩小范围；不能机械套保存白名单 |
| 多处 collectgarbage("collect") | 大堆及快照同时存活时产生同步停顿 | 拆分计时后调整时机，不删除所有完整 GC，也不在游戏中永久停 GC |
| 按 type／savename 判断冲突 | 不同楼层档案也可能等待；积压放大停顿 | 若改为档案身份，必须同时审计入队、完成注销、重试和令牌顺序 |
| 整个 tbl:save() 后才 yield | 单个大型普通表可阻塞一个时间片 | 设计序列化工作预算；目前 addon 未改变序列化格式或 C 写入器 |
| 读档菜单预载截图、逐项排序 | 其他角色目录数量直接增加菜单工作 | 独立 boot 模块 addon；收集后排序一次，按需解码／布局／纹理化 |
| scores.profile 全表重写 | 共享角色成绩历史增加保存成本 | 先测序列化与写入，再设计合并；保留持久性 |
| 云空间不足时维护 | 可用空间低于 200 MiB 时枚举和清理旧云档 | 单独测条件路径；暂未增加缓存或改清理策略 |
| 保存版本令牌增长 | 历史元数据累积 | 监测；令牌参与有效性判断，不随意裁剪 |
| 保存失败重试无明确上限 | 异常时可能反复重试 | 设计有限重试、保留失败状态和明确错误通知，尚未实现 |

首次读档菜单属于 boot 模块，当前 `for_module="tome"` 的 addon 不能直接解决它。
尚无 `boot-faster` 成品。按需读取截图还必须处理列表扫描后临时挂载已被解除的问题。

“其他角色目录数”“当前角色可达对象图”“共享成绩历史”“排队保存请求数”是四个独立
变量，应分别测试；删除其他角色不能作为后期保存卡顿的通用修复。

### 3.4 本体／DLC 的其他候选与已撤下原型

| 候选 | 发现与现有方案 | 决策 |
| --- | --- | --- |
| canSee 默认命中仍构造键 | 只快捷返回已有 nil/nil 缓存的原型，warm-JIT 比率约 0.999／1.015／0.992 | 未证明收益，不纳入 addon |
| Embers Micro Spiderbot 占位查询 | 临时坐标索引减少遍历，但二维表测试慢约 4.19–4.26 倍，扁平表慢约 2.46–3.05 倍 | 已撤下，补丁和基准仅作研究资料 |
| Cults Atrophy 多次更新计数 | 需在效果增删、层数变化、死亡／离图时建立失效通知 | 设计中，不能只按回合缓存 |
| Cults Fatebreaker 周期重建粒子 | 先测创建次数，核对寿命、方向、移除及随机流，再评估复用 | 待验证，未修改 |
| Embers Galvanic Arcing 坐标比较 | 比较输入世界坐标和已转相对坐标的存储；准备分开保存世界坐标，核查 LOS／几何失效 | 机制已确认，影响与安全修复待验证 |
| 热键 UI 反复生成键名纹理 | 需测 actor.changed 触发频率及字体底层缓存 | 观察项，未修改 |

不能只凭循环变少就接受优化。蜘蛛机器人和可见性原型的结果已说明：临时表分配、JIT
路径和状态失效成本可能抵消收益。源码依据及原型位置见
[runtime-review.md](../docs/runtime-review.md)。

## 4. 下一步修复方案及验收边界

下列优先级兼顾已确认的生命周期错误与数据完整性，不是未经测量的 CPU 热点排名。

| 工作 | 具体方案 | 纳入默认版之前的验收 |
| --- | --- | --- |
| 验证实验粒子修复 | 保留生成器、初次发射、视觉参数及随机调用，仅取消错误 no_stop；通过 overload/data/gfx/particles 覆盖 native 线程读取的资源 | 在兼容的完整游戏中验证两种动画、密度、当前与历史区域重载、其他 addon 覆盖；确认不再增长 |
| 阻止新增 Fearscape 残留 | 原退出回调成功返回来源 Level 后，清除仍匹配该施法者的 target.demon_plane_trapper | 覆盖主动解除、施法者／目标死亡、失败退出、仍在持续中的 Fearscape；不能提前破坏死亡回调 |
| 旧档 Fearscape 迁移 | 完整对象图加载后确认已离开该次 Fearscape、施法者死亡、死亡包装不再依赖字段、候选 Map 无合法 Level 所有者，再解除引用 | 幂等；证据不足跳过；不得清空所有非当前地图粒子；单独验证停止 native emitter 和 GC，不强毁整张 Map |
| 新增／旧档 inventory 规范化 | 新增物品保持原 hook 参数，只修标准归属记录；旧档依据实际 inventory、堆叠和附属对象确认所有者与数字 id | 覆盖出生物品、拾取、叠堆／拆堆、装备切换、转化、丢弃及再保存；不删物品，不盲信旧表 id，不新增同步完整 GC |
| 找到剩余存取档热点 | 用实际游戏拆分截图、成绩、快照、GC、序列化、写入及等待 | 取得配对计时后，才选择快照过滤、共享数据合并或序列化预算方案 |
| 数据模型与 DLC 扩展优化 | 玛瑙／种子先分离模板与必要实例状态；DLC 缓存先建立失效规则 | 保存兼容性、机制等价性与真实收益均有证据后实施 |

当前 `tests/profile/graph.lua` 中的 Fearscape 解除和 inventory 规范化是针对已审计输入的
实验处理。其检查条件不能替代上述游戏内迁移验收，也不能直接用于批量改写玩家存档。

## 5. 测量指标与现有结果

### 5.1 已运行的局部测量

原生测试逐字提取固定源码中的粒子初始化、发射、更新、清理及 RNG 包装函数，使用真实
SDL mutex、SFMT、LuaJIT 回调和顶点缓冲区计算。线程工作体在测试线程中运行，排除了
OpenGL、调度及多线程争用；瓦片 64、shader.active=false。预热 200 个关键帧后测 3,000 个，
每条件 5 次并交替顺序。下表为密度 100 的 CPU 中位数。

| 工作负载 | 稳态 emitter 数 | µs／粒子关键帧 |
| --- | ---: | ---: |
| 世界地图 42 个 notice_enemy，原版 | 42 | 10.588 |
| 同上，有限寿命修复 | 0 | 空测试循环约 0.001 |
| 孤儿链 135 个记录，原版预热后 | 114 | 453.720 |
| 同上，仅修两种一次性粒子 | 112 | 492.371 |
| 测试器中停止整条链后 | 0 | 空测试循环约 0.001 |

20 个 acid 与 1 个 melee_attack 在预热时已结束。原版孤儿链五次区间 448.6–530.3 µs，
仅改粒子寿命后为 450.2–518.2 µs，重叠明显；不能说该混合负载已经提速。“停止整条链”
不含停止／迁移自身成本，测的是移除该工作负载后的上限，而不是完整游戏的优化结果。

对象图测试保留序列化表和引用关系，将 1,544 个函数表达式替换为独立无作用闭包；没有
执行保存的字节码，没有 loaded 回调、native 句柄、运行时缓存或类元表。运行的克隆方法
来自固定源码。每条件 3 个进程，各测 25 次；表格取各进程中位数，再取三者中位数。

| 安全解码图条件 | class／atomic 计数 | 粒子记录 | 克隆分配 MiB | 克隆 CPU ms |
| --- | ---: | ---: | ---: | ---: |
| 基线 | 2,962 | 205 | 14.684 | 21.534 |
| 解除捕获者引用 | 2,708 | 70 | 14.212 | 20.043 |
| 规范化 inventory 引用 | 2,821 | 205 | 14.336 | 21.044 |
| 两项同时处理 | 2,567 | 70 | 13.861 | 21.548 |

背包实验包含玩家及种子内 NPC 的实际 inventory／stacked，共修正 63 条 table id，范围
比“玩家两个旧背包表”更宽。组合处理减少约 5.6% 的克隆分配，可达 Object 由 1,526 降至
1,449；这些数字属于实验图，不能拿来宣称原游戏实际减少了同样的运行时对象数。

为分开测量，克隆阶段暂时停自动 GC，随后立即恢复；这只发生在测试进程。持有原图和
快照时完整 GC 中位数为 5.249 → 4.993 ms，释放快照后为 4.401 → 4.195 ms。
默认 GC 开启的另组克隆中位数为 23.116 → 22.802 ms，也不足以证明稳定的实际提速。
每 1 ms 的 LuaJIT 栈采样主要命中递归克隆的遍历／分配与测试显式触发的 GC；它不是
正常游玩时的 GC 占比。

先前隔离测试还证明了操作量减少：2,001 个延迟回调的原队列搬移 2,001,000 个元素，
优化后不再头插；2,000 次重复地图布局的源码构造 2,000 → 1；Ashes 夹具效果访问 300 → 0。
这些计数与上述毫秒测试属于不同实验，不能相加为总性能收益。

### 5.2 当前计时器能提供什么

实验版的 `engine.FasterProfile` 默认关闭，只记录固定类别的标量统计，不保留演员、地图、
参数或返回对象。当前可对已加载类的方法安装计时包装。

| 指标／入口 | 已有能力 | 解释限制 |
| --- | --- | --- |
| started／completed | 每种方法开始和完成次数 | 差值可能是错误或未结束协程，不直接等于失败重试次数 |
| wall_ms／max_wall_ms | SDL 毫秒累计跨度和最大单次跨度 | 分辨率为毫秒；含子调用和协程等待，不是独占耗时 |
| process_cpu_ms | os.clock 进程 CPU 时间 | 可能含 native 粒子线程，不能称为主线程 CPU |
| clone_last／clone_max | cloneForSave 返回的最近／最大计数 | 不是 ZIP 条目数、字节数或 Lua 表总数 |
| Game.tick／saveGame／save／截图／成绩登记 | 包含子调用的分段跨度 | tick 不是显示帧；嵌套行不能相加 |
| Savefile.loadReal／loadGame／saveGame／saveObject | 对应入口累计次数与跨度 | loadReal 有递归；saveObject 覆盖整段序列化，尚未单独计每个 tbl:save |
| SavefilePipe.push／forceWait／steamCleanup | 提交、强制等待、云维护跨度 | 尚未自动记录每次等待原因、队列深度、实际档案身份 |
| Particles.loaded | 创建／重建入口次数和时间 | 不包括 native 线程后续更新 |
| 显式 collectgarbage("collect") | 完整 GC 次数与跨度 | 不是所有增量 GC 时间；不计无参数的默认调用 |

start() 幂等，可以再次调用补充后来加载的类。包装器保留返回值、nil、协程 yield 和
原错误传播；stop() 恢复方法时保留后来 addon 的覆盖。计时自身有时钟与打包开销，
应做启用／关闭对照，不能把带计时开销的结果直接视为正常游戏耗时。

### 5.3 完整游戏仍需补测的指标

| 目标 | 指标 | 建议测法 |
| --- | --- | --- |
| 明确卡顿症状 | 渲染帧时间 p50／p95／p99、最大停顿、回合响应时间 | 当前层静置、固定回合、密集战斗、切图分别采集；需增加逐帧记录或外部 profiler |
| 找到保存主因 | 截图／成绩／克隆／GC／最慢单对象序列化／压缩写盘／完成通知时间 | 保存入口拆段；Lua、C 写入线程分别计时；不能用一个 saving took 代替 |
| 找到读档主因 | 解压、Lua 解析与对象重建、loaded 回调、显示恢复 | 原兼容运行时和完整依赖 addon 下测冷／热加载 |
| 验证后台粒子负担 | 各线程 CPU、活跃 emitter、实际槽数、创建／销毁数量 | native profiler；区分当前层、合法历史层和孤儿链 |
| 识别保存积压 | 队列长度、forceWait 次数／原因、重试次数、请求档案 id | 在管线补计数；对照日志中的 Already saving data／force waiting／*RE*new save |
| 解释内存停顿 | Lua 堆、进程 RSS、快照峰值、GC 次数／时长 | 区分存活图与垃圾，存档压缩大小不能代替堆规模 |
| 量化菜单问题 | 角色目录数、PNG 解码数、纹理与布局次数、排序次数 | 保持当前角色、World、Profile 不变，仅改变其他目录数 |
| 验证 DLC 候选 | 回调次数、扫描条目、粒子重建次数及状态变化 | 对应职业／技能场景配对测试，保留 RNG、目标与伤害轨迹 |

使用备份出的独立副本，固定硬件、窗口尺寸、粒子密度、shader、游戏／DLC／addon 版本、
JIT 和 cheat 状态；区分冷启动与缓存后结果。云维护测试单列，避免混入普通保存对照。
若为开发控制台启用 cheat，Faster 的部分缓存和保存合并会绕过，必须保持 A/B 条件相同。

## 6. 已有检查与验收状态

| 检查 | 当前结果 | 覆盖范围 |
| --- | --- | --- |
| 原插件回归 | 20,790 项断言通过 | 日志、环形缓存、资源环境、文本缓存、受击提示等 |
| 保存／加载回归 | 71 项通过 | 合并顺序、取消／捕获／下一批、加载引用、队列身份及错误路径 |
| 地图／Ashes 回归 | 162 项通过 | 检查源码缓存、回调副作用顺序、投射／随机／伤害等价 |
| profile 模块回归 | 22 项通过 | 默认关闭、幂等、返回值、错误、yield、SDL 回绕、停止及后续覆盖 |
| 原生粒子案例 | 6 个通过 | 两种粒子 × 密度 0／25／100，初始粒子和顶点状态一致，修复后终止 |
| 安装包 | CRC、源码逐文件一致性、哈希检查通过 | 不含生成的玩家对象图／原存档；只安装一个 faster 副本 |
| 完整游戏／GPU／Steam | 尚未验收 | 不能从上述回归推断全部运行场景已验证 |

检查数字见默认版 [VALIDATION.json](../VALIDATION.json)和
实验版 [VALIDATION.json](../evidence/faster-tome4-profile/VALIDATION.json)。

## 7. 公开文件与本地输入边界

### 7.1 源码、分支和安装包

| 文件／目录 | 用途 |
| --- | --- |
| [README.md](../README.md) | 安装与构建入口；当前根目录为 0.2.1 实验版代码 |
| [releases/](../releases/) | 0.1.0、0.2.0、0.2.1-profile 已生成的历史快照与基线说明 |
| [原包 0.0.1](../upstream/tome-faster-0.0.1.teaa) | 未修改的下载归档 |
| [0.1.0 安装包](../releases/tome-faster-0.1.0.teaa) | 第一轮修复快照 b8ab0c9 |
| [0.2.0 安装包](../releases/tome-faster-0.2.0.teaa) | 默认交付快照 ec0a3d1 |
| [0.2.1 profile 安装包](../releases/tome-faster-0.2.1-profile.teaa) | 实验快照 070d3dc；尚无实际存档引用迁移 |

所有版本的 short_name 均为 faster，只启用一个副本。当前分支的公开文档比历史包更新；
使用 tools/package.py 重建会产生包含新文档的包，因此哈希不同。已生成的历史包保持不变。

### 7.2 核心实现与工具

| 文件 | 作用 |
| --- | --- |
| [FasterSave.lua](../overload/engine/FasterSave.lua) | 保存请求合并与延迟加载队列安装器 |
| [FasterRuntime.lua](../overload/engine/FasterRuntime.lua) | 地图检查源码缓存与 Ashes 修复 |
| [FasterProfile.lua](../overload/engine/FasterProfile.lua) | 可启停的游戏计时器 |
| [notice_enemy.lua](../overload/data/gfx/particles/notice_enemy.lua)／[dreamhammer.lua](../overload/data/gfx/particles/dreamhammer.lua) | 实验版有限寿命资源定义 |
| [audit.py](../evidence/faster-tome4-save-forensics/audit.py) | 原存档只读字面量解析、结构统计、引用链核验 |
| [tests/profile/prepare.py](../tests/profile/prepare.py) | 从固定源码和存档准备安全对象图、粒子配置及 C 函数片段 |
| [tests/profile/run.py](../tests/profile/run.py) | 编译 Linux 测试器、运行对照、记录环境／计时／栈样本 |
| [tests/profile/particles.c](../tests/profile/particles.c) | 原生粒子工作体驱动与生命周期检查 |
| [tests/profile/graph.lua](../tests/profile/graph.lua) | 对象图清理实验、克隆／GC 计时和采样；不是实际存档迁移器 |
| [tests/profile/save_literals.py](../tests/profile/save_literals.py) | 可供 profile 工具独立使用的受限解析器 |
| [实验版 tests/run.sh](../tests/run.sh) | 常规 Lua 回归入口，配置 Lua 5.1 搜索路径 |
| [tools/package.py](../tools/package.py) | 按源码目录白名单生成 dist/tome-faster.teaa |

### 7.3 报告、结果与输入

| 目录／文件 | 内容 |
| --- | --- |
| [evidence/faster-tome4-review/](../evidence/faster-tome4-review/) | 原包身份、初始复现脚本和导入核验记录 |
| [evidence/faster-tome4-optimization/](../evidence/faster-tome4-optimization/) | 保存／加载第一轮源码裁决 |
| [evidence/faster-tome4-runtime-review/](../evidence/faster-tome4-runtime-review/) | 本体／DLC review、验证结果与 DLC 文件哈希 |
| [runtime-review/experiments/](../evidence/faster-tome4-runtime-review/experiments/) | 已撤下的 Spiderbot 原型及微基准，不是当前修复 |
| [evidence/faster-tome4-save-forensics/](../evidence/faster-tome4-save-forensics/) | 静态审计方法、聚合结论和案例解析脚本 |
| [profile/README.md](../evidence/faster-tome4-profile/README.md) | 公开结果、路径替换规则及原始输入边界 |
| [profiling.md](profiling.md) | profile 方法和计时器使用说明 |
| [profile/results/environment.json](../evidence/faster-tome4-profile/results/environment.json) | 架构、解释器、编译参数、输入哈希；本机路径用占位符表示 |
| [profile/source-manifest.json](../evidence/faster-tome4-profile/source-manifest.json) | 本体关键源码哈希 |
| [profile/results/particles.json](../evidence/faster-tome4-profile/results/particles.json) | 五次原生粒子对照、活跃数、槽数和 CPU／wall 时间 |
| [profile/results/graph.json](../evidence/faster-tome4-profile/results/graph.json) | 各进程克隆／GC／分配量摘要 |
| [baseline-samples.txt](../evidence/faster-tome4-profile/results/baseline-samples.txt)／[both-samples.txt](../evidence/faster-tome4-profile/results/both-samples.txt) | 1 ms 栈样本；本机 native 地址替换为占位符 |
| [native-validation.json](../evidence/faster-tome4-profile/results/native-validation.json) | 6 个粒子动画状态与终止案例 |
| [compile.log](../evidence/faster-tome4-profile/results/compile.log) | 编译警告；本机路径替换为占位符 |

原始存档、带对象标识的 observations.json、安全解码 graph.lua、粒子配置和本机
particles 可执行文件仅保留本地。公开结果未包含这些玩家输入，因此其他人不能仅靠
本仓库重现同一个玩家对象图。tests/profile/prepare.py 和 audit.py 保留本次案例假设，
包括角色目录 yron、世界地图档案及已核验的捕获者链；并非通用存档分析／迁移入口。

初始缺陷复现脚本针对原包 0.0.1，使用前需隔离解压原包或检出 ded93e3，不能以当前
已经修复的根目录作为基线。常规回归 tests/run.sh 不需要玩家存档。

## 8. 复现与接续操作

以下命令从本分支仓库根目录执行。先将 TOME_ENGINE_ROOT、
TOME_DLC_ROOT、TOME_SAVE_ZIP 指向实际本体源码、DLC 输入根目录和存档副本。

```bash
# 常规回归；脚本内部设置 Lua 5.1 / LuaJIT 搜索路径。
bash tests/run.sh "$TOME_ENGINE_ROOT" "$TOME_DLC_ROOT"

# profile 输入与结果使用新目录，避免覆盖已记录的本轮证据。
python3 -B tests/profile/prepare.py --engine "$TOME_ENGINE_ROOT" \
  --save "$TOME_SAVE_ZIP" --out /tmp/tome-profile-next-data
python3 -B tests/profile/run.py --engine "$TOME_ENGINE_ROOT" \
  --data /tmp/tome-profile-next-data --results /tmp/tome-profile-next-results

# 生成当前分支的实验包到 dist/；releases/ 中的历史包不受影响。
python3 -B tools/package.py
```

prepare.py 不执行存档代码。run.py 需要 Linux 上的 GCC、SDL2 开发文件和 LuaJIT 5.1 ABI
库，并检查所用本地头文件／SFMT 与固定源码一致；这套编译命令不能直接用于 Windows。
TOME_LUAJIT、TOME_LUAROCKS_ROOT 可覆盖测试解释器和依赖位置。

完整游戏中启用实验计时器：

```lua
local p = require('engine.FasterProfile'); p.start(); p.reset()
-- 执行预定测试，等待保存协程结束，再输出并停止：
local p = require('engine.FasterProfile'); p.report(); p.stop()
```

若需覆盖初始读档，应在 addon 加载前配置 `config.settings.faster_tome.profile = true`。
日志前缀为 `[FasterProfile]`。不要在未完成调用期间 reset，不要把嵌套方法的累计跨度相加。
这一游戏内计时入口已通过隔离语义回归，但尚未在完整游戏中运行验证。

接续顺序为：准备兼容的实际游戏与存档依赖环境 → 保持相同配置采集基线 → 验证有限粒子
实验版 → 实现并验收 Fearscape／inventory 的保守迁移 → 根据剩余热点选择保存或 DLC 优化。

文件身份校验：

| 文件 | SHA256 |
| --- | --- |
| 原 Faster 0.0.1 包 | `030d9d4c86c98986e09ac8864991b7948a84263d9c8e23020ddae266b63882ea` |
| 0.1.0 包 | `7e57245a44c9aca46d29c8f9532fbe1a0f8aead3fd9539d64995b80ae5511869` |
| 0.2.0 包 | `52c05a31a569ab650e1862cf3af824efff52b81f2b0ef86d5471df51d0878d01` |
| 0.2.1 profile 包 | `3a2f67df5d904db994219cddcc379dd36aa6e723b1d0339da5dd7b08bb82c126` |
| 原始上传存档 | `eac52e4bd612b2ec6477f71bae12b7844c3e8031813df2ad89fe6fac2c1915a7` |

本体衍生代码保留 GPL-3.0-or-later 及原作者版权声明。本文是当前交付状态的汇总入口，
公开测量结果和源码身份保留在上述 evidence 与 Git 历史中；完整玩家输入仅留本地。
