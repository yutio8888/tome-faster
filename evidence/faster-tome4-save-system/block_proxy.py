#!/usr/bin/env python3
"""Read-only compact-name, cross-object compression proxy; no saved Lua runs."""
import argparse
import hashlib
import importlib.util
import json
import platform
import statistics
import time
import zipfile
import zlib
from pathlib import Path

ROOT = Path('/workspace/t-engine4/game/addons/tome-faster')
DEFAULT_SOURCE = Path('/workspace/t-engine4/test-saves/faster-0.2.8/.t-engine/4.0/tome/save/yron')
VARIANTS = [('entry', 0), ('64KiB', 65536), ('256KiB', 262144),
            ('1MiB', 1048576), ('archive', 1 << 60)]


def group(data, cap):
    if not cap:
        return data
    result, batch, count = [], [], 0
    for payload in data:
        if batch and count + len(payload) > cap:
            result.append(b''.join(batch))
            batch, count = [], 0
        batch.append(payload)
        count += len(payload)
    if batch:
        result.append(b''.join(batch))
    return result


def hashes(source):
    return {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
            for p in source.iterdir() if p.is_file()}


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--source', type=Path, default=DEFAULT_SOURCE)
    ap.add_argument('--output', type=Path, required=True)
    args = ap.parse_args()
    spec = importlib.util.spec_from_file_location(
        'size_audit', ROOT / 'evidence/faster-tome4-save-size/audit_size.py')
    audit = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(audit)
    previous = json.loads((ROOT / 'evidence/faster-tome4-save-size/offline-results.json').read_text())
    original_hashes = hashes(args.source)
    assert original_hashes == previous['source_sha256']
    archives = []
    for path in sorted(args.source.iterdir()):
        if path.suffix not in ('.teag', '.teaz'):
            continue
        with zipfile.ZipFile(path) as archive:
            assert archive.testzip() is None
            infos = archive.infolist()
            names = {info.filename.encode(): str(i + 1).encode()
                     for i, info in enumerate(infos) if info.filename != 'main'}
            names[b'main'] = b'main'
            inverse = {value: key for key, value in names.items()}
            assert len(inverse) == len(names)
            payloads = []
            for info in infos:
                raw = archive.read(info)
                assert len(audit.deflate(raw, 4)) == info.compress_size
                compact = audit.rename(raw, names)
                assert audit.rename(compact, inverse) == raw
                payloads.append(compact)
            archives.append((path.name, payloads))
    report = {
        'date': '2026-09-14',
        'purpose': 'Offline proxy, not a writer, reader, archive format, or full-game benchmark.',
        'python': platform.python_version(),
        'zlib': zlib.ZLIB_RUNTIME_VERSION,
        'source_manifest': 'evidence/faster-tome4-save-size/offline-results.json:source_sha256',
        'source_manifest_match': True,
        'protocol': 'Raw DEFLATE level 4, memLevel 8, default strategy; original ZIP order; '
                    'object boundaries retained; no grouping across archives; '
                    'target block sizes, oversized objects remain whole; compact names '
                    'from prior offline audit; grouping prebuilt outside timed intervals; '
                    '2 warmups, 7 rotating rounds; no index, framing, ZIP headers, CRC, '
                    'Lua/C serialization, disk, game scheduling, cloud, or reader.',
        'datasets': {},
    }
    for dataset, selected in [('game', [a for a in archives if a[0] == 'game.teag']),
                              ('all_archives', archives)]:
        chunks = {name: [chunk for _, payloads in selected for chunk in group(payloads, cap)]
                  for name, cap in VARIANTS}
        for name, data in chunks.items():
            for chunk in data:
                assert zlib.decompress(audit.deflate(chunk, 4), -15) == chunk
        samples = {name: [] for name, _ in VARIANTS}

        def run(name):
            cpu, wall = time.process_time_ns(), time.perf_counter_ns()
            size = sum(len(audit.deflate(chunk, 4)) for chunk in chunks[name])
            return {'cpu_ms': (time.process_time_ns() - cpu) / 1e6,
                    'wall_ms': (time.perf_counter_ns() - wall) / 1e6,
                    'compressed_bytes': size}

        for _ in range(2):
            for name, _ in VARIANTS:
                run(name)
        for round_index in range(7):
            for offset in range(len(VARIANTS)):
                name = VARIANTS[(round_index + offset) % len(VARIANTS)][0]
                samples[name].append({'round': round_index + 1, **run(name)})
        summary = {}
        for name, rows in samples.items():
            assert len({row['compressed_bytes'] for row in rows}) == 1
            summary[name] = {
                'units': len(chunks[name]),
                'largest_unit_bytes': max(map(len, chunks[name])),
                'compressed_bytes': rows[0]['compressed_bytes'],
                'cpu_median_ms': statistics.median(row['cpu_ms'] for row in rows),
                'wall_median_ms': statistics.median(row['wall_ms'] for row in rows),
                'samples': rows,
            }
        report['datasets'][dataset] = {
            'raw_bytes': sum(map(len, chunks['entry'])),
            'archives': len(selected),
            'variants': summary,
        }
        print(json.dumps({dataset: {name: {key: value for key, value in result.items()
                                          if key != 'samples'}
                                   for name, result in summary.items()}}), flush=True)
    assert hashes(args.source) == original_hashes
    report['source_unchanged'] = True
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
