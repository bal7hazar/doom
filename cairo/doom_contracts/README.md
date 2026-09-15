# doom_contracts — the on-chain verifier workspace

**Does**: verifies a Stwo *circuit* proof (the root of the recursive tree, ~96 k felts) on
Starknet in 5 transactions (**1.54e9 L2 gas per fact** on devnet after P4.1, every transaction
under 40 % of the invoke cap), with every proof section passed as **calldata** and only a
32-byte checkpoint hash in storage between transactions, then registers the fact
`poseidon(circuit_hash ‖ output_hash)` and answers `is_valid(fact)`. Design, measurements and
the soundness argument: [`docs/design/onchain-verifier.md`](../../docs/design/onchain-verifier.md).
The vendored verifier carries a documented optimization patch series (`vendor/patches/`); the
optimized phases are tested against the **unmodified** verifier (`vendor/stwo_cairo_verifier_ref`)
on the real root proofs, accepted and tampered.

It also holds the **consumer** side: `DoomRuns` recomposes the batch's root `output_hash` from
the ten public felts of each segment, requires the fact to be registered, and records one game
per member — validation rules, gas and open points in
[`docs/design/doomruns.md`](../../docs/design/doomruns.md). Since D35 (**open prover**) it
also holds the players' **commitments**: a player publishes a played game's packed input log
with a bounty in escrow, any address proves and submits it and is paid — see
[Open prover](#open-prover-d35-commitments-and-bounties) below.

The two halves have been driven **together** on devnet (P4.2b, `doomruns.md` §10): two batches
proved over `spikes/s4/programs/segment_stub10` (ten-felt leaves) verified by the router in 5
transactions each, then consumed by a `DoomRuns` whose `verifier_router` is that router — no
`MockFactRegistry` anywhere in the path. `tools/e2e_10felt_drive.py`,
`results/e2e_10felt_receipts.json`: **3.83e9** L2 gas for one batch's verification plus its
`submit_batch`, of which the consumer is **0.44 %**.

## Layout

| Path | What |
|---|---|
| `vendor/stwo_cairo_verifier/` | the verifier crates of `starkware-libs/proving` pinned at **`cd7bc5f`** (`VENDOR.md`) + the visibility-only patch + the **P4.1 patch series** (`vendor/patches/`: lazily-reduced FRI folds and `fri_answers`, one batch inversion each; per-patch invariant and equivalence argument in its README, `apply.sh`); `circuit_air/src/{multiverifier_consts,preprocessed_columns}.cairo` are **generated** from a registry (`tools/gen_multiverifier_consts.py`) |
| `vendor/stwo_cairo_verifier_ref/` | the **unmodified** vendored verifier (upstream + visibility patch) under `*_ref` package names (`tools/vendor_ref.sh`): the reference of the equivalence tests and the measurement-only monolithic class |
| `crates/stwo_circuit_phases/` | library: the phase machine (`machine.cairo`: `begin` / `merkle` / `answers` / `fri_layers`, sections arrive packed), the typed section decoder (`decode.cairo`: 2.1 range checks per value), the packed transport (`pack.cairo`), the section splitter used by tests (`sections.cairo`); tests = the unmodified monolithic reference, **equivalence with it** (`fri_answers` row by row, accepted proofs = the selected golden + the two proved ten-felt batches, one tampered felt per proof section rejected by both), end-to-end phases with checkpoint round-trips, tamper rejections at the phase level, cost probes, packing benchmarks |
| `crates/recursion_outputs/` | library: the recursive tree's output hashing recomputed from the leaves (blake2s leaf output, two-to-one fold with odd carry and single-leaf self-fold, `VerificationOutput.output_hash`); port of `spikes/s4/recursion_outputs`, tests = upstream goldens + the real S4 root proofs + the real **ten-felt** roots of P4.2b; `fixtures/B2_doom`, `fixtures/B2-1_doom` = those two proved batches (preimages, packed/program/verifier output, the root proof itself gzipped) |
| `crates/doom_runs/` | contracts: `DoomRuns` (version table, run records, leaderboards, replay publication, and the D35 commitments: escrowed bounties, open submission, expiry) and `MockFactRegistry` (tests/drives only); tests = recomposition against the Python model, the fact gate, every member-level rejection, replay data, boards, governance, `test_commitments.cairo` (commit, prove by a third party, settle, reclaim, with a `MockERC20` fee token defined in the tests), and `test_real_root.cairo` on the proved ten-felt batches; `fixtures/*.json` = those batches as a client receives them (leaves, members, logs, fact, run ids) |
| `crates/doom_contracts/` | contracts: `StwoPhasesBegin` / `StwoPhasesMerkle` / `StwoPhasesFri` (stateless library classes), `StwoCircuitRouter` (checkpoints, sequencing, facts), `StwoCircuitMonolithic` (measurement only); tests = the router driven over a real proof + rejections |
| `fixtures/` | real root proofs as one-felt-per-line text (gzipped; `sh fixtures/unpack.sh`): `n4_root_proof` (S4, registry `doom`), `n2_fold4min_root_proof` (S4b, registry `doom_fold4_min`); `selected.txt` picks the one the tests use (1 / 2) |
| `tools/` | `emit_calldata.py` (proof → per-transaction packed calldata), `devnet_drive.py` (declare, deploy, drive, receipts, pricing), `trace_tx.py` (per-call gas of a tx), `devnet_probe.py` (transport calibration), `gen_multiverifier_consts.py`, `check_registry.sh` (both vendor copies), `vendor_ref.sh` (rebuilds the pristine `_ref` copy), `vendor_patches.sh` (regenerates the patch files from git), `doomruns_model.py` (independent Python model + fixture generator), `doomruns_drive.py` (consumer drive), `real_batch.py` (loads and checks a proved ten-felt batch, emits its fixtures), `e2e_10felt_drive.py` (the whole path: router verifies the root proof, `DoomRuns` consumes the fact it registered) |
| `results/` | `p41_receipts.json` (**P4.1**: the 5-tx drive with the optimized classes, 1.54e9, class hashes in `p41_receipts_deployment.json`); P4.0: receipts of the 5-tx and 6-tx drives, deployment, transport probe; `doomruns_receipts.json` (consumer drive, N = 1…480), `e2e_10felt_receipts.json` (P4.2b: verification + consumption of two real ten-felt batches, 7.64e9 L2 gas with the P4.0 classes) |

## Toolchain

`.tool-versions`: **scarb 2.18.0** (required by the vendored verifier), **starknet-foundry
0.61.0** (0.57.0 cannot run the Sierra 1.8 test artifacts; snforge also needs a
`universal-sierra-compiler` that understands Sierra 1.8 — 2.10.0 does, 2.6.0 does not),
starknet-devnet 0.10.0 for the drives. This workspace is deliberately not a member of `cairo/Scarb.toml`: contracts need gas
enabled while `doom_run` needs it disabled, and Scarb honours one `[cairo]` table per workspace.
snforge is configured with `tracked_resource = "cairo-steps"`: that is what devnet/blockifier
0.14.4 bills (the default sierra-gas mode understates by 1.4–3.5×).

```bash
sh fixtures/unpack.sh                         # S4 goldens + the two ten-felt root proofs
scarb build                                   # audited libfuncs; class sizes in the design doc §7
(cd crates/stwo_circuit_phases && snforge test)   # 67: reference, equivalence + tampers, phases, cost probes
(cd crates/doom_contracts && snforge test)
(cd crates/recursion_outputs && snforge test) # 20
(cd crates/doom_runs && snforge test)         # 81 (53 + 28 for the D35 commitments)
tools/check_registry.sh doom_fold4_min        # conformance of regenerated constants (R3-A5)
python3 tools/real_batch.py crates/recursion_outputs/fixtures/B2-1_doom   # check a proved batch
```

## Open prover (D35): commitments and bounties

Proving is not the player's job. The player's client plays, then **commits** the game to
`DoomRuns` with its whole packed input log (7 tics per felt, ~900 felts for 3 minutes) and a
bounty in escrow; **any address** executes the log, proves the segments, folds them, has the
router register the fact and submits the batch — and is paid the bounty. No new privileged
role: the owner still only adds versions and genesis states; the contract cannot cancel,
seize or redirect an escrow.

```cairo
// player (caller): publishes the log, escrows `bounty` of the fee token (allowance needed),
// returns commitment_id = poseidon('HP.COMMIT', version_id, level_id, player, commit_log(packed))
fn commit_run(version_id: u32, level_id: u32, packed: Span<felt252>, tics: u32, bounty: u256) -> felt252;
// player, once `expires_at` (= created_block + expiry_blocks) is reached and still unproved
fn reclaim(commitment_id: felt252);

fn get_commitment(commitment_id: felt252) -> Commitment;
fn commitment_of(version_id: u32, level_id: u32, player: ContractAddress, inputs_commitment: felt252) -> Commitment;
fn commitment_count() -> u32;                                          // size of the append-only index
fn pending_commitments(cursor: u32, limit: u32) -> (Array<felt252>, u32); // ids still PENDING in [cursor, cursor+limit), next cursor
fn fee_token() -> ContractAddress;  fn expiry_blocks() -> u64;

// constructor(owner, fee_token: ContractAddress, expiry_blocks: u64)   -- expiry_blocks in 1 ..= 2^40
```

`Commitment = {player, version_id, level_id, genesis, inputs_commitment, tics, bounty: u256,
created_block, expires_at, status, run_id, prover}`, `status ∈ {0 NONE, 1 PENDING, 2 PROVED,
3 RECLAIMED}`. `commit_run` requires the level to be pinned, `tics != 0` and
`packed.len() == ceil(tics / 7)`, and refuses an id that is `PENDING` or `PROVED` (a
`RECLAIMED` one may be committed again: new escrow, new expiry, appended to the index again).

Events: `RunCommitted {commitment_id*, player*, version_id*, level_id, genesis,
inputs_commitment, tics, bounty, expires_at, n_chunks}` followed in the same transaction by
`n_chunks` × `RunLog {commitment_id*, chunk, offset, packed: Span<felt252>}` of at most
**256 felts** each (Starknet caps an event's data at 300 felts; concatenate the chunks in
`chunk` order to rebuild the log — the log is **not** stored, the events are its only copy);
`CommitmentProved {commitment_id*, run_id*, prover*, player, bounty}`;
`CommitmentReclaimed {commitment_id*, player*, bounty}` (`*` = key). The same rule now applies
to `Replay`: a segment log longer than 256 felts is published as several `Replay` events, each
carrying the tic sub-range its felts encode; a log that fits is one event, exactly as before.

**Settlement.** `submit_batch` / `register_member` are unchanged and callable by anyone
(`Member.player` is a field, not the caller — D20). When an accepted member's run is a
pending commitment of its player — same version, level and player (all in the id), same
`tics`, same genesis, and a **run-level** input commitment equal to the committed
`commit_log(packed)` — the commitment becomes `PROVED`, bound to the `run_id`, and the bounty
is transferred to the **caller**. The run-level commitment is derived from what the submitter
sent: for a one-segment run it is the leaf's own `inputs_commitment`; for several segments it
is the fold of the concatenated `replay` logs (which `check_logs` has already verified against
each leaf, D13), provided every non-final segment spans a multiple of 7 tics so that the
segment packing is a slice of the run packing. A multi-segment submission **without replay
data** is recorded as a run but settles nothing — a prover node must send the logs to be paid
(~ the same calldata as the commitment). A member with no matching commitment is recorded
exactly as before. Checks-effects-interactions throughout: the run record, the commitment
status and the events are written before any token call; the fee token is fixed at
deployment; a commitment settles once (`PROVED`), and a run id registers once (R10-A1), so a
fact/run can settle at most one commitment.

Known limits, deliberate: the player cannot cancel before expiry (a prover's work in flight
cannot be pulled from under it), and a player who sees a prover's submission could try to
submit the same calldata first to keep the bounty — sequencer ordering decides, as in any
open bounty market. Cost of `commit_run` for a 3-minute log (900 felts, with a bounty):
**76 868 steps, 905 poseidon, 3 872 range_check, 5 events**, ≈ 16.2 M L2 gas as snforge
estimates it in `cairo-steps` mode — the difference between the two `cost_probe_*` tests
(`snforge test cost_probe --detailed-resources`).

## Transaction flow (client side)

```
python3 tools/emit_calldata.py root.proof --out calls.json            # --fri-split 2: 5 txs (recommended)
tx1 begin(proof_id, head, head_n, payload, lens, trees=[0,1])      -> state S1 (228 felts)   302 M
tx2 merkle(proof_id, S1, payload, lens, trees=[2,3])               -> S2                     234 M
tx3 answers(proof_id, S2, payload=[sampled, qv0..qv3], lens)       -> S3 (576 felts)         466 M
tx4 fri(proof_id, S3, layers 0-1, n_values)                        -> S4                     295 M
tx5 fri(proof_id, S4, layers 2-5, n_values)                        -> fact registered        243 M
```

Each transaction's calldata is ≤ 4 627 felts; the state returned by a transaction is the
`state` argument of the next (`tools/devnet_drive.py` threads it from the trace's retdata). The
router forwards the packed sections to the phase classes, which decode them (P4.1); the calldata
format is the P4.0 one, so the client emitter is unchanged.
