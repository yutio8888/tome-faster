if config.settings.save_size_probe then
    class:bindHook("ToME:runDone", function() require("engine.SaveSizeProbe").start() end)
end
