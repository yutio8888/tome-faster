if config.settings.save_size_probe then
    local cfg=config.settings.save_size_probe
    if (cfg.block_bytes or 0)>0 or cfg.read_blocks then
        require('engine.BlockPrototype').install(cfg)
    end
    if cfg.reload then require('engine.BlockLoadMetrics').install(cfg) end
    class:bindHook("ToME:runDone", function() require("engine.SaveIsolatedProbe").start() end)
end
