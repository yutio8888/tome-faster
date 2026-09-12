#!/usr/bin/env python3
"""Build isolated profiling inputs; never evaluate saved Lua or bytecode."""
import argparse, hashlib, importlib.util, io, json, subprocess, sys
from pathlib import Path
from zipfile import ZipFile
COMMIT='624a67329fe2ad440c5b344785a9c73fcf22ae63'
cli=argparse.ArgumentParser(description=__doc__)
for a in ('engine','save','out'): cli.add_argument('--'+a,type=Path,required=True)
cli.add_argument('--audit',type=Path,default=Path(__file__).with_name('save_literals.py'))
a=cli.parse_args(); a.out.mkdir(parents=True,exist_ok=True)
spec=importlib.util.spec_from_file_location('audit',a.audit)
m=importlib.util.module_from_spec(spec);sys.modules['audit']=m;spec.loader.exec_module(m)
def pinned(path):return subprocess.check_output(['git','-C',str(a.engine),'show',COMMIT+':'+path]).decode()
def section(s,start,end):return s[s.index(start):s.index(end,s.index(start))]
def quote(s):
    b=s.encode('latin1')
    return '"'+''.join(chr(c) if 32<=c<127 and c not in (34,92) else '\\%03d'%c for c in b)+'"'
def scalar(v, refs=False):
    if v is None:return 'nil'
    if isinstance(v,bool):return str(v).lower()
    if isinstance(v,(int,float)):return repr(v)
    if isinstance(v,str):return quote(v)
    if isinstance(v,m.Ref):
        assert refs and v.name in indexes,v
        return 'o[%d]'%indexes[v.name]
    if isinstance(v,m.Opaque):
        assert refs and v.name=='loadstring',v
        return 'inert()'
    if isinstance(v,dict):return '{'+','.join('['+scalar(k,refs)+']='+scalar(x,refs) for k,x in v.items())+'}'
    raise TypeError(v)
raw=a.save.read_bytes(); sha=hashlib.sha256(raw).hexdigest()
with ZipFile(io.BytesIO(raw)) as outer:
    assert outer.testzip() is None
    with ZipFile(io.BytesIO(outer.read('yron/game.teag'))) as z:
        assert z.testzip() is None
        data={n:m.Parser(z.read(n)).parse() for n in z.namelist()}
    with ZipFile(io.BytesIO(outer.read('yron/zone-wilderness.teaz'))) as z:
        world=[m.Parser(z.read(n)).parse() for n in z.namelist() if n.startswith('engine.Particles-')]
indexes={n:i for i,n in enumerate(data,1)}
player=next(n for n in data if n.startswith('mod.class.Player-'))
trapper=data[player]['demon_plane_trapper'].name
orphan=m.walk([trapper],data,blocked=[player,'main'])
particles=[data[n] for n in orphan if n.startswith('engine.Particles-')]
# Table identities and object references are retained. Saved functions are inert unique closures.
with (a.out/'graph.lua').open('w') as f:
    f.write('local o={}\nlocal token=0\nlocal function inert() token=token+1 local id=token return function() return id end end\n')
    for i in indexes.values():f.write('o[%d]={}\n'%i)
    for n,d in data.items():
        for k,v in d.items():f.write('o[%d][%s]=%s\n'%(indexes[n],scalar(k),scalar(v,True)))
    f.write('local root=o[%d]\n'%indexes['main'])
    f.write('setmetatable(root.entities,{__mode="v"})\n')
    f.write('for _,e in pairs(o) do if type(e.ai_target)=="table" then setmetatable(e.ai_target,{__mode="v"}) end if type(e.ai_actors_seen)=="table" then setmetatable(e.ai_actors_seen,{__mode="k"}) end end\n')
    f.write('return root\n')
# Only known definitions are run; source bytes always come from the fixed Git commit.
original=a.out/'original'; fixed=a.out/'fixed'
original.mkdir(exist_ok=True);fixed.mkdir(exist_ok=True)
for name in ('notice_enemy','dreamhammer','vapour','acid','melee_attack','circle'):
    text=pinned('game/modules/tome/data/gfx/particles/'+name+'.lua')
    (original/(name+'.lua')).write_text(text)
    if name in ('notice_enemy','dreamhammer'):
        assert text.rstrip().endswith('true')
        text=text.rstrip()[:-4]+'false\n'
    (fixed/(name+'.lua')).write_text(text)
def fixture(group,ps):
    parts=[]
    for p in ps:
        args=dict(p.get('args',{}));args.update(tile_w=64,tile_h=64)
        argstr='\n'.join(k+'='+scalar(v) for k,v in args.items())
        parts.append('{def='+quote(p['def'])+',args='+quote(argstr)+'}')
    (a.out/(group+'.lua')).write_text('return {'+','.join(parts)+'}\n')
fixture('orphan',sorted(particles,key=lambda p:p['def']))
fixture('world_notice',[p for p in world if p['def']=='notice_enemy'])
fixture('notice',[{'def':'notice_enemy','args':{}}])
fixture('dreamhammer',[{'def':'dreamhammer','args':{'tile':'shockbolt/object/dream_hammer','sx':0,'sy':0,'tx':1,'ty':1}}])
src=pinned('src/particles.c');rng=pinned('src/core_lua.c')
chunks=[section(src,'static void getinitfield','static int particles_flush_last'),
 section(src,'static void particles_update','// Runs into main thread\nstatic void particles_draw'),
 section(src,'static int particles_emit','static const struct luaL_Reg particleslib'),
 section(src,'void thread_particle_run','// Runs on particles thread\nextern int docall'),
 section(src,'void thread_particle_init','// Runs on particles thread\nint thread_particles'),
 section(rng,'static int rng_float','static int rng_dice'),section(rng,'static int rng_range','static int rng_avg')]
(a.out/'kernels.inc').write_text('/* Extracted verbatim from pinned ToME GPL-3.0-or-later sources. */\n'+'\n'.join(chunks))
# The clone function and its recursive implementation also run verbatim.
cl=pinned('game/engines/default/engine/class.lua')
(a.out/'clone.lua').write_text('local _M={}\n'+section(cl,'local function clonerecursfull','--- Clones the object, and all subobjects without cloning a subobject twice')+'\n'+section(cl,'function _M:cloneForSave()','--- Replaces the object with an other')+'\nreturn _M.cloneForSave\n')
manifest={'engine_commit':COMMIT,'save_sha256':sha,'main_entries':len(data),'orphan_emitters':len(particles),
 'world_notice_emitters':sum(p['def']=='notice_enemy' for p in world),'tile_size_assumption':64,
 'snapshot_limitations':['Serialized functions become unique inert closures; no saved bytecode is executed.','No loaded callbacks, native map/texture handles, runtime caches or class metatables.','Restores only known weak global entity and AI target/seen tables.','This is a serialized graph workload, not a full live game load or the logged 34235-object snapshot.'],
 'kernel_sha256':hashlib.sha256((a.out/'kernels.inc').read_bytes()).hexdigest()}
(a.out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
assert hashlib.sha256(a.save.read_bytes()).hexdigest()==sha
print(json.dumps(manifest,indent=2))
