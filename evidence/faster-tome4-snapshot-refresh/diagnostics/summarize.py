#!/usr/bin/env python3
"""Export numeric evidence from disposable sessions, excluding private save data."""
import argparse
import hashlib
import json
from pathlib import Path
from statistics import median

cli = argparse.ArgumentParser(description=__doc__)
cli.add_argument('sessions', type=Path)
cli.add_argument('addon', type=Path)
cli.add_argument('output', type=Path)
args = cli.parse_args()

def events(name):
    directory = args.sessions / name
    process = json.loads((directory / 'process.json').read_text())
    assert process['completed'] and process['exit_code'] == 0, name
    log = (directory / 'game.log').read_text()
    assert '[YronProfile] SESSION_COMPLETE' in log, name
    rows = [json.loads(line[10:]) for line in log.splitlines() if line.startswith('[Stutter] ')]
    assert not any(r['kind'] == 'diagnostic_failed' for r in rows), name
    return rows, log

result = {
    'date': '2026-09-13', 'addon_version': '0.2.6',
    'engine_commit': '624a67329fe2ad440c5b344785a9c73fcf22ae63',
    'environment': {'runtime': 'embedded LuaJIT 2.0.2', 'renderer': 'Mesa llvmpipe',
                    'display': 'Xvfb 1280x800, approximately 30 FPS', 'hardware_gpu': False},
    'method': {
        'pairs_per_experiment': 3,
        'order': ['after, before', 'before, after', 'after, before'],
        'input': 'A fresh copy of the same immutable imported save for every run',
        'input_sha256': 'eac52e4bd612b2ec6477f71bae12b7844c3e8031813df2ad89fe6fac2c1915a7',
        'detail': False,
        'baseline': 'All 0.2.5 optimizations enabled; both new options disabled',
        'snapshot': 'Only snapshot_refresh enabled on after side',
        'png': 'Only screenshot_png enabled on after side',
        'combined': 'Both snapshot_refresh and screenshot_png enabled on after side',
        'timing': 'Main-thread CPU, wall clocks, original Game.saveGame and Game.takeScreenshot boundaries',
        'presentation': 'SDL_GL_SwapWindow call-entry intervals including first/tail; not GPU completion or input latency',
        'probe': 'Only native swap scope enabled. No wrapped native getScreenshot or forceRedraw, no glFinish or pixel readback probe.',
        'gc': 'Original game GC behavior; no diagnostic GC pause in formal runs',
        'selected_state_scope': 'Legacy actors counter selects entities with talents, including inventory Objects. The reload sample is 1 Player, 12 NPCs and 14 Objects; 203 inventory entries is not a claim of unique objects.',
        'caveat': 'Three samples on one software-rendered Linux machine; not a guarantee for other hardware or Windows',
    },
    'production_sha256': None,
    'experiments': {}, 'summaries': {},
}
for experiment in ['snapshot', 'png', 'combined']:
    runs = []
    for pair in range(1, 4):
        for side in (['after', 'before'] if pair % 2 else ['before', 'after']):
            name = f'stutter-save-refresh-v1-{experiment}-{side}-pair{pair}-01'
            rows, log = events(name)
            directory = args.sessions / name
            manifest = json.loads((directory / 'experiment.json').read_text())
            hashes = manifest['production_sha256']
            for path, value in hashes.items():
                assert hashlib.sha256((args.addon / path).read_bytes()).hexdigest() == value, path
            if result['production_sha256'] is None:
                result['production_sha256'] = hashes
                result['formal_driver_sha256'] = manifest['driver_sha256']
            assert result['production_sha256'] == hashes
            assert result['formal_driver_sha256'] == manifest['driver_sha256']
            state = '[FasterSaveState] equal=true actors=27 items=203 changed_sections=0 added_sections=0 removed_sections=0'
            assert log.count(state) == 1, name
            saves = [r for r in rows if r['kind'] == 'phase_end' and r['phase'] == 'save']
            assert len(saves) == 1 and saves[0]['turn_delta'] == 0, name
            row = saves[0]
            swap = row['native_screenshot']['swaps']['save_phase']
            records = row['records']
            metric = {'save_phase_wall_ms': row['wall_ms'], 'save_phase_cpu_ms': row['cpu_ms'],
                'synchronous_save_wall_ms': records['mod.class.Game.saveGame']['wall_ms'],
                'synchronous_save_cpu_ms': records['mod.class.Game.saveGame']['cpu_ms'],
                'screenshot_wall_ms': records['mod.class.Game.takeScreenshot']['wall_ms'],
                'screenshot_cpu_ms': records['mod.class.Game.takeScreenshot']['cpu_ms'],
                'max_game_display_interval_ms': max(row['frames_ms']),
                'max_swap_entry_interval_ms': swap['max_interval_ms'],
                'screenshot_png_bytes': (directory/'home/.t-engine/4.0/tome/save/yron/cur.png').stat().st_size}
            runs.append({'session': name, 'pair': pair, 'side': side, 'completed': True,
                'selected_state_equal': True, 'actors': 27, 'items': 203, 'turn_delta': 0,
                'metrics': metric, 'swap': swap, 'screenshot_stats': row['screenshot_stats'],
                'snapshot_refresh_stats': row.get('snapshot_refresh_stats')})
    result['experiments'][experiment] = runs
    summary = {}
    for side in ['before', 'after']:
        subset = [r for r in runs if r['side'] == side]
        summary[side] = {key: median(r['metrics'][key] for r in subset) for key in subset[0]['metrics']}
    summary['reduction_percent'] = {key: 100*(1-summary['after'][key]/summary['before'][key]) for key in summary['before']}
    result['summaries'][experiment] = summary

graph, _ = events('stutter-snapshot-refresh-final-graph-01')
result['graph_equivalence'] = next(r['result'] for r in graph if r['kind'] == 'diagnostic_result')
assert result['graph_equivalence']['passed']
result['png_pixel_equivalence'] = json.loads((args.sessions/'stutter-screenshot-pixels-v3-01/png-pixel-validation.json').read_text())
args.output.write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result['summaries'], indent=2))
