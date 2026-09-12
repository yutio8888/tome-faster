# 0.2.2 之后的保存优化：可交付方案与验证边界

分析日期：2026-09-12。引擎固定为 ToME 1.7.6 / `624a67329fe2ad440c5b344785a9c73fcf22ae63`，当前 addon 为 0.2.2 / `d4dbf77`。本文研究后续方案，**候选没有加入可安装 addon**。目标是保留战斗、角色、物品、存档和在线资料语义；可以增加实现复杂度，但不能用丢弃有效工作换取计时下降。

文中“实测”来自已完成的本地诊断；“源码结论”是固定源码能支持的机制判断；“待验证”不能当作游戏加速结果。引擎路径前缀 `engine/` 指 `game/engines/default/engine/`，`mod/` 指 `game/modules/tome/`。

## 目前剩余多少开销

0.2.2 的三组完整保存 A/B：同步 `Game.saveGame` 中位数 459.182 → 205.085 ms，完整保存流程 911.499 → 619.968 ms；这是两项优化共同启用的结果，不能分别归因。已有结果见 [save-stutter.md](save-stutter.md) 和 [save-stutter-results.json](save-stutter-results.json)。

随后启用 0.2.2 做三次细分计时，保留导出 guard 的真实函数身份，没有包装 `dumpToJSON`：

| 指标 | 三次值，ms | 中位数，ms | 所属阶段 |
| --- | --- | --- | --- |
| 同步 `Game.saveGame` | 212.83 / 206.55 / 193.34 | 206.55 | 保存请求的长调用 |
| 当前 `Game.cloneForSave` | 114.50 / 112.87 / 103.92 | 112.87 | 同步阶段 |
| 截图 | 50.82 / 50.27 / 49.49 | 50.27 | 同步阶段 |
| `Party.cloneFull` | 39.67 / 35.68 / 31.97 | 35.68 | 同步阶段 |
| `saveUUID` | 0.0123 / 0.0128 / 0.0159 | 0.0128 | 离线快速返回已生效 |
| 3 次完整 GC 合计 | 106.58 / 96.37 / 107.70 | 106.58 | `saveGame` 返回后的保存管线 |
| 最长单次完整 GC | 44.31 / 42.29 / 42.93 | 42.93 | 管线中的单次长调用 |

本地会话为 `tmp/profile/sessions/stutter-next-save-detail-{01,02,03}`。这些 span 包含嵌套调用，不能相加；细分包装也有观测扰动。之前同一真实图上预热后的 73.084 ms 克隆，不应代入首次实际保存的 112.87 ms。此次 GC 合计不在同步 `saveGame` 的 206.55 ms 之内。

较早的未优化保存诊断曾测得一次导出生成 190 份物品描述、155 份技能描述；物品描述约 159 ms、技能描述约 41 ms。当前真实角色在线内容验证得到 263,388 字节 JSON，原版与优化版的解压内容、标题和标签一致。**在线内容一致已经验证，当前在线保存耗时尚未重新测量。**

## 建议优先级

| 顺序 | 候选 | 能改善什么 | 当前证据 | 跨平台 addon |
| --- | --- | --- | --- | --- |
| 1 | 在线导出的 gzip 实现替换 | 修复逐次原生内存泄漏和短输入失败；可能改善长时间运行后的压力 | 真实引擎微测试已证实问题与候选行为 | 可以，使用引擎已带的 lzlib |
| 2 | Party 专用 `cloneFull` 特化 | 减少当前约 36 ms 复制中的 Lua 开销，保留回调与 RNG 顺序 | 源码可行；合成图候选约快 9%，真实图待测 | 可以，纯 Lua |
| 3 | 管线前两个相邻完整 GC 的合并试验 | 减少重复遍历，可能降低一个约几十 ms 的停顿 | 调用关系明确；等价条件和真实收益待验证 | 可以，纯 Lua，但需要严格限域 |
| 4 | 在存档协程里分步 GC | 分散部分 GC 停顿；不会降低全部 GC CPU | VM 有增量接口，也有不可分的 atomic 阶段 | 可以；不能承诺固定毫秒上限 |
| 5 | 在线资料、Party 复制的同步分片与等待画面 | 保留同步语义，同时让画面与进度有响应 | 现有等待绘制接口支持；完整原型待验证 | 可以；仍需短暂阻止游戏行动 |
| 6 | 只缓存已证明稳定的导出子结果 | 减少重复描述计算 | 尚缺重复率及失效依赖证据 | 可以，按方法与依赖白名单交付 |
| 7 | 允许继续游戏的完整后台导出 | 最大限度分散在线资料开销 | 需要快照隔离、上下文捕获、排队和退出屏障 | 协程方案可以；通用原生工作线程不属于现成 addon 接口 |

这些优先级同时考虑问题确定性和可交付性。第 1 项不是立刻消除主线程长帧的 CPU 优化；第 3、4 项针对管线的后续停顿，不会直接消除前面的截图与快照长调用。

## Party 克隆与清理：保留工作，优化执行

### 这份临时 Party 确实被丢弃，但清理会确定地消耗 RNG

`mod/class/Game.lua:2854–2886` 先入队游戏快照、保存 World，再克隆 `game.party`，逐成员设置 `save_cleanup`、调用 `stripForExport`，最后调用的是 `game.player:saveUUID(nil)`，没有传入临时 Party。

它不是无副作用的死代码：

- `engine/class.lua:236–265` 在 `cloneFull` 中调用每个对象的 `cloned`；`Entity.cloned:186` 分配全局 `next_uid` 并更新 `__uids`。
- `Actor.stripForExport:355` 调用 `removeEffectsSustainsFilter:7244`。后者先执行 `effectsFilter`、`sustainsFilter`，再调用 `rng.tableSampleIterator`。
- `game/loader/pre-init.lua:106,119` 明确规定：即使 `k=nil` 表示全选，`rng.tableSample` 和 `tableSampleIterator` 也仍调用 `rng.range` 洗牌。不是只在随机选一部分时才消耗 RNG。
- 持续技能停用及效果移除会调用 `dispel`、`forceUseTalent` 和效果回调，可能继续操作粒子、全局游戏、回合末队列。

因此，删除清理、少调用一次抽样，或者让下一次攻击先消耗 RNG 再异步清理，都会改变原游戏随机序列。0.2.2 导出检查证明的是 **`saveUUID` 本身没有消耗 RNG**，并不证明上游 Party 清理没有 RNG。

### 可行候选 A：专用于 Party 的原语义复制

0.2.2 只优化了 `Game.cloneForSave`。`Party.cloneFull` 仍进入通用 `clonerecursfull`，其 `noclonecall=nil`、`use_saveinstead=nil` 固定不变。可增加 `superload/mod/class/Party.lua` 和专用 Lua helper：

1. 检查继承到的 `cloneFull` 及递归 helper 仍为固定原版；未知覆盖回退。
2. 把固定为假的 `use_saveinstead` 分支与参数传递从复制热路径移除。
3. 仅对 table 键和值查 memo；仍以原 `next` 次序递归，保留 `__threads` 已在 memo 中时必须使用克隆的细节。
4. 按原后序位置调用 `n:cloned(d)`；保留元表查询次序、对象计数相关查询及 `post_copy` 的 `table.merge`。
5. 不替换 Actor 自己的 `cloneFull`，不改 `cloned`，不跳过清理。

这种改动保留实际复制图与副作用顺序，复杂度主要是再维护一个固定版本 helper。

本地纯 Lua 合成试验使用固定源码、2,000 个带 `cloned` 的模拟成员、成员对象表键、共享引用、自环及 `__threads`。两种实现的 **2,001 次 `cloned` 顺序及对应 UID 分配一致**。15 对交替计时、4 对预热，LuaJIT 2.1.0-beta3：

| 合成候选 | 原版中位数 | 候选中位数 | 判断 |
| --- | --- | --- | --- |
| 仅移动 type/memo 判断 | 2.419 ms | 2.661 ms | 约慢 10%，不能直接照搬 Game 的收益 |
| 同时特化固定参数和分支 | 2.331 ms | 2.124 ms | 约快 8.9%，值得测真实 Party |

这是合成 CPU 试验，不是 Yron 的 36 ms 已经下降。两个原型脚本和[汇总数据](../evidence/faster-tome4-followup/party-clone-results.json)保存在 `evidence/faster-tome4-followup/`，没有进入发布包。可从 addon 仓库运行：

```bash
luajit evidence/faster-tome4-followup/party-clone-lookup.lua /path/to/t-engine4
luajit evidence/faster-tome4-followup/party-clone-specialized.lua /path/to/t-engine4
```

正式验收应使用真实加载后的 Party，记录克隆图、每类 `cloned` 回调、UID 顺序、清理后的 RNG 调用参数序列及重新加载结果。

### 可行候选 B：减少过滤器私有数组分配

`effectsFilter` 和 `sustainsFilter` 都新建局部列表，再用 `rng.tableSample` 生成第二张列表，原局部列表不再使用。可在这两个已知方法的私有函数环境里替换 `rng.tableSample`：对它们私有的新数组做原位 Fisher–Yates，保持完全相同的 `rng.range(i,n)` 调用与输出顺序，再按 `k` 截断。

这不应成为全局 `rng.tableSample` 修改，因为公共 API 原本不会改调用者的输入；也不应省略“全选时的随机调用”。先对各 `n/k` 和随机序列做差分，再确认真实清理中的分配或耗时值得处理。此项预计只节省小型临时数组，优先级低于 Party 复制。

### 更小的 Party 快照

保留任意 `cloned`/清理回调的前提下，不能根据“最终 Party 不上传”就删除部分复制图；回调可以访问那些字段。正向路线是逐类证明只读、不可达或没有任何观察者的子图，再精确共享或省略。建议先记录真实 Party 子图各字段的表数与累计字节，选择最大分支做读依赖审计；未知 class、元表、回调一律保留完整复制。

“只执行回调、按原数量消耗 UID，但不建对象”的方案通常不能保持语义：回调需要真实别名图与新对象身份，且会把引用放入全局仓库。它不是本轮值得优先原型化的方向。

## GC：先减少重复周期，再研究分片

### 可以试验合并的确切位置

`SavefilePipe.doThread:157` 进入协程便完整 GC；随后新建 `Savefile`，第一项若为 game，则 `Savefile.saveGame:255` 开头再次完整 GC。`Savefile.init:47` 主要创建队列表并更新 `current_save`，两次 GC 之间原版没有正常的存档对象序列化和协程 yield。World 的第三次 GC 在 `saveWorld:176`，它与前一次之间已经完成游戏对象序列化，不能一并删除。

可做一个严格限域候选：仅当管线首项为标准 game、标准 `Savefile` 类、所有中间入口均为固定本体时，把 `doThread` 前置 GC 省去，仍保留紧随其后的 `Savefile.saveGame` 完整 GC。首项为 zone/level/entity、自定义保存类或未知覆盖时保持原版，因为这些入口并不都自己完整 GC。

这比“删除所有保存 GC”更有可验证性：第一个档案的序列化仍在完整 GC 之后。但 **两次相邻完整 GC 也不自动等价**：第一次可能运行 finalizer、清理弱表或释放另一层引用，第二次可能回收因此变为不可达的对象。需要比较两点之间的 finalizer 行为、弱表内容、保存图与实际文件，而不是只比较 Lua 堆 KB。

安装入口可放在 `hooks/load.lua`，处理已提前加载的 `engine.SavefilePipe`/`engine.Savefile` 缓存类；用受限函数环境的 `collectgarbage` 适配器或固定 `doThread` 替代体实现。不要全局包装 `collectgarbage` 来省略任意调用。正式开关应与克隆及在线导出开关分开，以便独立 A/B。

### 分步 GC 确实能做，但预算不是硬实时保证

`collectgarbage("step", k)` 在 LuaJIT 2.0.2 可用并报告一个周期是否结束。保存管线已经是协程，可在已知 `doThread` / `saveGame` / `saveWorld` 的 GC 点进行小步回收，预算耗尽时 yield，然后继续直到完成，之后才开始相关档案序列化。正常后台保存可以利用 `Game.registerCoroutine`；`SavefilePipe.forceWait` 会持续 resume 同一协程，适合退出或显式等待时排空。

不能把 `step` 参数当作毫秒：`lj_api.c:1163` 把它换成内存债务；`lj_gc.c:614` 的 atomic 阶段整块执行，单个大型表传播和 userdata finalizer 也可能超过预算。分片可降低多轮传播/清扫累积的长调用，不能承诺“GC 永不超过 2 ms”。

另一个容易漏掉的差别：`lj_gc_fullgc:715` 会结束/重置此前的部分周期，再完成一个新的完整周期；“step 到第一次返回 true”可能只是完成一个早已开始的旧周期，并不等价。若采用增量策略，应明确完成屏障的语义，并测量弱引用和析构器；不能把一次 true 直接称作替代了原完整 GC。

推荐先做三个独立原型对照：原版；仅合并前两次相邻 GC；不合并但采用增量屏障。记录完整周期次数、最长单步、总 CPU、Lua 堆峰值、RSS、被 finalize 的原生类型，以及两次保存之间移动/战斗是否出现新的周期性卡顿。保护峰值内存，不能用不断推迟回收把成本移到未来。

### 不能把主 Lua 状态的 GC 放进普通后台线程

对象图由主 LuaJIT VM 拥有，原生保存线程处理序列化后的缓冲区，不负责主 VM 的垃圾回收。addon 没有把共享 VM 的 GC 安全移交另一线程的接口。可交付的路线是减少分配、减少重复完整周期、主线程增量调度；修改 VM 收集器或引入并行 GC 是引擎层项目。

## 在线导出：从小而确定的修复到完整分片

### 立即值得交付验证：修复 gzip 原生资源释放

**已测：** `src/core_lua.c:4034` 的 `lua_zlib_compress` 调用 `deflateInit2`，但成功和失败出口都没有 `deflateEnd`。本地真实引擎会话 `stutter-next-gzip-verify-01` 使用 256 KiB 合成输入、每批 100 次调用；完整 Lua GC 后，以 glibc `mallinfo2` 的 `uordblks+hblkhd` 计，原方法每批增长 **26,817,600 字节**，连续两批一致。等价参数的 lzlib 候选每批增长 **0 字节**。

候选为 `zlib.compress(data, 9, 8, 31, 8, 0)`，参数匹配原版的 best compression / deflated / gzip / memLevel 8 / default strategy。原版能成功的 256、4,096、262,144 字节输入，候选 gzip 字节完全相同；0/1/2/8/16/64 字节短输入原版返回 nil，候选正常压缩并解压往返。100 次候选约 52.7–53.0 ms，原版约 53.7–54.7 ms，因此价值主要是修复**每次压缩约 261.89 KiB 原生内存泄漏**，不是大幅减少当次 CPU。

随后真实角色 263,388 字节 JSON 也已完成候选 gzip 的逐字节相同验证，统一结果见 [followup-results.json](followup-results.json)。可只给已知 `engine.interface.PlayerDumpJSON.saveUUID` 设置私有 `core.zlib.compress`，其余 core API 继续委托原环境；不用全局替换 native 函数。这样不改 JSON、gzip 格式、上传时机及消费端，也不影响 0.2.2 的 source guard。全平台引擎已注册 lzlib；仍需 Windows/macOS 的参数与往返兼容测试。0.2.2 离线已经不调用它，收益主要在在线保存及其他仍需压缩的资料导出。

### 先采用“仍同步，但可重绘”的分片，能保留最强语义

存在一条不必首先解决自由后台一致性的路线：保存调用仍同步完成，暂停游戏行动，利用等待画面在 Party 复制和资料生成的检查点重绘。这保持原调用者看到的完成顺序，退出保存也不需要新的异步完成 API。

现成基础：`Dialog.simpleWaiter:30` 建立 `core.wait` 等待模式；`src/main.c:652` 的 `call_draw` 遇到 `draw_waiting` 直接返回，**不会再调用真实 Game.display，也不会推进粒子关键帧**。`core.wait.manualTick` 会 PumpEvents；等待画面与游戏逻辑可分离。`forceRedraw` 也只调用绘制入口，不调用 `on_tick`。

实现可从保存分支创建一个闭包/协程开始，把复制循环和在线导出的物品、技能、子角色循环划分为小批次；外层仍在当前 `saveGame` 栈内 resume，批次间绘制等待画面，直到结束再恢复真实 `_G.game` 和玩家控制。仅在两次完整方法调用之间设检查点，不能在 `getDesc` 临时设置对象要求或技能临时字段后强行中断。

注意 native `manualTick` 的默认重绘节流是 `3000/requested_fps`，30 FPS 下约 100 ms；若目标更细，需要外层按 `core.game.getTime()` 主动 `forceRedraw`，同时使用等待模式，不能反复重绘完整世界。不要依赖指令计数 debug hook 强行 yield，它会干扰 JIT，也不能切开 native C 调用。

这主要改善可见响应与“窗口像死了一样”的体验，**不会让玩家行动在保存尚未完成时执行，也不保证总耗时下降**。应分别报告总保存时间、最长画面间隔和行动延迟，不能只报帧间隔改善。

具体入口可以是 `superload/mod/class/Game.lua` 的固定保存分支及新的分片 helper；资料部分采用 `superload/mod/class/interface/PlayerDumpJSON.lua`，按原 sections/成员/物品/技能次序构造相同 `js`。保持专用导出 hook 的执行次数和位置；遇到未知描述或导出覆盖时，可先回退同步原路径。

### 允许继续游戏的协程导出：可做，但需要完整任务协议

若下一阶段要求保存后立即继续移动，则需要明确实现以下机制，而非简单 `onTickEnd(function() saveUUID() end)`：

1. **保留保存时快照。** 可先复用本来已存在的 `cloneForSave` 结果，无须为了导出再复制整个游戏；但 `Savefile` 会执行 `onSaving`/`save`，例如 `Game.save` 更新游玩时间、`Level.onSaving` 清理字段。导出任务应在这些读写区域前完成，或单独保存它需要的字段。
2. **隔离执行上下文。** 每次 resume 前设置该任务的 `_G.game`，yield/error/return 后立即还原；还需捕获真实资料依赖的 `world`、profile、配置、语言、UI 日志及静态定义状态。不能让部分物品描述使用保存时状态，另一部分使用已经移动或换装备后的状态。
3. **保留随机顺序。** Party 清理必须在允许下一步战斗前完成。若延迟的描述或 hook 使用 RNG，也要保留调用次序，或将它判为不能后台执行。当前 Yron 导出本身为零 RNG，不代表任意角色/插件也是如此。
4. **保持任务 FIFO 和退出屏障。** 相同 UUID 的上传不得新旧颠倒；失败不能重复执行导出 hook；退出、切角色、关闭后台保存和 `forceWait` 必须排空或明确保留任务。不得静默合并相同 UUID 的两次有效上传。
5. **限制保留内存。** 每个待导出的完整快照约有十几万张表，不能无限累积。达到队列上限时恢复同步排空；完成后立即释放快照和缓存。

主 `Game.registerCoroutine` 按 tick 驱动，暂停时不应假定它仍稳定运行。可用显式请求 tick 或在可控 display/等待调度器里恢复任务；但必须避免让请求本身推进回合。现有保存协程可作为调度基础，主线程仍只执行一个任务片段，不能用“协程”声称已使用另一 CPU 核。

### 小快照与缓存的可行边界

最安全的小数据边界是 `dumpToJSON(js)` 完成后的普通数据表/JSON字符串：体积约 263 KiB，后续编码、压缩与传输不需要完整游戏图。它适合后续任务交接，但不会消除前面约 200 ms 的描述生成。

真正减少描述成本，可逐步引入两类缓存：

- **单次导出内缓存：** 先量化重复 `(对象身份, 描述参数, 使用者身份)` 或 `(角色, 技能)` 的比例；在同一冻结快照、已知纯描述方法、无相关 hook 时复用结果。每次导出立即丢弃缓存，无需跨回合失效。仍要证明原描述的临时状态、副作用和返回值别名允许复用。
- **跨保存缓存：** 从明确静态的数据开始，例如已确认不依赖角色/配置/语言的文本段；动态描述需要覆盖属性、天赋等级、装备、临时效果、识别、资源、语言及插件配置的修订号。仅使用 `game.turn`、物品 UID 或 `changed` 均不足以证明有效：同一回合也能换装备、调整设置，描述还读取 `game.player`。

若采用更小的角色快照，先对每个占比大的描述函数记录读依赖，再固定白名单，并保留未知函数的完整快照路径。普通 Lua 代理不能自动实现通用写时复制：已有字段赋值不会经过 `__newindex`，C 侧原始写入也不经过代理。读依赖分析可以帮助发现候选，不能替代动态回调的覆盖证明。

### 现有线程接口的真实边界

`core.serial.threadSave` 处理已生成的序列化缓冲区；粒子线程执行固定的粒子 Lua 环境；`core.profile.createThread` 创建唯一在线线程，固定加载 `/profile-thread/init.lua`，不是通用任务池。`Client.handleOrder:269` 把收到的数据反序列化后调用已存在的 `order...` 方法；普通 tome addon 不能靠多塞一个 order 字段自动给这个已经启动的线程安装代码。

因此，后台**网络发送本来就存在**，当前长调用主要发生在发出 order 之前。跨平台 addon 可直接交付协程分片、缓存及 lzlib 修复；要把任意描述生成搬到另一原生线程，需新 Lua VM、数据传输和引擎 API，或平台专用本地组件。用 LuaJIT FFI 从 pthread 回调进入主 Lua VM 不是可交付的安全实现。

## 下一轮验收顺序

1. gzip 候选先以原版成功输入做逐字节对照，再以空串/短串/真实角色 JSON 做解压往返；观察数百次导出后的原生堆与 RSS，而不只看 Lua GC 计数。
2. Party 专用复制先检查完整图和回调顺序，再测真实图冷/热调用，最后按同一脚本保存。效果清理的 RNG 序列要单独记录；不能拿 `saveUUID` 的零 RNG 检查替代。
3. GC 各候选独立开关，比较最慢单次回收和总 CPU；加入 finalizer 释放引用、弱键/弱值、切图保存、强制等待和自定义保存类的反例。
4. 分片在线导出先在网络捕获环境中逐字段比较；覆盖战斗间隙、同回合换装备、临时效果、附身/切队员、连续保存、导出报错和退出。确定原语义后再评价画面响应改善。

截至本文完成，已测的后续候选是 gzip 微测试与合成 Party 复制试验；其余是带有明确入口和验收条件的实现设计。生产 addon 仍为已发布的 0.2.2。
