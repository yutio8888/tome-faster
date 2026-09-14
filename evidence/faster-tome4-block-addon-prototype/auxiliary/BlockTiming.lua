-- Isolated attribution run only; this instrumentation is absent from formal A/B.
local M={stats={encode={},native={}}}
local CPU=require 'engine.SaveCompactionCPU'
local function record(group,key,wall,cpu,bytes)
    local value=group[key]
    if not value then value={calls=0,wall_ms=0,thread_cpu_ms=0,max_thread_cpu_ms=0,bytes=0};group[key]=value end
    value.calls=value.calls+1;value.wall_ms=value.wall_ms+wall;value.thread_cpu_ms=value.thread_cpu_ms+cpu
    value.max_thread_cpu_ms=math.max(value.max_thread_cpu_ms,cpu);value.bytes=value.bytes+(bytes or 0)
end
function M.install()
    local Encoder=require 'engine.CarrierEncoder'
    local original=Encoder.new
    Encoder.new=function(...)
        local encode=original(...)
        return function(object,...)
            local wall,cpu=CPU.clock(1),CPU.clock(3)
            local name,body=encode(object,...)
            local end_cpu,end_wall=CPU.clock(3),CPU.clock(1)
            record(M.stats.encode,object.__CLASSNAME or '(plain)',end_wall-wall,end_cpu-cpu,#body)
            return name,body
        end
    end
    local methods=assert(debug.getregistry()['core{serial}']).__index
    local toZip=assert(methods.toZip)
    assert(debug.getinfo(toZip,'S').what=='C')
    methods.toZip=function(serializer,object)
        local label=rawget(object,'format')=='faster-carrier-block-v1' and '(carrier)' or object.__CLASSNAME or '(plain)'
        local wall,cpu=CPU.clock(1),CPU.clock(3)
        local result=toZip(serializer,object)
        local end_cpu,end_wall=CPU.clock(3),CPU.clock(1)
        record(M.stats.native,label,end_wall-wall,end_cpu-cpu)
        return result
    end
end
return M
