#!/usr/bin/env python3
"""Independently recompute every reported timing interval from public 30-pair values."""
import argparse
import json
import math
from pathlib import Path
import statistics


def close(left, right):
    assert math.isclose(left, right, rel_tol=1e-10, abs_tol=1e-9), (left, right)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--results', type=Path, required=True)
    args = parser.parse_args()
    data = json.loads(args.results.read_text())
    assert data['validated_sessions'] == 300 and data['validated_pairs'] == 150
    t_one, t_two = 1.6991270265334972, 2.045229642132703
    checked = 0
    decisions = {}
    for case, row in data['cases'].items():
        pairs = row['paired_values']
        assert len(pairs) == 30 and [x['pair'] for x in pairs] == list(range(1, 31))
        for field, reported in row['metrics'].items():
            a = [p['baseline']['metrics'][field] for p in pairs]
            b = [p['candidate']['metrics'][field] for p in pairs]
            assert all(math.isfinite(x) and x >= 0 for x in a+b)
            close(statistics.mean(a), reported['baseline']['mean_ms'])
            close(statistics.mean(b), reported['candidate']['mean_ms'])
            close(statistics.median(a), reported['baseline']['median_ms'])
            close(statistics.median(b), reported['candidate']['median_ms'])
            assert a.count(0) == reported['baseline']['zero_count']
            assert b.count(0) == reported['candidate']['zero_count']
            differences = [y-x for x,y in zip(a,b)]
            close(statistics.mean(differences), reported['paired_mean_delta_ms'])
            if field == 'save_process_user_ms':
                assert all(x>0 for x in a+b)
                logs = [math.log(y/x) for x,y in zip(a,b)]
                average = statistics.mean(logs)
                error = statistics.stdev(logs)/math.sqrt(30)
                transform = lambda x:100*math.expm1(x)
                close(transform(average), reported['paired_geomean_change_pct'])
                upper = average+t_one*error
                close(transform(upper), reported['one_sided_95pct_upper_change_pct'])
                for actual, expected in zip(reported['two_sided_95pct_change_ci_pct'],
                    (transform(average-t_two*error),transform(average+t_two*error))):
                    close(actual, expected)
                passed = upper < math.log(1.01)
                assert passed == reported['passes_less_than_1pct_added_user_cpu']
                assert row['save_cpu_decision'] == ('pass' if passed else 'not_proven')
                decisions[case] = row['save_cpu_decision']
            else:
                mean = statistics.mean(differences)
                half = t_two*statistics.stdev(differences)/math.sqrt(30)
                for actual, expected in zip(reported['two_sided_95pct_delta_ci_ms'],(mean-half,mean+half)):
                    close(actual, expected)
            checked += 1
        for name, archive in row['archives']['by_archive'].items():
            for field, stat in archive['metrics'].items():
                unit=stat['unit']
                a=[p['baseline']['archives'][name][field] for p in pairs]
                b=[p['candidate']['archives'][name][field] for p in pairs]
                close(statistics.median(a),stat['baseline']['median_'+unit])
                close(statistics.median(b),stat['candidate']['median_'+unit])
                differences=[y-x for x,y in zip(a,b)]
                mean=statistics.mean(differences)
                half=t_two*statistics.stdev(differences)/math.sqrt(30)
                close(mean,stat['paired_mean_delta_'+unit])
                for actual,expected in zip(stat['two_sided_95pct_delta_ci_'+unit],(mean-half,mean+half)):
                    close(actual,expected)
    print(json.dumps(dict(cases=len(data['cases']),timing_metrics_recomputed=checked,
                          all_timing_and_archive_intervals_match=True,decisions=decisions),indent=2))


if __name__ == '__main__':
    main()
