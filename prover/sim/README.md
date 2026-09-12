<!--
SPDX-FileCopyrightText: 2026 Hellproof contributors
SPDX-License-Identifier: Apache-2.0
-->

# `hellproof-sim` — real-time Cairo simulation

Runs a Scarb `#[executable]` (the game core's `step_tic`) **many times per
second** in a browser Worker, on top of the very cairo-vm the prover uses.
Execution only: no trace, no memory relocation, no proof mode.

This is spike **S3** / risk action **R5-A1** (see `docs/spikes/S3.md`,
`RISKS.md` §R5, `PLAN.md` decision A1).

## What is cached, what is rebuilt

`SimProgram::load` parses the `.executable.json` **once** and keeps:

| cached | why it can be |
|---|---|
| the deserialized `Executable` → `cairo_vm::types::program::Program` | cairo-vm keeps the bytecode and the hint collection behind an `Arc`, so cloning a `Program` per call is `O(1)` |
| the `string_to_hint` map | it only depends on the program |
| a `CairoHintProcessor` | reset between calls instead of rebuilt (~10 % of a 4 k-step tic) |
| the entrypoint, its builtins, the run configuration | idem |
| the argument/output scratch buffers | avoids two allocations per tic |

Rebuilt on **every** call, unavoidably with cairo-vm 3.2:

* the `CairoRunner` and the `VirtualMachine` it owns — memory segments,
  builtin runners, execution scopes. There is no reset API, and a finished
  run's memory cannot be reused.
* the user arguments (`Vec<Arg>`) holding the input felts.

Measured cost of the rebuild at 4 k steps: **0.003 ms** out of a 0.44 ms tic.
Re-parsing the JSON instead, the way `stwo-cairo`'s `execute` does, costs the
whole parse on every tic — 0.13 ms for the 4 kB benchmark program, 16 ms for a
780 kB one.

## Felt encoding on the JS boundary

No JSON on the hot path. Every felt is a **fixed 32-byte little-endian** value
inside a `Uint8Array`: felt `i` is at bytes `[32i, 32i+32)`, least significant
byte first, zero padded, and must be canonical (`< p`); a non-canonical felt is
rejected rather than silently reduced. A 1 500-felt state is exactly 48 000
bytes.

The argument buffer is the **Cairo serialization** of the entrypoint
parameters, i.e. what `scarb execute --arguments` takes. For
`fn step_tic(state: Array<felt252>, cmd: felt252)` that is
`[len, s0, …, s_{len-1}, cmd]`.

`run` returns the Cairo serialization of the return value, which is exactly the
content of the output builtin segment: `[len, e0, …]` for an
`Array<felt252>`. A Cairo panic is an error, never a value.

```js
import init, { SimProgram } from '../pkg/hellproof_sim.js';
const wasm = await init();
const sim = SimProgram.load(await (await fetch('step_tic.executable.json')).text());
const out = sim.run(argsBytes);            // Uint8Array in, Uint8Array out
```

Zero-copy variant (no `Uint8Array` allocated per tic):

```js
const ptr = sim.reserve_input(nFelts);
new Uint8Array(wasm.memory.buffer, ptr, nFelts * 32).set(argsBytes);
const n = sim.run_buffered(nFelts);
const out = new Uint8Array(wasm.memory.buffer, sim.output_ptr(), n * 32);
```

Any wasm allocation can grow the linear memory and detach existing views, so
rebuild the views after each call, as above.

`run_json(argsJson)` takes and returns JSON arrays of decimal/hex strings; it
is a debugging helper, never for the hot path.

## Building

```sh
# toolchain
rustup target add wasm32-unknown-unknown
cargo install wasm-pack                 # or use an existing one
export ASDF_NODEJS_VERSION=22.22.2
# Scarb 2.19.4 is pinned by bench/step_tic/.tool-versions; with a plain
# install instead of asdf, make sure `scarb --version` reports 2.19.4.

cd prover/sim/bench
npm install                             # playwright
npx playwright install chromium
npm run build                           # Cairo executable + wasm + native bench
```

`npm run build` runs, in order:

* `scarb build` in `bench/step_tic/` → `target/dev/step_tic.executable.json`
* `wasm-pack build --release --target web --out-dir pkg` → `prover/sim/pkg/`
* `cargo build --release` → `target/release/hellproof-sim-bench`

Nothing built is committed (see `.gitignore`).

### Version pinning

`cairo-vm 3.2.0` and `cairo-lang-* 2.19.4` are pinned to the versions
StarkWare's [`proving`](https://github.com/starkware-libs/proving) repository
pins (`Cargo.lock` @ `cd7bc5f`), so the simulation VM **is** the VM the prover
executes. Scarb must match the `cairo-lang-*` minor version, hence
**Scarb 2.19.4**: an executable produced by another Scarb may not deserialize.

## Benchmarks

```sh
cd prover/sim/bench
npm run bench              # native + node + headless chromium worker, prints tables
npm run bench:native       # native only
npm run bench:node         # node + wasm
npm run bench:browser      # headless chromium, inside a Worker
npm run serve              # http://127.0.0.1:8787/bench/index.html (COOP/COEP on)
```

Raw JSON lands in `bench/results/`. `BENCH_ITERS` and `BENCH_LEAK_ITERS`
override the 2 000 / 10 000 defaults.

The benchmarked Cairo program is `bench/step_tic/`. Its step count is
`35 · state.len() + 69` — the `Serde` envelope of the state array dominates —
so the state length selects the step budget: 112 felts ≈ 4 k steps, 284 ≈ 10 k,
1 500 (the full Doom-sized state) ≈ 52.6 k. See `bench/step_tic/src/lib.cairo`
for the calibration table and `docs/spikes/S3.md` for the consequences.

### Cross-environment equivalence

Every run reports an `output_fingerprint`: FNV-1a over the raw output bytes of
100 consecutive tics. Native, Node and Chromium must agree — they do. This is
the seed of the continuous equivalence test R5-A3.

## Native benchmark binary

```sh
target/release/hellproof-sim-bench \
  --executable bench/step_tic/target/dev/step_tic.executable.json \
  --state-len 112 --iters 2000 --json
```

`--inflate N` appends `N` dead bytecode words to the executable JSON before
loading it, to see how the one-off parse — and therefore the naive
re-parse-per-call alternative — scales with program size.
