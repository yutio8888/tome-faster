# 局部 profile 的公开测量证据

方法、结论与限制见 [profiling.md](../../docs/profiling.md)，完整交接说明见
[performance report](../../docs/faster-tome4-performance-report.md)。
实现基线为 `070d3dc174ca84e841ebddc3c8df9ba4261f6b04`，版本 0.2.1 experimental。

results 中 particles.json、graph.json、native-validation.json 保留原始聚合结果，
source-manifest.json 保留固定源码身份。environment.json 和 compile.log 的本机路径
以 <ADDON_ROOT>、<TOME_ENGINE_ROOT>、<PROFILE_DATA> 代替；栈样本中的 native 地址
替换为 <native-address>。这些替换不改变计数、耗时和测量条件。

原存档、完整对象观察记录、生成的 graph.lua／粒子参数和本机可执行文件留在本地。
因此这些结果可供核对统计和方法，但本仓库不是可直接复现同一玩家输入的公开数据集。
准备工具保留本次案例结构假设，包括 yron 目录、捕获者引用和世界地图档案；使用其他
存档前需要适配并核验，不应当作任意存档的通用迁移器。

常规无存档回归入口为 tests/run.sh；原生粒子六个案例的既有结果在
[results/native-validation.json](results/native-validation.json)。完整游戏／GPU／Steam 尚未测试。
