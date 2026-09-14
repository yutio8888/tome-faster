#!/usr/bin/env python3
"""Validate all 300 fixed sessions before analyzing five isolated save experiments.

This program reads completed evidence, never starts the engine or decompresses
archives, and never publishes character-state projections. CRC verification is
required in each result from the hash-pinned runner. There is no partial-cohort,
sample-replacement, trimming, or optional-stopping analysis mode.
"""
import argparse
from dataclasses import dataclass
import hashlib
import json
import math
import os
from pathlib import Path, PurePosixPath
import statistics
import sys
import tempfile
import types


PAIRS = 30
T95_ONE_SIDED = 1.6991270265334972
T95_TWO_SIDED = 2.045229642132703
LIMIT_LOG = math.log(1.01)
PACKAGE_SHA256 = '9464fdfc425f53a238aa76ffc16853bd9c5e38df9d6e9b5519941b517f5d2f76'
ENGINE_SHA256 = '5aa8fe5cfa8f0cde3aa82deb4602be95d8f7668e7d5d2ea4ce450cae18248dc7'
SAVE_SHA256 = '51d998a74cd09093bea1a3d5fcacb7ae8f689b1dc19f30f7fabed4d3b33157be'
PACKAGE_SOURCE_KEY = 'runtime/game/addons/tome-faster.teaa'
SAMPLE_FIELDS = (
    'process_user_ms', 'process_system_ms', 'thread_user_ms',
    'thread_system_ms', 'thread_cpu_ms', 'wall_ms',
)
PRIMARY = 'save_process_user_ms'
CASE_SPECS = {
    'base62-save': ('compact_save_names_base62', ()),
    'inventory-idle': ('compact_inventory', ()),
    'inventory-add': ('compact_inventory', ('inventory_add',)),
    'fearscape-idle': ('fearscape_cleanup', ()),
    'fearscape-exit': (
        'fearscape_cleanup', ('entry_sync', 'entry_observed', 'exit_sync', 'exit_observed'),
    ),
}
NEW_OPTIONS = ('compact_inventory', 'fearscape_cleanup', 'compact_save_names_base62')
COMMON_OPTIONS = {
    'profile': False, 'stutter': False, 'session': False,
    'compact_save_names': True, 'fbo_gc_guard': True, 'hit_warning_interval_ms': 500,
}
EVENT_MARKERS = {
    'inventory-add': ('inventory_add_begin', 'inventory_add_return'),
    'fearscape-exit': (
        'entry_call_begin', 'entry_call_return', 'entry_complete',
        'exit_call_begin', 'exit_call_return', 'exit_complete',
    ),
}
EVENT_INTERVALS = {
    'inventory_add': ('inventory_add_begin', 'inventory_add_return'),
    'entry_sync': ('entry_call_begin', 'entry_call_return'),
    'entry_observed': ('entry_call_begin', 'entry_complete'),
    'exit_sync': ('exit_call_begin', 'exit_call_return'),
    'exit_observed': ('exit_call_begin', 'exit_complete'),
}
REWRITTEN_ARCHIVES = ('world.teaw', 'yron/game.teag')


class InvalidEvidence(ValueError):
    """A mandatory condition failed; no performance summary may be produced."""


def require(condition, message):
    if not condition:
        raise InvalidEvidence(message)


def strict_equal(left, right):
    """Keep JSON booleans distinct from numeric 0/1, including nested options."""
    return json.dumps(left, sort_keys=True, allow_nan=False, separators=(',', ':')) == json.dumps(
        right, sort_keys=True, allow_nan=False, separators=(',', ':'))


def finite_number(value, label, *, positive=False):
    require(type(value) in (int, float) and math.isfinite(value), label + ': finite numeric value required')
    require(value > 0 if positive else value >= 0, label + ': invalid sign')
    return value


def integer(value, label, minimum=0):
    require(type(value) is int and value >= minimum, label + ': integer required')
    return value


def hash_string(value, label):
    require(isinstance(value, str) and len(value) == 64
            and all(c in '0123456789abcdef' for c in value), label + ': SHA256 required')
    return value


def relative_name(value, label):
    require(isinstance(value, str) and value != '' and '\\' not in value, label + ': relative path required')
    path = PurePosixPath(value)
    require(not path.is_absolute() and '..' not in path.parts and path.as_posix() == value
            and value != '.', label + ': unsafe or noncanonical relative path')
    return value


def hash_file(path):
    hasher = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            hasher.update(block)
    return hasher.hexdigest()


def reject_constant(_value):
    raise InvalidEvidence('Nonfinite JSON constant is not permitted')


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, 'Duplicate JSON object key')
        result[key] = value
    return result


def read_json(path):
    data = path.read_bytes()
    value = json.loads(data, object_pairs_hook=unique_object, parse_constant=reject_constant)
    require(isinstance(value, dict), str(path.name) + ': JSON object required')
    return value, hashlib.sha256(data).hexdigest()


def load_runner(root, expected_hash):
    """Use the requested frozen run.canonical_loaded_state without writing pyc."""
    path = root / 'run.py'
    data = path.read_bytes()
    require(hashlib.sha256(data).hexdigest() == expected_hash, 'Current run.py differs from frozen source')
    module = types.ModuleType('_isolated_frozen_runner')
    module.__file__ = str(path)
    old_flag = sys.dont_write_bytecode
    sys.dont_write_bytecode = True
    try:
        exec(compile(data, str(path), 'exec'), module.__dict__)
    finally:
        sys.dont_write_bytecode = old_flag
    require(list(module.CASES) == list(CASE_SPECS), 'Runner case order differs from protocol')
    require(module.CASES == {case: spec[0] for case, spec in CASE_SPECS.items()},
            'Runner case options differ from protocol')
    require(strict_equal(module.OFF, dict.fromkeys(NEW_OPTIONS, False))
            and strict_equal(module.COMMON, COMMON_OPTIONS), 'Runner production defaults differ from protocol')
    require(callable(module.canonical_loaded_state), 'Runner semantic projection is unavailable')
    return module


def validate_plan(plan):
    require(type(plan.get('schema')) is int and plan['schema'] == 1, 'Plan schema must be 1')
    require(type(plan.get('pairs_per_case')) is int and plan['pairs_per_case'] == PAIRS,
            'Exactly 30 pairs per case are required')
    integer(plan.get('declared_unix_ns'), 'Plan declaration time', 1)
    for key, expected in (
        ('package_sha256', PACKAGE_SHA256), ('engine_sha256', ENGINE_SHA256), ('save_sha256', SAVE_SHA256),
    ):
        require(plan.get(key) == expected, 'Plan uses a different frozen ' + key)
    baseline = dict(COMMON_OPTIONS, **dict.fromkeys(NEW_OPTIONS, False))
    require(strict_equal(plan.get('production_options_baseline'), baseline),
            'Plan baseline must preserve common options and disable exactly the three new options')
    cases = plan.get('cases')
    require(isinstance(cases, dict) and set(cases) == set(CASE_SPECS), 'Exactly the five declared cases are required')
    for case, (option, prefixes) in CASE_SPECS.items():
        spec = cases[case]
        require(isinstance(spec, dict) and spec.get('option') == option, case + ': incorrect isolated option')
        require(spec.get('event_prefixes') == list(prefixes), case + ': incorrect event metric prefixes')
        pairs = spec.get('pairs')
        require(isinstance(pairs, list) and len(pairs) == PAIRS, case + ': exactly 30 pairs required')
        for index, pair in enumerate(pairs, 1):
            require(isinstance(pair, dict), case + ': pair must be an object')
            require(type(pair.get('pair')) is int and pair['pair'] == index, case + ': incorrect pair index')
            names = [f'{case}--{variant}--p{index:02d}' for variant in ('baseline', 'candidate')]
            require([pair.get('baseline'), pair.get('candidate')] == names, case + ': incorrect fixed session names')
            require(pair.get('run_order') == (names if index % 2 else names[::-1]),
                    case + ': odd AB / even BA order required')
    order = []
    case_order = list(CASE_SPECS)
    for index in range(PAIRS):
        offset = index % len(case_order)
        for case in case_order[offset:] + case_order[:offset]:
            order.extend(cases[case]['pairs'][index]['run_order'])
    require(plan.get('execution_order') == order and len(set(order)) == 300,
            'Plan must contain the fixed rotating 300-session execution order')
    rewritten = plan.get('expected_rewritten_archives')
    require(isinstance(rewritten, list) and len(rewritten) == len(set(rewritten))
            and set(rewritten) == set(REWRITTEN_ARCHIVES), 'Unexpected rewritten archive paths')
    sources = plan.get('source_sha256')
    require(isinstance(sources, dict) and 'run.py' in sources and len(sources) >= 3,
            'Frozen source manifest is incomplete')
    for key, value in sources.items():
        relative_name(key, 'Source name')
        hash_string(value, 'Source hash')
    require(sources.get(PACKAGE_SOURCE_KEY) == PACKAGE_SHA256, 'Source manifest does not pin the common package')
    require(any(key.endswith('/SaveIsolatedProbe.lua') for key in sources)
            and any(key.endswith('/SaveCompactionCPU.lua') for key in sources)
            and any(key.endswith('/FearscapeScenario.lua') for key in sources),
            'Probe, CPU sampler and Fearscape helper must all be frozen')
    environment = plan.get('environment_sha256')
    require(isinstance(environment, dict) and environment, 'Frozen environment manifest is missing')
    for key, value in environment.items():
        relative_name(key, 'Environment name')
        hash_string(value, 'Environment hash')
    return baseline


def validate_sources(root, plan, runner):
    require(runner.sources(root / 'runtime') == plan['source_sha256'],
            'Current source file set or hashes differ from the frozen manifest')
    for key, expected in plan['source_sha256'].items():
        path = root / key
        require(path.is_file() and hash_file(path) == expected, 'A frozen source file changed: ' + key)
    require(hash_file(root / 'runtime/t-engine') == plan['engine_sha256'], 'Runtime engine hash changed')


def validate_environment(root, plan):
    # The plan records workspace-relative names. This runs only after every
    # formal session has a completed result, never during a partial cohort.
    workspace = root.parent.parent
    for key, expected in plan['environment_sha256'].items():
        path = workspace / key
        require(path.is_file() and hash_file(path) == expected, 'Frozen environment changed: ' + key)


def record_of(records, kind, count, label):
    rows = [row for row in records if isinstance(row, dict) and row.get('kind') == kind]
    require(len(rows) == count, label + ': unexpected number of ' + kind + ' records')
    return rows[0] if count == 1 else rows


def validate_sample(sample, label):
    require(isinstance(sample, dict) and set(sample) == set(SAMPLE_FIELDS), label + ': incomplete sampler fields')
    for field in SAMPLE_FIELDS:
        finite_number(sample[field], label + '/' + field)


def interval(start, end, label):
    validate_sample(start, label + '/start')
    validate_sample(end, label + '/end')
    result = {}
    for field in SAMPLE_FIELDS:
        require(end[field] >= start[field], label + ': nonmonotonic ' + field)
        result[field] = end[field] - start[field]
    return result


def serialized_close(actual, expected, *source_values):
    # The Lua probe uses tostring(), so absolute values and their separately
    # serialized differences need not round-trip to identical doubles. This is
    # only a consistency tolerance for JSON serialization, not timing accuracy.
    allowance = 1e-7 + 2e-13 * sum(abs(value) for value in source_values)
    return abs(actual - expected) <= allowance


def validate_metrics(complete, case, label):
    samples = complete.get('save_samples')
    require(isinstance(samples, dict) and set(samples) == {'start', 'sync_return', 'finish'},
            label + ': save endpoints are missing')
    expected = {}
    source_bounds = {}

    def add(prefix, start, end):
        values = interval(start, end, label + '/' + prefix)
        for key, value in values.items():
            expected[prefix + '_' + key] = value
            source_bounds[prefix + '_' + key] = (start[key], end[key])

    add('save', samples['start'], samples['finish'])
    add('save_sync', samples['start'], samples['sync_return'])
    interval(samples['sync_return'], samples['finish'], label + '/save_after_sync')
    require(complete.get('save_endpoint_after_sync') is True
            and complete.get('save_endpoint_drained') is True, label + ': invalid save completion boundary')
    markers = EVENT_MARKERS.get(case, ())
    order = complete.get('event_order')
    # Lua's minimal encoder serializes an empty table as {}, not [].
    if not markers and order == {}:
        order = []
    require(order == list(markers), label + ': incorrect event marker order/count')
    events = complete.get('event_samples')
    require(isinstance(events, dict) and set(events) == set(markers), label + ': incorrect event samples')
    for marker in markers:
        validate_sample(events[marker], label + '/' + marker)
    for first, second in zip(markers, markers[1:]):
        interval(events[first], events[second], label + '/event_order')
    if markers:
        interval(events[markers[-1]], samples['start'], label + '/event_before_save')
    for prefix in CASE_SPECS[case][1]:
        start, end = EVENT_INTERVALS[prefix]
        add(prefix, events[start], events[end])
    event_prefix = {'inventory-add': 'inventory_add', 'fearscape-exit': 'exit_observed'}.get(case)
    if event_prefix:
        for key in SAMPLE_FIELDS:
            field = 'event_and_save_' + key
            expected[field] = expected[event_prefix + '_' + key] + expected['save_' + key]
            source_bounds[field] = source_bounds[event_prefix + '_' + key] + source_bounds['save_' + key]
    metrics = complete.get('metrics')
    require(isinstance(metrics, dict) and set(metrics) == set(expected), label + ': metric set differs from protocol')
    for field, value in metrics.items():
        finite_number(value, label + '/' + field, positive=field == PRIMARY)
        require(serialized_close(value, expected[field], *source_bounds[field]),
                label + ': metric does not match its recorded interval: ' + field)
    brackets = complete.get('empty_brackets')
    require(isinstance(brackets, list) and len(brackets) == 64, label + ': exactly 64 empty brackets required')
    for index, bracket in enumerate(brackets):
        validate_sample(bracket, label + '/empty_bracket_' + str(index + 1))
    return metrics, brackets


def validate_setup(setup, complete, case, variant, options, label):
    flags = {key: options[key] for key in NEW_OPTIONS}
    for record in (setup, complete):
        require(record.get('case') == case and record.get('variant') == variant,
                label + ': probe variant/case mismatch')
        require(strict_equal(record.get('options'), flags), label + ': observed switches differ from the sole intended change')
    require(setup.get('bare') is False and setup.get('production') is True, label + ': production addon is not active')
    require(setup.get('namer_source') == '@/engine/FasterSaveNames.lua', label + ': unexpected save namer')
    require(setup.get('sample_name_62') == ('10' if flags['compact_save_names_base62'] else '62'),
            label + ': name 62 does not match the selected encoder')
    require(setup.get('inventory_source') == ('@/engine/FasterInventory.lua' if flags['compact_inventory']
                                             else '@/mod/class/Player.lua'), label + ': inventory installation differs')
    require(setup.get('fearscape_source') == ('@/engine/FasterFearscape.lua' if flags['fearscape_cleanup']
                                             else '@/data/talents/corruptions/shadowflame.lua'),
            label + ': Fearscape installation differs')
    require(setup.get('fbo_gc_guard_setting') is True and setup.get('fbo_guard_module_loaded') is True,
            label + ': common FBO guard changed')
    require(strict_equal(setup.get('hit_warning_interval_ms'), 500), label + ': common warning interval changed')
    # Disabled-module absence and guarded stock function identities are also
    # asserted by the hash-pinned probe before its successful setup record.
    for field, flag in (('inventory_module_loaded', 'compact_inventory'),
                        ('fearscape_module_loaded', 'fearscape_cleanup')):
        if field in setup:
            require(setup[field] is flags[flag], label + ': module loading differs from option')


def validate_fearscape(report, complete, cleanup, label):
    require(isinstance(report, dict) and report.get('ok') is True and report.get('stage') == 'complete',
            label + ': Fearscape helper did not complete')
    require(report.get('mode') == 'casterdead' and type(report.get('seed')) is int
            and report['seed'] == 6140914, label + ': unexpected Fearscape workload')
    require(report.get('expect_cleanup') is cleanup and report.get('manually_changes_trapper') is False
            and report.get('pumps_game_ticks') is False and report.get('mutates_copy') is True,
            label + ': Fearscape lifecycle was not the declared native scenario')
    after = report.get('after')
    require(isinstance(after, dict), label + ': Fearscape completion evidence missing')
    for field in (
        'same_target_identity', 'same_source_identity', 'original_target_callback_identity',
        'original_caster_callback_identity', 'same_token_identity', 'source_and_plane_are_distinct',
        'plane_source_retained', 'target_is_original_name', 'returned_to_source_description',
        'target_death_wrapper_absent', 'paused',
    ):
        require(after.get(field) is True, label + ': Fearscape invariant failed: ' + field)
    require(after.get('trapper_absent') is cleanup and after.get('trapper_is_fixture') is (not cleanup),
            label + ': unexpected trapper cleanup')
    require(type(after.get('token_count')) is int and after['token_count'] == 1
            and type(after.get('pending')) is int and after['pending'] == 0 and after.get('saving') is False,
            label + ': incomplete exit or incorrect token count')
    caster = after.get('caster_observed_before_release')
    require(isinstance(caster, dict) and caster.get('dead') is True and caster.get('fearscape_active') is False,
            label + ': caster death/sustain state mismatch')
    for stage in ('before', 'entered', 'after'):
        row = report.get(stage)
        require(isinstance(row, dict) and row.get('turn') == complete['before'].get('turn'),
                label + ': gameplay turn changed during Fearscape')


def validate_archives(rows, rewritten, base62, label):
    require(isinstance(rows, list) and rows, label + ': archive evidence missing')
    result = {}
    for row in rows:
        require(isinstance(row, dict), label + ': archive record must be an object')
        name = relative_name(row.get('name'), label + '/archive_name')
        require(name not in result and PurePosixPath(name).suffix in ('.teag', '.teaw', '.teal', '.teaz'),
                label + ': duplicate/unexpected archive path')
        hash_string(row.get('sha256'), label + '/archive_sha256')
        for field in ('bytes', 'entries', 'raw_bytes', 'compressed_bytes', 'nondecimal_names', 'main_count'):
            integer(row.get(field), label + '/archive_' + field, 1 if field in ('bytes', 'entries') else 0)
        require(row.get('crc_valid') is True and row.get('unique_names') is True and row['main_count'] == 1,
                label + ': archive CRC, unique names, or main entry check failed')
        require(row['compressed_bytes'] <= row['bytes']
                and row['nondecimal_names'] <= row['entries'] - 1, label + ': impossible archive counts')
        if name in rewritten:
            require(row.get('compact_names') is True, label + ': rewritten archive lacks compact names')
            if base62:
                # With >=10 object entries the sequential alphabet necessarily
                # uses letters. Old, untouched zone archives are not tested here.
                require(row['entries'] <= 10 or row['nondecimal_names'] > 0,
                        label + ': rewritten archive does not show base62 names')
            else:
                require(row['nondecimal_names'] == 0, label + ': rewritten decimal archive has nondecimal names')
        result[name] = {field: row[field] for field in (
            'bytes', 'entries', 'raw_bytes', 'compressed_bytes', 'nondecimal_names', 'sha256',
        )}
    require(set(rewritten).issubset(result), label + ': a required rewritten archive is missing')
    return result


@dataclass
class Session:
    name: str
    case: str
    variant: str
    sequence: int
    started: int
    ended: int
    input_hash: str
    result_hash: str
    config_hash: str
    metrics: dict
    brackets: list
    archives: dict
    runtime: str
    before_projection: object
    after_projection: object
    initial_save_files: dict

    def public(self):
        # Intentionally do not serialize this dataclass or the original records:
        # they contain private character-state projections used only to validate.
        return {
            'session': self.name, 'measurement_sequence': self.sequence,
            'started_unix_ns': self.started, 'ended_unix_ns': self.ended,
            'input_sha256': self.input_hash, 'result_sha256': self.result_hash,
            'config_sha256': self.config_hash, 'metrics': self.metrics,
            'archives': self.archives,
        }


def validate_session(root, name, sequence, plan, plan_hash, runner, baseline_options):
    case, variant, _tag = name.split('--')
    session_dir = root / 'sessions' / name
    metadata, input_hash = read_json(session_dir / 'input.json')
    result, result_hash = read_json(session_dir / 'result.json')
    require(metadata.get('case') == case and metadata.get('variant') == variant
            and metadata.get('mode') == 'save' and metadata.get('source_session') is None,
            name + ': incorrect session identity or reused output')
    require(type(metadata.get('measurement_sequence')) is int and metadata['measurement_sequence'] == sequence,
            name + ': measurement sequence mismatch')
    require(metadata.get('acceptance_plan_sha256') == plan_hash, name + ': plan hash mismatch')
    require(strict_equal(metadata.get('source_sha256'), plan['source_sha256']), name + ': source hashes changed')
    for key, expected in (
        ('addon_sha256', plan['package_sha256']), ('engine_sha256', plan['engine_sha256']),
        ('save_sha256', plan['save_sha256']),
    ):
        require(metadata.get(key) == expected, name + ': fixed input changed: ' + key)
    options = dict(baseline_options)
    if variant == 'candidate':
        options[CASE_SPECS[case][0]] = True
    require(strict_equal(metadata.get('production_options'), options), name + ': production options are not isolated')
    require(metadata.get('profiling') is False, name + ': profiling must be disabled')
    config_hash = hash_string(metadata.get('config_sha256'), name + '/config_hash')
    start = integer(metadata.get('started_unix_ns'), name + '/start', 1)
    end = integer(result.get('ended_unix_ns'), name + '/end', 1)
    require(plan['declared_unix_ns'] < start <= end, name + ': invalid declaration/start/end order')
    finite_number(result.get('elapsed_s'), name + '/elapsed_s', positive=True)
    for key, expected in (
        ('exit_code', 0), ('timed_out', False), ('lua_error', False), ('complete', True),
        ('game_state_equal', True), ('save_endpoint_valid', True),
    ):
        require(key in result and strict_equal(result[key], expected), name + ': invalid completion flag: ' + key)
    records = result.get('records')
    require(isinstance(records, list), name + ': records must be a list')
    expected_kinds = ['setup', 'complete']
    if case == 'inventory-add':
        expected_kinds.append('inventory_fixture')
    if case == 'fearscape-exit':
        expected_kinds.append('fearscape_scenario')
    require(len(records) == len(expected_kinds) and all(isinstance(row, dict) for row in records)
            and sorted(row.get('kind', '') for row in records) == sorted(expected_kinds)
            and records[0].get('kind') == 'setup' and records[-1].get('kind') == 'complete',
            name + ': unexpected, duplicate or failed probe records')
    setup = record_of(records, 'setup', 1, name)
    complete = record_of(records, 'complete', 1, name)
    validate_setup(setup, complete, case, variant, options, name)
    before, after = complete.get('before'), complete.get('after')
    require(isinstance(before, dict) and isinstance(after, dict) and strict_equal(before, after),
            name + ': state changed during save')
    required_state = {'turn', 'x', 'y', 'life', 'uid', 'level', 'paused', 'actors', 'inventory'}
    require(set(before) == required_state and before.get('paused') is True, name + ': incomplete/invalid semantic projection')
    if case == 'inventory-add':
        fixture = record_of(records, 'inventory_fixture', 1, name)
        require(type(fixture.get('count')) is int and fixture['count'] == 24
                and fixture.get('canonical') is options['compact_inventory'], name + ': invalid 24-object fixture')
        inventory_id = integer(fixture.get('inventory_id'), name + '/inventory_id', 1)
        require(isinstance(before['inventory'], list), name + ': fixture inventory is absent')
        objects = [row for row in before['inventory'] if isinstance(row, dict) and type(row.get('fixture')) is int]
        require(len(objects) == 24 and sorted(row['fixture'] for row in objects) == list(range(1, 25)),
                name + ': fixture object count/identity mismatch')
        for row in objects:
            require(row.get('owner_uid') == before['uid'] and row.get('owner_inventory') == inventory_id
                    and row.get('inventory') == inventory_id and type(row.get('stacked')) is int and row['stacked'] == 0,
                    name + ': fixture ownership or stacking differs')
    if case == 'fearscape-exit':
        validate_fearscape(record_of(records, 'fearscape_scenario', 1, name).get('report'),
                           complete, options['fearscape_cleanup'], name)
    metrics, brackets = validate_metrics(complete, case, name)
    archives = validate_archives(result.get('archives'), plan['expected_rewritten_archives'],
                                 options['compact_save_names_base62'], name)
    initial_files = metadata.get('save_files_before')
    require(isinstance(initial_files, dict) and initial_files, name + ': initial save manifest missing')
    for key, value in initial_files.items():
        relative_name(key, name + '/initial_save_path')
        hash_string(value, name + '/initial_save_hash')
    runtime = complete.get('runtime')
    require(isinstance(runtime, str) and runtime, name + ': runtime version missing')
    return Session(
        name=name, case=case, variant=variant, sequence=sequence, started=start, ended=end,
        input_hash=input_hash, result_hash=result_hash, config_hash=config_hash,
        metrics=metrics, brackets=brackets, archives=archives, runtime=runtime,
        before_projection=runner.canonical_loaded_state(before),
        after_projection=runner.canonical_loaded_state(after), initial_save_files=initial_files,
    )


def validate_all(root):
    plan, plan_hash = read_json(root / 'acceptance-plan.json')
    baseline_options = validate_plan(plan)
    # Check completeness before reading any formal metric values. A running,
    # missing, or partially written cohort cannot produce partial estimates.
    for name in plan['execution_order']:
        for filename in ('input.json', 'result.json'):
            require((root / 'sessions' / name / filename).is_file(),
                    'All 300 completed sessions are required; missing ' + name + '/' + filename)
    runner = load_runner(root, plan['source_sha256']['run.py'])
    validate_sources(root, plan, runner)
    sessions = {}
    reference_files = None
    reference_runtime = None
    config_hashes = {}
    previous = None
    for sequence, name in enumerate(plan['execution_order'], 1):
        session = validate_session(root, name, sequence, plan, plan_hash, runner, baseline_options)
        if previous is not None:
            require(previous.started < session.started and previous.ended <= session.started,
                    name + ': actual order differs or sessions overlap')
        if reference_files is None:
            reference_files, reference_runtime = session.initial_save_files, session.runtime
        require(session.initial_save_files == reference_files, name + ': initial save contents changed')
        require(session.runtime == reference_runtime, name + ': runtime version changed')
        config_key = (session.case, session.variant)
        config_hashes.setdefault(config_key, session.config_hash)
        require(config_hashes[config_key] == session.config_hash, name + ': config changed within the same case/variant')
        sessions[name], previous = session, session
    for case, spec in plan['cases'].items():
        archive_names = None
        for pair in spec['pairs']:
            baseline, candidate = sessions[pair['baseline']], sessions[pair['candidate']]
            require(strict_equal(baseline.before_projection, candidate.before_projection)
                    and strict_equal(baseline.after_projection, candidate.after_projection),
                    case + '/pair_' + str(pair['pair']) + ': cross-variant semantic projection differs')
            for session in (baseline, candidate):
                if archive_names is None:
                    archive_names = set(session.archives)
                require(set(session.archives) == archive_names, session.name + ': archive set changed within the case')
    # Guard source/plan edits during validation as well as their per-session hashes.
    require(hash_file(root / 'acceptance-plan.json') == plan_hash, 'Plan changed during validation')
    validate_sources(root, plan, runner)
    validate_environment(root, plan)
    return plan, plan_hash, sessions


def percentile(values, fraction):
    ordered = sorted(values)
    position = fraction * (len(ordered) - 1)
    low = math.floor(position)
    high = math.ceil(position)
    return ordered[low] + (ordered[high] - ordered[low]) * (position - low)


def describe(values, unit='ms'):
    require(bool(values), 'Cannot describe an empty metric')
    return {
        'count': len(values), 'mean_' + unit: statistics.mean(values),
        'median_' + unit: statistics.median(values), 'sd_' + unit: statistics.stdev(values) if len(values) > 1 else 0,
        'min_' + unit: min(values), 'max_' + unit: max(values), 'p95_' + unit: percentile(values, 0.95),
        'zero_count': sum(value == 0 for value in values),
    }


def paired_absolute(baseline, candidate, unit='ms', *, timing=True):
    require(len(baseline) == PAIRS and len(candidate) == PAIRS, 'Exactly 30 paired observations required')
    for value in baseline + candidate:
        finite_number(value, 'Paired observation')
    differences = [new - old for old, new in zip(baseline, candidate)]
    mean = statistics.mean(differences)
    sd = statistics.stdev(differences)
    half = T95_TWO_SIDED * sd / math.sqrt(PAIRS)
    old_mean, new_mean = statistics.mean(baseline), statistics.mean(candidate)
    unresolved = timing and (all(value == 0 for value in baseline + candidate) or sd == 0)
    return {
        'method': 'Paired absolute differences; Student t(df=29); fixed 30 pairs; descriptive, not a gate.',
        'pairs': PAIRS, 'unit': unit, 'baseline': describe(baseline, unit), 'candidate': describe(candidate, unit),
        'paired_mean_delta_' + unit: mean, 'paired_median_delta_' + unit: statistics.median(differences),
        'paired_delta_sd_' + unit: sd, 'two_sided_95pct_delta_ci_' + unit: [mean - half, mean + half],
        'mean_change_pct_descriptive_only': 100 * (new_mean / old_mean - 1) if old_mean > 0 else None,
        'used_for_pass_decision': False,
        'degenerate_observed_variance': sd == 0,
        'measurement_caution': ('Zero or constant measured differences do not establish zero CPU cost or measurement error.'
                                if unresolved else None),
        'order_mean_delta_' + unit: {'AB': statistics.mean(differences[0::2]), 'BA': statistics.mean(differences[1::2])},
    }


def paired_log_save(baseline, candidate):
    require(len(baseline) == PAIRS and len(candidate) == PAIRS, 'Exactly 30 paired saves required')
    for value in baseline + candidate:
        finite_number(value, 'Save process user CPU', positive=True)
    ratios = [new / old for old, new in zip(baseline, candidate)]
    for value in ratios:
        finite_number(value, 'Paired save ratio', positive=True)
    logs = [math.log(value) for value in ratios]
    mean = statistics.mean(logs)
    sd = statistics.stdev(logs)
    se = sd / math.sqrt(PAIRS)
    upper = mean + T95_ONE_SIDED * se
    pct = lambda value: 100 * math.expm1(value)
    return {
        'method': 'Paired log ratios; Student t(df=29); fixed 30 pairs; one-sided 95% upper bound < +1%.',
        'pairs': PAIRS, 'unit': 'ms', 'baseline': describe(baseline), 'candidate': describe(candidate),
        'paired_geomean_change_pct': pct(mean),
        'paired_mean_delta_ms': statistics.mean(new - old for old, new in zip(baseline, candidate)),
        'paired_log_ratio_sd': sd, 'paired_log_ratio_se': se,
        'two_sided_95pct_change_ci_pct': [pct(mean - T95_TWO_SIDED * se), pct(mean + T95_TWO_SIDED * se)],
        'one_sided_95pct_upper_change_pct': pct(upper),
        'added_user_cpu_limit_pct': 1,
        'passes_less_than_1pct_added_user_cpu': upper < LIMIT_LOG,
        'used_for_pass_decision': True,
        'order_geomean_change_pct': {'AB': pct(statistics.mean(logs[0::2])), 'BA': pct(statistics.mean(logs[1::2]))},
    }


def summarize_archives(pairs, rewritten):
    names = sorted(pairs[0][0].archives)
    fields = {'bytes': 'bytes', 'raw_bytes': 'bytes', 'compressed_bytes': 'bytes',
              'entries': 'count', 'nondecimal_names': 'count'}
    output = {}
    for name in names:
        output[name] = {
            'expected_rewritten': name in rewritten,
            'metrics': {
                field: paired_absolute([row[0].archives[name][field] for row in pairs],
                                       [row[1].archives[name][field] for row in pairs], unit, timing=False)
                for field, unit in fields.items()
            },
        }
    totals = {}
    for group, selected in (('all_archives', names), ('expected_rewritten_archives', rewritten)):
        totals[group] = {
            field: paired_absolute([sum(row[0].archives[name][field] for name in selected) for row in pairs],
                                   [sum(row[1].archives[name][field] for name in selected) for row in pairs],
                                   unit, timing=False)
            for field, unit in fields.items()
        }
    return {'by_archive': output, 'totals': totals}


def summarize_brackets(pairs):
    output = {}
    for index, variant in enumerate(('baseline', 'candidate')):
        brackets = [bracket for pair in pairs for bracket in pair[index].brackets]
        output[variant] = {field: describe([row[field] for row in brackets]) for field in SAMPLE_FIELDS}
    return {
        'brackets_per_session': 64, 'sessions_per_variant': PAIRS,
        'interpretation': 'Observed empty sampling brackets only; pooled descriptively; neither an accuracy bound nor independent event samples; never subtracted.',
        'getrusage_representation_quantum_us': 1,
        'getrusage_accuracy_bound_us': None,
        'variants': output,
    }


def summarize(plan, plan_hash, sessions):
    require(len(sessions) == 300 and set(sessions) == set(plan['execution_order']),
            'Refusing to summarize anything short of the full validated cohort')
    cases = {}
    for case in CASE_SPECS:
        spec = plan['cases'][case]
        pairs = [(sessions[pair['baseline']], sessions[pair['candidate']]) for pair in spec['pairs']]
        metrics = {}
        for field in sorted(pairs[0][0].metrics):
            baseline = [pair[0].metrics[field] for pair in pairs]
            candidate = [pair[1].metrics[field] for pair in pairs]
            metrics[field] = paired_log_save(baseline, candidate) if field == PRIMARY else paired_absolute(baseline, candidate)
        passes = metrics[PRIMARY]['passes_less_than_1pct_added_user_cpu']
        cases[case] = {
            'option': spec['option'], 'pairs': PAIRS, 'valid_sessions': PAIRS * 2,
            'primary_metric': PRIMARY, 'save_cpu_decision': 'pass' if passes else 'not_proven',
            'event_prefixes': spec['event_prefixes'], 'metrics': metrics,
            'archives': summarize_archives(pairs, plan['expected_rewritten_archives']),
            'empty_brackets': summarize_brackets(pairs),
            'paired_values': [
                {'pair': index, 'order': 'AB' if index % 2 else 'BA',
                 'baseline': pair[0].public(), 'candidate': pair[1].public()}
                for index, pair in enumerate(pairs, 1)
            ],
        }
    return {
        'schema': 1, 'plan_sha256': plan_hash, 'analysis_sha256': hash_file(Path(__file__).resolve()),
        'package_sha256': plan['package_sha256'], 'engine_sha256': plan['engine_sha256'],
        'save_sha256': plan['save_sha256'], 'source_sha256': plan['source_sha256'],
        'environment_manifest_sha256': hashlib.sha256(json.dumps(
            plan['environment_sha256'], sort_keys=True, separators=(',', ':')).encode()).hexdigest(),
        'environment_file_count': len(plan['environment_sha256']),
        'validated_sessions': len(sessions), 'validated_pairs': PAIRS * len(CASE_SPECS),
        'declared_unix_ns': plan['declared_unix_ns'], 'execution_order': plan['execution_order'],
        'all_save_cases_pass': all(case['save_cpu_decision'] == 'pass' for case in cases.values()),
        'cases': cases,
        'validation': {
            'single_common_package': True, 'one_switch_per_candidate': True,
            'all_source_hashes_fixed': True, 'actual_sequence_and_nonoverlap_checked': True,
            'frozen_environment_rechecked_after_all_sessions': True,
            'cross_variant_semantic_projection_equal': True, 'intrasession_save_state_equal': True,
            'native_completion_endpoints_checked': True, 'reported_crc_unique_names_and_main_checked': True,
            'rewritten_archive_encoding_checked': True, 'all_fixed_samples_retained': True,
            'partial_analysis': False,
        },
        'limitations': [
            'Each save gate applies to this frozen workload and host; event, startup, reload, other exit paths and combined-feature costs are separate.',
            'SELF user CPU includes all process threads active within the measured interval; thread total CPU includes user and system work.',
            'Entry/exit observed intervals include scheduling, rendering and first-observation delay. Their synchronous subintervals are nested and are never added again.',
            'event_and_save is only inventory_add + save, or exit_observed + save. It excludes entry, fixture construction, validation and gaps and is not a replacement gate.',
            'Auxiliary and event intervals use 30 paired absolute differences. A batch of 24 objects is one observation. Zero/constant readings do not establish zero CPU cost.',
            'Mean-change percentages for auxiliary metrics and archive sizes are descriptive only and are never used to pass an optimization.',
            'Student t intervals assume a sufficiently independent, approximately normal paired mean. Per-case 95% intervals do not provide simultaneous 95% coverage for every case.',
            'Empty brackets are observed instrumentation costs, not error bounds, and are neither subtracted nor treated as extra independent event samples.',
            'Archive CRC evidence comes from the frozen runner, which fully tested each archive before writing its result. This analyzer does not decompress them again.',
            'Gameplay-state projections and full scenario reports were used for validation but are intentionally omitted from this output.',
        ],
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parent)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args(argv)
    root = args.root.resolve()
    output = args.output.resolve()
    require(output != root / 'acceptance-plan.json' and output != Path(__file__).resolve()
            and output != root / 'run.py' and not output.is_relative_to(root / 'sessions')
            and not output.is_relative_to(root / 'runtime') and not output.is_relative_to(root / 'probe'),
            'Output must not overwrite any plan, source, or session evidence')
    plan, plan_hash, sessions = validate_all(root)
    summary = summarize(plan, plan_hash, sessions)
    encoded = json.dumps(summary, indent=2, allow_nan=False) + '\n'
    # No output file is touched on any validation/statistics error. Publish only
    # a complete JSON document, so IO failure cannot truncate a prior summary.
    temporary = None
    try:
        with tempfile.NamedTemporaryFile('w', encoding='utf-8', dir=output.parent,
                                         prefix='.' + output.name + '.', suffix='.tmp', delete=False) as stream:
            temporary = Path(stream.name)
            stream.write(encoded)
        os.replace(temporary, output)
        temporary = None
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    print(json.dumps({
        'validated_sessions': summary['validated_sessions'], 'plan_sha256': plan_hash,
        'cases': {case: {
            'decision': row['save_cpu_decision'],
            'change_pct': row['metrics'][PRIMARY]['paired_geomean_change_pct'],
            'upper_95pct_pct': row['metrics'][PRIMARY]['one_sided_95pct_upper_change_pct'],
        } for case, row in summary['cases'].items()},
    }, indent=2, allow_nan=False))


if __name__ == '__main__':
    try:
        main()
    except (InvalidEvidence, OSError, KeyError, TypeError, json.JSONDecodeError, OverflowError) as error:
        print('Invalid or incomplete evidence; no analysis written: ' + str(error), file=sys.stderr)
        raise SystemExit(2)
