#!/usr/bin/env python3
"""Verify local formal saves; publish metadata only, never save/image contents."""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re
import shlex
import struct
import subprocess
import tempfile
import zipfile
import zlib


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def check_png(path, decoder):
    data = path.read_bytes()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", "invalid PNG signature"
    cursor, chunks, ihdr = 8, [], None
    while cursor < len(data):
        assert cursor + 12 <= len(data), "truncated PNG chunk header"
        length = struct.unpack_from(">I", data, cursor)[0]
        kind = data[cursor + 4:cursor + 8]
        end = cursor + 12 + length
        assert end <= len(data), "truncated PNG chunk payload"
        assert re.fullmatch(b"[A-Za-z]{4}", kind), "invalid PNG chunk type"
        payload = data[cursor + 8:cursor + 8 + length]
        crc = struct.unpack_from(">I", data, cursor + 8 + length)[0]
        assert zlib.crc32(kind + payload) & 0xFFFFFFFF == crc, "PNG chunk CRC mismatch"
        chunks.append(kind.decode("ascii"))
        if kind == b"IHDR":
            assert length == 13 and ihdr is None, "invalid or duplicate IHDR"
            ihdr = struct.unpack(">IIBBBBB", payload)
        if kind == b"IEND":
            assert length == 0 and end == len(data), "invalid IEND or trailing bytes"
        cursor = end
    assert chunks[0] == "IHDR" and chunks[-1] == "IEND", "PNG boundary chunks missing"
    assert chunks.count("IHDR") == chunks.count("IEND") == 1, "duplicate PNG boundary chunk"
    idats = [i for i, kind in enumerate(chunks) if kind == "IDAT"]
    assert idats and idats == list(range(idats[0], idats[-1] + 1)), "missing or nonconsecutive IDAT"
    width, height, depth, color, compression, filtering, interlace = ihdr
    assert width > 0 and height > 0 and depth == 8 and color == 2, "unexpected screenshot pixel format"
    assert compression == filtering == interlace == 0, "unexpected screenshot PNG encoding"
    decoded = subprocess.run([str(decoder), str(path), str(path)], capture_output=True, text=True)
    assert decoded.returncode == 0, "independent libpng decode failed"
    decoded = json.loads(decoded.stdout)
    assert decoded == {"width": width, "height": height, "rgb_bytes": width * height * 3,
                       "pixels_equal": True}, "independent decoded metadata differs"
    return {
        "files": 1, "bytes": len(data), "width": width, "height": height,
        "bit_depth": depth, "color_type": color, "interlace": interlace,
        "chunk_count": len(chunks), "chunk_types": dict(sorted(Counter(chunks).items())),
        "all_chunk_crcs_passed": True, "structure_passed": True,
        "independent_libpng_decode_passed": True, "decoded_rgb_bytes": width * height * 3,
    }


def check_archives(save):
    files = sorted(p for p in save.rglob("*") if p.is_file())
    assert not any(p.is_symlink() for p in files), "unexpected save symlink"
    archives = [p for p in files if zipfile.is_zipfile(p)]
    world = [p for p in archives if p.parent == save and p.name == "world.teaw"]
    assert len(archives) == 23 and len(world) == 1, "unexpected character/World archive count"
    entries, total_bytes = 0, 0
    methods = Counter()
    for archive in archives:
        with zipfile.ZipFile(archive) as zf:
            members = zf.infolist()
            entries += len(members)
            for member in members:
                total_bytes += member.file_size
                methods[member.compress_type] += 1
                # Open each ZipInfo, including duplicate names, and consume to
                # EOF so zipfile verifies that exact entry's CRC-32.
                with zf.open(member) as stream:
                    while stream.read(1024 * 1024):
                        pass
    return {
        "regular_files_scanned": len(files), "character_archives": 22,
        "world_archives": 1, "total_archives": len(archives),
        "total_entries": entries, "uncompressed_bytes_checked": total_bytes,
        "compression_methods": {str(k): v for k, v in sorted(methods.items())},
        "all_entries_crc_passed": True,
    }


def audit_session(profile, addon, scenario, arm, pair, decoder, manifest):
    name = f"stutter-save-refresh-v1-{scenario}-{arm}-pair{pair}-01"
    session = profile / "sessions" / name
    process = json.loads((session / "process.json").read_text())
    experiment = json.loads((session / "experiment.json").read_text())
    log = (session / "game.log").read_text(errors="replace")
    events = [json.loads(line[len("[Stutter] "):]) for line in log.splitlines()
              if line.startswith("[Stutter] {")]
    phases = [e for e in events if e.get("kind") == "phase_end" and e.get("phase") == "save"]
    selected = re.findall(r"^\[FasterSaveState\] equal=(true|false) actors=(\d+) items=(\d+) "
                          r"changed_sections=(\d+) added_sections=(\d+) removed_sections=(\d+)$", log, re.M)
    assert len(phases) == len(selected) == 1, "missing or duplicate save/state validation record"
    state = selected[0]
    flags = dict(re.findall(r"(?:^|,\s*)(snapshot_refresh|screenshot_png)=(true|false)", experiment["config"]))
    expected_snapshot = arm == "after" and scenario in ("snapshot", "combined")
    expected_png = arm == "after" and scenario in ("png", "combined")
    checks = {
        "process_completed": process["completed"] is True,
        "process_exit_zero": process["exit_code"] == 0,
        "session_complete_marker": log.count("[YronProfile] SESSION_COMPLETE") == 1,
        "complete_event": sum(e.get("kind") == "complete" for e in events) == 1,
        "save_turn_unchanged": phases[0]["turn_delta"] == 0,
        "selected_state_equal": state[0] == "true" and state[3:] == ("0", "0", "0"),
        "no_lua_error_reports": "Lua Error:" not in log,
        "driver_hash_matches": experiment["driver_sha256"] == sha256(session / "driver.lua"),
        "production_manifest_consistent": experiment["production_sha256"] == manifest,
        "production_matches_current_addon": all(sha256(addon / p) == digest for p, digest in manifest.items()),
        "snapshot_setting_matches_arm": flags.get("snapshot_refresh") == str(expected_snapshot).lower(),
        "png_setting_matches_arm": flags.get("screenshot_png") == str(expected_png).lower(),
    }
    assert all(checks.values()), "session completion/state/provenance assertion failed"
    save = session / "home" / ".t-engine" / "4.0" / "tome" / "save"
    archives = check_archives(save)
    pngs = list(save.rglob("cur.png"))
    assert len(pngs) == 1, "missing or multiple cur.png files"
    png = check_png(pngs[0], decoder)
    return {
        "session": name, "scenario": scenario, "arm": arm, "pair": pair,
        "passed": True, "checks": checks,
        "selected_state": {"equal": True, "actors": int(state[1]), "inventory_items": int(state[2]),
                           "changed_sections": 0, "added_sections": 0, "removed_sections": 0},
        "archives": archives, "png": png,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("profile", type=Path, help="local engine tmp/profile directory")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    addon = Path(__file__).resolve().parents[2]
    source = Path(__file__).resolve().parent / "diagnostics" / "compare-png.c"
    first = args.profile / "sessions" / "stutter-save-refresh-v1-snapshot-before-pair1-01" / "experiment.json"
    manifest = json.loads(first.read_text())["production_sha256"]
    rows = []
    with tempfile.TemporaryDirectory(prefix="tome-refresh-integrity-") as build:
        decoder = Path(build) / "compare-png"
        flags = shlex.split(subprocess.check_output(["pkg-config", "--cflags", "--libs", "libpng"], text=True))
        subprocess.run(["cc", "-O2", str(source), "-o", str(decoder), *flags], check=True)
        for scenario in ("snapshot", "png", "combined"):
            for pair in (1, 2, 3):
                for arm in ("before", "after"):
                    row = audit_session(args.profile, addon, scenario, arm, pair, decoder, manifest)
                    rows.append(row)
                    print(f"{row['session']}: completion/state/23 ZIPs/PNG passed", flush=True)
    totals = {
        "sessions": len(rows), "completed_processes": len(rows), "selected_state_assertions_passed": len(rows),
        "character_archives": sum(r["archives"]["character_archives"] for r in rows),
        "world_archives": sum(r["archives"]["world_archives"] for r in rows),
        "all_archives": sum(r["archives"]["total_archives"] for r in rows),
        "all_entries": sum(r["archives"]["total_entries"] for r in rows),
        "uncompressed_bytes_checked": sum(r["archives"]["uncompressed_bytes_checked"] for r in rows),
        "png_files": len(rows), "png_chunks": sum(r["png"]["chunk_count"] for r in rows),
        "independent_libpng_decodes_passed": len(rows), "all_checks_passed": True,
    }
    assert totals["sessions"] == 18 and totals["all_archives"] == 414
    result = {
        "schema_version": 1, "scope": "Final 18-session snapshot/PNG/combined formal A/B saves",
        "privacy": "Metadata only; no save contents, archive member names, local home paths, PNG payloads or pixels retained.",
        "methods": {
            "zip_detection": "zipfile.is_zipfile on every regular file beneath each session save directory",
            "zip_crc": "Read every ZipInfo member to EOF with Python zipfile, including duplicate names",
            "png": "Validate signature, chunk framing/order, every chunk CRC, RGB8 IHDR, and independent libpng decode",
            "libpng_decode": "Compile public diagnostic compare-png.c; decode each image twice and compare it with itself",
            "decoder_source_sha256": sha256(source),
            "selected_state": "Require one successful FasterSaveState assertion, unchanged turn, and later session completion",
        },
        "production_sha256": manifest, "totals": totals, "sessions": rows,
        "limits": [
            "CRC/decode and selected-state assertions are not a proof of all saved fields' semantic equality.",
            "Same-image libpng comparison proves decoding succeeds; it does not compare before/after screenshot pixels.",
            "No real game process is launched by this audit.",
        ],
    }
    args.output.write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps(totals, sort_keys=True))


if __name__ == "__main__":
    main()
