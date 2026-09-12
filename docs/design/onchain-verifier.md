# On-chain verifier — resumable circuit verification with proof sections as calldata (P4.0)

> Design + measured prototype for RISKS.md **R7-A6** (decisions D5/D6), on the verifier pinned at
> `proving@cd7bc5f`. Everything quantified below is **measured** on the S4 root proof
> (`spikes/s4/results/N4_doom`, 96 033 felts) with the code under `cairo/doom_contracts/`, in
> snforge (`--tracked-resource cairo-steps`, see §7) and on **starknet-devnet 0.10.0**
> (Starknet 0.14.4), 2026-09-12. No transaction was sent to a public network.

## 0. Verdict

| Target (R7-A6) | Result |
|---|---|
| ≤ 6 invokes per fact | **5 transactions** (or 6 with every tx ≤ 84 % of the cap) |
| each tx ≤ 90 % of the 1.21e9 L2-gas invoke cap | 5-tx plan: worst tx **90.4 %** (fri1); 6-tx plan: worst **84.0 %** |
| calldata ≤ ~4 990 felts per tx | worst tx **4 627 felts** (begin) |
| no proof data in storage | **0 proof felts stored**: 1 storage slot per (caller, proof_id), 3–5 writes per tx |
| ≤ 2.5e9 L2 gas per fact | **3.81e9** (5 tx) / 3.82e9 (6 tx) — **missed**, see §8: 78 % is verifier compute; the transport is 0.3e9 |
| cost per fact | **116 STRK ≈ 3.35 $** at the S5 mainnet price snapshot (30.5 gFri, 0.0288 $/STRK); **11.4 STRK ≈ 0.33 $** at the 3 gFri floor. Versus S5's extrapolation of the storage-staged design (≈ 250 STRK / 7.2 $ and 9 tx): **2.15× cheaper**, half the transactions |
| declares (once) | 4 classes, 7.83e9 L2 gas ≈ 238 STRK at the snapshot price |

The prototype verifies the real S4 root proof **end to end on devnet** (fact registered, `is_valid`
= true), the same for the `doom_fold4_min` registry with regenerated constants (S4b). The
remaining gap to 2.5e9 is not in the transport any more; it is the naive (non-opcode) QM31
arithmetic of the vendored FRI code (§8, levers).

## 1. What is verified and where it costs

`stwo_circuit_verifier::main` (vendored, `cairo/doom_contracts/vendor/stwo_cairo_verifier`) is
`verify_circuit` → `verify` → `verify_values`; the transcript-relevant steps and the
self-authenticating ones are interleaved:

```
begin ──────── claim checks, channel: salt, PCS config, preprocessed root, circuit_hash, claim,
               trace root, interaction PoW, lookup elements draw + logup sum, interaction claim,
               interaction root, composition coeff, composition root, OODS point,
               composition eval (11 components) + OODS check, mix sampled values,
               FRI commit (6 layer roots + alphas + last-layer poly), queries PoW, 70 queries
merkle ─────── 4 Merkle decommitments (preprocessed, trace, interaction, composition)
answers ────── fri_answers: OODS quotients at the 70 query rows -> first-layer evaluations
fri_layers ─── FRI decommit: first (circle) layer + 5 inner layers, fold_step 4, last-layer check
```

Per-stage cost map (snforge, cairo-steps mode = what devnet bills; vendored verifier compiled
**without** the qm31 opcode, gas enabled, audited libfuncs):

| Stage | VM steps | L2 gas (steps×100 + builtins) | devnet library call |
|---|---:|---:|---:|
| `begin` (whole transcript, incl. OODS eval) | 313 k | 50.6 M | 51.1 M |
| Merkle tree 0 / 1 / 2 / 3 | 381 k / 565 k / 666 k / 278 k | 67 / 95 / 111 / 51 M | 163.7 M (trees 0+1), 163.3 M (2+3) |
| `answers` (`fri_answers`) | 4.00 M | 675.7 M | 677.9 M |
| FRI first layer / inner 0 / 1 / 2 / 3 / 4 | 1.91 M / 1.83 M / 1.68 M / 1.48 M / 350 k / 21 k | 487 / 474 / 410 / 390 / 92 / 5 M | 931.2 M (layers 0-1), 906.1 M (2-5) |
| **compute total** | **17.5 M** | **≈ 2.93 e9** | **2.89 e9** |
| monolithic reference (`verify_circuit` on the whole stream) | 28.7 M | 2.87 e9 (incl. 10 M-step deserialization of 96 k felts) | class does not fit calldata |

Reading: the transcript (`begin`) is negligible; the two expensive stages are the OODS
quotient accumulation (`fri_answers`, 23 %) and above all the **FRI decommit walk (63 %)**:
each of the 6 layers folds 70 subsets of 16 evaluations with `fold_step = 4`, and every QM31
multiplication/inverse is emulated with `bounded_int` arithmetic (the qm31 opcodes are not in
`audited.json`). With the opcode the same proof costs 5.3 M steps (S4).

## 2. Proof anatomy and transport

`root.proof` = cairo-serde `CircuitProof`, 96 033 felts, all u32 values except the two u64 PoW
nonces (`tools/emit_calldata.py`):

| Section | felts | packed slots (7 u32/felt) | transport class |
|---|---:|---:|---|
| head = claim ‖ interaction PoW ‖ interaction claim ‖ PCS config ‖ 4 roots ‖ sampled values ‖ queries PoW ‖ FRI head (6 layer roots + last-layer poly) ‖ salt | 1 949 | 279 (escaped) | **transcript-bound**: every felt is mixed into the channel by `begin` |
| queried values, per tree 0/1/2/3 | 3 151 / 7 981 / 10 641 / 561 | 451 / 1 141 / 1 521 / 81 | self-authenticating (Merkle) then **digest-bound** for `answers` |
| Merkle hash witnesses, per tree | 9 601 ×4 | 1 372 ×4 | self-authenticating |
| FRI layer proofs 0..5 (witness evals + hash witness + root) | 11 570 / 9 330 / 7 050 / 4 654 / 778 / 10 | 1 653 / 1 333 / 1 008 / 665 / 112 / 2 | self-authenticating against the transcript-bound roots |
| total | 96 033 | 13 719 (+1 with the two escapes) | |

Packing: 7 little-endian u32 limbs per felt252 (`stwo_circuit_phases::pack`). Two encodings:
the **fast path** (`unpack_u32`, one u32 per limb, no escapes — every section but the head:
`deconstruct_f252` + 7 appends per slot) and the **escaped** one for the head (a `0xFFFFFFFF`
limb introduces a (low, high) u64 pair; a plain `0xFFFFFFFF` is escaped too — the first version
did not, a real 2⁻³² collision bug). Each section is packed independently (own padded last
slot) so the router can slice the payload by `n_slots(len)` without a second pass.

Measured transport cost on devnet (`tools/devnet_probe.py`, `results/devnet_probe.json`):
calldata **5 120 gas/felt** + validate/fee ≈ 6.7 k per felt all-in; `unpack_u32` **35.2 k gas per
slot** (5.0 k per value; the first u256/u128-divmod version cost 82 k/slot); the library-call
copy of the unpacked span ≈ 1.9 k per felt. Per proof value: 0.73 k (calldata) + 5.0 k (unpack)
+ 1.9 k (copy) ≈ 7.7 k, versus 7.0 k if the same value were sent unpacked — packing costs ~10 %
more gas than raw calldata but divides the transaction count by 7 (96 k felts would need 20
invokes raw). Total transport ≈ 0.3e9 per fact (the "61× cheaper than storage" of S5 §8.5,
confirmed: the storage-staged variant was extrapolated at 4.3e9 for staging alone).

## 3. Phase design (measured)

Rules: every section arrives in the transaction that consumes it; the head is the only
transcript input and is consumed whole by `begin`; the channel is never checkpointed (it is not
needed after the query sampling); the state carried between transactions is a few hundred felts
echoed by the caller and pinned by a Poseidon hash in storage.

**5-transaction plan** (`tools/emit_calldata.py --fri-split 2`, `results/devnet_receipts.json`):

| # | entrypoint | sections | calldata felts | echo felts | L2 gas (devnet) | % of 1.21e9 | of which library call(s) | router (unpack + slicing + hash + storage) | fee @30.5 gFri |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|
| 1 | `begin` | head (279 slots) + trees 0, 1 (4 334 slots) | 4 627 | 0 | **459 365 920** | 38.0 % | 51.1 M + 163.7 M | 219 M | 14.0 STRK |
| 2 | `merkle` | trees 2, 3 (4 346 slots) | 4 585 | 228 | **390 986 880** | 32.3 % | 163.3 M | 203 M | 11.9 |
| 3 | `answers` | sampled values + queried values of the 4 trees (3 448 slots) | 3 685 | 228 | **861 298 880** | 71.2 % | 677.9 M | 163 M | 26.2 |
| 4 | `fri` | FRI layers 0, 1 (2 986 slots) | 3 566 | 576 | **1 093 329 600** | **90.4 %** | 931.2 M | 142 M | 33.3 |
| 5 | `fri` | FRI layers 2..5 (1 785 slots), last-layer check, fact | 2 365 | 576 | **1 004 813 200** | 83.0 % | 906.1 M | 85 M | 30.6 |
| | **total** | 13 720 slots | | | **3 809 794 480** | | 2.89 e9 | 0.81 e9 | **116.1 STRK** |

**6-transaction plan** (`--fri-split 1,3`, `results/devnet_receipts_6tx.json`): same first three
transactions, then FRI layers {0} 565 664 640 (46.8 %), {1, 2} 1 015 987 200 (84.0 %), {3, 4, 5}
527 989 760 (43.6 %); total 3 821 293 280 (+0.3 %), 116.7 STRK. This is the plan that respects
the internal 90 % rule (R7-A5) today; the 5-tx plan is 9.6 % under the hard cap. The client
chooses the cut at emission time (the walk is chunkable at any layer boundary and the emitter
asserts the calldata cap), so a proof whose FRI section is a few percent larger simply gets the
6-tx plan.

Why not fewer: 13.7 k slots + echoes need ≥ 4 transactions at 4 990 felts, and the section
granularity (the four 1 372-slot hash witnesses, the 1 653-slot first FRI layer) leaves no
4-tx packing; the FRI compute (1.84e9 on devnet) needs ≥ 2 transactions on its own. Merging
`answers` with the first FRI layer would need 5 101 slots.

## 4. Checkpoint layout

Storage holds, per `(caller, proof_id)`, one `Checkpoint { tag: u8, state_hash: felt252 }`
(1 slot). The state itself is returned by each transaction and **echoed as calldata** by the
next one; the router checks `poseidon(state) == state_hash` and the tag. Nothing else is stored:
this is the "checkpoint in storage" of the brief at 1 write instead of 200–600 (≈ 495 k gas
each).

`stwo_circuit_phases::machine` states (cairo-serde):

| State | tag | felts (70 queries) | contents |
|---|---|---:|---|
| `Params` (inside both) | — | ≈ 210 | `circuit_hash` [u32;8], `output_hash` [u32;8], 4 tree roots (32), `d_sampled` (poseidon of the sampled-values felts), OODS point (8), `fri_answers` random coeff (4), 70 query positions, FRI first layer + 5 inner layers `{root, alpha, log_degree_bound, fold_step}` (6 × 14), last-layer value (4) |
| `MerkleState` | 1 | **228** | `Params` + `trees_done` bitmask + `d_queried[4]` (poseidon of each tree's queried-values felts, filled by `merkle`) |
| `FriState` | 2 | **576** | `Params` + `layers_done` + current layer query positions (≤ 70) + `layer_log_domain_size` + carried evaluations (≤ 70 QM31 = 280 felts) |
| done | 3 | 1 | the registered fact |

The FRI alphas, the OODS point and the random coefficient are transcript outputs of `begin`;
carrying them (instead of re-deriving from a checkpointed channel) is what lets the later phases
run without the channel at all.

## 5. Binding and replay protections

Section classes and how each is bound to the transcript (nothing is authenticated by storage):

1. **Head** — consumed by `begin` only; every felt is mixed into the Fiat–Shamir channel exactly
   as in the monolithic verifier (same order, same bytes; `machine.cairo` mirrors
   `verify_circuit`/`verify`/`verify_values` line by line up to the query sampling). The queries,
   alphas and OODS point that come out of it are therefore the monolithic verifier's.
2. **Merkle witnesses / queried values** — self-authenticating: verified against the checkpointed
   roots at the checkpointed positions; a tampered value fails `Root Mismatch` (tested).
3. **Queried values re-supplied to `answers`** — bound by `d_queried[i]` = poseidon(felts) taken
   by `merkle` after the tree verified; `answers` requires all 4 `trees_done` bits and the 4
   digests (tests: tampered, swapped trees, incomplete Merkle phase).
4. **Sampled values re-supplied to `answers`** — bound by `d_sampled` taken in `begin` over the
   raw section felts (also transcript-bound). Tested.
5. **FRI layers** — each chunk's layer roots must equal the transcript-bound roots in the state
   (`fri: first/inner commitment`); witnesses are Merkle-verified; the carried evaluations are
   consumed by the next layer's Merkle check, so a forged echo is caught even before the
   last-layer check (test `fri_rejects_tampered_carried_evals`). Layers are consumed strictly in
   order (`layers_done`); the fact is registered only when `layers_done == 6` and every carried
   evaluation equals the last-layer coefficient.

Router (`StwoCircuitRouter`):

- **proof_id uniqueness**: `begin` requires a free slot (`router: proof id in use`); every step
  overwrites the slot, so a phase can never re-run against a stale state and a finished proof id
  stays `DONE` forever (no re-registration, no reuse).
- **caller binding**: the slot key is `(get_caller_address(), proof_id)`; another account has its
  own (empty) slot and cannot continue, front-run or corrupt someone else's sequence (tested).
  Griefing by proof-id squatting is impossible for the same reason (ids are per caller).
- **phase sequencing**: tags `FREE → MERKLE → (MERKLE)* → FRI → (FRI)* → DONE`; `answers`
  requires the Merkle bitmask to be complete (machine-level), `fri` requires the FRI tag; a
  replayed Merkle transaction is rejected by the write-once bits (`merkle: tree already done`),
  a replayed FRI chunk by the root check of the next layer.
- **state echo**: `poseidon(state)` in storage; a tampered echo is rejected before any compute
  (`router: bad state echo`).
- An abandoned sequence costs nothing to anyone else and can be restarted under a new proof id.

## 6. Fact, consumer interface, multi-run facts, versioning

**Fact** = `poseidon(circuit_hash[0..8] ‖ output_hash[0..8])` over the 16 u32 words, where
`circuit_hash = blake2s(log_blowup ‖ component_log_sizes ‖ preprocessed_root)` is the
multiverifier's hash recomputed from the proof and `output_hash = blake2s(circuit_hash ‖ 8 output
words)` is exactly `VerificationOutput.output_hash` of the monolithic verifier (S4). Including
`circuit_hash` explicitly (it is already inside `output_hash`) lets a consumer reject a proof of a
different circuit without recomputing blake2s. `is_valid(fact) -> bool` is the consumer interface;
`FactRegistered { fact, caller, proof_id }` the event. On the S4 fixture the fact is
`0x6b07de2a…7184be` (devnet). The consumer computes the same fact from its own data:
`multiverifier_hash` (pinned, registry `doom_fold4_min` once switched: `02b34360…9f7fac34`) and
`output_hash` recomputed with `spikes/s4/recursion_outputs::root_output_hash` from the leaf
preimages.

**Consumer (`DoomRuns`, D6 / D13–D14)** — one fact aggregates M games (the wrapper folds all
their segments in one tree). `submit_runs(fact_inputs)` receives, per leaf, the preimage
`[program_hash, out_0..out_9]` (10-felt segment output: `version=1, h_in, h_out, tic_start,
tic_end, status, inputs_commitment, kills, items, secrets`) and the game → leaves index:

1. recompose `output_hash` with `fold_tree` over the leaf preimages in tree order (N leaves,
   odd carry, self-fold for N = 1) and `verification_output_hash(mv_hash, root)`; ask the
   registry `is_valid(poseidon(mv_hash ‖ output_hash))`;
2. per leaf: `preimage[0] == program_hash` of the pinned version, computed with the pinned
   `program_hash_function` (poseidon per D-S4b: the same executable hashed with blake gives a
   different value, so the version table pins the *pair*), `version == 1`, `status != ABORT (3)`;
3. per game: `h_in[0] == genesis`, `h_out[i] == h_in[i+1]`, `tic_end[i] == tic_start[i+1]`,
   `status == EXIT (2)` on the last segment (RUNNING/DEAD accepted only as non-final),
   `inputs_commitment` per segment checked against the published packed input log
   (`cairo/crates/segment/bench/reference.py` is the model), uniqueness by the run's input-log
   hash (R10-A1), then the `Run` record + `Replay` event.

`recursion_outputs` is generic over the preimage length; its S4 fixtures assumed 4 outputs and
need regenerating for the 10-felt width (P4.1). Recomposition cost is ≈ 1.4 k steps per leaf
(S4) — negligible next to the 3.8e9 of the fact.

**Versioning / freezing** — a router pins its three phase class hashes in the constructor and
has no upgrade path: one deployment = one verifier version `(verifier commit, registry
constants)`; `phase_classes()` exposes the pins. `DoomRuns` keeps the governed-then-frozen table
`{program_hash, program_hash_function, leaf_circuit_hash, multiverifier_circuit_hash,
registry_address}` per season (R3-A6): a new verifier version is a new router + a new table
entry, never a mutation. The registry-side "routes" pattern of modeofO (`add_route`/
`freeze_routes`) is not needed while the router is itself the fact store; if several routers
must feed one fact store later, the shared registry keeps that pattern.

**Registry constants** — `COMPONENT_LOG_SIZES`, the preprocessed column layout and the PCS
config are compile-time constants of the vendored verifier.
`tools/gen_multiverifier_consts.py --registry <name>` regenerates
`multiverifier_consts.cairo` and `preprocessed_columns.cairo` from
`spikes/s4/registry/<name>/registry.json` (port of upstream `cairo_consts_test.rs`, same stable
size-sort of the column layout; reproduces the upstream `doom` constants byte for byte) and
stamps the registry name and multiverifier hash in the header. `tools/check_registry.sh
doom_fold4_min` regenerates, selects the S4b fixture (`fixtures/selected.txt` = 2) and runs the
monolithic, phase and router suites: **passes** (the N = 2 `doom_fold4_min` root proof, 96 509
felts, verifies with the new constants: monolithic 1.55e9 sierra gas, begin calldata 4 643
felts). The committed default stays `doom` (the S4 measurement proofs); switching production to
`doom_fold4_min` is one script run + redeclare (≈ 240 STRK).

## 7. Class sizes and the gas oracle

| Class | Sierra felts (cap 81 920) | class JSON bytes (cap 4 089 446) | CASM felts (cap 81 920) | declare L2 gas |
|---|---:|---:|---:|---:|
| `StwoPhasesBegin` (transcript + OODS eval) | 38 402 (47 %) | 2 663 781 (65 %) | 62 403 (76 %) | 4.13e9 (126 STRK) |
| `StwoPhasesMerkle` (Merkle + `fri_answers`) | 13 432 (16 %) | 1 425 507 (35 %) | 29 907 (37 %) | 1.78e9 (54 STRK) |
| `StwoPhasesFri` (FRI walk) | 11 191 (14 %) | 1 153 468 (28 %) | 22 765 (28 %) | 1.39e9 (42 STRK) |
| `StwoCircuitRouter` (with the two calibration probes) | 4 165 (5 %) | 435 541 (11 %) | 9 670 (12 %) | 0.53e9 (16 STRK) |
| monolithic `verify_circuit` (measurement only) | 48 401 (59 %) | 3 847 068 (**94 %**) | 78 641 (**96 %**) | — |
| begin + merkle + answers in one class | 48 525 | 3 850 483 | **88 087 (107 %)** | rejected → 3 classes |

The whole vendored verifier compiles under the `audited` libfunc allowlist (no qm31 opcode) and
fits one class only barely; **library-class splitting is required** once checkpoint serde is
added, and 3 stateless classes + 1 router is the shape. The vendored crate needed a
visibility-only patch (`vendor/stwo_cairo_verifier/hellproof-visibility.patch`, 7 files, `pub`
additions only) to split `verify_circuit` without forking its logic.

**Gas oracle.** snforge's default `sierra-gas` accounting understated devnet by 1.4× (transcript)
to 2.1× (FRI) and 3.5× (unpack); with `--tracked-resource cairo-steps` (now the workspace
default) the library calls match the devnet receipts within 3 %: devnet 0.10 / blockifier 0.14.4
bills these classes by VM steps + builtins. Rule: size phases with cairo-steps snforge numbers
× 1.05, then confirm on devnet (`tools/devnet_drive.py`, R3-A7).

## 8. Costs, levers, what P4.1 should do

Where the 3.81e9 goes: FRI walk 1.84e9 (48 %), `fri_answers` 0.68e9 (18 %), Merkle 0.33e9
(9 %), transcript 0.05e9, transport (calldata + unpack + copies + storage + envelopes) 0.81e9
(21 %), state echoes/hashing < 0.02e9.

Levers, in order of expected value:

1. **FRI fold arithmetic** (1.84e9): the vendored `fold_coset`/`fold_line`/`fold_circle` do one
   M31 inverse per fold (a 31-step exponentiation) and naive QM31 products; batch-inverting the
   twiddles per layer, precomputing the per-layer x-coordinates once instead of per subset, and
   using the packed-unreduced QM31 accumulators already present in `quotients.cairo` could plausibly
   halve the FRI phase. This is the lever that brings the fact under 2.5e9; it is a vendored-code
   optimization to carry as a documented patch (or upstream) — not started here.
2. **qm31 opcode in `audited.json`** (watch item R3-A9): the same proof costs 5.3 M steps → ≈
   0.6e9 compute; everything here survives (the phases only get cheaper and fewer).
3. **`fri_answers`** (0.68e9): 70 rows × 319 columns; the accumulation is already packed-unreduced;
   fewer columns (registry) or batching across rows are the only gains.
4. **Transport** (0.81e9): unpack at 5 k gas per value is 2/3 of it; a limb-to-felt path that
   skips the intermediate array, or letting the Merkle/FRI code consume u32 limbs directly, would
   cut it by half; sending queried values 8 M31 per felt would save ~400 slots. Second order.
5. **Fewer transactions** is not a gas lever (each tx envelope ≈ 1 M): 5 vs 6 differs by 0.3 %.

Realistic P4.1 outcome with lever 1 only: ≈ 2.8e9 and 4–5 transactions; with the opcode, ≈ 1.0e9
and 2–3 transactions.

## 9. Sequencing UX

- One transaction = one signature; the client sends them in order and waits for each receipt
  (the next one needs the returned state as its echo). A multicall would not help: the whole
  `__execute__` shares the 1.21e9 per-invoke cap, so two phases cannot share a transaction.
- Estimation: `starknet_simulateTransactions` on the ordered array (S5, exact to 0.02 %), bounds
  `l2_gas` ×1.15 / `l1_data_gas` ×1.3, never sncast's global ×1.5 (fri1 ×1.5 = 1.64e9 > cap →
  rejected). Bounds used by the drive: 1.15e9 flat (accepted by the sequencer, the receipt bills
  the actual use).
- Failure handling: a reverted phase (e.g. under-provisioned gas, as happened in the first drive)
  leaves the slot untouched; the client resends the same phase. A wrong section is rejected
  deterministically before any state change.
- Sponsoring (R7-A4) is orthogonal: the paymaster signs the same 5–6 calls.
- Cost display: 116 STRK / 3.35 $ today per fact; per game with M = 8 aggregated games (D6):
  ≈ 15 STRK / 0.42 $, ≈ 0.04 $ at the price floor.

## 10. Blockers and open points

1. **2.5e9 target missed** (3.81e9): entirely a compute problem of the FRI walk under naive QM31
   arithmetic; the transport design is done and cheap (§8 lever 1 is the next step).
2. **fri1 at 90.4 % of the cap in the 5-tx plan**: use the 6-tx plan (84 %) until lever 1 lands;
   the emitter switch is `--fri-split 1,3`.
3. **Account class**: measured with devnet's predeployed OZ-type account; S5 saw ±19 % per
   calldata-heavy tx across account classes — re-measure with the Cartridge Controller before
   freezing bounds (R7-A1).
4. **Registry switch** (`doom_fold4_min`, D11): constants regenerated and verified; the committed
   default stays `doom` until the wrapper switches; then `tools/gen_multiverifier_consts.py
   --registry doom_fold4_min`, redeclare, redeploy a router.
5. **Consumer not implemented** (`DoomRuns`): interface and checks specified in §6 for the
   10-felt outputs; `recursion_outputs` fixtures to regenerate for that width.
6. **snforge/scarb pins**: scarb 2.18.0 (vendored verifier), starknet-foundry **0.61.0** (0.57.0
   cannot run the test artifacts of Sierra 1.8: "Unknown value for memory cell" at collection),
   starknet-devnet 0.10.0.

## 11. Reproduce

```bash
cd cairo/doom_contracts && sh fixtures/unpack.sh           # scarb 2.18.0, snforge 0.61.0 (.tool-versions)
scarb build                                                # 4 classes, audited libfuncs, sizes above
(cd crates/stwo_circuit_phases && snforge test)            # 35 tests: monolithic, phases, packing, cost probe
(cd crates/doom_contracts && snforge test)                 # 6 tests: router 5-tx drive + rejections
tools/check_registry.sh doom_fold4_min                     # regenerated constants vs the S4b root proof
python3 tools/emit_calldata.py fixtures/n4_root_proof.txt --out calls.json [--fri-split 1,3]
# devnet (S5 prices): see docs/spikes/S5.md §10 for the flags; port 5066 in this run
python3 tools/devnet_drive.py --calls calls.json --out results/devnet_receipts.json \
    --accounts-file accounts.json --url http://127.0.0.1:5066/rpc
python3 tools/trace_tx.py --blocks 11-16 --url http://127.0.0.1:5066/rpc   # per-call gas
python3 tools/devnet_probe.py --calls calls.json --deployment results/devnet_receipts_deployment.json \
    --accounts-file accounts.json --out results/devnet_probe.json           # transport calibration
```

Artefacts: `cairo/doom_contracts/results/devnet_receipts.json` (5-tx receipts verbatim, fact,
pricing), `devnet_receipts_6tx.json`, `devnet_receipts_deployment.json` (class hashes, declare
gas), `devnet_probe.json`.
