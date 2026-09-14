-- GPL-3.0-or-later. Linux 1.7.6 diagnostic only, no movement or game ticks.
local M = {}
local function encode(v)
    local kind = type(v)
    if kind == "nil" then return "null" end
    if kind == "boolean" or kind == "number" then return tostring(v) end
    if kind == "string" then
        return '"' .. v:gsub('[%z\1-\31\\"]', function(c) return ('\\u%04x'):format(c:byte()) end) .. '"'
    end
    local out = {}
    if #v > 0 then
        for i = 1, #v do out[#out+1] = encode(v[i]) end
        return '[' .. table.concat(out, ',') .. ']'
    end
    for k, x in pairs(v) do out[#out+1] = encode(tostring(k)) .. ':' .. encode(x) end
    return '{' .. table.concat(out, ',') .. '}'
end
local function emit(row) print('[FasterAIBench] ' .. encode(row)) end
local function pathString(path)
    if not path then return "nil" end
    local out = {}
    for i = 1, #path do out[i] = path[i].x .. ',' .. path[i].y end
    return table.concat(out, ';')
end
local function snapshot()
    local actors = 0
    for _, actor in ipairs(game.level.e_array) do if actor.__is_actor then actors = actors + 1 end end
    return {turn=game.turn, x=game.player.x, y=game.player.y, life=game.player.life,
        actors=actors, paused=game.paused and true or false}
end
local function run()
    assert(config.settings.cheat and not _G.profiling)
    local cfg = config.settings.faster_tome or {}
    assert(not cfg.profile and not cfg.stutter and not cfg.session and cfg.fbo_gc_guard ~= false)
    local ffi = require 'ffi'
    ffi.cdef[[struct faster_ai_bench_ts {long sec; long nsec;};
        int clock_gettime(int, struct faster_ai_bench_ts *);]]
    local ts = ffi.new('struct faster_ai_bench_ts[1]')
    local function clock(id)
        assert(ffi.C.clock_gettime(id, ts) == 0)
        return tonumber(ts[0].sec) * 1000 + tonumber(ts[0].nsec) / 1000000
    end
    local Astar, Map = require 'engine.Astar', require 'engine.Map'
    local Helper, Effect = require 'engine.FasterAI', require 'engine.FasterEffectMask'
    local production = Astar.calc
    assert(debug.getinfo(production, 'S').source:find('FasterAI.lua', 1, true), 'Astar optimization not installed')
    local fbo_mt = debug.getregistry()['gl{fbo}']
    local guarded = fbo_mt and require('engine.FBOGCGuard').originalUse(fbo_mt, fbo_mt.__index.use)
    assert(guarded, 'default FBO guard missing')
    assert(debug.getinfo(Map.displayEffects, 'S').source:find('FasterEffectMask.lua', 1, true), 'effect batching not installed')
    local function upstream()
        -- Directly load the runtime's original file without changing package.loaded.
        local env = setmetatable({_M={}, module=function() end}, {__index=_G})
        setfenv(assert(loadfile('/engine/Astar.lua')), env)()
        local info = debug.getinfo(env._M.calc, 'S')
        assert(info.source == '@/engine/Astar.lua' and info.linedefined == 113 and info.lastlinedefined == 193)
        return env._M
    end
    local original, neighbors, heap = upstream(), upstream(), upstream()
    assert(Helper.installAstar(neighbors, {ai_astar_heap=false}))
    assert(Helper.installAstar(heap, {ai_astar_neighbors=false}))
    local variants = {{name='original', calc=original.calc}, {name='neighbors', calc=neighbors.calc},
        {name='heap', calc=heap.calc}, {name='both', calc=production}}
    local before = snapshot()
    assert(before.paused, 'game must wait for input')
    local map, actor = game.level.map, game.player
    local astar = Astar.new(map, actor)
    local cache = map._fovcache.path_caches[actor:getPathString()]
    local sx, sy = actor.x, actor.y
    local targets = {}
    for y = 0, map.h-1 do for x = 0, map.w-1 do
        local blocked
        if cache then blocked = cache:get(x, y)
        else blocked = map:checkEntity(x, y, Map.TERRAIN, 'block_move', actor, nil, true) end
        if not blocked and (x ~= sx or y ~= sy) then
            targets[#targets+1] = {sx=sx, sy=sy, tx=x, ty=y, distance=math.max(math.abs(x-sx), math.abs(y-sy))}
        end
    end end
    -- Selection uses geometry and original path length, never measured timings.
    table.sort(targets, function(a,b)
        if a.distance ~= b.distance then return a.distance > b.distance end
        if a.ty ~= b.ty then return a.ty < b.ty end
        return a.tx < b.tx
    end)
    local groups = {{name='short', queries={}}, {name='medium', queries={}},
        {name='long', queries={}}, {name='unreachable', queries={}}}
    for _, q in ipairs(targets) do
        local path = original.calc(astar, q.sx, q.sy, q.tx, q.ty)
        local group = not path and groups[4] or (#path <= 3 and groups[1] or #path <= 15 and groups[2] or groups[3])
        if #group.queries < 8 then
            q.path_length = path and #path or false
            q.reference = pathString(path)
            group.queries[#group.queries+1] = q
        end
    end
    local assertions = 0
    for _, group in ipairs(groups) do for _, q in ipairs(group.queries) do
        for _, variant in ipairs(variants) do
            assert(pathString(variant.calc(astar, q.sx, q.sy, q.tx, q.ty)) == q.reference, 'path mismatch: '..group.name..'/'..variant.name)
            assertions = assertions + 1
        end
        q.reference = nil
    end end
    emit({kind='setup', runtime=jit and jit.version or _VERSION, jit=jit and jit.status() or false,
        map_w=map.w, map_h=map.h, path_cache=cache and true or false, targets=#targets,
        groups=groups, assertions=assertions, before=before, fbo_guard=true, effect_stats=Effect.stats()})
    local checksum = 0
    local function batch(calc, group, repeats)
        for _ = 1, repeats do for _, q in ipairs(group.queries) do
            local path = calc(astar, q.sx, q.sy, q.tx, q.ty)
            checksum = checksum + (path and #path or 0)
        end end
    end
    -- A balanced Latin square; each variant occupies each timing position twice.
    local orders = {{1,2,4,3}, {2,3,1,4}, {3,4,2,1}, {4,1,3,2}}
    local rows = {}
    for _, group in ipairs(groups) do if #group.queries > 0 then
        for _, variant in ipairs(variants) do batch(variant.calc, group, 30) end
        collectgarbage('collect')
        local start = clock(3)
        batch(original.calc, group, 10)
        local calibration = math.max(0.001, (clock(3)-start)/10)
        local repeats = math.min(2000, math.max(1, math.ceil(25/calibration)))
        for round = 1, 8 do
            for _, index in ipairs(orders[(round-1)%4+1]) do
                local variant = variants[index]
                collectgarbage('collect')
                local wall, cpu = clock(1), clock(3)
                batch(variant.calc, group, repeats)
                cpu, wall = clock(3)-cpu, clock(1)-wall
                rows[#rows+1] = {kind='timing', group=group.name, variant=variant.name, round=round,
                    queries=#group.queries*repeats, cpu_ms=cpu, wall_ms=wall}
            end
        end
        for _, variant in ipairs(variants) do
            collectgarbage('collect'); collectgarbage('stop')
            local memory = collectgarbage('count')
            batch(variant.calc, group, 1)
            memory = collectgarbage('count')-memory
            collectgarbage('restart')
            rows[#rows+1] = {kind='allocation', group=group.name, variant=variant.name,
                queries=#group.queries, allocated_kib=memory}
        end
    end end
    for _, row in ipairs(rows) do emit(row) end
    local after = snapshot()
    for k, value in pairs(before) do assert(after[k] == value, 'game state changed: '..k) end
    assert(Astar.calc == production and assertions > 0)
    emit({kind='complete', after=after, checksum=checksum, assertions=assertions, effect_stats=Effect.stats()})
end
function M.start()
    local Game = require 'mod.class.Game'
    local display, frames, started = Game.display, 0, core.game.getTime()
    local done = false
    Game.display = function(self, ...)
        local result = display(self, ...)
        frames = frames + 1
        if not done and frames >= 30 and core.game.getTime()-started >= 2000 then
            done = true
            local ok, err = xpcall(run, debug.traceback)
            if not ok then collectgarbage('restart'); emit({kind='error', error=err}) end
            core.game.exit_engine()
        end
        return result
    end
end
return M
