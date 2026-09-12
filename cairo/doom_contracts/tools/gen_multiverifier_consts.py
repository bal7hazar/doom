#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Regenerates the hard-coded multiverifier constants of the vendored circuit verifier from a
circuit registry JSON (`spikes/s4/registry/<name>/registry.json`, the file `leaf-prover` and
`stwo_run_and_prove_recursive_tree` consume).

It is a Python port of upstream `circuit_params/tests/cairo_consts_test.rs` (proving@cd7bc5f):
the same layout rule (`layout_from_component_sizes`: components in declaration order — eq,
qm31_ops, triple_xor, m31_to_u32, blake_g_gate — then the fixed lookup tables seq_16 and the
bitwise-xor tables of 4/7/8/9/10 bits; then a STABLE sort by log size), the same component
naming and the same `*_IDX` legacy names. It rewrites the `BEGIN GENERATED … END GENERATED`
sections of `multiverifier_consts.cairo` and `preprocessed_columns.cairo` and stamps the registry
name and multiverifier circuit hash in a header comment.

The registry JSON is the only source that carries the component sizes: a root proof's public
data does not (its preprocessed root is folded into `circuit_hash`; the sizes are the verifier's
own constants), so `--from-proof` is deliberately not offered.

Usage:
  tools/gen_multiverifier_consts.py --registry doom            # spikes/s4/registry/doom/registry.json
  tools/gen_multiverifier_consts.py --registry-json path/to/registry.json --name custom
  tools/gen_multiverifier_consts.py --registry doom --check    # CI: fail if the files differ
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent.parent
CIRCUIT_AIR_SRC = HERE.parent / "vendor/stwo_cairo_verifier/crates/circuit_air/src"
BEGIN_MARKER = "// === BEGIN GENERATED (see cairo_consts_test.rs; running it with FIX=1 regenerates) ==="
END_MARKER = "// === END GENERATED ==="

# Preprocessed columns per variable-size component, in commitment order (circuit_common/src/
# preprocessed.rs `define_preprocessed_columns!`), components in `layout_from_component_sizes`
# order. The registry key of each component is given alongside its Cairo `PerComponent` field.
VARIABLE_COMPONENTS = [
    ("eq", "eq", ["eq_in0_address", "eq_in1_address"]),
    ("qm31_ops", "qm31_ops", [
        "qm31_ops_add_flag", "qm31_ops_sub_flag", "qm31_ops_mul_flag",
        "qm31_ops_pointwise_mul_flag", "qm31_ops_in0_address", "qm31_ops_in1_address",
        "qm31_ops_out_address", "qm31_ops_mults",
    ]),
    ("triple_xor", "triple_xor", [
        "triple_xor_input_addr_0", "triple_xor_input_addr_1", "triple_xor_input_addr_2",
        "triple_xor_output_addr", "triple_xor_multiplicity",
    ]),
    ("m31_to_u32", "m_31_to_u_32", [
        "m31_to_u32_input_addr", "m31_to_u32_output_addr", "m31_to_u32_multiplicity",
    ]),
    ("blake_g_gate", "blake_g_gate", [
        "blake_g_gate_input_addr_a", "blake_g_gate_input_addr_b", "blake_g_gate_input_addr_c",
        "blake_g_gate_input_addr_d", "blake_g_gate_input_addr_f0", "blake_g_gate_input_addr_f1",
        "blake_g_gate_output_addr_a", "blake_g_gate_output_addr_b",
        "blake_g_gate_output_addr_c", "blake_g_gate_output_addr_d", "blake_g_gate_multiplicity",
    ]),
]
SEQ_LOG_SIZE = 16
XOR_TABLE_N_BITS = [4, 7, 8, 9, 10]
N_XOR_TABLE_COLUMNS = 3


def fixed_column_layout() -> list[tuple[str, int]]:
    out = [(f"seq_{SEQ_LOG_SIZE}", SEQ_LOG_SIZE)]
    for n in XOR_TABLE_N_BITS:
        out += [(f"bitwise_xor_{n}_{i}", 2 * n) for i in range(N_XOR_TABLE_COLUMNS)]
    return out


def layout(sizes: dict[str, int]) -> list[tuple[str, int]]:
    entries: list[tuple[str, int]] = []
    for key, _, ids in VARIABLE_COMPONENTS:
        entries += [(cid, sizes[key]) for cid in ids]
    entries += fixed_column_layout()
    entries.sort(key=lambda e: e[1])  # Python's sort is stable, like Rust's sort_by_key
    return entries


def cairo_component(cid: str) -> str:
    for _, cairo, ids in VARIABLE_COMPONENTS:
        if cid in ids:
            return cairo
    if cid == "seq_16":
        return "range_check_16"
    for n, cairo in ((4, "verify_bitwise_xor_4"), (7, "verify_bitwise_xor_7"),
                     (8, "verify_bitwise_xor_8"), (9, "verify_bitwise_xor_9"),
                     (10, "verify_bitwise_xor_12")):
        if cid.startswith(f"bitwise_xor_{n}_"):
            return cairo
    sys.exit(f"unknown preprocessed column id {cid!r}")


def idx_const_name(cid: str) -> str:
    renamed = {
        "qm31_ops_add_flag": "add_flag", "qm31_ops_sub_flag": "sub_flag",
        "qm31_ops_mul_flag": "mul_flag", "qm31_ops_pointwise_mul_flag": "pointwise_mul_flag",
        "qm31_ops_in0_address": "op_0_addr", "qm31_ops_in1_address": "op_1_addr",
        "qm31_ops_out_address": "dst_addr", "qm31_ops_mults": "qm_31_ops_multiplicity",
        "blake_g_gate_input_addr_f0": "blake_g_gate_input_addr_f_0",
        "blake_g_gate_input_addr_f1": "blake_g_gate_input_addr_f_1",
    }.get(cid)
    if renamed is None and cid.startswith("m31_to_u32_"):
        return f"M_31_TO_U_32_{cid[len('m31_to_u32_'):].upper()}_IDX"
    return f"{(renamed or cid).upper()}_IDX"


def header(name: str, mv_hash: list[str]) -> list[str]:
    words = " ".join(w[2:].zfill(8) for w in mv_hash)
    return [
        f"// Generated by cairo/doom_contracts/tools/gen_multiverifier_consts.py from the circuit",
        f"// registry `{name}` (multiverifier circuit_hash {words}).",
        "",
    ]


def render_multiverifier_consts(name: str, mv_hash: list[str], fri: dict, sizes: dict) -> str:
    lay = layout(sizes)
    log_of = dict(lay)
    security = fri["pow_bits"] + fri["log_blowup_factor"] * fri["n_queries"]
    lines = [BEGIN_MARKER, ""] + header(name, mv_hash) + [
        "/// Expected PCS config of the multiverifier circuit's proof.",
        "///",
        "/// Pinned to the production registry's proof config, so the verifier accepts",
        "/// only proofs produced with that canonical configuration. This pins",
        "/// every FRI security parameter (a weaker config — fewer queries, smaller",
        "/// blowup, or less proof-of-work — is rejected, independently of stwo's",
        "/// `security_bits >= SECURITY_BITS` floor).",
        f"/// Note `pow_bits + log_blowup_factor * n_queries = {fri['pow_bits']} + "
        f"{fri['log_blowup_factor']} * {fri['n_queries']} = {security} = SECURITY_BITS`.",
        "pub fn circuit_pcs_config() -> PcsConfig {",
        "    PcsConfig {",
        "        fri_config: FriConfig {",
        f"            pow_bits: {fri['pow_bits']},",
        f"            log_blowup_factor: {fri['log_blowup_factor']},",
        f"            log_last_layer_degree_bound: {fri['log_last_layer_degree_bound']},",
        f"            n_queries: {fri['n_queries']},",
        f"            fold_step: {fri['fold_step']},",
        "        },",
        "    }",
        "}",
        "",
        "/// Each component's log size.",
        "pub const COMPONENT_LOG_SIZES: PerComponent<u32> = PerComponent {",
        f"    eq: {log_of['eq_in0_address']},",
        f"    qm31_ops: {log_of['qm31_ops_add_flag']},",
        f"    triple_xor: {log_of['triple_xor_input_addr_0']},",
        f"    m_31_to_u_32: {log_of['m31_to_u32_input_addr']},",
        f"    blake_g_gate: {log_of['blake_g_gate_input_addr_a']},",
        f"    verify_bitwise_xor_8: {log_of['bitwise_xor_8_0']},",
        f"    verify_bitwise_xor_12: {log_of['bitwise_xor_10_0']},",
        f"    verify_bitwise_xor_4: {log_of['bitwise_xor_4_0']},",
        f"    verify_bitwise_xor_7: {log_of['bitwise_xor_7_0']},",
        f"    verify_bitwise_xor_9: {log_of['bitwise_xor_9_0']},",
        f"    range_check_16: {log_of['seq_16']},",
        "};",
        "",
        "/// Per-column log sizes of the multiverifier circuit's preprocessed trace,",
        "/// in size-sorted column order — the same order as the index constants in",
        "/// `crate::preprocessed_columns`. Every column of a component shares that",
        "/// component's log size, so each entry references the owning component's",
        "/// `COMPONENT_LOG_SIZES` field.",
        f"pub const PREPROCESSED_COLUMN_LOG_SIZES: [u32; {len(lay)}] = [",
    ]
    for i, (cid, _) in enumerate(lay):
        sep = "" if i + 1 == len(lay) else ","
        lines.append(f"    COMPONENT_LOG_SIZES.{cairo_component(cid)}{sep} // {cid}")
    lines += ["];", "", END_MARKER]
    return "\n".join(lines)


def render_preprocessed_columns(name: str, mv_hash: list[str], sizes: dict) -> str:
    lay = layout(sizes)
    lines = [BEGIN_MARKER, ""] + header(name, mv_hash) + [
        f"pub const NUM_PREPROCESSED_COLUMNS: u32 = {len(lay)};",
    ]
    idx = 0
    while idx < len(lay):
        cid, log_size = lay[idx]
        component = cairo_component(cid)
        end = idx
        while end < len(lay) and cairo_component(lay[end][0]) == component:
            end += 1
        lines.append("")
        if component == "qm31_ops":
            lines.append(f"// qm31_ops_* (log_size={log_size}). Hand-ported components reference "
                         "these without the")
            lines.append("// `qm31_ops_` prefix and with legacy names (`OP_0/OP_1/DST` for "
                         "`in0/in1/out`).")
        for cid2, _ in lay[idx:end]:
            lines.append(f"pub const {idx_const_name(cid2)}: PreprocessedColumnIdx = {idx};")
            idx += 1
    lines += ["", END_MARKER]
    return "\n".join(lines)


def replace_section(path: Path, rendered: str, check: bool) -> bool:
    committed = path.read_text()
    begin = committed.index(BEGIN_MARKER)
    end = committed.index(END_MARKER) + len(END_MARKER)
    if committed[begin:end] == rendered:
        return True
    if check:
        print(f"{path}: generated section differs from the registry")
        return False
    path.write_text(committed[:begin] + rendered + committed[end:])
    print("wrote", path)
    return True


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--registry", help="name under spikes/s4/registry/")
    g.add_argument("--registry-json", type=Path)
    ap.add_argument("--name", help="registry name for the header (defaults to --registry)")
    ap.add_argument("--check", action="store_true", help="verify instead of rewriting")
    a = ap.parse_args()

    path = a.registry_json or REPO / "spikes/s4/registry" / a.registry / "registry.json"
    name = a.name or a.registry or path.parent.name
    reg = json.loads(path.read_text())
    cfg = reg["circuit_proof_configs"]["default"]
    mv = reg["multiverifiers"][0]
    assert mv["config"] == "default", "only the `default` multiverifier config is supported"
    sizes = cfg["component_log_sizes"]
    fri = cfg["fri_config"]

    ok = replace_section(CIRCUIT_AIR_SRC / "multiverifier_consts.cairo",
                         render_multiverifier_consts(name, mv["circuit_hash"], fri, sizes), a.check)
    ok &= replace_section(CIRCUIT_AIR_SRC / "preprocessed_columns.cairo",
                          render_preprocessed_columns(name, mv["circuit_hash"], sizes), a.check)
    lay = layout(sizes)
    print(f"registry {name}: multiverifier {' '.join(w[2:].zfill(8) for w in mv['circuit_hash'])}")
    print("component log sizes:", sizes, "| fri:", fri)
    print("preprocessed layout:", ", ".join(f"{c}={s}" for c, s in lay))
    if not ok:
        sys.exit(1)


if __name__ == "__main__":
    main()
