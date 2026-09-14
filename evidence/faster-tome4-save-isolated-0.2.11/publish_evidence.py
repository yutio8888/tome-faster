#!/usr/bin/env python3
"""Publish scalar evidence after full analysis, compatibility and integrity pass."""
from pathlib import Path
import hashlib
import json
import shutil

ROOT = Path(__file__).resolve().parent
WORKSPACE = ROOT.parent.parent
ADDON = WORKSPACE / 'game/addons/tome-faster'
DEST = ADDON / 'evidence/faster-tome4-save-isolated-0.2.11'
ACTIVE_CASES = ('base62-save', 'inventory-add', 'fearscape-exit')


def read(path):
    return json.loads(path.read_text())


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def record(result, kind):
    rows = [row for row in result['records'] if row.get('kind') == kind]
    assert len(rows) == 1
    return rows[0]


def write(name, value):
    (DEST / name).write_text(json.dumps(value, indent=2, allow_nan=False) + '\n')


def main():
    summary = read(ROOT / 'isolated-results.json')
    assert summary['validated_sessions'] == 300 and summary['validated_pairs'] == 150
    assert summary['validation']['partial_analysis'] is False
    assert all(value is True for key, value in summary['validation'].items() if key != 'partial_analysis')
    integrity = read(ROOT / 'integrity.json')
    assert integrity['protected_manifest_files_verified'] == 67
    assert integrity['measured_and_current_package_byte_identical'] is True
    assert integrity['production_files_byte_identical_to_measured_package'] is True
    compatibility = []
    for case in ACTIVE_CASES:
        source = f'{case}--candidate--p01'
        source_result = read(ROOT / 'sessions' / source / 'result.json')
        for prefix, mode in (('stock-', 'stock'), ('offload-', 'offload')):
            name = prefix + source
            directory = ROOT / 'sessions' / name
            inp, result = read(directory/'input.json'), read(directory/'result.json')
            assert inp['mode'] == mode and inp['source_session'] == source
            assert result['exit_code'] == 0 and result['complete'] and result['game_state_equal']
            assert result['save_files_unchanged'] and not result['lua_error'] and not result['timed_out']
            loaded = record(result, 'reload')
            assert loaded['original_loadReal'] is True and loaded['no_faster'] is (mode == 'stock')
            for archive in source_result['archives']:
                assert inp['save_files_before'][archive['name']] == archive['sha256']
            assert result['archives'] == source_result['archives']
            row = dict(session=name, case=case, mode=mode, source_session=source,
                       input_sha256=digest(directory/'input.json'), result_sha256=digest(directory/'result.json'),
                       source_archives_unchanged_before_and_after_reload=True,
                       semantic_projection_equal=True, stock_loadReal=True,
                       faster_modules_absent=loaded['no_faster'], production_options=inp['production_options'],
                       engine_sha256=inp['engine_sha256'], addon_sha256=inp['addon_sha256'],
                       source_sha256=inp['source_sha256'], archives=result['archives'])
            if case == 'fearscape-exit':
                checked = record(result, 'fearscape_reloaded')['report']
                assert checked['token_count'] == 1 and checked['trapper_absent'] is True
                assert checked['target_death_wrapper_absent'] and checked['returned_to_source_description']
                row['fearscape'] = {key: checked[key] for key in (
                    'token_count', 'trapper_absent', 'target_death_wrapper_absent', 'returned_to_source_description')}
            compatibility.append(row)
    timing, preflights = [], []
    for name in summary['execution_order']:
        directory = ROOT/'sessions'/name
        completed = record(read(directory/'result.json'), 'complete')
        timing.append(dict(session=name, result_sha256=digest(directory/'result.json'),
                           save_samples=completed['save_samples'], event_samples=completed['event_samples'],
                           event_order=completed['event_order'], empty_brackets=completed['empty_brackets'],
                           save_endpoint_after_sync=completed['save_endpoint_after_sync'],
                           save_endpoint_drained=completed['save_endpoint_drained']))
    for case in summary['cases']:
        for variant in ('baseline','candidate'):
            for tag in ('preflight','preflight2'):
                name=f'{case}--{variant}--{tag}'
                directory=ROOT/'sessions'/name
                inp, result=read(directory/'input.json'),read(directory/'result.json')
                assert result['exit_code']==0 and result['complete'] and result['game_state_equal']
                assert result['save_endpoint_valid'] and not result['lua_error'] and not result['timed_out']
                preflights.append(dict(session=name, input_sha256=digest(directory/'input.json'),
                    result_sha256=digest(directory/'result.json'), source_sha256=inp['source_sha256'],
                    valid=True, included_in_formal_samples=False))
    DEST.mkdir(parents=True, exist_ok=False)
    for filename in ('acceptance-plan.json','run.py','analyze_isolated.py','verify_integrity.py',
                     'render_report.py','publish_evidence.py','recompute_public.py','protocol-review.md',
                     'analyzer-review.md','results-review.md','public-recompute-check.json','integrity.json'):
        shutil.copy2(ROOT/filename,DEST/filename)
    shutil.copytree(ROOT/'probe',DEST/'probe')
    shutil.copytree(ROOT/'preformal-revision-1',DEST/'preformal-revision-1',
                    ignore=shutil.ignore_patterns('__pycache__','*.pyc'))
    write('compatibility.json', dict(sessions=compatibility,
        stock_scope='Only official gameplay DLCs and the diagnostic probe remain. The copied desc.lua nonofficial addon requirements were removed; serialized archives were never modified for reload.',
        offload_scope='Same 0.2.11 package with the three new options and load_queue disabled; the stock Savefile.loadReal implementation was checked.'))
    write('timing-samples.json',dict(sessions=timing,
        scope='Raw clock samples and 64 empty brackets per session; no player state. Empty brackets are not subtracted or interpreted as strict accuracy bounds.'))
    write('preflight-validity.json',dict(sessions=preflights,formal_samples=0))
    shutil.copy2(ROOT/'isolated-results.json',ADDON/'docs/save-isolated-results.json')
    print(json.dumps(dict(evidence=str(DEST),formal_sessions=len(timing),compatibility_sessions=len(compatibility),
                          preflight_sessions=len(preflights))))


if __name__ == '__main__':
    main()
