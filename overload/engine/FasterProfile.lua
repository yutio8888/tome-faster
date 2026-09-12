-- GPL-3.0-or-later. Optional local diagnostics; disabled until start() is called.
-- Scalars only: never retain actors, maps, snapshots, arguments or returned objects.
local M={}
local active=false
local records, bindings={},{}
local function pack(...) return {n=select('#',...),...} end
local function wall() return core.game.getTime() end -- SDL milliseconds, wraps at 2^32.
local function bind(target,key,label)
    local original=target[key]
    if type(original)~='function' then return false end
    for _,b in ipairs(bindings) do if b.target==target and b.key==key then return true end end
    local binding={target=target,key=key,original=original,raw=rawget(target,key),enabled=true}
    local wrapped=function(...)
        if not active or not binding.enabled or (label=='gc.full' and select(1,...)~='collect') then return original(...) end
        local rec=records[label]
        if not rec then rec={started=0,completed=0,wall_ms=0,cpu_ms=0,max_wall_ms=0};records[label]=rec end
        rec.started=rec.started+1
        local start_wall,start_cpu=wall(),os.clock()
        -- No pcall: preserve coroutine yields and original errors/tracebacks on Lua 5.1.
        local result=pack(original(...))
        local dt=(wall()-start_wall)%4294967296
        rec.completed=rec.completed+1;rec.wall_ms=rec.wall_ms+dt
        rec.cpu_ms=rec.cpu_ms+(os.clock()-start_cpu)*1000
        rec.max_wall_ms=math.max(rec.max_wall_ms,dt)
        if key=='cloneForSave' and type(result[2])=='number' then
            rec.last_clone_objects=result[2];rec.max_clone_objects=math.max(rec.max_clone_objects or 0,result[2])
        end
        return unpack(result,1,result.n)
    end
    binding.wrapped=wrapped
    bindings[#bindings+1]=binding
    target[key]=wrapped
    return true
end
local function classMethods(name,methods)
    local target=package.loaded[name]
    if type(target)~='table' then return end
    for _,method in ipairs(methods) do bind(target,method,name..'.'..method) end
end
function M.attachGame(Game)
    if not active then return end
    for _,method in ipairs{'tick','saveGame','save','takeScreenshot','registerHighscore','cloneForSave'} do
        bind(Game,method,'mod.class.Game.'..method)
    end
end
function M.start()
    active=true
    bind(_G,'collectgarbage','gc.full')
    classMethods('engine.Savefile',{'loadReal','loadGame','saveGame','saveObject'})
    classMethods('engine.SavefilePipe',{'push','forceWait','steamCleanup'})
    classMethods('engine.Particles',{'loaded'})
    for _,name in ipairs{'mod.class.World','mod.class.Zone','engine.Level'} do classMethods(name,{'cloneForSave'}) end
    if type(package.loaded['mod.class.Game'])=='table' then M.attachGame(package.loaded['mod.class.Game']) end
end
function M.reset() records={} end
function M.snapshot()
    local out={}
    for name,rec in pairs(records) do out[name]={};for k,v in pairs(rec) do out[name][k]=v end end
    return out
end
function M.report()
    print('[FasterProfile] inclusive spans; wall=SDL ms, CPU=process CPU (includes native threads); unfinished=errors or suspended calls')
    local names={};for name in pairs(records) do names[#names+1]=name end;table.sort(names)
    for _,name in ipairs(names) do
        local r=records[name]
        print(('[FasterProfile] %s calls=%d/%d wall_ms=%.3f process_cpu_ms=%.3f max_wall_ms=%.3f clone_last=%s clone_max=%s')
            :format(name,r.completed,r.started,r.wall_ms,r.cpu_ms,r.max_wall_ms,tostring(r.last_clone_objects),tostring(r.max_clone_objects)))
    end
end
function M.stop()
    active=false
    for _,b in ipairs(bindings) do
        b.enabled=false
        -- Respect a later addon override; do not overwrite somebody else's function.
        if b.target[b.key]==b.wrapped then b.target[b.key]=b.raw end
    end
    bindings={}
end
return M
