-- GPL-3.0-or-later. Experimental encoder for isolated addon feasibility tests.
-- Mirrors the supported output of ToME 1.7.6 src/serial.c; never installed alone.
local M = {}
local kind, next, rawget = type, next, rawget
local concat, dump, tostring = table.concat, string.dump, tostring
local supported = {boolean=true, number=true, string=true, ["function"]=true, table=true}
local escaped = {["\0"]="\\000", ["\r"]="\\r", ["\n"]="\\\n", ["\\"]="\\\\", ['"']='\\"'}
local pattern = '[%z\r\n\\"]'

function M.new(name, add)
    local strings, string_count = {}, 0
    local function quote(value)
        local cached = strings[value]
        if cached then return cached end
        local result = '"' .. value:gsub(pattern, escaped) .. '"'
        if #value <= 96 and string_count < 2048 then
            strings[value] = result
            string_count = string_count + 1
        end
        return result
    end
    local buffer, size = {}, 0
    local function put(value) size=size+1;buffer[size]=value end
    local function objectName(object)
        -- writeTbl(s, get_name(...)) evaluates get_name twice in serial.c.
        name(object)
        return name(object)
    end
    local encode
    encode = function(value, what, top)
        if what == 'boolean' then put(value and 'true' or 'false')
        elseif what == 'number' then put(tostring(value))
        elseif what == 'string' then put(quote(value))
        elseif what == 'function' then
            -- lua_dump observes the stack top even when serial.c is encoding
            -- a function key. A failed dump writes an empty byte sequence.
            local ok, bytes = pcall(dump, top)
            put('loadstring(');put(quote(ok and bytes or ''));put(')')
        elseif what == 'table' then
            if rawget(value, '__CLASSNAME') ~= nil then
                put("loadObject('");put(objectName(value));put("')")
                add(value)
            else
                put('{')
                for k,v in next,value do
                    local kt,vt=kind(k),kind(v)
                    if supported[kt] and supported[vt] then
                        put('[');encode(k,kt,v);put(']=');encode(v,vt,v);put(',\n')
                    end
                end
                put('}\n')
            end
        else error('unsupported serial.c root type: '..what) end
    end
    return function(object, allow, disallow, disallow2)
        for i=1,size do buffer[i]=nil end
        size=0
        local filename=name(object)
        assert(kind(filename)=='string' and filename:match('^[%w_-]+$'), 'unsafe object key')
        put('d={}\n');put("setLoaded('");put(objectName(object));put("', d)\n")
        for k,v in next,object do
            local skip = allow and rawget(allow,k)==nil or not allow and disallow and rawget(disallow,k)~=nil
            -- The second exclusion table replaces, rather than combines with,
            -- the first decision in the pinned C serializer.
            if disallow2 then skip=rawget(disallow2,k)~=nil end
            if not skip then
                put('d[');encode(k,kind(k),v);put(']=');encode(v,kind(v),v);put('\n')
            end
        end
        put('\nreturn d')
        return filename,concat(buffer,'',1,size)
    end
end

return M
