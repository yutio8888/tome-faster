-- Diagnostic Linux x86_64 CPU sampling; never ship in the addon.
-- The paired native fixture verifies this layout against the host libc headers.
local ffi = require 'ffi'
assert(ffi.os == 'Linux' and ffi.arch == 'x64' and ffi.sizeof('long') == 8,
    'this diagnostic ABI is verified only for Linux x86_64 LP64')
ffi.cdef[[
struct save_compaction_timeval { long tv_sec; long tv_usec; };
struct save_compaction_rusage {
    struct save_compaction_timeval ru_utime;
    struct save_compaction_timeval ru_stime;
    long ru_other[14];
};
int getrusage(int who, struct save_compaction_rusage *usage);
struct block_metric_timespec { long tv_sec; long tv_nsec; };
int clock_gettime(int, void *);
]]
assert(ffi.sizeof('struct save_compaction_rusage') == 144)
assert(ffi.offsetof('struct save_compaction_rusage', 'ru_stime') == 16)
local usage = {
    [0] = ffi.new('struct save_compaction_rusage[1]'),
    [1] = ffi.new('struct save_compaction_rusage[1]'),
}
local M = {RUSAGE_SELF=0, RUSAGE_THREAD=1}
local ts=ffi.new('struct block_metric_timespec[1]')
function M.clock(id)
    assert(ffi.C.clock_gettime(id,ts)==0)
    return tonumber(ts[0].tv_sec)*1000+tonumber(ts[0].tv_nsec)/1e6
end
function M.memory()
    assert(ffi.C.getrusage(0,usage[0])==0)
    return {process_peak_rss_kib=tonumber(usage[0][0].ru_other[0]),lua_kib=collectgarbage('count')}
end
function M.sample(who)
    local out = assert(usage[who], 'supported scopes: SELF=0, THREAD=1')
    assert(ffi.C.getrusage(who, out) == 0, 'getrusage failed')
    return tonumber(out[0].ru_utime.tv_sec) * 1000 + tonumber(out[0].ru_utime.tv_usec) / 1000,
           tonumber(out[0].ru_stime.tv_sec) * 1000 + tonumber(out[0].ru_stime.tv_usec) / 1000
end
return M
