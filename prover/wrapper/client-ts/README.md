# `@hellproof/wrapper-client`

TypeScript client and wire types for the [wrapper service](../README.md). No dependencies: it is
`fetch` plus the types, so it runs in the browser (where the segment proofs are produced) and in
Node ≥ 22.

```bash
npm install        # only typescript, for the build
npm run typecheck
npm run build      # -> dist/
```

```ts
import { WrapperClient, toSegmentSubmission } from "@hellproof/wrapper-client";

const client = new WrapperClient({ baseUrl: "http://127.0.0.1:8787", apiKey });

// `prove()` in prover/wasm returns the bincode extended CairoProof, and the bootloader's
// output preimage next to it.
const { run_id, status } = await client.submitRun(
  {
    program: "doom_run",
    player: account.address,
    solo: false,                       // true = wrap alone now, at the displayed cost (D6)
    segments: proved.map((s, index) =>
      toSegmentSubmission({
        index,
        args: s.args,
        outputPreimage: s.outputPreimage,
        proofBytes: s.proofBytes,
      }),
    ),
  },
  5000,                                // block up to 5 s for the verification verdict (R8-A1)
);
if (status === "rejected") throw new Error("the server rejected a segment proof");

const run = await client.waitForRun(run_id, {
  onProgress: (r) =>
    console.log(`${r.status}: ${r.progress.leaves_done}/${r.progress.segments} leaves`),
});
const batch = await client.getBatch(run.batch_id!, { include: ["proof", "packed"] });
// batch.root_proof_felts  -> the calldata for the on-chain circuit verifier (~94 k felts)
// batch.leaves            -> which leaf belongs to which run, in fold order
// batch.packed_output     -> the digest tree the consumer contract recomposes
```

The JSON schema these types mirror is documented in [`../README.md`](../README.md); `src/model.rs`
in the service is the source of truth for both.

## Resumable per-segment uploads

`submitRun` above still works (and stays the simplest option for a small game), but a 3-minute
DOOM run is 25–75 segment proofs — tens of megabytes in one request. `putSegment` uploads them one
at a time instead, so a dropped connection costs one proof, not the whole game, and a reload can
resume from wherever it left off:

```ts
const runId = "player-3f2a-game-9";

// What the server already has, if this is a resumed session (a fresh run answers with `held: []`
// once its first segment lands, or 404 before that — see the README's sequence diagram).
const { held } = await client.getHeldSegments(runId).catch(() => ({ held: [] as number[] }));

for (const segment of proved) {
  if (held.includes(segment.index)) continue; // already uploaded, and idempotent if retried anyway
  const verdict = await client.putSegment(runId, segment.index, toSegmentSubmission(segment));
  if (!verdict.verified) throw new Error(`segment ${segment.index} rejected: ${verdict.error}`);
}

const { run_id, status } = await client.completeRun(runId, {
  program: "doom_run",
  player: account.address,
});
if (status === "rejected") throw new Error("the chain check failed at /complete");
const run = await client.waitForRun(run_id);
```

A run can also be created explicitly, fixing its program before any segment arrives:

```ts
await client.submitRun({ run_id: runId, program: "doom_run", segments: [], expected_segments: 40 });
// ...putSegment for each of the 40 indices...
await client.completeRun(runId); // `program` is already known, so it can be omitted here
```

`deleteRun(runId)` discards an unfinished (`collecting`) upload — useful if the player abandons the
game before completing it, so its partial segments do not linger on the server.

## Notes for the browser client

* Send `format: "bincode_b64"`. The cairo-serde felt stream cannot be verified server-side (the
  encoding is one-way at the pinned monorepo commit), so a server with the default
  `require_verifiable_proof = true` refuses it.
* Segment proofs are ~3 MB each; a full game is tens of megabytes of request body. `submitRun`
  keeps that streaming rather than building one giant string where it can, but `putSegment` is the
  better fit once a game runs to more than a handful of segments — see above.
* `run_id` is the idempotency key: reuse the same one when retrying a submission (whole-run or
  per-segment) after a network failure, and the server returns the existing run — or the existing
  segment, by content hash — instead of proving anything twice.
* `progress` and `timings` are what a progress UI should render. `batch_status` plus the batch's
  `closed_at_ms` tell the player whether they are still waiting for co-batchers (D6).
