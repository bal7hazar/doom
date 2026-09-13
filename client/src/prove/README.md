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
pins D29 + idle-loop revision `0c8a3a8` genesis/step/run_segment, R5 simulator WASM, its JavaScript glue and
its clock snippet, plus the Blake task hash of `run_segment` measured for that
exact executable (preimage element zero, distinct from the bootloader hash). The Worker independently verifies those six SHA-256 values.
It imports verified JavaScript bytes and its verified snippet via Blob URLs,
avoiding an unchecked second fetch. Serving requires same-origin assets and a
CSP permitting module Workers and `blob:` module imports.

The adapter initially measured revision `8ae7f1c`; migrating to `0c8a3a8` changes
step/run SHA and the task hash explicitly. Existing old identities remain refused;
no stored run or pin is rewritten to appear compatible.

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
A boundary starting at an already terminal EXIT/DEAD state is explicitly unsupported,
including a zero-tic segment at that boundary. The tested final EXIT segment starts
at tic676 and ends at677; it is not an empty segment starting at677.
Calls have a 120-second external timeout that terminates the Worker; aborts and
terminal boundaries are explicit errors, never manufactured neutral inputs.
The pipeline releases both proof and preparation Workers on failure or completion,
and on a hard stop. Preparation is recreated from pinned genesis if retried later.
Use `session.dispose()` (or `program.dispose()` with a directly owned pipeline) when
the run is closed; disposal rejects in-flight preparation and frees its Worker.

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

`main.ts` now connects F4 through `GameProofBridge`. The real route never calls
`createStubProgram`; the explicitly selected `?sim=demo` route retains the stub.
The bridge captures each InputJournal object, synchronizes acknowledged commands
before opening/proving/exporting and once per second while attached. A restart or
restore retires the old session and preserves separate journal and stored-run
exports. It never points an old program at a replacement journal.

F4 pauses via PlaySession and releases mouse capture. Closing leaves Resume
explicit. Preparation is cancellable during initialization; retired and failed
sessions release their workers. Cached-page suspension stops proof workers while
the existing game lifecycle retains its VM; reopening creates a verified fresh
preparation worker. These are synthetic persisted-event tests, not a claim of
actual browser BFCache admission.

The local panel offers raw game export even when proof assets are missing. Its
explicit proof action flushes the available acknowledged prefix, checks fresh AIR
resources and reports refusal without claiming certification. Refused arguments,
D14 output and resources remain in `.hellproof`. Import/resume requires the exact
Doom identity before writing the imported run, with old exports still available
on refusal. The Current game action explicitly leaves the imported run. New UI
sessions are offline and have no wrapper configured; F4, restore and refusal do
not start proofs or network submissions. The separate demo/prove routes retain
their existing explicit wrapper flow.

Unit tests cover deferred-initialization cancellation, captured providers,
synchronization coalescing, recovery and clearing a stale error before retry.
Browser tests execute the real game and resource checker, forbid `prove` messages,
and cover pre-F4 inputs, refusal/export/import, mismatched identity, restart,
synthetic BFCache events, keyboard pause and focus. Native pointer lock uses
`HELLPROOF_POINTER_LOCK=1 ... playwright test e2e/gameProof.spec.ts --headed`.

No complete-game proof, proof/render concurrency test on 16 GiB hardware, residual
C3 latency, or P3.7 completion is claimed by this UI or its resource measurements.

Worker ownership begins before asynchronous initialization. A failed or cancelled
prover init terminates the instance and cannot reattach it after a hard stop.
Local verification is owned by ProveSession as well: retirement, cached-page
suspension, reset and disposal cancel it immediately, including a pending init or
verification request. A lookup finishing after disposal cannot create a Worker.
