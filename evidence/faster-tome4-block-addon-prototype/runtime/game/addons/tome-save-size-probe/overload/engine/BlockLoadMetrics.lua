-- Diagnostic only. Identical timing wrapper for packed and materialized reads.
local M={}
local CPU=require 'engine.SaveCompactionCPU'
local clock=CPU.clock
local function sample()
    local wall=clock(1)
    local user,system=CPU.sample(0)
    local thread_user,thread_system=CPU.sample(1)
    return {wall_ms=wall,process_user_ms=user,process_system_ms=system,
        thread_user_ms=thread_user,thread_system_ms=thread_system,thread_cpu_ms=clock(3)}
end
local function delta(first,last)
    local out={}
    for key,value in pairs(last) do out[key]=value-first[key] end
    return out
end
function M.install(options)
    local Savefile,Class=require 'engine.Savefile',require 'engine.class'
    if options.load_audit then
        M.trace={}
        local original=Class.load
        Class.load=function(body,name)
            M.trace[#M.trace+1]={'begin',name}
            local object=original(body,name)
            M.trace[#M.trace+1]={'end',name,object and object.__CLASSNAME or false}
            return object
        end
    end
    local load=Savefile.loadGame
    function Savefile:loadGame(...)
        local started=sample()
        local object,delay=load(self,...)
        local returned=sample()
        if not object then return object,delay end
        local queue
        if options.load_audit then
            local names={}
            for name,value in pairs(self.loaded) do names[value]=name end
            queue={}
            for i,value in ipairs(self.delayLoad) do
                queue[i]={names[value] or false,value.__CLASSNAME or false}
            end
        end
        return object,function(...)
            local result=delay(...)
            local finished=sample()
            M.result={call=delta(started,returned),with_delayed=delta(started,finished),
                delay_queue=queue,trace=M.trace}
            return result
        end
    end
end
return M
