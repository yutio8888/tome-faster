# 0.2.11 单项存档优化的独立测量证据

本目录对应 2026-09-14 的同包、独立开关实验。正式数据为五场景各30对，共300次保存；与此前180次混合开关试验分别保存，未共享基准或合并数据。

- [说明与结果](../../docs/save-isolated.md)、[全部配对值与统计](../../docs/save-isolated-results.json)。
- [最终计划](acceptance-plan.json)：完整300次顺序、输入与环境指纹、事件口径和判定方法。
- [诊断运行器](run.py)、[探针](probe/overload/engine/SaveIsolatedProbe.lua)、[真实 Fearscape 场景](probe/overload/engine/FearscapeScenario.lua)、[CPU 采样](probe/overload/engine/SaveCompactionCPU.lua)。
- [完整队列分析器](analyze_isolated.py)、[独立统计复算器](recompute_public.py)、[复算结果](public-recompute-check.json)。
- [300次原始时钟与空采样区间](timing-samples.json)：仅含计时标量，没有角色状态。
- [原读取器与无 Faster 读档](compatibility.json)：三种单项输出各两种读回，共六次。
- [最终输入与保护存档完整性](integrity.json)、[二十次预检](preflight-validity.json)。
- [实验协议评审](protocol-review.md)、[分析器核验说明](analyzer-review.md)、[完整结果解释复核](results-review.md)。

第一版计划和运行器保留在 [采样前的修订副本](preformal-revision-1/acceptance-plan.json)。正式采样前完成第二轮十次预检，随后重新冻结计划；两个版本的预检都不进入300次正式样本。正式测量期间没有改变包、运行器、探针、计划、次序或样本数。分析方法在首个正式样本前固定；分析器在采样期间完成实现和纯合成／预检校验，完整队列结束后才读取正式性能数据。

全部比较使用同一个441398字节的0.2.11包，SHA256为
`9464fdfc425f53a238aa76ffc16853bd9c5e38df9d6e9b5519941b517f5d2f76`。
本次任务没有修改29个生产源码文件、默认开关或 dist 包。目录不含角色存档、完整对象图、游戏二进制或第三方资源；原始运行记录及各自的测试 home 保留在工作区独立实验目录。

公开配对值可以直接复算：

```bash
python3 evidence/faster-tome4-save-isolated-0.2.11/recompute_public.py \
  --results docs/save-isolated-results.json
```

完整验证器还会使用本机保存的状态投影核验每对语义一致性，因此需要原实验目录：

```bash
python3 -B /workspace/t-engine4/tmp/save-isolated-20260914/analyze_isolated.py \
  --output /tmp/save-isolated-recomputed.json
```

运行器用于说明和复现实验逻辑；它拒绝覆写已有会话。重新采样需要新实验目录、新测试 home 和事前冻结的新计划，不应更换本目录中个别样本。
