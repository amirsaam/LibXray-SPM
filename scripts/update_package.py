#!/usr/bin/env python3
"""Rewrites the LibXray version and checksum in Package.swift.

The nightly workflow calls this with the version and SHA-256 of the
libxray-apple-cgo.zip asset from the latest XTLS/libXray release. It changes
exactly two things: the download URL and the checksum line. Anything else it
cannot find, or an odd-shaped input, makes it exit nonzero so the run fails
loudly instead of committing garbage.
"""

import argparse
import re
import sys
from pathlib import Path

MANIFEST = Path("Package.swift")

URL_PATH = re.compile(r"libXray/releases/download/v([^/\"']+)/libxray-apple-cgo\.zip")
CHECKSUM = re.compile(r"[0-9a-f]{64}")
VERSION = re.compile(r"\d+\.\d+\.\d+")


def update(path: Path, version: str, checksum: str) -> bool:
    original = path.read_text()

    if len(URL_PATH.findall(original)) != 1:
        raise SystemExit(
            "{0}: expected exactly one libxray-apple-cgo.zip URL, found {1}".format(
                path, len(URL_PATH.findall(original))
            )
        )

    text = URL_PATH.sub(
        "libXray/releases/download/v{0}/libxray-apple-cgo.zip".format(version),
        original,
    )

    lines = text.splitlines(keepends=True)
    hits = [i for i, line in enumerate(lines) if "checksum" in line and CHECKSUM.search(line)]
    if len(hits) != 1:
        raise SystemExit("{0}: expected exactly one checksum line, found {1}".format(path, len(hits)))
    lines[hits[0]] = CHECKSUM.sub(checksum, lines[hits[0]], count=1)
    text = "".join(lines)

    if text == original:
        return False
    path.write_text(text)
    return True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", required=True, help="libXray version, e.g. 26.10.29")
    parser.add_argument("--checksum", required=True, help="SHA-256 of libxray-apple-cgo.zip")
    args = parser.parse_args()

    if not VERSION.fullmatch(args.version):
        raise SystemExit("unexpected version format: " + args.version)
    if not CHECKSUM.fullmatch(args.checksum):
        raise SystemExit("unexpected checksum format")

    if update(MANIFEST, args.version, args.checksum):
        print("Package.swift: updated to {0}".format(args.version))
        return 0
    print("Package.swift: already up to date")
    return 1


if __name__ == "__main__":
    sys.exit(main())
