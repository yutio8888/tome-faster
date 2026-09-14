#!/usr/bin/env python3
"""Recompute statistics from public rows; this does not validate hidden game states."""
import importlib.util
import json
from pathlib import Path

root = Path(__file__).resolve().parent
for cohort in ('base62-candidate', 'decimal-candidate', 'inventory-candidate'):
    folder = root / cohort
    spec = importlib.util.spec_from_file_location('analysis', folder / 'analyze_cpu.py')
    analysis = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(analysis)
    read = lambda name: json.loads((folder / name).read_text())
    rows = {r['session']: r for r in read('session-metrics.json')}
    plan, recorded = read('acceptance-plan.json'), read('cpu-results.json')
    assert len(rows) == 60 and len(plan['pairs']) == 30
    for metric in plan['metrics']:
        field = metric['field']
        old = [rows[p['baseline']]['timings'][field] for p in plan['pairs']]
        new = [rows[p['candidate']]['timings'][field] for p in plan['pairs']]
        recomputed = analysis.paired_summary(old, new)
        assert all(recorded['metrics'][field][k] == v for k, v in recomputed.items())
    print(cohort + ': all paired statistics reproduced; ' + recorded['decision'])
