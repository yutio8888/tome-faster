-- GPL-3.0-or-later.
if config.settings.faster_ai_bench then
    class:bindHook("ToME:runDone", function() require("engine.FasterAIBench").start() end)
end
