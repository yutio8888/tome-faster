# 保存后续：回调分配优化与其余候选的实际边界

2026-09-13；ToME 1.7.6 / `624a67329fe2ad440c5b344785a9c73fcf22ae63`，addon 基线 0.2.4。
本目录的原型、诊断及测量不进入安装包。真实游戏 A/B、存档重载及发布由集成阶段另外记录。

## 可集成改动：复用 native serializer 的两个回调

`engine/class.lua:443–477` 每个对象均创建 `namer` 和 `processor` 两个闭包，捕获同一个 `engine.Savefile.current_save`。
`src/serial.c:257–290` 把它们注册在 Lua registry；`serial_free:293–303` 在 userdata 原有的 GC 时机释放这些注册。
回调除了查当前 `savefile:getFileName(t)` 和 `savefile:addToProcess(t)` 外没有其他状态。

[`FasterSaveFollowup.lua`](../../overload/engine/FasterSaveFollowup.lua) 在同一个 Savefile 内共享这两个闭包。
缓存同时使用 weak keys 和 weak values；闭包保留 pair，pair 保留闭包，每个闭包仍捕获 Savefile。
原 native userdata 存活时仍强引用 Savefile，全部原 userdata 析构后缓存不会保留 Savefile。
不能只用 weak keys，因为 Lua 5.1 不是 ephemeron 语义，值经闭包回指 key 会泄漏整个保存对象。

安装：`require("engine.FasterSaveFollowup").installClass(class, config.settings.faster_tome)`。
`save_callbacks=false` 并重启可关闭。仅替换匹配来源、行号、无 upvalue 的固定 `class.save`，要求 `core.serial.new` 为 native C；已安装的方法幂等。
后续替换 `core.serial.new` 时调用原方法，保留替代 serializer 接收到的独立回调身份。
guard 是保守兼容判断，不是 native 函数代码哈希认证。

实际保存安装命中诊断：先 `FasterSaveFollowup.enableDiagnostics(true)`，保存完成后调用 `getDiagnostics()` 获取 `calls/optimized/fallbacks/callback_pairs`，最后 `enableDiagnostics(false)`。
诊断默认关闭，不包装 native 工厂；工厂包装会正确触发 fallback，不能用于计量此项。

保留全部对象、过滤器、原临时空元表、对象队列、`onSaving/save` 次序、每对象 yield、三个完整 GC、worker 唤醒点、CULTS 保存限制及原异常行为。
尤其保留原本序列化报错后留下空元表的行为；此项没有夹带修正错误恢复。
既不裁快照，也不调整 GC 周期或改写 ZIP 格式。

### 实测及复现

[`tests/test_save_followup.lua`](../../tests/test_save_followup.lua) 编译固定源码中的实际 C serializer 和 `thread_save`。
[`tests/save_callbacks_fixture.c`](../../tests/save_callbacks_fixture.c) 仅提供内存字节 sink 和可控的 ZIP/semaphore 替身，不使用真实用户存档或网络。

```sh
luajit tests/test_save_followup.lua . /workspace/t-engine4
luajit -joff tests/test_save_followup.lua . /workspace/t-engine4
TOME_SAVE_FOLLOWUP_BENCH=1 luajit tests/test_save_followup.lua . /workspace/t-engine4
```

JIT 开/关分别通过 **562 项检查**，包含：真实 entry 字节、别名/环引用注册、LIFO 次序、逐对象 yield、raw/继承 `_no_save_fields`、disallow2 覆盖行为、原 native userdata 数量及释放、弱引用可达性、交错 Savefile、第二次保存、晚替换、异常身份及重试、无 factory 包装的实际 guard 诊断。
还执行后文的 GC/worker/根字段反例。

2,853 对象合成图、2 组预热、9 组交替顺序的局部微基准：

| 中位数 | 原版 | 共享回调 |
| --- | ---: | ---: |
| Lua 新增分配 | 2,887.445 KiB | 2,489.902 KiB |
| 序列化与原对象调度 CPU | 4.502 ms | 4.458 ms |
| 每个 Savefile 的不同回调对数，独立功能检查 | 2,853 | 1 |

Lua 分配少 **397.543 KiB / 13.77%**；CPU 约持平。测量时两侧均暂停 GC，之后恢复；关闭回调身份追踪，避免追踪用 weak table 的存储被算成优化收益。
包含 fixture 的内存输出 entry，**不含真实 Game 复制、截图、ZIP 压缩、磁盘与游戏调度**。
此证据支持“减少临时闭包分配”，不能宣称已减少完整游戏的 100 ms 停顿。
原始 [benchmark.txt](benchmark.txt)、[results.json](results.json)、[JIT on](tests-jit-on.txt)、[JIT off](tests-jit-off.txt)。

## 相邻 GC 合并：严格保持 finalizer/weak 时不能用一周期替两周期

固定链路为 `SavefilePipe.doThread:157` 的 GC → `getPlayer().changed`、`Savefile.new/init`、saveversion 字段赋值 → `Savefile.saveGame:255` 的 GC。
两者之间没有序列化/yield，并不意味着两个周期等价。
fixture 使用两个真实 `newproxy` userdata：A 的 finalizer 删除全局注册表语义的最后一个 B 强引用。

| 序列化前屏障 | finalizer 轨迹 | weak value B |
| --- | --- | --- |
| 一次完整 GC | A | 仍存在 |
| 两次完整 GC | A, B | 已清除 |

两周期差异发生在序列化开始之前，不依赖时间统计或推测。
即使首项为固定 Game、固定 Savefile、固定 init，也无法仅靠这些函数的来源检查排除 Lua VM 中其他 native/userdata finalizer 产生这种链。
World GC 与 Game GC 之间更已经序列化整个 Game，不能合并。
因此在“保持 finalizer 与弱引用可观察行为”的约束下，**否决的是删除相邻一次 GC 的实现**。
可以执行且已经实现的替代方向是减少屏障前产生的分配；本次 callback 复用即属此项。

## `step` 到第一次 true：不是完整 GC 的等价屏障

fixture 通过公开 `collectgarbage("step", 1)` 进入已有标记周期，随后移除对象的最后一个普通强引用。
完成该旧周期时，已标记对象仍可从 weak value 读取；换成新的 `collect` 后 weak value 已清除。
测试自动找到尚未完成的标记点；具体 step 编号取决于 LuaJIT 根集合，不把它当成通用常数。

固定 `src/luajit2/src/lj_gc.c:715–737` 的 `lj_gc_fullgc` 先处理已有状态，再开始新的完整周期；`step` 完成旧周期没有这一承诺。
同文件 `613–620` 的 atomic 阶段整块运行，没有 Lua addon 可用的中途让出点。
增加一次/两次完成信号也会引入不同数量的周期，不能未经证明替代原屏障。
因此 **否决 first-true 替代和固定毫秒硬上限这两种承诺**，没有把所有增量 GC 研究宣布为不可能。
下一实现必须在固定 VM 上定义起始阶段/新周期语义、保留 finalizer 与 weak 观察点，并测 atomic 最长时间；现有 Lua API 没有直接读取/重置 GC 阶段的可靠接口。
当前可移植 addon 保留三个完整 GC，先减少分配。

## Game 根快照：已经找到“看似显示字段”的实际消费者

`Game.save:744–748` / `engine.Game.defaultSavedFields:123–137` 只是持久化字段集合。
不能把它当作 `SavefilePipe.push` 返回 clone 的全部消费者依赖。

| 根字段/入口 | 具体消费者 |
| --- | --- |
| `uiset` | `mod/class/interface/PlayerDumpJSON.lua:387` 读取 `game.uiset.logdisplay:getLines(30)` 写入在线资料 `last_messages`。fixture 执行固定原段，裁掉 uiset 后直接报错。 |
| `calendar` | 同 exporter `44,354` 生成死亡/成就日期；也不在 Game 根持久化默认白名单中。 |
| `__mod_info` | `Savefile.saveGame` 写 desc.lua；exporter 写标题/模块/addon 标签；`getUUID` 用 short_name。 |
| `last_update/real_starttime` | `Game.save` 更新 total_playtime，必须保留其输入。 |
| `party/player/level/zone` | `getSaveDescription`、`isLoadable`、`isTainted`、成员子资料，以及描述与保存回调。 |
| `dialogs/key/mouse/uiset` | 保存 clone 仍可能进入晚注册 UUID：`saveUUID → getUUID → PlayerProfile.registerNewCharacter:876 → Dialog.simpleWaiter → game:registerDialog`；需要完整等待界面上下文。 |
| `cults_book_data` 等渲染根 | 截图发生在 clone 之前，本身不能要求 clone 保留；但显示、注册/恢复对话框及任意描述 hook 的可达性须另审。Cults 的 `useCultsBookLook/displayMap` 有实际读取，不能按名字“只是渲染”直接删。 |
| `_chronoworlds` | Cults 外层 `Game.saveGame` 检查 `multiverse_fight` 并保持禁止保存/确认回调。删根方案不能绕过这一入口。 |

`Object:getDesc` 中的 `Object:descCombat/descWielder/descMisc/descPowerSource`，技能描述、任务 `desc` 及 `ToME:PlayerDumpJSON` hook 都是额外依赖入口。
`class.triggerHook:430–434` 的 `_hooks` 是类模块环境中的全局注册表，不能只检查 `Game.__persistent_hooks` 就声称没有未知 hook。
存档 `onSaving/save` 也不等于纯读取，例如 `engine.Projectile.save:43–47` 从全局 `game.level.map` 导出线路。

本次**否决 whitelist-only 和直接去掉整个 uiset 的实现**；没有证明其他任意 root 都必须完整复制。
下一可执行步骤由 [`FasterSnapshotAudit.lua`](FasterSnapshotAudit.lua) 提供：在真实保存计时外调用 `run(game)`，输出候选 root 的 raw 子图和删除单条 root 边的独占表数。
它对共享引用统一去重，遇到返回 Game 根的引用停止，且不执行任何 metamethod、保存 hook、导出或截图。
仅保留表计数、字段名和类型，不记录角色内容。
诊断会报告 weak、raw `__SAVEINSTEAD`、`__threads` 及不透明 `__index`；数值是候选筛选依据，**不是克隆等价性证明**。
选择独占收益最大的候选后，需要消费者来源清单、hook 注册签名和 `__SAVEINSTEAD/__threads` 跨边差分 guard，再做根裁剪；当前仍保持完整 clone。

## 现有异步 API：按对象唤醒会提前完成并再次 CREATE

公开 `core.serial` 只有 `new/threadSave/popSaveReturn`，没有 BEGIN/END/ABORT 或“生产暂空但未结束”标志。
fixture 直接执行固定 `thread_save:160–224`，在可控 semaphore 唤醒之间分两批生产同一个 archive：

| 模式 | `serial_new` CREATE 次数 | worker close | 完成回报 |
| --- | ---: | ---: | ---: |
| 原版，先产生两个对象再唤醒 | 1 | 1 | 1 |
| 每产生一个对象就唤醒 | 2 | 2 | 2 |

原因是队列暂空时 worker 清空 `last_zipname/last_zf`、关闭归档并回报完成；下一 `serial_new` 用 `APPEND_STATUS_CREATE` 重新打开同名归档。
这证明错误形态会提前报告不完整归档，并有覆盖第一批的风险；本实验不通过真实线程竞态或磁盘损坏“证明”风险。
原版 `Savefile.saveObject` 已逐对象 yield；一次 C `toZip` 没有可恢复的 byte-buffer continuation。

**否决 per-object threadSave 和让 native worker 直接复制 Lua graph**。
可执行的新协议需要字节型 BEGIN/ENTRY/END/ABORT、有界背压、完整/错误回传及退出排空；worker 不得操作主 VM。
若仍要求单一跨平台 Lua `.teaa`，实际可用路线是纯 Lua encoder + `fs.zipOpen/:add` 的兼容 writer，但 ZIP 压缩会在主线程执行。
必须先对本体 allow/disallow2、函数字节码、对象队列、错误和 ZIP 条目做字节/重载差分，不能把“已有后台线程”当作现成流水协议。

保持同步完成但允许重绘的等待事务是另一条独立路线：`core.wait` 下 `src/main.c:654` 会绕过真实 Game.display。
它需要在完整描述方法/复制检查点之间显式推进，不允许任意跨 C 调用 yield；原 `forceWait`、二次保存、退出及异常顺序仍需同一事务处理。
这改善界面响应，不能报告为允许继续战斗，也不能保证减少 CPU。

## 当前结论

本轮交付一个分配优化及四类可执行反例/读依赖证据。大幅降低首次快照/GC 停顿的工作仍未完成。
后续真正可发布的根裁剪、冻结切片或新 writer 必须满足各自的完整协议和验证，不能用本轮 callback 的小幅分配收益代替这些验收。
