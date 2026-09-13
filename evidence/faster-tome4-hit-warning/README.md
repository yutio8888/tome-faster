# 0.2.7 远程受击方向提示限速

用户要求减少过于频繁的远程受击提示。默认同一 Map 的所有 `hit_warning` 共用 500ms 间隔，
首个立即放行，被抑制的请求不延长间隔；玩家移动和攻击方向变化也不重置间隔。
`config.settings.faster_tome.hit_warning_interval_ms=1000` 改为每秒一次，`0` 恢复不限速，重启生效。

实现只包装 Map.particleEmitter 的同名提示，其他粒子完整透传参数与返回值；不缓存 emitter。
弱键 Map→时间旁表不进入 Map 字段或存档，毫秒差按 2^32 取模处理原生 SDL 时钟回绕。
受抑制调用无返回值，固定引擎唯一的 Player:onTakeHit 调用不消费返回值。更少的视觉粒子也
减少其随机数消耗，不补抽 RNG；没有修改伤害处理、技能或伤害公式。

固定引擎 `624a67329fe2ad440c5b344785a9c73fcf22ae63` 的源码依据：

- `game/modules/tome/class/Player.lua:793–800`：距离大于1时，在玩家处创建方向提示。
- `game/engines/default/engine/Map.lua:1403–1412`：创建粒子并注册两个容器，返回 emitter。
- `src/core_lua.c:521–525`：getTime 为 SDL_GetTicks 无符号32位毫秒。

在既有 `tests/test_existing.lua` 扩展35项检查，执行实际 Map superload，控制时钟及下游发射器。
覆盖首发、突发、499/500ms边界、坐标/方向变化、Map独立性和弱引用回收、参数/返回值/空参数、
SDL回绕、自定义间隔、关闭限速及无效配置回退。

```sh
bash tests/run.sh "$TOME_ENGINE_ROOT" "$TOME_DLC_ROOT"
luajit -joff tests/test_existing.lua . "$TOME_ENGINE_ROOT"
```

[完整回归](regression.log) 通过，包括既有保存、渲染和原生 fixtures；
[JIT-off 基础套件](existing-jit-off.log) 通过，两种模式各20825项断言。
这是功能限速回归，没有新增真实游戏 FPS 或画面验收，也不宣称某个毫秒性能收益。
