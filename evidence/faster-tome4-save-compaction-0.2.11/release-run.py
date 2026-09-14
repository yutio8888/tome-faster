#!/usr/bin/env python3
"""Measure normal saves on fresh disposable homes; keep original saves untouched."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time
import zipfile

ROOT = Path(__file__).resolve().parent
WORKSPACE = ROOT.parent.parent
DEPS = WORKSPACE / 'tmp/worktrees/yron-profile-20260912/tmp/profile/deps/root/usr'
SEEDS = WORKSPACE / 'tmp/combat-profile-20260913'
SAVE = WORKSPACE / 'test-saves/backups/combat-ready.zip'
EXPECTED_SAVE = '51d998a74cd09093bea1a3d5fcacb7ae8f689b1dc19f30f7fabed4d3b33157be'
EXPECTED_ENGINE = '5aa8fe5cfa8f0cde3aa82deb4602be95d8f7668e7d5d2ea4ce450cae18248dc7'

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def canonical_loaded_state(value):
    # engine.Entity.loaded (1.7.6 lines 211-218) assigns fresh UIDs on every load.
    # Preserve the bijection and repeated-UID aliases, not their numeric labels.
    ids={}
    def walk(item):
        if isinstance(item,dict):
            result={}
            for key in sorted(item):
                if key in ('uid','owner_uid') and isinstance(item[key],int) and not isinstance(item[key],bool):
                    ids.setdefault(item[key],len(ids)+1)
                    result[key]=ids[item[key]]
                else:
                    result[key]=walk(item[key])
            return result
        if isinstance(item,list):return [walk(x) for x in item]
        return item
    return walk(value)

def run(name, display):
    assert re.fullmatch('[a-zA-Z0-9_-]+', name)
    session = ROOT / 'sessions' / name
    session.mkdir(parents=True, exist_ok=False)
    candidate = name.startswith(('candidate-','resave-'))
    stock = name.startswith('stock-')
    bare = name.startswith('bare-') or stock
    experimental = candidate and 'experimental' in name
    fearscape = 'fearscape' in name
    compact = True
    reload_name = name[len('reload-'):] if name.startswith('reload-') else name[len('stock-'):] if stock else name[len('bare-'):] if bare else None
    source_name = reload_name or (name[len('resave-'):] if name.startswith('resave-') else None)
    home_root = WORKSPACE / 'test-saves/save-compaction-release-20260914'
    home = home_root / name / 'home'
    home.mkdir(parents=True, exist_ok=False)
    base = home / '.t-engine/4.0'
    assert digest(SAVE) == EXPECTED_SAVE
    if source_name:
        shutil.copytree(home_root / source_name / 'home/.t-engine/4.0/tome/save',base / 'tome/save')
    else:
        with zipfile.ZipFile(SAVE) as archive:
            assert archive.testzip() is None
            for info in archive.infolist():
                rel = Path(info.filename)
                assert not rel.is_absolute() and '..' not in rel.parts
                dest = base / 'tome/save' / rel
                if info.is_dir():
                    dest.mkdir(parents=True, exist_ok=True)
                else:
                    dest.parent.mkdir(parents=True, exist_ok=True)
                    dest.write_bytes(archive.read(info))
    desc = base / 'tome/save/yron/desc.lua'
    content = desc.read_text().replace("'combat-profile'", "'save-size-probe'")
    assert "'save-size-probe'" in content
    if bare:
        removable=['faster']
        if stock: removable+=['chn-mod','auto-loot-transmo-trans','improved_enemy_ui','danger-alert']
        for addon in removable:
            content=content.replace("'"+addon+"', ","")
            assert "'"+addon+"'" not in content
    desc.write_text(content)
    shutil.copytree(SEEDS / 'profile-seed', base / 'profiles')
    shutil.copytree(SEEDS / 'shader-cache-seed', session / 'mesa-cache')
    settings = base / 'settings'
    settings.mkdir(parents=True)
    (settings / 'save-size-probe.cfg').write_text('''cheat = true
audio.enable = false
window = {size="1280x800 Windowed"}
firstrun = true
firstrun_gdpr = true
disable_all_connectivity = true
allow_online_events = false
tome.upload_charsheet = false
tome.gfx = {tiles="shockbolt",size="64x64",tiles_custom_dir="",tiles_custom_moddable=false,tiles_custom_adv=false}
display_fps = 30
background_saves = true
faster_tome = {profile=false,stutter=false,session=false}
save_size_probe = {compact=true,candidate=%s,reload=%s,bare=%s,inventory=%s}
''' % ('true' if candidate else 'false','true' if reload_name else 'false','true' if bare else 'false','true' if 'inventory' in name and not name.startswith('resave-') else 'false'))
    if reload_name:
        with (settings / 'save-size-probe.cfg').open('a') as config:
            config.write('faster_tome.load_queue = false\n')
    with (settings / 'save-size-probe.cfg').open('a') as config:
        config.write('faster_tome.compact_save_names = ' + ('true' if compact else 'false') + '\n')
    with (settings / 'save-size-probe.cfg').open('a') as config:
        config.write('save_size_probe.experimental = '+('true' if experimental else 'false')+'\n')
        config.write('save_size_probe.fearscape = '+('true' if fearscape else 'false')+'\n')
        if experimental:
            config.write('faster_tome.compact_inventory = true\nfaster_tome.fearscape_cleanup = true\nfaster_tome.compact_save_names_base62 = true\n')
    if reload_name and fearscape:
        previous=json.loads((ROOT / 'sessions' / reload_name / 'result.json').read_text())
        report=next(record['report'] for record in previous['records'] if record.get('kind')=='fearscape_scenario')
        expected={key:report[key] for key in ('fixture_name','object_name','expect_cleanup')}
        expected['before']={'target':{'name':report['before']['target']['name']},'source':report['before']['source']}
        def lua(value):
            if value is None:return 'nil'
            if isinstance(value,bool):return 'true' if value else 'false'
            if isinstance(value,(int,float)):return repr(value)
            if isinstance(value,str):
                return '"'+''.join('\\%03d'%b if b<32 or b>=127 or b in (34,92) else chr(b) for b in value.encode())+'"'
            if isinstance(value,dict):return '{'+','.join('['+lua(k)+']='+lua(v) for k,v in value.items())+'}'
            raise TypeError(type(value))
        with (settings / 'save-size-probe.cfg').open('a') as config:
            config.write('save_size_probe.expected = '+lua(expected)+'\n')
    runtime = ROOT / ('runtime-stock' if stock else 'runtime-no-faster' if bare else 'runtime')
    if not bare:
        addon = runtime / 'game/addons/tome-faster.teaa'
        selected_package = ROOT / ('candidate.teaa' if candidate else 'baseline-0.2.10.teaa')
        if addon.exists(): addon.unlink()
        shutil.copy2(selected_package, addon)
    engine = runtime / 't-engine'
    assert digest(engine) == EXPECTED_ENGINE
    env = dict(os.environ)
    env.pop('LD_PRELOAD', None)
    env.update(DISPLAY=display, LIBGL_ALWAYS_SOFTWARE='1', ALSOFT_DRIVERS='null',
               LD_LIBRARY_PATH=str(DEPS / 'lib/x86_64-linux-gnu') + ':' + env.get('LD_LIBRARY_PATH', ''),
               MESA_SHADER_CACHE_DIR=str(session / 'mesa-cache'))
    command = [str(engine), '--no-steam', '--no-web', '--flush-stdout', '--home', str(home), '-Mtome', '-uyron']
    files = [Path(__file__)] + sorted((runtime / 'game/addons/tome-faster').rglob('*.lua'))
    archive_addon = runtime / 'game/addons/tome-faster.teaa'
    if archive_addon.is_file():
        files.append(archive_addon)
    files += sorted((runtime / 'game/addons/tome-save-size-probe').rglob('*.lua'))
    plan_path = ROOT / 'acceptance-plan.json'
    sequence = None
    plan_sha = None
    if plan_path.exists():
        plan_bytes = plan_path.read_bytes()
        plan_sha = hashlib.sha256(plan_bytes).hexdigest()
        plan = json.loads(plan_bytes)
        order = [session for pair in plan['pairs'] for session in pair['run_order']]
        if name in order: sequence = order.index(name) + 1
    meta = dict(measurement_sequence=sequence, acceptance_plan_sha256=plan_sha, started_unix_ns=time.time_ns(), command=command, engine_sha256=digest(engine), save_sha256=digest(SAVE),
                source_sha256={str(p.relative_to(ROOT)):digest(p) for p in files},
                home=str(home), save_files_before={str(p.relative_to(base / 'tome/save')):digest(p)
                    for p in (base / 'tome/save').rglob('*') if p.is_file()},
                host_load_start=os.getloadavg(), platform='Linux Xvfb llvmpipe', profiling=False,
                compact=compact,candidate=candidate,bare=bare,stock=stock,reload_from=reload_name,source_session=source_name,
                addon_sha256=digest(archive_addon) if archive_addon.is_file() else None)
    (session / 'input.json').write_text(json.dumps(meta, indent=2) + '\n')
    print('Starting ' + name, flush=True)
    started = time.monotonic()
    timed_out = False
    with (session / 'game.log').open('w') as log:
        process = subprocess.Popen(command, cwd=runtime, env=env, stdout=log, stderr=subprocess.STDOUT)
        (session / 'pid').write_text(str(process.pid) + '\n')
        try:
            process.wait(timeout=180)
        except subprocess.TimeoutExpired:
            timed_out = True
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
    content = (session / 'game.log').read_text(errors='replace')
    prefix = '[SaveSizeProbe] '
    records = [json.loads(line[len(prefix):]) for line in content.splitlines() if line.startswith(prefix)]
    after = {str(p.relative_to(base / 'tome/save')):digest(p) for p in (base / 'tome/save').rglob('*') if p.is_file()}
    result = dict(exit_code=process.returncode, timed_out=timed_out, records=records,
                  elapsed_s=time.monotonic()-started, host_load_end=os.getloadavg(),
                  save_files_unchanged=after == meta['save_files_before'],
                  lua_error=bool(re.search(r'Lua Error:|\[COROUTINE\] error', content)))
    result['complete'] = any(r.get('kind') == ('reload' if reload_name else 'complete') for r in records)
    result['archives'] = []
    for path in sorted((base / 'tome/save').rglob('*')):
        if path.is_file() and path.suffix in ('.teag','.teaz','.teaw','.teal'):
            with zipfile.ZipFile(path) as archive:
                assert archive.testzip() is None
                infos=archive.infolist()
                result['archives'].append(dict(name=str(path.relative_to(base / 'tome/save')),bytes=path.stat().st_size,
                    entries=len(infos),raw_bytes=sum(i.file_size for i in infos),compressed_bytes=sum(i.compress_size for i in infos),
                    compact_names=all(i.filename=='main' or bool(re.fullmatch('[a-zA-Z0-9_]+',i.filename)) for i in infos)))
    final_record=next((r for r in records if r.get('kind') in ('complete','reload')),None)
    if final_record:
        if reload_name:
            previous=json.loads((ROOT / 'sessions' / reload_name / 'result.json').read_text())
            expected=next(r['after'] for r in previous['records'] if r.get('kind')=='complete')
            result['game_state_equal']=canonical_loaded_state(final_record['state'])==canonical_loaded_state(expected)
            result['reload_uid_comparison']='Bijective renaming; stock Entity.loaded regenerates numeric UIDs.'
        else:
            result['game_state_equal']=final_record['before']==final_record['after']
    (session / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({k:v for k,v in result.items() if k not in ('records','archives')}), flush=True)
    if result['exit_code'] or timed_out or result['lua_error'] or not result['complete'] or not result.get('game_state_equal') or (reload_name and not result['save_files_unchanged']):
        print(json.dumps([r for r in records if r.get('kind') == 'error']), flush=True)
        raise SystemExit(1)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('names', nargs='*')
    parser.add_argument('--plan', action='store_true', help='run the frozen 30-pair plan exactly once')
    parser.add_argument('--display', default=':96')
    args = parser.parse_args()
    if args.plan:
        assert not args.names, 'plan and explicit sessions are mutually exclusive'
        plan=json.loads((ROOT / 'acceptance-plan.json').read_text())
        args.names=[session for pair in plan['pairs'] for session in pair['run_order']]
    assert args.names, 'provide session names or --plan'
    assert re.fullmatch(r':\d+', args.display)
    number = args.display[1:]
    assert not Path('/tmp/.X11-unix/X' + number).exists(), 'display is already in use'
    assert not Path('/tmp/.X' + number + '-lock').exists(), 'display lock exists'
    lock = (ROOT / 'session.lock').open('w')
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    env = dict(os.environ)
    env['LD_LIBRARY_PATH'] = str(DEPS / 'lib/x86_64-linux-gnu') + ':' + env.get('LD_LIBRARY_PATH', '')
    command = [str(DEPS / 'bin/Xvfb-local'), args.display, '-screen', '0', '1280x800x24',
               '-nolisten', 'tcp', '-ac', '-fp', str(DEPS / 'share/fonts/X11/misc')]
    with (ROOT / ('xvfb-' + args.names[0] + '.log')).open('w') as log:
        xvfb = subprocess.Popen(command, cwd=DEPS, env=env, stdout=log, stderr=subprocess.STDOUT)
        (ROOT / 'xvfb-owner.json').write_text(json.dumps(dict(pid=xvfb.pid, command=command)) + '\n')
        try:
            for _ in range(100):
                assert xvfb.poll() is None, 'Xvfb exited early'
                if Path('/tmp/.X11-unix/X' + number).exists():
                    break
                time.sleep(0.05)
            else:
                raise RuntimeError('Xvfb did not open the socket')
            for name in args.names:
                run(name, args.display)
        finally:
            if xvfb.poll() is None:
                xvfb.terminate()
                try:
                    xvfb.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    xvfb.kill()
                    xvfb.wait()
            (ROOT / 'xvfb-owner.json').write_text(json.dumps(dict(pid=xvfb.pid, exited=xvfb.returncode)) + '\n')

if __name__ == '__main__':
    main()
