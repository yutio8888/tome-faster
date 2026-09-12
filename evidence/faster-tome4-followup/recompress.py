#!/usr/bin/env python3
"""Benchmark raw deflate on existing save entries, without executing save data."""

import argparse
import collections
import json
from pathlib import Path
import re
import statistics
import sys
import time
import zipfile
import zlib


LEVELS = (1, 4, 6)
WARMUP_ROUNDS = 2
MEASURED_ROUNDS = 9
CLASS_ENTRY = re.compile(r"^((?:engine|mod)\.[A-Za-z_][A-Za-z0-9_.]*)-0x[0-9a-fA-F]+$")


def rotated_levels(round_number):
    offset = round_number % len(LEVELS)
    return LEVELS[offset:] + LEVELS[:offset]


def compress_entries(entries, level):
    start_wall = time.perf_counter()
    start_cpu = time.process_time()
    compressed_bytes = 0
    for data in entries:
        compressor = zlib.compressobj(
            level, zlib.DEFLATED, -15, 8, zlib.Z_DEFAULT_STRATEGY
        )
        encoded = compressor.compress(data) + compressor.flush()
        compressed_bytes += len(encoded)
    cpu_ms = (time.process_time() - start_cpu) * 1000
    wall_ms = (time.perf_counter() - start_wall) * 1000
    return {
        "wall_ms": wall_ms,
        "cpu_ms": cpu_ms,
        "deflate_bytes": compressed_bytes,
    }


def benchmark(path):
    # All archive I/O, decompression and CRC validation precede timed sections.
    # Entry data is never extracted to disk or evaluated as Lua.
    groups = collections.defaultdict(lambda: {"entries": 0, "uncompressed_bytes": 0})
    with zipfile.ZipFile(path) as archive:
        failed_entry = archive.testzip()
        if failed_entry is not None:
            raise ValueError("input archive failed its CRC check")
        infos = archive.infolist()
        if not infos:
            raise ValueError("input archive is empty")
        entries = [archive.read(info) for info in infos]
        for info, data in zip(infos, entries):
            match = CLASS_ENTRY.fullmatch(info.filename)
            group = match.group(1) if match else "main" if info.filename == "main" else "other"
            groups[group]["entries"] += 1
            groups[group]["uncompressed_bytes"] += len(data)
        original_compressed_bytes = sum(info.compress_size for info in infos)
        original_methods = sorted({info.compress_type for info in infos})

    results = {
        "kind": "compression_only_proxy_not_game_benchmark",
        "archive": path.name,
        "entries": len(entries),
        "uncompressed_bytes": sum(map(len, entries)),
        "archive_bytes": path.stat().st_size,
        "original_deflate_bytes": original_compressed_bytes
        if original_methods == [zipfile.ZIP_DEFLATED] else None,
        "original_compressed_bytes": original_compressed_bytes,
        "original_compression_methods": original_methods,
        "input_crc_passed": True,
        "zlib_version": zlib.ZLIB_RUNTIME_VERSION,
        "method": (
            "each original uncompressed ZIP entry recompressed using fresh "
            "raw-deflate context (wbits=-15,memLevel=8,strategy=default); "
            "2 warmup rounds, 9 measured rounds; levels 1/4/6 rotate each round "
            "and rotation restarts after warmup; preloaded data; "
            "no disk I/O/ZIP headers/CRC/serializer included"
        ),
        "warmup_rounds": WARMUP_ROUNDS,
        "measured_rounds": MEASURED_ROUNDS,
        "measured_level_orders": [list(rotated_levels(i)) for i in range(MEASURED_ROUNDS)],
        "groups": dict(sorted(groups.items(), key=lambda item: item[1]["uncompressed_bytes"], reverse=True)),
        "samples": {str(level): [] for level in LEVELS},
    }

    for round_number in range(WARMUP_ROUNDS):
        for level in rotated_levels(round_number):
            compress_entries(entries, level)
    for round_number in range(MEASURED_ROUNDS):
        for level in rotated_levels(round_number):
            results["samples"][str(level)].append(compress_entries(entries, level))

    results["summary"] = {}
    for level, samples in results["samples"].items():
        sizes = {sample["deflate_bytes"] for sample in samples}
        if len(sizes) != 1:
            raise ValueError("compressed size changed across identical input samples")
        results["summary"][level] = {
            "median_wall_ms": statistics.median(sample["wall_ms"] for sample in samples),
            "min_wall_ms": min(sample["wall_ms"] for sample in samples),
            "max_wall_ms": max(sample["wall_ms"] for sample in samples),
            "median_cpu_ms": statistics.median(sample["cpu_ms"] for sample in samples),
            "deflate_bytes": sizes.pop(),
        }
    return results


def main():
    parser = argparse.ArgumentParser(
        description=(
            "CRC-check and preload a game.teag ZIP, then benchmark raw deflate "
            "levels 1, 4 and 6 with 2 warmups and 9 rotating measured rounds. "
            "Print JSON to stdout. This measures compression only, not game saves."
        )
    )
    parser.add_argument("archive", type=Path, help="path to a game.teag ZIP; never modified")
    args = parser.parse_args()
    try:
        result = benchmark(args.archive)
    except (OSError, ValueError, RuntimeError, zipfile.BadZipFile, zlib.error) as error:
        parser.exit(1, f"recompress: {error}\n")
    json.dump(result, sys.stdout, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
