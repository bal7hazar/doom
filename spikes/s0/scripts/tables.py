#!/usr/bin/env python3
"""Render the results/*/summary.json files as the Markdown tables used in S0.md.

Usage: tables.py [results_dir]
"""
import json
import os
import sys

RESULTS = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "results")


def load():
    rows = {}
    for tag in sorted(os.listdir(RESULTS)):
        p = os.path.join(RESULTS, tag, "summary.json")
        if os.path.exists(p):
            try:
                rows[tag] = json.load(open(p))
            except Exception:
                pass
    return rows


def builtins(s):
    er = s.get("vm_execution_resources") or {}
    b = er.get("builtin_instance_counter") or er.get("builtin_instance_counts") or {}
    parts = [f"{k.replace('_builtin', '')} {v}" for k, v in sorted(b.items()) if v]
    return ", ".join(parts) or "—"


def fmt(v, unit="", nd=2):
    if v is None:
        return "—"
    if isinstance(v, float):
        return f"{v:.{nd}f}{unit}"
    return f"{v}{unit}"


def mb(b):
    return "—" if not b else f"{b / 1e6:.2f} MB"


def ok(s):
    return "OK" if s.get("ok") else "**FAIL**"


def main():
    rows = load()

    print("### Per-program pipeline (bootloader route, canonical_small)\n")
    print("| program | args | steps (app) | steps (+bootloader) | builtins (app run) "
          "| prove+verify | wall | CPU | peak RSS | proof bytes | proof felts |")
    print("|---|---|---|---|---|---|---|---|---|---|---|")
    for tag, s in rows.items():
        if not tag.endswith("_cs_bl") or tag.startswith("steps_k"):
            continue
        print(f"| {s['program']} | {s['args']} | — | {s['n_steps']:,} | {builtins(s)} "
              f"| {ok(s)} | {fmt(s.get('wall_s'),' s')} | {fmt(s.get('cpu_s'),' s')} "
              f"| {fmt(s.get('max_rss_gib'),' GiB')} | {mb(s.get('proof_bytes'))} "
              f"| {s.get('proof_felts','—')} |")

    print("\n### steps_k scaling\n")
    print("| tag | params | steps | wall | CPU | peak RSS | proof bytes | proof felts | result |")
    print("|---|---|---|---|---|---|---|---|---|")
    for tag, s in rows.items():
        if not tag.startswith("steps_k"):
            continue
        print(f"| {tag} | {s['params']} | {s['n_steps']:,} | {fmt(s.get('wall_s'),' s')} "
              f"| {fmt(s.get('cpu_s'),' s')} | {fmt(s.get('max_rss_gib'),' GiB')} "
              f"| {mb(s.get('proof_bytes'))} | {s.get('proof_felts','—')} "
              f"| {ok(s)}{(' — ' + s['panic_message']) if s.get('panic_message') else ''}"
              f"{(' — ' + s['error']) if s.get('error') else ''} |")

    print("\n### Stage timings (tracing spans, seconds)\n")
    print("| tag | cairo run | adapt | prove_cairo | verify_cairo |")
    print("|---|---|---|---|---|")
    for tag, s in rows.items():
        sp = s.get("spans_s") or {}
        if not sp:
            continue
        print(f"| {tag} | {fmt(sp.get('cairo run'),' s')} | {fmt(sp.get('adapt'),' s')} "
              f"| {fmt(sp.get('prove_cairo'),' s')} | {fmt(sp.get('verify_cairo'),' s')} |")


if __name__ == "__main__":
    main()
