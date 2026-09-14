-- GPL-3.0-or-later. Independently exercise the new escaped entry through the
-- existing pinned-native-writer / untouched stock-reader harness, one graph only.
local addon = assert(arg[1], 'pass addon directory')
local owned = assert(arg[3], 'pass acceptance artifact directory')
local f = assert(io.open(addon..'/tests/test_save_names.lua', 'rb'))
local harness = f:read('*a'); assert(f:close())
local marker = assert(harness:find('-- Both callback implementations,', 1, true))
harness = harness:sub(1, marker - 1)
local before = 'output("mktemp -d /tmp/tome-save-names.XXXXXX")'
local at = assert(harness:find(before, 1, true))
local q = "'"..owned:gsub("'", "'\\''").."'"
harness = harness:sub(1, at-1)..'output("mktemp -d " .. '..string.format('%q', q)..' .. "/native.XXXXXX")'..harness:sub(at+#before)
before = 'assert(build:match("^/tmp/tome%-save%-names%.[%w]+$"))'
at = assert(harness:find(before, 1, true))
harness = harness:sub(1, at-1)..'assert(build:sub(1, '..#owned..') == '..string.format('%q', owned)..')'..harness:sub(at+#before)
local check_case = [[
collect(); native.reset()
local writer = world(true, true)
local original = graph(writer, 3)
writer.save:getFileName(original.child)
local caches
for i = 1, 20 do
    local name, value = debug.getupvalue(writer.save.getFileName, i)
    if name == 'caches' then caches = value; break end
end
assert(caches and caches[writer.save])
local alphabet, value = '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ', 0
for ch in ('main'):gmatch('.') do value = value * 62 + assert(alphabet:find(ch, 1, true)) - 1 end
caches[writer.save].count = value - 1
check(writer.save:getFileName(original.child.child) == '_main', 'escaped name allocated')
local resumes, count = serialize(writer, original)
check(resumes == 5 and count == 4, 'exact native object/yield count')
local files = {}
for _, entry in ipairs(native.entries()) do
    check(files[entry.file] == nil, 'entry name remains unique')
    files[entry.file] = entry.data
end
check(files.main and files._main, 'root and escaped non-root both serialized')
local reader = world(false, false, files)
local loaded = reader.save:loadReal('main')
check(reader.save:getFileName(loaded) == reader.originalName(reader.save, loaded), 'stock reader owns original namer')
equalGraph(original, loaded)
check(reader.save.loaded._main == loaded.child.child, 'escaped setLoaded/loadObject retain object identity')
assert(os.execute('rm -r -- ' .. quote(build)) == 0)
print('PASS '..checks..' independent escaped-main checks through pinned C writer and stock full-graph reader')
]]
assert(loadstring(harness..check_case, '@independent-reserved-stock-fixture'))()
