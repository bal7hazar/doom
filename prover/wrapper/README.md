# `prover/wrapper` — the Hellproof wrapper service

The browser proves each **segment** of a game (`prover/wasm`, spike S2). One Starknet fact can only
carry **one** proof, and a game is 25–75 segments, so those segment proofs have to be folded into a
single **root proof** that the on-chain circuit verifier accepts. That fold needs 32.5 GB of RAM per
step (S4) and is not feasible in a browser — hence this service (PLAN §1 **A4**, Phase 3 task 4;
G0 decisions **D6** and **D7**; risk **R8**).

It owns no proving code. It drives the pinned `starkware-libs/proving` binaries
(**`cd7bc5f`**, R3-A1, plus [`patches/`](patches/README.md)) as subprocesses with a configured
circuit registry (S4, S4b):

```
segment proofs (browser)
   │  POST /v1/runs
   ▼
verify      hellproof-leaf-verify     ~0.02 s/segment   ← reject invalid submissions here (R8-A1)
   ▼
leaf        leaf-prover --cairo_proof          ~24 s / 32.1 GB per leaf
   ▼                    ↑ the browser's proof goes straight into the leaf circuit (D19)
fold        stwo_run_and_prove_recursive_tree   ~28 s / 31.3 GB per reduction
   ▼
root proof felts + packed_output + program_output   → GET /v1/batches/{id}
```

A batch can hold **several games** (D6 / R7-A3): the on-chain cost of one fact is divided by the
number of games in it.

## Contents

| Path | What |
|---|---|
| `src/` | the service (axum + tokio + rusqlite) |
| `leaf-verify/` | `hellproof-leaf-verify`, the Rust verifier front end (its own workspace: it pulls the monorepo's `cairo-air`) |
| `client-ts/` | the TypeScript client the browser will use |
| `patches/` | the diff carried on top of the pinned monorepo, one commit per file, written for upstream (D19) |
| `scripts/apply_patches.sh` | applies them to a clone; the Dockerfile runs it after the checkout |
| `scripts/e2e_fixtures.sh` | produces browser-equivalent segment proofs for the end-to-end test |
| `scripts/leaf_mode_equivalence.sh` | proves the same segments both ways and checks the roots are identical |
| `wrapper.example.toml` | a complete configuration |
| `../../infra/wrapper/` | `Dockerfile` and `docker-compose.yml` |

## API

All endpoints need `Authorization: Bearer <api-key>`. Times are milliseconds, felts are `0x…` hex
(decimal strings are accepted on input and normalised to hex).

### `POST /v1/runs` — submit one game

Query: `?wait_verify_ms=N` blocks up to `N` ms for the verification verdict, so an invalid
submission comes back as `422` instead of surfacing later in the run status.

```jsonc
{
  "run_id": "optional-client-id",          // idempotency key; [A-Za-z0-9_-]{1,64}
  "player": "0x04a3…",                     // Starknet account address (informational for now)
  "program": "segment_stub10",             // a program id the server has pinned
  "program_hash_function": "blake",     // optional; must match the program's configuration
  "solo": false,                           // true = wrap this game alone, immediately
  "expected_segments": 40,                 // optional; resumable uploads only, see below
  "segments": [                            // empty (or omitted) creates a `collecting` run
    {
      "index": 0,                          // 0-based, contiguous, in fold order
      "args": ["0x1","0x0","0x1","0x0","0x0","0x0","0x0","0x0"], // rerun only
      "output_preimage": [                 // [task_program_hash, task_output…]
        "0x6715c525…",                    // measured task hash
        "0x1", "0x1", "0x32185493…",        // version, h_in, h_out
        "0x0", "0x1", "0x0",              // tic_start, tic_end, status
        "0x4ac69ffd…", "0x0", "0x0", "0x0" // commitment, kills, items, secrets
      ],
      "public_outputs": ["0xde5c…", "0x44bf…"],   // optional, the 2 output cells
      "proof": {
        "format": "bincode_b64",           // or "cairo_serde_felts" (see below)
        "data": "<base64 of the bincode extended CairoProof>"
      }
    }
  ]
}
```

Response `202` (or `422` when `wait_verify_ms` caught a rejection):

```json
{ "run_id": "9f2c…", "status": "verifying", "segments": 2, "duplicate": false }
```

Errors: `400` validation, `401` auth, `409` same `run_id` with different content, `422` rejected
proof, `429` quota, `413` body over `max_body_bytes`.

An empty (or omitted) `segments` array does not submit a game — it creates one, with none of its
segments uploaded yet: `{ "run_id": "…", "status": "collecting", "segments": 0, "duplicate": false }`,
`202`. `expected_segments`, if given, is checked later at `/complete`; it is not required, since the
chain check is what actually proves a game is whole. This is the resumable per-segment upload
protocol below — a run can also come into existence without this call at all, from a first `PUT`.

**Proof formats.** `bincode_b64` is what `prover/wasm`'s `prove()` returns, the **only form the
Rust verifier can read**, and — since P3.4b — the only form that can be *folded*. The cairo-serde
felt stream (`proof_to_felts`) is one-way at `cd7bc5f`: `CairoProof` derives `CairoSerialize` but
not `CairoDeserialize`, the monorepo's own loader panics with *"Deserialization from a
Cairo-serialized proof is not supported"* (`cairo_air::utils::deserialize_proof_from_file`), and
the stream is lossy besides — it carries neither `ExtendedStarkProof.aux` nor
`preprocessed_trace_variant`, and it transposes the queried values. `cairo_serde_felts` is
therefore accepted only with `leaf_mode = "rerun"` **and** `require_verifiable_proof = false`, and
such a run skips the R8-A1 gate. `hellproof-leaf-verify` and `leaf-prover --cairo_proof` both
accept the raw bincode the browser sends *and* the bzip2-wrapped `--proof-format extended-binary`
files the monorepo writes; nothing else is needed on the browser side.

**What the server checks before spending anything** (all of it in well under a second):

1. segment indices contiguous and ordered; args, preimage and outputs are felts;
2. the chain `h_in[i+1] == h_out[i]` across the run (PLAN Phase 3 task 3);
3. `output_preimage[0]` equals the pinned task hash of `program` (required for
   `backend = "subprocess"` / `leaf_mode = "from_proof"`), and
   the submission's `program_hash_function` is the one that program is configured for (`blake`
   vs `poseidon` give different program hashes, so it is part of a leaf's identity);
4. `public_outputs == blake2s(cairo0_encode(output_preimage))` — the two 128-bit output cells the
   leaf circuit will publish;
5. then, per segment, the **Rust verifier** on the proof itself, and that the proof's own output
   cells are exactly those from (4). This is what binds the submitted preimage — and therefore the
   leaf's contribution to the root digest — to the proof. With `leaf_mode = "from_proof"` it is
   also the *only* place that binding is made, since nothing is replayed afterwards; the leaf
   circuit then re-derives the same cells from the proof's public memory and constrains them
   through the public logup sum, so a leaf cannot be built around a preimage that is not the
   proof's own.

### Resumable per-segment uploads

A 3-minute DOOM run is 25–75 segment proofs, ~3 MB each — tens of megabytes in the one request
`POST /v1/runs` wants. These four endpoints let a client upload a game one segment at a time
instead, so a dropped connection costs one proof rather than a whole re-upload, and a reload can
resume from whatever the server already holds. `client-ts`'s `putSegment`/`getHeldSegments`/
`completeRun`/`deleteRun` wrap them; `client/src/wrapper/submitter.ts` in the browser client probes
for them and falls back to the whole-run `POST` when they are absent (an older server).

A run spends its whole life in one extra state, `collecting`, before it ever reaches `verifying`:
accepting segments, nothing queued, nothing billed yet. It ends there either by `/complete` (moving
on to `verifying`, exactly where a whole-run `POST` would have left it) or by `DELETE`.

```mermaid
sequenceDiagram
    participant C as Client
    participant S as Wrapper

    Note over C,S: First attempt
    C->>S: GET /v1/runs/{id}/segments
    S-->>C: 404 (run does not exist yet)
    C->>S: PUT /v1/runs/{id}/segments/0  (proof 0)
    Note right of S: verifies immediately (R8-A1)<br/>run created as `collecting`
    S-->>C: 200 { verified: true, sha256, ... }
    C->>S: PUT /v1/runs/{id}/segments/1  (proof 1)
    S-->>C: 200 { verified: true, ... }
    Note over C,S: connection drops before segment 2

    Note over C,S: Resumed attempt (reload, retry)
    C->>S: GET /v1/runs/{id}/segments
    S-->>C: 200 { held: [0, 1], segments: [...] }
    C->>S: PUT /v1/runs/{id}/segments/1  (proof 1, same bytes)
    S-->>C: 200 { verified: true, duplicate: true }
    Note right of C: idempotent by sha256 — a safe retry, not a re-verification
    C->>S: PUT /v1/runs/{id}/segments/2  (proof 2)
    S-->>C: 200 { verified: true, ... }
    C->>S: POST /v1/runs/{id}/complete  { program, player, solo }
    Note right of S: chain check (h_in/h_out) across every<br/>segment; binds each to the program (leaf key);<br/>queues into the batching policy (D6)
    S-->>C: 202 { status: "verifying", batch_id: null }
    C->>S: GET /v1/runs/{id}  (poll, as with a whole-run POST)
    S-->>C: 200 { status: "done", batch_id, ... }
```

#### `GET /v1/runs/{id}/segments` — what the server holds

```json
{
  "run_id": "9f2c…", "status": "collecting", "expected_segments": 40,
  "held": [0, 1, 2],
  "segments": [
    { "index": 0, "size_bytes": 2954931, "sha256": "1c2a…", "verified": true, "verify_ms": 21.4 }
  ]
}
```

`404` if `id` does not exist yet — indistinguishable, on purpose, from "nothing uploaded"; a client
that wants to know which is the case tracks that itself (or just starts uploading: the first `PUT`
creates the run).

#### `PUT /v1/runs/{id}/segments/{index}` — one segment

`Content-Type: application/json` carries exactly one element of a whole-run `POST`'s `segments`
array (`index` in the body must match the URL, if present). Any other content type is the raw
bincode `CairoProof` bytes as the whole body, with the felts a JSON envelope would have carried
instead in headers: `X-Hellproof-Output-Preimage` (required), `X-Hellproof-Args` and
`X-Hellproof-Public-Outputs` (both optional) — comma-separated `0x…` felts. Either way this is at
most `max_proof_bytes` of one proof, so the request body is never more than a single segment's
worth of memory, matching the bound a whole-run `POST` has per segment it streams.

If the run does not exist yet, this call creates it (`collecting`, no program: `/complete` supplies
one). An index at or past `expected_segments` (or past `max_segments_per_run` when that was never
declared) is `400`. The proof is **verified immediately** with the Rust verifier — not merely
queued — against the output cells its own `output_preimage` implies; the response is the verdict:

```json
{ "run_id": "9f2c…", "index": 0, "verified": true, "verify_ms": 21.4,
  "sha256": "1c2a…", "size_bytes": 2954931, "duplicate": false }
```

Idempotent by content hash: uploading the same bytes again under the same index replays this same
response (`"duplicate": true`) without re-verifying; different bytes under an already-held index is
`409`, not a silent overwrite. A failed verdict (`422`, mirroring `wait_verify_ms` on the whole-run
path) also rejects the run itself (`status: "rejected"`), the same as an invalid proof in a
whole-run `POST` — nothing later can un-reject it, `/complete` included.

The pinned-program-hash check and the leaf cache key (`validate::bind_segment_to_program`) are not
made here — a bare `PUT` does not know the program yet — so they wait for `/complete`, along with
the chain check, which needs every segment at once regardless.

Errors: `400` validation or out-of-range index, `401` auth, `403` a different account's run, `409`
run no longer `collecting`, or same index with different content, `413` over `max_proof_bytes`.

#### `POST /v1/runs/{id}/complete` — finish a resumable upload

```json
{ "program": "doom_run", "program_hash_function": "blake", "player": "0x04a3…", "solo": false }
```

`program` is required unless the run already has one (an explicit `POST /v1/runs` supplied it);
giving a different one than that is `400`. This is where the whole-run checks that need every
segment at once finally run — indices contiguous from `0`, the count matches `expected_segments`
when one was declared, the `h_in[i+1] == h_out[i]` chain, and each segment's pinned program hash —
and the first one that fails is what comes back, `422`. Once all of that passes the run is queued
into the batching policy exactly as a whole-run `POST` would have (every segment is already
verified, so nothing is re-verified). Same response and `wait_verify_ms` semantics as
`POST /v1/runs`:

```json
{ "run_id": "9f2c…", "status": "verifying", "segments": 40, "duplicate": false }
```

Calling it again on a run that already left `collecting` answers idempotently — the run's current
status, `duplicate: true` — or replays the stored rejection (`422`) if a segment was rejected along
the way.

#### `DELETE /v1/runs/{id}` — abandon an unfinished upload

Only ever a `collecting` run: nothing has been queued or billed for it yet, so this is just
forgetting its rows and its proof files. `204`, or `409` if the run has already left `collecting`
(finish it or leave it be — it cannot be un-queued), or `404` if it never existed.

### `GET /v1/runs/{id}` — status, progress, per-stage timings

```jsonc
{
  "run_id": "9f2c…", "status": "wrapping", "program": "segment_stub", "solo": false,
  "batch_id": "1a7e…", "batch_status": "closed",
  "progress": { "segments": 2, "verified": 2, "leaves_done": 1, "leaves_cached": 0 },
  "segments": [
    { "index": 0, "leaf_key": "29ee…", "verified": true, "verify_ms": 21.6,
      "leaf_state": "done", "leaf_ms": 24081.4, "leaf_max_rss_bytes": 32122880000 }
  ],
  "timings": { "verify_ms_total": 41.3, "leaf_ms_total": 48162.8, "fold_ms": null,
               "queued_ms": 12.0, "total_ms": null }
}
```

`status`: (`collecting` →) `verifying` → `rejected` | `queued` → `wrapping` → `done` | `failed`.
`collecting` only appears for a run built through the resumable per-segment upload protocol,
before its `/complete`.

### `GET /v1/batches/{id}` — the root proof and the fold order

Query: `?include=proof` adds the ~94 k root felts (and the packed tree), `?include=packed` only the
tree. Without it the response carries the metadata and `root_proof_felt_count`.

```jsonc
{
  "batch_id": "1a7e…", "status": "done",
  "runs": ["9f2c…", "b331…"],
  "leaves": [                                  // the fold order, left to right
    { "position": 0, "run_id": "9f2c…", "segment_index": 0, "leaf_key": "29ee…" },
    { "position": 1, "run_id": "9f2c…", "segment_index": 1, "leaf_key": "460c…" },
    { "position": 2, "run_id": "b331…", "segment_index": 0, "leaf_key": "7b10…" }
  ],
  "fold_ms": 27683.0, "fold_max_rss_bytes": 31344640000,
  "root_proof_felt_count": 93797,
  "root_proof_felts": ["0x1799", "…"],         // with ?include=proof
  "program_output": [1047851672, …],           // the root node's 8 output words
  "packed_output": { "Composite": { "circuit_hash": […], "subtasks": […] } }
}
```

`root_proof_felts` is exactly what `scarb execute -p stwo_circuit_verifier --arguments-file`
consumes. `leaves` is what the consumer contract needs to map leaves back to players
(R7-A3: "indexation joueur → feuilles").

### `POST /v1/batches/close` — admin

Closes the open batch now rather than waiting for M runs or T minutes. Returns `{ "closed": [id] }`.

### `GET /metrics`, `GET /healthz`

Prometheus text and a liveness probe that echoes the effective policy and registry hash.

## What the browser has to produce

Since P3.4b the submitted proof is not checked and discarded, it is **folded**. That makes the
browser's output format part of the protocol, so here it is in full — and the answer is that
`prover/wasm` needs no change at all (S2's `prove()` already returns exactly this).

**The bytes.** `bincode::serialize(&proof)` where `proof: CairoProof<Blake2sMerkleHasher>` — the
whole struct, not `CairoProofForRustVerifier`. That is byte-for-byte what
`stwo_run_and_prove --proof-format extended-binary` writes, modulo the bzip2 wrapper that tool
adds and the wrapper accepts either way (it sniffs the `BZh` magic). Base64 it into
`proof.data` with `"format": "bincode_b64"`. **Confirmed**, as S2 said. The other three
`ProofFormat`s are unusable here:

| Format | What is missing |
|---|---|
| `json`, `binary` | `CairoProofForRustVerifier` — `StarkProof` instead of `ExtendedStarkProof`, so no `aux` |
| `cairo-serde` (`proof_to_felts`) | no `aux`, no `preprocessed_trace_variant`, queried values transposed, and no `CairoDeserialize` to read it back |

**Why `aux` is the whole point.** The leaf circuit is filled by
`prepare_cairo_proof_for_circuit_verifier`, which needs `extended_stark_proof.aux`:
`unsorted_query_locations` (the query indices in sampling order, before sorting and
deduplication), `trace_decommitment` (per-tree Merkle decommitment aux) and `fri` (FRI aux). The
Rust verifier can re-derive what it needs; the in-circuit verifier cannot, and a proof without
`aux` simply cannot be wrapped. This is the one hard requirement the browser side has.

**The public data.** Everything else the leaf needs is already in `claim.public_data`, and the
wrapper reads it from there rather than asking for it:

* `public_memory.output` — exactly **2 cells**, each a 128-bit half of the run's Blake2s digest.
  They become the leaf circuit's public output, and the circuit constrains them against the proven
  public memory through the public logup sum. A run producing any other number of output cells is
  rejected while the circuit is built.
* `public_memory.program` — the bootloader's bytecode as proven. The wrapper does **not** take the
  program from here: the circuit bakes it in as constants, so it comes from the configured
  `leaf_bootloader` and the registry's leaf circuit hash is what pins it (see
  [`patches/README.md`](patches/README.md)).
* `preprocessed_trace_variant` must be the registry's (`canonical_small`), and the proof's per-tree
  column counts must match the verifier config — both checked before any proving.

**The prover parameters** are still `prover/wasm/harness/params/leaf.json` and must stay exactly
that: `blake2s_m31` channel, `canonical_small` preprocessed trace, `include_all_preprocessed_columns
= true`, `lifting_size_policy = at_least_preprocessed`, FRI pow 26 / blowup 1 / 70 queries. Those
are what make every segment up to 2^20 steps land on the log-20 leaf circuit the registry lists.

**The preimage.** `output_preimage` (the felts the bootloader dumps to `output_preimage_dump_path`)
is still submitted alongside the proof — not because the leaf needs it, but because
`stwo_run_and_prove_recursive_tree` hashes it into the leaf's node output. It cannot be faked: the
wrapper checks `blake2s(cairo0_encode(preimage))` against the proof's own output cells at
submission, and the fold re-verifies the leaf proof in circuit against the output it derives from
the preimage, so a mismatched pair fails there too.

Nothing else. In particular the browser does **not** need to send `args` any more, and does not
need to run the bootloader twice or produce any second artefact.

## Batching policy (D6)

A batch closes when **either**:

* it holds `batch_max_runs` games (**M**, default 8) — checked the moment a game joins, so a burst
  produces batches of exactly M; **or**
* `batch_max_wait_secs` (**T**, default 600 s) have passed since the batch opened.

A game submitted with `"solo": true` gets a batch of its own, closed immediately: that is the
"submit alone now, at the displayed cost" option D6 requires so a player never waits without
knowing. An operator can also force a close through `POST /v1/batches/close`.

Leaves are proven as soon as a game is verified, *before* its batch closes, so the wait costs
nothing but the fold. Within a batch the fold order is: games in the order they finished
verification, segments in index order.

## The circuit registry

The registry is one configuration item, and everything downstream follows from it: the leaf circuit
hash the contract pins, the multiverifier hash the on-chain verifier constants are generated from,
the size of each leaf cache key, and the memory and time of every circuit proof. Both hashes are
checked against the file at startup, so a registry swap that would invalidate the deployed verifier
constants fails immediately instead of producing roots nothing on chain accepts.

| Registry | Multiverifier | Per circuit proof | Notes |
|---|---|---|---|
| `spikes/s4/registry/doom` (default) | `a5989715…973f680f` — **identical to production**, so the deployed verifier constants hold | 32.1–32.5 GB, ~24 s | production padding, `fold_step = 1` (S4) |
| `spikes/s4/registry/doom_fold4_min` (**production target**) | `02b34360…9f7fac34` — different: P4.0 must regenerate the constants | 21.9 GB / 13.3 s per leaf, 21.4 GB / 13.5 s per fold | `fold_step = 4` + minimal padding, −33 % memory and −41 % time (S4b) |

`max_circuit_proofs` follows from that number and the machine's memory unless the operator sets it:
one at a time with `doom` on 64 GB, **two with `doom_fold4_min`**.

Segment size is not a constraint the wrapper enforces: `trace_log_size` comes from the largest AIR
component, not from the step count, so a segment of up to ~5.38 M steps still uses the log-20 leaf
circuit and costs the same leaf proof (S4b measurement 3) — about 25 leaves for a 3-minute game.

## Configuration

`wrapper.example.toml` is the reference; a few knobs are overridable by environment
(`WRAPPER_BIND`, `WRAPPER_DATA_DIR`, `WRAPPER_REGISTRY_JSON`, `WRAPPER_MAX_CIRCUIT_PROOFS`,
`WRAPPER_BATCH_MAX_RUNS`, `WRAPPER_BATCH_MAX_WAIT_SECS`, `WRAPPER_API_KEY`).

| Key | Default | Notes |
|---|---|---|
| `registry.path` / `.multiverifier_hash` / `.leaf_circuit_hash` / `.circuit_proof_rss_bytes` | — | see above; the hashes are verified at startup |
| `max_circuit_proofs` | derived | leaf **and** fold jobs share this semaphore; omitted = machine memory / `registry.circuit_proof_rss_bytes` |
| `max_verify_jobs` | `4` | cheap, CPU-only |
| `proof_lock_dir` | — | optional `mkdir` mutex shared with other proving jobs on the machine |
| `batch_max_runs` / `batch_max_wait_secs` | `8` / `600` | D6 |
| `max_segments_per_run` | `64` | ~25 leaves per 3-minute game (S4b); raise it for longer sessions |
| `max_proof_bytes` | `8 MiB` | a 2^20-step segment proof is ~3 MB bincode |
| `require_verifiable_proof` | `true` | refuse felt-only submissions (they cannot be verified). `leaf_mode = "from_proof"` refuses them regardless: they cannot be folded either |
| `check_preimage_binding` | `true` | `rerun` only: the bootloader's dumped preimage must equal the submitted one. `from_proof` replays nothing, and the verify stage already made that binding |
| `job_max_attempts` | `3` | leaf and fold jobs are retried; a verification verdict is never retried |
| `programs[].hash_function` | `blake` | D31: matches the browser runtime; passed to bootloader task input in rerun mode |
| `programs[].program_hash` | required for subprocess/from_proof | Task hash at `output_preimage[0]`, measured from the exact executable; parsed as a felt at startup |
| `programs[].output_layout` | `d14` | Eleven felts including task hash and version 1; `legacy_stub` explicitly selects the old five-felt spike fixture |
| `backend` | `subprocess` | `stub` disables proving entirely (tests, load runs) |
| `leaf_mode` | `from_proof` | `from_proof` folds the submitted proof (`leaf-prover --cairo_proof`, needs `patches/`); `rerun` replays the segment from its `args`. Checked at startup |

### Output layout and chain (D14)

The product layout is exactly eleven preimage felts:
`[task_hash, version=1, h_in, h_out, tic_start, tic_end, status, commitment, kills, items, secrets]`.
Both whole-run admission and resumable completion use the same decoder and compare
`previous[3] == next[2]`. The version is not a state hash. Unknown versions and
wrong lengths are rejected before any circuit work. A bare PUT does not yet know
the program/layout; its program-specific validation happens at `/complete`.

The historical S4 `segment_stub` fixtures have five felts
`[task_hash, h_in, h_out, n, status]`. They require an explicit
`output_layout = "legacy_stub"` on that program configuration; no layout is guessed
from client data. Existing tests select that layout explicitly. The client and
Docker examples use `segment_stub10` with `output_layout = "d14"`.

### Task identity at admission (D19 / D31)

`from_proof` never reads the configured task executable while constructing a leaf.
Its path alone cannot pin the submitted task: `program_hash` is therefore mandatory
for every subprocess/from_proof program. Missing pins and malformed/out-of-field
felts fail at startup; admission repeats that check for callers using the library.
Stub backends may keep fake programs without pins; rerun mode may omit a pin because
it executes the configured file. A supplied pin is always parsed and enforced.

Whole-run submission binds every preimage before queueing. A bare resumable PUT
verifies the proof/output digest without yet knowing the program; `/complete`
checks each task pin before assigning leaf keys or queueing. Recovered leaf jobs
rebind against the current configuration before using a cached leaf or starting
a prover, so a changed pin cannot revive work admitted under an older identity.
Before every new from_proof circuit, the same stored proof file handed to the
circuit is checked again by the native gate. This covers persisted `verified`
markers from an earlier policy, including the bootloader binding; successful
cached circuit leaves need no repeat check. The extra work is one cheap native
verification, not a new Cairo execution or proof.

`hellproof-leaf-verify` reports the **bootloader** hash in `program_hash`; its
`--expect-program-hash` option also pins that bootloader. The service passes `--expect-bootloader` with its configured Cairo 0 bootloader:
the verifier derives the expected hash from that exact bytecode using the pinned
upstream hash function, and rejects another proven program before a circuit job.
No duplicate bootloader hash constant is maintained. Neither bootloader pin is
the task hash at `output_preimage[0]`. The output digest binds that separate task preimage to
the verified proof. DoomRuns additionally recomposes with its own pinned task hash.

The examples use the exact committed `client/public/programs/segment_stub10.executable.json`:
SHA-256 `7617a62d9ea3cf6968a24442c246f6c96c4a1018414fd71360ee42dbb9240a4a`,
Blake task hash `0x6715c525e90af7cf1df88ebcae1d7556ebbbbf1da79a2a322408b3593a9786a`.
Measured using the built WASM core on arguments `["0x1","0x0","0x1","0x0","0x0","0x0","0x0","0x0"]`,
171,372 steps; no proof generation. From the repository root, Node 24 can remeasure:

```sh
node prover/wrapper/scripts/measure_task_hash.mjs \
  prover/wasm/pkg/dist/core.js client/public/programs/segment_stub10.executable.json args.json
```

The script requires string felts and reports the executable SHA-256 with the task
hash. Any rebuild, profile or artifact change needs a fresh measurement; do not
copy this pin to doom_run. This command uses Blake because that is the runtime's
fixed choice, without altering the leaf prover parameters or registry.

## Authentication

**Implemented: API keys.** `Authorization: Bearer <key>`; each key carries an `account` (the quota
and ownership key), an `admin` flag and a rolling 24 h `daily_run_quota`.

**Intended: Cartridge Controller session signatures** (R8-A2). The seam is the `Authenticator`
trait in `src/auth.rs`; only the implementation changes, not the handlers. The scheme:

1. The client computes the canonical submission digest
   `h = poseidon(DOMAIN, run_id, program_id, leaf_key_0, …, leaf_key_{n-1})`, where `leaf_key_i` is
   the same content hash the server derives (registry hash, program id, args), so the signature
   commits to *what* is being wrapped, not to the proof bytes.
2. It signs `h` with its **session key** and sends `X-Hellproof-Account` (the account address),
   `X-Hellproof-Session-Signature` and the session policy proof.
3. The server resolves `is_valid_signature(h, sig)` (SNIP-6) on that account through a Starknet
   node, checks the session policy authorises "submit run" and that the session has not expired,
   and uses the account address as the quota key.
4. Replay is bounded by the `run_id` idempotency already implemented: a repeated signature on the
   same digest is the same run.

Neither scheme authorises anything on-chain: the wrapper cannot forge a proof, and the contract is
indifferent to where a valid root proof came from (R8-A4).

## Persistence and resume (R8-A2)

Everything lives in SQLite (`data_dir/queue.sqlite3`, WAL): runs, segments, content-addressed
leaves, batches with their frozen fold order, and the job queue. The service persists a submission
*before* queueing any work, and on startup `recover()` re-queues every job that was `running`,
re-opens batches caught mid-fold and resets half-proven leaves. Killing the process at any point
loses no game. Proof files live under `data_dir/proofs/` (`leaves/<leaf_key>.json`,
`batches/<id>/root.proof`); a segment uploaded through the resumable protocol lands under
`data_dir/submissions/<run_id>/` immediately, on `PUT`, the same as a whole-run `POST` writes its
segments — so a `collecting` run's progress is exactly as durable as a queued one's, restart or
not. Its `leaf_key` is `NULL` until `/complete` assigns it (the program is not known before then).

Leaves are **content addressed**: `leaf_key = sha256(registry_hash, program_id, program_hash,
hash_function, identity)`. The same segment submitted twice — by the same player or by two players
— is proven once, and a registry change invalidates the whole cache instead of silently mixing
circuits (R8-A3).

What `identity` is depends on `leaf_mode`, and the two are domain-separated so they never share an
entry. In `rerun` it is the segment's **arguments**: the server replays them, so they determine the
leaf proof. In `from_proof` there is no canonical proof for a segment — two runs of the same code
produce two different, equally valid proofs — so keying on the proof bytes would destroy the cache.
It keys on the **output preimage** instead: that is precisely what a leaf contributes to the root
(the tree hashes it, and the fold re-verifies the leaf proof in circuit), so two leaves with the
same preimage are interchangeable for every consumer.

## Metrics

`GET /metrics`, Prometheus text:

| Metric | Type | Labels |
|---|---|---|
| `wrapper_jobs_total` | counter | `kind` (`verify`/`leaf`/`fold`), `outcome` (`done`/`retry`/`failed`) |
| `wrapper_job_duration_seconds` | histogram | `kind` |
| `wrapper_verify_duration_seconds` | histogram | — |
| `wrapper_job_max_rss_bytes` | gauge (peak) | `kind` |
| `wrapper_queue_depth` | gauge | `kind`, `state` |
| `wrapper_runs` / `wrapper_runs_total` | gauge / counter | `status` |
| `wrapper_batches_opened_total`, `wrapper_batches_closed_total` | counter | — |
| `wrapper_batch_leaves`, `wrapper_root_proof_felts` | histogram | — |
| `wrapper_leaf_cache_hits_total` | counter | — |

Logs are structured JSON (`tracing`); `RUST_LOG` selects the level.

## Running it

```bash
cargo build --release                       # the service
cd leaf-verify && cargo build --release     # the verifier (pulls the pinned monorepo)
cp wrapper.example.toml wrapper.toml        # then edit the paths
./target/release/hellproof-wrapper --config wrapper.toml --check   # validate
./target/release/hellproof-wrapper --config wrapper.toml
```

The pinned `leaf-prover` and `stwo_run_and_prove_recursive_tree` come from the monorepo at
`cd7bc5f`, with [`patches/`](patches/README.md) applied:

```bash
git clone https://github.com/starkware-libs/proving.git && cd proving && git checkout cd7bc5f
prover/wrapper/scripts/apply_patches.sh .          # `leaf-prover --cairo_proof`; skip for "rerun"
cargo build --release -p leaf-prover -p stwo-run-and-prove-recursive-tree
```

The container image in `infra/wrapper/` does all of that for you.

## Tests

```bash
cargo test                       # service tests, no proving (real pipeline tests stay ignored)
cargo test --test load           # 20 concurrent runs on the stub backend
```

* `src/batching.rs` — the D6 policy, as pure functions.
* `src/recompose.rs` — the Rust twin of `spikes/s4/recursion_outputs`, checked against the four
  committed S4 runs (N = 1, 2, 3, 4): it reproduces both `program_output` and the
  `VerificationOutput.output_hash` the on-chain verifier printed. The fold job runs the same check
  on its own output and fails the batch on a mismatch.
* `tests/service.rs` — submission, batching, fold order, cache, idempotency, auth, validation,
  metrics, and two restart tests.
* `tests/resumable.rs` — the resumable per-segment upload protocol: a bare `PUT` creating a run,
  idempotent-by-hash and out-of-range `PUT`s, `/complete` rejecting a broken chain / a gap / a
  short count with `422`, ownership on the new endpoints, `DELETE` only working on a `collecting`
  run, the raw-bincode `PUT` body, and a restart test that rebuilds the router against the same
  on-disk database mid-upload to check a partial upload survives it.
* `tests/pipeline_e2e.rs` — the **real** pipeline (ignored by default), see its module docs. One
  test per `leaf_mode`: `folds_the_submitted_proofs_without_reproving_them` submits with **no**
  `args` at all and checks the root is the recomposition of the submitted preimages;
  `wraps_two_real_segment_proofs_into_one_root` does the same in `"rerun"`;
  `resumable_upload_wraps_two_real_segment_proofs_into_one_root` submits the same two fixtures
  through `PUT`/`/complete` instead of one `POST`, and checks it folds the same way.
* `scripts/leaf_mode_equivalence.sh` — the two modes on the same segment proofs, folded, compared
  leaf by leaf and at the root, then the circuit verifier on the proof-only root and a tampered
  proof that must be rejected. Not a `cargo test`: it needs 32 GB and the pinned binaries.

## Measured end to end

M2 Max, 12 cores, 64 GB, `doom` registry, `max_circuit_proofs = 1`, one game submitted `solo`.
Segment proofs produced by `scripts/e2e_fixtures.sh` (2.4–4.7 s and 2.7 GB each, 2.95 MB on the
wire) stand in for the browser.

| | N = 2 | N = 4 |
|---|---|---|
| verify all segments (Rust verifier) | **0.34 s** | **0.31 s** |
| leaf (each) | 24.1 s / 32.0–32.1 GB | 21.1–25.0 s / 31.7–32.1 GB |
| fold (whole batch) | 27.7 s / 31.3 GB | 69.4 s / 32.3 GB |
| **end to end** (submit → root proof) | **76.5 s** | **160.6 s** |
| root proof | 93 797 felts | 96 033 felts |
| circuit verifier on that root | 5 260 345 steps, 506 312 range_check | 519 203 range_check |
| tampered proof rejected in | 0.29 s | 0.31 s |

Both roots reproduce the corresponding S4 golden run exactly — same leaf circuit hash
(`2ad52ed0…9edac7e2`), same multiverifier hash (`a5989715…973f680f`, production's), same felt
count, and the same `VerificationOutput.output_hash` the on-chain verifier prints. R8-A1's "reject
an invalid leaf in < 5 s" is met by an order of magnitude, and no expensive job is ever scheduled
for a rejected run.

### `from_proof` against `rerun` (P3.4b)

`tests/pipeline_e2e.rs`, same machine, same fixtures, N = 2, back to back with the proof lock held
so nothing else ran:

| | `from_proof` | `rerun` |
|---|---|---|
| leaf 0 / leaf 1 | **19.1 s / 18.9 s** | 21.7 s / 22.1 s |
| leaf peak RSS | **31.4 GB** | 31.9 GB |
| fold | 25.0 s / 31.4 GB | 27.3 s / 31.4 GB |
| **end to end** | **65.0 s** | 73.0 s |
| root proof | 93 797 felts | 93 797 felts |

**2.6–3.2 s and ~0.5 GB less per leaf**, about 13 %. The accounting, from `leaf-prover`'s own log
timestamps: `rerun` spends 2.07 s (segment 0) and 3.05 s (segment 1) running the segment under the
bootloader, adapting and proving it, while `from_proof` spends 0.7–1.0 s reading and deserializing
the 4.2 MB bincode proof. On `segment_stub` (155 k steps) that is all there is to win; a real
3-minute DOOM segment is ~20× longer, and its Cairo proof is the 5–10 s per segment D19 is about,
against a proof that grows far more slowly — so the margin widens with segment size, not shrinks.

The two are **interchangeable, not merely comparable**. `scripts/leaf_mode_equivalence.sh` proves
the same two segment proofs both ways and compares:

* per leaf: `circuit_hash`, `circuit_preprocessed_root` and `output_preimage` — identical;
* at the root: `program_output`, the whole `packed_output` tree and the felt count — identical;
* the on-chain circuit verifier on the **proof-only** root: accepted, 5 260 345 steps and 506 312
  `range_check` — the same figures as the golden run above — and the same
  `VerificationOutput.output_hash` (`[2757233259, 2334429728, …, 618877963]`) that `rerun`,
  `recompose::root_from_preimages` and the S4 golden all produce;
* a proof with **one felt flipped** (a single bit in the queried-values/FRI region): rejected by
  `assert!(context.is_circuit_valid())` while the circuit is being *built*, i.e. before the 24 s /
  32 GB circuit proof is started, not silently absorbed.

## Known gaps

* **The patch is not upstream yet.** `leaf_mode = "from_proof"` — the default — needs
  `patches/proving-0001-leaf-prover-from-proof.patch` on the pinned monorepo. It is one commit,
  written for an upstream PR, applied by `scripts/apply_patches.sh` and by the container image, and
  the service checks for it at startup rather than failing per job. Until it lands upstream,
  anybody building the binaries by hand has to run that script (or set `leaf_mode = "rerun"`).
* **No CI job yet.** `cargo test`, `cargo clippy`, `cargo fmt --check` and the client's `tsc` all
  pass locally but nothing runs them on push; a `wrapper` job in `.github/workflows/ci.yml` is a
  one-screen addition the orchestrator should make (the e2e test stays `--ignored` there: it needs
  64 GB).
* **Fold parallelism.** Reductions in the same tree layer are independent (R8-A3), but the pinned
  binary folds a whole batch in one process, so the only knob is `max_circuit_proofs` across
  batches. Splitting a layer needs the `Proof<QM31>` intermediate the binary does not expose
  (S4, plan B).

The verifier is an independent Cargo workspace and must be checked separately:

```sh
cargo +nightly-2026-01-15 build --manifest-path leaf-verify/Cargo.toml --release --locked
cargo +nightly-2026-01-15 test --manifest-path leaf-verify/Cargo.toml --locked
python3 scripts/check_leaf_proof.py --verifier leaf-verify/target/release/hellproof-leaf-verify existing-browser-proof.bin
```

The smoke script verifies an existing raw proof and its bzip2 encoding, then
requires a one-bit corruption to be rejected. It never generates a proof. The
2026-09-13 audit checked the real 4,343,870-byte WASM Blake proof (log21): accepted
in about 21 ms; corruption rejected with `Root mismatch`. This verifies the native
admission gate, not compatibility with the default log20 registry (D32).
