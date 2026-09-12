# prover/wasm — Stwo Cairo prover for the browser (WASM64 / Memory64)

The prover of the Hellproof recursion **leaf**, compiled from
[`starkware-libs/proving` @ `cd7bc5f4697fb188a27e09f9242f1dd76df8afdc`](https://github.com/starkware-libs/proving/commit/cd7bc5f4697fb188a27e09f9242f1dd76df8afdc)
(+ 6 small patches, see `patches/`) to `wasm64-unknown-unknown`, plus the npm package
**`@hellproof/prover-wasm`** that drives it from a page, and a Playwright/Chrome harness that
measures it.

Two artifacts are built from the same source:

| Artifact | Build | Memory | Used when |
|---|---|---|---|
| `hellproof_prover_wasm.wasm` | single-threaded | module-owned `WebAssembly.Memory` | fallback — the page is **not** `crossOriginIsolated` (no `SharedArrayBuffer`) |
| `hellproof_prover_wasm.threads.wasm` | `+atomics`, `--shared-memory --import-memory` | shared memory supplied by JS | `crossOriginIsolated` page, `init({threads: n})` |

Both produce the same *proof*: same size, same 755 500 cairo-serde felts, verified in the browser,
whatever the thread count. The bytes are not identical across thread counts — the proof-of-work
nonce search is parallel, so a different (equally valid) nonce wins and the Fiat-Shamir transcript
diverges from there; for a fixed thread count the module is deterministic (same sha256 over
repeated runs). Phase-3 deliverable **P3.1**; the measurements that got here are in
[`docs/spikes/S2.md`](../../docs/spikes/S2.md) (S2) and in §Measurements below (P3.1).

```
prover/wasm/
├── Cargo.toml, Cargo.lock       # git deps pinned by full hash, built from vendor/ ([patch] sections)
├── rust-toolchain.toml          # nightly-2026-01-15 (the monorepo's), rust-src for -Z build-std
├── .cargo/config.toml           # wasm64 rustflags (getrandom custom cfg, simd128, 16 GiB max memory)
├── build.sh                     # vendor (fetch + patch) + both variants -> dist/*.wasm + SHA256SUMS
├── SHA256SUMS, SHA256SUMS.linux # artifact hashes: macOS build, container build
├── Dockerfile                   # the same build in a pinned Linux container (R11-A1)
├── patches/                     # 6 patches vs upstream, applied by build.sh (see patches/README.md)
├── resources/                   # leaf_simple_bootloader_compiled.json.gz (from the monorepo)
├── src/core.rs                  # execute / prove / verify / proof_to_felts / resources (target-independent)
├── src/lib.rs                   # wasm exports, host imports, rayon thread pool (hand-written ABI)
├── src/bin/native.rs            # native reference binary running the same code path
├── pkg/                         # the npm package @hellproof/prover-wasm (TypeScript)
│   ├── src/index.ts             #   createProver(): main-thread client, everything in a Worker
│   ├── src/core.ts              #   ProverCore: owns the wasm instance (Worker or Node)
│   ├── src/abi.ts               #   the wasm64 ABI binding
│   ├── src/thread-pool.ts       #   host side of the rayon pool; src/thread-worker.ts = one thread
│   ├── src/prover-worker.ts     #   the Worker that runs execute/prove/verify off the main thread
│   ├── test/smoke.mjs           #   end-to-end run in Node 24; test/sizing.mjs = segment sizing scan
│   └── wasm/                    #   the two artifacts (gitignored, written by build.sh)
└── harness/                     # Vite page + Playwright bench + the steps_k test program
    ├── bench.mjs                #   `npm run bench`: headless Chrome, results/*.json + *.md
    ├── src/main.js, index.html, vite.config.js (COOP/COEP)
    ├── params/{leaf,auto,s0}.json
    └── programs/steps_k/        #   Scarb 2.16.0 executable, args/k{14…20}.json, args/m{2,3,4}.json
```

## Quick start (the package)

```ts
import { createProver } from "@hellproof/prover-wasm";

const prover = createProver({ onEvent: (e) => console.log(e) });   // progress + memory events
await prover.init({ threads: "auto" });                            // 1 without cross-origin isolation
const { input, stats } = await prover.execute(executableJson, ["0x1c"]);
const budget = await prover.resources(input);                      // can this segment still grow?
const { proof, stats: p } = await prover.prove(input);             // seconds, in a Worker
await prover.verify(proof);                                        // true
const felts = await prover.proofToFelts(proof);                    // 755 500 felts for a 2^20 leaf
await prover.terminate();                                          // frees the whole linear memory
```

| Method | Runs | Returns |
|---|---|---|
| `init({threads, wasmUrl, threadedWasmUrl, initialPages, maximumPages, threadStackBytes})` | loads an artifact, starts the pool | `{threads, threaded, crossOriginIsolated, wasmUrl, instantiateMs, memoryBytes}` |
| `execute(executableJson, argsFelts)` | the Scarb executable under the leaf bootloader, then the adapter | `{input: ProverInput, stats: {n_steps, builtins, output, output_preimage, prover_input_bytes}, ms}` |
| `resources(input, params?)` | adapter counters only — no trace, ~1 ms | `ResourceSummary` (§Segment sizing) |
| `prove(input, params?)` | `prove_cairo` | `{proof: Proof, stats: {proof_bytes, proof_felts, trace_log_size, max_trace_component_log_size, component_log_sizes, …}, ms}` |
| `verify(proof, params?)` | `verify_cairo_ex` in the browser | `true`, or rejects with the verifier's reason |
| `proofToFelts(proof, params?)` | cairo-serde | `string[]` of hex felts — what the recursion leaf / `scarb verify` take |
| `defaultParams()` | – | the built-in leaf parameters |
| `terminate()` | stops the Worker and its thread pool | – |

`ProverInput` and `Proof` are opaque `Uint8Array`s (bincode); they are *transferred*, not copied,
between the Worker and the page. Everything is typed (`pkg/src/types.ts`), `tsc` clean, no runtime
dependency. `createProver()` never blocks the page: the Worker does the work, and with threads it
blocks on `Atomics.wait`, which is forbidden on a browser main thread — hence the wrapper.

`ProverCore` (`@hellproof/prover-wasm/core`) is the same API without the Worker wrapper, for use
inside a Worker of your own or in Node ≥ 24 (`pkg/test/smoke.mjs`).

Progress and memory are reported through `onEvent`:

* `{type: "stage", stage: "prove", phase: "start"|"end", ms, memoryBytes}` per call,
* `{type: "span", stage, name, ms, memoryBytes}` for every tracing span inside the prover
  (`Write Base trace`, `Simd Blake2s Grind`, `Prove STARKs`, … — the breakdown in §Measurements),
* `{type: "log", level, message}` for the prover's own logs and panics.

`memoryBytes` is `WebAssembly.Memory.buffer.byteLength`, which never shrinks: it *is* the peak wasm
heap. Release it by terminating the prover (R1-A7: one prover per segment, dropped after the proof
is persisted).

The package is `private: true` (internal); `npm pack` produces a tarball with `dist/` + `wasm/`.
Build it with `npm install && npm run build` in `pkg/` after `./build.sh` has produced the
artifacts.

## Build recipe

Requirements: `rustup` (the nightly is auto-installed from `rust-toolchain.toml`; `rust-src` is
required — wasm64 is a tier-3 target without prebuilt `std`, and the threaded variant rebuilds
`std` from a patched copy of those sources), `git`, `curl`, `patch`, network access to crates.io
and GitHub on the first build. Optional: `wasm-opt` (binaryen ≥ 119), Docker, Node ≥ 24.

```sh
cd prover/wasm
./build.sh                    # vendor + both variants -> dist/*.wasm, SHA256SUMS, harness/public/, pkg/wasm/
./build.sh vendor             # only populate vendor/ (needed once before any plain `cargo` command here)
VARIANTS=st ./build.sh        # only the single-threaded artifact (VARIANTS="st mt" by default)
NATIVE=1 ./build.sh           # + target/release/hellproof-prover-native
WASM_OPT=1 ./build.sh         # + a wasm-opt -O3 pass (off by default, see §Artifact size)
NO_SIMD=1 ./build.sh          # comparison build without +simd128
PROVING_SRC=~/git/proving ./build.sh   # take the monorepo from a local clone instead of GitHub
```

What `build.sh` runs per variant, explicitly (`mt` shown; `st` drops the atomics/shared-memory
flags and the `__CARGO_TESTS_ONLY_SRC_ROOT` override):

```sh
CARGO_TARGET_DIR=target/mt \
CARGO_TARGET_WASM64_UNKNOWN_UNKNOWN_RUSTFLAGS='--cfg getrandom_backend="custom" \
  -C target-feature=+bulk-memory,+nontrapping-fptoint,+sign-ext,+mutable-globals,+simd128,+atomics \
  -C link-arg=--max-memory=17179869184 -C link-arg=-zstack-size=16777216 \
  -C link-arg=--shared-memory -C link-arg=--import-memory \
  -C link-arg=--export=__stack_pointer -C link-arg=--export=__wasm_init_tls \
  -C link-arg=--export=__tls_size -C link-arg=--export=__tls_align -C link-arg=--export=__tls_base \
  --remap-path-prefix=<repo>=/hellproof --remap-path-prefix=$CARGO_HOME=/cargo' \
__CARGO_TESTS_ONLY_SRC_ROOT=vendor/rust-std/library \
cargo +nightly-2026-01-15 build --release --lib --target wasm64-unknown-unknown -Z build-std=std,panic_abort
```

The `st` command is the monorepo's own wasm64 CI command (`.github/workflows/
stwo-cairo-prover-ci.yml`, job `stwo-cairo-prover-wasm64`) turned into a `build` of a cdylib, plus
SIMD128 and the memory/stack link arguments. `strip = true`, `panic = "abort"`, `lto = false`.
With `-Z build-std`, cargo also resolves the sysroot workspace and prints spurious
"patch … was not used in the crate graph" warnings — harmless.

Dependency sources: `Cargo.toml` names the monorepo crates as git dependencies at the full commit
hash; the `[patch]` sections redirect them to `vendor/proving` (a clone at that commit with
`patches/proving-*.patch` applied by `git apply`), `xxhash-rust` and `parking_lot_core` to their
crates.io tarballs (checksums from `Cargo.lock`, or from the monorepo's `Cargo.lock` once ours
records the patched path source) with their patches. `vendor/rust-std` is a copy of the nightly's
`library/` tree with `patches/rust-std-*.patch`; `-Z build-std` is pointed at it for the threaded
variant only. `vendor/` is gitignored and rebuilt by `build.sh vendor`.

**Reproducibility (R11-A1).** Two hash files are committed, because the build is bit-reproducible
*per host*, not across hosts:

| File | Built by | Sizes (st / mt) |
|---|---|---|
| `SHA256SUMS` | `./build.sh` on macOS arm64 | 45 035 551 / 45 111 575 B |
| `SHA256SUMS.linux` | `docker build -o out -f Dockerfile .` (Debian bookworm arm64) | 45 032 682 / 45 114 562 B |

```sh
docker build -o out -f prover/wasm/Dockerfile prover/wasm   # both artifacts + SHA256SUMS in ./out
```

Evidence: the macOS build has been reproduced bit-for-bit three times (S2's artifact
`32c031ea…ce02c` from a fresh GitHub clone of the monorepo in a separate target directory, then
again here), and the container build twice — **the same host always lands on the same bytes**.
macOS and Linux do *not*: the two artifacts differ by ~3 KB, and a string diff of their data
sections shows the same literals merged in a different order, i.e. codegen/layout ordering of the
two host builds of rustc, not a leftover absolute path (`--remap-path-prefix` covers the crate,
`CARGO_HOME`, the target dir and the rustup sysroot; adding the sysroot mapping changed the
single-threaded hash, which proves the mechanism works, and left the threaded one untouched
because its `std` comes from `vendor/rust-std`). Cross-host bit-identity would need the
reproducible-builds work upstream in rustc; it is not required by R11-A1's "two independent builds
→ same hash", which is satisfied per platform.

`.github/workflows/prover-wasm.yml` rebuilds in the container on every change and diffs against
`SHA256SUMS.linux`, printing the macOS hashes next to it.

### Versions (pinned)

| Component | Version |
|---|---|
| starkware-libs/proving | `cd7bc5f4697fb188a27e09f9242f1dd76df8afdc` (workspace version 2.4.0) + `patches/proving-000{1,2,3}` |
| Rust | `nightly-2026-01-15` (+ `patches/rust-std-…` for the threaded variant) |
| Target | `wasm64-unknown-unknown` (tier 3), `-Z build-std=std,panic_abort`, `panic = "abort"`, opt-level 3, no LTO |
| cairo-vm | 3.2.0 (`default-features = false`, `extensive_hints`, `mod_builtin`) |
| cairo-lang-{executable,runner,execute-utils,utils} | 2.19.4 |
| xxhash-rust / parking_lot_core | 0.8.18 / 0.9.12 (+ patches, `nightly` feature on wasm64) |
| getrandom | 0.2.17 (`custom` feature), 0.3.4 / 0.4.3 (`getrandom_backend="custom"`) |
| rayon / rayon-core | 1.12.0 / 1.13.0 |
| binaryen (optional `WASM_OPT=1`) | 132 |
| Scarb (test program) | 2.16.0 (`cairo_execute = "2.16.0"`) |
| Package | TypeScript 5.9, no runtime dependency, ESM only |
| Harness | Node 24.16.0, Vite 7.3.6, Playwright 1.63.0 |
| Browser | Google Chrome 152.0.7977.84 (`--channel chrome`) or Playwright Chromium |

## Threads

The threaded artifact runs rayon over a pool of Web Workers on one shared linear memory. There is
no wasm-bindgen: the mechanism is ~120 lines of TypeScript and ~40 lines of Rust.

1. `init({threads: n})` creates the shared memory (`WebAssembly.Memory({initial, maximum, shared:
   true, address: "i64"})`, 16 GiB max) and instantiates the module.
2. It then starts `n` thread Workers **up front**. For each, the prover thread allocates a
   16 MiB shadow stack plus a TLS block with the module's own allocator and hands the Worker
   `{module, memory, stackTop, tlsBase}`; the Worker instantiates the *same* module on the *same*
   memory, sets `__stack_pointer`, calls `__wasm_init_tls(tlsBase)` and reports `ready`.
   Doing this before any proving matters: from step 3 on, the prover thread is blocked inside wasm
   and cannot pump its message loop, so a Worker that failed to start would deadlock it.
3. `init_thread_pool(n)` (Rust) builds rayon's **global** pool with a `spawn_handler` that leaks
   each rayon thread body and passes the pointer to `host.spawn_thread`; the host hands it to the
   next idle Worker, which calls `worker_entry(ptr)` and never returns.
4. Rust statics live in the shared linear memory, so every thread sees the same allocator, the same
   `tracing` subscriber and the same rayon registry — exactly as natively. Only `__stack_pointer`
   and the TLS base are per-thread (wasm globals are per-instance).

Consequences and limits:

* **`crossOriginIsolated` is required** (COOP `same-origin` + COEP `require-corp`). Without it
  `SharedArrayBuffer` does not exist; `init({threads: n})` then logs a warning, loads the
  single-threaded artifact and reports `threads: 1`. The client must handle both.
* Proving blocks its thread on `Atomics.wait`, which browsers forbid on the main thread — always
  run it in a Worker (what `createProver()` does).
* Each thread costs 16 MiB of linear memory (`threadStackBytes`), never released.
* `"auto"` = `hardwareConcurrency - 2` **capped at 4** (`MAX_AUTO_THREADS`). R6-A1 asks for
  `hardwareConcurrency - 2`; the cap is measured (§Measurements): past 4 threads the wasm
  allocator's spin lock (std's dlmalloc takes one when `+atomics`) makes witness generation
  *slower*, and the gain on the STARK part no longer compensates. Pass an explicit `threads` to
  override on other hardware.
* A panic on any thread aborts the whole module (`panic = "abort"`); the package surfaces it as a
  rejected promise with the panic message.

## Parameters

The defaults (`src/core.rs::DEFAULT_PARAMS_JSON`, also `harness/params/leaf.json`) are the
recursion leaf's, and every call takes an optional override (`prove(input, params)`).

```json
{ "channel_hash": "blake2s_m31", "channel_salt": 0, "preprocessed_trace": "canonical_small",
  "fri_config": { "pow_bits": 26, "log_blowup_factor": 1, "log_last_layer_degree_bound": 0,
                  "n_queries": 70, "fold_step": 1 },
  "store_polynomials_coefficients": false, "include_all_preprocessed_columns": true,
  "opt_n_id_to_big_components": 16, "lifting_size_policy": "at_least_preprocessed" }
```

Compared with the recursion registry that will consume these proofs
(`spikes/s4/registry/doom/cairo_prover_params.json`):

| Field | Registry | Here | Why |
|---|---|---|---|
| `channel_hash` | `blake2s` | **`blake2s_m31`** | `leaf_prover::prove_leaf` **ignores this field** and always calls `prove_cairo::<Blake2sM31MerkleChannel>`; to produce what the leaf produces, the module must be told `blake2s_m31`. Keep this difference — it is the registry's field that is dead, not ours. |
| `preprocessed_trace` | `canonical_small` | same | the only variant that fits in a 16 GiB Memory64 (`canonical` needs ~17 GB). |
| `pow_bits` / `log_blowup_factor` / `n_queries` | 26 / 1 / 70 | same | 96-bit security. |
| `fold_step` | 1 | same | the `doom` registry's value. The future `doom_fold4_min` registry will use 4 (S0: −12 % proof size); pass `{"fri_config": {…, "fold_step": 4}}` then — the module does not care. |
| `include_all_preprocessed_columns` | `true` | same | **mandatory**: `prove_leaf` asserts it (the verifier circuit expects a constant number of preprocessed columns). |
| `lifting_size_policy` | `at_least_preprocessed` | same | **mandatory**, asserted too; it lifts every tree to max(trace, preprocessed) = 2^21 rows, which is what pins `trace_log_size` to 20. |
| `opt_n_id_to_big_components` | 16 | same | forces 16 `memory_id_to_big` components whatever the memory size. |
| `store_polynomials_coefficients` | `false` | same | +0.36 GiB if enabled (S0). |

`harness/params/s0.json` (S0's `canonical_small.json`) and `harness/params/auto.json` are
comparison sets, not what the recursion takes.

## Segment sizing (`resources()`)

A segment is **not** capped at 2^20 steps (S4b): the leaf registry is keyed on `trace_log_size`,
which stays 20 as long as **every AIR component stays within 2^20 rows**. `resources(input)`
answers that from the adapter's counters, without generating a trace (~1 ms, no extra memory):

```jsonc
{ "n_steps": 2000000,
  "opcodes": [["add_ap_opcode", 1], ["add_opcode_small", 181371], …],  // one component each
  "builtins": [["range_check_builtin", 256], …],
  "memory_address_to_id": 2015806, "memory_id_to_big": 158, "memory_id_to_small": 1000032,
  "verify_instruction": 1149,
  "max_component": "memory_id_to_small", "max_component_rows": 1048576,
  "log_max_component_size": 20,         // ceil(log2) of the largest component
  "fits_leaf_registry": true,           // log_max_component_size <= 20 and id_to_big fits
  "n_memory_id_to_big_components": 1 }  // must stay <= opt_n_id_to_big_components (16)
```

The row counts follow the witness generators: `next_pow2(count)` per opcode and for
`verify_instruction`; `next_pow2(len / 16)` for `memory_address_to_id` (`MEMORY_ADDRESS_TO_ID_SPLIT`);
`next_pow2(len)` for `memory_id_to_small` — **not** split, which is what binds first for a
memory-writing program; chunks of 2^20 for `memory_id_to_big`.

Cross-check with the proof: `prove()` returns `trace_log_size` (what the leaf reads, 20 with these
parameters), `max_trace_component_log_size` and the whole `component_log_sizes` list. Note that
with `include_all_preprocessed_columns` the fixed range-check/bitwise components sit at 2^20 rows
in *every* proof, so only `resources()` tells you how much room the *program* still has.

Above the limit the prover does not fail gracefully: it panics inside the constraint framework with
`Preprocessed column Seq(21) is missing from static allocation` (upstream finding, see
`patches/README.md`). **Call `resources()` and stop the segment while `fits_leaf_registry` is
true.**

Measured on the `steps_k` program (a felt loop that writes one new memory value per iteration, so
`memory_id_to_small` ≈ steps/2), with `pkg/test/sizing.mjs`:

| total steps | largest component | rows | log | provable |
|---:|---|---:|---:|---|
| 16 271 | `memory_id_to_small` | 8 192 | 13 | yes |
| 1 048 456 | `memory_id_to_small` | 524 288 | 19 | yes |
| 2 000 000 | `memory_id_to_small` | 1 048 576 | 20 | yes (measured, §Measurements) |
| 2 314 919 | `memory_id_to_small` | 1 048 576 | 20 | yes (measured) |
| 2 369 919 | `memory_id_to_small` | 2 097 152 | 21 | **no** — prover panics |
| 2 999 999 / 3 999 998 | `memory_id_to_small` | 2 097 152 | 21 | **no** |

So for *this* program the browser ceiling is between 2.31 M and 2.37 M steps, and it is set by
distinct memory values, not by time or memory (2.31 M steps peak at 4.49 GiB and prove in 48 s
single-threaded, 16 s with 4 threads). A program
with a different memory profile (Doom: a few thousand live felts, rewritten every tic) will reach
a very different step count at the same 2^20-row limit — which is exactly why the client must ask
`resources()` rather than count steps.

## Measurements

Apple M2 Max (12 cores, 64 GB, macOS 25.6), Google Chrome 152.0.7977.84 headless, cross-origin
isolated page, fresh prover Worker per run, leaf parameters. Raw data:
`harness/results/bench-*.json` (not committed; regenerate with `npm run bench`).

### Thread scaling, 2^20 steps (1 048 456 steps, 2 runs each)

| threads | prove s (median) | speed-up | wasm memory GiB | verify ms | proof felts |
|---:|---:|---:|---:|---:|---:|
| 1 | 36.5 | 1.0× | 3.05 | 60 | 755 500 |
| 4 | **11.7** | **3.1×** | 3.15 | 72 | 755 500 |
| 8 | 12.4 | 2.9× | 3.29 | 66 | 755 500 |

S2's single-thread baseline was 35.6 s; native with 12 threads is 4.2 s. Where the time goes
(tracing spans inside the module, ms):

| span | 1 thread | 4 threads | 8 threads |
|---|---:|---:|---:|
| Write Base trace | 1 434 | 1 286 | **3 833** |
| Write interaction trace | 1 961 | 1 017 | 1 863 |
| Compute base trace commitment | 4 201 | 1 134 | 653 |
| Compute interaction trace commitment | 3 395 | 882 | 529 |
| Simd Blake2s Grind (pow 26) | 4 878 | 1 275 | 704 |
| Prove STARKs (quotients + FRI + decommit) | 22 650 | 6 260 | 4 609 |
| **total prove** | **36 457** | **11 658** | **12 416** |

The STARK part keeps scaling to 8 threads (22.7 s → 4.6 s, 4.9×), but witness generation
*regresses* (1.4 s → 3.8 s): `Write Base trace` is allocation-heavy and std's wasm allocator takes
a **spin** lock when built with `+atomics`, so the threads burn CPU fighting for it. Fixing that
(a per-thread arena, or a `wee_alloc`-style allocator) is the next threading win; until then 4
threads is the recommended default on an 8-performance-core machine.

### Segment sizes (2 runs each)

| total steps | threads | prove s (median) | wasm memory GiB | UA memory GiB | proof felts | verified |
|---:|---:|---:|---:|---:|---:|---|
| 1 048 456 | 1 | 36.5 | 3.05 | 3.09 | 755 500 | 2/2 |
| 1 048 456 | 4 | 11.7 | 3.15 | 3.18 | 755 500 | 2/2 |
| 1 048 456 | 8 | 12.4 | 3.29 | 3.33 | 755 500 | 2/2 |
| 2 000 000 | 1 | 47.7 | 4.48 | 4.54 | 758 500 | 2/2 |
| 2 000 000 | 4 | 15.6 | 4.55 | 4.62 | 758 500 | 2/2 |
| 2 000 000 | 8 | 16.8 | 4.62 | 4.68 | 758 500 | 2/2 |
| **2 314 919** (this program's ceiling) | 1 | 48.0 | 4.49 | 4.56 | 757 756 | 2/2 |
| 2 314 919 | 4 | 16.2 | 4.56 | 4.63 | 757 756 | 2/2 |
| 2 314 919 | 8 | 16.9 | 4.63 | 4.70 | 757 756 | 2/2 |

3 M and 4 M steps of this program are **not provable** with the leaf parameters (see §Segment
sizing) — the failure is an AIR-component limit, not memory: at its ceiling the module is at
4.6 GiB of a 16 GiB cap, and the time barely moves between 2.0 M and 2.3 M steps (the cost is
dominated by the fixed 2^21-row trees).

**Open issue — intermittent hangs with threads on large segments.** Two of ~16 threaded runs at
≥ 2 M steps in Chrome did not finish: one renderer crash (`Execution context was destroyed`) and
one hang with every thread idle. The same sizes then ran 2/2 clean twice in a row, and the same
module with the same thread counts never failed in Node 24 (`pkg/test/smoke.mjs --size mmax
--threads 4`), so the suspect is Chrome-side: growing a *shared* Memory64 while several threads
hammer the allocator's spin lock. Pre-growing the memory avoided it in the one run that was tried
(`--initial-pages 81920`, i.e. 5 GiB up front: 16.6 s, no hang — but the module then peaks at
9.5 GiB, because dlmalloc still grows from the end instead of reusing the pre-allocated pages).
Not diagnosed further; it is the main risk on the threads path and the reason R1-A3's "< 1 % proof
failures" cannot be claimed yet for threaded runs of that size. Single-threaded runs: 0 failures in
all of S2 and P3.1.

### Node 24 (same modules, `pkg/test/smoke.mjs`, 2^14 steps)

prove 40.8 s single-threaded, 12.7 s with 4 threads, verify 70 ms, 1.9 GiB. Node's V8 is slower
than Chrome's on this module; Node is a convenience runner, not a target. Node 22 cannot load the
module at all (`invalid table elements limits flags`: Memory64 with 64-bit table limits landed in
V8 13.3).

## Proof felts — the counting convention

S0 reported "≈ 290 k felts" for a segment proof and S2 counted 755 k for the same parameter file.
**Both counted the same thing** — the length of the cairo-serde felt array
(`CairoSerialize::serialize` of the extended `CairoProof`, i.e. `ProofFormat::CairoSerde`, what
`proofToFelts()` returns and what `scarb verify` / the leaf circuit take). There is no bincode /
JSON / u32-word convention hiding in the difference.

The difference is the **bootloader program**, measured with one binary, one parameter file at a
time, the same `steps_k(k14)` task (`stwo-run-and-prove --proof-format cairo-serde`, felts =
`len(json)`):

| bootloader | parameters | sampled columns | proof felts | file |
|---|---|---:|---:|---:|
| `privacy_simple_bootloader` (S0's route) | S0 `canonical_small` | 2 370 | **288 231** | 4.31 MB |
| `leaf_simple_bootloader` (the recursion's) | S0 `canonical_small` | 7 622 | **689 696** | 9.87 MB |
| `leaf_simple_bootloader` | **leaf/registry** | 8 537 | **755 280** | 10.64 MB |

The leaf bootloader hashes the task program with Blake2s *in Cairo 0*, which activates ~3× more AIR
components; `include_all_preprocessed_columns = true` and the 16 forced `memory_id_to_big`
components add the last 10 %. The felt count tracks the number of sampled columns, not the trace
size.

> **The number to plan with: a 2^20-step leaf proof with the `doom` registry parameters is
> 755 500 cairo-serde felts** (4.20 MB bincode, 8.4 MB as a hex-string JSON array). It is flat in
> the segment size: 755 280 at 2^14, 754 324 at 2^16, 756 844 at 2^19, 755 500 at 2^20, 758 500 at
> 2 M steps — ±0.3 %. Those felts never go on-chain; they go to the `leaf_prover`, whose *root*
> proof is 94–96 k felts (S4).

## Artifact size

| Artifact | raw | gzip -9 |
|---|---:|---:|
| `hellproof_prover_wasm.wasm` (single-threaded) | 45 035 551 B | 8.11 MB |
| `hellproof_prover_wasm.threads.wasm` | 45 111 575 B | 8.14 MB |
| single-threaded + `wasm-opt -O3 --strip-debug --strip-producers --strip-target-features` | 40.5 MB (−10 %) | 8.42 MB (**+4 %**) |

`wasm-opt -O3` is therefore **off by default** (`WASM_OPT=1` to enable): it costs 8 minutes of CPU,
shrinks the file by 10 % but makes the *transferred* bytes bigger, which is the size that matters
(the module is fetched once, compiled in < 100 ms by `compileStreaming` with lazy tier-up).

The module is 94 % code (42.4 MB of `code`, 2.3 MB of `data`). Its bulk is the **Cairo compiler**:
`cairo-lang-executable` depends unconditionally on `cairo-lang-compiler`, `-lowering`, `-semantic`,
`-sierra-to-casm` and `salsa` (164 of the 443 crates in the graph are `cairo-lang-*`), and
`cairo-program-runner-lib` depends on `cairo-lang-executable` *and* `cairo-lang-runner`, so the
dependency cannot be dropped from this side and **none of those crates exposes a feature to trim
it** (checked: `cairo-lang-executable` 2.19.4 has no `[features]` at all). Only the executable
*parser* is used at run time. The three ways out, none of them cheap:

1. parse the `*.executable.json` in JS and pass bytecode + hints across the ABI (drops
   `cairo-lang-executable`, but `cairo-program-runner-lib` still pulls it in);
2. patch `cairo-program-runner-lib` to gate its `Cairo1ExecutablePath` task type behind a feature
   (a 4th monorepo patch, upstreamable, and the honest fix);
3. `lto = "fat"`, which is the only lever that could remove the unreachable compiler code without
   touching the dependency graph — not attempted here (build time, and it changes the codegen of
   the measured artifact).

S3 hit the same wall for the simulator. Until one of those lands, 8.1 MB gzipped is the transfer
cost; it is a one-off download per version and can be cached in the Cache API by the client.

## Harness

```sh
cd prover/wasm/pkg && npm install && npm run build      # the package (needed by the harness)
cd ../harness && npm install && npx playwright install chromium
npm run dev                                             # http://localhost:5173 (COOP/COEP set)
npm run bench -- --sizes k20 --threads 1,4,8 --runs 2    # headless Chrome, results/bench-*.{json,md}
npm run bench -- --sizes m2,mmax --threads 1,4 --runs 2  # big segments (takes $SCRATCH/.proof-lock)
npm run bench -- --sizes mmax --threads 4 --initial-pages 81920   # pre-grown shared memory
npm run bench -- --channel chromium --sizes k14 --threads 1,4 --runs 1 --ci   # the CI smoke test
node test-fallback.mjs                                  # no COOP/COEP -> single-threaded fallback
npm run bench:native -- --k "14 16 18 19" --threads "0 1"    # native reference (NATIVE=1 ../build.sh)
cd ../pkg && node test/smoke.mjs --threads 4 --k 14      # same pipeline in Node 24
node test/sizing.mjs --n 181371,210000,215000            # segment sizing scan (no proving)
```

Sizes are the files in `harness/programs/steps_k/args`: `k14 … k20` (≈ 2^k total steps),
`m2/m3/m4` (2/3/4 M steps), `mmax` (2.31 M, the ceiling of this program). Runs above 2^19 steps
take the shared proof lock (`$SCRATCH/.proof-lock`, ROADMAP §4).

The test program (`programs/steps_k`, Scarb 2.16.0) is a felt-first loop, `steps = 11·n + 38`, plus
≈ 4 881 bootloader steps; its compiled `main.executable.json` is committed (4 KB) so CI can prove
without Scarb. Rebuild with `ASDF_SCARB_VERSION=2.16.0 scarb build` in that directory.

## CI (`.github/workflows/prover-wasm.yml`)

1. **`docker-build`** — rebuilds both artifacts in the pinned container and diffs their hashes
   against the committed `SHA256SUMS` (R11-A1), then uploads them.
2. **`browser-smoke`** — downloads those artifacts, builds the package, proves a 2^14-step program
   in headless Chromium through Playwright with 1 and with 4 threads and verifies it in the
   browser (R11-A3), plus the same two runs in Node 24.

Neither job has run yet: the workflow file is new and Docker is not available on the development
machine. `harness/bench.mjs --ci` exits 1 on any failure, and the hash comparison is a plain
`diff`, so both jobs fail loudly rather than silently.

## What the module does (ABI)

Hand-written ABI, no wasm-bindgen (`src/lib.rs`; the JS side is `pkg/src/abi.ts`):

| Export | Input | Output |
|---|---|---|
| `execute(exe_ptr, exe_len, args_ptr, args_len)` | Scarb `*.executable.json`, args JSON array of felts | `info` = `ExecutionStats`, `data` = bincode `ProverInput` |
| `resources(in_ptr, in_len, params_ptr, params_len)` | the bytes above, params JSON | `info` = `ResourceSummary` |
| `prove(in_ptr, in_len, params_ptr, params_len)` | idem | `info` = `ProofStats`, `data` = bincode `CairoProof<H>` |
| `verify(proof_ptr, proof_len, params_ptr, params_len)` | proof bytes, params | status 0 + `{"ok":true}` or status 1 + error |
| `proof_to_felts(…)` | proof bytes, params | JSON array of hex felts (cairo-serde) |
| `default_params()` | – | the built-in parameters JSON |
| `init_thread_pool(n)` / `worker_entry(ptr)` / `thread_count()` | threads (§Threads) | number of threads |
| `alloc(len)`, `dealloc(ptr,len)`, `free_result(ptr)`, `init()` | memory management / panic hook + tracing forwarder | |

Every entry point returns a pointer to a 40-byte result header `{status, info_ptr, info_len,
data_ptr, data_len}` (u64 LE); on wasm64 every pointer and length is an `i64` (BigInt in JS). Host
imports (module `host`): `log(level, ptr, len)`, `random(ptr, len)`, `now() -> f64`, and
`spawn_thread(ptr)` in the threaded build. Tracing spans are forwarded as `span:<name>:<ms>` debug
lines, which the package turns into progress events.

**Execution path** — the leaf of the recursion route, as `leaf_prover::prove_leaf` runs it: the
executable's `Bootloader` entry point is wrapped in a `Task::Cairo1Program` and run under the
**leaf simple bootloader** (`leaf_simple_bootloader_compiled.json` of the monorepo, embedded
gzipped, 60 KB) with `cairo_program_runner_lib::cairo_run_program` — layout `all_cairo_stwo`, proof
mode, no trace padding, no VM relocation — then `stwo_cairo_adapter::adapt`. The bootloader adds
≈ 4 881 steps and hashes the task program with Blake2s; the task's return values are in
`output_preimage`.

Why not the standalone entry point: at cd7bc5f `adapt()` hardcodes
`PublicSegmentContext::bootloader_context()`, so a standalone executable yields a trace the AIR
rejects (`Constraints not satisfied`; the monorepo's own `run_and_prove --program_type executable`
fails the same way). The bootloader path is the supported one and the one the recursion needs.

## Known limitations

- Memory64 needs Chrome/Edge ≥ 133 (Firefox ≥ 143 behind a flag, Safari no); Node ≥ 24 outside a
  browser. Chrome caps a Memory64 at 16 GiB (`--max-memory=17179869184` in the link args).
- Threads additionally need `crossOriginIsolated` (COOP/COEP) and a Worker (never the main thread).
- `preprocessed_trace = canonical` (default SHARP params, ~17 GB) cannot fit; `canonical_small`
  caps a component at 2^20 rows (§Segment sizing).
- `Poseidon252` channel is not available on wasm (upstream `cfg`).
- The module is 45 MB / 8.1 MB gzipped (§Artifact size).
- The proof crosses the JS boundary as a copy out of wasm memory (bincode, ~4.2 MB per segment).
- Measured on one machine (M2 Max). R1-A3 asks for a 16 GB Apple Silicon and a 16 GB x86 Windows
  machine as well; `npm run bench -- --channel chromium` is what to run there.
