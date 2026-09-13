# Executable gameplay regression (P1.10)

This corpus uses only the public Scarb 2.16.0 `doom_run` entrypoints: `genesis`,
`step_tic`, and `run_segment`. Every scenario starts at real E1M1 genesis and supplies legal
32-bit command words. No state, health, actor, RNG, door or terminal status is injected.
It is independent of the internal roster representation (D33).

`corpus.py` defines 26 distinct command logs: the five existing historical replays plus
backwards and sideways collision, turns and momentum, diagonal sprint, zigzag, held/tapped
attack, fist/pistol/unowned weapon requests, use edges/held/released, retreat after pickups,
combat while moving, canonical input extrema and seeded arbitrary u32 commands. Purpose
labels describe the intended stimulus; the result reports the actually observed health,
weapon, ammo, counts and terminal state. At least twenty distinct final states, real pickups,
a kill, a genuine death and a real EXIT are required. The `exit_route` case explicitly
requires status 2, including during characterization; a different terminal outcome fails.

## Real EXIT route and additional pin

`exit_route.py` holds 139 explicit RLE groups expanding to 677 legal commands, discovered
from public inputs on D29 engine commit `8ae7f1ccf3102eff99dbd57228ced61cdb3abdc3`.
The player reaches the exit switch at tic 677 with 29 health, 0 kills, 4 items and 0 secrets.
The route traverses the two main doors, detours north around a blocking demon, then uses
the final door and exit switch. It is not a shortest-route claim. There is no random search
seed: `genesis(0)` selects E1M1, and the engine's initial P/M RNG cursors are 4/1.

The corpus appends 17 legal movement/attack words after the exit command: 694 supplied,
677 consumed, 17 excluded from D13/D14 and tic counts. Full/cut/empty-boundary checks cover
that suffix in both profiles. The expected final state/render/envelope and D14 were obtained
independently by full Scarb dev/proving replay and the Python oracle before adding the pin;
the native exploration and a Chromium replay also returned the same full envelope.
`goldens.json.case_provenance.exit_route` records its own D29 executable identities.
The original global provenance and all 25 previous golden objects are unchanged; they do
not pretend to originate from this later D29 executable. Existing cases were independently
revalidated against these same frozen D29 binaries before this addition.

This supplies real spawn-to-exit execution coverage. It does not establish a cryptographic
proof of a complete game, P3.7, AIR limits, proof latency, memory limits or browser fluidity.

## What is checked

For each corpus case, in **both dev and proving**:

- Run the complete input log in a single call, then with reproducible random serialized cuts.
  Compare **every output felt**, including full state, RNG, canonical grid order, render and
  terminal status. Compare the two compiler profiles directly, not just their hashes.
- Validate every returned state and snapshot envelope and every contained felt against
  `[0, 2^72)`. The public D14 state hashes and input commitment legitimately occupy the larger
  Starknet field and are checked separately. These are outputs exposed at batch/cut call
  boundaries, not necessarily a snapshot for every intermediate tic. Result `checked_outputs`
  counts decoded states/snapshots and empty outputs checked by exact equality. No bound on
  every intermediate VM state or memory cell is claimed.
- Check all ten D14 fields for the whole run and every cut against an independent Python
  Poseidon implementation: state hashes, version, times, terminal status, D13 packed-input
  commitment and cumulative stats. Check every adjacent `h_out → h_in` and tic boundary.
- Re-execute an empty Worker call on the final serialized state and require exact output
  equality, including DEAD/EXIT. A terminal command's tic counts; the unconsumed suffix does not.
- Compare compact pinned state/render/output SHA-256 values and the D14 values in
  `goldens.json`. The historical pins in `src/tests/e1m1.cairo` are never rewritten;
  a separate provenance test checks the five shared final state hashes.

The fuzz campaign advances **exactly 10,000 logical tics** from real genesis states. It uses
up to 64 commands per case, real movement prefixes into different rooms, random held-control
bursts and arbitrary canonical u32 words. A new episode starts on a terminal state or after
1,024 advanced tics. Every case compares its whole output against a random two-piece split
and checks the whole D14 independently; adjacent fuzz batches must chain. Every eighth case
also checks each split's D14 and the empty boundary. Zero-tic/ABORT results fail instead of
being counted. The summary separates logical advancement, supplied-but-unconsumed commands,
serialized boundaries, D14 checks and repeated tics executed for verification.

Seeds, runtime versions, engine commit and executable/bytecode SHA-256 identities are written
with results. Exact bytecode words are observational metadata; no timing quantiles or AIR,
browser-memory, proof-generation or cryptographic security claim follows from these runs.

## Run from a clean checkout

```sh
python3.11 -m venv /path/to/venv-game-regression
. /path/to/venv-game-regression/bin/activate
python3 -m pip install -r cairo/doom/doom_game/regression/requirements.txt
# poseidon-py 0.1.5, also used by the existing submission CI; no new unpinned dependency.
export ASDF_SCARB_VERSION=2.16.0 RAYON_NUM_THREADS=2 CARGO_BUILD_JOBS=2
scarb --manifest-path cairo/Scarb.toml --profile dev build -p doom_run
scarb --manifest-path cairo/Scarb.toml --profile proving build -p doom_run
python3 -m unittest discover -s cairo/doom/doom_game/regression -p 'test_*.py'
python3 cairo/doom/doom_game/regression/run.py corpus --out /path/to/results/corpus
python3 cairo/doom/doom_game/regression/run.py fuzz --out /path/to/results/fuzz \
  --profile proving --tics 10000 --seed 20260913
```

The output directory is required; it must be outside tracked source. No machine-specific
scratch path, native cache, WAD download, Rust compiler, Docker or prover is needed.
`--target` selects an already-built target directory; calls always use `--no-build --output none`.
A call has a 120-second timeout that kills its whole process group; the campaign has a
3,600-second wall limit. The CI wrapper also bounds each build to 600 seconds. CPU settings
remain two threads/jobs, and execution is sequential within a campaign.

For a focused rerun use `corpus --case fight_sweep --profiles proving`; this does not claim
full corpus coverage. `--record /path/to/new-candidate.json` is only for initial characterization:
it requires all cases and both profiles and refuses to overwrite an existing file. Normal tests
and CI never record or update pins. Any intentional gameplay change requires separate review
and justification; do not rebaseline to make a failure disappear.
An unmet required terminal status also writes the complete `failure.json` and `repro.json`,
including initial state, commands, observed output/D14 and required status. Reproduction
rechecks that status; this diagnostic is retained even during initial characterization.

## Failure artifacts

`failure.json` preserves the original serialized checkpoint, commands, cut seed and executable
identity. Genesis failures preserve the public `[0]` invocation, and cross-profile failures
also preserve the complete expected output and D14 fields. Malformed or missing subprocess
output retains command, arguments, profile, executable identity and stdout/stderr in
`execution-failure.json` and the campaign artifact. `repro.json` contains the smallest command
sequence found by bounded delta debugging
(maximum 24 attempts / 120 seconds), retaining the same failure category. This is not a claim
of a globally minimal counterexample. Golden/profile mismatches, genesis, launch/parse failures and timeouts retain the entire
original case without reduction. Reproduction checks the original expected pin/profile
output and records both original and current executable identities. A refusal is exit 1.

```sh
python3 cairo/doom/doom_game/regression/run.py reproduce \
  --failure /path/to/results/repro.json --out /path/to/reproduction
```

The harness itself is tested for ABI truncation/extra values, oversized felts, ABORT, terminal
accounting, a deliberate split-only divergence, reduction/reproduction, cross-profile and
genesis failure artifacts, malformed Scarb output, and process-group termination. Those synthetic harness tests are not counted as gameplay coverage.

## CI and remaining gates

`.github/workflows/game-regression.yml` runs the exact dev/proving corpus on relevant pull
requests and main pushes. Nightly and manual runs additionally advance 10,000 fuzz tics;
`github.run_number` is the recorded seed. The workflow uses Python 3.11, pinned Scarb 2.16.0,
and the exact requirement above. All logs, summaries and counterexamples are uploaded even on
failure. The nightly trigger becomes active only after this workflow and the full-game
entrypoints reach the default branch; the initial work was based on integration commit
`91719f8`, not the old main scaffold.

`infra/ci/run-game-regression.sh OUTPUT_DIR [corpus|nightly]` builds both profiles and runs these
checks. It then invokes the existing **strict** `doom_run/bench/size.py` without `--report`:
D29's **100,000-word target** and **120,000-word hard ceiling** remain distinct. The initial
integration program is **110,848 proving words**: below the hard ceiling, above the target,
so that gate correctly returns nonzero even if all correctness checks pass. D2's 12k mean /
25k p99 target and browser fluidity are separate unresolved gates, not inferred from corpus
success. No benchmark threshold or historical golden is modified by this work.
