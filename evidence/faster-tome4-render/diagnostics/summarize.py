#!/usr/bin/env python3
"""Export aggregate render evidence; never publish player logs or save data."""
import argparse
import json
from pathlib import Path
from statistics import median

cli = argparse.ArgumentParser(description=__doc__)
cli.add_argument('sessions', type=Path)
cli.add_argument('output', type=Path)
cli.add_argument('--map-prefix', default='stutter-map-v3')
cli.add_argument('--map-pixel-session', default='stutter-map-display-pixels-v5-01')
args = cli.parse_args()

def events(name):
    session = args.sessions / name
    process = json.loads((session / 'process.json').read_text())
    assert process['exit_code'] == 0 and process['completed'], name
    rows = []
    for line in (session / 'game.log').read_text().splitlines():
        if line.startswith('[Stutter] '):
            rows.append(json.loads(line[10:]))
    assert not any(r.get('kind') == 'diagnostic_failed' for r in rows), name
    return rows

def percentile(values, fraction):
    values = sorted(values)
    return values[min(len(values)-1, int((len(values)-1)*fraction))] if values else None

def phase(row):
    keys = ['phase', 'reason', 'wall_ms', 'cpu_ms', 'turn_delta', 'cache_stats', 'native_render']
    out = {k: row[k] for k in keys if k in row}
    out['records'] = row['records']
    out['actions'] = len(row['actions'])
    out['frames'] = len(row['frames_ms'])
    out['frame_p50_ms'] = percentile(row['frames_ms'], .5)
    out['frame_p95_ms'] = percentile(row['frames_ms'], .95)
    out['frame_max_ms'] = max(row['frames_ms']) if row['frames_ms'] else None
    return out

result = {
    'date': '2026-09-13', 'addon_version': '0.2.5',
    'engine_commit': '624a67329fe2ad440c5b344785a9c73fcf22ae63',
    'environment': {'runtime': 'embedded LuaJIT 2.0.2', 'display': 'Xvfb 1280x800 ~30 FPS',
                    'renderer': 'Mesa llvmpipe software rendering', 'hardware_gpu': False},
    'method': 'Fresh immutable-save copies, three alternating pairs, detail=false; only named option differs within each experiment.',
    'combat_caveat': 'RNG trajectories and action counts differ. Whole-combat speedup is not established by these samples.',
    'experiments': {},
}
for name, prefix in [('hotkeys', 'stutter-hotkeys-v1'), ('effect_mask', args.map_prefix)]:
    runs = []
    for pair in range(1, 4):
        for side in (['after', 'before'] if pair % 2 else ['before', 'after']):
            session = f'{prefix}-{side}-pair{pair}-01'
            runs.append({'session': session, 'pair': pair, 'side': side,
                         'process_completed': True,
                         'phases': [phase(r) for r in events(session) if r.get('kind') == 'phase_end' and r.get('phase') in ('move', 'combat')]})
    result['experiments'][name] = runs
hotkeys = result['experiments']['hotkeys']
summary = {}
for side in ('before', 'after'):
    rs = [p['records']['engine.HotkeysIconsDisplay.display'] for r in hotkeys if r['side'] == side for p in r['phases'] if p['phase'] == 'move']
    summary[side] = {'median_cpu_ms_per_call': median(r['cpu_ms']/r['calls'] for r in rs),
                     'median_total_cpu_ms': median(r['cpu_ms'] for r in rs), 'calls_per_run': [r['calls'] for r in rs]}
summary['cpu_per_call_reduction_percent'] = 100*(1-summary['after']['median_cpu_ms_per_call']/summary['before']['median_cpu_ms_per_call'])
result['hotkey_move_summary'] = summary
result['native_attribution'] = {}
for side, name in [('before', 'stutter-render-native-baseline-01'), ('after', 'stutter-render-native-optimized-01')]:
    result['native_attribution'][side] = [phase(r) for r in events(name) if r.get('kind') == 'phase_end' and r.get('phase') == 'move']
result['native_attribution']['caveat'] = 'Separate LD_PRELOAD attribution runs; use only stable-movement glyph work counts, not formal timing or map batch conclusions.'
result['full_frame_diagnostics'] = {}
for name, session, prefix in [
    ('glyphs', 'stutter-hotkeys-pixels-v2-01', '[HotkeysPixels] PASS '),
    ('hotkeys', 'stutter-hotkeys-display-pixels-v5-01', '[HotkeysDisplayPixels] PASS '),
    ('effect_mask', args.map_pixel_session, '[EffectMaskPixels] PASS '),
]:
    events(session)
    line = next(line for line in (args.sessions/session/'game.log').read_text().splitlines() if line.startswith(prefix))
    data = json.loads(line[len(prefix):])
    data.pop('frozen_native_tick', None)
    result['full_frame_diagnostics'][name] = {'session': session, 'process_completed': True, 'result': data}
args.output.write_text(json.dumps(result, indent=2) + '\n')
print(args.output)
