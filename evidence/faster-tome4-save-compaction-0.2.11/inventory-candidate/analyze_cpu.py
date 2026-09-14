#!/usr/bin/env python3
"""Analyze the predeclared 30 paired saves without dropping or extending samples."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import statistics

# Student's t quantiles with 29 degrees of freedom, fixed by the 30-pair plan.
T95_ONE_SIDED = 1.6991270265334972
T95_TWO_SIDED = 2.045229642132703


def paired_summary(baseline, candidate):
    if len(baseline) != 30 or len(candidate) != 30:
        raise ValueError('exactly 30 complete pairs required; no optional stopping')
    for value in baseline + candidate:
        if not isinstance(value, (int, float)) or not math.isfinite(value) or value <= 0:
            raise ValueError('all timing values must be finite positive numbers')
    logs = [math.log(new / old) for old, new in zip(baseline, candidate)]
    mean_log = statistics.mean(logs)
    sd_log = statistics.stdev(logs)
    se_log = sd_log / math.sqrt(len(logs))
    upper_log = mean_log + T95_ONE_SIDED * se_log
    log_ci = (mean_log - T95_TWO_SIDED * se_log, mean_log + T95_TWO_SIDED * se_log)
    pct = lambda x: 100 * math.expm1(x)
    describe = lambda xs: {
        'mean_ms': statistics.mean(xs), 'median_ms': statistics.median(xs),
        'sd_ms': statistics.stdev(xs), 'min_ms': min(xs), 'max_ms': max(xs),
    }
    paired_changes = [100 * (new / old - 1) for old, new in zip(baseline, candidate)]
    return {
        'pairs': len(logs), 'baseline': describe(baseline), 'candidate': describe(candidate),
        'paired_geomean_change_pct': pct(mean_log),
        'paired_mean_delta_ms': statistics.mean(new - old for old, new in zip(baseline, candidate)),
        'paired_change_sd_percentage_points': statistics.stdev(paired_changes),
        'paired_log_ratio_sd': sd_log, 'paired_log_ratio_se': se_log,
        'two_sided_95pct_change_ci_pct': [pct(v) for v in log_ci],
        'one_sided_95pct_upper_change_pct': pct(upper_log),
        'passes_less_than_1pct_added_user_cpu': upper_log < math.log(1.01),
        'order_geomean_change_pct': {
            'AB': pct(statistics.mean(logs[0::2])),
            'BA': pct(statistics.mean(logs[1::2])),
        },
        'paired_values': [
            {'pair': index + 1, 'order': 'AB' if index % 2 == 0 else 'BA',
             'baseline_ms': old, 'candidate_ms': new, 'change_pct': change}
            for index, (old, new, change) in enumerate(zip(baseline, candidate, paired_changes))
        ],
    }


def load_record(session):
    result = json.loads((session / 'result.json').read_text())
    for key, expected in (('exit_code', 0), ('timed_out', False), ('lua_error', False),
                          ('complete', True), ('game_state_equal', True)):
        if key not in result or result[key] != expected:
            raise ValueError(f'{session.name}: invalid result {key}={result.get(key)!r}')
    complete = [r for r in result['records'] if r.get('kind') == 'complete']
    if len(complete) != 1:
        raise ValueError(f'{session.name}: exactly one completed save required')
    return complete[0], result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--plan', type=Path, required=True)
    parser.add_argument('--sessions', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    plan_bytes = args.plan.read_bytes()
    plan = json.loads(plan_bytes)
    pairs = plan['pairs']
    if len(pairs) != 30:
        raise ValueError('plan must have exactly 30 pairs')
    names = [name for row in pairs for name in row['run_order']]
    if len(set(names)) != 60:
        raise ValueError('sessions must be unique')
    invariant_inputs = None
    diagnostic_inputs = None
    variant_sources = {}
    records = []
    input_hashes = {}
    observed_starts = {}
    execution_order = [name for pair in pairs for name in pair['run_order']]
    for i, pair in enumerate(pairs):
        expected = [pair['baseline'], pair['candidate']]
        if i % 2:
            expected.reverse()
        if pair['run_order'] != expected:
            raise ValueError(f'pair {i + 1}: predeclared balanced AB/BA order required')
        loaded = []
        for variant in ('baseline', 'candidate'):
            name = pair[variant]
            if Path(name).name != name or name in ('.', '..'):
                raise ValueError('invalid session name')
            session = args.sessions / name
            input_bytes = (session / 'input.json').read_bytes()
            input_data = json.loads(input_bytes)
            if input_data['measurement_sequence'] != execution_order.index(name) + 1:
                raise ValueError(f'{name}: incorrect measurement sequence')
            if input_data['acceptance_plan_sha256'] != hashlib.sha256(plan_bytes).hexdigest():
                raise ValueError(f'{name}: plan changed during the cohort')
            observed_starts[name] = input_data['started_unix_ns']
            invariant = {key: input_data[key] for key in plan['invariant_input_fields']}
            if invariant_inputs is None:
                invariant_inputs = invariant
            elif invariant != invariant_inputs:
                raise ValueError(f'{name}: different engine/save input; cannot combine')
            sources = input_data['source_sha256']
            archive_key = plan['production_archive_source_key']
            package_hash = plan['variant_manifests'][variant]['production_archive_sha256']
            if not isinstance(package_hash, str) or not re.fullmatch('[0-9a-f]{64}', package_hash):
                raise ValueError(f'{variant}: production package SHA256 must be frozen in the plan')
            if sources.get(archive_key) != package_hash:
                raise ValueError(f'{name}: package SHA256 does not match the frozen {variant} package')
            production = {k: v for k, v in sources.items()
                          if k == archive_key or any(k.startswith(p) for p in plan['production_source_prefixes'])}
            diagnostic = {k: v for k, v in sources.items() if k not in production}
            if variant not in variant_sources:
                variant_sources[variant] = production
            elif production != variant_sources[variant]:
                raise ValueError(f'{name}: changed production inputs within {variant}')
            if diagnostic_inputs is None:
                diagnostic_inputs = diagnostic
            elif diagnostic != diagnostic_inputs:
                raise ValueError(f'{name}: changed diagnostic source inputs')
            input_hashes[name] = hashlib.sha256(input_bytes).hexdigest()
            record, result = load_record(session)
            loaded.append(record)
        records.append(loaded)
    if sorted(execution_order, key=observed_starts.get) != execution_order:
        raise ValueError('observed session start times do not follow the predeclared order')
    if min(observed_starts.values()) <= plan['declared_unix_ns']:
        raise ValueError('plan must be declared before all formal sessions')
    metrics = {}
    for metric in plan['metrics']:
        field = metric['field']
        metrics[field] = paired_summary([r[0][field] for r in records], [r[1][field] for r in records])
        metrics[field]['role'] = metric['role']
    primary = next(m['field'] for m in plan['metrics'] if m['role'] == 'primary')
    summary = {
        'plan_sha256': hashlib.sha256(plan_bytes).hexdigest(), 'comparison': plan['comparison'],
        'method': 'Paired log ratio; fixed 30 samples; Student t(df=29); no trimming; no extension.',
        'decision': 'pass' if metrics[primary]['passes_less_than_1pct_added_user_cpu'] else 'not_proven',
        'primary_metric': primary, 'metrics': metrics, 'input_sha256': input_hashes,
        'production_source_sha256': variant_sources, 'diagnostic_source_sha256': diagnostic_inputs,
        'limitations': [
            'Inference applies to this frozen save workload and measured host, not every character or platform.',
            'RUSAGE_SELF includes render/other process threads active while a save completes.',
            'The paired t interval assumes the paired log-ratio mean is approximately normally distributed.',
            'These timing results do not replace old-save, stock-reader, or lifecycle acceptance.',
        ],
    }
    args.output.write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps({'decision': summary['decision'], 'primary_metric': primary,
                      'change_pct': metrics[primary]['paired_geomean_change_pct'],
                      'upper_95pct_pct': metrics[primary]['one_sided_95pct_upper_change_pct']}, indent=2))


if __name__ == '__main__':
    main()
