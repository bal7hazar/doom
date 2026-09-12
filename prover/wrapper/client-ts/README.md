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

## Notes for the browser client

* Send `format: "bincode_b64"`. The cairo-serde felt stream cannot be verified server-side (the
  encoding is one-way at the pinned monorepo commit), so a server with the default
  `require_verifiable_proof = true` refuses it.
* Segment proofs are ~3 MB each; a full game is tens of megabytes of request body. Submitting a
  game in one request is the supported shape (the run is the unit of idempotency), so keep the
  body streaming rather than building one giant string where you can.
* `run_id` is the idempotency key: reuse the same one when retrying a submission after a network
  failure, and the server returns the existing run instead of proving anything twice.
* `progress` and `timings` are what a progress UI should render. `batch_status` plus the batch's
  `closed_at_ms` tell the player whether they are still waiting for co-batchers (D6).
