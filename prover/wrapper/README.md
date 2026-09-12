# `prover/wrapper` — the Hellproof wrapper service

The browser proves each **segment** of a game (`prover/wasm`, spike S2). One Starknet fact can only
carry **one** proof, and a game is 25–75 segments, so those segment proofs have to be folded into a
single **root proof** that the on-chain circuit verifier accepts. That fold needs 32.5 GB of RAM per
step (S4) and is not feasible in a browser — hence this service (PLAN §1 **A4**, Phase 3 task 4;
G0 decisions **D6** and **D7**; risk **R8**).

It owns no proving code. It drives the pinned `starkware-libs/proving` binaries
(**`cd7bc5f`**, R3-A1) as subprocesses with a configured circuit registry (S4, S4b):

```
segment proofs (browser)
   │  POST /v1/runs
   ▼
verify      hellproof-leaf-verify     ~0.02 s/segment   ← reject invalid submissions here (R8-A1)
   ▼
leaf        leaf-prover               ~24 s / 32.1 GB per leaf
   ▼
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
| `scripts/e2e_fixtures.sh` | produces browser-equivalent segment proofs for the end-to-end test |
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
  "program": "segment_stub",               // a program id the server has pinned
  "program_hash_function": "poseidon",     // optional; must match the program's configuration
  "solo": false,                           // true = wrap this game alone, immediately
  "segments": [
    {
      "index": 0,                          // 0-based, contiguous, in fold order
      "args": ["0x1", "0xfa"],             // the segment program's user arguments
      "output_preimage": [                 // [task_program_hash, task_output…]
        "0x6281af8c…", "0x1", "0x4cd2be…", "0xfa", "0x1"
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

**Proof formats.** `bincode_b64` is what `prover/wasm`'s `prove()` returns and the **only form the
Rust verifier can read**. The cairo-serde felt stream (`proof_to_felts`) is one-way at `cd7bc5f`:
`CairoProof` derives `CairoSerialize` but not `CairoDeserialize`, and the monorepo's own loader
panics with *"Deserialization from a Cairo-serialized proof is not supported"*
(`cairo_air::utils::deserialize_proof_from_file`). `cairo_serde_felts` is therefore accepted only
when the operator sets `require_verifiable_proof = false`, and such a run skips the R8-A1 gate.
`hellproof-leaf-verify` accepts both the raw bincode the browser sends and the bzip2-wrapped
`--proof-format extended-binary` files the monorepo writes.

**What the server checks before spending anything** (all of it in well under a second):

1. segment indices contiguous and ordered; args, preimage and outputs are felts;
2. the chain `h_in[i+1] == h_out[i]` across the run (PLAN Phase 3 task 3);
3. `output_preimage[0]` equals the pinned program hash of `program`, when one is configured, and
   the submission's `program_hash_function` is the one that program is configured for (`blake`
   vs `poseidon` give different program hashes, so it is part of a leaf's identity);
4. `public_outputs == blake2s(cairo0_encode(output_preimage))` — the two 128-bit output cells the
   leaf circuit will publish;
5. then, per segment, the **Rust verifier** on the proof itself, and that the proof's own output
   cells are exactly those from (4). This is what binds the submitted preimage — and therefore the
   leaf's contribution to the root digest — to the proof.

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

`status`: `verifying` → `rejected` | `queued` → `wrapping` → `done` | `failed`.

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
| `require_verifiable_proof` | `true` | refuse felt-only submissions (they cannot be verified) |
| `check_preimage_binding` | `true` | the bootloader's dumped preimage must equal the submitted one |
| `job_max_attempts` | `3` | leaf and fold jobs are retried; a verification verdict is never retried |
| `programs[].hash_function` | `blake` | `poseidon` in production (G0 D4); passed to the bootloader task input |
| `backend` | `subprocess` | `stub` disables proving entirely (tests, load runs) |

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
`batches/<id>/root.proof`).

Leaves are **content addressed**: `leaf_key = sha256(registry_hash, program_id, program_hash,
args)`. The same segment submitted twice — by the same player or by two players — is proven once,
and a registry change invalidates the whole cache instead of silently mixing circuits (R8-A3).

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

The pinned `leaf-prover` and `stwo_run_and_prove_recursive_tree` come from the monorepo
(`cargo build --release -p leaf-prover -p stwo-run-and-prove-recursive-tree` at `cd7bc5f`); the
container image in `infra/wrapper/` builds them for you.

## Tests

```bash
cargo test                       # 46 tests, no proving
cargo test --test load           # 20 concurrent runs on the stub backend
```

* `src/batching.rs` — the D6 policy, as pure functions.
* `src/recompose.rs` — the Rust twin of `spikes/s4/recursion_outputs`, checked against the four
  committed S4 runs (N = 1, 2, 3, 4): it reproduces both `program_output` and the
  `VerificationOutput.output_hash` the on-chain verifier printed. The fold job runs the same check
  on its own output and fails the batch on a mismatch.
* `tests/service.rs` — submission, batching, fold order, cache, idempotency, auth, validation,
  metrics, and two restart tests.
* `tests/pipeline_e2e.rs` — the **real** pipeline (ignored by default), see its module docs.

## Known gaps

* **The wrapper re-proves the segment.** `leaf-prover` takes a *program and its input*, runs it and
  proves it, then proves the verifier circuit around that proof. It has no entry point that accepts
  an already-made Cairo proof, so the browser's proof is used as the admission gate and the server
  redoes the Cairo proof (~2 s of the ~60 s leaf) before the circuit proof. A genuinely "proof-only"
  API (A4) needs a small upstream addition — everything in `prove_leaf` after `prove_cairo` only
  needs `(proof, program_felts, output_hash, registry)` — tracked as an open question for P3.5.
* **Fold parallelism.** Reductions in the same tree layer are independent (R8-A3), but the pinned
  binary folds a whole batch in one process, so the only knob is `max_circuit_proofs` across
  batches. Splitting a layer needs the `Proof<QM31>` intermediate the binary does not expose
  (S4, plan B).
