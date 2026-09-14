-- Differential check against the unchanged native serializer, not a Lua oracle.
local native=assert(package.loadlib(assert(arg[1]),'luaopen_serial_fixture'))()
local Encoder=assert(loadfile(assert(arg[2])))()
local checks=0
local function check(value,why)assert(value,why);checks=checks+1 end
local function compare(object,allow,disallow,disallow2)
    local function callbacks()
        local names,sequence={[object]='main'},{}
        local count=0
        return function(o)
            if not names[o] then count=count+1;names[o]=tostring(count) end
            sequence[#sequence+1]={'name',o,names[o]}
            return names[o]
        end,function(o)sequence[#sequence+1]={'add',o}end,sequence
    end
    native.reset()
    local name,add,original_events=callbacks()
    native.new('encoder-differential.tmp',name,add,allow,disallow,disallow2):toZip(object)
    local expected=native.entries()[1]
    local new_name,new_add,actual_events=callbacks()
    local filename,body=Encoder.new(new_name,new_add)(object,allow,disallow,disallow2)
    check(filename==expected.file,'filename differs')
    if body~=expected.data then
        local at=1
        while at<=math.min(#body,#expected.data) and body:byte(at)==expected.data:byte(at) do at=at+1 end
        print('first byte difference',at,'native bytes',#expected.data,'Lua bytes',#body)
        print('native',string.format('%q',expected.data:sub(math.max(1,at-40),at+100)))
        print('lua',string.format('%q',body:sub(math.max(1,at-40),at+100)))
    end
    check(body==expected.data,'native/Lua object program differs')
    if #actual_events~=#original_events then
        for i,e in ipairs(original_events) do print('native',i,e[1],e[2]==object and 'root' or e[2].id,e[3]) end
        for i,e in ipairs(actual_events) do print('lua',i,e[1],e[2]==object and 'root' or e[2].id,e[3]) end
    end
    check(#actual_events==#original_events,'callback count differs')
    for i,event in ipairs(actual_events) do
        for j=1,3 do check(event[j]==original_events[i][j],'callback order/value differs') end
    end
    return body
end
local bytes={}
for i=0,255 do bytes[#bytes+1]=string.char(i) end
bytes=table.concat(bytes)
local function fn(a)return a*2 end
local function second(a)return a+1 end
local child={__CLASSNAME='Fixture',id=2}
local object={__CLASSNAME='Fixture',__ATOMIC=true,child=child,binary=bytes,
    boolean=false,number=-1.23456789012345,text='中文\0'..'123\r\n"\\',callback=fn,
    ccallback=print,plain={array={1,2,3},empty={},[false]=false,[true]=true,[child]=child,
        [fn]=second,ignored=io.stdout}, [false]=true,[child]=fn,[fn]=second}
object.self=object
child.parent=object
compare(object)
compare(object,{__CLASSNAME=false,child=false,plain=0,self=true})
compare(object,nil,{binary=false,number=true,ccallback=false})
compare(object,{child=true,callback=true,__CLASSNAME=true},nil,{callback=false})
compare({nan=0/0,pinf=math.huge,ninf=-math.huge,minuszero=-0})
for i=1,1000 do
    local a={__CLASSNAME='Fixture',value=i}
    local b={__CLASSNAME='Fixture',value=-i}
    local root={__CLASSNAME='Fixture',__ATOMIC=true,a=a,b=b,index=i,values={},data={}}
    root.self=root
    for j=1,12 do
        root.values[j]={n=(i-j)/7,yes=(j%2==0),word=bytes:sub(j,j+i%32),[a]=b}
        root.data['field'..j]=j%3==0 and fn or 'text\0"\\\n'..j
    end
    compare(root,i%4==0 and {__CLASSNAME=true,self=true,values=true,a=false} or nil,
        i%4==1 and {data=false,index=true} or nil,i%4==2 and {b=false} or nil)
    if i%50==0 then collectgarbage('collect') end
end
print(('PASS: %d native serializer differential checks across 1005 objects'):format(checks))
