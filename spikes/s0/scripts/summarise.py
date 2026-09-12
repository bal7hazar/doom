#!/usr/bin/env python3
"""Turn one prove.sh run directory into a machine-readable summary.json.

Usage: summarise.py <out_dir> <executable> <args> <params> <route> <n_steps> <status>

Pulls together:
  * wall / user / sys time and peak RSS from the `/usr/bin/time -l` block,
  * per-stage timings from the prover's tracing spans (cairo run, adapt, prove_cairo,
    verify_cairo),
  * proof size in bytes and, for the cairo-serde format, in felts,
  * the builtin counts the VM actually used.
"""
import json
import os
import re
import sys


def parse_time_block(path):
    """macOS `/usr/bin/time -l` block -> dict."""
    out = {}
    if not os.path.exists(path):
        return out
    txt = open(path, errors="replace").read()
    m = re.search(r"([\d.]+)\s+real\s+([\d.]+)\s+user\s+([\d.]+)\s+sys", txt)
    if m:
        out["wall_s"] = float(m.group(1))
        out["user_s"] = float(m.group(2))
        out["sys_s"] = float(m.group(3))
        out["cpu_s"] = round(float(m.group(2)) + float(m.group(3)), 3)
    m = re.search(r"(\d+)\s+maximum resident set size", txt)
    if m:
        out["max_rss_bytes"] = int(m.group(1))
        out["max_rss_gib"] = round(int(m.group(1)) / 2**30, 3)
    m = re.search(r"(\d+)\s+peak memory footprint", txt)
    if m:
        out["peak_footprint_bytes"] = int(m.group(1))
        out["peak_footprint_gib"] = round(int(m.group(1)) / 2**30, 3)
    return out


_DUR = re.compile(r"([\d.]+)(ns|µs|ms|s|m)$")
_SCALE = {"ns": 1e-9, "µs": 1e-6, "ms": 1e-3, "s": 1.0, "m": 60.0}


def _dur(tok):
    m = _DUR.match(tok)
    return float(m.group(1)) * _SCALE[m.group(2)] if m else None


def parse_spans(path):
    """Top-level span durations from the tracing `close time.busy=` lines."""
    spans = {}
    if not os.path.exists(path):
        return spans
    want = ("cairo run", "adapt", "prove_cairo", "verify_cairo", "stwo_run_and_prove",
            "run_and_prove",
            # inside prove_cairo (crates/prover/src/prover.rs)
            "Write Preprocessed trace", "Precompute Twiddles",
            "Compute preprocessed trace commitment", "Write Base trace",
            "Compute base trace commitment", "Write interaction trace",
            "Compute interaction trace commitment", "Prove STARKs")
    for line in open(path, errors="replace"):
        if "close" not in line or "time.busy=" not in line:
            continue
        m = re.search(r"time\.busy=(\S+)", line)
        if not m:
            continue
        d = _dur(m.group(1))
        if d is None:
            continue
        for name in want:
            # span names appear as `...:<name>:` in the log prefix
            if f":{name}:" in line or line.strip().startswith(name):
                # keep the largest occurrence (spans can repeat for sub-runs)
                if d > spans.get(name, 0.0):
                    spans[name] = round(d, 3)
    return spans


def proof_info(out_dir):
    for name in ("proof.cairo_serde.json", "proof.json"):
        p = os.path.join(out_dir, name)
        if os.path.exists(p) and os.path.getsize(p) > 0:
            info = {"proof_file": name, "proof_bytes": os.path.getsize(p)}
            if name.startswith("proof.cairo_serde"):
                try:
                    info["proof_felts"] = len(json.load(open(p)))
                except Exception:
                    pass
            return info
    return {"proof_file": None, "proof_bytes": 0}


def main():
    out_dir, executable, args, params, route, n_steps, status = sys.argv[1:8]
    s = {
        "program": os.path.basename(executable).replace(".executable.json", ""),
        "args": json.load(open(args)) if os.path.exists(args) else None,
        "args_file": os.path.basename(args)[:-5],
        "params": os.path.basename(params),
        "route": route,
        "n_steps": int(n_steps),
        "ok": status == "0",
        "exit_status": int(status),
    }
    for f in ("vm_execution_resources.json", "execution_resources.json"):
        p = os.path.join(out_dir, f)
        if os.path.exists(p):
            try:
                s[f.replace(".json", "")] = json.load(open(p))
            except Exception:
                pass
    s.update(parse_time_block(os.path.join(out_dir, "prove.time")))
    s["spans_s"] = parse_spans(os.path.join(out_dir, "prove.log"))
    s.update(proof_info(out_dir))

    # first panic / error line, if any
    log = os.path.join(out_dir, "prove.log")
    if os.path.exists(log):
        txt = open(log, errors="replace").read()
        m = re.search(r"thread '.*?' .*?panicked at ([^\n]+)\n([^\n]+)", txt)
        if m:
            s["panic_location"] = m.group(1).strip()
            s["panic_message"] = m.group(2).strip()
        m = re.search(r"Proving failed(?: with error)?:? ([^\n]+)", txt)
        if m:
            s["error"] = m.group(1).strip()[:400]

    with open(os.path.join(out_dir, "summary.json"), "w") as fh:
        json.dump(s, fh, indent=2)
    print(json.dumps({k: v for k, v in s.items()
                      if k in ("program", "args", "params", "route", "n_steps", "ok",
                               "wall_s", "cpu_s", "max_rss_gib", "proof_bytes",
                               "proof_felts", "panic_message")}, indent=2))


if __name__ == "__main__":
    main()
