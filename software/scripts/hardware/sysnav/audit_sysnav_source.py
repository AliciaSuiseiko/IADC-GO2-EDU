#!/usr/bin/env python3

import argparse
import hashlib
import os
from pathlib import Path


def file_mode(path: Path) -> str:
    if path.is_symlink():
        return "120000"
    return "100755" if path.stat().st_mode & 0o111 else "100644"


def content_hash(path: Path) -> str:
    digest = hashlib.sha256()
    if path.is_symlink():
        digest.update(os.readlink(path).encode())
        return digest.hexdigest()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("manifest", type=Path)
    parser.add_argument("source_root", type=Path)
    parser.add_argument("--details", type=int, default=200)
    args = parser.parse_args()

    expected = {}
    with args.manifest.open(encoding="utf-8") as manifest:
        for line in manifest:
            mode, digest, relative = line.rstrip("\n").split(" ", 2)
            expected[relative] = (mode, digest)

    missing = []
    modified = []
    mode_changed = []
    for relative, (mode, digest) in expected.items():
        path = args.source_root / relative
        if not path.exists() and not path.is_symlink():
            missing.append(relative)
            continue
        actual_mode = file_mode(path)
        if actual_mode != mode:
            mode_changed.append(f"{relative} expected={mode} actual={actual_mode}")
        if content_hash(path) != digest:
            modified.append(relative)

    actual = set()
    for directory, names, files in os.walk(args.source_root, followlinks=False):
        names[:] = [name for name in names if name != ".git"]
        base = Path(directory)
        for name in files:
            actual.add((base / name).relative_to(args.source_root).as_posix())
        for name in names:
            candidate = base / name
            if candidate.is_symlink():
                actual.add(candidate.relative_to(args.source_root).as_posix())

    extra = sorted(actual - set(expected))
    categories = (
        ("MISSING", missing),
        ("MODIFIED", modified),
        ("MODE_CHANGED", mode_changed),
        ("EXTRA", extra),
    )
    for label, entries in categories:
        for entry in entries[: args.details]:
            print(f"{label}\t{entry}")
        if len(entries) > args.details:
            print(f"{label}\t... {len(entries) - args.details} more")
    print(
        "SUMMARY "
        f"tracked={len(expected)} missing={len(missing)} modified={len(modified)} "
        f"mode_changed={len(mode_changed)} extra={len(extra)}"
    )
    return 1 if missing or modified or mode_changed else 0


if __name__ == "__main__":
    raise SystemExit(main())
