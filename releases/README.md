# 已生成的版本快照

这些 teaa 文件保留原来构建时的字节和哈希，没有因公开说明文档更新而重打包。

| 文件 | 代码基线 | 用途 |
| --- | --- | --- |
| [tome-faster-0.2.5.teaa](tome-faster-0.2.5.teaa) | 本次 0.2.5 提交 | 快捷栏文字缓存、地图遮罩批处理、保存回调复用；当前交付版 |
| [tome-faster-0.2.4.teaa](tome-faster-0.2.4.teaa) | 6a307b8 | 修复角色导出 gzip 内存保留；历史版本 |
| [tome-faster-0.2.3.teaa](tome-faster-0.2.3.teaa) | f314ec5 | 删除未使用的导出 Party；不保留其 RNG 消耗，历史版本 |
| [tome-faster-0.2.2.teaa](tome-faster-0.2.2.teaa) | d4dbf77 | 保留临时 Party 与 RNG 消耗的历史保存优化版 |
| [tome-faster-0.1.0.teaa](tome-faster-0.1.0.teaa) | b8ab0c9 | 第一轮修复历史对照 |
| [tome-faster-0.2.0.teaa](tome-faster-0.2.0.teaa) | ec0a3d1 | 历史交付版快照 |
| [tome-faster-0.2.1-profile.teaa](tome-faster-0.2.1-profile.teaa) | 070d3dc | 有限粒子寿命与计时器实验版 |

安装时将所选版本重命名为 `tome-faster.teaa`，只启用一份 short_name 为 faster 的 addon。代码及说明均可从对应 Git commit 检出。
当前分支重新运行 tools/package.py 会包含更新后的文档，生成的包哈希会与历史快照不同。
历史包内若提到“本地分支”，那是构建时的交付状态；当前发布状态以本分支 README 为准。

0.2.4 SHA256：`e5f34b6c132796665d4607dda1c5beeac1d61902a7e538a7dac21db787acdbb4`。包含 54 个 allowlist 文件，CRC 和逐文件内容校验通过；没有诊断模块、玩家资料、存档或已编译测试库。

0.2.5 SHA256：`39c06d93a6a39c74286c3aa31b446a2d577dc0bfcc319c5131269c3c2a4b1754`。包含 67 个 allowlist 文件，CRC、逐文件内容和生产 Lua 语法校验通过；测试运行副本与新生产模块逐字节一致。没有诊断模块、玩家资料、存档或已编译原生测试库。
