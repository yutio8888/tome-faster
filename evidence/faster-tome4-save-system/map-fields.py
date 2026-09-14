#!/usr/bin/env python3
"""Read-only field inventory; deletion deltas are counterfactual, not save edits."""
import argparse
from collections import Counter, defaultdict
import hashlib
import json
from pathlib import Path
import re
import zipfile
import zlib

# Consume all quoted strings, including escaped Lua bytecode, before finding
# another real top-level d["field"] assignment from the pinned native encoder.
TOKEN = re.compile(rb'''(?P<field>^d\["(?P<name>[^"\\]+)"\]=)|"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*' ''', re.M | re.S | re.X)
CELL = re.compile(rb'\[(\d+)\]=(true|false|[-+0-9.eE]+),\s*')
FIELDS = ('map','attrs','lites','seens','infovs','has_seens','remembers','particles','effects')
FLAGS = ('lites','seens','infovs','has_seens','remembers')

def deflate(raw):
    encoder=zlib.compressobj(4,zlib.DEFLATED,-15,8,zlib.Z_DEFAULT_STRATEGY)
    return encoder.compress(raw)+encoder.flush()

def split_fields(raw):
    spans=[m for m in TOKEN.finditer(raw) if m.group('field')]
    end=len(raw)-len(b'\nreturn d')
    assert raw.endswith(b'\nreturn d')
    result={}
    for i,m in enumerate(spans):
        nxt=spans[i+1].start() if i+1<len(spans) else end
        key=m.group('name').decode('utf-8')
        assert key not in result
        result[key]=(m.start(),nxt,raw[m.end():nxt])
    return result

def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('save',type=Path);ap.add_argument('output',type=Path)
    args=ap.parse_args();paths=sorted(p for p in args.save.iterdir() if p.is_file())
    hashes={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
    stats=defaultdict(lambda:dict(maps=0,raw_assignment_bytes=0,cells=0,value_types=Counter(),table_parse_complete=True))
    groups=defaultdict(lambda:dict(maps=0,raw_bytes=0,compressed_bytes=0,without_visibility_raw_bytes=0,without_visibility_compressed_bytes=0))
    for path in paths:
        if path.suffix not in ('.teag','.teaz','.teaw','.teal'):continue
        with zipfile.ZipFile(path) as archive:
            assert archive.testzip() is None
            for info in archive.infolist():
                # This audit deliberately targets the preserved pre-short-name dataset.
                if not info.filename.startswith('engine.Map-'):continue
                raw=archive.read(info);fields=split_fields(raw)
                assert fields['__CLASSNAME'][2].strip()==b'"engine.Map"'
                assert len(deflate(raw))==info.compress_size
                group=groups['game' if path.name=='game.teag' else 'history']
                group['maps']+=1;group['raw_bytes']+=len(raw);group['compressed_bytes']+=info.compress_size
                removes=[]
                for key in FIELDS:
                    if key not in fields:continue
                    a,b,value=fields[key];row=stats[key];row['maps']+=1;row['raw_assignment_bytes']+=b-a
                    if key not in FLAGS:continue
                    removes.append((a,b));v=value.strip();assert v.startswith(b'{') and v.endswith(b'}')
                    body=v[1:-1]
                    matches=list(CELL.finditer(body))
                    remainder=CELL.sub(b'',body).strip()
                    row['table_parse_complete'] &= not bool(remainder)
                    assert not remainder,(key,'unexpected value syntax')
                    for m in matches:
                        row['cells']+=1
                        text=m.group(2)
                        kind=text.decode() if text in (b'true',b'false') else 'number'
                        row['value_types'][kind]+=1
                transformed=raw
                for a,b in sorted(removes,reverse=True):transformed=transformed[:a]+transformed[b:]
                packed=deflate(transformed);assert zlib.decompress(packed,-15)==transformed
                group['without_visibility_raw_bytes']+=len(transformed)
                group['without_visibility_compressed_bytes']+=len(packed)
    assert hashes=={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
    output=dict(source_sha256=hashes,source_unchanged=True,fields=dict(stats),groups=dict(groups),
        protocol='Original preserved 0.2.8 saves, exact pinned native field grammar; no Lua execution. Raw DEFLATE level4/mem8 matches every original Map compressed size.',
        counterfactual='without_visibility deletes entire lites/seens/infovs/has_seens/remembers assignments in memory only. It destroys meaningful state, is not a proposed optimization or a measured packing saving, and is not a mathematical upper bound on compressibility.',
        limitations='No encoding/decoding CPU benchmark; only one supplied character; historical map saves are not all rewritten by a normal main save.')
    args.output.parent.mkdir(parents=True,exist_ok=True);args.output.write_text(json.dumps(output,indent=2)+'\n')
    print(json.dumps({k:output[k] for k in ('groups','fields','source_unchanged')},indent=2))

if __name__=='__main__':main()
