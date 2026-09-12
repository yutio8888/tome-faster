-- Local diagnostic only; no installed overrides or network operations.
local M = {}
function M.run(game)
 local ffi = require 'ffi'
 ffi.cdef[[
 struct faster_mallinfo2 { size_t arena,ordblks,smblks,hblks,hblkhd,usmblks,fsmblks,uordblks,fordblks,keepcost; };
 struct faster_mallinfo2 mallinfo2(void);
 struct faster_gzip_ts { long tv_sec, tv_nsec; };
 int clock_gettime(int, struct faster_gzip_ts *);
 ]]
 local ts=ffi.new('struct faster_gzip_ts[1]')
 local clock=ffi.cast('int (*)(int, void *)',ffi.C.clock_gettime)
 local function now() clock(1,ts);return tonumber(ts[0].tv_sec)*1000+tonumber(ts[0].tv_nsec)/1e6 end
 local function memory() local m=ffi.C.mallinfo2();return tonumber(m.uordblks+m.hblkhd) end
 local function candidate(data)
  local out,status=zlib.compress(data,9,8,31,8,0)
  assert(status==1 and type(out)=='string','replacement gzip failed')
  return out
 end
 local original=core.zlib.compress
 local base={}
 for i=0,255 do base[#base+1]=string.char(i) end
 base=table.concat(base)
 local sizes={0,1,2,8,16,64,256,4096,262144}
 local cases={}
 for _,n in ipairs(sizes) do
  local data=string.rep(base,math.ceil(n/256)):sub(1,n)
  local a,b=original(data),candidate(data)
  local decoded,status=zlib.decompress(b,47)
  assert(decoded==data and status==1,'roundtrip failed')
  if a then assert(a==b,'gzip byte mismatch on successful original') end
  cases[#cases+1]={bytes=n,original_ok=a~=nil,candidate_ok=true,equal_when_original_succeeds=a and true or nil}
 end
 local data=string.rep(base,1024)
 local batches={}
 for i,which in ipairs{'candidate','original','candidate','original'} do
  local f=which=='candidate' and candidate or original
  collectgarbage('collect')
  local m0=memory();local t0=now()
  for j=1,100 do assert(f(data)) end
  local dt=now()-t0
  collectgarbage('collect')
  local m1=memory()
  batches[#batches+1]={method=which,calls=100,input_bytes=#data,wall_ms=dt,native_allocated_delta_bytes=m1-m0}
 end
 local result={cases=cases,batches=batches,network_calls=0,installed_overrides=false,turn=game.turn,
  memory_method='glibc mallinfo2 uordblks+hblkhd before/after batch, full Lua GC before each reading',
  runtime=jit.version,parameters={level=9,method=8,windowBits=31,memLevel=8,strategy=0}}
 require 'Json2'
 print('[GzipBench] '..json.encode(result))
 return result
end
return M
