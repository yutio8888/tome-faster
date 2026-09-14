#!/usr/bin/env python3
"""Read-only exploratory accounting of all 30 already-frozen save pairs."""
import hashlib
import json
import math
from pathlib import Path
import statistics as st

HERE = Path(__file__).resolve().parent
DATA = HERE.parent / 'save-compaction-20260914'
METRICS = [
    'total_process_user_ms', 'total_process_system_ms', 'process_cpu_ms',
    'total_main_cpu_ms', 'other_threads_cpu_ms', 'sync_thread_user_ms',
    'sync_thread_system_ms', 'sync_cpu_ms', 'after_sync_main_cpu_ms',
    'sync_wall_ms', 'after_sync_wall_ms', 'total_wall_ms',
    'main_archive_bytes', 'main_raw_bytes', 'main_compressed_bytes',
]


def summary(xs, ys):
    delta = [y-x for x,y in zip(xs,ys)]
    logs = [math.log(y/x) for x,y in zip(xs,ys)]
    mean, sd = st.mean(logs), st.stdev(logs)
    pct = lambda x: 100 * math.expm1(x)
    return {
        'baseline_mean': st.mean(xs), 'candidate_mean': st.mean(ys),
        'baseline_median': st.median(xs), 'candidate_median': st.median(ys),
        'mean_paired_delta': st.mean(delta), 'sd_paired_delta': st.stdev(delta),
        'paired_geomean_change_pct': pct(mean),
        'exploratory_two_sided_95pct_ci_pct': [pct(mean + k*sd/math.sqrt(30)) for k in (-2.045229642132703,2.045229642132703)],
        'exploratory_one_sided_95pct_upper_pct': pct(mean + 1.6991270265334972*sd/math.sqrt(30)),
        'AB_mean_delta': st.mean(delta[::2]), 'BA_mean_delta': st.mean(delta[1::2]),
        'pairs_1_10_mean_delta': st.mean(delta[:10]),
        'pairs_11_20_mean_delta': st.mean(delta[10:20]),
        'pairs_21_30_mean_delta': st.mean(delta[20:]),
    }


def main():
    pairs, hashes = [], {}
    plan = json.loads((DATA/'acceptance-plan.json').read_text())
    for i, pair in enumerate(plan['pairs'], 1):
        loaded = []
        for variant in ('baseline','candidate'):
            name = pair[variant]
            result_path = DATA/'sessions'/name/'result.json'
            input_path = DATA/'sessions'/name/'input.json'
            raw = result_path.read_bytes()
            result = json.loads(raw)
            metadata = json.loads(input_path.read_text())
            assert result['exit_code'] == 0 and not result['timed_out'] and not result['lua_error']
            assert result['complete'] and result['game_state_equal']
            complete = [r for r in result['records'] if r.get('kind')=='complete']
            assert len(complete)==1
            record = {k:v for k,v in complete[0].items() if k not in ('before','after')}
            record['process_cpu_ms'] = record['total_process_user_ms'] + record['total_process_system_ms']
            record['other_threads_cpu_ms'] = record['process_cpu_ms'] - record['total_main_cpu_ms']
            record['after_sync_main_cpu_ms'] = record['total_main_cpu_ms'] - record['sync_cpu_ms']
            record['after_sync_wall_ms'] = record['total_wall_ms'] - record['sync_wall_ms']
            archive = next(a for a in result['archives'] if a['name']=='yron/game.teag')
            for old,new in [('bytes','main_archive_bytes'),('raw_bytes','main_raw_bytes'),('compressed_bytes','main_compressed_bytes')]:
                record[new] = archive[old]
            record['source_name'] = name
            record['measurement_sequence'] = metadata['measurement_sequence']
            record['started_unix_ns'] = metadata['started_unix_ns']
            record['host_load_start'] = metadata['host_load_start']
            record['elapsed_s'] = result['elapsed_s']
            hashes[name] = hashlib.sha256(raw).hexdigest()
            loaded.append(record)
        pairs.append({'pair':i,'order':'AB' if i%2 else 'BA','baseline':loaded[0],'candidate':loaded[1]})
    assert len(pairs)==30
    metrics = {key:summary([p['baseline'][key] for p in pairs],[p['candidate'][key] for p in pairs]) for key in METRICS}
    published = json.loads((DATA/'cpu-results.json').read_text())
    assert abs(metrics['total_process_user_ms']['paired_geomean_change_pct'] - published['metrics']['total_process_user_ms']['paired_geomean_change_pct']) < 1e-10
    deltas = {key:[p['candidate'][key]-p['baseline'][key] for p in pairs] for key in METRICS}
    corr = {x:{y:st.correlation(deltas[x],deltas[y]) for y in ['total_main_cpu_ms','other_threads_cpu_ms','sync_cpu_ms','after_sync_main_cpu_ms','total_wall_ms']}
            for x in ['total_process_user_ms','total_wall_ms']}
    result = {
        'type':'post-decision diagnostic only; no replacement or relaxation of the primary decision',
        'primary_decision_unchanged':published['decision'],
        'included_pairs':list(range(1,31)), 'excluded_pairs':[],
        'metrics':metrics, 'paired_delta_correlations':corr, 'pairs':pairs,
        'result_json_sha256':hashes,
        'accounting_identity':'process_user = main_user_plus_system + other_threads_user_plus_system - process_system',
        'interpretation_limits':[
            'after_sync_main_cpu is the interval after saveGame returned, including main-thread rendering/scheduling, not isolated doThread instruction time.',
            'other_threads_cpu includes save worker, llvmpipe and any other process threads; no thread IDs or isolated GL counters were captured.',
            'Main-thread user CPU at the end of doThread was not measured, so exact non-main user CPU cannot be recovered.',
            'Exploratory intervals and subgroups are post-hoc diagnostics, not additional acceptance tests or grounds for trimming.',
            'Correlation of process_user with other_threads_cpu is partly built into the accounting identity and is not causal evidence.',
        ],
    }
    (HERE/'failure-analysis-results.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps({key:metrics[key] for key in ['total_process_user_ms','total_main_cpu_ms','other_threads_cpu_ms','after_sync_main_cpu_ms']},indent=2))


if __name__=='__main__': main()
