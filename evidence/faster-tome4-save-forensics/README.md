# 存档分析的独立核验与 addon 修复设计

后续已进行[本地局部 profile](../faster-tome4-profile/README.md)：泄漏机制仍成立，
但测量没有证明它是严重卡顿的主要来源，也没有证明克隆速度稳定改善。
下面保留静态取证与迁移边界，性能归因以该后续测量的限制为准。

2026-09-12。对应用户提交的分析，主代理只读上传存档及本体源码；没有启动游戏、
执行存档中的 Lua／字节码、修改原存档或变更 addon。上一轮 addon 仍是提交
`ec0a3d184ea1b90303842387bed768fb5984d03f` 的 0.2.0，不包含本文设计的新修复。

本体核验版本为 ToME 1.7.6，commit
`624a67329fe2ad440c5b344785a9c73fcf22ae63`。所检查的关键源码文件与该 commit 无 diff。
这是源码与序列化数据的静态核验，不是玩家机器的耗时测量，也不能证明该存档加载的
所有第三方 addon 都与本次本体源码具有相同行为。

## 输入与方法

输入 SHA256（读取前后相同）：
`eac52e4bd612b2ec6477f71bae12b7844c3e8031813df2ad89fe6fac2c1915a7`。
外层 ZIP 及 22 个内部存档全部通过 CRC 校验。主档 2,849 个条目通过受限字面量解析；
另外统计全部区域档中的 Particles 条目。解析器不运行 Lua，`loadstring` 等调用只作为
不透明标记处理，`loadObject` 只记录引用名。它针对这份序列化格式，不是通用 Lua 解释器。

此解析脚本针对本次案例的结构（包括固定角色目录及对象条件），不是任意存档的通用审计器。

复现：`python3 -B audit.py /path/to/save.zip --output /tmp/observations.json`。
此命令产生观察报告，不会改写输入。完整 observations.json 含存档对象标识，仅保留本地；本目录公开机制分析与聚合计数。

## 独立裁决

| 项目 | 核验结论 |
| --- | --- |
| Fearscape 残留引用 | **confirmed**：Player → `demon_plane_trapper` → dead NPC → `ai_state.safe_grid.Astar` → 12×12 Map；主档的九个 Level 均不以该 Map 为自己的地图 |
| 孤儿链粒子 | **confirmed**：Map.particles 有 132 个；另有 NPC 身上的两个 notice_enemy 和一个 circle，全链合计 135 个 |
| 粒子重建及后台工作 | **confirmed（本体源码路径）**：Particles.loaded 创建 native emitter，粒子线程按 alive 状态更新，不按当前地图筛选 |
| 一次性粒子永不停止 | **confirmed**：notice_enemy 和 dreamhammer 只发射一次，却返回 no_stop=true；全档分别保存 58 和 2 条记录 |
| 背包对象图 | **confirmed（序列化可达范围）**：1,163 个 Object、46 个 NPC，对应条目正文 2,192,332 字节；这不是 Lua 堆大小，也不是当前实际携带物品数 |
| 玛瑙堆和恶魔种子 | **confirmed**：玛瑙根对象加 421 个 stacked 对象，共 512,883 字节；46 个种子可达子图约 733,186 字节。数据量不等于机制错误 |
| 旧背包引用 | **confirmed**：移动纹身及转化箱的 in_inven.id 为内嵌背包表；两表合计额外引用 30 个不在当前直接 inventory 中的物品 |
| Cloud Caller | **confirmed**：主档中仅有 main.entities 与转化箱的 in_inven 字段引用它；无 in_inven／carried，且 power_regen=1。全局行动表加载后为弱值表，旧背包表才是本链需要修复的强引用 |
| 卡顿主要耗时来源 | **pending**：上述机制足以解释持续后台工作与保存膨胀，但尚无帧时间、线程 CPU、GC 或保存分段计时，不能认定全部卡顿或其主要比例已经归因 |

逐级字段锚点：

```text
mod.class.Player-<instance>.demon_plane_trapper
  -> mod.class.NPC-<instance> (dead=true)
     .ai_state.safe_grid.Astar -> engine.Astar-<instance>
       .map -> engine.Map-<instance> (w=12, h=12)
```

主档共 205 个粒子：当前层 Map 与直接实体合计 12 个，其他八层合计 58 个，孤儿链
135 个。这里的 193/205 是“非当前场景的序列化粒子记录比例”，不是 CPU 占比，也不代表
193 个都持续工作：acid、melee_attack、dust_trail 等有限寿命粒子会停止；vapour 持续发射，
circle 可重复发射，no_stop 粒子则在粒子耗尽后仍更新。孤儿 Map 的三个效果 duration
为 5、6、6；没有所属 Level 推进它们时，不能靠正常回合到期清除。

全档 notice_enemy 分布：主档 2，世界地图 42，Heart of the Gloom 10，其他区域 4。
区域档中的对象不会在本次主档加载时全部同时活跃。dust_trail 共 212 条。

## 对原分析的口径修正

- 22,208,501 字节是外层 ZIP 展开后的文件总量，其中 .teag/.teaz 仍是压缩容器；
  展开这些内部档案共 52,505,076 字节，主档正文为 6,640,758 字节。
- “132”与“135”应分别指地图列表和整个孤儿链，不应都称为 Map.particles 的数量。
- 当前 Level.entities 和 Level.e_array 均为 13 项，原文的“23 个 e_array 实体”未复现。
  地图格子的对象层、地形层和行动数组是不同计数，不宜混用。
- `game.entities` 在 `GameEnergyBased.loaded()` 中恢复弱值语义。修复 Cloud Caller
  应先解除旧背包强引用，不能把全局表本身描述为强引用泄漏根。
- 17,400、12,600 和 5,041 是指定密度、指定 emitter 集合下的槽位检查量。
  native 容量实际为 `max(1, floor(capacity * density / 100))`；动画暂停时不发关键帧。
  空槽检查、活粒子积分及 Lua updater 成本也不同，不能据此换算帧率。
- 日志中的 34,235 是 cloneForSave 的计数，主档实际只有 2,849 个 ZIP 条目。
  两者范围不同；不能据日志认定写出了 34,235 个独立文件。

没有重新统计所有区域的 distance_map、任务、时间克隆等剩余排除项，仍按用户提供的
观察对待。也未验证第三方自动拾取函数是否增加了堆叠数量，不能仅因字段出现就归责。

## 下一轮 addon 的修复边界与验收

1. **Fearscape：先防止新增，再做严格限定的旧档迁移。** 仅在原退出回调成功完成、
   已返回来源 Level 后，清除仍匹配该施法者的 target.demon_plane_trapper。
   不能在死亡回调调用 forceUseTalent 之前清除。旧档迁移要确认已不处于该次 Fearscape、
   施法者已经死亡、目标不再使用依赖该字段的死亡包装，且候选地图不属于合法持久 Level。
   证据不足则跳过并记录原因。解除引用与停止 native emitter 是两项工作；不应通过
   清空所有非当前地图粒子或强行销毁整个 Map 来代替。迁移应幂等，运行于副本载入后的
   完整对象图上，不编辑 ZIP。测试须覆盖施法者／目标死亡、主动解除、正常持续中的
   Fearscape、失败退出、旧档正常重载和合法历史楼层。
2. **notice_enemy／dreamhammer：修粒子资源定义的终止条件。** 保持生成器、初次发射、
   视觉参数及随机调用，取消错误的 no_stop。资源应通过 addon 的
   `overload/data/gfx/particles/` 覆盖；仅改主 Lua 环境里的 loadfile 包装不足以修复
   native 线程独立加载的定义。旧记录重载时也会使用新定义，但有限寿命结束不等于
   非当前地图上的 Lua 记录已经从保存图删除。测试保留完整初始动画、零活粒子后退出线程
   列表、当前／历史场景重载，以及不同粒子密度。
3. **in_inven：规范化字段，保留背包 API 与钩子语义。** 新增物品后只把标准归属记录中的
   table id 改为对应 inventory 的数字 id，不改变传给已有 hook 的参数。旧档只根据
   当前真实归属修复记录，包括堆叠和装备附属对象；不盲信旧表自身的 id，不删物品。
   清除引用后使用正常 GC 回收弱值表中的失去归属对象，不新增同步完整 GC。
   测试出生发放、拾取、叠堆／拆堆、装备交换、转化、丢弃和载入后再次保存。
4. **玛瑙／恶魔种子：暂不改变数据模型。** 每个实例可能含独立回调、状态与装备；
   “数量字段替代对象”或删除 NPC 会影响机制。先区分相同模板、运行时缓存、必要实例状态，
   再验证快照／序列化收益。此项优先级低于已经确认的失效引用与 emitter 生命周期错误。

验收使用独立存档副本，对照原版、仅粒子修复、仅引用修复、两者合并的结果，分别测
粒子线程 CPU、主线程帧时间、载入重建量、保存克隆量与 GC；保留世界地图／当前层切换测试。
不能用人工减少名义对象数来代替行为保持与实际耗时测量。

## 固定源码索引

以下路径相对于上述固定 commit 的 t-engine4 checkout：

- `game/modules/tome/data/talents/corruptions/shadowflame.lua:243` 写入捕获者；
  `:245` 死亡包装依赖该字段；`:286-372` 退出未清除字段。
- `game/engines/default/engine/Particles.lua:53-115` 重建 native emitter。
- `src/particles.c:133-165` 创建并登记；`:266-410` 遍历槽位及 no_stop；
  `:732-768` 调用 updater；`:852-861` 密度／容量；`:1078-1108` 线程列表推进和移除。
- `src/main.c:652-659` 仅在动画未暂停时向粒子线程提交关键帧。
- `game/modules/tome/data/gfx/particles/notice_enemy.lua`、`dreamhammer.lua`：
  返回的第五项 true；`vapour.lua:46-50` 持续发射；`circle.lua:98-106` 条件性重复发射。
- `game/engines/default/engine/interface/ActorInventory.lua:92` getInven 支持 table；
  `:141-194` addObject 把原参数传给 onAddObject；`:317` 按原参数保存归属。
- `game/modules/tome/class/Player.lua:106`、`Game.lua:233` 传入实际 inventory 表。
- `game/engines/default/engine/GameEnergyBased.lua:43-57` 恢复全局实体弱值表；
  `:75-88` 全局行动扫描。
- `game/engines/default/engine/interface/ActorAI.lua:65-78` 加载时不清除 safe_grid；
  `game/engines/default/engine/class.lua:243-263` 克隆计数的实际范围。
