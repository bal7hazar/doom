# prover/wasm — Stwo Cairo prover for the browser (WASM64 / Memory64)

Spike **S2** deliverable (see `docs/spikes/S2.md` for the measurements and verdict). A
`cdylib` that compiles the Stwo Cairo prover of
[`starkware-libs/proving` @ `cd7bc5f4697fb188a27e09f9242f1dd76df8afdc`](https://github.com/starkware-libs/proving/commit/cd7bc5f4697fb188a27e09f9242f1dd76df8afdc)
(+ 3 small patches, see `patches/`) to `wasm64-unknown-unknown`, plus a Vite/Playwright harness
that runs `execute → prove → verify` of a Scarb executable in headless Chrome and reports time and
memory.

```
prover/wasm/
├── Cargo.toml, Cargo.lock       # git deps pinned by full hash, built from vendor/ ([patch] sections)
├── rust-toolchain.toml          # nightly-2026-01-15 (the monorepo's), rust-src for -Z build-std
├── .cargo/config.toml           # wasm64 rustflags (getrandom custom cfg, simd128, 16 GiB max memory)
├── build.sh                     # vendor (fetch + patch) + reproducible build -> dist/*.wasm + SHA256SUMS
├── Dockerfile                   # same build in a pinned Linux container (R11-A1)
├── patches/                     # patches vs upstream applied by build.sh (3 on proving, 1 on xxhash-rust)
├── resources/                   # leaf_simple_bootloader_compiled.json.gz (from the monorepo, see resources/README.md)
├── src/core.rs                  # execute / prove / verify / proof_to_felts (target-independent)
├── src/lib.rs                   # wasm exports + host imports (hand-written ABI, no wasm-bindgen)
├── src/bin/native.rs            # native reference binary running the same code path
└── harness/                     # Vite app + Web Worker + Playwright bench + test programs
    ├── src/abi.mjs              # JS side of the ABI (browser Worker and Node >= 24)
    ├── src/worker.js, src/main.js, index.html, vite.config.js (COOP/COEP)
    ├── bench.mjs                # `npm run bench`: headless Chrome, results/*.json + *.md
    ├── bench-node.mjs           # same module in Node 24+ (Memory64 shipped in V8 13.3)
    ├── bench-native.sh          # native reference loop (all cores and 1 thread)
    ├── params/{leaf,auto,s0}.json  # prover parameter sets (leaf = built-in defaults, s0 = spikes/s0 reference)
    └── programs/steps_k/        # Scarb 2.16.0 executable, args/k{14,16,18,19,20}.json ≈ 2^k steps
```

## Build recipe

Requirements: `rustup` (the nightly is auto-installed from `rust-toolchain.toml`; `rust-src` is
required because wasm64 is a tier-3 target without prebuilt `std`), `git`, `curl`, `patch`,
network access to crates.io and GitHub on the first build. Optional: `wasm-opt` (binaryen ≥ 119
for `--enable-memory64`), Docker.

```sh
cd prover/wasm
./build.sh                    # vendor + wasm64 build -> dist/hellproof_prover_wasm.wasm, SHA256SUMS, harness/public/…
./build.sh vendor             # only populate vendor/ (needed once before any plain `cargo` command here)
NATIVE=1 ./build.sh           # + target/release/hellproof-prover-native
WASM_OPT=1 ./build.sh         # + wasm-opt -O2 pass (off by default: not part of the measured artifact)
NO_SIMD=1 ./build.sh          # comparison build without +simd128
PROVING_SRC=~/git/proving ./build.sh   # take the monorepo from a local clone instead of GitHub
```

What `build.sh` runs, explicitly:

```sh
CARGO_TARGET_WASM64_UNKNOWN_UNKNOWN_RUSTFLAGS='--cfg getrandom_backend="custom" \
  -C target-feature=+bulk-memory,+nontrapping-fptoint,+sign-ext,+mutable-globals,+simd128 \
  -C link-arg=--max-memory=17179869184 -C link-arg=-zstack-size=16777216 \
  --remap-path-prefix=<repo>=/hellproof --remap-path-prefix=$CARGO_HOME=/cargo' \
cargo +nightly-2026-01-15 build --release --lib --target wasm64-unknown-unknown -Z build-std=std,panic_abort
```

This is the monorepo's own CI command (`.github/workflows/stwo-cairo-prover-ci.yml`, job
`stwo-cairo-prover-wasm64`: `RUSTFLAGS='--cfg getrandom_backend="custom"' cargo check --target
wasm64-unknown-unknown -Z build-std=std,panic_abort -p stwo-cairo-prover --release`) turned into
a `build` of a cdylib, plus SIMD128 and the memory/stack link arguments. `strip = true` (43 MB
artifact; a `wasm-opt` pass is a follow-up). With `-Z build-std`, cargo also resolves the sysroot
workspace and prints spurious "patch … was not used in the crate graph" warnings — harmless.

Dependency sources: `Cargo.toml` names the monorepo crates as git dependencies at the full commit
hash; the `[patch]` sections redirect them to `vendor/proving` (a clone at that commit with
`patches/proving-*.patch` applied by `git apply`) and `xxhash-rust` to `vendor/xxhash-rust` (the
crates.io tarball, verified against the `Cargo.lock` checksum, with its patch). `vendor/` is
gitignored and rebuilt by `build.sh vendor`.

Docker (Linux, R11-A1) — written, not executed on the S2 machine (no daemon running):

```sh
docker build -t hellproof-prover-wasm -f prover/wasm/Dockerfile prover/wasm
docker run --rm hellproof-prover-wasm cat /SHA256SUMS
```

### Versions (pinned)

| Component | Version |
|---|---|
| starkware-libs/proving | `cd7bc5f4697fb188a27e09f9242f1dd76df8afdc` (workspace version 2.4.0) + `patches/proving-000{1,2,3}` |
| Rust | `nightly-2026-01-15` (rust-toolchain.toml of the monorepo and of this crate) |
| Target | `wasm64-unknown-unknown` (tier 3), `-Z build-std=std,panic_abort`, `panic = "abort"`, opt-level 3, no LTO |
| cairo-vm | 3.2.0 (`default-features = false`, `extensive_hints`, `mod_builtin`) |
| cairo-lang-{executable,runner,execute-utils,utils} | 2.19.4 |
| xxhash-rust | 0.8.18 + `patches/xxhash-rust-0.8.18-wasm64-simd128.patch` |
| getrandom | 0.2.17 (`custom` feature), 0.3.4 / 0.4.3 (`getrandom_backend="custom"`) |
| rayon / rayon-core | 1.12.0 / 1.13.0 (single-thread fallback on wasm) |
| Scarb (test program) | 2.16.0 (`cairo_execute = "2.16.0"`); the 2.16 executable JSON parses with cairo-lang-executable 2.19.4 |
| Harness | Node 22.22.2 (Vite/Playwright) and Node 24.16.0 (running the module), Vite 7.3.6, Playwright 1.63.0 (bundled Chromium 153.0.8010.12) |
| Browser | Google Chrome 152.0.7977.84 (`--channel chrome`, default) or Playwright Chromium (`--channel chromium`) |

## What the module does

Three entry points (plus helpers), matching the recursion route's *leaf*:

| Export | Input | Output |
|---|---|---|
| `execute(exe_ptr, exe_len, args_ptr, args_len)` | Scarb `*.executable.json`, args JSON array of felts (`["0x1c"]`) | `info` = `{n_steps, builtins, output, output_preimage, prover_input_bytes}`, `data` = bincode `ProverInput` |
| `prove(in_ptr, in_len, params_ptr, params_len)` | the bytes above, `ProverParameters` JSON (empty = defaults) | `info` = `{proof_bytes, proof_felts, max_log_size, …}`, `data` = bincode `CairoProof<H>` (extended proof) |
| `verify(proof_ptr, proof_len, params_ptr, params_len)` | proof bytes, params | status 0 + `{"ok":true}` or status 1 + error |
| `proof_to_felts(...)` | proof bytes, params | JSON array of hex felts = `ProofFormat::CairoSerde` (what `scarb verify` / the Cairo verifier take) |
| `default_params()` | – | the built-in parameters JSON |
| `alloc(len)`, `dealloc(ptr,len)`, `free_result(ptr)`, `init()` | memory management / panic hook + tracing forwarder |

Every export returns a pointer to a 40-byte result header `{status, info_ptr, info_len,
data_ptr, data_len}` (u64 LE). Host imports (module `host`): `log(level, ptr, len)`,
`random(ptr, len)` (`crypto.getRandomValues`), `now() -> f64`. Tracing spans inside the prover
are forwarded as `span:<name>:<ms>` debug lines, which the harness turns into a per-stage
breakdown. The JS binding is `harness/src/abi.mjs` (≈130 lines, works in a Worker and in Node);
it compiles the module first and stubs every import outside `host` (five wasm-bindgen runtime
glue functions dragged in by `web-time` ← `microlp` ← `cairo-lang-eq-solver`, never called).

**Execution path** — the leaf of the recursion route, as `leaf_prover::prove_leaf` runs it: the
executable's `Bootloader` entry point is wrapped in a `Task::Cairo1Program` and run under the
**leaf simple bootloader** (`leaf_simple_bootloader_compiled.json` of the monorepo, the program
of the `canonical_small` circuit registry; embedded gzipped, 60 KB) with
`cairo_program_runner_lib::cairo_run_program` — layout `all_cairo_stwo`, proof mode, no trace
padding, no VM relocation — then `stwo_cairo_adapter::adapt`. The bootloader adds ≈ 4 900 steps
(k14: 16 274 program steps → 21 155 total) and hashes the task program with Blake2s; the task's
return values are in `output_preimage`.

Why not the standalone entry point: at cd7bc5f `adapt()` hardcodes
`PublicSegmentContext::bootloader_context()` (all 11 builtin segments public), so a standalone
executable — which only exposes its own builtins — yields a trace the AIR rejects (`Constraints
not satisfied`; the monorepo's own `run_and_prove --program_type executable` fails the same way).
The bootloader path is the supported one and the one the recursion needs anyway.

**Default prover parameters** (`src/core.rs::DEFAULT_PARAMS_JSON`, = `harness/params/leaf.json`)
— the leaf format with production security:

```json
{ "channel_hash": "blake2s_m31", "channel_salt": 0, "preprocessed_trace": "canonical_small",
  "fri_config": { "pow_bits": 26, "log_blowup_factor": 1, "log_last_layer_degree_bound": 0,
                  "n_queries": 70, "fold_step": 1 },
  "store_polynomials_coefficients": false, "include_all_preprocessed_columns": true,
  "opt_n_id_to_big_components": 16, "lifting_size_policy": "at_least_preprocessed" }
```

`leaf_prover::prove_leaf` proves with `Blake2sM31MerkleChannel` and asserts
`include_all_preprocessed_columns = true` and `lifting_size_policy = at_least_preprocessed`;
`circuit_registry_definitions/canonical_small` uses `canonical_small`, blowup 1, 70 queries,
`opt_n_id_to_big_components = 16` (its `pow_bits = 16` is test data; production is 26).
`at_least_preprocessed` lifts every committed tree to the preprocessed height (2^20 · blowup =
2^21 rows), so **every proof, however small, pays the 2^20-preprocessed cost**;
`harness/params/auto.json` (`"lifting_size_policy": "auto"`) measures the trace-proportional
behaviour instead.

## Harness

```sh
cd prover/wasm/harness
npm install && npx playwright install chromium
npm run dev                                   # http://localhost:5173  (COOP/COEP set by vite.config.js)
npm run bench -- --k 14,16,18,19,20 --runs 3  # headless Google Chrome, writes results/bench-<stamp>.{json,md}; k>=20 takes $SCRATCH/.proof-lock
npm run bench -- --channel chromium --k 14 --runs 1 --ci     # CI smoke test (R11-A3), exit 1 on failure
npm run bench -- --params params/auto.json --k 14,18 --runs 1
npm run bench:node -- --k 14                  # Node >= 24 (Memory64 shipped; Node 22 rejects the module)
npm run bench:native -- --k "14 16 18 19" --threads "0 1"    # native reference (NATIVE=1 ../build.sh first)
```

The page loads the wasm in a module Web Worker (fresh Worker per run, so the 16 GiB Memory64 is
released between runs), reports wall time per stage, `WebAssembly.Memory.buffer.byteLength`
after each stage (the linear memory never shrinks, so this is the peak wasm heap) and
`performance.measureUserAgentSpecificMemory()` (needs cross-origin isolation) for the whole
agent cluster.

Test program `programs/steps_k`: a felt-first loop, `steps = 11·n + 38`; `args/k<K>.json` gives
≈ 2^K program steps (see `programs/steps_k/args/README.md`); the leaf bootloader adds ≈ 4.9 k.
Rebuild with `ASDF_SCARB_VERSION=2.16.0 scarb build` in that directory.

## Threads

The artifact is **single-threaded**. `stwo` is built with its `parallel` feature (rayon), and
`rayon-core 1.13` transparently falls back to a one-thread pool on the calling thread when
`std::thread::spawn` is unsupported (global pool); the three witness generators that build their
own pool needed `patches/proving-0003`. Multi-threading would need `+atomics,+bulk-memory`
(shared memory imported from JS, `-Z build-std` with `-C target-feature=+atomics`), a
thread-spawning shim (`wasm-bindgen-rayon` needs wasm-bindgen) and COOP/COEP (already set).
wasm-bindgen gained wasm64 support (usize lowered through an f64 number ABI) in 2026 but has not
been validated on this toolchain; `clealabs`' hand-written ABI (this crate) is the fallback. See
`docs/spikes/S2.md` §Follow-ups.

## Known limitations

- Memory64 needs Chrome/Edge ≥ 133 (Firefox ≥ 143 behind a flag, Safari no); Node ≥ 24 to run
  the module outside a browser (Node 22's V8 rejects the 64-bit table limits). Chrome caps a
  Memory64 at 16 GiB (`--max-memory=17179869184` in the link args).
- `preprocessed_trace = canonical` (default SHARP params, ~17 GB) cannot fit; `canonical_small`
  caps a segment at 2^20 steps (CONTEXT.md §4.4), bootloader included.
- `Poseidon252` channel is not available on wasm (upstream `cfg`).
- Single-threaded (see above).
- The module is 43 MB (Cairo compiler crates are linked for the executable parser; no wasm-opt).
- The proof crosses the JS boundary as a copy (bincode); a 2^19 proof is a few MB, fine.
