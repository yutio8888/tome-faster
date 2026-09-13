#!/usr/bin/env python3
"""Run serial fresh-copy profiling experiments; all config and logs are retained."""
import argparse
import json
import hashlib
import os
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parent
cli = argparse.ArgumentParser(description=__doc__)
cli.add_argument('name')
cli.add_argument('--count', type=int, default=1)
cli.add_argument('--config', default='detail = true, actions = 60')
cli.add_argument('--settings', default='', help='Additional local game settings, Lua syntax.')
args = cli.parse_args()
for i in range(1, args.count+1):
    session = root/'sessions'/f'{args.name}-{i:02}'
    subprocess.run(['python3', '-B', str(root/'prepare-home.py'), str(session/'home')], check=True)
    config = session/'home/.t-engine/4.0/settings/profile.cfg'
    config.write_text(config.read_text().replace(
        'profile = true, session = false, idle_ms = 5000',
        'profile = false, stutter = true, '+args.config)+'\n'+args.settings+'\n')
    driver=root.parent.parent/'game/addons/tome-faster/overload/engine/FasterStutterSession.lua'
    (session/'driver.lua').write_bytes(driver.read_bytes())
    (session/'experiment.json').write_text(json.dumps({'config': args.config, 'settings': args.settings,
        'driver_sha256':hashlib.sha256(driver.read_bytes()).hexdigest(),
        'production_sha256': {name:hashlib.sha256((root.parent.parent/'game/addons/tome-faster'/name).read_bytes()).hexdigest()
            for name in ['init.lua','overload/engine/FasterClone.lua','overload/engine/FasterCloneRefresh.lua',
                'overload/engine/FasterSnapshotRefresh.lua','overload/engine/FasterScreenshot.lua','superload/mod/class/Game.lua']},
        'ld_preload':os.environ.get('LD_PRELOAD','')}, indent=2)+'\n')
    subprocess.run(['python3', '-B', str(root/'run-session.py'), str(session)], check=True)
