-- Local, opt-in diagnosis against disposable copies of the Yron save.
-- Timers preserve returns and coroutine yields. No debug hooks/JIT changes.
local M = {}
function M.start()
 local cfg = config.settings.faster_tome or {}
 if not cfg.stutter then return end
 require('engine.FasterProfile').stop()
 local ffi = require('ffi')
 ffi.cdef[[struct yron_timespec { long tv_sec; long tv_nsec; }; int clock_gettime(int, struct yron_timespec *);]]
 local ts = ffi.new('struct yron_timespec[1]')
 local function clock(id) ffi.C.clock_gettime(id, ts); return tonumber(ts[0].tv_sec)*1000 + tonumber(ts[0].tv_nsec)/1e6 end
 local function now() return clock(1) end
 local function cpu() return clock(3) end -- CLOCK_THREAD_CPUTIME_ID, main Lua thread only.
 local function encode(v)
  local t=type(v)
  if t=='nil' then return 'null' elseif t=='boolean' or t=='number' then return tostring(v)
  elseif t=='string' then return '"'..v:gsub('[%z\1-\31\\"]', function(c) return ('\\u%04x'):format(c:byte()) end)..'"'
  else local a={}; if #v>0 then for i=1,#v do a[#a+1]=encode(v[i]) end; return '['..table.concat(a,',')..']'
   else for k,x in pairs(v) do a[#a+1]=encode(tostring(k))..':'..encode(x) end; return '{'..table.concat(a,',')..'}' end end
 end
 local function emit(v) print('[Stutter] '..encode(v)) end
 local function pack(...) return {n=select('#',...), ...} end
 local phase='load'
 local records, frames, actions, slow = {}, {}, {}, {}
 local last_frame, phase_wall, phase_cpu, initial_turn, heap_start
 local pending, queued, action_count, save_requested = nil, false, 0, false
 local origin, adjacent, phase_seq = nil, nil, 0
 local active=true
 local save_state
 local function stateText(state)
  local keys, values = {}, {}
  for k in pairs(state.sections) do keys[#keys+1]=k end
  table.sort(keys)
  for _, k in ipairs(keys) do values[#values+1]=encode(k)..":"..encode(state.sections[k]) end
  return "{"..table.concat(values,",").."}"
 end
 local function cacheStats()
  local out={}
  for _,name in ipairs{'FasterHotkeys','FasterEffectMask'} do
   local m=package.loaded['engine.'..name]; if m and m.stats then out[name]=m.stats() end
  end
  return out
 end
 if cfg.effect_guard_probe then require('engine.FasterEffectMaskGuardProbe').start() end
 local Screenshot = cfg.screenshot_profile and require('engine.FasterScreenshotProfile')
 if Screenshot then Screenshot.start({screenshots=cfg.screenshot_attribution==true, save_swaps=false}) end
 local ScreenshotFast = cfg.screenshot_diagnostics and require('engine.FasterScreenshot')
 local SnapshotRefresh = cfg.snapshot_refresh_diagnostics and require('engine.FasterSnapshotRefresh')
 if SnapshotRefresh then SnapshotRefresh.enableDiagnostics(true) end
 local SaveCallbacks = cfg.save_callback_diagnostics and require('engine.FasterSaveFollowup')
 if SaveCallbacks then SaveCallbacks.enableDiagnostics(true) end
 local Render = cfg.render_profile and require('engine.FasterRenderProfile')
 local bindings={}
 local function bind(target,key,label,essential)
  if not target or type(target[key])~='function' or (cfg.detail==false and not essential) then return end
  -- Preserve the production offline export guard while measuring the other
  -- save costs. An unknown dumpToJSON wrapper intentionally disables it.
  if cfg.export_guard_preserving and key=='dumpToJSON' then return end
  bindings[target]=bindings[target] or {}; if bindings[target][key] then return end; bindings[target][key]=true
  local f=target[key]; local info=debug.getinfo(f,'S')
  emit{kind='binding',label=label,source=info.source,line=info.linedefined}
  target[key]=function(...)
   if not active or (label=='GC.full' and select(1,...)~='collect') then return f(...) end
   local bucket=records; local rec=bucket[label]
   if not rec then rec={calls=0,wall_ms=0,cpu_ms=0,max_ms=0}; bucket[label]=rec end
   local w,c=now(),cpu(); local ret=pack(f(...)); local dt,dc=now()-w,cpu()-c
   rec.calls=rec.calls+1; rec.wall_ms=rec.wall_ms+dt; rec.cpu_ms=rec.cpu_ms+dc; rec.max_ms=math.max(rec.max_ms,dt)
   if key=='cloneForSave' then rec.clone_objects=ret[2] end
   if dt>=20 then slow[#slow+1]={label=label,at_ms=w-phase_wall,wall_ms=dt,cpu_ms=dc,turn=game.turn} end
   return unpack(ret,1,ret.n)
  end
 end
 local Game=require('mod.class.Game')
 local onDialog=Game.onRegisterDialog
 Game.onRegisterDialog=function(self,d,...)
  emit{kind='dialog',phase=phase,class=d.__CLASSNAME,title=d.title,trace=debug.traceback('',2)}
  return onDialog(self,d,...)
 end
 local function methods(name,keys,essential)
  local t=package.loaded[name]; for _,key in ipairs(keys) do bind(t,key,name..'.'..key,essential) end
 end
 phase_wall=now()
 methods('mod.class.Game',{'tick','display','saveGame'},true)
 methods('mod.class.Game',{'takeScreenshot'},cfg.screenshot_measure)
 methods('mod.class.Game',{'cloneForSave','takeScreenshot','registerHighscore','displayMap','targetOnTick','onTurn','tickLevel','onTickEndExecute','targetDisplayTooltip'})
 methods('engine.Savefile',{'saveGame','saveWorld','saveObject','checkValidity','close','saveScreenshot'})
 methods('engine.SavefilePipe',{'push','forceWait'})
 methods('mod.class.World',{'cloneForSave','saveWorld'})
 for _,name in ipairs{'mod.class.Player','mod.class.NPC','mod.class.Actor'} do
  methods(name,{'act','actBase','move','waitTurn','doFOV','computeFOV','doAI','fireTalentCheck','attackTarget','attackTargetWith','useTalent','forceUseTalent','project','regenLife','saveUUID','dumpToJSON','stripForExport','cloneFull','onTakeHit','getTalentFullDescription'})
 end
 methods('mod.class.Object',{'act','getDesc','getTextualDesc','getUseDesc'})
 methods('engine.Map',{'display','displayEffects','displayParticles','updateMap','processEffects'})
 methods('engine.Particles',{'loaded'})
 methods('engine.Shader',{'loaded','createProgram'})
 for name,t in pairs(package.loaded) do
  if type(name)=='string' and type(t)=='table' and name:find('Party$') then
   for _,key in ipairs{'cloneFull','stripForExport','setPlayer'} do bind(t,key,name..'.'..key) end
  elseif type(name)=='string' and name:find('mod.class.uiset.') and type(t)=='table' then
   for _,key in ipairs{'display','displayResources','displayBuffs','displayParty','displayPlayer','displayMinimap','displayGameLog','displayHotkeys'} do bind(t,key,name..'.'..key) end
  end
 end
 methods('engine.HotkeysIconsDisplay',{'display'},cfg.render_measure)
 methods('engine.Map',{'displayEffects'},cfg.render_measure)
 if Render then Render.start() end
 bind(_G,'collectgarbage','GC.full')
 local function begin(name)
  phase=name; records={}; frames={}; actions={}; slow={}; last_frame=nil; action_count=0
  if phase=='save' then save_requested=false end
  if phase~='warmup' and (cfg.expect_save_state or cfg.capture_reload_state) then
   local current=require('engine.FasterSaveState').capture(game)
   local f=assert(fs.open('faster-save-state.json','r'))
   local expected=f:read(16777216); f:close()
   local equal=expected==stateText(current)
   emit{kind=cfg.capture_reload_state and 'reload_state_capture' or 'reload_state',
    raw_uid_equal=equal,actors=current.actors,items=current.items,
    comparison=cfg.capture_reload_state and 'Compare privately exported states offline with explicit Entity.loaded UID remapping' or nil}
   local observed=assert(fs.open('faster-reload-state.json','w'))
   observed:write(stateText(current)); observed:close()
   if not equal and not cfg.capture_reload_state then
    emit{kind='diagnostic_failed',phase=phase,error='selected saved state changed across reload'}
    active=false;phase='done';core.game.exit_engine();return
   end
   cfg.expect_save_state=false
   cfg.capture_reload_state=false
  end
  if phase=='save' and cfg.validate_save_state then save_state=require('engine.FasterSaveState').capture(game) end
  if phase=='save' and cfg.export_save_state then
   local f=assert(fs.open('faster-save-state.json','w'))
   f:write(stateText(assert(save_state))); f:close()
  end
  if Render then Render.reset() end
  if SaveCallbacks then SaveCallbacks.enableDiagnostics(true) end
  phase_wall,phase_cpu=now(),cpu(); last_frame=phase_wall; initial_turn=game.turn; heap_start=collectgarbage('count')
  if Screenshot then Screenshot.reset(); if phase=='save' then Screenshot.beginSwapScope('save_phase') end end
  emit{kind='phase_start',phase=phase,wall_ms=phase_wall,turn=game.turn,heap_kib=heap_start}
 end
 local function finish(reason)
  if Screenshot and phase=='save' then Screenshot.endSwapScope() end
  active=false
  emit{kind='phase_end',phase=phase,reason=reason,wall_ms=now()-phase_wall,cpu_ms=cpu()-phase_cpu,
   turn_delta=game.turn-initial_turn,heap_start_kib=heap_start,heap_end_kib=collectgarbage('count'),
   native_screenshot=Screenshot and Screenshot.snapshot() or nil,
   screenshot_stats=ScreenshotFast and ScreenshotFast.stats() or nil,
   snapshot_refresh_stats=SnapshotRefresh and SnapshotRefresh.getDiagnostics() or nil,
   save_callback_stats=SaveCallbacks and SaveCallbacks.getDiagnostics() or nil,
   cache_stats=cfg.render_measure and cacheStats() or nil, native_render=Render and Render.snapshot() or nil, records=records,frames_ms=frames,actions=actions,slow=slow,life=game.player.life,x=game.player.x,y=game.player.y}
  if phase=='save' and save_state then
   assert(require('engine.FasterSaveState').check(save_state,game),'live business state changed during save')
   save_state=nil
  end
  active=true
 end
 local function nextPhase()
  local phases=cfg.phases or (cfg.save_only and {'save'} or {'idle','wait','move','combat','save'})
  phase_seq=phase_seq+1
  if not phases[phase_seq] then
   active=false; emit{kind='complete'}; print('[YronProfile] SESSION_COMPLETE'); core.game.exit_engine(); phase='done'; return
  end
  begin(phases[phase_seq])
 end
 local Map=require('engine.Map')
 local function diagnostic(name)
  local ok,err=pcall(function() return require(name).run(game) end)
  if not ok then
   emit{kind='diagnostic_failed',phase=phase,error=tostring(err)}
   active=false;phase='done';core.game.exit_engine();return
  end
  if type(err)=='table' then emit{kind='diagnostic_result',phase=phase,result=err} end
  finish();nextPhase()
 end
 local function walkable(x,y)
  return game.level.map:isBound(x,y) and not game.level.map:checkEntity(x,y,Map.TERRAIN,'block_move',game.player)
 end
 local function chooseCombatStep()
  local map=game.level.map; local p=game.player
  local enemies={}
  for _,e in pairs(game.level.entities) do
   if e.__is_actor and not e.dead and e~=p and e.x and p:reactionToward(e)<0 then enemies[e.x..','..e.y]=e end
  end
  if not next(enemies) then return nil,'no_hostile_on_level' end
  -- Breadth first route across ordinary walkable cells to a real saved hostile.
  local q,head={{x=p.x,y=p.y}},1
  local visited={[p.x..','..p.y]=true}
  while head<=#q do
   local n=q[head]; head=head+1
   for _,d in ipairs{{0,-1},{-1,0},{1,0},{0,1},{-1,-1},{1,-1},{-1,1},{1,1}} do
    local x,y=n.x+d[1],n.y+d[2]; local key=x..','..y
    local terrain=map:isBound(x,y) and map(x,y,Map.TERRAIN)
    local door=terrain and terrain.door_opened and not terrain.door_player_stop
    if not visited[key] and (walkable(x,y) or door) then
     visited[key]=true
     local step=n.step or {x=x,y=y}
     if enemies[key] then return step,nil,enemies[key].name end
     local occupant=map(x,y,Map.ACTOR)
     if not occupant or occupant==p then q[#q+1]={x=x,y=y,step=step} end
    end
   end
  end
  return nil,'no_route_to_hostile'
 end
 local function queueAction()
  if queued or pending then return end
  local p=game.player; local target,reason,enemy
  if phase=='move' then target=(action_count%2==0) and adjacent or origin
  elseif phase=='combat' then target,reason,enemy=chooseCombatStep(); if not target then finish(reason); nextPhase(); return end end
  if phase=='move' and not target then finish('no_adjacent_empty_tile'); nextPhase(); return end
  queued=true
  game:onTickEnd(function()
   queued=false
   pending={index=action_count+1,start_wall=now(),start_cpu=cpu(),turn=game.turn,x=p.x,y=p.y,life=p.life,enemy=enemy}
   if target then
    local terrain=game.level.map(target.x,target.y,Map.TERRAIN)
    -- Select the ordinary Open response only for this specific saved vault door.
    local Dialog=require('engine.ui.Dialog'); local popup=Dialog.yesnoPopup
    if phase=='combat' and terrain and terrain.door_player_check then
     Dialog.yesnoPopup=function(self,title,text,callback,...)
      if text==terrain.door_player_check then emit{kind='open_vault',x=target.x,y=target.y}; callback(true)
      else return popup(self,title,text,callback,...) end
     end
    end
    p:move(target.x,target.y,false)
    Dialog.yesnoPopup=popup
   else p:waitTurn() end
   pending.command_ms=now()-pending.start_wall
   pending.command_cpu_ms=cpu()-pending.start_cpu
   core.game.requestNextTick()
  end,'yron_stutter_action')
 end
 local display=Game.display
 Game.display=function(self,...)
  local ret=pack(display(self,...))
  if self~=game or not self.inited or not self.player or not self.level or phase=='done' or core.display.redrawingForSavefileScreenshot() then return unpack(ret,1,ret.n) end
  local w=now()
  if phase=='load' then
   local mt=getmetatable(self.level.map._map)
   if type(mt)=='table' then
    bind(type(mt.__index)=='table' and mt.__index or mt,'toScreen','native.Map.toScreen')
   end
   local entities={}
   for _,e in pairs(self.level.entities) do entities[#entities+1]={name=e.name,class=e.__CLASSNAME,x=e.x,y=e.y,dead=e.dead,life=e.life,hostile=e.__is_actor and self.player:reactionToward(e)<0} end
   emit{kind='context',player=self.player.name,class=self.player.__CLASSNAME,party=self.party.__CLASSNAME,entities=entities,
    level=self.level.level,zone=self.zone.short_name,x=self.player.x,y=self.player.y,
    upload_charsheet=config.settings.tome.upload_charsheet,background_saves=config.settings.background_saves,detail=cfg.detail~=false,
    charsheet_off=cfg.charsheet_off or false,jit=jit.version}
   origin={x=self.player.x,y=self.player.y}
   for _,d in ipairs{{0,-1},{-1,0},{1,0},{0,1}} do
    local x,y=origin.x+d[1],origin.y+d[2]
    if walkable(x,y) and not self.level.map(x,y,Map.ACTOR) and not self.level.map(x,y,Map.TRAP) then adjacent={x=x,y=y}; break end
   end
   if cfg.charsheet_off then config.settings.tome.upload_charsheet=false end
   begin('warmup')
  else
   if last_frame then frames[#frames+1]=w-last_frame end; last_frame=w
   if phase=='warmup' then if w-phase_wall>2000 then finish(); nextPhase() end
   elseif phase=='idle' then if w-phase_wall>5000 then finish(); nextPhase() end
   elseif phase=='clone_bench' then
    diagnostic('engine.FasterCloneBench')
   elseif phase=='chardump_check' then
    diagnostic('engine.FasterChardumpCheck')
   elseif phase=='snapshot_audit' then
    diagnostic('engine.FasterSnapshotAudit')
   elseif phase=='screenshot_check' then diagnostic('engine.FasterScreenshotCheck')
   elseif phase=='snapshot_refresh_check' then diagnostic('engine.FasterSnapshotRefreshCheck')
  elseif phase=='hotkeys_display_check' then
    diagnostic('engine.FasterHotkeysDisplayCheck')
   elseif phase=='effect_mask_check' then
    diagnostic('engine.FasterEffectMaskCheck')
   elseif phase=='hotkeys_check' then
    diagnostic('engine.FasterHotkeysCheck')
   elseif phase=='gzip_check' then
    diagnostic('engine.FasterGzipCheck')
   elseif phase=='gzip_bench' then
    diagnostic('engine.FasterGzipBench')
   elseif phase=='party_export_check' then
    diagnostic('engine.FasterPartyExportCheck')
   elseif phase=='wait' or phase=='move' or phase=='combat' then
    for i=#self.dialogs,1,-1 do
     local d=self.dialogs[i]
     if d.__CLASSNAME=='engine.dialogs.Achievement' or d.__CLASSNAME=='mod.dialogs.UnlockDialog' then
      emit{kind='dismiss_achievement',phase=phase,title=d.title}
      d.key:triggerVirtual('EXIT')
     end
    end
    if pending and self.paused and self.player:enoughEnergy() then
     local a=pending; pending=nil; action_count=action_count+1
     a.response_ms=w-a.start_wall; a.cpu_ms=cpu()-a.start_cpu; a.turn_delta=self.turn-a.turn
     a.dx=self.player.x-a.x; a.dy=self.player.y-a.y; a.life_delta=self.player.life-a.life
     a.start_wall=nil; a.start_cpu=nil; actions[#actions+1]=a
    end
    if self.player.dead then
     finish('player_died'); active=false; emit{kind='complete',outcome='player_died'}; print('[YronProfile] SESSION_COMPLETE'); phase='done'; core.game.exit_engine()
    elseif phase=='combat' and self.player.life<400 then
     finish('low_life_stop'); nextPhase()
    elseif #self.dialogs>0 or w-phase_wall>60000 then
     emit{kind='abort',phase=phase,dead=self.player.dead,dialogs=#self.dialogs}; finish('blocked_or_timeout'); active=false; phase='done'; core.game.exit_engine()
    elseif action_count>=(cfg.actions or 60) then finish(); nextPhase()
    elseif self.paused and self.player:enoughEnergy() then queueAction() end
   elseif phase=='save' then
    if not queued and not save_requested then
     queued=true; self:onTickEnd(function()
      game:saveGame(); save_requested=true; queued=false
      if cfg.force_save_wait then savefile_pipe:forceWait() end
     end,'yron_stutter_save')
    end
    local pipe=savefile_pipe
    if save_requested and #pipe.pipe>0 and not pipe.saving then core.game.requestNextTick() end
    if save_requested and #pipe.pipe==0 and not pipe.saving and (not pipe.waiton or not next(pipe.waiton)) then finish(); nextPhase() end
   end
  end
  return unpack(ret,1,ret.n)
 end
end
return M
