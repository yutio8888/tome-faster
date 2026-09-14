-- GPL-3.0-or-later; added 2026-09-13. Differential tests against pinned engine code.
assert(_VERSION == "Lua 5.1", "Lua 5.1 / LuaJIT required")
local root, engineRoot = arg[1] or ".", assert(arg[2], "engine clone required")
local F = assert(loadfile(root .. "/tests/ai_fixture.lua"))()
F.load(root, engineRoot)
local checks, scenarios = 0, 0
local function check(ok, message) assert(ok, message); checks = checks + 1 end
local function compare(spec, coordinates, options)
    scenarios = scenarios + 1
    local a, b = F.world(spec, false, true), F.world(spec, true, true, options)
    local n = spec.n or 16
    local points = coordinates or {1, 1, n-2, (spec.h or n)-2}
    local ao, ap = pcall(a.query, unpack(points))
    local bo, bp = pcall(b.query, unpack(points))
    local label = "scenario " .. scenarios .. " seed " .. tostring(spec.seed)
    check(ao == bo, label .. ": error parity")
    if ao then check(F.path(ap) == F.path(bp), label .. ": exact path mismatch") end
    check(table.concat(a.events, "\n") == table.concat(b.events, "\n"), label .. ": ordered callback/RNG trace mismatch")
    check(a.metrics.expanded == b.metrics.expanded, label .. ": expansion/reconstruction parity")
    return a, b
end

for _, mode in ipairs(jit and {"jit", "interpreter"} or {"interpreter"}) do
    if jit then
        if mode == "jit" then jit.on() else jit.off() end
        jit.flush()
    end
    for _, cache in ipairs{true, false} do
        for _, diagonal in ipairs{false, true} do
            for seed = 1, 120 do
                compare({n = 8 + seed % 11, density = seed % 46, seed = seed, cache = cache,
                    no_diagonals = diagonal, dynamic = seed % 3 == 0, use_seen = seed % 7 == 0})
            end
        end
    end
    for _, heuristic in ipairs{"zero", "random", "nan", "infinity", "negative_infinity", "sentinel"} do
        for seed = 1, 15 do compare({n = 13, density = 15, seed = seed, heuristic = heuristic, dynamic = true}) end
    end
    for _, heuristic in ipairs{"zero", "random", "nan", "negative_infinity"} do
        for seed = 1, 8 do compare({n = 36, seed = seed, heuristic = heuristic, dynamic = true}) end
    end
    do
        local a, b = compare({n=64, heuristic="nan", nan_at=1000})
        check(b.metrics.nan_next < a.metrics.nan_next, "NaN fallback after heap has activated")
    end
    for _, cache in ipairs{true, false} do
        for _, extra in ipairs{"hex", "switch_hex", "switch_adjacent", "reenter"} do
            local spec = {n = 12, cache = cache, dynamic = true, seed = 81}
            spec[extra] = true
            compare(spec)
        end
    end
    for _, points in ipairs{{0,0,0,0}, {0,0,15,15}, {0,0,16,16}, {-1,0,2,3}, {1,1,-1,0}, {15,0,0,15}} do
        compare({n=16}, points)
    end
    compare({n=64, shape="gap"})
    compare({n=64, shape="blocked"})
    -- Exercise the independently selectable A/B variants.
    compare({n=32, shape="gap"}, nil, {ai_astar_heap=false})
    compare({n=32, shape="gap"}, nil, {ai_astar_neighbors=false})
    print("PASS AI exact paths and ordered map/heuristic/RNG callbacks: " .. mode)
end
if jit then jit.on(); jit.flush() end

do
    local a, b = compare({n=64, shape="blocked"})
    check(b.metrics.next < a.metrics.next / 2, "frontier iteration work reduced, not just equal path lengths")
    print("PASS AI frontier next calls: " .. a.metrics.next .. " -> " .. b.metrics.next)
end
do
    local w = F.world({}, false, true)
    local old = w.Astar.calc
    check(not w.helper.installAstar(w.Astar, {ai_astar=false}) and w.Astar.calc == old, "opt-out")
    check(w.helper.installAstar(w.Astar), "install known engine")
    local installed = w.Astar.calc
    check(w.helper.installAstar(w.Astar) and w.Astar.calc == installed, "idempotent installation")
    local unknown = function() return "other addon" end
    w.Astar.calc = unknown
    check(not w.helper.installAstar(w.Astar) and w.Astar.calc == unknown, "retain later unknown override")
    check(not w.helper.installAstar({calc=unknown}), "retain earlier unknown override")
    local e = setmetatable({loadPrevious=function() return w.Astar end, config={settings={}},
        require=function(name) check(name == "engine.FasterAI", "superload helper"); return w.helper end,
        print=function() end}, {__index=_G})
    check(setfenv(assert(loadfile(root .. "/superload/engine/Astar.lua")), e)() == w.Astar, "superload returns original class")
    check(w.Astar.calc == unknown, "superload respects unknown override")
end
do
    local a, b = F.world({n=16}, false, true), F.world({n=16}, true, true)
    for i=1,12 do
        for _, w in ipairs{a,b} do w.map.walls[8+i%16*16] = i%2==0 end
        check(F.path(a.query(0,i%16,15,15-i%16)) == F.path(b.query(0,i%16,15,15-i%16)), "live map on repeated calls")
    end
    check(table.concat(a.events,"\n") == table.concat(b.events,"\n"), "repeated-query event parity")
    for key in pairs(b.instance) do check(key == "map" or key == "actor" or key == "move_cache", "no new serialized Astar fields") end
end
do
    local function movement(optimized)
        local w = F.world({n=24, shape="gap"}, optimized, true)
        local e, actor, definitions = w.env, w.actor, {}
        e.newAI = function(name, fn) definitions[name] = fn end
        F.run(F.simple, "@/engine/ai/simple.lua", e)
        local target, random = {x=22,y=22}, F.random(451)
        actor.ai_target = {actor=target}
        function actor:aiSeeTargetPos(t)
            local roll=random(2); w.record("targetRNG",roll)
            return t.x, t.y-roll
        end
        setmetatable(w.map, {__call=function(_, x, y, layer)
            w.record("actorAt",x,y,layer)
            if x==target.x and y==target.y then return target end
        end})
        function w.map:checkAllEntities(x,y,what,who)
            w.record("actorBlock",x,y,what,who==actor)
            return x==3 and y==3
        end
        local attempts=0
        function actor:moveDirection(x,y)
            attempts=attempts+1; w.record("move",x,y,attempts)
            if attempts%3==0 then return false end -- exercise move_simple fallback
            self.x,self.y=x,y
            return true
        end
        function actor:runAI(name,...)
            w.record("runAI",name)
            return definitions[name](self,...)
        end
        for i=1,12 do
            target.y=22-i%3
            actor:runAI("move_astar_advanced")
        end
        return table.concat(w.events,"\n"),actor.x,actor.y
    end
    local ae,ax,ay=movement(false)
    local be,bx,by=movement(true)
    check(ae==be and ax==bx and ay==by,"pinned move_astar_advanced/move_simple: moves, RNG, blockers and fallback order")
end
do
    local function safeGrid(optimized)
        local w = F.world({n=16},optimized,true)
        local e,actor=w.env,w.actor
        local methods={}
        local aiEnv=setmetatable({_M=methods,Astar=w.Astar},{__index=e})
        F.run(F.section(F.actorAI,741,816),"@/mod/class/interface/ActorAI.lua",aiEnv)
        actor.ai_target={actor={x=12,y=12}}
        function actor:combatMovementSpeed() return 1 end
        function actor:attr() return false end
        function actor:aiSeeTargetPos(t) return t.x,t.y end
        function actor:canMove(x,y)
            w.record("canMove",x,y)
            return w.map:isBound(x,y) and not w.map.walls[x+y*w.map.w]
        end
        e.core.fov.calc_circle=function(x,y,width,height,radius,block,apply)
            w.record("circle",x,y,radius)
            for cy=0,math.min(height-1,y+radius) do
                for cx=0,math.min(width-1,x+radius) do
                    if not block(nil,cx,cy) then apply(nil,cx,cy) end
                end
            end
        end
        local function hazard(_,x,y)
            w.record("hazard",x,y)
            return math.max(0,12-x-y),math.max(0,12-x-y),0
        end
        local grid=methods.aiFindSafeGrid(actor,5,1,1,1,0.5,false,hazard)
        w.record("result",grid[1],grid[2],grid.val,grid.dist,F.path(grid.path))
        return table.concat(w.events,"\n"),w.metrics.paths
    end
    local ae,ac=safeGrid(false)
    local be,bc=safeGrid(true)
    check(ac>1 and ac==bc and ae==be,"pinned aiFindSafeGrid: selected grid, full path and repeated-search callbacks")
end
do
    -- Run the actual hook with an Astar module loaded before superloading.
    local w=F.world({},false,true)
    local callback
    local e=setmetatable({config={settings={}},class={bindHook=function(_,name,fn)
        check(name=="ToME:load","AI hook name"); callback=fn
    end},print=function() end,get_printlog=function() return {} end,truncate_printlog=function() end},{__index=_G})
    e._G=e
    e.require=function(name)
        if name=="engine.FasterAI" then return w.helper end
        if name=="engine.Astar" then return w.Astar end
        if name=="engine.FasterRuntime" then return {installMap=function() end,installTalents=function() end} end
        if name=="engine.FasterEffectMask" then return {install=function() return true end} end
        if name=="engine.FasterSaveFollowup" then return {installClass=function() return true end} end
        if name=="engine.FasterSaveNames" then return {installSavefile=function() return true end} end
        if name=="engine.FBOGCGuard" then return assert(loadfile(root.."/overload/engine/FBOGCGuard.lua"))() end
        if name=="engine.class" then return e.class end
        if name=="engine.Map" or name=="engine.interface.ActorTalents" or name=="engine.Savefile" then return {} end
        if name=="engine.FasterSave" then return {installSavefile=function() return true end} end
        if name=="engine.CacheList" then return {new=function() return {} end} end
        if name=="engine.Particles" or name=="engine.Shader" then return {loaded=setfenv(function() end,e)} end
        error(name)
    end
    setfenv(assert(loadfile(root.."/hooks/load.lua")),e)()
    check(w.Astar.calc==w.original,"defer preloaded Astar patch until ToME load")
    callback()
    check(w.Astar.calc~=w.original,"ToME load patches preloaded Astar")
    local patched=w.Astar.calc
    e.loadPrevious=function() return w.Astar end
    check(setfenv(assert(loadfile(root.."/superload/engine/Astar.lua")),e)()==w.Astar and w.Astar.calc==patched,
        "hook and superload installation is idempotent")
end
print("PASS AI: " .. checks .. " checks; " .. scenarios .. " differential searches; " .. (jit and jit.version or _VERSION))
