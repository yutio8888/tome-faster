#!/usr/bin/env python3
"""Build from an explicit source allowlist, excluding Git and local files."""
from pathlib import Path
import hashlib
import zipfile

root = Path(__file__).resolve().parents[1]
files = [root / name for name in ("init.lua", "COPYING", "README.md", "UPSTREAM.json", "VALIDATION.json")]
for name in ("hooks", "overload", "superload", "docs", "tests", "tools"):
    files.extend(path for path in (root / name).rglob("*") if path.is_file() and "__pycache__" not in path.parts)
output = root / "dist" / "tome-faster.teaa"
output.parent.mkdir(exist_ok=True)
with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
    for path in sorted(files):
        if path.is_symlink():
            raise ValueError(f"refusing symlink: {path}")
        entry = zipfile.ZipInfo(path.relative_to(root).as_posix(), (2026, 9, 13, 0, 0, 0))
        entry.compress_type = zipfile.ZIP_DEFLATED
        entry.create_system = 3
        entry.external_attr = 0o100644 << 16
        archive.writestr(entry, path.read_bytes())
with zipfile.ZipFile(output) as archive:
    assert archive.testzip() is None
    assert "init.lua" in archive.namelist()
print(f"{output}\nSHA256 {hashlib.sha256(output.read_bytes()).hexdigest()}\n{len(files)} source files")
