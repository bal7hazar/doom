# @hellproof/prover-wasm

The Stwo Cairo prover of the Hellproof recursion **leaf**, compiled to WASM64 (Memory64), driven
from a page: `execute → prove → verify` of a Cairo segment off the main thread, with an optional
rayon Worker pool.

```ts
import { createProver } from "@hellproof/prover-wasm";

const prover = createProver({ onEvent: (e) => console.log(e) }); // progress + memory
await prover.init({ threads: "auto" });              // needs crossOriginIsolated; else 1 thread
const { input, stats } = await prover.execute(executableJson, ["0x1c"]);
const budget = await prover.resources(input);        // can this segment still grow?
const { proof } = await prover.prove(input);         // ~12 s for 2^20 steps, 4 threads, M2 Max
await prover.verify(proof);                          // true
const felts = await prover.proofToFelts(proof);      // 755 500 felts for a 2^20 leaf proof
await prover.terminate();                            // frees the whole linear memory
```

* **Requirements**: Chrome/Edge ≥ 133 (Memory64), a `crossOriginIsolated` page (COOP
  `same-origin` + COEP `require-corp`) for threads, or Node ≥ 24 with `ProverCore`
  (`@hellproof/prover-wasm/core`). Without isolation the package loads the single-threaded
  artifact and warns.
* **Artifacts**: `wasm/hellproof_prover_wasm{,.threads}.wasm`, produced by `prover/wasm/build.sh`
  (45 MB each, 8.1 MB gzipped). Override their location with `init({wasmUrl, threadedWasmUrl})`.
* **Parameters**: the defaults are the recursion leaf's (`canonical_small`, pow 26, blowup 1,
  70 queries, `include_all_preprocessed_columns`, `at_least_preprocessed`, `blake2s_m31`); every
  call takes an override.
* **Segment sizing**: `resources()` returns the largest AIR component of a run — a segment is
  provable while `fits_leaf_registry` is true (≤ 2^20 rows), which is *not* the same as a step
  budget.

Everything — the build recipe, the patches, the measurements (threads, memory, proof sizes), the
felt-counting convention and the known limits — is documented in
[`prover/wasm/README.md`](../README.md).

Internal package: `private: true`, not published to a public registry.
