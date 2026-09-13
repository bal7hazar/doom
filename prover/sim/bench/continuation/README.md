<!--
SPDX-FileCopyrightText: 2026 Hellproof contributors
SPDX-License-Identifier: Apache-2.0
-->

# Cairo simulation continuation — R5 prototype

This prototype keeps an unfinished Cairo execution alive between inputs. A
standalone Cairo harness deserializes a valid schema-2 GameState once, calls
**the actual `doom_game::step_tic` for each individual command**, emits the
actual Cairo snapshot, and retains the typed state for the next command.
No game rule is implemented in Rust. No proved entrypoint or client is changed.

The [feasibility note](FEASIBILITY.md) compares the two investigated routes.
Keeping the runner is supported by cairo-vm 3.2.0's public APIs; copying a
GameState pointer graph into another VM was rejected because its segments,
dictionary trackers and hint scopes cannot be migrated through a typed public API.

## Runner and trust boundary

`SimContinuation` owns `CairoRunner`, execution scopes, builtin memory and the
existing `CairoHintProcessor`. It compiles hint data once. Execution delegates
ordinary hints to that processor and instructions to the unmodified
`VirtualMachine::step_instruction`. The four simulation-only cheatcodes are:

| Exchange | Meaning |
|---|---|
| `hp_poll` | Pause before the instruction; supply exactly `[action, word]` on resume. |
| `hp_status` | Cairo emits the engine's status. |
| `hp_frame` | Cairo emits `doom_game::snapshot`. |
| `hp_state` | Cairo emits the complete `doom_game::serialize` checkpoint on request. |

Action 0 advances one tic, action 1 exports state without advancing, and action
2 ends the native session. `hp_poll` must be the instruction's only hint; other
shapes and unknown cheatcodes are rejected. The host cannot submit a second
command while a computation is interrupted. A step quantum can suspend between
instructions without replaying a hint. Waiting for input executes zero steps.
Like ordinary simulation, this path does not finalize or prove each suspended
run. Its checkpoints become authoritative only through the existing replay/proof
path. The standard hint processor is initialized without a separate step budget;
the continuation loop enforces its own prototype bounds.

This is an explicitly **trusted simulation transport**, not a proof program.
The host supplies words and chooses when to export or discard a VM. It does not
validate a proof or establish D14 by itself. A checkpoint is the complete
schema-2 record, including committed grid order, and is checked by the real
`from_felts` on every load/restart. Input-word validation and engine ABORT remain
inside the actual `step_tic`. VM/transport errors are Rust/JS errors, distinct
from game statuses. Programs must be the reviewed matching Cairo harness; this
API is not an untrusted executable service. A future client would still retain
the accepted command log and use the unchanged proved segment interface.

WASM exposes `SimContinuation.load(programJson, stateBytes)`,
`advance(word, quantum)`, `resume(quantum)`, `snapshot()`, `status()`,
`request_checkpoint(quantum)`, `checkpoint()` and `restart(stateBytes)`.
State/snapshot bytes retain the existing canonical 32-byte little-endian felt
encoding. Progress values are 0 (waiting), 1 (interrupted), 2 (ended). Read and
copy a completed snapshot/status before requesting a checkpoint: queuing any
action clears the previous response. A zero quantum preserves progress.

## Memory and interruption limits

Cairo memory is immutable and grows with the retained execution. There is no
segment GC. This prototype caps a session at 256 commands and 32 million VM
steps; these are local resource bounds, **not changes to game/proof budgets**.
Restart before reaching a bound. A VM error or failed runner initialization poisons the session: discard its
partial state and restart from a previously exported valid checkpoint, retaining
any commands to replay individually. Snapshot/status are complete only after
progress returns to 0. A plain interruption resumes the same VM directly.

The measured browser policy checkpoints and restarts every 32 tics. Inputs are
never batched or predicted. Checkpoint/restart pauses are included in the frame
that incurs them. The final export for audit is outside the per-tic timing;
periodic and terminal maintenance inside the run is included. The first load
includes JSON decoding; later restarts reuse the parsed program and hint cache.

The browser's WASM linear memory reached 950,140,928 bytes (906.1 MiB), compared
with 70,254,592 bytes (67 MiB) for the stateless baseline. This is allocated
linear-memory capacity, **not RSS or live heap**; it cannot shrink. Capacity
plateaued during the final scenes of this finite campaign, which is not a
long-duration leak test. Selecting a shorter checkpoint interval may trade
memory for more pauses; it has not been measured here.

## Reproduction

Prerequisites: the repository's Rust dependencies/lock, Scarb 2.16.0,
`wasm-pack`, the wasm32 target, Node 22 and Playwright Chromium. The generic S3
calibration uses Scarb 2.19.4, but this real-game executable's Scarb 2.16.0
format was verified against the pinned cairo-lang-runner 2.19.4 and VM 3.2.0.
No dependency or compiler pin changes are needed.

Start from the intended game revision and build the ordinary proving
`doom_run` targets using the repository's usual build command. Then:

```sh
export ASDF_SCARB_VERSION=2.16.0
export ASDF_NODEJS_VERSION=22.22.2
python3 prover/sim/bench/continuation/prepare.py /tmp/sim-continuation-reference
# If Playwright is installed outside the usual node_modules resolution:
export PLAYWRIGHT_MODULE=/absolute/path/to/playwright/index.mjs
python3 prover/sim/bench/continuation/run.py \
  /tmp/sim-continuation-reference/fixtures.json \
  /tmp/sim-continuation-reference/step_tic.executable.json \
  /tmp/sim-continuation-results
```

`prepare.py` imports the existing five golden replay scripts, generates initial
states with Scarb and saves final complete-output SHA-256 references. It does
not change golden pins. Each Scarb invocation has a 180-second timeout.
`run.py` builds the standalone harness, native runner and simulation WASM,
with two Rust jobs and 600-second build deadlines. It runs native equivalence
under 180 seconds and the Chromium Worker under a 240-second outer deadline
(180 seconds inside the browser). Timeout kills the entire child process group.
`--skip-build` uses existing artifacts. No proof, Docker or network service
other than an ephemeral local HTTP server is involved.

Four Rust lifecycle tests use a small, protocol-only Cairo counter executable
committed under `tests/fixtures` so `cargo test` does not require Scarb. They
exercise the actual 256-command limit, checkpoint/restart after that limit,
step-limit poisoning using a lower private test threshold, failed runner
initialization, invalid restart arguments and clean recovery. Regenerate that
fixture explicitly with Scarb 2.16.0 and compare it before committing changes:

```sh
cmp prover/sim/tests/fixtures/counter.executable.json \
  prover/sim/bench/continuation/cairo/target/proving/counter.executable.json
```

`native.json` contains the expected per-frame values and is deliberately large.
The native runner verifies every state/snapshot/status felt for 386 tics:
80 each idle/walk/door/fight and 66 death, stopping on the real terminal status.
It interrupts every seventh input after 101 instructions, resumes in 4096-step
chunks, checks busy-submit rejection, zero-step waits and invalid initial state,
and reloads exported state every 32 tics. The Worker checks every snapshot byte,
all checkpoint bytes and the five final complete legacy ABI hashes. These checks
also compare paths with a checkpoint every tic (native) versus only periodically
(browser), covering the journal retained between boundaries.

[Measured results](results.json) record both native and browser summaries plus
artifact hashes. The immutable audit artifacts for this run are in
`/tmp/hellproof-sim-continuation`, based on game revision `91719f8`.
The original stateless outputs came from `883efbb` and were independently
rechecked by the orchestrator against `91719f8` before this campaign.

## Measured result and remaining work

The report in `/tmp/hellproof-sim-continuation/report.md` gives the full table.
The final campaign measured 8.95–17.85 ms/tic, or 9.73–18.64 ms including
periodic maintenance, against 46.65–57.81 ms for the stateless Worker.
The mean supports 35 Hz on these scenes. It does **not** guarantee the deadline
for every frame: 13 of 386 inclusive frame calls exceeded 28.57 ms; the p99
including maintenance was 40.17–60.61 ms. Memory and maintenance scheduling
require a separate integration decision. There is no client rollout in this
change, and no budget, cadence, gameplay or proof-validation change.
