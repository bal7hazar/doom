# Patches (R11-A2: differences with upstream as patches, never a silent fork)

`build.sh vendor` materializes `vendor/` and applies every patch here; `Cargo.toml` `[patch]`
sections point the pinned git/crates.io dependencies at those vendored copies, and the threaded
build points `-Z build-std` at the patched copy of the Rust standard library sources
(`__CARGO_TESTS_ONLY_SRC_ROOT`). Rule: at most 5 patches, each with a justification and an
upstream issue/PR.

Six patches are applied today: three on `starkware-libs/proving`, one on `xxhash-rust`, one on
`parking_lot_core` and one on the Rust standard library. The last two are only needed by the
**threaded** artifact (`+atomics`); the single-threaded one builds with four. Every one of the six
is a *cfg oversight*: a piece of `wasm32`-only plumbing that wasm64 needs too, or a `std::fs` /
`std::thread` call on a target that has neither — each is a handful of lines and none changes
native behaviour.

| Patch | Target | Lines | Why | Upstream |
|---|---|---|---|---|
| `proving-0001-privacy-bootloader-output-preimage-in-scopes.patch` | starkware-libs/proving @ cd7bc5f, `crates/cairo-program-runner-lib` | +10 | The leaf simple bootloader's `DUMP_PRIVACY_SIMPLE_BOOTLOADER_OUTPUT_PREIMAGE` hint writes the output preimage with `std::fs::write`; wasm64-unknown-unknown has no filesystem. The patch keeps the preimage in the execution scopes (`vars::OUTPUT_PREIMAGE`) and writes the file only when a path is given. Existing callers pass a real path and are unaffected. | PR to open against `starkware-libs/proving` |
| `proving-0002-getrandom-js-feature-wasm32-only.patch` | starkware-libs/proving @ cd7bc5f, `crates/prover/Cargo.toml` | 1 line | The prover crate enables `getrandom/js` (0.2) and `getrandom/wasm_js` (0.3) for every wasm target; in getrandom 0.2.17 `js` also covers wasm64 and wins over `custom`, so the wasm64 module imports wasm-bindgen glue (`__wbindgen_placeholder__::__wbg_getRandomValues_*`, `__wbg_crypto_*`, …) that a non-wasm-bindgen host cannot provide — instantiation fails in Node 24 and Chrome. The patch restricts the override to wasm32; on wasm64 this crate registers the `custom` backends. | PR to open against `starkware-libs/proving` |
| `proving-0003-witness-thread-pool-fallback-without-threads.patch` | starkware-libs/proving @ cd7bc5f, `crates/prover/src/witness/{components/partial_ec_mul_window_bits_9,components/partial_ec_mul_window_bits_18,components/cube_252,utils}.rs` | 3 × 3 lines + 12 | These three witness generators build a dedicated rayon pool with an 8 MiB thread stack and `unwrap()` it; on a target where `std::thread::spawn` returns `Unsupported` that panics (`ThreadPoolBuildError`). rayon's automatic single-thread fallback only covers the global pool. The patch runs the closure on the calling thread when the pool cannot be built (`install_or_inline`); native behaviour unchanged. The closure's own `par_iter`s still use the global pool, so the threaded wasm build keeps its parallelism there. | PR to open against `starkware-libs/proving` |
| `xxhash-rust-0.8.18-wasm64-simd128.patch` | crates.io `xxhash-rust` 0.8.18 (pulled by `cairo-lang-defs` ← `cairo-lang-executable`/`cairo-lang-runner`) | 7 × 1 line | `xxh3.rs` gates its wasm SIMD path on `all(target_family = "wasm", target_feature = "simd128")` and then imports `core::arch::wasm32`, which does not exist on wasm64 (`core::arch::wasm64` intrinsics are still unstable). With `+simd128` the crate fails to compile on wasm64; the patch gates the path on `target_arch = "wasm32"` so wasm64 uses the scalar code (xxhash is only used by the Cairo compiler's salsa db here). | PR to open against `DoumanAsh/xxhash-rust` |
| `parking_lot_core-0.9.12-wasm64-atomic-parker.patch` | crates.io `parking_lot_core` 0.9.12 (pulled by `parking_lot` ← `salsa` ← the Cairo compiler crates) | 12 | `src/thread_parker/mod.rs` already selects the atomic parker for `all(feature = "nightly", target_family = "wasm", target_feature = "atomics")`, but `wasm_atomic.rs` imports `core::arch::wasm32`, so on wasm64 the selection cannot compile and the crate falls back to `wasm.rs`, whose parker panics `Parking not supported on this platform` the first time two threads contend a lock. The patch imports `core::arch::wasm64` on wasm64 (same `memory_atomic_wait32`/`memory_atomic_notify`) and adds the matching `feature(simd_wasm64)` attribute. Our `Cargo.toml` enables the crate's `nightly` feature for wasm64. | PR to open against `Amanieu/parking_lot` |
| `rust-std-nightly-2026-01-15-wasm64-atomics-sync.patch` | `library/std` of the pinned nightly (rust-src), applied to `vendor/rust-std` and used through `__CARGO_TESTS_ONLY_SRC_ROOT` | 2 × 1 line | `sys/sync/once/mod.rs` and `sys/sync/thread_parking/mod.rs` select their futex implementation with `all(target_arch = "wasm32", target_feature = "atomics")`, while their `mutex`/`condvar`/`rwlock` siblings correctly use `target_family = "wasm"` and `sys/pal/wasm/atomics/futex.rs` already has a `core::arch::wasm64` arm. On wasm64 + atomics `Once` and `thread::park` therefore fall back to the `no_threads` implementations, and the first concurrent `Once::call_once` panics with *"one-time initialization may not be performed recursively"* — which every `OnceLock`/`LazyLock` hits, `crossbeam-epoch`'s default collector (i.e. rayon itself) first. | PR to open against `rust-lang/rust` |

Applied as: `git apply --index` (proving, on a clone at the pinned commit), `patch -p1`
(crates.io tarballs verified against the `Cargo.lock` checksum) and `patch -p1` on the copied
`library/` tree (std).

### Upstream PR drafts

Each patch is written to be submitted as-is; suggested titles and bodies:

1. **starkware-libs/proving — "cairo-program-runner-lib: keep the privacy bootloader output
   preimage in the execution scopes"**: the hint currently requires a writable filesystem, which
   rules out wasm and any sandbox; the preimage is already a `Vec<Felt252>` in scope, so storing it
   under `vars::OUTPUT_PREIMAGE` and writing the file only when `output_preimage_dump_path` is
   non-empty keeps every existing caller working and lets non-file hosts read the preimage back.
2. **starkware-libs/proving — "prover: enable getrandom's js backend on wasm32 only"**: on
   `wasm64-unknown-unknown` the `js` feature both fails to build the `wasm_js` backend and, when it
   does resolve, injects wasm-bindgen imports that a plain host cannot satisfy; restricting the
   dependency to `cfg(target_arch = "wasm32")` lets wasm64 users select `getrandom_backend="custom"`.
3. **starkware-libs/proving — "witness: fall back to the calling thread when a dedicated rayon pool
   cannot be built"**: `ThreadPoolBuilder::build()` fails on targets without `std::thread`;
   `install_or_inline` keeps the 8 MiB-stack pool where it exists and runs the closure inline
   otherwise, which makes `stwo-cairo-prover` usable on wasm without giving up the global pool.
4. **DoumanAsh/xxhash-rust — "xxh3: gate the wasm SIMD path on target_arch = wasm32"**: the path
   imports `core::arch::wasm32`, which does not exist on `wasm64-unknown-unknown`, so the crate
   fails to build there with `+simd128`; wasm64 falls back to the scalar implementation.
5. **Amanieu/parking_lot — "thread_parker: support wasm64 in the atomic parker"**: `wasm_atomic.rs`
   is already selected for `target_family = "wasm"` but only compiles on wasm32; importing
   `core::arch::wasm64` (identical intrinsics) under the matching `feature(simd_wasm64)` makes
   threaded wasm64 builds work instead of panicking at the first contended lock.
6. **rust-lang/rust — "std: use the futex Once and thread parker on wasm64 with atomics"**: three
   of the five wasm-capable sync modules test `target_family = "wasm"`, two still test
   `target_arch = "wasm32"`; the `no_threads` fallbacks they select on wasm64 are unsound with
   threads (`Once` panics as soon as two threads race on the same initializer).

## Not patched (works as-is at cd7bc5f)

- `stwo-cairo-prover`, `cairo-air`, `stwo-cairo-adapter`, `stwo`, `cairo-program-runner-lib`,
  `cairo-vm 3.2.0`, `cairo-lang-* 2.19.4` compile and run on `wasm64-unknown-unknown` unmodified,
  with and without `+atomics`.
- `getrandom` backends (0.2 `custom` feature; 0.3/0.4 `--cfg getrandom_backend="custom"`) are
  defined in this crate (`src/lib.rs`); only the feature override needed patch 0002.
- Single-threaded rayon: `rayon-core 1.13` falls back to a one-thread pool on the calling thread
  when `std::thread::spawn` is unsupported, so `stwo`'s `parallel` feature (global pool) needs no
  change; only the three explicit pools needed patch 0003. In the threaded build the pool is built
  by this crate with a `spawn_handler` (`init_thread_pool`), so rayon never calls
  `std::thread::spawn` either.
- `Poseidon252` channel is already `cfg`-gated out of wasm targets upstream.
- The remaining wasm-bindgen runtime imports of the module (`__wbindgen_placeholder__::
  __wbindgen_throw`, externref-table helpers, JSPI spawn) come from `web-time` ← `microlp` ←
  `good_lp` ← `cairo-lang-eq-solver` (Cairo compiler, never executed here); the package stubs them
  (`pkg/src/abi.ts`) instead of patching.
- The wasm allocator (`std`'s dlmalloc) is already thread-safe with `+atomics` — it takes a
  **spin** lock, which is why witness generation stops scaling past ~4 threads (README §Threads).

## Not a patch, but an upstream finding

At cd7bc5f `stwo_cairo_adapter::adapter::adapt` hardcodes
`PublicSegmentContext::bootloader_context()`, so the *standalone* entry point of a Scarb
executable (`stwo-cairo-dev-utils run_and_prove --program_type executable`) produces a trace the
AIR rejects (`Constraints not satisfied`, or `TryFromIntError` in `extract_public_segments`).
Executables must run under the (leaf) simple bootloader — which is what this crate does.

A second one, found while sizing segments (P3.1): when a component would need more than 2^20 rows
with `preprocessed_trace = canonical_small`, the prover panics deep in the constraint framework
with `Preprocessed column Seq(21) is missing from static allocation` instead of returning a
"trace too large for this preprocessed trace" error. `resources()` in this crate answers the
question before proving; upstream would do better to check it in `prove_cairo`.
