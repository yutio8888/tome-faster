#!/usr/bin/env python3
"""Verify isolated experiment inputs and protected saves after measurement."""
from pathlib import Path
import hashlib
import json
import subprocess
import time
import zipfile

ROOT = Path(__file__).resolve().parent
WORKSPACE = ROOT.parent.parent
ADDON = WORKSPACE / 'game/addons/tome-faster'
EXPECTED_PLAN = '82ba2eede4edcf0c454a0ecafaada371c421493cb2b6a2fcdc79fa140398a2b3'
EXPECTED_COMMIT = '624a67329fe2ad440c5b344785a9c73fcf22ae63'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    assert digest(ROOT / 'acceptance-plan.json') == EXPECTED_PLAN
    plan = json.loads((ROOT / 'acceptance-plan.json').read_text())
    for rel, expected in plan['source_sha256'].items():
        assert digest(ROOT / rel) == expected, rel
    for rel, expected in plan['environment_sha256'].items():
        assert digest(WORKSPACE / rel) == expected, rel
    manifest = json.loads((WORKSPACE / 'test-saves/manifest.json').read_text())
    protected = []
    for row in manifest['files']:
        path = WORKSPACE / 'test-saves' / row['path']
        assert path.stat().st_size == row['bytes'] and digest(path) == row['sha256'], row['path']
        protected.append({'path': row['path'], 'bytes': row['bytes'], 'sha256': row['sha256']})
    assert digest(WORKSPACE / 'test-saves/backups/combat-ready.zip') == plan['save_sha256']
    assert digest(ADDON / 'dist/tome-faster.teaa') == plan['package_sha256']
    production = {}
    with zipfile.ZipFile(ROOT / 'frozen-0.2.11.teaa') as archive:
        assert archive.testzip() is None
        for name in archive.namelist():
            if name == 'init.lua' or name.startswith(('hooks/', 'superload/', 'overload/')):
                data = archive.read(name)
                assert (ADDON / name).read_bytes() == data, name
                production[name] = hashlib.sha256(data).hexdigest()
    commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=WORKSPACE, text=True).strip()
    assert commit == EXPECTED_COMMIT
    subprocess.run(['git', 'diff', '--exit-code'], cwd=WORKSPACE, check=True, capture_output=True)
    subprocess.run(['git', 'diff', '--cached', '--exit-code'], cwd=WORKSPACE, check=True, capture_output=True)
    owner = json.loads((ROOT / 'xvfb-owner.json').read_text())
    assert owner.get('exited') == 0
    output = dict(verified_unix_ns=time.time_ns(), acceptance_plan_sha256=EXPECTED_PLAN,
        source_files_verified=len(plan['source_sha256']), environment_files_verified=len(plan['environment_sha256']),
        protected_manifest_files_verified=len(protected), protected_files=protected,
        package_sha256=plan['package_sha256'], measured_and_current_package_byte_identical=True,
        production_files_sha256=production, production_files_byte_identical_to_measured_package=True,
        engine_commit=commit, tracked_engine_unchanged=True, owned_xvfb=owner,
        scope='Post-measurement integrity; no new production edits or package rebuild for this testing task.')
    (ROOT / 'integrity.json').write_text(json.dumps(output, indent=2) + '\n')
    print(json.dumps({k: v for k, v in output.items() if k not in ('protected_files', 'production_files_sha256')}))


if __name__ == '__main__':
    main()
