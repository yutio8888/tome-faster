-- GPL-3.0-or-later. Diagnostic only, in disposable save copies.
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
    for inventory,list in pairs(p.inven) do for slot,o in ipairs(list) do
        local owner=o.in_inven
        local owner_id=owner and owner.id
        if type(owner_id)=='table' then owner_id=rawget(owner_id,'id') end
        objects[#objects+1]={uid=o.uid,inventory=inventory,slot=slot,stacked=o.stacked and #o.stacked or 0,
            fixture=o.faster_fixture or false,owner_uid=owner and owner.actor and owner.actor.uid or false,
            owner_inventory=type(owner_id)=='number' and owner_id or false}
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
    local Savefile,Pipe,Game=require 'engine.Savefile',require 'engine.SavefilePipe',require 'mod.class.Game'
    local CPU=require 'engine.SaveCompactionCPU'
    local clock=CPU.clock
    local function sample()
        local wall=clock(1)
        local user,sys=CPU.sample(0)
        local thread_user,thread_sys=CPU.sample(1)
        return {wall_ms=wall,process_user_ms=user,process_system_ms=sys,
            thread_user_ms=thread_user,thread_system_ms=thread_sys,thread_cpu_ms=clock(3)}
    end
    local function interval(a,b)
        local result={}
        for key,value in pairs(b) do result[key]=value-a[key];assert(result[key]>=0,'negative CPU/time interval: '..key) end
        return result
    end
    local options={compact_inventory=ft.compact_inventory==nil or ft.compact_inventory==true,fearscape_cleanup=ft.fearscape_cleanup==nil or ft.fearscape_cleanup==true,
        compact_save_names_base62=ft.compact_save_names_base62==true}
    for key,value in pairs(cfg.expected_options) do assert(options[key]==value,'unexpected production option: '..key) end
    local info=debug.getinfo(Savefile.getFileName,'S')
    local inventory_source=debug.getinfo(require('mod.class.Player').onAddObject,'S').source
    local talent=require('engine.interface.ActorTalents').talents_def.T_DEMON_PLANE
    local fearscape_source=debug.getinfo(talent.deactivate,'S').source
    if cfg.bare then
        assert(info.source=='@/engine/Savefile.lua' and info.linedefined==130 and info.lastlinedefined==136)
        for name in pairs(package.loaded) do
            assert(not name:match('^engine%.Faster') and name~='engine.FBOGCGuard','Faster loaded in stock run: '..name)
        end
    else assert(info.source=='@/engine/FasterSaveNames.lua','production compact namer required') end
    if options.compact_inventory then
        assert(inventory_source=='@/engine/FasterInventory.lua','inventory option did not install')
    else
        assert(not package.loaded['engine.FasterInventory'],'disabled inventory module loaded')
        assert(inventory_source=='@/mod/class/Player.lua','disabled inventory method changed')
    end
    if options.fearscape_cleanup then
        assert(fearscape_source=='@/engine/FasterFearscape.lua','Fearscape option did not install')
    else
        assert(not package.loaded['engine.FasterFearscape'],'disabled Fearscape module loaded')
        assert(fearscape_source=='@/data/talents/corruptions/shadowflame.lua','disabled Fearscape method changed')
    end
    local name62
    if not cfg.bare then
        local names=setmetatable({tables={}}, {__index=Savefile})
        for i=1,62 do name62=names:getFileName({}) end
        assert(name62==(options.compact_save_names_base62 and '10' or '62'),'wrong save-name encoding')
    end
    emit({kind='setup',case=cfg.case,variant=cfg.variant,options=options,bare=cfg.bare and true or false,
        namer_source=info.source,sample_name_62=name62,inventory_source=inventory_source,fearscape_source=fearscape_source,
        fbo_gc_guard_setting=ft.fbo_gc_guard~=false,fbo_guard_module_loaded=package.loaded['engine.FBOGCGuard']~=nil,
        hit_warning_interval_ms=ft.hit_warning_interval_ms or 500,production=true})
    -- Observed empty brackets, not subtracted and not an accuracy/error bound.
    local empty_brackets={}
    for i=1,64 do local a=sample();empty_brackets[i]=interval(a,sample()) end
    local phase,started,frames='warmup',clock(1),0
    local pending,scenario_step,scenario_report,scenario_poll_queued
    local segments={count=0,max_wall_ms=0,max_thread_cpu_ms=0}
    if cfg.latency then
        local resume=coroutine.resume
        coroutine.resume=function(co,...)
            if not pending or pending.complete or co~=savefile_pipe.co then return resume(co,...) end
            local wall,cpu=clock(1),clock(3)
            local ok,value=resume(co,...)
            segments.count=segments.count+1
            segments.max_wall_ms=math.max(segments.max_wall_ms,clock(1)-wall)
            segments.max_thread_cpu_ms=math.max(segments.max_thread_cpu_ms,clock(3)-cpu)
            return ok,value
        end
    end
    local events,event_order={},{}
    local function mark(name)
        assert(not events[name],'duplicate event phase '..name)
        events[name]=sample();event_order[#event_order+1]=name
    end
    local function inventoryFixture()
        local Object=require 'mod.class.Object'
        local player,count=game.player,24
        local inventory=player:getInven('INVEN')
        assert(#inventory+count<=inventory.max,'inventory fixture needs 24 empty slots')
        local objects,returns={},{}
        for i=1,count do
            objects[i]=Object.new{name='save acceptance item '..i,type='gem',subtype='white',display='*',
                color={255,255,255},image='object/white_gem.png',encumber=0,identified=true,cost=0,
                desc='Disposable save acceptance object.',faster_fixture=i}
            returns[i]=false
        end
        mark('inventory_add_begin')
        for i=1,count do returns[i]=player:addObject(inventory,objects[i],true) end
        mark('inventory_add_return')
        for i=1,count do
            assert(returns[i])
            local owner=objects[i].in_inven
            assert(owner.actor==player and player:getInven(owner.id)==inventory)
            assert(owner.id==(options.compact_inventory and inventory.id or inventory))
        end
        emit({kind='inventory_fixture',count=count,canonical=options.compact_inventory,inventory_id=inventory.id})
    end
    local function drained(pipe)
        return #pipe.pipe==0 and not pipe.saving and not next(pipe.on_done)
            and (not pipe.waiton or not next(pipe.waiton))
    end
    local function finishSave()
        if not pending or pending.complete or not pending.sync_returned or not pending.thread_returned or not drained(savefile_pipe) then return end
        pending.finish=sample()
        pending.memory_after=CPU.memory()
        assert(pending.finish.wall_ms>=pending.sync_finish.wall_ms,'save finished before synchronous return')
        pending.complete=true
    end
    local thread=Pipe.doThread
    Pipe.doThread=function(self,...)
        local result=thread(self,...)
        if pending and drained(self) then pending.thread_returned=true;finishSave() end
        return result
    end
    local function metrics()
        local out={}
        local function add(prefix,a,b)
            for key,value in pairs(interval(a,b)) do out[prefix..'_'..key]=value end
        end
        add('save',pending.start,pending.finish)
        add('save_sync',pending.start,pending.sync_finish)
        if cfg.case=='inventory-add' then
            assert(#event_order==2 and event_order[1]=='inventory_add_begin' and event_order[2]=='inventory_add_return')
            add('inventory_add',events.inventory_add_begin,events.inventory_add_return)
        elseif cfg.case=='fearscape-exit' then
            local expected={'entry_call_begin','entry_call_return','entry_complete','exit_call_begin','exit_call_return','exit_complete'}
            assert(#event_order==#expected and scenario_report and scenario_report.ok)
            for i,name in ipairs(expected) do assert(event_order[i]==name,'unexpected Fearscape phase order') end
            add('entry_sync',events.entry_call_begin,events.entry_call_return)
            add('entry_observed',events.entry_call_begin,events.entry_complete)
            add('exit_sync',events.exit_call_begin,events.exit_call_return)
            add('exit_observed',events.exit_call_begin,events.exit_complete)
        else assert(#event_order==0,'an idle/save-only case executed an event') end
        local event=cfg.case=='inventory-add' and 'inventory_add' or cfg.case=='fearscape-exit' and 'exit_observed'
        if event then
            -- Two disjoint measured intervals, not continuous elapsed time.
            for _,key in ipairs{'process_user_ms','process_system_ms','thread_user_ms','thread_system_ms','thread_cpu_ms','wall_ms'} do
                out['event_and_save_'..key]=out[event..'_'..key]+out['save_'..key]
            end
        end
        return out
    end
    local display=Game.display
    Game.display=function(self,...)
        local result=display(self,...)
        frames=frames+1
        if phase=='scenario' and not scenario_poll_queued then
            scenario_poll_queued=true
            self:onTickEnd(function()
                local done,report=scenario_step()
                if done then
                    scenario_step=nil
                    if not report.ok then emit({kind='error',report=report});phase='failed';core.game.exit_engine();return end
                    scenario_report=report;emit({kind='fearscape_scenario',report=report});phase='ready'
                end
                scenario_poll_queued=false
            end,'isolated_fearscape_step')
            core.game.requestNextTick()
        end
        if phase=='warmup' and frames>=30 and clock(1)-started>=2000 then
            if cfg.case=='fearscape-exit' and not cfg.reload then
                scenario_step=require('engine.FearscapeScenario').start{
                    mode='casterdead',seed=6140914,expect_cleanup=options.fearscape_cleanup,on_phase=mark}
                phase='scenario'
            else phase='ready' end
        end
        if phase=='ready' then
            phase='queued'
            self:onTickEnd(function()
                assert(game.paused and drained(savefile_pipe),'save starts with pending work')
                if cfg.case=='inventory-add' and not cfg.reload then inventoryFixture() end
                local before=state()
                if cfg.reload then
                    if cfg.read_blocks then
                        assert(debug.getinfo(Savefile.loadReal,'S').source=='@/engine/BlockPrototype.lua','prototype reader required')
                    else
                        assert(not package.loaded['engine.BlockPrototype'],'unexpected prototype in materialized read')
                    end
                    if cfg.case=='fearscape-exit' then
                        local restored=require('engine.FearscapeScenario').inspect(assert(cfg.expected))
                        assert(restored.token_count==1 and restored.target_death_wrapper_absent and restored.returned_to_source_description)
                        assert(restored.trapper_absent==cfg.expected.expect_cleanup)
                        emit({kind='fearscape_reloaded',report=restored})
                    end
                    local prototype=package.loaded['engine.BlockPrototype']
                    emit({kind='reload',state=before,runtime=jit.version,
                        block_reader=cfg.read_blocks and true or false,
                        read_stats=prototype and prototype.read_stats or {},
                        load_metrics=assert(require('engine.BlockLoadMetrics').result)})
                    phase='done';core.game.exit_engine();return
                end
                pending={before=before,memory_before=CPU.memory()}
                pending.start=sample()
                game:saveGame()
                pending.sync_finish=sample();pending.sync_returned=true
                finishSave();phase='saving'
            end,'isolated_save_start')
        elseif phase=='saving' then
            if #savefile_pipe.pipe>0 and not savefile_pipe.saving then core.game.requestNextTick() end
            if pending.complete then
                phase='done'
                emit({kind='complete',case=cfg.case,variant=cfg.variant,options=options,runtime=jit.version,
                    before=pending.before,after=state(),metrics=metrics(),empty_brackets=empty_brackets,
                    memory_before=pending.memory_before,memory_after=pending.memory_after,
                    latency_segments=cfg.latency and segments or nil,
                    attribution=require('engine.BlockTiming').stats,
                    event_samples=events,event_order=event_order,save_samples={start=pending.start,sync_return=pending.sync_finish,finish=pending.finish},
                    save_endpoint_after_sync=true,save_endpoint_drained=drained(savefile_pipe),
                    block_writes=package.loaded['engine.BlockPrototype'] and package.loaded['engine.BlockPrototype'].writes or {}})
                core.game.exit_engine()
            end
        end
        return result
    end
end
return M
