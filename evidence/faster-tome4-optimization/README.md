# 保存／加载优化与后续方案

核对日期：2026-09-12。目标为 ToME **1.7.6**，源码 commit：
`624a67329fe2ad440c5b344785a9c73fcf22ae63`。
下列路径均相对该引擎仓库。本轮是 addon 修改，不是翻译批次。

## 本轮实现

### 合并切图产生的重复主存档请求

`game/modules/tome/class/Game.lua:2818` 在每次 zone／level 入队时注册匿名回合末
`saveGame()`。`game/engines/default/engine/SavefilePipe.lua:138` 调用它时请求刚入队，
**不是写盘已经完成**。

新增 `superload/mod/class/Game.lua` 与 `overload/engine/FasterSave.lua`：同一实际回调数组
中的多次请求仅让最后一个回调调用 `saveGame()`；先前回调成为空操作。这样减少重复快照、
World 请求及成绩更新，仍保留少量回调调度成本。保留最后请求的位置，可以覆盖夹在请求
之间的其他回调造成的状态变化；“第一次具名注册后忽略后续请求”可能过早保存。

引擎执行前替换 `set.fcts`（`engine/Game.lua:321`），因此使用该数组作为批次键：执行中
产生的新请求属于下一批，不取消当前批。取消回调、捕获队列和失败后再次保存不会被永久
pending 标记阻挡。不同捕获队列随后合并时仍可各保存一次，不强行跨队列／回合消重。
显式手动／退出保存不合并。最终 `saveGame()`、令牌、克隆、World、写盘和失败处理仍由
原引擎执行。合并意味着批内只留下最后的快照，不再保留那些中间保存尝试。

### 消除延迟回调的重复头插

`engine/Savefile.lua:121` 每次执行 `table.insert(self.delayLoad, 1, o)`。
对象图由 `loadReal()`／`engine/class.lua:494` 递归恢复，然后五种加载入口才遍历队列。
优化在最外层 `loadReal()` 期间顺序追加临时数组，返回或抛出异常前逆序填入原公共数组。
保留数组身份、已有条目顺序和后注册先执行的回调顺序。Game 的延迟闭包、`loadNoDelay`
立即回调和图读取范围之外的 `addDelayLoad()` 行为保持不变。

一个根对象图有 M 个新增、K 个已有回调时，合并成本 O(M+K)，额外空间 O(M)。多个独立根
仍会逐次移动已有队列，不能声称任意加载模式均已全局线性化。
`engine/Entity.lua:210` 设置 `loadNoDelay=true`，很多实体不进入此队列：M 不是实体数、
ZIP 条目数或角色目录数，实际收益需要测量。

Savefile 被 `engine.Module` 提前 require，仅提供 superload 不会生效，因此从
`hooks/load.lua` 对缓存类安装包装；Game 在 addon 加载后初始化，采用常规 superload。
安装器检查原方法路径／行边界，未知布局或此前的包装会跳过。这不是代码哈希认证。
如果其他 addon 在递归解析期间读取公共 `delayLoad` 的中间内容，应关闭本优化并集成测试；
固定源码没有这种消费者。带特殊元表的队列也会走原路径。

## 1.7.6 源码核验与裁决

下表 engine 路径前缀为 `game/engines/default/engine/`，mod 为 `game/modules/tome/`。
confirmed 只确认代码机制，**不代表已证明它是某个实际存档的主要瓶颈**。

| 机制 | 源码证据 | 裁决 |
| --- | --- | --- |
| 同步完整快照 | `SavefilePipe.lua:125`；`class.lua:362`；`Zone.lua:32` | confirmed；不机械套用最终保存白名单 |
| 多处完整 GC | `SavefilePipe.lua:159`；`Savefile.lua:177,201,214,256`；`Zone.lua:1006` | confirmed；保留，先计时 |
| 重复切图主存档 | `mod/class/Game.lua:2818`；`engine/Game.lua:321,342` | confirmed；本轮合并同一回调队列内请求 |
| type／savename 冲突等待 | `SavefilePipe.lua:108,127,224` | confirmed；修改档案键需同时审计完成注销与重试 |
| 单对象序列化后才让出 | `Savefile.lua:142` 的 `tbl:save()`／yield 顺序 | confirmed；大型普通表需要序列化层预算设计 |
| 延迟队列头插 | `Savefile.lua:121` 与五个 load 入口 | confirmed；本轮修复 |
| 菜单预载与重复排序 | `Module.lua:176`；`modules/boot/dialogs/LoadGame.lua:83` | confirmed；需要独立 boot addon |
| 成绩全表重写 | `mod/class/Game.lua:2854`；`HighScores.lua:39`；`PlayerProfile.lua:334,375` | confirmed；共享历史影响待测，保留持久性 |
| 低云空间清理 | `SavefilePipe.lua:50`，阈值 200 MiB | confirmed；条件路径，API 调用不等于确定网络等待 |
| 令牌增长 | `mod/class/Game.lua:2801` | confirmed；不裁剪有效性令牌 |
| 无显式重试上限 | `SavefilePipe.lua:200` | confirmed；异常路径，未来需保留失败状态和明确错误通知 |

“其他角色目录”“当前角色可达对象图”“共享成绩历史”“管线排队请求”应分别测量。

## 下一轮：独立 boot 菜单 addon

主 addon 为 `for_module="tome"`，首次读取菜单属于 `boot`。
`engine/Module.lua:380` 按模块筛选 addon，不能把 boot superload 放进 tome addon 就声称
冷启动菜单已加速。本轮未修改菜单，也未打包未验证的 companion。

后续可实现独立 `boot-faster`，匹配 boot 版本 `{1,0,0}`，保留版本／缺失 addon 判断、
Steam 描述读取、删除与启动行为：

1. 收集结束后每模块只排序一次；相同时间戳保留稳定顺序。
2. 只为选中项创建 Textzone 与纹理，缓存少量最近项。
3. 延后 PNG 解码。列表结束时引擎恢复挂载，原 `/tmp/listsaves/.../cur.png` 路径失效；
   必须记录存档定位信息，按需临时挂载，并在缺图、异常和成功路径恢复挂载。

验收覆盖空列表、大量存档、缺失／相同时间戳、旧版本、缺失 addon、选项切换、损坏截图、
云端独有角色和删除后刷新；统计显示菜单前的解码／纹理／文本布局次数与冷／热启动耗时。

## 验证与真实存档测量

`tests/test_save_load.lua` 从固定 commit 执行真实 Savefile、class.load 和 tick 方法，
使用内存文件及图形／云接口桩。覆盖交错状态修改、取消／捕获／下一批调度、debug、
错误恢复；引用与 SELF、队列身份、已有／缓存／缺失对象、损坏警告、异常对象身份、
五个加载入口、Game 延迟闭包和立即 loaded 回调。

合成图有 2,001 个延迟回调时，原方法搬移 2,001,000 个数组元素；优化后不再头插，顺序
相同。这是操作计数，不是真实存档秒数、帧率或总内存测量。本轮未启动游戏、访问玩家
存档或触发 Steam 写入／清理。

真实 A/B 测试应使用备份副本与隔离云同步，保持当前角色、World 和 Profile 不变，
独立改变其他角色目录数量，区分手动保存、切图、角色读档和菜单打开。
后续至少计时：成绩更新、截图、克隆、各完整 GC、`tbl:save()` 总耗时及最慢对象、C 写入
等待、`forceWait` 次数／队列长度、`loadReal` 与 `loaded`。日志中的 `Already saving data`、
`force waiting`、`*RE*new save`、`Steam cloud missing space` 可辅助识别不同路径。
完成测量后，再决定快照范围、GC 时机、共享数据合并与云维护的改动。
