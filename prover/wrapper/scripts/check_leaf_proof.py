#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Hellproof contributors
# SPDX-License-Identifier: Apache-2.0
"""Verify an existing browser proof, its bzip2 encoding, and a one-bit corruption.

No proof is generated. The executable is the standalone leaf-verify build,
which is separate from the service's Rust tests.
"""
import argparse
import bz2
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--verifier', type=Path, required=True)
parser.add_argument('proof', type=Path)
parser.add_argument('--bootloader', type=Path, help='also check the service bootloader binding')
args = parser.parse_args()
raw = args.proof.read_bytes()
if raw.startswith(b'BZh'):
    raw = bz2.decompress(raw)
if not raw:
    parser.error('proof is empty')

with tempfile.TemporaryDirectory(prefix='leaf-admission-') as tmp:
    def verify(name, data, accepted, extra=()):
        path = Path(tmp) / name
        path.write_bytes(data)
        result = subprocess.run([str(args.verifier.resolve()), '--proof', str(path), *extra],
                                capture_output=True, text=True, timeout=60)
        report = json.loads(result.stdout)
        if result.returncode != (0 if accepted else 2) or report['ok'] != accepted:
            raise AssertionError(f'{name}: exit {result.returncode}: {report}')
        return report

    good = verify('raw.bin', raw, True)
    compressed = verify('compressed.bz2', bz2.compress(raw), True)
    for field in ('program_hash', 'output', 'trace_log_size'):
        assert compressed[field] == good[field], field
    corrupted = bytearray(raw)
    offset = len(corrupted) // 2
    corrupted[offset] ^= 1
    bad = verify('corrupt.bin', corrupted, False)
    bootloader_binding = None
    if args.bootloader:
        verify('matching-bootloader.bin', raw, True,
               ['--expect-bootloader', str(args.bootloader.resolve())])
        altered = json.loads(args.bootloader.read_text())
        altered['data'][0] = hex(int(altered['data'][0], 0) ^ 1)
        other = Path(tmp) / 'other-bootloader.json'
        other.write_text(json.dumps(altered))
        bootloader_binding = verify('other-bootloader.bin', raw, False,
                                    ['--expect-bootloader', str(other)])
    print(json.dumps({'proof_sha256': hashlib.sha256(raw).hexdigest(),
                      'valid': good, 'bzip2_verified': True,
                      'corrupt_byte_offset': offset, 'rejected': bad,
                      'wrong_bootloader_rejected': bootloader_binding}, indent=2))
