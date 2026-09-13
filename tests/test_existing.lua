-- ToME - Tales of Maj'Eyal:
-- Copyright (C) 2009 - 2019 Nicolas Casalini
--
-- This program is free software: you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation, either version 3 of the License, or
-- (at your option) any later version.
--
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU General Public License for more details.
--
-- You should have received a copy of the GNU General Public License
-- along with this program.  If not, see <http://www.gnu.org/licenses/>.
--
-- Nicolas Casalini "DarkGod"
-- darkgod@te4.org

-- GPL-3.0-or-later; modified 2026-09-12: isolated actual-code regressions.
-- Read pinned upstream directly from Git; never execute game startup.
assert(_VERSION == 'Lua 5.1', 'Lua 5.1 / LuaJIT required')
local root = arg[1] or '.'
local repo = assert(arg[2], 'pass the path to a local ToME source Git clone as argument 2')
local commit = '624a67329fe2ad440c5b344785a9c73fcf22ae63'
local function quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
local function pinned(path)
    local p = assert(io.popen('git -C ' .. quote(repo) .. ' show ' .. quote(commit .. ':' .. path), 'r'))
    local s = p:read('*a'); assert(p:close()); assert(#s > 0); return s
end
local function env(t) return setmetatable(t or {}, {__index = _G}) end
local function run(path, e) return setfenv(assert(loadfile(root .. '/' .. path)), e)() end
local function chunk(s, e) return setfenv(assert(loadstring(s)), e)() end
local function section(s, first, last)
    local a = assert(s:find(first, 1, true)); local b = assert(s:find(last, a, true))
    return s:sub(a, b - 1)
end
local checks = 0
local function check(ok, label) assert(ok, label); checks = checks + 1 end
local function same(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= 'table' then return a == b end
    for k, v in pairs(a) do if not same(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end
local ring = {}
run('overload/engine/CacheList.lua', env{_M=ring, module=function() end, class={make=function() end}})
function ring.new(n) local q=setmetatable({}, {__index=ring}); q:init(n); return q end
for _, n in ipairs{1, 2, 3, 5000} do
    local q, ref = ring.new(n), {}
    check(select(2, q:peekOldest()) == nil, 'empty oldest')
    for i=1,n*2+3 do
        q:offer(i); ref[#ref+1]=i; if #ref>n then table.remove(ref,1) end
        check(same(q:enumerate(), ref), 'partial/full/wrapped enumeration ' .. n)
        check(select(2,q:peekOldest()) == ref[1] and select(2,q:peek()) == i, 'oldest/newest')
    end
    check(same(q:enumerate(1), {ref[1]}), 'limited chronological enumeration')
    q:truncate(1); check(same(q:enumerate(), {ref[#ref]}), 'retain newest')
    q:offer(999); check(select(2,q:peek()) == 999, 'offer after truncation')
    q:truncate(0); check(#q:enumerate()==0 and q:peek()==0, 'clear ring')
    q:append{1,2}; check(select(2,q:peek())==2, 'append after clear')
end
for _, n in ipairs{0,-1,1.5,math.huge} do check(not pcall(ring.new,n), 'invalid capacity') end
-- Model comparison across truncation in partially filled and wrapped states.
for _, n in ipairs{1,3,7} do
    local q, ref = ring.new(n), {}
    for i=1,100 do
        if i % 4 == 0 then
            local keep = (i / 4) % (n + 2)
            q:truncate(keep)
            while #ref > keep do table.remove(ref,1) end
        else
            q:offer(i); ref[#ref+1]=i
            if #ref > n then table.remove(ref,1) end
        end
        check(same(q:enumerate(),ref), 'truncation/offer model')
        check(select(2,q:peekOldest())==ref[1], 'oldest after truncation')
    end
end
print('PASS ring capacity, order, truncation (partial/full/wrapped)')

local pre = section(pinned('game/loader/pre-init.lua'), 'local printlog = {}', 'local rngavg =')
local function world()
    -- Isolate print/cache behavior from the FBO installer's startup message.
    -- FBO installation and its configuration are covered by test_fbo_gc.lua.
    local w = env{config={settings={faster_tome={fbo_gc_guard=false}}}, stdout={}, fail_stdout=false}
    w._G = w
    w.print = function(...)
        w.stdout[#w.stdout+1] = {n=select('#',...), ...}
        if w.fail_stdout then error('stdout failure') end
    end
    chunk(pre,w)
    return w
end
local function install(w,p,s)
    w.class = w.class or {}
    w.class.bindHook = function() end
    w.require=function(name)
        if name=='engine.Particles' then return p end
        if name=='engine.Shader' then return s end
        if name=='engine.CacheList' then return ring end
        if name=='engine.Savefile' then return {} end
        if name=='engine.FasterSave' then return {installSavefile=function() return true end} end
        if name=='engine.FasterSaveFollowup' then return {installClass=function() return true end} end
        if name=='engine.class' then return w.class end
        error(name)
    end
    run('hooks/load.lua',w)
end
local function method(e)
    return chunk('return function(self, ...) return loadfile(self.file, ...) end',e)
end
local w, reference = world(), world()
w.print('backlog'); reference.print('backlog')
local original_get = w.get_printlog
local p, s = {loaded=method(w)}, {loaded=method(w)}
install(w,p,s)
local calls=0
local object=setmetatable({}, {__tostring=function() calls=calls+1; return 'object' end})
for _, args in ipairs{{n=0},{n=5,'a',nil,3,false,object},{n=2,'tail',2}} do
    w.print(unpack(args,1,args.n)); reference.print(unpack(args,1,args.n))
end
check(calls==2,'stringified once per original print')
check(same(w.get_printlog(),reference.get_printlog()), 'original stringification and backlog')
check(same(w.stdout,reference.stdout),'original stdout arguments and order')
check(#original_get()==0,'upstream buffer drained')
local enumerate = ring.enumerate
ring.enumerate = function() error('print must not enumerate/copy the ring') end
for i=1,5010 do w.print(i) end
ring.enumerate = enumerate
local log=w.get_printlog()
check(#log==5000 and log[1][1]=='11' and log[5000][1]=='5010','full print ring')
w.truncate_printlog(2); check(#w.get_printlog()==2 and w.get_printlog()[1][1]=='5009','truncate newest logs')
w.truncate_printlog(0); check(#w.get_printlog()==0,'clear logs')
w.fail_stdout=true; check(not pcall(w.print,'error log'),'stdout error preserved')
check(w.get_printlog()[1][1]=='error log','log before stdout error preserved')
w.fail_stdout=false
-- A stdout callback sees the pending entry, and nested prints stay chronological.
w = world()
local raw = w.print
local inner = false
-- Replace stdout upvalue of the pinned function in this test only.
for i=1,10 do
    local name=debug.getupvalue(raw,i)
    if name=='oprint' then debug.setupvalue(raw,i,function()
        if not inner then
            inner=true
            check(w.get_printlog()[1][1]=='outer','log visible within stdout')
            w.print('inner')
        end
    end) end
end
install(w,{loaded=method(w)},{loaded=method(w)})
w.print('outer'); check(same(w.get_printlog(),{{'outer'},{'inner'}}),'nested print order')
print('PASS original print stdout, stringification, backlog, capacity, truncation, errors, nesting')

w=world()
local disk, revision = {}, 1
local original_env=env{config=w.config, marker='original', _M={identity=true}}
original_env.loadfile=function(path,...)
    disk[path]=(disk[path] or 0)+1
    if path=='missing' and revision==1 then return nil,'missing',nil,'detail' end
    if path=='closure' then local value=17; return function() return value end end
    return assert(loadstring('return value, function() return value end, ' .. revision)),nil,'extra',nil
end
p,s={loaded=method(original_env)},{loaded=method(original_env)}
local global_loader=w.loadfile
install(w,p,s)
check(w.loadfile==global_loader,'global loadfile unchanged')
check(getmetatable(getfenv(p.loaded)).__index==original_env and getfenv(p.loaded)._M==original_env._M,'original environment inherited')
local function pack(...) return {n=select('#',...),...} end
local first=pack(p.loaded{file='ok'}); local second=pack(p.loaded{file='ok'})
check(first.n==4 and second.n==4 and second[3]=='extra' and first[1]~=second[1] and disk.ok==1,'fresh functions and exact returns')
setfenv(first[1],{value='A'}); local a, callback=first[1]()
setfenv(second[1],{value='B'}); local b=second[1]()
check(a=='A' and b=='B' and callback()=='A','instance closure environments isolated')
local missing=pack(s.loaded{file='missing'})
check(missing.n==4 and missing[1]==nil and missing[2]=='missing' and missing[4]=='detail','failure returns')
s.loaded{file='missing'}; check(disk.missing==2,'failed loads retry')
revision=2; check(type(s.loaded{file='missing'})=='function','failure recovery')
p.loaded{file='closure'}; p.loaded{file='closure'}; check(disk.closure==2,'custom closure bypass')
for i=1,256 do p.loaded{file='file'..i} end
p.loaded{file='ok'}; check(disk.ok==2,'bounded successful FIFO eviction')
w.config.settings.cheat=true
p.loaded{file='ok'}; p.loaded{file='ok'}; check(disk.ok==4,'debug bypass')
w.config.settings.cheat=false
p.loaded{file='ok'}; check(disk.ok==5,'debug cleared stale cache')
p.loaded({file='ok'},'mode'); check(disk.ok==6,'extra loader arguments bypass')
print('PASS loader environment, fresh closures, returns, retries, eviction, debug bypass')

-- Execute the pinned loaded methods with minimal rendering/native stubs.
w=world()
w.fs={exists=function() return true end}
w.engine={Map={tile_w=32,tile_h=32}}
w.core={display={loadImage=function() return {glTexture=function() return 'texture' end} end},
    particles={newEmitter=function() return {} end},shader={}}
w.table=setmetatable({serialize=function() return '' end},{__index=table})
w.module=function() end; w.class={make=function() end}; w.require=function() end
p={}; local pe=env{_M=p}; setmetatable(pe,{__index=w})
chunk(pinned('game/engines/default/engine/Particles.lua'),pe)
s={}; local se=env{_M=s}; setmetatable(se,{__index=w})
chunk(pinned('game/engines/default/engine/Shader.lua'),se)
local actual_loads={}
w.loadfile=function(path)
    actual_loads[path]=(actual_loads[path] or 0)+1
    if path:find('/particles/',1,true) then
        return assert(loadstring('callback = function() return value end; return nil,nil,nil,"particle"'))
    end
    return assert(loadstring('return {args={value=value, callback=function() return value end}}'))
end
install(w,p,s)
local pa={def='test',args={value='A'},updateZoom=function() end}
local pb={def='test',args={value='B'},updateZoom=function() end}
p.loaded(pa); p.loaded(pb)
check(pa.args.callback()=='A' and pb.args.callback()=='B','actual particle parameter isolation')
local function shader(id)
    return {name='test',totalname=id,args={value=id},createProgram=function() return {} end,
        setUniform=function(self,k,v) self.shad[k]=v end}
end
local sa,sb=shader('A'),shader('B'); s.loaded(sa); s.loaded(sb)
check(sa.shad.value=='A' and sb.shad.value=='B' and sa.shad.callback()=='A','actual shader parameter isolation')
check(actual_loads['/data/gfx/particles/test.lua']==1 and actual_loads['/data/gfx/shaders/test.lua']==1,'actual methods use cache')
print('PASS pinned Particles.loaded and Shader.loaded integration')

local map={particleEmitter=function(self,...) return 'emitter',select('#',...),... end}
local previous=map.particleEmitter
local loaded=run('superload/engine/Map.lua',env{loadPrevious=function() return map end, config={settings={}},
    require=function() return {installMap=function() return true end, install=function() return true end} end})
local result=pack(loaded:particleEmitter(1,2,3,'hit_warning',{},nil,7))
check(loaded.particleEmitter==previous and result[1]=='emitter' and result[2]==7 and result[6]=='hit_warning','hit warning pass-through without clock')

-- Exercise the actual superload with a controllable SDL millisecond clock.
local function warningMap(interval)
    local now, clock_calls, emitted = 0, 0, {}
    local methods={particleEmitter=function(self,...)
        emitted[#emitted+1]=pack(...)
        return 'emitter',nil,select('#',...),...
    end}
    local old=methods.particleEmitter
    run('superload/engine/Map.lua',env{
        loadPrevious=function() return methods end,
        core={game={getTime=function() clock_calls=clock_calls+1; return now end}},
        config={settings={faster_tome={hit_warning_interval_ms=interval}}},
        require=function() return {installMap=function() return true end,install=function() return true end} end,
    })
    return methods,emitted,function(value) now=value end,function() return clock_calls end,old
end
local limited,emitted,setTime,clockCalls=warningMap()
local first=pack(limited:particleEmitter(1,2,3,'hit_warning',{angle=90},nil,7))
check(first.n==10 and first[1]=='emitter' and first[2]==nil and first[3]==7 and first[7]=='hit_warning','first warning preserves return arity and nils')
for i=1,20 do check(select('#',limited:particleEmitter(i,i,1,'hit_warning',{angle=i}))==0,'burst warning suppressed across positions/directions') end
setTime(499); limited:particleEmitter(1,2,1,'hit_warning',{})
check(#emitted==1,'warning remains suppressed before deadline; suppressed attempts do not extend it')
setTime(500); limited:particleEmitter(1,2,1,'hit_warning',{})
check(#emitted==2,'warning resumes at exact default deadline')
local calls=clockCalls()
local ordinary=pack(limited:particleEmitter(1,2,3,'fireball',{},nil,7))
check(ordinary.n==10 and ordinary[7]=='fireball' and clockCalls()==calls,'other particles bypass clock and preserve returns')
local empty=pack(limited:particleEmitter())
check(empty.n==3 and empty[3]==0,'empty argument list is forwarded exactly')
local secondMap=setmetatable({}, {__index=limited})
secondMap:particleEmitter(1,2,1,'hit_warning',{})
check(#emitted==5 and next(secondMap)==nil,'maps have independent limits and no saved timestamp fields')
local weak=setmetatable({secondMap}, {__mode='v'}); secondMap=nil
collectgarbage('collect'); collectgarbage('collect')
check(weak[1]==nil,'warning timestamps do not retain discarded maps')
local wrapped,wrapEmits,wrapTime=warningMap(500)
wrapTime(4294967196); wrapped:particleEmitter(1,2,1,'hit_warning',{})
wrapTime(0); wrapped:particleEmitter(1,2,1,'hit_warning',{})
check(#wrapEmits==1,'SDL tick wrap retains remaining cooldown')
wrapTime(400); wrapped:particleEmitter(1,2,1,'hit_warning',{})
check(#wrapEmits==2,'SDL tick wrap expires at exact deadline')
local custom,customEmits,customTime=warningMap(1000)
custom:particleEmitter(1,2,1,'hit_warning',{})
customTime(500); custom:particleEmitter(1,2,1,'hit_warning',{})
customTime(1000); custom:particleEmitter(1,2,1,'hit_warning',{})
check(#customEmits==2,'configured warning interval is honored')
local unlimited,unlimitedEmits,_,unlimitedClock,unlimitedOriginal=warningMap(0)
for i=1,3 do unlimited:particleEmitter(1,2,1,'hit_warning',{}) end
check(unlimited.particleEmitter==unlimitedOriginal and #unlimitedEmits==3 and unlimitedClock()==0,'zero disables rate limiting entirely')
for _,invalid in ipairs{-1,math.huge,0/0,'500'} do
    local fallback,fallbackEmits,fallbackTime=warningMap(invalid)
    fallback:particleEmitter(1,2,1,'hit_warning',{})
    fallbackTime(499); fallback:particleEmitter(1,2,1,'hit_warning',{})
    fallbackTime(500); fallback:particleEmitter(1,2,1,'hit_warning',{})
    check(#fallbackEmits==2,'invalid configuration uses default interval')
end
print('PASS hit warning default/custom/disabled rate limits, independent weak maps, SDL wrap and particle pass-through')

local util={bound=function(i,lo,hi) return math.max(lo,math.min(i,hi)) end}
local chat={}
run('superload/mod/dialogs/ShowChatLog.lua',env{loadPrevious=function() return chat end,util=util})
local baseline={}
chunk(section(pinned('game/modules/tome/dialogs/ShowChatLog.lua'),'function _M:setScroll','function _M:innerDisplay'),env{_M=baseline,util=util})
local function font(id)
    return {calls=0,draw=function(self,str,width)
        self.calls=self.calls+1
        local out={}
        for i=1,math.ceil(#str/math.max(1,math.floor(width/10))) do
            out[i]={_tex=id..':'..str..':'..i,w=width,h=12,_tex_w=width,_tex_h=12,_dduids={}}
        end
        return out
    end}
end
local function dialog(methods,f,width,texts)
    local d={font=f,iw=width,max=#texts,max_display=2,line_size={},lines={},scrollbar={max=math.max(0,#texts-2)}}
    for i,str in ipairs(texts) do d.lines[i]={str=str,src=i} end
    return setmetatable(d,{__index=methods})
end
local texts={'a','long line wraps over several rows','cc','dd','last'}
for _, shifty in ipairs{false,true} do
    local d,b=dialog(chat,font('A'),80,texts),dialog(baseline,font('A'),80,texts)
    for _, pos in ipairs{0,1,3,999,-1,0,2,0} do
        d:setScroll(pos,shifty); b:setScroll(pos,shifty)
        for _, key in ipairs{'dlist','scroll','max','scrollbar','line_size'} do check(same(d[key],b[key]),'pinned setScroll '..key) end
    end
end
local f=font('A'); local d=dialog(chat,f,300,{'same text'})
d:setScroll(0); d.scroll=nil; d:setScroll(0); check(f.calls==1,'chat cache hit')
collectgarbage('collect'); d.scroll=nil; d:setScroll(0); check(f.calls==1,'strong cache survives GC')
local other=dialog(chat,f,300,{'same text'}); other:setScroll(0); check(f.calls==2,'per-instance cache')
d.iw=50; d:setScroll(0); check(f.calls==3 and d.dlist[1].d.w==40 and d.line_size['same text']==3,'width invalidation at same scroll')
d.font=font('B'); d:setScroll(0); check(d.font.calls==1 and d.dlist[1].d.t:sub(1,1)=='B','font invalidation')
for i=1,129 do
    d.lines={{str='entry'..i,src=i}}; d.max=1; d.scroll=nil; d:setScroll(0)
end
local count=0; for _ in pairs(d._faster_text_cache.entries) do count=count+1 end
check(count==128 and not d._faster_text_cache.entries.entry1,'chat bounded FIFO eviction')
local before=d.font.calls
d.lines={{str='entry1',src=1}}; d.scroll=nil; d:setScroll(0)
check(d.font.calls==before+1,'evicted text rendered again')
print('PASS pinned setScroll parity, font/width invalidation, per-instance cache, GC, eviction')
print('PASS all '..checks..' assertions; '.._VERSION..' / '..(jit and jit.version or 'no JIT'))
