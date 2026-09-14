#!/usr/bin/env python3
"""Summarize all predefined production trials without player object graphs."""
import hashlib
import json
from pathlib import Path
import statistics
import sys

root = Path(sys.argv[1]) if len(sys.argv)>1 else Path(__file__).resolve().parent
order = ['baseline-01','compact-01','compact-02','baseline-02','baseline-03','compact-03','compact-04','baseline-04','baseline-05','compact-05']
for i in range(6,21):
    variants = ['compact','baseline'] if i%2==0 else ['baseline','compact']
    order.extend(f'{v}-{i:02d}' for v in variants)
rows=[]
for name in order:
    result=json.loads((root/'sessions'/name/'result.json').read_text())
    inp=json.loads((root/'sessions'/name/'input.json').read_text())
    complete=next(r for r in result['records'] if r['kind']=='complete')
    setup=next(r for r in result['records'] if r['kind']=='setup')
    assert result['exit_code']==0 and not result['timed_out'] and not result['lua_error'] and result['game_state_equal']
    main=next(a for a in result['archives'] if a['name']=='yron/game.teag')
    assert main['compact_names']==inp['compact']
    rows.append(dict(session=name, compact=inp['compact'], timings={k:v for k,v in complete.items() if k.endswith('_ms')},
        main_archive=main,zip_archives_checked=len(result['archives']),zip_entries_checked=sum(a['entries'] for a in result['archives']),
        game_state_equal=result['game_state_equal'],setup=setup,engine_sha256=inp['engine_sha256'],
        source_sha256=inp['source_sha256'],host_load_start=inp['host_load_start'],host_load_end=result['host_load_end']))
metrics=['sync_wall_ms','sync_cpu_ms','total_wall_ms','total_main_cpu_ms']
summary={}
for metric in ['main_archive_bytes']+metrics:
    def val(r):return r['main_archive']['bytes'] if metric=='main_archive_bytes' else r['timings'][metric]
    a=[val(r) for r in rows if not r['compact']];b=[val(r) for r in rows if r['compact']]
    am,bm=statistics.median(a),statistics.median(b)
    summary[metric]=dict(baseline_median=am,compact_median=bm,change_percent=(bm/am-1)*100,
        baseline_min=min(a),baseline_max=max(a),compact_min=min(b),compact_max=max(b),
        paired_differences=[y-x for x,y in zip(a,b)])
roundtrips=[]
for name in ['reload-compact-05','reload-baseline-05','resave-compact-05','reload-resave-compact-05']:
    result=json.loads((root/'sessions'/name/'result.json').read_text())
    assert result['exit_code']==0 and not result['lua_error'] and result['game_state_equal']
    if name.startswith('reload-'):assert result['save_files_unchanged']
    roundtrips.append(dict(session=name,exit_code=result['exit_code'],lua_error=result['lua_error'],
        game_state_equal=result['game_state_equal'],save_files_unchanged=result['save_files_unchanged'],
        original_loadReal=next((r.get('original_loadReal') for r in result['records'] if r['kind']=='reload'),None),
        zip_archives_checked=len(result['archives']),zip_entries_checked=sum(a['entries'] for a in result['archives'])))
output=dict(version='0.2.10',platform='Linux Xvfb llvmpipe, unchanged ToME 1.7.6 and embedded LuaJIT 2.0.2',
    protocol=dict(pairs=20,initial_pairs=5,extension_reason='High timing variance in the first five pairs; predefined 15 extra balanced pairs. All 20 reported.',
        order=order,preflights_excluded=['baseline-preflight','compact-preflight','reload-compact-preflight'],
        one_save_per_fresh_home=True,source_home_directory='test-saves/save-names-20260914',
        warmup='at least 30 display callbacks and 2 seconds',profiling=False,graphics_changed=False,
        variable='faster_tome.compact_save_names, same production addon on both sides'),
    summary=summary,rows=rows,roundtrips=roundtrips,
    scope=dict(real_game_state='Bounded recorded projection of player, actors and direct inventory; bijective UID renaming across reloads.',
        fixture_state='All fields and object aliases of the synthetic graphs through native serialization and stock loading.',
        timing='Synchronous call and complete original save pipeline including native writer completion; main-thread CPU excludes worker CPU.',
        all_calls_faster_claimed=False,windows_tested=False,steam_tested=False))
(root/'production-results.json').write_text(json.dumps(output,indent=2)+'\n')
print(json.dumps(summary,indent=2))
