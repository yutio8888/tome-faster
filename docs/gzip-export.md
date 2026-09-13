# 0.2.4：修复角色导出 gzip 原生内存保留

2026-09-13。实现位于 [FasterGzip.lua](../overload/engine/FasterGzip.lua)。它只替换已识别的 `Player.saveUUID` 内角色 JSON 压缩调用，使用游戏已内置的 lzlib；不修改全局 `core.zlib`，也不重写存档 ZIP、charball 档案、保存线程或游戏规则。

## 问题和实现边界

固定引擎 `624a67329fe2ad440c5b344785a9c73fcf22ae63` 的 `src/core_lua.c` 在 `deflateInit2` 后没有调用 `deflateEnd`，成功和失败路径均保留压缩状态。固定大小输出缓冲 `len * 1.1 + 12` 对空串和部分短串也不足。

新实现采用 `zlib.compress(data, 9, 8, 31, 8, 0)`，参数与原接口一致：level 9、DEFLATED、gzip、memLevel 8、默认 strategy。lzlib 动态收集输出，并在正常完成及 deflate 错误后释放状态。只有字符串输出且状态为 `Z_STREAM_END`（1）才向 consumer 返回一个值；其他状态返回零个值，保留旧压缩失败时的参数数量，不传入部分 gzip 或额外状态码。Lua 异常照常传播。极端 Lua 分配失败中断原生函数不属于已证明的内存释放路径。

安装器复制固定 `engine.interface.PlayerDumpJSON.saveUUID` 的本体，仅修改压缩调用，保留其函数环境、UUID 注册、JSON builder、资料 hook、consumer 和延迟 charball 回调（包括原有全局 `f` 写入）。离线资料跳过仍位于外层，两项开关可独立组合；自定义 dumper 和资料 hook 仍被原样调用。

兼容检查要求已知 exporter 源码路径、行号和零 upvalue，以及原生 C compressor/decompressor。内置 lzlib 注册时丢弃了单独的元数据表，因此实际全局 `_VERSION` 为 nil；允许 nil 或已知的 `lzlib 0.3`，拒绝其他声明版本，并对空串及带 NUL 的二进制短串做 gzip 往返预检。预检不调用旧的泄漏接口。来源、原生函数类型和能力检查不是代码哈希认证。

在实际压缩点再次检查 core/zlib 表和绑定身份。其他 addon 后来替换接口（包括在 dumper 或 hook 内替换）时，调用当前 `core.zlib.compress`，透传其所有返回值与异常。非字符串输入及长度超过 lzlib 有符号 int 上限的字符串也回退。未知 exporter 或预检失败不替换原方法；此时旧接口的缺陷也可能保留。`config.settings.faster_tome.export_gzip = false` 并重启可关闭本项。

正常输入成功时保持相同压缩字节。空串及原先缓冲不足的短串现在能生成有效 gzip，这是有意修复的行为差异。保存格式、技能、伤害、AI、冷却和 Cults 禁存档规则未改。

## 三组真实导出对照

每侧测量 300 次完整角色导出，分为六批各 50 次；另有每进程一次输出检查和五次预热。每批均在丢弃输出及完整 Lua GC 后读数。

| 指标 | 原 core gzip | 修复后 |
| --- | ---: | ---: |
| 每 50 次导出原生分配增量，中位数 | 13,408,800 bytes（约 12.8 MiB） | 0 bytes |
| 六批原生分配增量 | 五批 13,408,800，一批 13,408,816 bytes | 六批均为 0 bytes |
| 每 50 次完整导出耗时，中位数 | 12,466.50 ms | 12,562.31 ms |

真实 JSON 为 **263,388 bytes**，输出逐次解压一致，使用相同输入与原压缩器对比时 gzip 字节相同。实际导出仍主要耗时于描述生成，这轮没有测得稳定 CPU 加速；修复收益是消除已识别压缩路径的持续原生内存保留。

六个进程均正常退出、完成保存且游戏回合未推进；六份存档各 22 个 ZIP 档案 CRC 通过。围绕导出及保存检查的 **27 个角色、203 件物品**和选定业务字段一致。另两次兼容诊断确认 gzip 开/关时原始与优化在线 JSON、标题和标签一致，离线无消费者路径仍不编码 JSON，Cults 禁存档和异常回退 fixture 通过。上述是选定状态及所测调用链验证，不是整个游戏状态逐字段证明。

第三组优化存档使用最终 0.2.4 元数据重新加载，空闲后再次保存并正常退出；重载后 22 个 ZIP 档案 CRC 通过。原上传 ZIP 的 SHA256 保持不变。

## 验证方法

新增 native fixture 从固定引擎 Git 提交提取两种压缩器，使用 Lua 5.1 ABI 编译到临时目录执行；262 项检查在 JIT 开/关时均通过，覆盖随机数据、空串、短串、实际原生状态码、成功/失败参数数量、异常对象、UUID、charball、动态环境、接口覆盖及四种优化开关组合。预检使用实际 lzlib 注册表，未假造版本字段。完整回归通过，包括 Ashes 和 Cults 的固定哈希 fixture。

真实游戏使用同一原始存档的六份独立副本，三组交替 A/B，只切换 `export_gzip`。每个进程先加载及预热，再拦截全局 profile sender 与实际 consumer 的 sender，然后模拟在线认证；不真实上传资料。调用实际安装的 `player:saveUUID(nil)`，验证真实 JSON 解压及与旧压缩器的字节一致性；预热五次后，各执行两批 50 次完整角色导出，释放捕获输出并在每批前后完整 Lua GC 后读取 glibc `mallinfo2.uordblks + hblkhd`。该指标是分配器仍保留的活动分配，不是 RSS 或 Lua 堆大小。

导出在游戏快照上执行，比较选定的 live 和 snapshot 状态；恢复认证和所有诊断包装后，执行正常离线保存并再次检查 live 状态。此处保存已充分预热，且导出基准后执行过显式 GC，不能与 0.2.3 的首次轻量保存时长直接比较，也不用于宣传新的保存加速。

结构化测量、最终回归和重载结果见 [结果](gzip-export-results.json) 与 [验证入口](../evidence/faster-tome4-gzip/README.md)。Linux FFI 内存/时钟探针只存在于包外诊断；生产实现没有平台原生依赖。当前完整游戏验证限于 Linux、内嵌 LuaJIT 2.0.2、Xvfb/llvmpipe 和所给存档；Windows/macOS、硬件 GPU、Steam 及真实在线传输尚未验证。
