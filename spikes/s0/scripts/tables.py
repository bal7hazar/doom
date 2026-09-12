#!/usr/bin/env python3
"""Render the results/*/summary.json files as the Markdown tables used in
docs/spikes/S0.md.

Usage: tables.py [results_dir]
"""
import json
import os
import re
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


def standalone_steps():
    """n_steps of each program run WITHOUT the bootloader, from resources.sh."""
    out = {}
    d = os.path.join(RESULTS, "resource-usage")
    if not os.path.isdir(d):
        return out
    for f in os.listdir(d):
        m = re.search(r"steps:\s*([\d,]+)", open(os.path.join(d, f), errors="replace").read())
        if m:
            out[f[:-4]] = int(m.group(1).replace(",", ""))
    return out


def builtins(s):
    er = s.get("vm_execution_resources") or {}
    b = er.get("builtin_instance_counter") or {}
    return ", ".join(f"{k.replace('_builtin','')} {v}" for k, v in sorted(b.items()) if v) or "—"


def fmt(v, unit="", nd=2):
    if v is None:
        return "—"
    return f"{v:.{nd}f}{unit}" if isinstance(v, float) else f"{v}{unit}"


def mb(b):
    return "—" if not b else f"{b/1e6:.2f}"


def why(s):
    if s.get("ok"):
        return "OK"
    return "**FAIL** — " + (s.get("panic_message") or s.get("error") or "see prove.log.tail")


def main():
    rows = load()
    sa = standalone_steps()

    print("### A. Programmes, route bootloader, `canonical_small`\n")
    print("| programme | args | steps seuls | steps + bootloader | builtins (run bootloader) "
          "| résultat | mur (s) | CPU (s) | RSS max (GiB) | preuve (MB) | preuve (felts) |")
    print("|---|---|---:|---:|---|---|---:|---:|---:|---:|---:|")
    for tag, s in rows.items():
        if not tag.endswith("_cs_bl") or tag.startswith("steps_k"):
            continue
        key = f"{s['program']}_n1000"
        print(f"| `{s['program']}` | {s['args'][0]} | {sa.get(key,'—'):,} | {s['n_steps']:,} "
              f"| {builtins(s)} | {why(s)} | {fmt(s.get('wall_s'))} | {fmt(s.get('cpu_s'))} "
              f"| {fmt(s.get('max_rss_gib'))} | {mb(s.get('proof_bytes'))} "
              f"| {s.get('proof_felts','—'):,} |")

    print("\n### B. Route standalone (`run_and_prove --program_type executable`)\n")
    print("| programme | args | steps | résultat |")
    print("|---|---|---:|---|")
    for tag, s in rows.items():
        if not tag.endswith("_cs_sa"):
            continue
        print(f"| `{s['program']}` | {s['args'][0]} | {s['n_steps']:,} | {why(s)} |")

    print("\n### C. `steps_k` — montée en taille\n")
    print("| k | params | steps (bootloader compris) | mur (s) | CPU (s) | RSS max (GiB) "
          "| preuve (MB) | preuve (felts) | résultat |")
    print("|---:|---|---:|---:|---:|---:|---:|---:|---|")
    def kof(tag):
        m = re.match(r"steps_k(\d+)_", tag)
        return int(m.group(1)) if m else 99
    for tag in sorted([t for t in rows if t.startswith("steps_k") and "_lv_" not in t],
                      key=lambda t: (rows[t]["params"], kof(t))):
        s = rows[tag]
        print(f"| {kof(tag)} | `{s['params']}` | {s['n_steps']:,} | {fmt(s.get('wall_s'))} "
              f"| {fmt(s.get('cpu_s'))} | {fmt(s.get('max_rss_gib'))} "
              f"| {mb(s.get('proof_bytes'))} | {s.get('proof_felts') or '—'} | {why(s)} |")

    print("\n### D. Leviers mémoire à k = 19 (R1-A5)\n")
    print("| variante | mur (s) | CPU (s) | RSS max (GiB) | Δ RSS vs baseline | preuve (MB) "
          "| preuve (felts) | résultat |")
    print("|---|---:|---:|---:|---:|---:|---:|---|")
    base = rows.get("steps_k19_lv_baseline", {})
    b_rss = base.get("max_rss_gib")
    for tag in sorted(t for t in rows if "_lv_" in t):
        s = rows[tag]
        d = ("—" if (b_rss is None or s.get("max_rss_gib") is None)
             else f"{s['max_rss_gib'] - b_rss:+.3f}")
        print(f"| `{tag.replace('steps_k19_lv_','')}` | {fmt(s.get('wall_s'))} "
              f"| {fmt(s.get('cpu_s'))} | {fmt(s.get('max_rss_gib'),'',3)} | {d} "
              f"| {mb(s.get('proof_bytes'))} | {s.get('proof_felts') or '—'} | {why(s)} |")

    print("\n### E. Temps par étape (spans tracing, secondes)\n")
    stages = [("cairo run", "VM"), ("adapt", "adapt"),
              ("Write Preprocessed trace", "pp trace"),
              ("Compute preprocessed trace commitment", "pp commit"),
              ("Write Base trace", "base trace"),
              ("Compute base trace commitment", "base commit"),
              ("Write interaction trace", "inter trace"),
              ("Compute interaction trace commitment", "inter commit"),
              ("Prove STARKs", "STARK+FRI"), ("verify_cairo", "verify")]
    print("| tag | " + " | ".join(l for _, l in stages) + " |")
    print("|---" * (len(stages) + 1) + "|")
    for tag, s in rows.items():
        sp = s.get("spans_s") or {}
        if not sp or not s.get("ok"):
            continue
        print(f"| `{tag}` | " + " | ".join(fmt(sp.get(k)) for k, _ in stages) + " |")


if __name__ == "__main__":
    main()
