#!/usr/bin/python3
"""
Check every local file in a PKGBUILD's source=() against its sha256sums pin.

makepkg only discovers a stale pin once it has downloaded (or cloned) the
whole source list, which is after a release build has already started. This
runs in milliseconds and catches the case that actually happened: a tracked
file was edited and its hash was never re-pinned.

Local files are the source entries that name a file in this directory and are
not URLs or VCS checkouts; those have no hash to check ('SKIP') or a remote
one (the tar.xz downloads, which are not in the repository).

Usage: check_pkgbuild_sums.py [PKGBUILD]
"""

import hashlib
import os
import re
import shlex
import sys

VCS = ("git+", "svn+", "hg+", "bzr+", "file://")
URL = ("http://", "https://", "ftp://")


def read_text(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read()
    except OSError as exc:
        sys.exit(f"check_pkgbuild_sums: cannot read {path}: {exc}")


def sha256_of(path):
    try:
        with open(path, "rb") as fh:
            return hashlib.sha256(fh.read()).hexdigest()
    except OSError as exc:
        sys.exit(f"check_pkgbuild_sums: cannot read {path}: {exc}")


def array(text, name):
    """Return the quoted entries of a bash array assignment, expansion-free."""
    pattern = rf"^{name}=\((.*?)^\)"
    m = re.search(pattern, text, re.S | re.M)
    if not m:
        sys.exit(f"check_pkgbuild_sums: no {name}=() array in the PKGBUILD")
    start = m.start(1)
    entries = []
    # Line numbers, so a parse failure can name the line like makepkg does.
    line = text[:start].count("\n") + 1
    for raw in m.group(1).splitlines():
        body = raw.strip()
        if body:
            try:
                # comments=True strips a trailing comment but keeps a '#'
                # inside quotes, so "git+...#commit=x" survives.
                parts = shlex.split(body, comments=True)
            except ValueError:
                sys.exit(f"check_pkgbuild_sums: cannot parse {name} "
                         f"line {line}: {body}")
            entries.extend((p, line) for p in parts)
        line += 1
    return entries


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "PKGBUILD"
    root = os.path.dirname(os.path.abspath(path)) or "."
    text = read_text(path)

    sources = array(text, "source")
    sums = [s for s, _ in array(text, "sha256sums")]
    if len(sources) != len(sums):
        sys.exit("check_pkgbuild_sums: source=() and sha256sums=() differ in "
                 f"length ({len(sources)} vs {len(sums)})")

    checked = failed = 0
    for (src, _line), want in zip(sources, sums, strict=True):
        src = src.split("::")[-1]          # name::url form
        if src.startswith(VCS + URL):
            continue
        fpath = os.path.join(root, src)
        if not os.path.isfile(fpath):
            continue                       # downloaded asset, not committed
        if want == "SKIP":
            print(f"  {src}: SKIP")
            continue
        got = sha256_of(fpath)
        checked += 1
        if got != want:
            print(f"  {src}: FAILED\n    expected {want}\n    actual   {got}")
            failed += 1
        else:
            print(f"  {src}: Passed")

    if failed:
        print(f"check_pkgbuild_sums: {failed} stale pin(s); "
              "re-pin sha256sums in the PKGBUILD")
        return 1
    print(f"check_pkgbuild_sums: {checked} local source(s) match their pins")
    return 0


if __name__ == "__main__":
    sys.exit(main())
