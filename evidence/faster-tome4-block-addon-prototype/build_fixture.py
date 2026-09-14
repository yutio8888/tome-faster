#!/usr/bin/env python3
from pathlib import Path
import hashlib
import json
import subprocess

ROOT=Path(__file__).resolve().parent
WORKSPACE=ROOT.parent.parent
source=(WORKSPACE/'src/serial.c').read_text()
build=ROOT/'native-fixture'
build.mkdir(exist_ok=True)
for name,first,last in (
    ('pinned_serial.c','static int serial_new(lua_State *L)','static int serial_order_realsave'),
    ('pinned_worker.c','int thread_save(void *data)','// Runs on main thread'),
):
    a=source.index(first);b=source.index(last,a)
    (build/name).write_text('\n'*source[:a].count('\n')+source[a:b])
pkg='luajit' if subprocess.run(['pkg-config','--exists','luajit']).returncode==0 else 'lua5.1'
flags=subprocess.check_output(['pkg-config','--cflags',pkg],text=True).split()
subprocess.run(['cc','-shared','-fPIC','-O2',*flags,'-I'+str(build),
    str(WORKSPACE/'game/addons/tome-faster/tests/save_callbacks_fixture.c'),
    '-o',str(build/'serial_fixture.so')],check=True)
encoder=ROOT/'runtime/game/addons/tome-save-size-probe/overload/engine/CarrierEncoder.lua'
for mode,options in (('jit',[]),('no-jit',['-joff'])):
    result=subprocess.run(['luajit',*options,str(ROOT/'test_encoder.lua'),
        str(build/'serial_fixture.so'),str(encoder)],text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    (ROOT/('encoder-'+mode+'.log')).write_text(result.stdout)
    print(result.stdout,end='')
    result.check_returncode()
(ROOT/'encoder-source.json').write_text(json.dumps({
    'serial_source_sha256':hashlib.sha256(source.encode()).hexdigest(),
    'encoder_sha256':hashlib.sha256(encoder.read_bytes()).hexdigest(),
    'scope':'Unchanged native serializer with in-memory queue sink; no compression or real game.'
},indent=2)+'\n')
