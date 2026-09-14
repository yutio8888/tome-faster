#!/usr/bin/env python3
"""Single-factor game/save experiments on fresh, disposable homes."""
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
HOME_ROOT = WORKSPACE / 'test-saves/save-isolated-20260914'
EXPECTED_SAVE = '51d998a74cd09093bea1a3d5fcacb7ae8f689b1dc19f30f7fabed4d3b33157be'
EXPECTED_ENGINE = '5aa8fe5cfa8f0cde3aa82deb4602be95d8f7668e7d5d2ea4ce450cae18248dc7'
EXPECTED_ADDON = '9464fdfc425f53a238aa76ffc16853bd9c5e38df9d6e9b5519941b517f5d2f76'
CASES = {
    'base62-save': 'compact_save_names_base62',
    'inventory-idle': 'compact_inventory',
    'inventory-add': 'compact_inventory',
    'fearscape-idle': 'fearscape_cleanup',
    'fearscape-exit': 'fearscape_cleanup',
}
OFF = {key: False for key in ('compact_inventory', 'fearscape_cleanup', 'compact_save_names_base62')}
COMMON = dict(profile=False, stutter=False, session=False, compact_save_names=True,
              fbo_gc_guard=True, hit_warning_interval_ms=500)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def canonical_loaded_state(value):
    ids = {}
    def walk(item):
        if isinstance(item, dict):
            out = {}
            for key in sorted(item):
                if key in ('uid', 'owner_uid') and isinstance(item[key], int) and not isinstance(item[key], bool):
                    ids.setdefault(item[key], len(ids) + 1)
                    out[key] = ids[item[key]]
                else:
                    out[key] = walk(item[key])
            return out
        if isinstance(item, list):
            return [walk(x) for x in item]
        return item
    return walk(value)


def lua(value):
    if value is None:
        return 'nil'
    if isinstance(value, bool):
        return 'true' if value else 'false'
    if isinstance(value, (int, float)):
        return repr(value)
    if isinstance(value, str):
        return '"' + ''.join('\\%03d' % b if b < 32 or b >= 127 or b in (34, 92) else chr(b)
                             for b in value.encode()) + '"'
    if isinstance(value, dict):
        return '{' + ','.join('[' + lua(k) + ']=' + lua(v) for k, v in value.items()) + '}'
    raise TypeError(type(value))


def split_name(name):
    assert re.fullmatch('[a-zA-Z0-9_-]+', name)
    source = None
    mode = 'save'
    for prefix, candidate_mode in (('stock-', 'stock'), ('offload-', 'offload')):
        if name.startswith(prefix):
            source, mode = name[len(prefix):], candidate_mode
            break
    case, variant, tag = (source or name).split('--')
    assert case in CASES and variant in ('baseline', 'candidate')
    assert re.fullmatch('p[0-9]{2}|preflight[0-9]*', tag)
    return case, variant, tag, mode, source


def sources(runtime):
    files = [Path(__file__)] + sorted((runtime / 'game/addons/tome-save-size-probe').rglob('*.lua'))
    addon = runtime / 'game/addons/tome-faster.teaa'
    if addon.exists():
        files.append(addon)
    return {p.relative_to(ROOT).as_posix(): digest(p) for p in files}


def run(name, display, sequence=None, plan_sha=None):
    case, variant, tag, mode, source_name = split_name(name)
    session = ROOT / 'sessions' / name
    session.mkdir(parents=True, exist_ok=False)
    home = HOME_ROOT / name / 'home'
    home.mkdir(parents=True, exist_ok=False)
    base = home / '.t-engine/4.0'
    assert digest(SAVE) == EXPECTED_SAVE
    if source_name:
        shutil.copytree(HOME_ROOT / source_name / 'home/.t-engine/4.0/tome/save', base / 'tome/save')
    else:
        with zipfile.ZipFile(SAVE) as z:
            assert z.testzip() is None
            for info in z.infolist():
                rel = Path(info.filename)
                assert not rel.is_absolute() and '..' not in rel.parts
                dest = base / 'tome/save' / rel
                if info.is_dir():
                    dest.mkdir(parents=True, exist_ok=True)
                else:
                    dest.parent.mkdir(parents=True, exist_ok=True)
                    dest.write_bytes(z.read(info))
    desc = base / 'tome/save/yron/desc.lua'
    content = desc.read_text().replace("'combat-profile'", "'save-size-probe'")
    assert "'save-size-probe'" in content
    if mode == 'stock':
        for addon in ('faster', 'chn-mod', 'auto-loot-transmo-trans', 'improved_enemy_ui', 'danger-alert'):
            content = content.replace("'" + addon + "', ", '')
            assert "'" + addon + "'" not in content
    desc.write_text(content)
    shutil.copytree(SEEDS / 'profile-seed', base / 'profiles')
    shutil.copytree(SEEDS / 'shader-cache-seed', session / 'mesa-cache')
    options = dict(OFF)
    if mode == 'save' and variant == 'candidate':
        options[CASES[case]] = True
    production = dict(COMMON, **options)
    if mode != 'save':
        production['load_queue'] = False
    diagnostic = dict(case=case, variant=variant, expected_options=options,
                      reload=mode != 'save', bare=mode == 'stock')
    if source_name and case == 'fearscape-exit':
        previous = json.loads((ROOT / 'sessions' / source_name / 'result.json').read_text())
        report = next(r['report'] for r in previous['records'] if r['kind'] == 'fearscape_scenario')
        expected = {k: report[k] for k in ('fixture_name', 'object_name', 'expect_cleanup')}
        expected['before'] = {'target': {'name': report['before']['target']['name']},
                              'source': report['before']['source']}
        diagnostic['expected'] = expected
    settings = base / 'settings'
    settings.mkdir(parents=True)
    config = '''cheat = true
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
'''
    config += 'faster_tome = ' + lua(production) + '\n'
    config += 'save_size_probe = ' + lua(diagnostic) + '\n'
    (settings / 'save-size-probe.cfg').write_text(config)
    runtime = ROOT / ('runtime-stock' if mode == 'stock' else 'runtime')
    engine = runtime / 't-engine'
    assert digest(engine) == EXPECTED_ENGINE
    if mode != 'stock':
        assert digest(runtime / 'game/addons/tome-faster.teaa') == EXPECTED_ADDON
    env = dict(os.environ)
    env.pop('LD_PRELOAD', None)
    env.update(DISPLAY=display, LIBGL_ALWAYS_SOFTWARE='1', ALSOFT_DRIVERS='null',
               LD_LIBRARY_PATH=str(DEPS / 'lib/x86_64-linux-gnu') + ':' + env.get('LD_LIBRARY_PATH', ''),
               MESA_SHADER_CACHE_DIR=str(session / 'mesa-cache'))
    command = [str(engine), '--no-steam', '--no-web', '--flush-stdout', '--home', str(home), '-Mtome', '-uyron']
    before = {p.relative_to(base / 'tome/save').as_posix(): digest(p)
              for p in (base / 'tome/save').rglob('*') if p.is_file()}
    metadata = dict(case=case, variant=variant, mode=mode, production_options=production,
        measurement_sequence=sequence, acceptance_plan_sha256=plan_sha, started_unix_ns=time.time_ns(),
        command=command, home=str(home), source_session=source_name, source_sha256=sources(runtime),
        engine_sha256=EXPECTED_ENGINE, save_sha256=EXPECTED_SAVE,
        addon_sha256=None if mode == 'stock' else EXPECTED_ADDON,
        config_sha256=hashlib.sha256(config.encode()).hexdigest(), save_files_before=before,
        host_load_start=os.getloadavg(), platform='Linux x86_64 Xvfb llvmpipe', profiling=False)
    (session / 'input.json').write_text(json.dumps(metadata, indent=2) + '\n')
    print('Starting ' + name, flush=True)
    started, timed_out = time.monotonic(), False
    with (session / 'game.log').open('w') as log:
        process = subprocess.Popen(command, cwd=runtime, env=env, stdout=log, stderr=subprocess.STDOUT)
        (session / 'pid').write_text(str(process.pid) + '\n')
        try:
            process.wait(timeout=120)
        except subprocess.TimeoutExpired:
            timed_out = True
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill(); process.wait()
    content = (session / 'game.log').read_text(errors='replace')
    prefix = '[SaveSizeProbe] '
    records = [json.loads(line[len(prefix):]) for line in content.splitlines() if line.startswith(prefix)]
    after = {p.relative_to(base / 'tome/save').as_posix(): digest(p)
             for p in (base / 'tome/save').rglob('*') if p.is_file()}
    result = dict(exit_code=process.returncode, timed_out=timed_out, records=records,
        elapsed_s=time.monotonic()-started, host_load_end=os.getloadavg(), save_files_unchanged=after == before,
        lua_error=bool(re.search(r'Lua Error:|\[COROUTINE\] error', content)), archives=[])
    end_kind = 'complete' if mode == 'save' else 'reload'
    final = [r for r in records if r.get('kind') == end_kind]
    result['complete'] = len(final) == 1
    if len(final) == 1:
        if mode == 'save':
            result['game_state_equal'] = final[0]['before'] == final[0]['after']
            result['save_endpoint_valid'] = final[0]['save_endpoint_after_sync'] and final[0]['save_endpoint_drained']
        else:
            previous = json.loads((ROOT / 'sessions' / source_name / 'result.json').read_text())
            expected = next(r['after'] for r in previous['records'] if r['kind'] == 'complete')
            result['game_state_equal'] = canonical_loaded_state(final[0]['state']) == canonical_loaded_state(expected)
    for path in sorted((base / 'tome/save').rglob('*')):
        if path.is_file() and path.suffix in ('.teag', '.teaz', '.teaw', '.teal'):
            with zipfile.ZipFile(path) as z:
                assert z.testzip() is None
                infos = z.infolist()
                names = [i.filename for i in infos]
                assert len(names) == len(set(names)), 'duplicate archive names'
                assert names.count('main') == 1, 'archive needs exactly one main'
                result['archives'].append(dict(name=path.relative_to(base / 'tome/save').as_posix(),
                    bytes=path.stat().st_size, sha256=digest(path), entries=len(infos),
                    raw_bytes=sum(i.file_size for i in infos), compressed_bytes=sum(i.compress_size for i in infos),
                    crc_valid=True, unique_names=True, main_count=names.count('main'),
                    compact_names=all(n == 'main' or re.fullmatch('[a-zA-Z0-9_]+', n) is not None for n in names),
                    nondecimal_names=sum(n != 'main' and not n.isdigit() for n in names)))
    result['ended_unix_ns'] = time.time_ns()
    (session / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    valid = (result['exit_code'] == 0 and not timed_out and not result['lua_error'] and result['complete']
             and result.get('game_state_equal') and (mode != 'save' or result.get('save_endpoint_valid'))
             and (mode == 'save' or result['save_files_unchanged']))
    print(json.dumps({'session': name, 'valid': bool(valid), 'sequence': sequence}), flush=True)
    if not valid:
        raise SystemExit('Invalid session; preserve evidence and stop: ' + name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('names', nargs='*')
    parser.add_argument('--plan', action='store_true')
    parser.add_argument('--preflight', action='store_true')
    parser.add_argument('--display', default=':97')
    args = parser.parse_args()
    plan_sha = None
    if args.plan:
        assert not args.names and not args.preflight
        data = (ROOT / 'acceptance-plan.json').read_bytes()
        plan_sha = hashlib.sha256(data).hexdigest()
        plan = json.loads(data)
        args.names = plan['execution_order']
        assert len(args.names) == 300 and len(set(args.names)) == 300
        assert all(not (ROOT / 'sessions' / name).exists() for name in args.names)
    elif args.preflight:
        assert not args.names
        args.names = [f'{case}--{variant}--preflight' for case in CASES for variant in ('baseline', 'candidate')]
    assert args.names and re.fullmatch(r':\d+', args.display)
    assert not Path('/tmp/.X11-unix/X' + args.display[1:]).exists()
    assert not Path('/tmp/.X' + args.display[1:] + '-lock').exists()
    lock = (ROOT / 'session.lock').open('w')
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    env = dict(os.environ)
    env['LD_LIBRARY_PATH'] = str(DEPS / 'lib/x86_64-linux-gnu') + ':' + env.get('LD_LIBRARY_PATH', '')
    command = [str(DEPS / 'bin/Xvfb-local'), args.display, '-screen', '0', '1280x800x24',
               '-nolisten', 'tcp', '-ac', '-fp', str(DEPS / 'share/fonts/X11/misc')]
    with (ROOT / ('xvfb-' + args.names[0] + '.log')).open('w') as log:
        xvfb = subprocess.Popen(command, cwd=DEPS, env=env, stdout=log, stderr=subprocess.STDOUT)
        (ROOT / 'xvfb-owner.json').write_text(json.dumps({'pid': xvfb.pid, 'command': command}) + '\n')
        try:
            for _ in range(100):
                assert xvfb.poll() is None, 'Xvfb exited early'
                if Path('/tmp/.X11-unix/X' + args.display[1:]).exists():
                    break
                time.sleep(0.05)
            else:
                raise RuntimeError('Xvfb did not open socket')
            for index, name in enumerate(args.names, 1):
                run(name, args.display, index if args.plan else None, plan_sha)
        finally:
            if xvfb.poll() is None:
                xvfb.terminate()
                try:
                    xvfb.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    xvfb.kill(); xvfb.wait()
            (ROOT / 'xvfb-owner.json').write_text(json.dumps({'pid': xvfb.pid, 'exited': xvfb.returncode}) + '\n')


if __name__ == '__main__':
    main()
