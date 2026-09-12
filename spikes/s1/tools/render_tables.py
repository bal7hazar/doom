#!/usr/bin/env python3
"""Spike S1 - render the results JSON as the markdown tables used in S1.md."""
import json
import os

R = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "results")


def load(n):
    p = os.path.join(R, n)
    return json.load(open(p)) if os.path.exists(p) else None


def primitives():
    a = load("primitives.json")
    b = load("primitives2.json")
    c = load("primitives3.json")
    print("\n### Primitive costs (steps, net of the 8-step loop iteration)\n")
    print("| primitive | steps/call | net of loop | range checks |")
    print("|---|---:|---:|---:|")
    for src in (a, b, c):
        if not src:
            continue
        loop = src["loop_overhead"]
        for k, v in src["ops"].items():
            print("| %s | %.0f | %.0f | %.0f |"
                  % (k, v["steps_per_iter"], v["steps_per_iter"] - loop,
                     v["range_check_per_iter"]))


def scenarios():
    s = load("scenarios.json")
    if not s:
        return
    print("\n### Steps per tic, 350 scripted tics, all optimisations on\n")
    print("| scenario | mean | p50 | p90 | p99 | max | total (350 tics) |")
    print("|---|---:|---:|---:|---:|---:|---:|")
    for k in ("0", "1", "2", "3"):
        r = s[k]
        print("| %s | %.0f | %d | %d | %d | %d | %d |"
              % (r["name"], r["mean"], r["p50"], r["p90"], r["p99"], r["max"],
                 r["total_steps"]))


def optimisations():
    o = load("optimisations.json")
    if not o:
        return
    print("\n### Effect of each optimisation (mean steps/tic over 350 tics)\n")
    print("| configuration | scenario 1 (dormant) | scenario 2 (chasing) | scenario 3 (+hitscan) |")
    print("|---|---:|---:|---:|")
    labels = [r["label"] for r in o["1"]]
    for i, lab in enumerate(labels):
        print("| %s | %.0f | %.0f | %.0f |"
              % (lab, o["1"][i]["mean"], o["2"][i]["mean"], o["3"][i]["mean"]))


def subsystems():
    s = load("subsystems.json")
    if not s:
        return
    print("\n### Subsystem cost, one call (differential, steps)\n")
    print("| subsystem | optimised | unoptimised | ratio |")
    print("|---|---:|---:|---:|")
    for k, v in s.items():
        o = v["opt"]["steps_per_call"]
        b = v["base"]["steps_per_call"]
        print("| %s | %.0f | %.0f | %s |"
              % (k, o, b, ("%.2fx" % (b / o)) if o else "-"))


if __name__ == "__main__":
    primitives()
    scenarios()
    optimisations()
    subsystems()
