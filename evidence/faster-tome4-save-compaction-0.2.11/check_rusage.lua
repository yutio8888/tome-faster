local dir=assert(arg[1], 'pass acceptance artifact directory')
local ffi=require 'ffi'
local cpu=assert(loadfile(dir..'/cpu_usage.lua'))()
ffi.cdef[[
size_t fixture_sizeof_rusage(void);
size_t fixture_sizeof_timeval(void);
size_t fixture_offset_stime(void);
size_t fixture_offset_nivcsw(void);
int fixture_self(void);
int fixture_thread(void);
int fixture_sample(int who, double *out);
int fixture_worker(void);
]]
local c=ffi.load(dir..'/rusage_fixture.so')
assert(c.fixture_sizeof_rusage() == ffi.sizeof('struct save_compaction_rusage'))
assert(c.fixture_sizeof_timeval() == ffi.sizeof('struct save_compaction_timeval'))
assert(c.fixture_offset_stime() == ffi.offsetof('struct save_compaction_rusage','ru_stime'))
assert(c.fixture_offset_nivcsw() == ffi.offsetof('struct save_compaction_rusage','ru_other') + 13 * ffi.sizeof('long'))
assert(c.fixture_self()==cpu.RUSAGE_SELF and c.fixture_thread()==cpu.RUSAGE_THREAD)
local out=ffi.new('double[2]')
for _, who in ipairs{cpu.RUSAGE_SELF,cpu.RUSAGE_THREAD} do
    local before_u,before_s=cpu.sample(who)
    assert(c.fixture_sample(who,out)==0)
    local after_u,after_s=cpu.sample(who)
    assert(before_u<=out[0] and out[0]<=after_u)
    assert(before_s<=out[1] and out[1]<=after_s)
end
local self_u,self_s=cpu.sample(cpu.RUSAGE_SELF)
local main_u,main_s=cpu.sample(cpu.RUSAGE_THREAD)
assert(c.fixture_worker()==0)
local after_self_u,after_self_s=cpu.sample(cpu.RUSAGE_SELF)
local after_main_u,after_main_s=cpu.sample(cpu.RUSAGE_THREAD)
local worker_user=after_self_u-self_u
local main_user=after_main_u-main_u
assert(worker_user >= 15, 'RUSAGE_SELF includes joined worker user time')
assert(main_user < 5, 'RUSAGE_THREAD excludes worker user time')
print(('PASS native rusage ABI: sizeof=%d, utime=0, stime=%d, nivcsw=%d, SELF=%d, THREAD=%d; worker user delta=%.3f ms, main user delta=%.3f ms')
    :format(c.fixture_sizeof_rusage(),c.fixture_offset_stime(),c.fixture_offset_nivcsw(),c.fixture_self(),c.fixture_thread(),worker_user,main_user))
