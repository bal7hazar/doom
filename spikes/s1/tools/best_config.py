#!/usr/bin/env python3
"""Spike S1 - pick the best combination of the two order-dependent flags.

`bboxreject` (Doom's reject order) and `fastsector` interact with R2-A4, so the
cumulative ladder in run_measurements.py cannot isolate them.  This enumerates
the four combinations with the other flags fixed at their best value.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from run_measurements import RESULTS, build, mean_only  # noqa: E402

if __name__ == "__main__":
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 350
    build()
    out = {}
    for bbox in (0, 1):
        for fast in (0, 1):
            opts = (1, 1, 1, 0, bbox, fast)
            row = {}
            for sc in (1, 2, 3):
                row[str(sc)] = mean_only(sc, n, opts)["mean"]
            key = "bboxreject=%d fastsector=%d" % (bbox, fast)
            out[key] = row
            print("%-32s sc1 %8.1f  sc2 %9.1f  sc3 %9.1f"
                  % (key, row["1"], row["2"], row["3"]), flush=True)
    json.dump(out, open(os.path.join(RESULTS, "best_config.json"), "w"), indent=2)
