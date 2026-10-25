#!/usr/bin/env python3
"""Derive the Chrome/Chromium extension ID from a manifest `key` field.

An unpacked extension normally gets an ID derived from its absolute path, which
changes whenever the checkout moves and would force re-installing the native
host. Embedding an RSA public key in the manifest pins the ID instead:

    id = first 16 bytes of SHA-256(DER SubjectPublicKeyInfo),
         with each hex digit mapped 0-f -> a-p

Usage:
    extension_id.py [manifest.json]      print the ID
    extension_id.py --key [manifest]     print the key (for a second manifest)
"""

from __future__ import annotations

import base64
import binascii
import hashlib
import json
import sys
from pathlib import Path

DEFAULT_MANIFEST = Path(__file__).resolve().parent.parent / "extension" / "manifest.json"


def extension_id(key_b64: str) -> str:
    """Chrome's ID derivation for a manifest-embedded public key."""
    try:
        der = base64.b64decode(key_b64, validate=True)
    except (binascii.Error, ValueError) as exc:
        raise SystemExit(f"manifest key is not valid base64: {exc}") from exc
    if not der:
        raise SystemExit("manifest key is empty")
    digest = hashlib.sha256(der).hexdigest()[:32]
    return "".join(chr(ord("a") + int(nibble, 16)) for nibble in digest)


def load_key(path: Path) -> str:
    try:
        manifest = json.loads(path.read_text(encoding="utf-8"))
    except OSError as exc:
        raise SystemExit(f"cannot read {path}: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise SystemExit(f"{path} is not valid JSON: {exc}") from exc
    key = manifest.get("key")
    if not key:
        raise SystemExit(f"{path} has no 'key' field; the ID would be path-derived")
    return key


def main(argv: list[str]) -> int:
    want_key = False
    args = []
    for arg in argv:
        if arg == "--key":
            want_key = True
        elif arg in ("-h", "--help"):
            print(__doc__.strip())
            return 0
        else:
            args.append(arg)

    path = Path(args[0]).expanduser() if args else DEFAULT_MANIFEST
    key = load_key(path)
    print(key if want_key else extension_id(key))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
