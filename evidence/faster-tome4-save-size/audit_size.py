#!/usr/bin/env python3
"""Read-only size audit and in-memory representation/compression comparison."""
import argparse
from collections import defaultdict
import hashlib
import json
from pathlib import Path
import re
import statistics
import time
import zipfile
import zlib

# Quoted strings consume their entire contents, including escaped bytecode.
# Only actual serializer calls outside those strings are rewritten.
TOKEN = re.compile(rb'''"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|(?P<call>(?:setLoaded|loadObject)\(')(?P<name>[^']+)(?P<end>')''', re.S)

def rename(payload, names):
    def replace(match):
        if match.group('call'):
            return match.group('call') + names[match.group('name')] + match.group('end')
        return match.group()
    return TOKEN.sub(replace, payload)

def deflate(payload, level):
    comp = zlib.compressobj(level, zlib.DEFLATED, -15, 8, zlib.Z_DEFAULT_STRATEGY)
    return comp.compress(payload) + comp.flush()

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('save', type=Path)
    ap.add_argument('output', type=Path)
    args = ap.parse_args()
    files = sorted(p for p in args.save.iterdir() if p.is_file())
    hashes = {p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
    archives, groups = [], defaultdict(lambda:dict(entries=0, raw=0, compressed=0, headers=0))
    all_original, all_compact, game_original, game_compact = [], [], [], []
    for path in files:
        if path.suffix not in ('.teag','.teaz','.teal','.teaw','.teae'):
            continue
        with zipfile.ZipFile(path) as archive:
            assert archive.testzip() is None
            infos = archive.infolist()
            mapping = {info.filename.encode():str(i+1).encode() for i,info in enumerate(infos) if info.filename != 'main'}
            mapping[b'main'] = b'main'
            inverse = {value:key for key,value in mapping.items()}
            assert len(mapping) == len(inverse)
            old, new = [], []
            originals, compacts = [], []
            header_reduction = 0
            for info in infos:
                raw = archive.read(info)
                transformed = rename(raw, mapping)
                assert rename(transformed, inverse) == raw, 'name change did not round-trip'
                packed = deflate(raw, 4)
                assert len(packed) == info.compress_size, (path.name,info.filename,'baseline compression mismatch')
                compact_packed = deflate(transformed, 4)
                assert zlib.decompress(compact_packed, -15) == transformed
                old.append(len(packed));new.append(len(compact_packed))
                originals.append(raw);compacts.append(transformed)
                delta = len(info.filename.encode()) - len(mapping[info.filename.encode()])
                header_reduction += 2 * delta
                cls = info.filename.split('-0x')[0] if info.filename != 'main' else 'main'
                group = groups[cls]
                group['entries'] += 1;group['raw'] += len(raw);group['compressed'] += info.compress_size
                group['headers'] += 76 + 2 * len(info.filename.encode())
            row = dict(name=path.name,entries=len(infos),file_bytes=path.stat().st_size,
                raw_bytes=sum(map(len,originals)),compressed_bytes=sum(old),header_bytes=path.stat().st_size-sum(old),
                compact_raw_bytes=sum(map(len,compacts)),compact_compressed_bytes=sum(new),
                compact_header_bytes=path.stat().st_size-sum(old)-header_reduction,
                compact_file_bytes=path.stat().st_size-sum(old)-header_reduction+sum(new),
                byte_exact_after_inverse_rename=True)
            archives.append(row)
            all_original.extend(originals);all_compact.extend(compacts)
            if path.name == 'game.teag':game_original,game_compact = originals,compacts
    result = dict(source_sha256=hashes,zlib_version=zlib.ZLIB_RUNTIME_VERSION,
        files=[dict(name=p.name,bytes=p.stat().st_size) for p in files],archives=archives,
        classes=sorted([dict(name=k,**v) for k,v in groups.items()],key=lambda x:x['compressed']+x['headers'],reverse=True),
        total_bytes=sum(p.stat().st_size for p in files),
        compact_total_bytes=sum(p.stat().st_size for p in files)-sum(a['file_bytes']-a['compact_file_bytes'] for a in archives),
        protocol='In-memory raw DEFLATE, memLevel 8, default strategy. Two warmups, seven rotating rounds, each phase measured once per round. Excludes serialization, rename work, CRC, ZIP headers, disk, game scheduling and cloud.',
        compression=[])
    phases=[('level1',1,False),('level4',4,False),('level6',6,False),('level9',9,False),('compact_level4',4,True)]
    for dataset,original,compact in [('game',game_original,game_compact),('all_archives',all_original,all_compact)]:
        def run(phase):
            _,level,renamed=phase
            data=compact if renamed else original
            cpu,wall=time.process_time_ns(),time.perf_counter_ns()
            size=sum(len(deflate(payload,level)) for payload in data)
            return dict(cpu_ms=(time.process_time_ns()-cpu)/1e6,wall_ms=(time.perf_counter_ns()-wall)/1e6,compressed_bytes=size)
        for _ in range(2):
            for phase in phases:run(phase)
        measurements=defaultdict(list)
        for round_index in range(7):
            for offset in range(len(phases)):
                phase=phases[(round_index+offset)%len(phases)]
                measurements[phase[0]].append(dict(round=round_index+1,**run(phase)))
        for name,rows in measurements.items():
            result['compression'].append(dict(dataset=dataset,variant=name,
                median_cpu_ms=statistics.median(r['cpu_ms'] for r in rows),
                median_wall_ms=statistics.median(r['wall_ms'] for r in rows),compressed_bytes=rows[0]['compressed_bytes'],raw=rows))
    assert hashes == {p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
    result['source_unchanged']=True
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps({k:v for k,v in result.items() if k in ('total_bytes','compact_total_bytes','source_unchanged')}),flush=True)
    for row in result['compression']:
        print(row['dataset'],row['variant'],round(row['median_cpu_ms'],2),'ms',row['compressed_bytes'],'bytes',flush=True)

if __name__ == '__main__':main()
