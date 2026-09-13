#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Independent Python hashlib model of the explicitly experimental S11 encoding."""
import argparse
import hashlib
import json
from pathlib import Path
import struct

P = 2**251 + 17 * 2**192 + 1
DOMAIN = b"HP.STATE.B2S9\x00\x00\x00"
HERE = Path(__file__).resolve().parent


def message(values):
    if len(values) > 477218584 or any(x < 0 or x >= 2**72 for x in values):
        raise ValueError("outside S11 nine-byte domain")
    return DOMAIN + struct.pack("<IIQ", 2, 1, len(values)) + b"".join(x.to_bytes(9, "little") for x in values)


def digest(values):
    return hashlib.blake2s(message(values), digest_size=32).digest()


def field_hash(values):
    return int.from_bytes(digest(values), "little") % P


def vectors():
    cases = [("empty", []), ("zero", [0]), ("max72", [2**72-1]),
             ("endian", [0x010203040506070809]), ("trailing_zero", [1, 0])]
    for n in [3, 4, 7, 8, 31, 32, 33, 63, 64, 65, 96]:
        cases.append((f"length_{n}", [(2**72-1-i*0x01020304050607) for i in range(n)]))
    result = []
    for name, values in cases:
        d = digest(values)
        result.append(dict(name=name, values=[hex(x) for x in values], bytes=len(message(values)),
            messageHex=message(values).hex(), digestHex=d.hex(),
            digestWords=list(struct.unpack("<8I", d)), fieldHex=hex(field_hash(values))))
    return result


def cairo_tests(rows):
    lines = ["// SPDX-" + "License-Identifier: Apache-2.0", "// Generated independently by vectors.py (hashlib), not by Cairo.",
             "use super::hash9;", ""]
    for r in rows:
        lines += ["#[test]", f"fn test_{r['name']}() {{", f"    let input = array![{', '.join(r['values'])}];",
                  "    let digest = hash9::digest(input.span()).unwrap();",
                  f"    assert(digest == [{', '.join(hex(x) for x in r['digestWords'])}], 'independent digest');",
                  f"    assert(hash9::reduce(digest) == {r['fieldHex']}, 'reduction all bits');", "}", ""]
    lines += ["#[test]", "fn test_domain_rejected() {",
              "    assert(hash9::hash(array![0x1000000000000000000].span()).is_none(), 'two72 rejected');",
              f"    assert(hash9::hash(array![{hex(P-1)}].span()).is_none(), 'large felt rejected');", "}"]
    return "\n".join(lines) + "\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--write", action="store_true", help="explicitly write candidate vectors and Cairo tests")
    args = ap.parse_args()
    rows = vectors()
    if args.write:
        (HERE / "vectors.json").write_text(json.dumps(rows, indent=2) + "\n")
        (HERE / "src/tests.cairo").write_text(cairo_tests(rows))
    else:
        assert json.loads((HERE / "vectors.json").read_text()) == rows
    assert hashlib.blake2s(b"abc").hexdigest() == "508c5e8c327c14e2e1a72ba34eeb452f37458b209ed63a294d999b4c86675982"
    for bad in [-1, 2**72, P-1]:
        try:
            message([bad])
        except ValueError:
            pass
        else:
            raise AssertionError("domain rejection")
    print(f"{len(rows)} independent vectors and domain checks passed")


if __name__ == "__main__":
    main()
