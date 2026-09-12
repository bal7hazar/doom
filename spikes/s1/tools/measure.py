#!/usr/bin/env python3
"""Spike S1 - throwaway measurement driver.

Runs `scarb execute --print-resource-usage` repeatedly and parses the resource
block.  Two helpers:

  prim   : difference two run lengths to isolate the per-iteration cost of a
           primitive (cancels bootstrap + serialization overhead).
  tics   : run the prototype for t = 0..N tics and difference consecutive runs
           to obtain a per-tic step profile (mean, p50, p99, max).

Usage:
  measure.py prim <pkg_dir> <ops.json> <out.json>
  measure.py tics <pkg_dir> <scenario> <n_tics> <out.json>
"""
import json
import re
import subprocess
import sys
import os

RE = re.compile(r"^\s*([a-z_ ]+):\s*([0-9,]+)\s*$")


def run(pkg_dir, args):
    env = dict(os.environ, ASDF_SCARB_VERSION="2.16.0")
    p = subprocess.run(
        ["scarb", "execute", "--no-build", "--output", "none",
         "--print-resource-usage", "--arguments", ",".join(str(a) for a in args)],
        cwd=pkg_dir, capture_output=True, text=True, env=env)
    if p.returncode != 0:
        raise SystemExit("execute failed for args %s:\n%s\n%s" % (args, p.stdout, p.stderr))
    out = {}
    for line in p.stdout.splitlines():
        m = RE.match(line)
        if m:
            out[m.group(1).strip()] = int(m.group(2).replace(",", ""))
    if "steps" not in out:
        raise SystemExit("no steps in output:\n" + p.stdout)
    return out


def build(pkg_dir):
    env = dict(os.environ, ASDF_SCARB_VERSION="2.16.0")
    p = subprocess.run(["scarb", "build"], cwd=pkg_dir, capture_output=True,
                       text=True, env=env)
    if p.returncode != 0:
        raise SystemExit(p.stdout + p.stderr)


def cmd_prim(pkg_dir, ops_file, out_file):
    ops = json.load(open(ops_file))
    build(pkg_dir)
    base = {}
    res = {}
    for entry in ops:
        op, n1, n2 = entry["op"], entry["n1"], entry["n2"]
        r1 = run(pkg_dir, [op, n1])
        r2 = run(pkg_dir, [op, n2])
        per = (r2["steps"] - r1["steps"]) / (n2 - n1)
        rc = (r2.get("range_check_builtin", 0) - r1.get("range_check_builtin", 0)) / (n2 - n1)
        pos = (r2.get("poseidon_builtin", 0) - r1.get("poseidon_builtin", 0)) / (n2 - n1)
        res[entry["name"]] = dict(op=op, steps_per_iter=round(per, 3),
                                  range_check_per_iter=round(rc, 3),
                                  poseidon_per_iter=round(pos, 3),
                                  raw=[r1["steps"], r2["steps"]], n=[n1, n2])
        if op == 0:
            base = res[entry["name"]]
        print("%-28s %8.2f steps/iter  (rc %5.2f)" % (entry["name"], per, rc))
    loop = base.get("steps_per_iter", 0.0)
    for k, v in res.items():
        v["steps_net_of_loop"] = round(v["steps_per_iter"] - loop, 3)
    json.dump(dict(loop_overhead=loop, ops=res), open(out_file, "w"), indent=2)
    print("\nbare-loop overhead: %.2f steps/iter" % loop)


def cmd_tics(pkg_dir, scenario, n_tics, out_file):
    build(pkg_dir)
    cum = []
    for t in range(0, n_tics + 1):
        r = run(pkg_dir, [scenario, t])
        cum.append(r)
        if t % 50 == 0:
            print("  tic %3d: %d steps" % (t, r["steps"]), flush=True)
    per = [cum[t]["steps"] - cum[t - 1]["steps"] for t in range(1, n_tics + 1)]
    rc = [cum[t].get("range_check_builtin", 0) - cum[t - 1].get("range_check_builtin", 0)
          for t in range(1, n_tics + 1)]
    s = sorted(per)
    stats = dict(
        scenario=scenario, n_tics=n_tics,
        total_steps=cum[n_tics]["steps"], base_steps=cum[0]["steps"],
        mean=round(sum(per) / len(per), 1),
        p50=s[len(s) // 2], p90=s[int(len(s) * 0.90)], p99=s[int(len(s) * 0.99)],
        max=s[-1], min=s[0],
        rc_mean=round(sum(rc) / len(rc), 1),
        per_tic=per,
    )
    json.dump(stats, open(out_file, "w"), indent=2)
    print("scenario %s: mean %.1f  p50 %d  p90 %d  p99 %d  max %d  (base %d)"
          % (scenario, stats["mean"], stats["p50"], stats["p90"], stats["p99"],
             stats["max"], stats["base_steps"]))


if __name__ == "__main__":
    if sys.argv[1] == "prim":
        cmd_prim(sys.argv[2], sys.argv[3], sys.argv[4])
    elif sys.argv[1] == "tics":
        cmd_tics(sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), sys.argv[5])
    else:
        raise SystemExit(__doc__)
