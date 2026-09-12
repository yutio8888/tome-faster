#!/usr/bin/env python3
"""Compile and run native particle and sanitized graph profiling comparisons."""
import argparse,json,os,platform,statistics,subprocess
from pathlib import Path
cli=argparse.ArgumentParser(description=__doc__)
cli.add_argument('--engine',type=Path,required=True)
cli.add_argument('--data',type=Path,required=True)
cli.add_argument('--results',type=Path,required=True)
a=cli.parse_args(); a.results.mkdir(parents=True,exist_ok=True)
here=Path(__file__).resolve().parent;data=a.data.resolve();engine=a.engine.resolve()
commit='624a67329fe2ad440c5b344785a9c73fcf22ae63'
for path in ['src/particles.h','src/types.h','src/tgl.h','src/useshader.h','src/SFMT.c','src/SFMT.h',
             'src/SFMT-params.h','src/SFMT-params19937.h',
             *['src/luajit2/src/'+f for f in ('lua.h','lauxlib.h','lualib.h','luaconf.h')]]:
    fixed=subprocess.check_output(['git','-C',str(engine),'show',commit+':'+path])
    assert (engine/path).read_bytes()==fixed, 'Build input differs from pinned source: '+path
# Use verified Lua 5.1/LuaJIT paths for every invocation, including embedded Lua.
env=dict(os.environ);rocks=Path(env.get('TOME_LUAROCKS_ROOT',str(Path.home()/'.local/share/tome4-luarocks')))
env['LUA_PATH']=str(rocks/'share/lua/5.1/?.lua')+';'+str(rocks/'share/lua/5.1/?/init.lua')+';;'
env['LUA_CPATH']=str(rocks/'lib/lua/5.1/?.so')+';;'
def run(cmd):
    r=subprocess.run([str(v) for v in cmd],capture_output=True,text=True,env=env)
    if r.returncode:raise RuntimeError(str(cmd)+'\n'+r.stdout[-2000:]+'\n'+r.stderr[-2000:])
    return r.stdout
flags=run(['sdl2-config','--cflags']).split();libs=run(['sdl2-config','--libs']).split()
cmd=['gcc','-std=gnu99','-O2','-g','-fno-omit-frame-pointer','-fgnu89-inline',
 '-I'+str(engine/'src'),'-I'+str(engine/'src/luajit2/src'),'-I'+str(data),*flags,
 here/'particles.c',engine/'src/SFMT.c','-l:libluajit-5.1.so.2',*libs,'-lm','-o',data/'particles']
r=subprocess.run([str(v) for v in cmd],capture_output=True,text=True,env=env)
(a.results/'compile.log').write_text(r.stdout+r.stderr)
if r.returncode:raise RuntimeError(r.stderr)
metadata={'machine':platform.machine(),'platform':platform.platform(),'compiler':run(['gcc','--version']).splitlines()[0],
 'luajit':run([env.get('TOME_LUAJIT','luajit'),'-v']).strip(),'compile_command':[str(v) for v in cmd],
 'input':json.loads((data/'manifest.json').read_text())}
(a.results/'environment.json').write_text(json.dumps(metadata,indent=2)+'\n')
def particle(group,mode,density=100,frames=3000,purge=0,trace=0):
    s=run([data/'particles',data/(group+'.lua'),data/mode,density,frames,purge,trace])
    return json.loads(s.splitlines()[-1]),s
# Check actual native particle states throughout the original visible lifespan.
for group,frames in [('notice',22),('dreamhammer',11)]:
    for density in (0,25,100):
        old,oldtrace=particle(group,'original',density,100,trace=1)
        new,newtrace=particle(group,'fixed',density,100,trace=1)
        assert oldtrace.splitlines()[:frames]==newtrace.splitlines()[:frames],(group,density,'visual state mismatch')
        assert old['final_alive']==1 and new['final_alive']==0
print('PASS native visual/lifetime checks at density 0, 25, 100',flush=True)
rows=[]
cases=[('world_notice','original',0),('world_notice','fixed',0),('orphan','original',0),('orphan','fixed',0),('orphan','fixed',1)]
for rep in range(5):
    # Reverse order on alternating runs to reduce systematic order bias.
    for group,mode,purge in (cases if rep%2==0 else list(reversed(cases))):
        row,_=particle(group,mode,purge=purge);row.update(group=group,mode=mode,purge=purge,rep=rep)
        rows.append(row)
    print('Particle repetition',rep+1,'complete',flush=True)
(a.results/'particles.json').write_text(json.dumps(rows,indent=2)+'\n')
for group,mode,purge in cases:
    selected=[r['cpu_us_per_keyframe'] for r in rows if (r['group'],r['mode'],r['purge'])==(group,mode,purge)]
    print(group,mode,'purge',purge,'median us/keyframe',statistics.median(selected),flush=True)
graph=[]
for rep in range(3):
    variants=['baseline','fearscape','inventory','both']
    for variant in (variants if rep%2==0 else list(reversed(variants))):
        row=json.loads(run([env.get('TOME_LUAJIT','luajit'),here/'graph.lua',data,variant,25]).splitlines()[-1])
        row['rep']=rep;graph.append(row)
    print('Graph repetition',rep+1,'complete',flush=True)
(a.results/'graph.json').write_text(json.dumps(graph,indent=2)+'\n')
for variant in ('baseline','both'):
    run([env.get('TOME_LUAJIT','luajit'),here/'graph.lua',data,variant,45,(a.results/(variant+'-samples.txt')).resolve()])
print('Saved timings and LuaJIT stack samples in',a.results,flush=True)
