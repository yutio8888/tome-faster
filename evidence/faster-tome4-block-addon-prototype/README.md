# 纯 addon 分块原型证据

结论及统计口径见[验证报告](../../docs/save-block-addon.md)。分块保存不加入正式包，本目录仅归档实验快照。

- [预先冻结的计划](acceptance-plan.json)：120 次保存、40 次读档，两个块大小分别统计。
- [完整统计及标量样本](results.json)、[分析程序](analyze_blocks.py)。分析先检查整批结果及源码哈希，再计算统计，不支持挑选部分样本。
- [正确性与实际失败测试](correctness.json)、[独立耗时归因](auxiliary-attribution.json)。
- [Lua 编码差分](encoder-jit.log)、[关闭 JIT 的差分](encoder-no-jit.log)、[读取器故障夹具](reader-faults.log)。故障夹具使用模拟文件系统及关闭 MD5 的调用分支；实际 ToME 失败测试保留了全部文件。
- `runtime/game/addons/` 包含冻结的 Lua 探针；`auxiliary/` 保留单独的计时探针。现有打包工具的目录清单不包含 `evidence/`，原型不会进入安装包。
- [文件哈希](source-manifest.json) 区分已归档源码与需另行准备的基线安装包。Git 不跟踪 `.teaa`，不含角色存档、完整游戏日志或原生测试二进制。

原实验布局是工作区下独立的 `tmp/block-addon-20260914` 和 `test-saves/block-addon-20260914`。复现需要另外准备对应游戏运行时、DLC、0.2.12 基线安装包、原始存档及配置种子。原基线包 SHA256 为 `ef287cf882b9fcea6719440ec901cfa2768651de13148265e0e9b19459d64f6c`，冻结计划保留该输入哈希；对应正式源码已归档为提交 `b75e44f`。运行器中的路径依赖该布局；复现时应使用新的隔离目录，调整路径并重新声明计划，不能覆盖冻结的实验目录。归因数据与正式性能数据分开。
