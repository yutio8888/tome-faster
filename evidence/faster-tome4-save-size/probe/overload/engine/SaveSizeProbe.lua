-- GPL-3.0-or-later. Diagnostic only; no source save should use this addon.
local M = {}
local function encode(v)
    local kind = type(v)
    if kind == 'nil' then return 'null' end
    if kind == 'boolean' or kind == 'number' then return tostring(v) end
    if kind == 'string' then return '"'..v:gsub('[%z\1-\31\\"]', function(c) return ('\\u%04x'):format(c:byte()) end)..'"' end
    local out = {}
    if #v > 0 then
        for i=1,#v do out[#out+1]=encode(v[i]) end
        return '['..table.concat(out,',')..']'
    end
    for k,x in pairs(v) do out[#out+1]=encode(tostring(k))..':'..encode(x) end
    return '{'..table.concat(out,',')..'}'
end
local function emit(row) print('[SaveSizeProbe] '..encode(row)) end
local function state()
    local p, actors, objects = game.player, {}, {}
    for _,a in ipairs(game.level.e_array) do
        if a.__is_actor then actors[#actors+1]={uid=a.uid,x=a.x,y=a.y,life=a.life,dead=a.dead or false} end
    end
    table.sort(actors,function(a,b)return a.uid<b.uid end)
    for inventory,list in pairs(p.inven) do for _,o in ipairs(list) do
        objects[#objects+1]={uid=o.uid,inventory=inventory,stacked=o.stacked and #o.stacked or 0}
    end end
    table.sort(objects,function(a,b)return a.uid<b.uid end)
    return {turn=game.turn,x=p.x,y=p.y,life=p.life,uid=p.uid,level=p.level,
        paused=game.paused and true or false,actors=actors,inventory=objects}
end
function M.start()
    local cfg=config.settings.save_size_probe
    assert(config.settings.cheat and not _G.profiling)
    local ft=config.settings.faster_tome or {}
    assert(not ft.profile and not ft.stutter and not ft.session)
    local ffi=require 'ffi'
    ffi.cdef[[struct save_size_ts {long sec;long nsec;}; int clock_gettime(int,struct save_size_ts*);]]
    local ts=ffi.new('struct save_size_ts[1]')
    local function clock(id)
        assert(ffi.C.clock_gettime(id,ts)==0)
        return tonumber(ts[0].sec)*1000+tonumber(ts[0].nsec)/1e6
    end
    local Savefile,Pipe,Game=require 'engine.Savefile',require 'engine.SavefilePipe',require 'mod.class.Game'
    local original_name=Savefile.getFileName
    local info=debug.getinfo(original_name,'S')
    assert(info.source=='@/engine/Savefile.lua' and info.linedefined==130 and info.lastlinedefined==136)
    local names=setmetatable({}, {__mode='k'})
    if cfg.compact then
        Savefile.getFileName=function(self,o)
            if o==self.current_save_main then return 'main' end
            local cache=names[self]
            if not cache then cache={count=0,objects=setmetatable({}, {__mode='k'})}; names[self]=cache end
            local name=cache.objects[o]
            if not name then
                cache.count=cache.count+1
                name=tostring(cache.count)
                cache.objects[o]=name
            end
            return name
        end
    end
    local phase,started,frames='warmup',clock(1),0
    local pending,completed
    local thread=Pipe.doThread
    Pipe.doThread=function(self,...)
        local result=thread(self,...)
        if pending then
            pending.total_wall_ms=clock(1)-pending.start_wall
            pending.total_main_cpu_ms=clock(3)-pending.start_cpu
            completed=true
        end
        return result
    end
    local display=Game.display
    Game.display=function(self,...)
        local result=display(self,...)
        frames=frames+1
        if phase=='warmup' and frames>=30 and clock(1)-started>=2000 then
            phase='queued'
            self:onTickEnd(function()
                assert(game.paused and #savefile_pipe.pipe==0 and not savefile_pipe.saving)
                local before=state()
                if cfg.reload then
                    assert(not cfg.compact)
                    local loader=debug.getinfo(Savefile.loadReal,'S')
                    assert(loader.source=='@/engine/Savefile.lua','reload must use original loadReal')
                    emit({kind='reload',state=before,runtime=jit.version,original_loadReal=true})
                    phase='done';core.game.exit_engine();return
                end
                pending={before=before,compact=cfg.compact and true or false,start_wall=clock(1),start_cpu=clock(3)}
                local cpu=clock(3)
                game:saveGame()
                pending.sync_cpu_ms=clock(3)-cpu
                pending.sync_wall_ms=clock(1)-pending.start_wall
                phase='saving'
            end,'save_size_probe')
        elseif phase=='saving' then
            local pipe=savefile_pipe
            if #pipe.pipe>0 and not pipe.saving then core.game.requestNextTick() end
            if completed and #pipe.pipe==0 and not pipe.saving and (not pipe.waiton or not next(pipe.waiton)) then
                phase='done'
                pending.kind='complete';pending.runtime=jit.version;pending.after=state()
                pending.start_wall=nil;pending.start_cpu=nil
                emit(pending)
                core.game.exit_engine()
            end
        end
        return result
    end
end
return M
