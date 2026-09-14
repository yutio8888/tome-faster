-- GPL-3.0-or-later; added 2026-09-13. Isolated CPU/allocation measurements, not FPS.
local root, engineRoot = arg[1] or ".", assert(arg[2], "engine clone required")
local F = assert(loadfile(root .. "/tests/ai_fixture.lua"))()
F.load(root, engineRoot)
local repetitions = tonumber(arg[3]) or 12
assert(repetitions >= 1 and repetitions % 1 == 0)
local orders = {{1,2,4,3}, {2,3,1,4}, {3,4,2,1}, {4,1,3,2}}
local function allocation(w, n)
    collectgarbage("collect"); collectgarbage("stop")
    local before = collectgarbage("count")
    local path = w.query(1,1,n-2,n-2)
    local allocated = collectgarbage("count") - before
    collectgarbage("restart")
    return allocated, F.path(path)
end
print("runtime,mode,size,scenario,variant,kind,round,cpu_ms,allocated_kib")
for _, mode in ipairs(jit and {"jit", "interpreter"} or {"interpreter"}) do
    if jit then
        if mode == "jit" then jit.on() else jit.off() end
        jit.flush()
    end
    for _, n in ipairs(mode == "jit" and {16,32,64,96} or {64}) do
        for _, shape in ipairs{"open","gap","blocked"} do
            local spec = {n=n, shape=shape}
            local reference, variants = nil, {}
            for _, variant in ipairs{"original","neighbors","heap","both"} do
                local w = F.world(spec, variant ~= "original", false,
                    {ai_astar_heap=variant ~= "neighbors", ai_astar_neighbors=variant ~= "heap"})
                for i=1,20 do w.query(1,1,n-2,n-2) end
                local allocated,path = allocation(w,n)
                reference = reference or path
                assert(reference == path, "full path mismatch")
                variants[#variants+1] = {name=variant, world=w}
                print(string.format("%s,%s,%d,%s,%s,allocation,0,,%.3f", jit and jit.version or _VERSION,
                    mode,n,shape,variant,allocated))
            end
            for round=1,8 do
                for _, index in ipairs(orders[(round-1)%4+1]) do
                    local variant = variants[index]
                    collectgarbage("collect")
                    local start = os.clock()
                    for i=1,repetitions do variant.world.query(1,1,n-2,n-2) end
                    local elapsed = (os.clock()-start)*1000/repetitions
                    print(string.format("%s,%s,%d,%s,%s,timing,%d,%.6f,", jit and jit.version or _VERSION,
                        mode,n,shape,variant.name,round,elapsed))
                end
            end
        end
    end
end
