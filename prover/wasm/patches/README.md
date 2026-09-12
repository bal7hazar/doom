# Patches (R11-A2: differences with upstream as patches, never a silent fork)

`build.sh vendor` materializes `vendor/` and applies every patch here; `Cargo.toml` `[patch]`
sections point the pinned git/crates.io dependencies at those vendored copies. Rule: at most 5
patches, each with a justification and an upstream issue/PR.

| Patch | Target | Lines | Why | Upstream |
|---|---|---|---|---|
| `proving-0001-privacy-bootloader-output-preimage-in-scopes.patch` | starkware-libs/proving @ cd7bc5f, `crates/cairo-program-runner-lib` | +10 | The leaf simple bootloader's `DUMP_PRIVACY_SIMPLE_BOOTLOADER_OUTPUT_PREIMAGE` hint writes the output preimage with `std::fs::write`; wasm64-unknown-unknown has no filesystem. The patch keeps the preimage in the execution scopes (`vars::OUTPUT_PREIMAGE`) and writes the file only when a path is given. Existing callers pass a real path and are unaffected. | PR to open against `starkware-libs/proving` |
| `proving-0002-getrandom-js-feature-wasm32-only.patch` | starkware-libs/proving @ cd7bc5f, `crates/prover/Cargo.toml` | 1 line | The prover crate enables `getrandom/js` (0.2) and `getrandom/wasm_js` (0.3) for every wasm target; in getrandom 0.2.17 `js` also covers wasm64 and wins over `custom`, so the wasm64 module imports wasm-bindgen glue (`__wbindgen_placeholder__::__wbg_getRandomValues_*`, `__wbg_crypto_*`, …) that a non-wasm-bindgen host cannot provide — instantiation fails in Node 24 and Chrome. The patch restricts the override to wasm32; on wasm64 this crate registers the `custom` backends. | PR to open against `starkware-libs/proving` |
| `proving-0003-witness-thread-pool-fallback-without-threads.patch` | starkware-libs/proving @ cd7bc5f, `crates/prover/src/witness/{components/partial_ec_mul_window_bits_9,components/partial_ec_mul_window_bits_18,components/cube_252,utils}.rs` | 3 × 3 lines + 12 | These three witness generators build a dedicated rayon pool with an 8 MiB thread stack and `unwrap()` it; without threads (`std::thread::spawn` → `Unsupported`) that panics (`ThreadPoolBuildError`). rayon's automatic single-thread fallback only covers the global pool. The patch runs the closure on the calling thread when the pool cannot be built (`install_or_inline`); native behaviour unchanged. | PR to open against `starkware-libs/proving` |
| `xxhash-rust-0.8.18-wasm64-simd128.patch` | crates.io `xxhash-rust` 0.8.18 (pulled by `cairo-lang-defs` ← `cairo-lang-executable`/`cairo-lang-runner`) | 7 × 1 line | `xxh3.rs` gates its wasm SIMD path on `all(target_family = "wasm", target_feature = "simd128")` and then imports `core::arch::wasm32`, which does not exist on wasm64 (`core::arch::wasm64` intrinsics are still unstable). With `+simd128` the crate fails to compile on wasm64; the patch gates the path on `target_arch = "wasm32"` so wasm64 uses the scalar code (xxhash is only used by the Cairo compiler's salsa db here). | PR to open against `DoumanAsh/xxhash-rust` |

Applied as: `git apply --index` (proving, on a clone at the pinned commit) and `patch -p1`
(crates.io tarball verified against the `Cargo.lock` checksum).

## Not patched (works as-is at cd7bc5f)

- `stwo-cairo-prover`, `cairo-air`, `stwo-cairo-adapter`, `stwo`, `cairo-program-runner-lib`,
  `cairo-vm 3.2.0`, `cairo-lang-* 2.19.4` compile and run on `wasm64-unknown-unknown` unmodified.
- `getrandom` backends (0.2 `custom` feature; 0.3/0.4 `--cfg getrandom_backend="custom"`) are
  defined in this crate (`src/lib.rs`); only the feature override needed patch 0002.
- Single-threaded rayon: `rayon-core 1.13` falls back to a one-thread pool on the calling thread
  when `std::thread::spawn` is unsupported, so `stwo`'s `parallel` feature (global pool) needs no
  change; only the three explicit pools needed patch 0003.
- `Poseidon252` channel is already `cfg`-gated out of wasm targets upstream.
- The remaining wasm-bindgen runtime imports of the module (`__wbindgen_placeholder__::
  __wbindgen_throw`, externref-table helpers, JSPI spawn) come from `web-time` ← `microlp` ←
  `good_lp` ← `cairo-lang-eq-solver` (Cairo compiler, never executed here); the harness stubs them
  (`harness/src/abi.mjs`) instead of patching.

## Not a patch, but an upstream finding

At cd7bc5f `stwo_cairo_adapter::adapter::adapt` hardcodes
`PublicSegmentContext::bootloader_context()`, so the *standalone* entry point of a Scarb
executable (`stwo-cairo-dev-utils run_and_prove --program_type executable`) produces a trace the
AIR rejects (`Constraints not satisfied`, or `TryFromIntError` in `extract_public_segments`).
Executables must run under the (leaf) simple bootloader — which is what this crate does.
