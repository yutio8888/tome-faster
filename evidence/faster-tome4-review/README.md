# 原插件来源与缺陷复现

原作者 yutio888，原始包 0.0.1。来源和逐文件 SHA256 见 [provenance.json](provenance.json)，
原包见 [tome-faster-0.0.1.teaa](../../upstream/tome-faster-0.0.1.teaa)。
[publication.json](publication.json) 仅记录初始 main 分支导入的历史核验。
后续修复与限制见 [known-fixes.md](../../docs/known-fixes.md)。

[reproduce.lua](reproduce.lua) 针对未修改的原版：第一个参数为隔离解压后的 0.0.1 源码目录，
第二个参数为固定 commit `624a67329fe2ad440c5b344785a9c73fcf22ae63` 的引擎源码目录。
使用 Lua 5.1／LuaJIT，并在同一次调用中配置 LUA_PATH、LUA_CPATH。
当前分支已经修复这些缺陷，不能把当前根目录作为原版复现输入。
