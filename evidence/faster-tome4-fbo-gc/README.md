# 0.2.8 FBO 回收保护验证

实现及测量边界见 [设计说明](../../docs/fbo-gc.md)。FBO helper 与独立原型字节相同，启动入口改为 Faster ToME4 自身的 hooks，保留 `faster` 身份，并支持 `fbo_gc_guard=false` 关闭。

[完整回归](regression.log) 通过，包括既有缓存、保存／加载、DLC、原生 GL、gzip、截图、等待刷新及快照套件。新的 FBO 套件在 JIT 开启和 [关闭](fbo-gc-jit-off.log) 时各通过 25 项检查。

FBO 图形套件编译固定 1.7.6 引擎的原生绑定，在真实 EGL／llvmpipe 上下文中核查绑定、像素、嵌套矩阵／视口、释放时机和多轮 GC；单独的 C 资源模型核查 Lua 状态关闭及处理过程中再次 GC。533 个生命周期资源和 3 个重入资源均恰好释放一次。模型的资源计数不是整局游戏的显存泄漏测量。

复现命令：

```sh
bash tests/run.sh "$TOME_ENGINE_ROOT" "$TOME_DLC_ROOT"
luajit -joff tests/test_fbo_gc.lua . "$TOME_ENGINE_ROOT"
```

除已有的 EGL／GL 及 Lua 5.1 头文件，资源宿主还需要 Lua 5.1 兼容链接库，通过 `pkg-config luajit` 或 `pkg-config lua5.1` 定位。这些仅为测试依赖，addon 不包含原生库。

原型的 12 次战斗可行性数据另列于 [脱敏汇总](../../docs/fbo-gc-results.json)，没有将集成加载检查追加到该小样本中。原型数据不能用于声称稳定改善比例或 Windows 表现。

集成后的 0.2.8 在未修改引擎上分别完成启用／关闭两次真实游戏检查，各启动火雨并等待五次，无 Lua 错误，运行代码与提交源码一致；日志确认启用条件生效、关闭条件未安装。[集成检查](integration.json)
