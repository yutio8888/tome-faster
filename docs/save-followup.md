# 0.2.5 保存后续：减少序列化回调分配，保留现有保存协议

2026-09-13；ToME 1.7.6 / `624a67329fe2ad440c5b344785a9c73fcf22ae63`。
本轮已交付 serializer 回调复用，减少临时 Lua 闭包分配。**三组真实保存 A/B 没有显示稳定的 CPU 或最长停顿改善**；完整快照裁剪、冻结保存事务和 GC 调度仍未实现。
结构化数据见 [save-followup-results.json](save-followup-results.json)，局部实验、固定源码反例与复现命令见 [证据说明](../evidence/faster-tome4-save-followup/README.md)。

## 生产实现与兼容边界

原 `engine/class.lua:443–477` 每保存一个对象，创建两个捕获同一 Savefile 的闭包：取得 entry 名称、将引用对象加入保存队列。
[`FasterSaveFollowup.lua`](../overload/engine/FasterSaveFollowup.lua) 在该 Savefile 内复用这两个回调；回调仍动态调用 `getFileName/addToProcess`，原 native serializer userdata 仍按原时机释放自己的 registry 引用。
缓存同时使用 weak keys 与 weak values，避免 Lua 5.1 中缓存经闭包反向保留整个 Savefile。

[`hooks/load.lua`](../hooks/load.lua) 对已经载入的 `engine.class` 安装此项。仅接受固定原 `class.save` 的来源、行号及 upvalue 形态，并要求原生 C serializer；未知覆盖保留原方法，晚替换 `core.serial.new` 时回退。
这属于保守兼容检查，不能当作任意第三方实现的完整认证。

完整对象图、过滤器、原临时元表、`onSaving/save` 顺序、每对象 yield、三次完整 GC、截图、ZIP writer、保存限制和异常语义均保留。
例如 raw `_no_save_fields` 覆盖 allow/disallow 的原 C 行为，以及序列化报错后对象留下空元表的原行为，都没有在此项中修改。

关闭并重启：

```lua
config.settings.faster_tome.save_callbacks = false
```

实际命中诊断默认关闭，可在诊断阶段使用 `enableDiagnostics(true)`、保存后 `getDiagnostics()`、最后 `enableDiagnostics(false)`。
不要包装 `core.serial.new` 来测量此项，因为该操作会正常触发兼容回退。

## 分配差分与真实安装验证

固定 C serializer/worker fixture 在 LuaJIT JIT 开启和关闭时各通过 **562 项检查**，覆盖真实 entry 字节、过滤器、别名/环引用队列、LIFO 顺序、每对象 yield、弱引用/析构、交错 Savefile、第二次保存、错误身份及重试。

2,853 对象合成图，2 组预热、9 组交替顺序，两侧计时期间均暂停 GC，关闭回调身份追踪：

| 中位数 | 原版 | 共享回调 |
| --- | ---: | ---: |
| Lua 新增分配 | 2,887.445 KiB | 2,489.902 KiB |
| 序列化及对象调度 CPU | 4.502 ms | 4.458 ms |

局部分配减少 **397.543 KiB，约 13.77%**；CPU 约持平。该实验不含真实快照、截图、压缩、磁盘或游戏调度，不能外推为游戏峰值内存下降或完整保存加速。

真实诊断 `stutter-save-followup-audit-01` 得到 **2,854 次 optimized、0 次 fallback、2 对回调**，对应 Game 和 World 两个 Savefile；三次完整 GC 均仍执行。
该诊断启用 `detail=true`，其 `dumpToJSON` 包装使离线导出兼容检查回退并执行了额外导出工作，**不纳入 A/B 性能样本**。
其中首次快照 103.638 ms、截图 50.944 ms、三个完整 GC 合计 106.364 ms，仍是后续热点线索。
这些包含嵌套调用，不能相加；跨 yield 的 `Savefile.saveObject` span 也不是其独占执行时间。

## 三组真实保存 A/B

每次从相同原档的新副本启动，预热约 2 秒；顺序为前/后、后/前、前/后。
只切换 `save_callbacks`，两侧均 `detail=false`、快捷栏文字缓存开启、地图 mask 批处理关闭；既有 0.2.4 保存优化开启。
环境为 Linux / LuaJIT 2.0.2 / Ryzen 7 9800X3D / llvmpipe / Xvfb 1280×800，约 30 FPS 上限，离线测试。

| 指标，中位数 | 关闭回调复用 | 开启回调复用 |
| --- | ---: | ---: |
| `Game.saveGame` 同步调用 | 168.141 ms | 171.841 ms |
| 同步调用主线程 CPU | 159.445 ms | 165.162 ms |
| 发起保存至观察到完成 | 601.469 ms | 584.809 ms |
| 保存阶段主线程 CPU | 481.291 ms | 488.158 ms |
| 最长显示回调间隔 | 176.787 ms | 179.873 ms |

流程三组分别为 602.658 / 601.469 / 586.548 ms，开启后为 582.483 / 584.809 / 635.390 ms。
第三组方向反转；同步调用、CPU 和最长显示间隔也未改善，因此不能把较低的流程中位数宣传为稳定保存加速。
保存流程包含协程、后台压缩/写盘和观察延迟，不等于主线程持续阻塞时间。

六次进程均 `exit_code=0`、`completed=true`、完成标记存在、`turn_delta=0`。
各次选定状态比较均通过：27 个现有角色、203 件物品，选定角色/队伍/任务/资源/技能/效果/背包字段的 changed/added/removed sections 均为 0。
这属于选定业务字段检查，不是完整世界等价性证明。

原始 session 名称：`stutter-save-callbacks-v1-{before,after}-pair{1,2,3}-01`。

## 根字段消费者与真实图审计

`Game.save/defaultSavedFields` 的持久化白名单不能直接作为快照保留白名单：

- 实际 `PlayerDumpJSON:387` 读取 `game.uiset.logdisplay:getLines(30)`，写入在线资料日志；固定原段差分已证明裁掉 uiset 会报错。
- 同 exporter 在 `44,354` 读取 `calendar` 生成死亡/成就日期；`__mod_info` 用于保存 metadata、UUID 和资料标签。
- `Game.save` 读取 `last_update/real_starttime`；晚注册 UUID 的等待界面还会进入 clone 的对话框上下文。
- 物品/技能/任务描述和导出 hook，以及自定义 `save/onSaving` 都是额外消费者；全局 hook 注册表不能只由 `Game.__persistent_hooks` 判断。
- Cults 外层 `saveGame` 的竞技场禁止保存逻辑必须保留。截图在 clone 之前执行，但这不能证明 clone 中任意显示字段都没有其他消费者。

只读 `FasterSnapshotAudit.run(game)` 在正式保存计时外取得 **128,179 张 raw 表**。它统一去重，并在返回 Game 根的引用处停止；只报告结构数量，不裁剪也不调用保存 hook。

| 根字段 | 单分支可达 raw 表 | 删除这一根边的独占 raw 表 |
| --- | ---: | ---: |
| uiset | 36,899 | 694 |
| calendar | 14 | 14 |
| flyers | 2 | 2 |
| tooltip | 1,055 | 1,039 |
| target | 36,206 | 5 |
| dialogs | 1 | 1 |
| key | 209 | 0 |
| mouse | 30 | 30 |
| cults_book_data | 5 | 5 |

最大候选 tooltip 的 1,039 张独占 raw 表仅占本次 raw 图 **0.81%**；此比例不代表 clone CPU 成本或已证明可删的比例。
uiset/target 的分支数很大，但大部分通过其他路径共享，不能把整个分支规模算作可省量。
图中还观察到 1,139 个弱表、49 个 raw `__SAVEINSTEAD` 和 9 个不透明 `__index`；特殊替代引用、弱引用及 hook 依赖仍需逐项证明。
因此本版继续完整复制快照；后续可以先审计 tooltip 的实际消费者与特殊引用，再决定局部根裁剪是否值得实现。

## GC 与后台切片：已否决的具体实现，尚未交付的工作

固定源码 fixture 已执行三个反例：

| 候选实现 | 实际观察 | 当前处理 |
| --- | --- | --- |
| 把前两个相邻完整 GC 合成一次 | A 析构后删除 B 的最后强引用；一次 GC 后 weak B 仍存在，两次 GC 后 B 也析构且 weak 被清除 | 保留三次原完整 GC |
| `step` 到首次 true 替代完整 GC | 完成旧标记周期仍可能保留 weak 值，新 full GC 已清除 | 不采用 first-true 屏障，也不承诺 atomic 阶段硬毫秒上限 |
| 每产生一个对象就唤醒原 worker | 队列暂空即 close/回报完成；同一 archive 分两批产生会两次 CREATE，原一次性入队仅一次 | 保留原 worker 协议 |

这些反例否决的是上述具体形态，不代表所有进一步优化都不可能。
冻结后分片需要同一保存时点、受控界面写入、weak/finalizer 边界，以及二次保存、退出和错误顺序的完整事务。
真正的生产/压缩流水需要 BEGIN/ENTRY/END/ABORT、背压和完成/错误回传；现有公开接口没有这套协议。
完整根裁剪、冻结事务、GC 调度和新 writer **仍未实现**，不能用本轮闭包分配收益替代其验收。

## 重载及完整性

六份 A/B 输出逐一遍历保存目录的所有普通文件，以 `zipfile.is_zipfile` 识别档案，并检查所有 entry CRC。
每份包括 **22 个角色档案和保存根目录的 1 个 `world.teaw`，共 23 个 ZIP**，全部通过。

`render-save-roundtrip-20260913` 从 after-pair3 的角色目录打包输入，重新加载、空闲约 **5.027 秒**、再次保存并正常退出，空闲及保存 `turn_delta=0`，选定业务状态一致。
此输入与原始角色 ZIP 的目录结构一致，**没有携带上轮保存根目录的 `world.teaw`**；因此这里验证的是角色档案重载及再次保存，不能宣称上轮 World 全局内容也已重载。
新输出的 22 个角色档案及 World 共 23 个 ZIP 均通过 CRC。

随后 `render-save-full-roundtrip-20260913` 使用 after-pair3 的完整保存目录作为输入，包含同一份 22 个角色档案和旧 `world.teaw`。
已逐档案核对输入中的 23 个 ZIP 与源输出字节相同，且外层输入归档及全部内层 ZIP CRC 通过。
该完整输入重新加载后空闲约 **5.024 秒**、再次保存，进程 `exit_code=0`、`completed=true`，空闲及保存 `turn_delta=0`，选定业务状态一致；新输出 23 个 ZIP 的所有 entry CRC 均通过。
完整输入 SHA256 为 `80afc4c8578b30fecf9559fbd85db40fb401b16eb0ed8e24c1cacc48f9fad88b`。
这补充了携带上轮 World 的重载路径，但选定状态及 CRC 仍不是每个 World 字段的完整语义等价证明。
连同六份 A/B 和两次重载，本报告检查 **184 个输出 ZIP**。

结论仅覆盖当前一个输入存档和 addon 组合；没有覆盖 Windows/macOS、硬件 GPU、Steam/云保存或实际在线资料发送。
