-- GPL-3.0-or-later. Profile the pinned clone function on a safely decoded save graph.
assert(_VERSION == 'Lua 5.1')
local dir, variant, rounds = assert(arg[1]), assert(arg[2]), tonumber(arg[3]) or 25
local clone = assert(loadfile(dir..'/clone.lua'))()
local build = assert(loadfile(dir..'/graph.lua'))
local function census(root)
    local seen, todo, n, atomic, particles, objects = {}, {root}, 0, 0, 0, 0
    while #todo > 0 do
        local t=table.remove(todo)
        if type(t)=='table' and not seen[t] then
            seen[t]=true; n=n+1
            if t.__ATOMIC or t.__CLASSNAME then atomic=atomic+1 end
            if t.__CLASSNAME=='engine.Particles' then particles=particles+1 end
            if t.__CLASSNAME=='mod.class.Object' then objects=objects+1 end
            for k,v in pairs(t) do if type(k)=='table' then todo[#todo+1]=k end if type(v)=='table' then todo[#todo+1]=v end end
        end
    end
    return {tables=n,atomic=atomic,particles=particles,objects=objects}
end
local function normalizeInventory(root)
    local actors, items, changes = {}, {}, 0
    local actor, item
    item=function(o, owner, id)
        if type(o)~='table' or items[o] then return end
        items[o]=true
        if o.in_inven and o.in_inven.actor==owner and type(o.in_inven.id)=='table' then
            o.in_inven.id=id; changes=changes+1
        end
        for _,s in ipairs(o.stacked or {}) do item(s,owner,id) end
        -- Seed-held NPCs have separate inventories; preserve all their mechanics/data.
        if o.demon then actor(o.demon) end
    end
    actor=function(a)
        if type(a)~='table' or actors[a] then return end
        actors[a]=true
        for id,inven in pairs(a.inven or {}) do
            for _,o in ipairs(inven) do item(o,a,id) end
        end
    end
    actor(root.player)
    return changes
end
local graph=build()
local changes=0
if variant=='fearscape' or variant=='both' then
    local t=assert(graph.player.demon_plane_trapper)
    assert(t.dead and t.ai_state.safe_grid.Astar.map.w==12)
    graph.player.demon_plane_trapper=nil -- Experiment on this audited snapshot ONLY.
end
if variant=='inventory' or variant=='both' then changes=normalizeInventory(graph) end
collectgarbage('collect'); collectgarbage('collect')
local baseline_kb=collectgarbage('count')
local counts=census(graph)
-- Warm up the identical clone code before collecting timings.
for i=1,8 do local c=clone(graph) end
collectgarbage('collect')
local measurements={}
local holder={}
local samples={}
local profiler
if arg[4] then
    profiler=require('jit.profile')
    profiler.start('i1',function(thread,n,state)
        local key=state..' '..profiler.dumpstack(thread,'l',2):gsub('\n',' ')
        samples[key]=(samples[key] or 0)+n
    end)
end
for i=1,rounds do
    collectgarbage('collect')
    local before=collectgarbage('count')
    -- Separate clone CPU from GC CPU in this isolated process, never in the live game.
    collectgarbage('stop')
    local t=os.clock(); local snap, nb=clone(graph); local dt=os.clock()-t
    holder[1]=snap
    local peak=collectgarbage('count')-before
    collectgarbage('restart')
    t=os.clock(); collectgarbage('collect'); local held_gc=os.clock()-t
    assert(holder[1].player~=graph.player, 'snapshot must remain live across the held GC')
    holder[1]=nil; snap=nil
    t=os.clock(); collectgarbage('collect'); local release_gc=os.clock()-t
    measurements[#measurements+1]={clone=dt,held_gc=held_gc,release_gc=release_gc,peak=peak,nb=nb}
end
-- Complement timer separation with clone runs under the default incremental collector.
local normal={}
collectgarbage('collect')
for i=1,rounds do local t=os.clock(); local snap=clone(graph);normal[i]=os.clock()-t end
local function summary(key)
    local vals={};for i,v in ipairs(measurements) do vals[i]=v[key] end
    table.sort(vals);return vals[math.ceil(#vals/2)],vals[1],vals[#vals]
end
local c,cmin,cmax=summary('clone');local h=summary('held_gc');local r=summary('release_gc');local peak=summary('peak')
table.sort(normal)
if profiler then
    profiler.stop()
    local rows={};for key,n in pairs(samples) do rows[#rows+1]={key=key,n=n} end
    table.sort(rows,function(a,b) return a.n>b.n end)
    local f=assert(io.open(arg[4],'w'))
    f:write('Samples at 1 ms; isolated clone and forced-GC workload, not live gameplay.\n')
    for _,row in ipairs(rows) do f:write(row.n,'\t',row.key,'\n') end
    f:close()
end
print(('{"variant":"%s","rounds":%d,"normalized_records":%d,"tables":%d,"atomic":%d,"particles":%d,"objects":%d,"lua_heap_kb":%.3f,"clone_count":%d,"clone_median_s":%.9f,"clone_min_s":%.9f,"clone_max_s":%.9f,"held_gc_median_s":%.9f,"release_gc_median_s":%.9f,"clone_alloc_kb":%.3f,"clone_normal_gc_median_s":%.9f}')
    :format(variant,rounds,changes,counts.tables,counts.atomic,counts.particles,counts.objects,baseline_kb,measurements[1].nb,c,cmin,cmax,h,r,peak,normal[math.ceil(#normal/2)]))
