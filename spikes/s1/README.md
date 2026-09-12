# Spike S1 — cost per tic of the Cairo game core

Throwaway prototype. Its only products are the numbers and the design
recommendations in [`docs/spikes/S1.md`](../../docs/spikes/S1.md). None of this
code is meant to become `cairo/crates/*` or `cairo/doom/*`; the real crates
should be written from the recommendations, not ported from here.

```
spikes/s1/
├── tools/
│   ├── extract.py            freedoom1.wad -> Cairo constants (two representations)
│   ├── measure.py            differential primitive-cost driver
│   ├── run_measurements.py   scenario / optimisation / subsystem campaigns
│   ├── render_tables.py      results JSON -> the markdown tables in S1.md
│   ├── raw_dumps.sh          raw `--print-resource-usage` blocks
│   └── prim_ops*.json        primitive benchmark plans
├── prim/                     standalone Scarb package: primitive cost benchmark
├── proto/                    standalone Scarb package: the Doom tic prototype
└── results/                  every measurement, raw and parsed
```

## Reproducing

```sh
export ASDF_SCARB_VERSION=2.16.0
SCRATCH=...   # somewhere outside the repo; never commit WAD files
curl -L -o "$SCRATCH/freedoom-0.13.0.zip" \
  https://github.com/freedoom/freedoom/releases/download/v0.13.0/freedoom-0.13.0.zip
unzip -o -j "$SCRATCH/freedoom-0.13.0.zip" '*/freedoom1.wad' -d "$SCRATCH"

python3 tools/extract.py "$SCRATCH/freedoom1.wad" proto/src results
cp proto/src/tables.cairo prim/src/tables.cairo

(cd proto && scarb build && scarb cairo-test)          # 31 unit tests
python3 tools/measure.py prim prim tools/prim_ops.json  results/primitives.json
python3 tools/measure.py prim prim tools/prim_ops2.json results/primitives2.json
python3 tools/measure.py prim prim tools/prim_ops3.json results/primitives3.json
python3 tools/run_measurements.py subsystems
python3 tools/run_measurements.py scenarios    350
python3 tools/run_measurements.py optimisations 350
sh tools/raw_dumps.sh
python3 tools/render_tables.py
```

Profiling (note: **cairo-profiler 0.9.0 does not work** with Scarb 2.16
gas-less executables — it fails with `found an unexpected cycle during cost
computation`; 0.17.0 does):

```sh
asdf install cairo-profiler 0.17.0
PROF=~/.asdf/installs/cairo-profiler/0.17.0/bin/cairo-profiler
cd proto
scarb execute --executable-name proto --output standard \
  --save-profiler-trace-data --arguments 3,60,1,1,1,0,0,1
# do NOT pass --show-inlined-functions: it folds the recursive loop functions
# Cairo generates for `while` into their parent and makes `run` look like 24%
# of the program.
$PROF build-profile target/execute/proto/execution<N>/cairo_profiler_trace.json \
  -o ../results/profile.pb.gz
go tool pprof -top -sample_index=steps -nodecount=25 ../results/profile.pb.gz
```

## Executable arguments

```
proto main(scenario, n_tics, reject, cadence, three, dedup, bboxreject, fastsector)
probe probe_main(op, n, reject, cadence, three, dedup, bboxreject, fastsector)
```

`scenario`: 0 player only, 1 +5 dormant monsters, 2 +5 chasing monsters,
3 = 2 plus one hitscan every 10 tics. The five flags are the R2 optimisations,
each switchable on its own (see `mobj.cairo::Opts`).
