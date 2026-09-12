"""Read ToME serialized literals without evaluating Lua or loading bytecode."""
import re, io, json, hashlib, collections, argparse
from pathlib import Path
from zipfile import ZipFile
from dataclasses import dataclass
@dataclass(frozen=True)
class Ref:
    name: str
@dataclass(frozen=True)
class Opaque:
    name: str
TOKEN = re.compile(r'''\s+|"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?|[a-zA-Z_][a-zA-Z_0-9.]*|.''', re.S)
def string(s):
    s=s[1:-1]
    def sub(m):
        a=m[0][1:]
        if a.isdigit(): return chr(int(a))
        return {'n':'\n','r':'\r','t':'\t','a':'\a','b':'\b','f':'\f','v':'\v'}.get(a,a)
    return re.sub(r'\\(?:\d{1,3}|.)',sub,s,flags=re.S)
class Parser:
    def __init__(self,b):
        self.ts=[m[0] for m in TOKEN.finditer(b.decode('latin1')) if not m[0].isspace()]; self.i=0
    def pop(self):
        t=self.ts[self.i]; self.i+=1; return t
    def eat(self,t):
        got=self.pop()
        if got!=t: raise ValueError((self.i, 'expected',t,'got',repr(got)[:60]))
    def value(self):
        t=self.pop()
        if t=='{':
            v={}; idx=1
            while self.ts[self.i]!='}':
                if self.ts[self.i]=='[':
                    self.eat('['); k=self.value(); self.eat(']'); self.eat('=')
                else: k=idx; idx+=1
                v[k]=self.value()
                if self.ts[self.i] in (',',';'): self.pop()
                elif self.ts[self.i]!='}': raise ValueError(('table delimiter',self.i,self.ts[self.i]))
            self.eat('}'); return v
        if t[0] in ('"',"'"): return string(t)
        if t=='-': return -self.value()
        if t=='true': return True
        if t=='false': return False
        if t=='nil': return None
        if t[0].isdigit() or t[0]=='.': return float(t) if any(x in t for x in '.eE') else int(t)
        if self.i<len(self.ts) and self.ts[self.i]=='(':
            self.eat('('); args=[]
            while self.ts[self.i]!=')':
                args.append(self.value())
                if self.ts[self.i]==',': self.pop()
                elif self.ts[self.i]!=')': raise ValueError(('call delimiter',t,self.i))
            self.eat(')')
            if t=='loadObject': return Ref(args[0])
            return Opaque(t) # Includes serialized loadstring bytecode: never execute it.
        return Opaque(t)
    def parse(self):
        self.eat('d'); self.eat('='); d=self.value()
        if self.ts[self.i]=='setLoaded': self.value()
        while self.ts[self.i]=='d':
            self.eat('d'); self.eat('['); k=self.value(); self.eat(']'); self.eat('='); d[k]=self.value()
        self.eat('return'); self.eat('d')
        if self.i!=len(self.ts): raise ValueError(('trailing',self.i))
        return d

def refs(v):
    todo=[v]
    while todo:
        x=todo.pop()
        if isinstance(x,Ref): yield x.name
        elif isinstance(x,dict):
            todo.extend(x); todo.extend(x.values())
def walk(seeds,data,allow=lambda n:True,blocked=()):
    seen=set(); todo=list(seeds); blocked=set(blocked)
    while todo:
        n=todo.pop()
        if n in seen or n in blocked or n not in data or not allow(n): continue
        seen.add(n); todo.extend(refs(data[n]))
    return seen
if __name__=='__main__':
    cli=argparse.ArgumentParser(description=__doc__)
    cli.add_argument('save',type=Path)
    cli.add_argument('--output',type=Path,required=True)
    args=cli.parse_args()
    P=args.save
    if P.resolve() == args.output.resolve():
        cli.error('The report must not overwrite the input save.')
    out={'sha256':hashlib.sha256(P.read_bytes()).hexdigest(),'archives':{}}
    main=None; sizes=None
    with ZipFile(P) as z:
        out['outer_bytes']=sum(x.file_size for x in z.infolist()); out['outer_crc_error']=z.testzip()
        for f in z.namelist():
            if not f.endswith(('.teag','.teaz')): continue
            with ZipFile(io.BytesIO(z.read(f))) as a:
                size=sum(x.file_size for x in a.infolist())
                if size>256*1024*1024: raise ValueError('archive size budget exceeded')
                crc=a.testzip()
                parts={n:Parser(a.read(n)).parse() for n in a.namelist() if n.startswith('engine.Particles-')}
                out['archives'][f]={'entries':len(a.infolist()),'bytes':size,'crc_error':crc,'particles':dict(collections.Counter(d.get('def') for d in parts.values()))}
                if f.endswith('/game.teag'):
                    main={}; sizes={n:len(a.read(n)) for n in a.namelist()}
                    for n in a.namelist():
                        try: main[n]=Parser(a.read(n)).parse()
                        except Exception as e: raise ValueError((n,e))
        out['clone_log']=[line.decode('utf-8','replace') for line in z.read('yron/last_log.txt').split(b'\n') if b'[SAVEFILE PIPE] new save running' in line and b'(34235)' in line][-3:]
    player=next(n for n in main if n.startswith('mod.class.Player-'))
    trapper=main[player]['demon_plane_trapper'].name
    astar=main[trapper]['ai_state']['safe_grid']['Astar'].name
    mapid=main[astar]['map'].name
    m=main[mapid]
    level_maps={n:d['map'].name for n,d in main.items() if n.startswith('engine.Level-') and isinstance(d.get('map'),Ref)}
    direct=list(refs(m.get('particles',{})))
    allchain=walk([trapper],main,blocked=[player,'main'])
    particles={n for n in allchain if n.startswith('engine.Particles-')}
    # Include identity and field evidence only; no save bytecode is written out.
    out['fearscape']={'player':player,'trapper':trapper,'trapper_dead':main[trapper]['dead'],'astar':astar,'map':mapid,'size':[m['w'],m['h']], 'level_owners':[n for n,v in level_maps.items() if v==mapid], 'map_particle_count':len(direct),'map_particle_defs':dict(collections.Counter(main[n]['def'] for n in direct)), 'chain_particle_count':len(particles),'chain_particle_defs':dict(collections.Counter(main[n]['def'] for n in particles)), 'effect_durations':[d.get('duration') for d in m.get('effects',{}).values()]}
    out['level_particles']={n:{'map':mapid,'level':main[n].get('level'),'particles':len(list(refs(main[mapid].get('particles',{}))))} for n,mapid in level_maps.items()}
    out['current_level']=main['main']['level'].name
    out['current_level_e_array']=len(main[out['current_level']]['e_array'])
    out['current_level_entities']=len(main[out['current_level']]['entities'])
    out['game_entities']=len(main['main']['entities'])
    out['main_parsed_entries']=len(main)
    inventory=set(refs(main[player]['inven']))
    contained=walk(inventory,main,lambda n:n.startswith(('mod.class.Object-','mod.class.NPC-','engine.Entity-','engine.Particles-')))
    object_ids={n for n in contained if n.startswith('mod.class.Object-')}
    npc_ids={n for n in contained if n.startswith('mod.class.NPC-')}
    agate=next(n for n in inventory if main[n].get('name')=='alchemist agate')
    stack={agate,*refs(main[agate]['stacked'])}
    seeds={n for n in object_ids if 'demon' in main[n]}
    seed_graph=walk(seeds,main,lambda n:n.startswith(('mod.class.Object-','mod.class.NPC-','engine.Entity-','engine.Particles-')))
    out['inventory']={'direct_refs':len(inventory),'object_entries':len(object_ids),'npc_entries':len(npc_ids),
        'object_and_npc_bytes':sum(sizes[n] for n in object_ids|npc_ids),'agate_objects':len(stack),
        'agate_bytes':sum(sizes[n] for n in stack),'seed_objects':len(seeds),'seed_graph_bytes':sum(sizes[n] for n in seed_graph)}
    for n in out['level_particles']:
        ps=set(refs(main[main[n]['map'].name].get('particles',{})))
        for actor in refs(main[n]['entities']): ps.update(refs(main[actor].get('__particles',{})))
        out['level_particles'][n]['map_and_entity_particles']=len(ps)
    out['source_commit']='624a67329fe2ad440c5b344785a9c73fcf22ae63'
    out['inner_bytes']=sum(v['bytes'] for v in out['archives'].values())
    out['sha256_after']=hashlib.sha256(P.read_bytes()).hexdigest()
    assert out['sha256']==out['sha256_after'], 'Input changed during read-only audit'
    args.output.write_text(json.dumps(out,ensure_ascii=False,indent=2)+'\n')
    print('Verified archive CRCs; parsed', len(main), 'main entries without executing Lua.')
    print('Report:', args.output)
