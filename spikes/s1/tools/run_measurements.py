#!/usr/bin/env python3
"""Spike S1 - throwaway driver for the whole measurement campaign.

Produces, under spikes/s1/results/:
  scenarios.json      per-tic step distribution (mean/p50/p90/p99/max) x 4 scenarios
  optimisations.json  steps/tic with each R2 optimisation on and off
  subsystems.json     differential cost of one call to each subsystem
"""
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROTO = os.path.join(ROOT, "proto")
RESULTS = os.path.join(ROOT, "results")
RE = re.compile(r"^\s*([a-z_ ]+):\s*([0-9,]+)\s*$")
ENV = dict(os.environ, ASDF_SCARB_VERSION="2.16.0")

# opts order: reject, cadence, three, dedup, bboxreject(Doom order), fastsector
FULL = (1, 1, 1, 0, 0, 1)
NONE = (0, 0, 0, 0, 1, 0)


def execute(target, args):
    p = subprocess.run(
        ["scarb", "execute", "--no-build", "--executable-name", target,
         "--output", "none", "--print-resource-usage",
         "--arguments", ",".join(str(a) for a in args)],
        cwd=PROTO, capture_output=True, text=True, env=ENV)
    if p.returncode != 0:
        raise SystemExit("FAILED %s %s\n%s%s" % (target, args, p.stdout, p.stderr))
    out = {}
    for line in p.stdout.splitlines():
        m = RE.match(line)
        if m:
            out[m.group(1).strip()] = int(m.group(2).replace(",", ""))
    return out


def build():
    p = subprocess.run(["scarb", "build"], cwd=PROTO, capture_output=True,
                       text=True, env=ENV)
    if p.returncode != 0:
        raise SystemExit(p.stdout + p.stderr)


def per_tic(scenario, n_tics, opts):
    """Cumulative steps at every tic count, differenced."""
    cum = []
    for t in range(0, n_tics + 1):
        cum.append(execute("proto", (scenario, t) + tuple(opts))["steps"])
    per = [cum[t] - cum[t - 1] for t in range(1, n_tics + 1)]
    s = sorted(per)
    return dict(
        base_steps=cum[0], total_steps=cum[n_tics],
        mean=round(sum(per) / len(per), 1), p50=s[len(s) // 2],
        p90=s[int(len(s) * 0.90)], p99=s[int(len(s) * 0.99)],
        max=s[-1], min=s[0], per_tic=per)


def mean_only(scenario, n_tics, opts):
    a = execute("proto", (scenario, 0) + tuple(opts))
    b = execute("proto", (scenario, n_tics) + tuple(opts))
    return dict(
        mean=round((b["steps"] - a["steps"]) / n_tics, 1),
        rc_mean=round((b.get("range_check_builtin", 0)
                       - a.get("range_check_builtin", 0)) / n_tics, 1),
        total_steps=b["steps"], base_steps=a["steps"])


def cmd_scenarios(n_tics):
    names = {0: "player only", 1: "+5 monsters dormant",
             2: "+5 monsters awake and chasing", 3: "+1 hitscan per 10 tics"}
    out = {}
    for sc in (0, 1, 2, 3):
        r = per_tic(sc, n_tics, FULL)
        r["name"] = names[sc]
        out[str(sc)] = r
        print("%-32s mean %8.1f  p50 %7d  p90 %7d  p99 %7d  max %7d"
              % (names[sc], r["mean"], r["p50"], r["p90"], r["p99"], r["max"]),
              flush=True)
    json.dump(out, open(os.path.join(RESULTS, "scenarios.json"), "w"), indent=2)


def cmd_optimisations(n_tics):
    # each row: label, opts tuple
    rows = [
        ("baseline (no optimisation)", NONE),
        ("cumulative: + R2-A2 REJECT", (1, 0, 0, 0, 1, 0)),
        ("cumulative: + R2-A3 AI cadencing", (1, 1, 0, 0, 1, 0)),
        ("cumulative: + R2-A4 3-array half-plane", (1, 1, 1, 0, 1, 0)),
        ("cumulative: + R2-A5 blockmap dedup", (1, 1, 1, 1, 1, 0)),
        ("cumulative: + reject reorder", (1, 1, 1, 1, 0, 0)),
        ("cumulative: + uniform-cell sector", (1, 1, 1, 1, 0, 1)),
        ("best (dedup off)", (1, 1, 1, 0, 0, 1)),
        ("alone: R2-A2 REJECT", (1, 0, 0, 0, 1, 0)),
        ("alone: R2-A3 cadencing", (0, 1, 0, 0, 1, 0)),
        ("alone: R2-A4 3-array", (0, 0, 1, 0, 1, 0)),
        ("alone: R2-A5 dedup", (0, 0, 0, 1, 1, 0)),
        ("alone: reject reorder", (0, 0, 0, 0, 0, 0)),
        ("alone: uniform-cell sector", (0, 0, 0, 0, 1, 1)),
    ]
    out = {}
    for sc in (1, 2, 3):
        out[str(sc)] = []
        print("--- scenario %d ---" % sc, flush=True)
        for label, opts in rows:
            if opts is None:
                continue
            r = mean_only(sc, n_tics, opts)
            r["label"] = label
            r["opts"] = list(opts)
            out[str(sc)].append(r)
            print("  %-42s %9.1f steps/tic" % (label, r["mean"]), flush=True)
    json.dump(out, open(os.path.join(RESULTS, "optimisations.json"), "w"), indent=2)


SUBSYS = [
    ("empty loop", 0, 200, 400),
    ("point_in_subsector (BSP descent)", 1, 100, 200),
    ("collect_bbox (player radius)", 2, 100, 200),
    ("box_crosses_three (1 line)", 3, 200, 400),
    ("box_crosses_six (1 line)", 4, 200, 400),
    ("  baseline for the two above", 5, 200, 400),
    ("try_move (player)", 6, 50, 100),
    ("check_sight (monster -> player)", 7, 20, 40),
    ("reject_blocks lookup", 8, 200, 400),
    ("path_traverse (hitscan, 2048u)", 9, 20, 40),
    ("monster_think (awake, chasing)", 10, 20, 40),
    ("step_tic scenario 2", 11, 20, 40),
    ("step_tic scenario 0 (player only)", 12, 40, 80),
    ("collect_ray (sight distance)", 13, 20, 40),
    ("sine + cosine", 14, 200, 400),
    ("point_to_angle", 15, 200, 400),
    ("genesis + checksum (5 mobjs)", 16, 20, 40),
    ("line_side_three (coeffs in hand)", 17, 200, 400),
    ("line_side_six (6 array reads)", 18, 200, 400),
    ("try_move (monster radius)", 19, 50, 100),
    ("sector_at_fast (uniform cell)", 20, 100, 200),
    ("tic loop overhead (empty tics)", 21, 100, 200),
]


def cmd_subsystems():
    out = {}
    for label, op, n1, n2 in SUBSYS:
        for opts, tag in ((FULL, "opt"), (NONE, "base")):
            a = execute("probe", (op, n1) + tuple(opts))
            b = execute("probe", (op, n2) + tuple(opts))
            per = (b["steps"] - a["steps"]) / (n2 - n1)
            rc = (b.get("range_check_builtin", 0)
                  - a.get("range_check_builtin", 0)) / (n2 - n1)
            out.setdefault(label, {})[tag] = dict(
                op=op, steps_per_call=round(per, 1), rc_per_call=round(rc, 1))
        print("%-38s opt %9.1f   unopt %9.1f"
              % (label, out[label]["opt"]["steps_per_call"],
                 out[label]["base"]["steps_per_call"]), flush=True)
    json.dump(out, open(os.path.join(RESULTS, "subsystems.json"), "w"), indent=2)


if __name__ == "__main__":
    build()
    what = sys.argv[1]
    if what == "scenarios":
        cmd_scenarios(int(sys.argv[2]))
    elif what == "optimisations":
        cmd_optimisations(int(sys.argv[2]))
    elif what == "subsystems":
        cmd_subsystems()
    else:
        raise SystemExit(__doc__)
