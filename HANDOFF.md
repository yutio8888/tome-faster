# Faster ToME4 当前交接：0.2.5

更新：2026-09-13 UTC。用户本轮要求“请你继续完成handoff内列出的待优化项”。已完成三项可集成优化和真实验证；完整快照切片、GC 重调度及新保存事务仍未实现，不能把候选反例分析称为这些功能已经交付。**本节是最新状态，后面的 0.2.4 / 0.2.3 内容只作历史索引。**

## 交付与有效约束

打包产物政策（用户最新要求）：当前源码树已取消跟踪全部 `.teaa` 归档和生成的 release 校验文件，并加入忽略规则。仅在本地 `dist/` 构建，二进制发布使用附件或制品存储。下面的历史包名与 SHA256 保留作验证记录，不再作为仓库内下载入口。本次按普通提交取消跟踪，未重写既有 Git 历史。

当前发布状态：用户已明确“批准发布”；功能提交 `7ab9918` 和状态提交 `1c9093a` 已成功推送到 `origin/perf-save-stutter-20260912`。此前自动审批要求明确批准，获得批准后完成原分支发布。此次发布状态文档更新不改变 0.2.5 安装包及其 SHA256。

- 生产 A：`/workspace/t-engine4/tmp/worktrees/tome-faster-save-20260912`；分支 `perf-save-stutter-20260912`；远端 `https://github.com/yutio8888/tome-faster.git`。本次提交以该分支 Git log 为准，父提交 `6a307b8cd35e6ceb6b6de777bc9c4780d52179ee`。没有合并用户原 checkout；本次远端发布的审批状态见上。
- 运行 W：`/workspace/t-engine4/tmp/worktrees/yron-profile-20260912`；P 为 `W/tmp/profile`。固定引擎仍为 `624a67329fe2ad440c5b344785a9c73fcf22ae63`。
- 新生产模块：[FasterHotkeys.lua](overload/engine/FasterHotkeys.lua)、[FasterEffectMask.lua](overload/engine/FasterEffectMask.lua)、[FasterSaveFollowup.lua](overload/engine/FasterSaveFollowup.lua)。独立关闭项 `hotkey_text_cache=false`、`effect_mask_batch=false`、`save_callbacks=false`，改后重启。
- 用户允许 RNG 消耗不同，不允许随意改游戏规则。新改动未改冷却、伤害、FOV、tick、三个完整 GC、保存格式或后台 worker 协议。
- 最近验证的本地包：`tome-faster-0.2.5.teaa`（历史构建记录，见 [构建说明](releases/README.md)），SHA256 `39c06d93a6a39c74286c3aa31b446a2d577dc0bfcc319c5131269c3c2a4b1754`，67 个 allowlist 文件。CRC、逐文件内容及生产 Lua 语法通过；旧包没有重写。
- 主报告：[render-save.md](docs/render-save.md)、[render-save-results.json](docs/render-save-results.json)；保存细节：[save-followup.md](docs/save-followup.md)、[save-followup-results.json](docs/save-followup-results.json)。

## 真实结果与范围

- 快捷栏三组 A/B：`P/sessions/stutter-hotkeys-v1-{before,after}-pair{1,2,3}-01`。每次 60 次移动 / 61 次 display，CPU 每调用中位数 **1.156 → 0.883 ms，少约 24%**；完整原生归因运行的移动 TTF 调用 **1260 → 0**。战斗过程有随机差异，不宣传整体战斗百分比。
- 地图最终 A/B：`P/sessions/stutter-map-v3-{before,after}-pair{1,2,3}-01`。优化侧批量绘制 34 / 40 / 20 次，省去 729 / 722 / 380 次逐格调用。另有 3 对各 120 帧的受控原 shader 计时；CPU 和提交 wall 均无稳定改善。它缓存有序顶点，**不是缓存最终遮罩像素**；仍逐帧重建公开 Map.fbo 和动态 shader。
- 保存三组 A/B：`P/sessions/stutter-save-callbacks-v1-{before,after}-pair{1,2,3}-01`。未测得稳定 CPU 或最长帧改善；局部 2853 对象 fixture 少约 397.5 KiB / 13.77% Lua 分配。真实 `stutter-save-followup-audit-01` 2854 次 class.save 全部命中、0 回退，只创建 2 组回调（Game / World），仍 3 次完整 GC。
- 18 次正式分项运行全部 exit0 / completedtrue，互不并行，各用原始 ZIP 新副本。不要纳入旧 map-v1、map-v2 或失败的像素诊断。
- 完整像素：`stutter-hotkeys-display-pixels-v5-01` 120 帧 UI、117964800 bytes RGBA、8484 次业务调用，三阴影路径各 40 帧；`stutter-map-display-pixels-v5-01` 48 帧完整输出/公开遮罩/GL/FOV/动画全等。前者使用合成 actor 和真实字体/Entity/UI，后者用临时特效和真实可见性/target_fbo。不是整个游戏世界的逐帧回放。
- 字形基础：`stutter-hotkeys-pixels-v2-01` 576 原生组合 + 120 帧序列，包括中文、AA/split、样式与跨纹理单元绑定；RGBA/元数据/GL 一致。
- 存档重载：`render-save-roundtrip-20260913` 为角色目录重载，未携带上一份 World。随后 `render-save-full-roundtrip-20260913` **携带了上一轮全部 22 个角色 ZIP + world.teaw**，输入字节与 after-pair3 一致，空闲后再保存。六次保存 A/B + 两次重载的输出共 184 个 ZIP CRC 通过，选定 27 角色 / 203 物品状态一致，回合增量 0。
- 完整重载输入 `P/render-save-full-roundtrip-20260913.zip` SHA256 `80afc4c8578b30fecf9559fbd85db40fb401b16eb0ed8e24c1cacc48f9fad88b`。原始 ZIP 最终仍为 `eac52e4bd612b2ec6477f71bae12b7844c3e8031813df2ad89fe6fac2c1915a7`。
- 当前仍是 Linux、嵌入 LuaJIT 2.0.2、Xvfb 1280×800、llvmpipe 软件渲染。没有硬件 GPU / Windows / macOS / 云存档验证。

## 关键实现与排障经验

1. 快捷栏缓存只替三次 `font:draw`，全局 512 项 / 4 MiB，owner 弱持有，返回新元数据。引擎 `font.size` 被 utils 包成 Lua，不能要求它为 C。命中绑定 1×1 sentinel 再绑文字，以处理引擎跨 texture unit 的共享绑定缓存，4 bytes 已入预算。
2. 标准 MapEffect 是 Entity 类实例，存在纯 `__index` 继承链；引擎 class 模块终端保留空元表。第一版 plain-only / nil-terminal-only 检查都误回退，已用实际构造 fixture 和逐条件真实探针纠正。
3. 原 `gl_free_fbo` finalizer 会 raw bind 自身 FBO 后绑 0，不恢复调用者。完整 UI 诊断确实记录到原版字体分配期间 FBO 25→0，并捕获了窗口内容。离屏比较现每对前后仅在 FBO0 回收，对内停 GC，结束恢复；**不能将这些受控计时称为常规 GC 开启的游戏 A/B**。
4. 最终地图实现把顶点准备/可能触发 GC 的分配移到已识别 native FBO 绑定前，绑定内仅 drawEntry。新 fixture 强制执行真实 FBO finalizer，并验证遮罩/返回 scene FBO；未知 custom FBO 保持原循环与回调时点。没有全局修改 FBO finalizer 或生产 GC。
5. 本体 `core.display.glScale(number,...)` 自带 glPushMatrix，无参数 glScale() 才 pop。诊断额外 glPush 曾在第 15 帧导致栈溢出，现成对调用并检查三个 GL 栈；生产代码不涉及此 API。
6. driver 与其他诊断均先声明 clock_gettime，独立 FFI struct tag 不兼容；地图诊断用 void* 转换实际同布局参数。错误收尾不应遮蔽原始错误，PASS 必须在状态恢复后输出。
7. 保存 audit 的 `detail=true` 包装 dumpToJSON 会使离线 guard 回退，因此该详细调用 400ms 左右不能混入正式 detailfalse 保存 A/B。

## 回归与复现

- [regression.log](evidence/faster-tome4-render/regression.log)：现有套件、Ashes/Cults 固定哈希 fixture、799 hotkey、876 native mask、562 native serializer 检查全过；新三项 JIT 开关均过。其他计数以 [VALIDATION.json](VALIDATION.json) 为准。
- 真实绘制诊断和聚合脚本在 [render evidence](evidence/faster-tome4-render/README.md)；根图、GC/worker 反例在 [save evidence](evidence/faster-tome4-save-followup/README.md)。这些目录不进入安装包，不发布 home、完整日志、玩家 JSON、DLC、RGBA 或存档。
- `W/game/addons/tome-faster` 包含额外诊断，不能整体作为生产源提交。同步生产时保留本地 hooks；最终 driver 副本已放 render evidence。
- 每场游戏都必须等上一场完成，`game.lock` 是非阻塞锁，重叠启动会失败。必须同时看 process.json、PASS、SESSION_COMPLETE，不能只看进程 exit0。
- 本轮已停止自己启动的 Xvfb；没有遗留测试游戏。下轮按历史环境段重新启动显示服务，不能复用历史 PID/session。

## 剩余工作及已否决方案

完整快照切片 / 根裁剪、GC 调度、后台导出事务、新 writer、FBO 复制省略、原生等待归因和旧引用迁移均未发布。对应范围和理由在主报告逐项列出。

- GC 合并已有真实 finalizer / weak 反例；step 到第一次 true 只完成旧周期，不等于新完整屏障。不要只靠计时删 GC。
- 原 worker 每对象提前唤醒会重复 CREATE、关闭并报告同一个归档；须先有 BEGIN/ENTRY/END/ABORT 和退出/错误协议。
- 根图诊断 128179 个 raw table，uiset 单边独占 694，tooltip 1039（约0.81%）。大部分共享；exporter 确实读取 uiset 日志/calendar/对话框等。原持久化白名单不等于完整消费者依赖。
- 要显著降低剩余约百毫秒快照/GC 停顿，仍需完整冻结事务及弱引用/写入屏障设计；不能用本次小幅回调分配收益代替验收。

---

# Faster ToME4 当前交接：0.2.4

更新：2026-09-13 UTC。用户本轮要求“请阅读handoff文档，继续跟进tome4优化插件开发工作”；已按此前优先一完成角色导出 gzip 内存修复。**本节是最新状态，下方 0.2.3 原文仅作为历史环境和证据索引。**

## 当前代码及交付

- 生产工作区仍是 `/workspace/t-engine4/tmp/worktrees/tome-faster-save-20260912`，分支 `perf-save-stutter-20260912`；远端 `https://github.com/yutio8888/tome-faster.git`。本次 0.2.4 提交以该分支 Git log 为准，父提交 `036e30c`。未合并用户原分支。
- 最新实现：[FasterGzip.lua](overload/engine/FasterGzip.lua)、[Player superload](superload/mod/class/Player.lua)。识别固定 `saveUUID` 本体后仅改 JSON 压缩调用，使用内置 lzlib 同参数 gzip；成功一个返回值，压缩状态失败零个返回值，动态 API 覆盖时回退。
- `export_gzip=false` 并重启可关闭；与 `offline_chardump` 独立组合。其他优化及“不要求相同 RNG 消耗，但不随意修改游戏规则”的约束不变。
- gzip 主要修复内存保留，不宣传 CPU/保存加速。短/空输入原先可能压缩失败，现在生成有效 gzip。全局 core API 不变，因此其他调用或未知覆盖回退后仍可能使用旧的泄漏接口。
- 最新说明：[gzip-export.md](docs/gzip-export.md)、[结构化结果](docs/gzip-export-results.json)。安装包：`tome-faster-0.2.4.teaa`（历史构建记录，见 [构建说明](releases/README.md)），SHA256 `e5f34b6c132796665d4607dda1c5beeac1d61902a7e538a7dac21db787acdbb4`，54 个 allowlist 文件。旧包未重写。

## 新验证结果和入口

环境仍使用下方定义的 A（生产）、W（运行）和 P（profile）。原始 ZIP 路径及 SHA256 未变；只操作独立副本。

- 正式 A/B：`P/sessions/stutter-gzip-v3-{before,after}-pair{1,2,3}-01`。顺序后/前、前/后、后/前；每侧 300 次计时完整导出，六批各 50 次。配置 `detail=false, export_gzip=false/true, phases={"gzip_check","save"}, validate_save_state=true`。
- 原接口每 50 次导出 native allocation 中位增量 **13,408,800 bytes（约 12.8 MiB）**；新接口六批均为 **0 bytes**。指标为完整 Lua GC 后 `mallinfo2.uordblks + hblkhd`，不是 RSS。全导出耗时中位数 12,466.50 / 12,562.31 ms，没有稳定 CPU 加速结论。
- 实际角色 JSON 263,388 bytes、gzip 字节一致，selected live/snapshot 状态 27 个角色、203 件物品一致。模拟认证前双重拦截 profile 发送；真实网络调用 0。
- 六个进程全部 `exit_code=0, completed=true`，后续正常保存回合增量 0，六份各 22 个 ZIP CRC 通过。这里保存发生在反复导出及诊断 GC 之后，**不能当成新的冷保存基准或与 0.2.3 时间直接比较**。
- `stutter-gzip-export-compat-{before,after}-01` 分别运行 `chardump_check` 和 `party_export_check`，确认在线 JSON/标题/标签一致，离线仍不编码资料。
- `P/sessions/gzip-roundtrip-20260913` 已重载优化 after-pair3 存档，空闲后再保存，正常退出；22 个 ZIP CRC 通过。派生输入 `P/gzip-roundtrip-20260913.zip`。
- 最终回归：[evidence/faster-tome4-gzip/regression.log](evidence/faster-tome4-gzip/regression.log)，包含 Ashes/Cults 固定哈希 fixture。新增 262 个 gzip 检查在 JIT 开/关均通过；角色导出测试现在 176 个（新增后覆盖安装记录边界）。其他套件通过，具体计数见 `VALIDATION.json`。
- 新 native fixtures 需要 C compiler、Lua 5.1 ABI headers、zlib dev 和 pkg-config（或 `TOME_LUA_INCLUDE`），运行时从固定引擎 Git 提取源码到 /tmp 编译，完成后删除，不发布原生 addon 组件。

## 本轮新发现及诊断兼容

1. 固定 lzlib 的 `luaopen_zlib` 把 `_VERSION` 放进随后丢弃的独立表，实际全局 `zlib._VERSION` 为 nil。当前 guard 接受 nil/已知版本并做真实 gzip 能力预检。不能重新要求必须有版本字段。
2. `FasterChardump` 的原委托 upvalue 现在叫 `delegate`。旧 evidence 诊断按 `original` 查找，直接复用会失败。W 中两个旧入口已修复；对应可复现新版都在 [evidence/faster-tome4-gzip/diagnostics](evidence/faster-tome4-gzip/README.md)。**不要覆盖回旧版本的 FasterChardumpCheck / FasterPartyExportCheck。**
3. W 的 `FasterStutterSession` 新增 `gzip_check` 阶段，诊断模块 `FasterGzipCheck`。代码和驱动副本保存在新 evidence；生产包排除整个 evidence。
4. 初次受限沙箱游戏启动发生 native 退出，Xvfb 和游戏需工具级 escalation；随后完整运行正常。最早 `stutter-gzip-after-pair1-01`、`stutter-gzip-v2-after-pair1-01`、`stutter-gzip-binding-probe-01` 是失败启动/守卫诊断，不能纳入 A/B。
5. 本轮最终停止自己启动的 Xvfb；下一轮按原文方法重新启动，不复用历史 PID。全局 `.DS_Store` 等无关内容未清理。

## 下一步

gzip 优先项已经交付。继续开发时先推进快捷栏稳定文字光栅化的有界缓存：分离 font draw 成本，覆盖字体/缩放/分辨率/按键/界面变化失效，并验证连续图像序列与真实移动/战斗 A/B。参见 [render-next-analysis.md](docs/render-next-analysis.md)。地图静态遮罩其次；快照/GC 调度仍需要完整冻结和保存协议设计。不要重复实现 gzip 或已删除 Party 的专用复制优化。

---

# 0.2.3 交接原文（历史记录）

# Faster ToME4 性能优化交接

更新：2026-09-13（UTC）。面向没有前文上下文的接手者。本文记录已完成工作、行为边界、复现入口和建议下一步；本次交付仅准备交接文档，没有启动新一轮优化或新的接手代理。

## 1. 用户目标与有效约束

用户希望分析提供的 ToME 存档在**移动、战斗和保存**时的卡顿，并尽可能通过 addon 修复。实现不得随意改变游戏规则。最初要求实现简洁易懂，随后明确允许不限制实现复杂度，并要求完成提交、推送 GitHub 后继续分析热点。

最新有关行为约束的原话是：**“不考虑rng消耗，请你继续清理”**。因此，0.2.3 已有意删除未使用导出 Party 的构造和清理，不补偿旧 RNG 调用和临时 UID 分配。未来随机结果可以不同；这不等于允许修改伤害公式、技能成本、冷却、AI 规则、存档限制或其他业务逻辑。

最后一次功能工作已完成提交和推送，用户已收到优化清单及可能的逻辑影响说明。当前请求是：**“请撰写handoff文档，准备交接工作”**。接手时先确认用户是否已要求继续实施；不要把文档中的候选当成已经交付的功能。

## 2. 仓库、分支与交付状态

远端：`https://github.com/yutio8888/tome-faster.git`。

| 用途 | 本机路径 | 分支 / 固定版本 |
| --- | --- | --- |
| 引擎原仓库 | `/workspace/t-engine4` | `codex/hd2d`，引擎提交 `624a67329fe2ad440c5b344785a9c73fcf22ae63` |
| 用户指定的原 addon checkout | `/workspace/t-engine4/game/addons/tome-faster` | `perf-review-profile-20260912`，`bdc63e355c03280cda06f088563830a91df8d17e`，保持原样 |
| **生产 addon 工作区** | `/workspace/t-engine4/tmp/worktrees/tome-faster-save-20260912` | **`perf-save-stutter-20260912`** |
| 引擎运行 / profile 工作区 | `/workspace/t-engine4/tmp/worktrees/yron-profile-20260912` | `profile/yron-20260912`，同一固定引擎提交 |

本文编写前，生产工作区干净，HEAD 与本地 `origin/perf-save-stutter-20260912` 均为 **`f314ec5dbad7a374abcb932f7176932e9ae81d1b`**；此前已推送 GitHub。本文的后续文档提交不改变该功能版本。没有创建 PR，也没有合并原分支。

关键提交：

- `d4dbf77`：0.2.2，等价快照复制、离线无消费者导出跳过及验证。
- `308a31d`：后续热点分析和实验原型，无新增生产优化。
- `f314ec5`：0.2.3，删除未使用导出 Party，同时保留 Cults 禁止保存逻辑。

以下命令和路径约定贯穿本文：

```bash
addon_root=/workspace/t-engine4/tmp/worktrees/tome-faster-save-20260912
game_root=/workspace/t-engine4/tmp/worktrees/yron-profile-20260912
profile_root="$game_root/tmp/profile"
```

文中 `A/`、`W/`、`P/` 分别代表上述三个目录。**修改和提交生产代码应在 A 中进行。** `W/game/addons/tome-faster` 是导出的运行副本，包含本地诊断 hooks 和模块，不是独立 addon Git 工作区。同步生产代码时保留这些诊断入口；不要把运行副本整体当作发布源码提交。

主引擎仓库原有 `.DS_Store`、`.build-deps/`、`documentation/asset-audit-2026-09-09/`、`game/.DS_Store`、`tome-chn-mod.teaa.bak-before-numeric-diff` 等无关本地内容，不属于本任务，不清理。不要 prune 主仓库列出的其他旧 worktree。

## 3. 原始存档与已补齐环境

原始存档现在位于：

```text
/home/paseo/imports/C__Users_yutio888_T-Engine_4.0_tome_yron.zip
SHA256 eac52e4bd612b2ec6477f71bae12b7844c3e8031813df2ad89fe6fac2c1915a7
```

用户最初提供过 `ssh orb` 上的上传路径，之后改为上述本地文件，**不需要再次 SSH 获取**。原始 ZIP 未修改；每个测试都解压独立副本。角色 Yron，34 级，Dreadfell 9，坐标 `(16,5)`，回合 `1933440`，原档 7 个持续技能、无临时效果。

- 引擎：ToME 1.7.6，运行二进制 `W/t-engine` 已构建，保留调试符号与 frame pointers。
- 主机：Debian 12、AMD Ryzen 7 9800X3D、GCC 12.2。
- 游戏内嵌 **LuaJIT 2.0.2**；独立 fixture 测试使用 `/usr/bin/luajit`，**LuaJIT 2.1.0-beta3**。不要混淆这两个环境。
- 图形：Xvfb `:97`，1280×800，约 30 FPS；Mesa 22.3.6 **llvmpipe 软件渲染**，没有可用 `/dev/dri` 硬件 GPU。
- 本地依赖在 `P/deps/root`；`P/env.sh` 设置库路径、可执行路径、软件渲染和空音频驱动。Lua fixtures 的依赖默认在 `/home/paseo/.local/share/tome4-luarocks`。
- 存档的 9 项 addon/DLC 已可加载：`chn-mod`、`auto-loot-transmo-trans`、`danger-alert`、`improved_enemy_ui`、`possessors`、`ashes`、`orcs`、`cults`、`faster`。缺失公开插件已从官方来源补齐；DLC 使用现有本地文件。
- Ashes/Cults 测试 fixture 已提取至 `P/fixtures/dlcs`，测试会校验哈希。不把完整 DLC、玩家存档、完整角色 JSON 或保存对象图发布到 GitHub。
- 交接核查时没有本任务的 `t-engine` 或 Xvfb 进程运行；下一轮需启动显示服务。不要复用历史 PID 或工具 session ID。

当前环境已可复用，无需重新构建、下载依赖或解包原始档覆盖旧测试目录。结论不覆盖 Windows/macOS、硬件 GPU、Steam 云保存或实际在线资料发送。

## 4. 当前已发布优化及行为边界

生产安装顺序见 [Game superload](superload/mod/class/Game.lua)：保存合并 → 快照复制 → 导出 Party 清理 → 可选 profiler。

| 优化 | 实现 / 入口 | 保持的行为与潜在差异 |
| --- | --- | --- |
| 删除未使用导出 Party（0.2.3） | [FasterExportCleanup.lua](overload/engine/FasterExportCleanup.lua) | 保留实际保存和导出流程；删除临时回调、RNG 消耗、资源操作及 UID 分配，详见下文 |
| 等价快照复制（0.2.2） | [FasterClone.lua](overload/engine/FasterClone.lua) | 对基本类型键值省去 memo 查询；完整复制原对象图，不裁字段，保留遍历顺序、环、别名、表键、元表、弱表和计数 |
| 跳过被丢弃的离线角色资料（0.2.2） | [FasterChardump.lua](overload/engine/FasterChardump.lua)、[Player superload](superload/mod/class/Player.lua) | 仅已存在 UUID、参数恰为 nil、已识别的离线/无效 hash 消费路径；在线、真实 charball、显式 false、晚注册及未知覆盖仍走原路径 |
| 重复保存请求合并 | [FasterSave.lua](overload/engine/FasterSave.lua) | 同一 callback 批次的 zone/level 主保存请求合并到最后一次的位置；显式手动保存保留，重复 callback 次数有意减少 |
| 延迟加载队列 | 同上 | 避免反复数组头插，保持最终 callback 顺序及公开队列表 |
| Map checker 源码缓存 | [FasterRuntime.lua](overload/engine/FasterRuntime.lua)、[Map superload](superload/engine/Map.lua) | 只缓存生成的源码字符串；排序、编译缓存和实时实体判断照常执行，不缓存 FOV/碰撞结果 |
| Ashes `inferno_nexus` | `FasterRuntime.lua` | 删除未使用的 `is_burning` 扫描，保留伤害、效果及原有 50% RNG 调用顺序；异常元表读取副作用需另查 |
| 日志 / 聊天缓存 | [CacheList.lua](overload/engine/CacheList.lua)、[ShowChatLog.lua](superload/mod/dialogs/ShowChatLog.lua)、`hooks/` | 日志环 5000 条，正确截断及 stdout；聊天纹理每窗口 FIFO 128，字体身份和宽度改变时失效；同一字体对象原地修改可能残留缓存 |
| 粒子 / shader 加载缓存 | `hooks/` | 两类 bytecode 缓存各 256 项，实例仍创建新闭包，保留环境、返回和错误；同路径资源热更新需重启或 debug bypass，自定义加载副作用可能被缓存跳过 |
| 粒子收尾 / 命中提示 | [notice_enemy.lua](overload/data/gfx/particles/notice_enemy.lua)、[dreamhammer.lua](overload/data/gfx/particles/dreamhammer.lua)、`hooks/` | 一次性动画完成后停止空 emitter，保留初始生成和寿命；第三方长期持有 emitter 的行为可能不同；恢复 `hit_warning` 方向提示 |

`FasterProfile.lua` 的诊断默认关闭。GC 调度、截图、保存格式、原序列化器、ZIP writer 和后台保存协议均没有在当前版本重写。

### 4.1 Party 删除的具体语义

固定引擎 `game/modules/tome/class/Game.lua:2854–2886` 原本克隆 `game.party`，给临时 Party 设置 UUID，清理成员和 Party，最后调用的却是 **`game.player:saveUUID(nil)`**，没有使用该临时 Party。

0.2.3 保留分数、快捷栏更新、Game/World 保存队列、玩家控制切换、`_G.game` 上下文、导出条件、`saveUUID(nil)`、外围 `pcall` 及恢复路径。当前档实际诊断里，旧准备过程消耗 136 次被监测 RNG 调用、1743 个临时 UID；新过程都是 0。现有角色/物品不重编号，但后续随机结果及新对象 UID 可不同。

旧清理还会清空**快照**的目标坐标；删除后保留快照坐标。live game 目标未改变；固定本体保存白名单不保存该目标，当前在线资料内容也一致。因此不能声称新旧整个快照完全相同。

当前 Cults `Game.saveGame` 包装器禁止 S.M.A.C.K 竞技场内保存。安装器保留外层包装函数、弹窗、确认/取消回调，只替换已识别 `saveGame` upvalue 中的本体委托。未知包装器或委托保留原实现。其弱表安装记录按内层函数区分，以识别后续覆盖。

来源路径和行号 guard 是保守兼容检查，不是完整代码哈希认证，也不能证明任意 addon 的回调都无业务副作用。额外自定义 `cloned`、`stripForExport`、技能清理或次级描述方法需要单独验证。

关闭此项并**重启**可恢复原导出准备：

```lua
config.settings.faster_tome.unused_party_cleanup = false
```

已有其他可选开关：`save_coalescing`、`load_queue`、`map_checker_source`、`inferno_nexus`、`save_clone`、`offline_chardump`。未配置的优化默认启用，详见 [README](README.md)。

## 5. 已验证结果与证据入口

### 5.1 当前 0.2.3：三组独立真实保存 A/B

每次用原始存档的新副本、预热约 2 秒、轻量计时 `detail=false`；仅切换 `unused_party_cleanup`，两侧都开启 0.2.2 优化。顺序为前/后、后/前、前/后。

| 指标，中位数 | 保留临时 Party | 删除临时 Party | 减少 |
| --- | ---: | ---: | ---: |
| `Game.saveGame` 同步调用 | 216.682 ms | 166.506 ms | 23.16% |
| 发起保存至观察到完成 | 672.900 ms | 586.968 ms | 12.77% |
| 每次保存最长显示回调间隔 | 227.950 ms | 174.560 ms | 23.42% |

同步调用原三次 216.31 / 218.79 / 216.68 ms，新三次 166.51 / 166.70 / 165.96 ms。六次 exit code 均为 0、`completed=true`、`turn_delta=0`。单独详细诊断确认 `Party.cloneFull` 和 `Player.stripForExport` 均 0 次，**三次完整 GC 仍在**。

- 发布报告：[export-cleanup.md](docs/export-cleanup.md)、[结构化结果](docs/export-cleanup-results.json)。
- 原始 session：`P/sessions/stutter-cleanup-v2-{before,after}-pair{1,2,3}-01`。
- 详细探针：`P/sessions/stutter-cleanup-v2-probe-01`。
- 最初 `stutter-cleanup-{before,after}-pair*` 尚未支持 Cults，实际回退，**不能纳入收益样本**。

同步调用时长、保存流程时长、显示回调间隔是不同指标。流程包含 coroutine、后台写盘及观察延迟，不等于全程主线程阻塞；嵌套 span 不可相加。

### 5.2 状态、在线导出及重载

- `P/sessions/stutter-cleanup-state-check-01`：27 个现有角色、203 件物品及选定队伍/任务/资源/技能/效果字段一致，`changed/added/removed_sections=0`。是选定业务字段验证，不是整个世界或 RNG 一致性证明。
- `P/sessions/stutter-cleanup-export-check-01`：先安装双重网络拦截，再模拟在线认证；两个实际游戏快照的 263,388 bytes JSON、标题、标签一致。仅归一化原本无序的 effects/ESP/subsheets/addon tags，保留背包及技能等列表顺序。没有实际网络发送。
- `P/sessions/cleanup-roundtrip-20260913`：加载优化后的 after-pair3 存档，空闲 5 秒后再次保存，正常退出；22 个档案 ZIP CRC 通过。
- 派生输入 `P/cleanup-roundtrip-20260913.zip`、完整性记录 `P/cleanup-save-integrity.json`；六次 A/B 存档也通过 CRC，原始 ZIP 哈希保持不变。
- 诊断源码及发布回归日志：[evidence/faster-tome4-export-cleanup](evidence/faster-tome4-export-cleanup/README.md)。

### 5.3 回归测试与较早证据

最终日志 `P/logs/cleanup-tests-final-20260913.log`：20790 个基础断言、71 项 save/load、162 项 runtime（含 Ashes）、22 项 profiler、91 个克隆差分图、175 项角色导出检查、38 个 cleanup 场景 / 824 断言全部通过。克隆图该次为 73203 断言，遍历计数可随哈希顺序变化。cleanup 新测试在 JIT 开启和关闭时均通过；覆盖真实 Cults 包装器与错误/回退边界。

0.2.2 独立一轮 A/B：同步保存 **459.182→205.085 ms**（55.34%），流程 **911.499→619.968 ms**（31.98%）。见 [save-stutter.md](docs/save-stutter.md)、[结果](docs/save-stutter-results.json)，原始目录 `P/sessions/stutter-opt-{before,after}-pair{1,2,3}-01`。不要把它与 0.2.3 数字拼接成同一轮实验。

0.2.2 完整图差分验证 127833 个表、509503 个条目、27373 个计数对象。充分预热复制微基准 **109.354→73.084 ms**，不代表首次正常保存只需 73 ms；首次真实复制约 104–115 ms。对应 `stutter-opt-clone-check-01`、`stutter-opt-chardump-final-01`、`optimization-roundtrip`，均在 `P/sessions/`。

## 6. 剩余热点与建议接手顺序（均未投入生产）

先阅读 [followup-plan.md](docs/followup-plan.md)、[followup-results.json](docs/followup-results.json)，再按方向阅读 [render-next-analysis.md](docs/render-next-analysis.md)、[save-next-analysis.md](docs/save-next-analysis.md)、[snapshot-next-analysis.md](docs/snapshot-next-analysis.md)。这些是 **0.2.2 时期**的分析：其中“必须保留 Party/RNG”的旧约束已被用户后续授权及 0.2.3 实现取代。其他未完成方案仍可参考。

### 优先一：修复已确认的 gzip 原生内存泄漏

固定引擎 `src/core_lua.c:4034` 的 `core.zlib.compress` 在 `deflateInit2` 后没有 `deflateEnd`，成功及失败路径均泄漏状态；`len * 1.1 + 12` 的输出缓冲还使部分短串返回 nil。

可用已内置 lzlib：**`zlib.compress(data, 9, 8, 31, 8, 0)`**，动态输出并释放状态。原型两组各 100 次、每次 256 KiB 合成输入：原接口各保留 26,817,600 bytes，候选各 0；约 54→53 ms/100 次。真实角色 JSON 的压缩字节一致。指标是完整 Lua GC 后 glibc `mallinfo2.uordblks + hblkhd`，不是 RSS。

下一步：为已识别 exporter 设计局部替换，避免全局修改压缩 API；保留单返回值及失败约定、未知覆盖回退，验证空串/短串/随机数据/实际资料、重复导出原生内存及多平台绑定。其主要收益是防止内存持续保留，不能宣传成明显 CPU 加速；当前离线优化已经绕开该调用。

证据：`P/sessions/stutter-next-gzip-verify-01`、`stutter-next-real-gzip-01`；[FasterGzipBench.lua](evidence/faster-tome4-followup/diagnostics/FasterGzipBench.lua)、[FasterChardumpCheck.lua](evidence/faster-tome4-followup/diagnostics/FasterChardumpCheck.lua)。Linux FFI/mallinfo2 仅用于本地诊断，不应装进跨平台 addon。

### 优先二：快捷栏文字及地图特效遮罩缓存

`P/sessions/stutter-next-actions-01`：60 次普通移动最大显示间隔 43.27 ms，无超过 50 ms；战斗含接敌移动共 51 次动作，按低生命阈值正常停止，最大显示间隔 67.36 ms、动作响应 102.68 ms。快捷栏移动/战斗累计绘制 122.655 / 141.864 ms，单次最大 10.74 / 14.90 ms；这些是热点线索，尚无新缓存 A/B 收益。

建议先分离快捷键标签的文字光栅化耗时，对稳定标签做有界缓存，完整覆盖字体、缩放、分辨率、按键和界面变化失效；技能可用性、冷却、拖拽及鼠标逻辑仍逐次执行。地图侧只考虑可见格集合相同的静态 mask FBO；shader 时间、粒子和最终绘制继续每帧推进。验证连续图像序列，不能只比一张截图。

旧 native GL 探针出现过 postEffects `glDrawArrays` 107.505 ms wall / 0.033 ms 主线程 CPU，以及 FBO 到屏幕 66.141 / 51.386 ms；尚不足以断言是驱动编译、粒子锁或用户显卡问题。软件渲染结果必须与硬件 GPU 验证分开报告。

### 之后：减少快照 / GC 的主线程停顿

0.2.2 的详细首次保存中，复制 103.92–114.50 ms、截图 49.49–50.82 ms、Party 31.97–39.67 ms；三次 GC 合计 96.37–107.70 ms，在同步保存返回后的 coroutine 管线。**Party 项在 0.2.3 已移除**，新方案要重新测剩余分布。

可探索 Game 根字段消费者依赖闭包，保留子图仍完整复制，未知 hook/扩展回退；不能按字段名猜测删引用。GC 可先研究严格限域的相邻周期合并，再讨论事务切片。LuaJIT `step` 参数不是毫秒预算，完成旧增量周期不等价完整 GC 屏障，atomic 阶段不可任意拆分。

保存 coroutine 仍在主线程序列化 Lua；现有 native worker 只接收字节、压缩并写 ZIP。逐条唤醒当前 worker 会遇到队列空即关闭归档及共享状态问题。完整分片/后台方案要先设计同一规则时点的冻结、显示回调写入、弱表/终结器、任务顺序、第二次保存、退出和错误恢复协议。

额外注意：原 C 序列化 `_no_save_fields` 的 disallow=2 可以覆盖之前的 skip；`class.save` 移除元表，raw 字段与继承字段不同。ZIP 压缩等级 4→1 代理实验只节约约 8.69 ms 后台 CPU、体积增 4.63%，不是全游戏收益。Fearscape captive 引用 / 旧背包引用规范化仍未实施。Party 专用克隆原型对已删掉的导出路径不再优先。

## 7. 复现操作与验收方法

本节供下一轮代码改动使用；编写本文没有重新运行游戏或回归套件。

### fixtures 与打包

```bash
cd "$addon_root"
bash tests/run.sh /workspace/t-engine4 "$profile_root/fixtures/dlcs"
python3 tools/package.py
```

测试读取固定引擎 Git 提交。省略 DLC 参数会显式跳过相关覆盖，不能算完整回归。Cults fixture：`P/fixtures/dlcs/cults/tome-cults/superload/mod/class/Game.lua`，SHA256 `765df32782249dfb0d2db6a80a30c81052b40494456332815d95052ee0aef008`。

### 真实游戏轻量 A/B

先将新生产文件同步至 W 的 addon 副本，保留本地诊断 hooks/modules；确保没有同时启用另一个 faster 源码目录或归档。然后在独立终端 / 持续工具 session 中启动显示服务：

```bash
cd "$game_root"
bash tmp/profile/start-display.sh > tmp/profile/logs/xvfb-handoff-next.log 2>&1
```

该脚本前台运行。另一个终端设置上面的路径变量，再运行下例；**每轮改成新的唯一名称**，已有输出目录会被拒绝：

```bash
python3 "$profile_root/run-stutter-batch.py" stutter-handoff-next-before --count 1 \
  --config 'detail=false, save_only=true, unused_party_cleanup=false'
python3 "$profile_root/run-stutter-batch.py" stutter-handoff-next-after --count 1 \
  --config 'detail=false, save_only=true, unused_party_cleanup=true'
python3 "$profile_root/summarize-stutter.py" > "$profile_root/stutter-summary.txt"
```

正式比较使用至少三组独立原档副本、交替顺序、一次只改一个选项。`run-stutter-batch.py` 自动准备隔离 home、记录配置和 driver 哈希，串行运行；session 目录为 `P/sessions/名称-01` 等。名称保留 `stutter-` 前缀，汇总器只扫描这个前缀，并另写 `P/stutter-summary.json`。

`run-game.sh` 用 `P/game.lock` 的 nonblocking flock 防止同时运行，并关闭 Steam/web。`run-session.py` 检查退出状态、180 秒超时；成功必须同时满足 `process.json` 的 `exit_code=0`、`completed=true` 以及日志 `[YronProfile] SESSION_COMPLETE`。仅创建了 ZIP 不算成功。

详细定位用 `detail=true, save_only=true, export_guard_preserving=true`。直接包装 `dumpToJSON` 会改变方法来源，使离线导出 guard 正常回退，进而污染性能结论；先检查安装/skip 日志确认优化生效。业务状态检查可加 `validate_save_state=true`，在计时区间外比较。

在线资料对照阶段可用 `detail=false, phases={"party_export_check"}`。必须使用既有双重网络拦截后模拟认证，并保证恢复环境；不通过真实网络发送用户资料。

### 重载、完整性及清理

将某次已完成的优化存档目录打包，ZIP 根目录保持 `yron/`。用新的 session 名称：

```bash
python3 "$profile_root/prepare-home.py" "$profile_root/sessions/handoff-next-roundtrip/home" \
  --session --save /absolute/path/to/new-derived-save.zip
python3 "$profile_root/run-session.py" "$profile_root/sessions/handoff-next-roundtrip"
```

检查重新加载、再次保存、所有内部 ZIP CRC 和原始上传档 SHA256。`prepare-home.py` 拒绝覆盖已有目录，检查解压路径并关闭连接。只停止自己创建的游戏/Xvfb 进程，核对 `/proc/<pid>/cmdline` 和隔离 home，不使用宽泛的 `pkill`。旧环境里 `ps` 曾因库加载失败不可用，可读 `/proc`。

当前沙箱允许写 `/workspace/t-engine4` 和 `/tmp`；Xvfb 本地 socket、GitHub 网络或范围外写入可能需要工具级 escalation。沿用用户已授予的任务授权，不重复索要无必要确认。

### 下一项功能的完成标准

1. addon 内实现，准确描述作用域、兼容 guard 和用户可见行为差异；不把原型收益当成正式结果。
2. 运行适当回归和真实原档副本 A/B，确认优化实际安装，分别报告同步停顿、流程及内存等对应指标。
3. 涉及保存/导出时验证选定 live 状态、实际输出、Cults 禁存档/异常恢复、重载再次保存及 CRC；RNG 变化可接受，但其他规则差异需修正或明确报告。
4. 包中仅有生产文件，诊断默认关闭；更新设计、结果、版本及校验值，按既有授权提交并推送工作分支。
5. 说明未覆盖平台和硬件；不要把当前单存档、软件渲染结果泛化为所有场景。

## 8. 已踩过的坑与文档优先级

- 初版清理 guard 未识别 Cults，真实保存全部回退；修复后才使用 `stutter-cleanup-v2-*` 作为正式样本。
- `core.zlib.decompress` 不存在；本地验证用 `zlib.decompress(data, 47)`，会返回字符串和状态码 1，不要把第二返回值误传为 JSON 解析偏移。
- 小输入 gzip 预检失败是真实短缓冲问题，不能一概判定环境没准备好。
- 本地 FFI 时钟结构体声明曾冲突；复用声明或使用现有诊断写法，避免反复声明同名 C 类型。
- 克隆图计数不等于 ZIP entry 数；跨 yield 的 `saveObject` 外层时间包含期间其他工作。
- 更早 `docs/profiling.md` 等 ARM64/static 记录是历史环境，当前 AMD64 完整游戏已能运行，不要重复以“尚不能运行”判断阻塞。
- 当前行为以 [README](README.md) 和 [export-cleanup.md](docs/export-cleanup.md) 为准；0.2.2 文档保留历史基线，其中 RNG/Party 限制不再有效。

## 9. 安装包与接手入口

当前安装包：`tome-faster-0.2.3.teaa`（历史构建记录，见 [构建说明](releases/README.md)）。SHA256：

```text
b33ca1448702bdbcd3cc9e34da063ccca8c073b0a1bed7c139bf15619984047e
```

`A/dist/tome-faster.teaa` 是忽略的构建产物，同一版本包含 49 个源码文件，已逐文件及 CRC 验证。安装版本化归档时重命名为 `tome-faster.teaa`，放入 `game/addons/`，只保留一份 faster。历史 0.2.2 包不重写。

`tools/package.py` 使用明确 allowlist；`evidence/`、本地 profile、玩家数据和本根目录 `HANDOFF.md` 不进入安装包。本文纯文档变更无需重打包历史 release。

给下一位接手者的启动说明：

> 先读本 HANDOFF.md、docs/export-cleanup.md 和 docs/followup-plan.md。生产工作区是 `/workspace/t-engine4/tmp/worktrees/tome-faster-save-20260912`，当前功能基线 0.2.3 / f314ec5，工作分支 perf-save-stutter-20260912。环境和原档都已就绪。用户允许 RNG 消耗不同，但仍要求 addon 不随意改变游戏规则。若用户要求继续，优先把已验证的 gzip 原生泄漏替代方案做成有兼容检查的生产实现，或按最新指示处理渲染热点；保留已完成的验证和边界，不重做已删除 Party 的专用复制优化。
