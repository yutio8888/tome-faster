-- Synthetic container faults with the actual reader/class/Module caller excerpt.
-- Filesystem and UI are explicit in-memory fixtures; no character files are read.
-- The caller fixture keeps the engine default md5_types={}, unlike live ToME's
-- enabled game checksum. Live ToME may raise inside md5Check before that branch.
local root,repo=assert(arg[1]),assert(arg[2])
local native=assert(package.loadlib(root..'/native-fixture/serial_fixture.so','luaopen_serial_fixture'))()
local function read(path)local f=assert(io.open(path,'rb'));local s=f:read('*a');f:close();return s end
local function section(source,first,last)
    local a=assert(source:find(first,1,true));local b=assert(source:find(last,a,true));return source:sub(a,b-1)
end
local function run(code,name,env)return setfenv(assert(loadstring(code,name)),env)()end
local classSource=section(read(repo..'/game/engines/default/engine/class.lua'),'__zipname_zf_store = {}','--- "Reloads"')
local saveSource=read(repo..'/game/engines/default/engine/Savefile.lua')
local caller=section(read(repo..'/game/engines/default/engine/Module.lua'),
    'local save = engine.Savefile.new(_G.game.save_name)','\n\t-- And now run it!')
local prototypeSource=read(root..'/runtime/game/addons/tome-save-size-probe/overload/engine/BlockPrototype.lua')
local Encoder=assert(loadfile(root..'/runtime/game/addons/tome-save-size-probe/overload/engine/CarrierEncoder.lua'))()
local FORMAT='faster-carrier-block-v1'
local MARKER='_faster_block_format'
local function carrier(name,object)
    native.reset()
    native.new('fault-fixture.tmp',function()return name end,function()error('unexpected object')end,
        nil,nil,nil):toZip(object)
    return native.entries()[1].data
end
local bytes={}
for i=0,255 do bytes[#bytes+1]=string.char(i) end
bytes=table.concat(bytes)
local bodies={
    main="d={}\nsetLoaded('main',d)\nd.__CLASSNAME='Fixture'\nd.child=loadObject('1')\nd.same=loadObject('1')\nd.self=loadObject('main')\nd.bytes="..string.format('%q',bytes).."\nreturn d",
    ['1']="d={}\nsetLoaded('1',d)\nd.__CLASSNAME='Fixture'\nd.parent=loadObject('main')\nd.flag=false\nreturn d",
}
local function validFiles()
    return {
        [MARKER]=carrier(MARKER,{format=FORMAT,version=1}),
        main=carrier('main',{format=FORMAT,version=1,index={main='block_1',['1']='block_2'},
            object_count=2,block_count=2,body_bytes=#bodies.main+#bodies['1'],target=65536}),
        block_1=carrier('block_1',{format=FORMAT,version=1,records={main=bodies.main}}),
        block_2=carrier('block_2',{format=FORMAT,version=1,records={['1']=bodies['1']}}),
    }
end
local function world(files,install)
    local Class,Savefile={},{}
    local events,deletes,read_chunks={}, {},0
    local game={save_name='fixture'}
    local classObject={loaded=function(o)events[#events+1]=o end}
    local Dialog={simpleWaiter=function()return{done=function()end}end}
    local function requireFixture(name)
        if name=='engine.class' then return Class end
        if name=='engine.Savefile' then return Savefile end
        if name=='engine.CarrierEncoder' then return Encoder end
        if name=='engine.ui.Dialog' then return Dialog end
        if name=='Fixture' then return classObject end
        error('unavailable fixture class '..tostring(name))
    end
    local fs={
        exists=function(path)
            if path=='/save/fixture/game.teag' then return true end
            return files[path:gsub('^/tmp/loadsave/','')]~=nil
        end,
        getRealPath=function()return 'fixture.zip' end,mount=function()end,umount=function()end,
        list=function()return{'game.teag','zone-fixture.teaz','desc.lua'}end,
        delete=function(path)deletes[#deletes+1]=path end,
        open=function(path)
            local body=files[path:gsub('^/tmp/loadsave/','')]
            if not body then return nil,'fixture missing entry' end
            local position=1
            return {read=function(_,requested)
                if position>#body then return nil end
                -- Force partial reads, including inside escape sequences.
                local count=math.min(requested or 8192,17)
                local piece=body:sub(position,position+count-1)
                position=position+#piece;read_chunks=read_chunks+1;return piece
            end,close=function()end}
        end,
    }
    local core={serial={new=native.new},wait={manualTick=function()end,enableManualTick=function()end},
        display={forceRedraw=function()end}}
    local environment=setmetatable({engine={Savefile=Savefile},core=core,fs=fs,require=requireFixture,
        config={settings={cheat=true,disable_all_connectivity=true}},
        print=function()end,game=game,util={steamCanCloud=function()return false end},
        module=function()end,_t=function(s)return s end}, {__index=_G})
    local classEnv=setmetatable({_M=Class},{__index=environment})
    run(classSource,'@/engine/class.lua',classEnv);Class.load=classEnv.load
    local saveEnv=setmetatable({_M=Savefile,class=Class,savefile_pipe={current_nb=0}},{__index=environment})
    run(saveSource,'@/engine/Savefile.lua',saveEnv)
    Savefile.md5_types={}
    local save=setmetatable({}, {__index=Savefile});save:init('fixture',false)
    Savefile.new=function()return save end
    local moduleEnv=setmetatable({_G={game=game},new_game=false},{__index=environment})
    local prototype
    if install then
        prototype=run(prototypeSource,'@/engine/BlockPrototype.lua',environment)
        prototype.install{block_bytes=0}
    end
    return {
        call=function()return run(caller,'@/engine/Module.lua',moduleEnv)end,
        value=function()return moduleEnv._G.game end,
        events=events,deletes=deletes,
        reads=function()return read_chunks end,
    }
end
local checks=0
local function check(value,message)assert(value,message);checks=checks+1 end
local function accept(name,files,install)
    local w=world(files,install)
    w.call()
    local game=w.value()
    check(game.child==game.same,'shared reference')
    check(game.child.parent==game and game.self==game,'cyclic/self reference')
    check(game.bytes==bytes and game.child.flag==false,'field values')
    check(#w.events==2 and w.events[1]==game and w.events[2]==game.child,'deferred callback order')
    check(#w.deletes==0 and w.reads()>2,'partial reads and no deletes')
    print('PASS',name)
end
accept('valid packed file with forced 17-byte reads',validFiles(),true)
accept('legacy fallback with prototype installed',bodies,true)
local faults={
    {'missing referenced block',function(f)f.block_2=nil end},
    {'truncated block',function(f)f.block_1=f.block_1:sub(1,80)end},
    {'unknown format version',function(f)f[MARKER]=carrier(MARKER,{format=FORMAT,version=99})end},
    {'missing index',function(f)f.main=nil end},
    {'invalid block path',function(f)f.main=carrier('main',{format=FORMAT,version=1,
        index={main='../other',['1']='block_2'},object_count=2,block_count=2})end},
    {'missing logical main',function(f)f.main=carrier('main',{format=FORMAT,version=1,
        index={['1']='block_2'},object_count=1,block_count=1})end},
}
for _,fault in ipairs(faults) do
    local files=validFiles();fault[2](files)
    local w=world(files,true)
    local ok=pcall(w.call)
    check(not ok and #w.deletes==0 and #w.events==0,'malformed container must raise before caller deletion')
    print('PASS',fault[1], 'raised before the caller deletion path')
end
-- These are recorded limitations of the measured prototype, not passing safety claims.
for _,case in ipairs{{'reader absent',false,false},{'format marker absent',true,true}} do
    local files=validFiles()
    if case[3] then files[MARKER]=nil end
    local w=world(files,case[2])
    local ok=pcall(w.call)
    check(ok and #w.deletes==4,'known stock nil-load deletion path was not observed')
    print('KNOWN UNSAFE',case[1],'actual Module caller excerpt reached four mocked delete operations')
end
print(('PASS: %d assertions; six rejection cases; two explicitly unsafe cases reproduced'):format(checks))
print('Scope: pinned class/Savefile methods and Module load branch; md5_types={}, filesystem/UI mocked, not full Module instantiation.')
