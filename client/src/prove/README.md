# Real Doom proof preparation

`createDoomProgram` implements the state-2 / D14-v1 `doom_run` ABI. It is an async
factory because it verifies the executable and runs real genesis in a dedicated
preparation Worker. The existing stub remains available for its tests/harness.
This module does not change `main.ts`, trigger network submission, or admit a
proof that exceeds the existing planner/registry limits.

## Stage exact artifacts

```sh
python3 client/scripts/prepare-game-proof.py \
  --target /path/to/existing/cairo/target \
  --sim /path/to/existing/prover/sim/pkg
```

This verifies all bytes before copying them into the ignored
`client/public/prover/game-proof/`. No compilation occurs. `doomArtifacts.ts`
pins D29 genesis/step/run_segment, R5 simulator WASM, its JavaScript glue and
its clock snippet, plus the Blake bootloader program hash measured for that
exact executable. The Worker independently verifies those six SHA-256 values.
It imports verified JavaScript bytes and its verified snippet via Blob URLs,
avoiding an unchecked second fetch. Serving requires same-origin assets and a
CSP permitting module Workers and `blob:` module imports.

These are distinct artifacts from the corrected Memory64 proof WASM, staged by
`client/scripts/prepare-prover.sh`. No proof parameters or hashes are inferred
from whatever executable happens to be available. A new engine/ABI requires an
explicit pin migration and new measurements.

## Live journal and late panel opening

```ts
const program = await createDoomProgram({
  journal: () => cairoClient.journal!.export(),
});
const session = await ProveSession.create({ host, program });
// The entire acknowledged journal before F4 is now persisted once.
// After each subsequent acknowledged game tic, either record its word exactly once
// through session.recordTic(word), or call session.pipeline.syncGameJournal().
// startProving()/finishAndProve() synchronize again before starting work.
```

CairoClient creates its journal at tic zero; the proof panel may stay lazy.
Repeated synchronization verifies the old prefix and copies only new words.
A restored simulation whose journal starts at a later checkpoint is refused for
proof. A normal full journal containing an imported maintenance checkpoint is
accepted only if its initial state equals the pinned real genesis; the supplied
checkpoint is never used to prepare proof arguments.

`prepareArgs` sends a frozen full journal and requested slice to its own Worker.
That Worker replays from real genesis (or its own already replayed prefix) in
bounded 32-tic chunks to the exact requested boundary. It then executes pinned
`run_segment` over the full boundary state and the exact slice. The resulting
D14—including D13 commitment over consumed commands—is the reference for the
proof Worker. All eleven output-preimage felts, including the pinned program
hash, must match before resource admission and again on retry. No JavaScript
implementation of Doom or state transition is used as an oracle.

The preparation cache holds one replayed state and one prepared argument list;
it is not a cache of arbitrary imported checkpoints. Rewind replays from genesis.
Calls have a 120-second external timeout that terminates the Worker; aborts and
terminal boundaries are explicit errors, never manufactured neutral inputs.
Use `program.dispose()` when its run is closed; the caller still owns this lifecycle.

## Persistence and reload

A concrete program's complete executable/ABI/simulation identity is stored in
`RunRecord.programIdentity`. An absent or different identity refuses resume;
legacy stub metadata is preserved as before. Every persisted segment's exact
arguments and D14 are re-derived from genesis plus the journal before requeue.
Proof execution/retry repeats preparation, D14 comparison and fresh AIR admission.

A `.hellproof` file already contains the full input log and `RunRecord`:

```ts
const program = await createDoomProgram({ resume: { run, words: unpackedInputs } });
const pipeline = new ProofPipeline({ store, program, proverWorkerUrl });
await pipeline.attach(run.id);
```

This reconstruction uses the loaded genesis and verifies the complete persisted
identity; it never promotes saved argument state to a trusted root. Importing or
re-executing a transcript is not cryptographic verification of its stored proofs.
The separate proof verification operation remains necessary.

If fresh `resources()` rejects all sizes, the last attempted full arguments,
output preimage, resource counters and reason are persisted in
`RunRecord.admissionFailure`; the complete journal stays in its input store.
Normal `.hellproof` export/import preserves both. Retrying executes/prepares again;
saved counters are not admission authority. D29 currently fails the production
log-20 AIR limit even for one tic (and for the measured empty segment).

## Validation and remaining integration

Tests cover exact non-maintenance boundaries, changed prefixes/slices/hashes,
forged initial states, ignored imported checkpoints, full D14/D13/program-hash
comparison, late journal synchronization, incompatible resume, substituted
persisted args, and preserved admission refusal. Real Worker runs were compared
felt by felt with independently executed Scarb + Python Poseidon references for
0/1/4 tics, boundaries 3 and 33, and the final 676→677 EXIT transition. Real
corrected proof WASM execute/resources returned the same eleven output felts.
A real browser pipeline refused admission, exported/imported its complete refusal
and resumed without invoking proof generation.

`main.ts` still needs to supply the live journal, manage the async factory and
Worker disposal, and connect acknowledgements to proof-session recording. The
journal provider must remain the same run until the program is disposed. The
adapter performs no automatic submission. No complete-game proof, proof/render
concurrency test on 16 GiB hardware, residual C3 latency, or P3.7 completion is
claimed by this adapter or its execution/resource measurements.
