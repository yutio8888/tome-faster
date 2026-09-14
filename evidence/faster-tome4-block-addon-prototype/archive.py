"""Inspect experimental carriers without executing saved Lua or bytecode."""
from pathlib import Path
import hashlib
import importlib.util
import sys
import zipfile

ROOT=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('block_save_literals',ROOT/'save_literals.py')
parser=importlib.util.module_from_spec(spec)
sys.modules[spec.name]=parser
spec.loader.exec_module(parser)
FORMAT='faster-carrier-block-v1'
MARKER='_faster_block_format'

def unpack(z):
    mark=parser.Parser(z.read(MARKER)).parse()
    assert mark=={'format':FORMAT,'version':1}
    meta=parser.Parser(z.read('main')).parse()
    assert meta['format']==FORMAT and meta['version']==1
    index=meta['index']
    assert len(index)==meta['object_count'] and 'main' in index
    records={}
    blocks=[]
    for block in sorted(set(index.values()),key=lambda x:int(x[6:])):
        carrier=parser.Parser(z.read(block)).parse()
        assert carrier['format']==FORMAT and carrier['version']==1
        count=0;size=0
        for name,body in carrier['records'].items():
            assert name not in records and index[name]==block and isinstance(body,str)
            records[name]=body.encode('latin1');count+=1;size+=len(records[name])
        blocks.append(dict(name=block,objects=count,body_bytes=size))
    assert set(records)==set(index) and len(blocks)==meta['block_count']
    assert sum(len(v) for v in records.values())==meta['body_bytes']
    expected={MARKER,'main',*(b['name'] for b in blocks)}
    native_names={n for n in z.namelist() if n.startswith('native_')}
    assert set(z.namelist())==expected|native_names
    native_equal=None
    if native_names:
        assert native_names=={'native_'+n for n in records}
        for name,body in records.items():
            assert z.read('native_'+name)==body,('native encoder mismatch',name)
        native_equal=True
    return records,dict(format=FORMAT,target=meta['target'],logical_objects=len(records),
        logical_body_bytes=meta['body_bytes'],blocks=len(blocks),block_sizes=blocks,
        native_byte_identical=native_equal,
        logical_body_sha256={name:hashlib.sha256(body).hexdigest() for name,body in records.items()})

def materialize(path):
    with zipfile.ZipFile(path) as z:
        records,summary=unpack(z)
    temporary=path.with_suffix('.materialized.tmp')
    with zipfile.ZipFile(temporary,'w',compression=zipfile.ZIP_DEFLATED,compresslevel=4) as z:
        for name,body in records.items():z.writestr(name,body)
    with zipfile.ZipFile(temporary) as z:
        assert z.testzip() is None and set(z.namelist())==set(records)
        for name,body in records.items():assert z.read(name)==body
    temporary.replace(path)
    return summary
