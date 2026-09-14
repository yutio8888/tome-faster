#!/usr/bin/env python3
"""Collect aggregate evidence; omit character states, objects, saves and binaries."""
import difflib
import hashlib
import json
from pathlib import Path
import shutil
import statistics
import zipfile

HERE = Path(__file__).resolve().parent
ADDON = HERE.parents[1]
WORKSPACE = ADDON.parents[2]
SCRATCH = WORKSPACE / 'tmp'


def read(path):
    return json.loads(path.read_text())


def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + '\n')


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main_archive(result):
    return next(a for a in result['archives'] if a['name'].endswith('/game.teag'))


def session(root, name):
    path = root / 'sessions' / name
    result, metadata = read(path / 'result.json'), read(path / 'input.json')
    for key, expected in [('exit_code', 0), ('timed_out', False), ('lua_error', False),
                          ('complete', True), ('game_state_equal', True)]:
        assert result[key] == expected, (name, key)
    timings = next((r for r in result['records'] if r['kind'] == 'complete'), None)
    setup = next(r for r in result['records'] if r['kind'] == 'setup')
    output = {
        'session': name,
        'input_sha256': sha(path / 'input.json'),
        'result_sha256': sha(path / 'result.json'),
        'measurement_sequence': metadata['measurement_sequence'],
        'started_unix_ns': metadata['started_unix_ns'],
        'acceptance_plan_sha256': metadata['acceptance_plan_sha256'],
        'engine_sha256': metadata['engine_sha256'],
        'save_sha256': metadata['save_sha256'],
        'addon_sha256': metadata['addon_sha256'],
        'source_sha256': metadata['source_sha256'],
        'setup': setup,
        'exit_code': result['exit_code'],
        'complete': result['complete'],
        'lua_error': result['lua_error'],
        'selected_game_state_equal': result['game_state_equal'],
        'save_files_unchanged': result['save_files_unchanged'],
        'main_archive': {k: v for k, v in main_archive(result).items() if k != 'name'},
        'archive_count_crc_checked': len(result['archives']),
        'all_archives_bytes': sum(a['bytes'] for a in result['archives']),
        'host_load_start': metadata['host_load_start'],
        'host_load_end': result['host_load_end'],
        'scope': 'State comparison is a bounded projection with UID alias normalization, not a whole real-save graph proof.',
    }
    if timings:
        output['timings'] = {k: v for k, v in timings.items()
                             if k.endswith('_ms') or k in ('runtime', 'kind')}
    reload_record = next((r for r in result['records'] if r['kind'] == 'reload'), None)
    if reload_record:
        output['reload'] = {k: v for k, v in reload_record.items() if k != 'state'}
    return output


def describe(values):
    return {'median': statistics.median(values), 'min': min(values), 'max': max(values)}


def collect_cohort(label, directory):
    root, output = SCRATCH / directory, HERE / label
    output.mkdir(exist_ok=True)
    plan, cpu = read(root / 'acceptance-plan.json'), read(root / 'cpu-results.json')
    names = [name for pair in plan['pairs'] for name in pair['run_order']]
    rows = [session(root, name) for name in names]
    for name in ('acceptance-plan.json', 'analyze_cpu.py', 'cpu-results.json', 'run.py'):
        shutil.copy2(root / name, output / name)
    shutil.copytree(root / 'probe', output / 'probe', dirs_exist_ok=True)
    write(output / 'session-metrics.json', rows)
    size = {}
    for variant in ('baseline', 'candidate'):
        selected = [r for r in rows if r['session'].startswith(variant + '-')]
        assert len(selected) == 30
        size[variant] = {
            key: describe([r['main_archive'][key] for r in selected])
            for key in ('bytes', 'entries', 'raw_bytes', 'compressed_bytes')
        }
        size[variant]['all_archives_bytes'] = describe([r['all_archives_bytes'] for r in selected])
    size['main_median_reduction_bytes'] = size['baseline']['bytes']['median'] - size['candidate']['bytes']['median']
    size['main_median_reduction_pct'] = 100 * size['main_median_reduction_bytes'] / size['baseline']['bytes']['median']
    write(output / 'size-results.json', size)
    return {'comparison': plan['comparison'], 'decision': cpu['decision'],
            'pairs': 30, 'sessions': 60, 'plan_sha256': cpu['plan_sha256'],
            'candidate_archive_sha256': plan['variant_manifests']['candidate']['production_archive_sha256'],
            'cpu': {name: {k: v for k, v in metric.items() if k != 'paired_values'}
                    for name, metric in cpu['metrics'].items()}, 'size': size,
            'evidence': f'evidence/faster-tome4-save-compaction-0.2.11/{label}/'}


def collect_fearscape():
    root = SCRATCH / 'save-fearscape-20260914'
    rows = []
    for name in ('baseline-check', 'candidate-check', 'bare-candidate-check'):
        row = session(root, name)
        original = read(root / 'sessions' / name / 'result.json')
        record = next(r for r in original['records'] if r['kind'] in ('fearscape_scenario', 'fearscape_reloaded'))
        report = record['report']
        after = report.get('after', report)
        row['scenario'] = {k: after[k] for k in (
            'same_target_identity', 'same_source_identity', 'same_token_identity', 'token_count',
            'original_target_callback_identity', 'original_caster_callback_identity',
            'target_death_wrapper_absent', 'returned_to_source_description', 'trapper_absent',
            'source_and_plane_are_distinct', 'plane_source_retained') if k in after}
        row['scenario'].update({k: report[k] for k in ('mode', 'stage', 'ok', 'expect_cleanup',
            'manually_changes_trapper', 'pumps_game_ticks') if k in report})
        if 'before' in report:
            row['scenario']['turn_unchanged'] = report['before']['turn'] == after['turn']
            row['scenario']['inventory_count_before'] = len(report['before']['inventory'])
            row['scenario']['inventory_count_after'] = len(after['inventory'])
            row['scenario']['ground_object_count_before'] = len(report['before']['loose_objects'])
            row['scenario']['ground_object_count_after'] = len(after['loose_objects'])
        rows.append(row)
    write(HERE / 'fearscape-results.json', {'sessions': rows, 'main_bytes_reduced':
        rows[0]['main_archive']['bytes'] - rows[1]['main_archive']['bytes'],
        'main_entries_reduced': rows[0]['main_archive']['entries'] - rows[1]['main_archive']['entries'],
        'scope': 'One real caster-death scenario. Only one NPC entry was removed; no whole-plane or CPU saving claim.',
        'astar_field_limit': 'The fixture diagnostic astar_map_present checks ai_state.astar, not stock ai_state.safe_grid.Astar.map. It is excluded from conclusions.'})
    shutil.copy2(root / 'run.py', HERE / 'fearscape-run.py')
    shutil.copytree(root / 'probe', HERE / 'fearscape-probe', dirs_exist_ok=True)


def collect_release():
    root = SCRATCH / 'save-compaction-release-20260914'
    names = ('candidate-default', 'stock-candidate-default', 'candidate-experimental-inventory',
        'stock-candidate-experimental-inventory', 'reload-candidate-experimental-inventory',
        'resave-candidate-experimental-inventory', 'stock-resave-candidate-experimental-inventory',
        'candidate-experimental-fearscape', 'stock-candidate-experimental-fearscape')
    rows = [session(root, name) for name in names]
    for row in rows:
        row.pop('timings', None)  # These checks are explicitly outside the CPU acceptance cohorts.
        assert row['setup']['fbo_gc_guard'] and row['setup']['hit_warning_interval_ms'] == 500
    assert rows[0]['setup']['sample_name_62'] == '62' and not rows[0]['setup']['experiments_enabled']
    assert rows[2]['setup']['sample_name_62'] == '10' and rows[2]['setup']['experiments_enabled']
    write(HERE / 'release-compatibility.json', {
        'sessions': rows, 'all_passed': True, 'formal_cpu_benchmark': False,
        'stock_runtime_addons': sorted(p.name for p in (root / 'runtime-stock/game/addons').iterdir()),
        'stock_scope': 'All nonofficial addons removed. Original official DLCs and a diagnostic probe retained. Only addon dependency names in desc.lua adjusted; serialized archive contents untouched.',
        'final_package_validation_archive_sha256': sha(root / 'candidate.teaa'),
    })
    shutil.copy2(root / 'final-production-manifest.json', HERE / 'final-production-manifest.json')
    shutil.copy2(root / 'run.py', HERE / 'release-run.py')
    shutil.copytree(root / 'probe', HERE / 'release-probe', dirs_exist_ok=True)
    changes = []
    with zipfile.ZipFile(SCRATCH / 'save-compaction-defaults-20260914/candidate.teaa') as before, zipfile.ZipFile(root / 'candidate.teaa') as after:
        for name in sorted(read(root / 'final-production-manifest.json')['source_sha256']):
            old, new = before.read(name).decode(), after.read(name).decode()
            if old != new:
                changes.extend(difflib.unified_diff(old.splitlines(True), new.splitlines(True),
                    fromfile='measured-candidate/' + name, tofile='release/' + name))
    (HERE / 'candidate-to-release.diff').write_text(''.join(changes))


def main():
    summary = {'version': '0.2.11', 'date': '2026-09-14',
        'release_decision': 'All three new experiments disabled by default; no general less-than-1% added user-CPU claim.',
        'defaults': {'compact_save_names': True, 'compact_save_names_base62': False,
            'compact_inventory': False, 'fearscape_cleanup': False,
            'fbo_gc_guard': True, 'hit_warning_interval_ms': 500},
        'cohorts': {label: collect_cohort(label, directory) for label, directory in (
            ('base62-candidate', 'save-compaction-20260914'),
            ('decimal-candidate', 'save-compaction-defaults-20260914'),
            ('inventory-candidate', 'save-inventory-20260914'))},
        'limitations': [
            'Each cohort has all 30 predeclared pairs; no trimming, pooling, or extra samples.',
            'Primary metric is save-interval RUSAGE_SELF utime, including worker, render and particle threads.',
            'Inventory additions and Fearscape entry/exit happen before save timing; their event CPU is unmeasured.',
            'Ordinary decimal-candidate results remain NOTPROVEN despite inventory-candidate passing.',
            'The released opt-in guards differ from the frozen measured candidates; only behavior/compatibility was rechecked on final code.',
            'Linux llvmpipe and one supplied old save; no Windows, hardware GPU or population-wide claim.',
        ]}
    write(ADDON / 'docs/save-compaction-results.json', summary)
    collect_fearscape()
    collect_release()
    independent = SCRATCH / 'save-compaction-acceptance-20260914'
    for name in ('independent-review.json', 'independent-results.json', 'final-review.md',
        'failure-analysis.md', 'failure-analysis-results.json', 'failure-analysis.py',
        'failure-analysis-compress.py', 'failure-analysis-compress-results.json',
        'failure-analysis-compress-protocol.json', 'check_reserved_stock.lua',
        'cpu_usage.lua', 'rusage_fixture.c', 'check_rusage.lua', 'test_analysis.py'):
        shutil.copy2(independent / name, HERE / name)
    tests = SCRATCH / 'save-compaction-20260914'
    for name in ('regression.log', 'regression-final.log', 'final-save_names-jit-off.log',
        'final-inventory_compact-jit-off.log', 'final-fearscape_cleanup-jit-off.log', 'final-save_load-jit-off.log'):
        shutil.copy2(tests / name, HERE / name)
    print(json.dumps({label: {'decision': row['decision'],
        'main_bytes_reduced': row['size']['main_median_reduction_bytes'],
        'main_pct_reduced': row['size']['main_median_reduction_pct']}
        for label, row in summary['cohorts'].items()}, indent=2))


if __name__ == '__main__':
    main()
