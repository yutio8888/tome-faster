#!/usr/bin/env python3
"""Count in_inven IDs without executing serialized Lua or changing saves."""
import argparse
from collections import Counter
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import zipfile

scope = re.compile(rb'''"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|[{}\[\](),=]|[^\s{}\[\](),=]+''',re.S)

def inventory(value):
    tokens=scope.findall(value);at=0
    def take(expected=None):
        nonlocal at
        token=tokens[at];at+=1
        if expected is not None:assert token==expected,(token,expected)
        return token
    def parse():
        token=take()
        if token==b'{':
            fields=[]
            while tokens[at]!=b'}':
                take(b'[');k=parse();take(b']');take(b'=');v=parse();take(b',');fields.append((k,v))
            take(b'}');return ('table',fields)
        if token.startswith((b'"',b"'")):return ('string',token[1:-1])
        if token in (b'true',b'false'):return ('boolean',token==b'true')
        if token in (b'loadObject',b'loadstring'):
            take(b'(');arg=parse();take(b')');return ('reference' if token==b'loadObject' else 'function',arg[1])
        return ('number',float(token))
    result=parse();assert at==len(tokens);return result

def get(table,key):
    assert table[0]=='table'
    return next((v for k,v in table[1] if k==('string',key)),None)

def refs(value):
    if value[0]=='reference':return 1
    if value[0]=='table':return sum(refs(k)+refs(v) for k,v in value[1])
    return 0

def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('save',type=Path);ap.add_argument('output',type=Path)
    args=ap.parse_args()
    spec=importlib.util.spec_from_file_location('map_fields',Path(__file__).with_name('map-fields.py'))
    helper=importlib.util.module_from_spec(spec);spec.loader.exec_module(helper)
    paths=sorted(p for p in args.save.iterdir() if p.is_file());hashes={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
    totals=Counter();rows=[]
    for path in paths:
        if path.suffix not in ('.teag','.teaz'):continue
        counts=Counter()
        with zipfile.ZipFile(path) as archive:
            assert archive.testzip() is None
            for info in archive.infolist():
                if not info.filename.startswith('mod.class.Object-'):continue
                fields=helper.split_fields(archive.read(info))
                if 'in_inven' not in fields:continue
                a,b,raw=fields['in_inven'];inv=inventory(raw);counts['objects_with_in_inven']+=1;counts['raw_assignment_bytes']+=b-a
                id=get(inv,b'id')
                counts['id_'+(id[0] if id else 'missing')]+=1
                if id and id[0]=='table':
                    counts['inlined_inventory_reference_occurrences']+=refs(id)
                    inner_id=get(id,b'id')
                    counts['table_inner_id_'+(inner_id[0] if inner_id else 'missing')]+=1
                owner=get(inv,b'actor')
                if owner and owner[0]=='reference' and owner[1].startswith(b'mod.class.Player-'):counts['owner_is_player']+=1
        rows.append(dict(archive=path.name,**counts));totals.update(counts)
    assert hashes=={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
    out={'source_sha256':hashes,'source_unchanged':True,'totals':dict(totals),'archives':rows,
         'protocol':'Strict parse of in_inven values only, using the pinned encoder grammar. No Lua execution. Duplicate references count occurrences, not unique objects.',
         'limits':'An inner numeric inventory ID does not prove that replacing an arbitrary table is semantically safe; identity and current ownership require runtime validation.'}
    args.output.write_text(json.dumps(out,indent=2)+'\n');print(json.dumps(out['totals'],indent=2))

if __name__=='__main__':main()
