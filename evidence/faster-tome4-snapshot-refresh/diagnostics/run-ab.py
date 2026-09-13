import os,subprocess,json
from pathlib import Path
w=Path('/workspace/t-engine4/tmp/worktrees/yron-profile-20260912')
env=dict(os.environ,LD_PRELOAD=str(w/'tmp/profile/screenshot-probe.so'))
for experiment in ['snapshot','png','combined']:
    for pair in range(1,4):
        order=['after','before'] if pair%2 else ['before','after']
        for side in order:
            enabled=side=='after'
            snapshot=enabled and experiment in ['snapshot','combined']
            png=enabled and experiment in ['png','combined']
            config='detail=false, save_only=true, validate_save_state=true, snapshot_refresh_diagnostics=true, screenshot_diagnostics=true, screenshot_measure=true, screenshot_profile=true, snapshot_refresh='+str(snapshot).lower()+', screenshot_png='+str(png).lower()
            name=f'stutter-save-refresh-v1-{experiment}-{side}-pair{pair}'
            subprocess.run(['python3','tmp/profile/run-stutter-batch.py',name,'--config',config],cwd=w,env=env,check=True)
