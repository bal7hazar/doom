# Memory64 SIMD load diagnostics (S12)

These are bounded kernel/runtime tests, not a proof benchmark. They do not change
Cairo, AIR, proof parameters, memory limits or the admission policy.

The audit reproduced a V8 Liftoff error: `v128.load{8,16,32,64}_splat` used a
32-bit address even with Memory64. At addresses above 4 GiB this could read another
location and omit an expected out-of-bounds trap. Observed runtimes:

| Runtime | Original splat loads | Lowered scalar load + splat |
|---|---|---|
| Node 24.16.0 / V8 13.6.233.17-node.49, default or `--liftoff-only` | Incorrect above 4 GiB | Correct |
| Node 24.16.0, `--no-liftoff` | Correct | Correct |
| Node 25.2.1 / V8 14.1.146.11-node.14, default | Incorrect above 4 GiB | Correct |
| Chromium 153.0.8010.12 (independent root test) | Correct | Whole-proof equivalence with corrected Node |

These observations do not claim that all browsers or every Node patch version are
affected. The original S9 executable happened to prove successfully with older
artifacts; that was not a test of every address and execution tier.

## Exact instruction/runtime test

From the repository root:

```sh
cargo +nightly-2026-01-15 build --release --locked --jobs 2 \
  --manifest-path prover/wasm/tools/memory64-splats/Cargo.toml
node prover/wasm/diagnostics/memory64-splats.mjs \
  prover/wasm/tools/memory64-splats/target/release/hellproof-memory64-splats
node --liftoff-only prover/wasm/diagnostics/memory64-splats.mjs \
  prover/wasm/tools/memory64-splats/target/release/hellproof-memory64-splats
node --no-liftoff prover/wasm/diagnostics/memory64-splats.mjs \
  prover/wasm/tools/memory64-splats/target/release/hellproof-memory64-splats
```

The script constructs and validates a small Memory64 module, then tests all four
widths, immediate offsets 0/7/2^32, low/high addresses, exact last valid reads and
first invalid reads, and 20,000 calls per valid case to exercise JIT tiering. It
requires **400,024** corrected checks per mode. Original failures are reported,
not required: a fixed engine must also pass. Only a few pages are touched in its
4,295,163,904-byte virtual memory. Run with an external timeout (45 seconds used in
the audit). The transformation is checked for byte-for-byte idempotence.

`memory64-splats-minimal.wat` is the human-readable nine-line core reproduction:
write 123 at 128 and 456 at 2^32+128; `scalar` and `vector` read 456 at the latter,
whereas affected `splat` reads 123. `wasm-as --enable-memory64 --enable-simd` can
assemble it, but the automated test above needs no WAT tooling.

## Real pinned SIMD/CPU kernels

`backend_probe.rs` calls Stwo `cd7bc5f` itself. It compares CM31/QM31 batch inverses
against scalar multiplication, FFT/iFFT/LDE/barycentric evaluation against exact
roundtrips, and the complete mixed-height FRI quotient pipeline against
`CpuBackend`. Heights cover the changed D33 shapes 14/15/17/18 and lifting 22.
Seeds are fixed (19 for roundtrip, 23 for quotients). The error report contains
phase, first index, expected/actual values and relevant buffer addresses.

Use **an existing single-threaded WASM64 dependency cache built by the pinned
`prover/wasm/build.sh`**. The helper links without changing/rebuilding that cache:

```sh
python3 prover/wasm/diagnostics/build_backend_probe.py \
  --wasm-deps /path/to/target/st/wasm64-unknown-unknown/release/deps \
  --host-deps /path/to/target/release/deps \
  --stwo libstwo-EXACT_HASH.rlib --std libstd-EXACT_HASH.rlib \
  --output /tmp/backend-probe.wasm
prover/wasm/tools/memory64-splats/target/release/hellproof-memory64-splats \
  /tmp/backend-probe.wasm /tmp/backend-probe-lowered.wasm
node prover/wasm/diagnostics/backend_probe.mjs /tmp/backend-probe.wasm 0
node prover/wasm/diagnostics/backend_probe.mjs /tmp/backend-probe.wasm 4
node prover/wasm/diagnostics/backend_probe.mjs /tmp/backend-probe-lowered.wasm 4
```

Rlib filenames are explicit because multiple variants may coexist. The Rust
compiler remains `nightly-2026-01-15`; the helper uses one compiler process and a
120-second build timeout. The runtime tests used a 45-second external timeout.
Repeat the corrected case with 8 and 11 GiB reservations. A reservation is kept
alive and touches only its first/last byte; it positions subsequent allocations
above the chosen boundary, without populating gigabytes of data. This diagnostic
instance is discarded after the test; it is not a production allocator.

Audit result: 32 kernel cases pass at low addresses. Original kernels fail the
first FFT roundtrip at high addresses; all 32 corrected cases pass at low, 4, 8,
and 11 GiB reservations. The final linked probe is 745,730 bytes; lowering its
42 splat loads adds exactly 42 bytes. This establishes a concrete address-dependent
kernel defect, not an inferred AIR size problem.

The complete real D33 proof was tested independently by the root task. Its original
Chromium proof and corrected Node four-thread proof are identical, SHA256
`89d7492ec4527b8c7454ccb542e0c57ae374c229437ab652676777622df34c1f`,
4,332,446 bytes. Native verification passes and mutated proofs are rejected.
Corrected Node mono also verifies. Full audit artifacts and provenance are in
`/tmp/hellproof-proof-triage` and `/tmp/hellproof-audit-20260913/hash-cost`.
