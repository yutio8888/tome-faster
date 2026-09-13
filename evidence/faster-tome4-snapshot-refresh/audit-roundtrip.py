#!/usr/bin/env python3
"""Verify extra local graph/repeated-save/reload sessions, exporting counts only."""
import argparse
import importlib.util
import json
from pathlib import Path
import re

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('profile',type=Path)
parser.add_argument('decoder',type=Path)
parser.add_argument('output',type=Path)
args=parser.parse_args()
spec=importlib.util.spec_from_file_location('integrity',Path(__file__).with_name('audit-integrity.py'))
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
rows=[]
for name, saves in [('stutter-snapshot-refresh-final-graph-01',1),
                    ('stutter-snapshot-png-repeat-save-01',2),
                    ('snapshot-png-full-roundtrip-v2-20260913',1)]:
    session=args.profile/'sessions'/name
    process=json.loads((session/'process.json').read_text())
    log=(session/'game.log').read_text()
    assert process['exit_code']==0 and process['completed']
    assert log.count('[YronProfile] SESSION_COMPLETE')==1 and 'Lua Error:' not in log
    events=[json.loads(line[10:]) for line in log.splitlines() if line.startswith('[Stutter] ')]
    assert not any(row['kind']=='diagnostic_failed' for row in events)
    states=re.findall(r'^\[FasterSaveState\] equal=true actors=27 items=203 changed_sections=0 added_sections=0 removed_sections=0$',log,re.M)
    assert len(states)==saves
    phases=[row for row in events if row['kind']=='phase_end' and row['phase']!='warmup']
    assert sum(row['phase']=='save' for row in phases)==saves
    out=[]
    for phase in phases:
        if phase['phase'] in ('save','idle'): assert phase['turn_delta']==0
        record={key:phase[key] for key in ('phase','wall_ms','turn_delta')}
        record['actions']=len(phase.get('actions',[]))
        if phase['phase']=='save':
            record['screenshot_stats']=phase['screenshot_stats']
            record['snapshot_refresh_stats']=phase['snapshot_refresh_stats']
            assert record['snapshot_refresh_stats']['completed']
            assert not record['snapshot_refresh_stats']['fallback']
        out.append(record)
    savedir=session/'home/.t-engine/4.0/tome/save'
    archives=module.check_archives(savedir)
    png=module.check_png(next(savedir.rglob('cur.png')),args.decoder)
    row={'session':name,'completed':True,'selected_state_checks':saves,'phases':out,'archives':archives,'png':png}
    if 'roundtrip-v2' in name:
        assert any(r.get('kind')=='dialog' and r.get('phase')=='save' and 'forceWait' in r.get('trace','') for r in events)
        manifest=json.loads((session/'experiment.json').read_text())
        row['reload_input']={key:manifest[key] for key in ['input_sha256','input_source','input_files','all_input_files_match_source','includes_world_teaw']}
        row['force_wait_path_exercised']=True
        row['cross_reload_selected_comparison']='Separate UID-aware comparison is required; see reload-state-validation.json'
    rows.append(row)
result={'sessions':rows,'total_output_zip_crcs':sum(r['archives']['total_archives'] for r in rows),
        'total_output_png_decodes':len(rows),'selected_state_checks':sum(r['selected_state_checks'] for r in rows),
        'limit':'Repeated saves replace output files; only the final 23 archives of that session are counted. Timing is not formal A/B.'}
args.output.write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps({k:v for k,v in result.items() if k!='sessions'},indent=2))
