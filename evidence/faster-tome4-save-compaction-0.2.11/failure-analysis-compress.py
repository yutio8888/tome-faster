#!/usr/bin/env python3
"""Fixed offline compression diagnostic; does not run the game or mutate a save."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import platform
import re
import resource
import statistics as st
import time
import zipfile
import zlib

HERE=Path(__file__).resolve().parent
WORKSPACE=HERE.parent.parent
PROTOCOL=HERE/'failure-analysis-compress-protocol.json'
RESULT=HERE/'failure-analysis-compress-results.json'
SOURCE=WORKSPACE/'test-saves/save-compaction-20260914/baseline-01/home/.t-engine/4.0/tome/save/yron/game.teag'


def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()


def base62(number):
    alphabet='0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'
    out=''
    while number:
        number,digit=divmod(number,62)
        out=alphabet[digit]+out
    if out=='main': return '_main'
    return out or '0'


# Match quoted strings as indivisible lexical units. A serialized bytecode or
# text string containing apparent calls is preserved verbatim, never executed.
LITERAL_OR_CALL=re.compile(rb'''(?P<call>\b(?:loadObject|setLoaded)\('(?P<number>[0-9]+)')|"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*' ''',re.X|re.S)


def remap(data, mapping):
    def replace(match):
        number=match.group('number')
        if number is None: return match.group(0)
        assert number.decode() in mapping, number
        return match.group('call')[:-(len(number)+1)]+mapping[number.decode()].encode()+b"'"
    return LITERAL_OR_CALL.sub(replace,data)


def datasets():
    with zipfile.ZipFile(SOURCE) as archive:
        assert archive.testzip() is None
        infos=archive.infolist()
        mapping={i.filename:base62(int(i.filename)) for i in infos if i.filename!='main'}
        assert all(i.filename=='main' or i.filename.isdigit() for i in infos)
        assert len(set(mapping.values()))==len(mapping) and 'main' not in mapping.values()
        decimal=[(i.filename,archive.read(i)) for i in infos]
    compact=[(mapping.get(name,name),remap(data,mapping)) for name,data in decimal]
    reverse={new:old for old,new in mapping.items()}
    # Independently reverse only callable lexical positions, preserving every
    # byte of all other state (including all serialized function payloads).
    undo=re.compile(rb'''(?P<call>\b(?:loadObject|setLoaded)\('(?P<name>[0-9A-Za-z_]+)')|"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*' ''',re.X|re.S)
    def restore(data):
        def replace(match):
            name=match.group('name')
            if name is None or name==b'main': return match.group(0)
            old=reverse[name.decode()].encode()
            return match.group('call')[:-(len(name)+1)]+old+b"'"
        return undo.sub(replace,data)
    assert all(oldname==reverse.get(newname,newname) and olddata==restore(newdata)
               for (oldname,olddata),(newname,newdata) in zip(decimal,compact))
    # Guard a fixture whose harmless string contains call-looking text.
    fake=b'''d['text']="loadObject('123')";setLoaded('123',d);'''
    assert remap(fake,{'123':'1Z'})==b'''d['text']="loadObject('123')";setLoaded('1Z',d);'''
    return {'decimal':decimal,'base62':compact}


def compress(entries):
    total=0
    for _,data in entries:
        stream=zlib.compressobj(4,zlib.DEFLATED,-15,8,zlib.Z_DEFAULT_STRATEGY)
        total+=len(stream.compress(data))+len(stream.flush())
    return total


def describe(values):
    return {'mean_ms':st.mean(values),'median_ms':st.median(values),'sd_ms':st.stdev(values),'min_ms':min(values),'max_ms':max(values)}


def prepare():
    assert not PROTOCOL.exists() and not RESULT.exists(), 'keep fixed protocol/results; do not rerun adaptively'
    plan={
        'declared_unix_ns':time.time_ns(), 'purpose':'isolate transformed input effect on main-archive compression CPU; not complete save CPU',
        'source':str(SOURCE),'source_sha256':sha(SOURCE), 'script_sha256':sha(Path(__file__)),
        'python':platform.python_version(),'zlib_build':zlib.ZLIB_VERSION,'zlib_runtime':zlib.ZLIB_RUNTIME_VERSION,
        'parameters':{'level':4,'method':'Z_DEFLATED','wbits':-15,'memLevel':8,'strategy':'Z_DEFAULT_STRATEGY'},
        'warmup_rounds_per_variant':2,'fixed_pairs':24,
        'pair_order':[['decimal','base62'] if i%2==0 else ['base62','decimal'] for i in range(24)],
        'measurement':'resource.getrusage(RUSAGE_SELF).ru_utime per full set of 2864 separate streams; setup/read/remap excluded',
        'limitations':['System Python zlib build, not the game executable zlib; Python calls and allocation included identically in both variants.',
                       'No Lua allocator, object traversal, CRC, ZIP metadata, I/O, scheduling or rendering measured.',
                       'No exclusion, extension or sequential retesting; all 24 pairs retained.'],
    }
    PROTOCOL.write_text(json.dumps(plan,indent=2)+'\n')
    print('Prepared '+str(PROTOCOL))


def run():
    assert PROTOCOL.exists() and not RESULT.exists()
    plan=json.loads(PROTOCOL.read_text())
    assert sha(SOURCE)==plan['source_sha256'] and sha(Path(__file__))==plan['script_sha256']
    assert zlib.ZLIB_RUNTIME_VERSION==plan['zlib_runtime']
    data=datasets()
    counts={}
    for name,entries in data.items():
        for _ in range(plan['warmup_rounds_per_variant']):
            size=compress(entries)
        counts[name]={'entries':len(entries),'raw_bytes':sum(len(d) for _,d in entries),
                      'compressed_payload_bytes':size,'zip_filename_bytes_local_plus_central':2*sum(len(n) for n,_ in entries),
                      'ordered_payload_sha256':hashlib.sha256(b''.join(d for _,d in entries)).hexdigest()}
    rows=[]
    for pair,order in enumerate(plan['pair_order'],1):
        row={'pair':pair,'order':order}
        for name in order:
            before=resource.getrusage(resource.RUSAGE_SELF)
            wall=time.perf_counter_ns()
            size=compress(data[name])
            elapsed=time.perf_counter_ns()-wall
            after=resource.getrusage(resource.RUSAGE_SELF)
            assert size==counts[name]['compressed_payload_bytes']
            row[name]={'user_ms':1000*(after.ru_utime-before.ru_utime),
                       'system_ms':1000*(after.ru_stime-before.ru_stime),'wall_ms':elapsed/1e6}
        rows.append(row)
    stats={}
    for metric in ['user_ms','system_ms','wall_ms']:
        a=[r['decimal'][metric] for r in rows];b=[r['base62'][metric] for r in rows]
        item={'decimal':describe(a),'base62':describe(b),'mean_paired_delta_ms':st.mean(y-x for x,y in zip(a,b))}
        if min(a+b)>0:
            logs=[math.log(y/x) for x,y in zip(a,b)]
            mean,se=st.mean(logs),st.stdev(logs)/math.sqrt(24)
            item['paired_geomean_change_pct']=100*math.expm1(mean)
            # t(23, .975) for a descriptive two-sided interval; no acceptance gate.
            item['two_sided_95pct_change_ci_pct']=[100*math.expm1(mean+k*se) for k in [-2.068657610419041,2.068657610419041]]
        stats[metric]=item
    result={'protocol_sha256':sha(PROTOCOL),'started_after_protocol':True,'all_pairs_kept':True,
            'datasets':counts,'statistics':stats,'pairs':rows,'not_complete_save_cpu':True}
    RESULT.write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps({'datasets':counts,'statistics':stats},indent=2))


if __name__=='__main__':
    cli=argparse.ArgumentParser(description=__doc__);cli.add_argument('action',choices=['prepare','run'])
    args=cli.parse_args();prepare() if args.action=='prepare' else run()
