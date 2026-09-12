#!/usr/bin/env python3
"""Turns a `leaf_prover` output into a `LeafInput` for `stwo_run_and_prove_recursive_tree`.

The leaf simple bootloader dumps the preimage of the leaf's hashed output (hex felts:
`[task_program_hash, task_output...]`) to `output_preimage_dump_path`; the tree wants it flattened
into the leaf JSON as decimal strings under `output_preimage` (what the backend injects).

Usage: inject_preimage.py <leaf_raw.json> <preimage_dump.json> <leaf_out.json>
"""
import json
import sys

raw, dump, out = sys.argv[1:4]
leaf = json.load(open(raw))
preimage_hex = json.load(open(dump))
leaf["output_preimage"] = [str(int(h, 16)) for h in preimage_hex]
json.dump(leaf, open(out, "w"))
print("preimage:", leaf["output_preimage"])
