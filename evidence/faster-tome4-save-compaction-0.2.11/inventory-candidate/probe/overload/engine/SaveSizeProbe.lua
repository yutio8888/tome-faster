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
local function inventoryFixture(candidate)
    local Object = require 'mod.class.Object'
    local player, count = game.player, 24
    local inventory = player:getInven('INVEN')
    assert(#inventory+count<=inventory.max, 'inventory fixture needs 24 empty slots')
    for i=1,count do
        local object=Object.new{name='save acceptance item '..i, type='gem', subtype='white',
            display='*', color={255,255,255}, image='object/white_gem.png',
            encumber=0, identified=true, cost=0, desc='Disposable save acceptance object.', faster_fixture=i}
        assert(player:addObject(inventory,object,true))
        assert(object.in_inven.actor==player)
        assert(object.in_inven.id==(candidate and inventory.id or inventory))
    end
    emit({kind='inventory_fixture',count=count,canonical=candidate,inventory_id=inventory.id})
end
local function state()
    local p, actors, objects = game.player, {}, {}
    for _,a in ipairs(game.level.e_array) do
        if a.__is_actor then actors[#actors+1]={uid=a.uid,x=a.x,y=a.y,life=a.life,dead=a.dead or false} end
    end
    table.sort(actors,function(a,b)return a.uid<b.uid end)
    for inventory,list in pairs(p.inven) do for slot,o in ipairs(list) do
        objects[#objects+1]={uid=o.uid,inventory=inventory,slot=slot,stacked=o.stacked and #o.stacked or 0,
            fixture=o.faster_fixture or false,owner_uid=o.in_inven and o.in_inven.actor and o.in_inven.actor.uid or false}
    end end
    table.sort(objects,function(a,b)return a.inventory==b.inventory and a.slot<b.slot or a.inventory<b.inventory end)
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
    local CPU = require 'engine.SaveCompactionCPU'
    local info=debug.getinfo(Savefile.getFileName,'S')
    if cfg.bare then
        assert(info.source=='@/engine/Savefile.lua' and info.linedefined==130 and info.lastlinedefined==136)
        for name in pairs(package.loaded) do
            assert(not name:match('^engine%.Faster') and name~='engine.FBOGCGuard', 'Faster addon loaded in bare run: '..name)
        end
    else
        assert(info.source=='@/engine/FasterSaveNames.lua','production compact namer required')
    end
    local inventory_source=debug.getinfo(require('mod.class.Player').onAddObject,'S').source
    local fearscape_source=debug.getinfo(require('engine.interface.ActorTalents').talents_def.T_DEMON_PLANE.deactivate,'S').source
    if cfg.candidate then
        assert(inventory_source=='@/engine/FasterInventory.lua','inventory optimization did not install')
        assert(fearscape_source=='@/engine/FasterFearscape.lua','Fearscape optimization did not install')
    end
    emit({kind='setup',inventory_source=inventory_source,fearscape_source=fearscape_source,compact=cfg.compact and true or false,candidate=cfg.candidate and true or false,
        bare=cfg.bare and true or false,namer_source=info.source,
        namer_first=info.linedefined,namer_last=info.lastlinedefined,production=true,
        fbo_gc_guard=ft.fbo_gc_guard~=false,hit_warning_interval_ms=ft.hit_warning_interval_ms or 500})
    local phase,started,frames='warmup',clock(1),0
    local pending,completed
    local thread=Pipe.doThread
    Pipe.doThread=function(self,...)
        local result=thread(self,...)
        if pending then
            assert(#self.pipe==0 and not self.saving and not next(self.on_done) and (not self.waiton or not next(self.waiton)))
            local user,sys=CPU.sample(0)
            pending.total_process_user_ms=user-pending.start_user
            pending.total_process_system_ms=sys-pending.start_system
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
                if cfg.inventory and not cfg.reload then inventoryFixture(cfg.candidate) end
                local before=state()
                if cfg.reload then
                    local loader=debug.getinfo(Savefile.loadReal,'S')
                    assert(loader.source=='@/engine/Savefile.lua','reload must use original loadReal')
                    emit({kind='reload',state=before,runtime=jit.version,original_loadReal=true,no_faster=cfg.bare and true or false})
                    phase='done';core.game.exit_engine();return
                end
                pending={before=before,compact=cfg.compact and true or false,candidate=cfg.candidate and true or false}
                pending.start_user,pending.start_system=CPU.sample(0)
                pending.start_wall,pending.start_cpu=clock(1),clock(3)
                local threaduser,threadsys=CPU.sample(1)
                local cpu=clock(3)
                game:saveGame()
                pending.sync_cpu_ms=clock(3)-cpu
                local user,sys=CPU.sample(1)
                pending.sync_thread_user_ms=user-threaduser
                pending.sync_thread_system_ms=sys-threadsys
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
                pending.start_user=nil;pending.start_system=nil
                emit(pending)
                core.game.exit_engine()
            end
        end
        return result
    end
end
return M
