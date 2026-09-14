# 0.2.12 默认开关验收

[当前默认值](../../docs/save-defaults.md)：库存归属压缩、Fearscape 清理开启，base62 关闭。

- [行为与兼容性结果](acceptance.json)：8 次真实游戏会话，默认三项配置均省略，4 次保存与4次读回通过；包含原版读取器和无 Faster 检查。
- [完整回归](regression.log)、[保存／加载 JIT 关闭](save_load-jit-off.log)、[库存 JIT 关闭](inventory_compact-jit-off.log)、[Fearscape JIT 关闭](fearscape_cleanup-jit-off.log)。
- [诊断运行器](run.py)、[探针](probe/overload/engine/SaveIsolatedProbe.lua)和[真实 Fearscape 场景](probe/overload/engine/FearscapeScenario.lua)。
- [最终打包检查](package-check.json)：所有打包源码与工作区一致，29 个生产文件与行为验收包一致。

行为验收使用包含最终生产代码的0.2.12包，SHA256为
`7e2c7a8d8aac9aa9fec26e5d2686c1871d2878d99df74303af5e97fac8dfe7a5`。
最终打包增加验收文档和元数据，包哈希因此不同，生产代码逐字节一致。
本轮没有新 CPU 基准；[此前单项性能证据](../faster-tome4-save-isolated-0.2.11/README.md)保持独立。
本目录仅保存源码、校验和状态结论，不包含角色对象图或存档。
