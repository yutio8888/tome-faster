-- GPL-3.0-or-later. Profile hooks preserve return/yield/error/override semantics.
assert(_VERSION=='Lua 5.1')
local root=arg[1] or '.'
local checks=0
local function check(v,msg) assert(v,msg);checks=checks+1 end
local function pack(...) return {n=select('#',...),...} end
local function world()
    local now,cpu=0,0
    local function advance(ms)now=now+ms;cpu=cpu+ms/1000 end
    local Game={tick=function(...) advance(3);return nil,'ok',nil end,
        cloneForSave=function(self)advance(5);return {copy=true},42 end}
    local Savefile={loadReal=function(self,mode)
        if mode=='fail' then error('expected failure') end
        if mode=='yield' then coroutine.yield('pause') end
        advance(7);return nil,'loaded',nil
    end}
    local stdout={}
    local env=setmetatable({os={clock=function()return cpu end},core={game={getTime=function()return now%4294967296 end}},
        package={loaded={['mod.class.Game']=Game,['engine.Savefile']=Savefile}},
        print=function(s)stdout[#stdout+1]=s end,
        collectgarbage=function(...)advance(2);return ... end}, {__index=_G})
    env._G=env
    local P=setfenv(assert(loadfile(root..'/overload/engine/FasterProfile.lua')),env)()
    return P,Game,Savefile,env,advance,stdout
end
local p,g,s,e,advance,stdout=world()
local original=g.tick;check(g.tick==original,'no automatic installation')
p.start();local wrapped=g.tick;p.start();check(g.tick==wrapped,'idempotent start')
local r=pack(g:tick('arg',nil));check(r.n==3 and r[1]==nil and r[2]=='ok' and r[3]==nil,'return arity and nils')
local snap=p.snapshot();check(snap['mod.class.Game.tick'].wall_ms==3,'wall timer')
snap['mod.class.Game.tick'].wall_ms=999;check(p.snapshot()['mod.class.Game.tick'].wall_ms==3,'snapshot detached')
local copy,n=g:cloneForSave();check(copy.copy and n==42,'clone values unchanged')
check(p.snapshot()['mod.class.Game.cloneForSave'].last_clone_objects==42,'clone counter')
e.collectgarbage('step',5);check(p.snapshot()['gc.full']==nil,'ignore non-full GC')
e.collectgarbage('collect');check(p.snapshot()['gc.full'].completed==1,'full GC measured')
local ok,err=pcall(s.loadReal,s,'fail');check(not ok and err:find('expected failure',1,true),'error propagation')
check(p.snapshot()['engine.Savefile.loadReal'].started==1 and p.snapshot()['engine.Savefile.loadReal'].completed==0,'unfinished error visible')
local co=coroutine.create(function()return s:loadReal('yield')end)
local ok,value=coroutine.resume(co);check(ok and value=='pause','yield supported')
advance(100)
local out=pack(coroutine.resume(co));check(out.n==4 and out[1] and out[2]==nil and out[3]=='loaded' and out[4]==nil,'resume and trailing nil')
check(p.snapshot()['engine.Savefile.loadReal'].wall_ms==107,'span includes suspended time explicitly')
p.report();check(#stdout>=5 and stdout[1]:find('process CPU',1,true),'report clock limitation')
p.reset();check(next(p.snapshot())==nil,'reset counters')
advance(4294967294);g:tick();check(p.snapshot()['mod.class.Game.tick'].wall_ms==3,'SDL wrap')
p.stop();check(g.tick==original,'restore original function')
local previous=g.tick;p.start();local profileWrapper=g.tick
local later=function(...)return profileWrapper(...)end;g.tick=later
p.stop();check(g.tick==later,'preserve later addon override')
p.reset();p.start();g:tick();check(p.snapshot()['mod.class.Game.tick'].completed==1,'restart does not reactivate old nested wrapper')
p.stop()
-- Attach a class that was loaded after profiling began, retaining inherited fields on stop.
local p2,g2,s2,e2=world();e2.package.loaded['mod.class.Game']=nil;p2.start()
local inherited=setmetatable({}, {__index=g2});p2.attachGame(inherited);inherited:tick()
check(p2.snapshot()['mod.class.Game.tick'].completed==1,'late Game attach')
p2.stop();check(rawget(inherited,'tick')==nil and inherited.tick==g2.tick,'restore inherited method lookup')
print(('PASS profile instrumentation: %d checks'):format(checks))
