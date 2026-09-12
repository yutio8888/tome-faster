-- GPL-3.0-or-later; uses ToME 1.7.6 engine/class.lua, Copyright (C) 2009-2019 Nicolas Casalini.
-- Synthetic test only: original pinned cloneFull vs two lookup reorderings.
local repo = assert(arg[1])
local function quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
local p = assert(io.popen("git -C " .. quote(repo) .. " show 624a67329fe2ad440c5b344785a9c73fcf22ae63:game/engines/default/engine/class.lua"))
local source = p:read("*a"); assert(p:close())
local first = assert(source:find("local function clonerecursfull(", 1, true))
local last = assert(source:find("--- Automatically called by cloneCustom()", first, true))
local code = source:sub(first, last - 1)
local oldkey = [[if clonetable[k] then nk = clonetable[k]
		elseif type(k) == "table" then nk, add = clonerecursfull(clonetable, k, noclonecall, use_saveinstead) nb = nb + add
		end]]
local newkey = [[if type(k) == "table" then
            if clonetable[k] then nk = clonetable[k]
            else nk, add = clonerecursfull(clonetable, k, noclonecall, use_saveinstead) nb = nb + add end
        end]]
local oldvalue = [[if clonetable[e] then ne = clonetable[e]
		elseif type(e) == "table" and (type(k) ~= "string" or k ~= "__threads") then ne, add = clonerecursfull(clonetable, e, noclonecall, use_saveinstead) nb = nb + add
		end]]
local newvalue = [[if type(e) == "table" then
            if clonetable[e] then ne = clonetable[e]
            elseif k ~= "__threads" then ne, add = clonerecursfull(clonetable, e, noclonecall, use_saveinstead) nb = nb + add end
        end]]
local function replace(s, a, b)
    local start, finish = assert(s:find(a, 1, true))
    return s:sub(1, start - 1) .. b .. s:sub(finish + 1)
end
local candidate = replace(replace(code, oldkey, newkey), oldvalue, newvalue)
local function load(text)
    local Class = {}
    setfenv(assert(loadstring(text)), setmetatable({_M = Class}, {__index = _G}))()
    return Class.cloneFull
end
local original, faster = load(code), load(candidate)
local trace, uid = {}, 0
local mt = {__index = {cloned = function(self, from)
    uid = uid + 1; self.uid = uid; self.from_label = from.label
    trace[#trace + 1] = from.label
end}}
local function graph(count)
    local root = setmetatable({label = "party", __CLASSNAME = "Party", members = {}, list = {}}, mt)
    for i = 1, count do
        local object = setmetatable({label = "actor" .. i, __CLASSNAME = "Actor", name = "actor name", level = 34,
            life = 1200, max_life = 1400, exp = 12.1, self_value = false, note = "not a table",
            values = {1,2,3,4,5,6,7,8,9,10}, f = print}, mt)
        object.self_value = object
        root.members[object] = {important = true, index = i}
        root.list[i] = object
    end
    root.self_value = root
    root.shared = root.list[1]
    root.__threads = {retained = true}
    return root
end
local input = graph(2000)
trace, uid = {}, 0; local a = original(input); local expected, countA = table.concat(trace, ","), uid
trace, uid = {}, 0; local b = faster(input); local got, countB = table.concat(trace, ","), uid
assert(expected == got and countA == countB and countA == 2001)
assert(a.self_value == a and b.self_value == b and a.shared == a.list[1] and b.shared == b.list[1])
assert(a.__threads == input.__threads and b.__threads == input.__threads)
for i = 1, #input.list do
    local x, y = a.list[i], b.list[i]
    assert(x.uid == y.uid and x.from_label == y.from_label and x.self_value == x and y.self_value == y)
    assert(a.members[x].index == b.members[y].index and a.members[x].index == i)
    assert(getmetatable(x) == getmetatable(y) and x.values[10] == y.values[10])
end
a, b = nil, nil
local function measure(method)
    trace, uid = {}, 0
    collectgarbage("collect")
    local started = os.clock()
    local output = method(input)
    local elapsed = (os.clock() - started) * 1000
    assert(output and uid == 2001)
    return elapsed
end
for _ = 1, 4 do measure(original); measure(faster) end
local oa, ob = {}, {}
for i = 1, 15 do
    if i % 2 == 1 then oa[i] = measure(original); ob[i] = measure(faster)
    else ob[i] = measure(faster); oa[i] = measure(original) end
end
local function stats(values)
    table.sort(values)
    return ("median=%.3f min=%.3f max=%.3f"):format(values[8], values[1], values[#values])
end
print("PASS exact 2001 cloned callback order and UID assignments; cycles, actor table keys, retained threads, metatables")
print("runtime=" .. (jit and jit.version or _VERSION) .. " synthetic_actors=2000 pairs=15")
print("baseline_ms " .. stats(oa))
print("candidate_ms " .. stats(ob))
