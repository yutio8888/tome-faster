-- GPL-3.0-or-later. Disposable-save prototype, not a production addon feature.
local M = {version='carrier-v1', writes={}, read_stats={}}
local Class = require 'engine.class'
local Savefile = require 'engine.Savefile'
local Encoder = require 'engine.CarrierEncoder'
local native_new = core.serial.new
local marker = '_faster_block_format'
local format = 'faster-carrier-block-v1'
local active = setmetatable({}, {__mode='k'})
local readers = setmetatable({}, {__mode='k'})
local original_save, original_objects = Class.save, Savefile.saveObject
local original_load, original_add, original_close = Savefile.loadReal, Savefile.addDelayLoad, Savefile.close
local batches = setmetatable({}, {__mode='k'})
local installed=false

local function readfile(path)
    local file,err=fs.open(path,'r')
    assert(file, 'block file missing: '..path..' '..tostring(err))
    local parts={}
    while true do
        local part=file:read(65536)
        if not part or #part==0 then break end
        parts[#parts+1]=part
    end
    file:close()
    local body=table.concat(parts)
    assert(type(body)=='string' and #body>0, 'empty block file: '..path)
    return body
end

local function unpackCarrier(body, name)
    local registered
    local fn=assert(loadstring(body,'@block:'..name))
    local environment={setLoaded=function(key,obj)
        assert(key==name and not registered, 'carrier registration mismatch')
        registered=obj
    end}
    local result=setfenv(fn,environment)()
    assert(type(result)=='table' and result==registered, 'invalid carrier')
    return result
end

local function newContext(save, zip, target)
    local context={save=save,zip=zip,target=target,records={},index={},bytes=0,
        count=0,blocks=0,total_bytes=0,max_block_bytes=0,max_object_bytes=0}
    context.encode=Encoder.new(function(o)return save:getFileName(o)end,
        function(o)save:addToProcess(o)end)
    local entry
    local function entryName()return entry end
    local function noObjects()error('carrier queued a gameplay object')end
    function context:write(name, object)
        entry=name
        native_new(zip,entryName,noObjects,nil,nil,nil):toZip(object)
    end
    function context:flush()
        if self.bytes==0 then return end
        self.blocks=self.blocks+1
        local name='block_'..self.blocks
        for key in pairs(self.records) do
            assert(not self.index[key], 'duplicate logical object')
            self.index[key]=name
        end
        self:write(name,{format=format,version=1,records=self.records})
        self.max_block_bytes=math.max(self.max_block_bytes,self.bytes)
        self.records={};self.bytes=0
    end
    function context:append(name, body)
        if self.bytes>0 and self.bytes+#body>self.target then self:flush() end
        assert(not self.records[name] and not self.index[name], 'duplicate logical object')
        self.records[name]=body;self.bytes=self.bytes+#body
        self.count=self.count+1;self.total_bytes=self.total_bytes+#body
        self.max_object_bytes=math.max(self.max_object_bytes,#body)
    end
    function context:finish()
        self:flush()
        assert(self.index.main, 'missing logical main')
        self:write('main',{format=format,version=1,index=self.index,
            object_count=self.count,block_count=self.blocks,body_bytes=self.total_bytes,target=self.target})
        self:write(marker,{format=format,version=1})
        M.writes[#M.writes+1]={zip=zip,target=self.target,objects=self.count,blocks=self.blocks,
            body_bytes=self.total_bytes,max_object_bytes=self.max_object_bytes,max_block_bytes=self.max_block_bytes}
    end
    return context
end

local function loadContext(self)
    local context=readers[self]
    if context~=nil then return context end
    if not fs.exists(self.load_dir..marker) then readers[self]=false;return false end
    local mark=unpackCarrier(readfile(self.load_dir..marker),marker)
    assert(mark.format==format and mark.version==1, 'unknown block format')
    local index=unpackCarrier(readfile(self.load_dir..'main'),'main')
    assert(index.format==format and index.version==1 and type(index.index)=='table', 'invalid block index')
    assert(type(index.object_count)=='number' and type(index.block_count)=='number', 'invalid block counts')
    local count=0
    for name,block in pairs(index.index) do
        assert(type(name)=='string' and name:match('^[%w_-]+$'), 'invalid object key')
        assert(type(block)=='string' and block:match('^block_%d+$'), 'invalid block key')
        count=count+1
    end
    assert(count==index.object_count and index.index.main, 'incomplete block index')
    context={index=index.index,cache={},order={},bytes=0,limit=4*1024*1024,
        stats={objects=0,block_reads=0,cache_hits=0,cache_peak_bytes=0,max_read_bytes=0}}
    readers[self]=context
    M.read_stats[#M.read_stats+1]=context.stats
    return context
end

local function fetch(self, context, name)
    local block=assert(context.index[name], 'object absent from block index: '..tostring(name))
    local entry=context.cache[block]
    if entry then context.stats.cache_hits=context.stats.cache_hits+1
    else
        local raw=readfile(self.load_dir..block)
        local decoded=unpackCarrier(raw,block)
        assert(decoded.format==format and decoded.version==1 and type(decoded.records)=='table', 'invalid block')
        local bytes=0
        for key,body in pairs(decoded.records) do
            assert(context.index[key]==block and type(body)=='string', 'record/index mismatch')
            bytes=bytes+#body
        end
        while #context.order>0 and context.bytes+bytes>context.limit do
            local old=table.remove(context.order,1)
            context.bytes=context.bytes-context.cache[old].bytes
            context.cache[old]=nil
        end
        entry={records=decoded.records,bytes=bytes}
        if bytes<=context.limit then
            context.cache[block]=entry;context.order[#context.order+1]=block
            context.bytes=context.bytes+bytes
        end
        context.stats.block_reads=context.stats.block_reads+1
        context.stats.max_read_bytes=math.max(context.stats.max_read_bytes,#raw)
        context.stats.cache_peak_bytes=math.max(context.stats.cache_peak_bytes,context.bytes)
    end
    return assert(entry.records[name], 'record absent from indexed block: '..name)
end

-- Same self-reference restoration contract as the stock Savefile loader.
local function resolveSelf(object, base, allow_object)
    if (object.__ATOMIC or object.__CLASSNAME) and not allow_object then return end
    local change={}
    for key,value in pairs(object) do
        if type(value)=='table' then
            if value==Class.LOAD_SELF then change[#change+1]=key
            else resolveSelf(value,base,false) end
        end
    end
    for i,key in ipairs(change) do object[key]=base end
end

local function blockLoad(self, name, context)
    if self.loaded[name] then return self.loaded[name] end
    local object=Class.load(fetch(self,context,name),name)
    assert(type(object)=='table', 'block object did not load')
    resolveSelf(object,object,true)
    core.wait.manualTick(1)
    self.loaded[name]=object
    context.stats.objects=context.stats.objects+1
    return object
end

function M.install(options)
    assert(not installed, 'prototype already installed')
    assert(config.settings.cheat and config.settings.disable_all_connectivity,
        'prototype restricted to isolated offline test sessions')
    assert(type(native_new)=='function' and debug.getinfo(native_new,'S').what=='C', 'native serializer required')
    installed=true
    local target=options.block_bytes or 0
    assert(target==0 or target==65536 or target==262144, 'unknown target block size')
    if target>0 then
        function Class:save(filter, allow)
            local save=Savefile.current_save
            local context=active[save]
            if not context then return original_save(self,filter,allow) end
            filter=filter or {}
            if self._no_save_fields then table.merge(filter,self._no_save_fields) end
            if not allow then
                filter.new=true;filter._no_save_fields=true;filter._mo=true
                filter._last_mo=true;filter._mo_final=true;filter._hooks=true
            else filter.__CLASSNAME=true end
            local metatable=getmetatable(self)
            setmetatable(self,{})
            local ok,name,body=pcall(context.encode,self,allow and filter or nil,not allow and filter or nil,self._no_save_fields)
            if ok and options.native_verify then
                local physical='native_'..name
                local first=true
                native_new(context.zip,function(o)
                    local logical=save:getFileName(o)
                    if first then first=false;return physical end
                    return logical
                end,function(o)save:addToProcess(o)end,
                    allow and filter or nil,not allow and filter or nil,self._no_save_fields):toZip(self)
            end
            setmetatable(self,metatable)
            if not ok then error(name,0) end
            context:append(name,body)
        end
        function Savefile:saveObject(object, zip)
            if not zip:match('/game%.teag%.tmp$') then return original_objects(self,object,zip) end
            assert(not active[self], 'nested block save')
            local context=newContext(self,zip,target)
            active[self]=context
            local result=original_objects(self,object,zip)
            context:finish()
            active[self]=nil
            assert(result==context.count, 'object bypassed prototype encoder')
            return result
        end
    end
    function Savefile:addDelayLoad(object)
        local batch=batches[self]
        if batch and self.delayLoad==batch.queue then batch.items[#batch.items+1]=object
        else return original_add(self,object) end
    end
    function Savefile:loadReal(name)
        if self.loaded[name] then return self.loaded[name] end
        local context=loadContext(self)
        if not context then return original_load(self,name) end
        if batches[self] then return blockLoad(self,name,context) end
        local batch={queue=self.delayLoad,items={}}
        batches[self]=batch
        local ok,result=pcall(blockLoad,self,name,context)
        batches[self]=nil
        local count=#batch.items
        for i=#batch.queue,1,-1 do batch.queue[i+count]=batch.queue[i] end
        for i=1,count do batch.queue[i]=batch.items[count-i+1] end
        if not ok then error(result,0) end
        return result
    end
    function Savefile:close()
        readers[self]=nil
        return original_close(self)
    end
end

return M
