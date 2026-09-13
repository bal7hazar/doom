# On-chain verifier — resumable circuit verification with proof sections as calldata (P4.0, P4.1)

> Design + measured prototype for RISKS.md **R7-A6** (decisions D5/D6), on the verifier pinned at
> `proving@cd7bc5f`. Everything quantified below is **measured** on the S4 root proof
> (`spikes/s4/results/N4_doom`, 96 033 felts) with the code under `cairo/doom_contracts/`, in
> snforge (`--tracked-resource cairo-steps`, see §7) and on **starknet-devnet 0.10.0**
> (Starknet 0.14.4). No transaction was sent to a public network.
>
> **P4.1 (2026-09-13)** — the gas lever of §8 landed: the vendored verifier carries a documented
> patch series (`cairo/doom_contracts/vendor/patches/`: lazily-reduced FRI folds with one batch
> inversion per layer, lazily-reduced `fri_answers` with one batch inversion per proof) and the
> phase classes decode the packed sections themselves. **1.540e9 L2 gas per fact on devnet
> (was 3.810e9, −59.6 %), 5 transactions, worst 38.5 % of the cap, 47.0 STRK ≈ 1.35 $** at the S5
> price snapshot. What is verified did not change: the optimized phases are compared with the
> **unmodified** vendored `verify_circuit` (`vendor/stwo_cairo_verifier_ref`) on the real root
> proofs, accepted and tampered (`crates/stwo_circuit_phases/tests/test_equivalence.cairo`).
> Numbers marked *P4.0* are the pre-optimization ones, kept for the comparison.

## 0. Verdict

| Target (R7-A6) | P4.0 | **P4.1** |
|---|---|---|
| ≤ 6 invokes per fact | 5 transactions (or 6 under the 90 % rule) | **5 transactions** (`--fri-split 2`), the 6-tx plan is no longer needed |
| each tx ≤ 90 % of the 1.21e9 L2-gas invoke cap | worst tx 90.4 % (fri1) | worst tx **38.5 %** (`answers`, 466 M) |
| calldata ≤ ~4 990 felts per tx | worst tx 4 627 felts (begin) | unchanged (same calldata format) |
| no proof data in storage | 0 proof felts stored, 1 slot per (caller, proof_id) | unchanged |
| ≤ 2.5e9 L2 gas per fact | 3.81e9 — missed | **1.540e9** — met (§3, `results/p41_receipts.json`) |
| cost per fact | 116 STRK ≈ 3.35 $ at the S5 snapshot (30.5 gFri, 0.0288 $/STRK); 11.4 STRK at the 3 gFri floor | **47.0 STRK ≈ 1.35 $**; **4.6 STRK ≈ 0.13 $** at the floor. Versus S5's storage-staged extrapolation (≈ 250 STRK, 9 tx): **5.3× cheaper** |
| declares (once) | 4 classes, 7.83e9 L2 gas ≈ 238 STRK | 4 classes, 8.77e9 ≈ 267 STRK (the classes grew by the decoders and the lazy arithmetic; all under the caps, §7) |

The optimized classes verify the real S4 root proof end to end on devnet (fact
`0x6b07de2a…7184be` registered, `is_valid` = true — the same fact as P4.0) and the two proved
ten-felt batches of P4.2b in snforge, and reject the same tampered proofs as the unmodified
verifier. The remaining cost is no longer dominated by field arithmetic: the largest transaction
(`answers`) is bound by VM steps, not range checks (§8).

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
**without** the qm31 opcode, gas enabled, audited libfuncs). **How the gas is computed** (P4.1
finding, §7): the fee of a transaction is the *maximum* over VM resources of `count × weight` —
steps × 100, range checks × 1 600, bitwise × 6 400, … — not their sum; in the vendored verifier
the range checks dominate the steps two to one (one reduced M31 multiplication costs 3 range
checks, an inversion 136, the packed `fri_fold` 28), so every P4.0 figure below is its
range-check count × 1 600, and the P4.1 levers are "fewer reduced field operations". The P4.1
column includes the decoding of the packed section (P4.0 unpacked in the router, 21 range checks
per slot, counted in the transport then; the fair P4.0 figure is given with it in brackets):

| Stage | P4.0 steps / range checks | P4.0 L2 gas (+ unpack) | **P4.1 steps / range checks** | **P4.1 L2 gas** | binding resource |
|---|---:|---:|---:|---:|---|
| `begin` (whole transcript, incl. OODS eval) | 313 k / 31.6 k | 50.6 M | 400 k / 38.7 k | 61.9 M | range checks (it now also packs the sampled section for its digest) |
| Merkle tree 0 / 1 / 2 / 3 (+ decode) | 381 k / 42.0 k … 278 k / 32.0 k | 67 / 95 / 111 / 51 M (+ 13 / 38 / 44 / 22 M unpack) | 523 k / 52.3 k, 716 k / 72.4 k, 822 k / 83.6 k, 415 k / 40.8 k | **84 / 116 / 134 / 65 M** | range checks (decode 2.1 per value, tree walk 4 per node) |
| `answers` (`fri_answers` + decode) | 4.00 M / 422 k | 676 M (+ 116 M unpack) | 3.88 M / 192 k | **388 M** | **steps** (3.9 M: 22 k column terms, decoding, arrays) |
| FRI first layer / inner 0 / 1 / 2 / 3 / 4 (+ decode) | 1.91 M / 305 k … 21 k / 3.3 k | 487 / 474 / 410 / 390 / 92 / 5 M (+ 160 M unpack) | 1.11 M / 97.5 k, 1.00 M / 87.6 k, 872 k / 75.2 k, 714 k / 61.1 k, 162 k / 13.6 k, 12 k / 1.0 k | **156 / 140 / 120 / 98 / 22 / 2 M** | range checks (decode ≈ 30 %, Merkle ≈ 10 %, folds + twiddles ≈ 60 %) |
| **compute + decode total** | 13.5 M / 1.83 M | **≈ 2.93 e9 + 0.46 e9** | 10.6 M / 0.82 M | **≈ 1.39 e9** | |
| monolithic reference (`verify_circuit`, unmodified vendor, whole stream) | 13.1 M / 1.80 M | 2.87 e9 | — (it is the reference the phases are compared with) | | |

Reading: the transcript is negligible; after P4.1 the FRI walk costs 0.54e9 instead of 2.0e9
(one Montgomery batch inversion per layer instead of 1 050 exponentiations, folds on unreduced
`felt252` limbs reduced once per subset, twiddles from one `to_point` per subset, table bit
reversal), `fri_answers` 0.39e9 instead of 0.79e9 (numerators accumulated unreduced per sample
point, one batch inversion of all 630 denominators, one reduction per row) and the transport +
deserialization 2.1 range checks per proof value instead of 5–6. With the qm31 opcode the same
proof would cost ≈ 5.3 M steps (S4); the opcode is still not in `audited.json` (R3-A9).

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

Measured transport cost on devnet (`tools/devnet_probe.py`, `results/devnet_probe.json`, P4.0):
calldata **5 120 gas/felt** + validate/fee ≈ 6.7 k per felt all-in; `unpack_u32` **35.2 k gas per
slot** (5.0 k per value = 21 range checks per slot; the first u256/u128-divmod version cost 82
k/slot); the library-call copy of the unpacked span ≈ 1.9 k per felt.

**P4.1**: the router no longer unpacks. It slices the payload into its packed sections and
forwards the slices (7× less library-call calldata); the phase class decodes each section
straight into the verifier's types (`stwo_circuit_phases::decode`): one `felt252 → u256` split
per slot, the limbs isolated with the bitwise builtin and exact divisions by 2^32 in the field,
five `u128` re-typings per slot and one range check per value (`u128 → M31` constrain or
`u128 → u32` downcast) — **15 range checks per slot ≈ 2.1 per value** (3.4 k gas), where P4.0
paid 3 to unpack plus 2–3 to deserialize (`felt252 → u32 → M31`). The digests that bind the
re-supplied sections (`d_sampled`, `d_queried`) are now taken over the packed slots, which
determine the decoded values (decoding is a function of the slots and every value is
range-checked to its type). Packing costs ~10 % more gas than raw calldata would but divides the
transaction count by 7 (96 k felts would need 20 invokes raw). The calldata format is unchanged.

## 3. Phase design (measured)

Rules: every section arrives in the transaction that consumes it; the head is the only
transcript input and is consumed whole by `begin`; the channel is never checkpointed (it is not
needed after the query sampling); the state carried between transactions is a few hundred felts
echoed by the caller and pinned by a Poseidon hash in storage.

**5-transaction plan** (`tools/emit_calldata.py --fri-split 2`), **P4.1**
(`results/p41_receipts.json`, devnet 0.10.0, the P4.0 figures of `results/devnet_receipts.json`
in brackets):

| # | entrypoint | sections | calldata felts | echo felts | L2 gas (devnet) | % of 1.21e9 | of which library call(s) | router (slicing + hash + storage) + envelope | fee @30.5 gFri |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|
| 1 | `begin` | head (279 slots) + trees 0, 1 (4 334 slots) | 4 627 | 0 | **302 485 920** (459 M) | 25.0 % | 66.9 M + 200.9 M | 34.7 M | 9.22 STRK |
| 2 | `merkle` | trees 2, 3 (4 346 slots) | 4 585 | 228 | **233 506 880** (391 M) | 19.3 % | 200.5 M | 33.0 M | 7.12 |
| 3 | `answers` | sampled values + queried values of the 4 trees (3 448 slots) | 3 685 | 228 | **466 418 880** (861 M) | **38.5 %** | 432.9 M | 33.5 M | 14.21 |
| 4 | `fri` | FRI layers 0, 1 (2 986 slots) | 3 566 | 576 | **294 609 600** (1 093 M) | 24.4 % | 266.3 M | 28.3 M | 8.98 |
| 5 | `fri` | FRI layers 2..5 (1 785 slots), last-layer check, fact | 2 365 | 576 | **243 213 200** (1 005 M) | 20.1 % | 224.5 M | 18.7 M | 7.41 |
| | **total** | 13 720 slots | | | **1 540 234 480** (3 810 M) | | 1.39 e9 | 0.15 e9 | **47.0 STRK** |

Every transaction is under 40 % of the cap: the internal 90 % rule (R7-A5) holds with the 5-tx
plan, so **`--fri-split 2` is the recommended plan** and the 6-tx plan (`--fri-split 1,3`, P4.0:
3.82e9, worst tx 84 %) is only a fallback for a proof whose FRI section grows past the calldata
cap. The per-transaction envelope (validate 0.32 M + fee transfer 0.4 M + calldata 5.1 k/felt)
is now a visible share: 105 M of the 1 540 M.

Why not fewer: 13.7 k slots + echoes need ≥ 4 transactions at 4 990 felts, and the section
granularity (the four 1 372-slot hash witnesses, the 1 653-slot first FRI layer) leaves no
4-tx packing; the FRI walk (0.51e9 on devnet) would now fit one transaction by gas but not by
calldata (4 773 slots + 576 echo). Merging `answers` with the first FRI layer would need 5 101
slots. The one structural lever left is to fold `fri_answers` into the Merkle transactions
(§8, lever 2): 4 transactions and no re-supply of the queried values.

## 4. Checkpoint layout

Storage holds, per `(caller, proof_id)`, one `Checkpoint { tag: u8, state_hash: felt252 }`
(1 slot). The state itself is returned by each transaction and **echoed as calldata** by the
next one; the router checks `poseidon(state) == state_hash` and the tag. Nothing else is stored:
this is the "checkpoint in storage" of the brief at 1 write instead of 200–600 (≈ 495 k gas
each).

`stwo_circuit_phases::machine` states (cairo-serde):

| State | tag | felts (70 queries) | contents |
|---|---|---:|---|
| `Params` (inside both) | — | ≈ 210 | `circuit_hash` [u32;8], `output_hash` [u32;8], 4 tree roots (32), `d_sampled` (poseidon of the fast-path packed sampled-values section, P4.1 — of its felts in P4.0), OODS point (8), `fri_answers` random coeff (4), 70 query positions, FRI first layer + 5 inner layers `{root, alpha, log_degree_bound, fold_step}` (6 × 14), last-layer value (4) |
| `MerkleState` | 1 | **228** | `Params` + `trees_done` bitmask + `d_queried[4]` (poseidon of each tree's packed queried-values section, filled by `merkle`) |
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
3. **Queried values re-supplied to `answers`** — bound by `d_queried[i]` = poseidon(packed
   section) taken by `merkle` after the tree verified; `answers` requires all 4 `trees_done` bits
   and the 4 digests (tests: tampered, swapped trees, incomplete Merkle phase). The digest is
   over the packed slots (P4.1): decoding is a function of the slots and every decoded value is
   range-checked to its type, so equal digests mean equal values.
4. **Sampled values re-supplied to `answers`** — bound by `d_sampled` taken in `begin` over the
   fast-path packing of the section (the section is also transcript-bound). Tested.
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

P4.1 (`scarb build`, audited libfuncs; P4.0 CASM in brackets):

| Class | Sierra felts (cap 81 920) | class JSON bytes (cap 4 089 446) | CASM felts (cap 81 920) | declare L2 gas (devnet) |
|---|---:|---:|---:|---:|
| `StwoPhasesBegin` (transcript + OODS eval) | 38 929 (48 %) | 2 694 075 (66 %) | 63 575 (78 %) (62 403) | 4.20e9 (128 STRK) |
| `StwoPhasesMerkle` (Merkle + `fri_answers` + decoders) | 16 750 (20 %) | 1 666 103 (41 %) | 40 073 (49 %) (29 907) | 2.33e9 (71 STRK) |
| `StwoPhasesFri` (FRI walk + decoder) | 13 635 (17 %) | 1 354 401 (33 %) | 27 677 (34 %) (22 765) | 1.69e9 (52 STRK) |
| `StwoCircuitRouter` (with the two calibration probes) | 3 956 (5 %) | 425 543 (10 %) | 9 079 (11 %) (9 670) | 0.54e9 (16 STRK) |
| monolithic `verify_circuit` (measurement only, **unmodified** vendor) | 48 401 (59 %) | 3 896 125 (95 %) | 78 641 (96 %) | — |

The optimized verifier compiled monolithically no longer fits one class (86 357 CASM felts),
which is why the measurement-only class stays the pristine copy; the three stateless classes +
router remain the shape. The vendored crate carries a visibility-only patch and, since P4.1, the
arithmetic patch series of `vendor/patches/` (per-patch invariant and equivalence argument in its
README); `vendor/stwo_cairo_verifier_ref/` is the unmodified tree under `*_ref` package names
(`tools/vendor_ref.sh`) so both can be compiled into one test binary and compared.

**Gas oracle.** snforge's default `sierra-gas` accounting understated devnet by 1.4× (transcript)
to 2.1× (FRI) and 3.5× (unpack); with `--tracked-resource cairo-steps` (the workspace default)
the library calls match the devnet receipts within 3 %: devnet 0.10 / blockifier 0.14.4 bills
these classes by VM resources. **The bill is the maximum, not the sum**, of `steps × 100`,
`range_check × 1 600`, `bitwise × 6 400`, `poseidon × 3 200`, … (P4.1 finding, verified on every
probe: the P4.0 figures are exactly `range checks × 1 600`). Consequences: (1) the cost of a
class is its range-check count while `range_check × 1 600 > steps × 100`, i.e. more than one
range check per 16 steps — the vendored verifier had one per 7; (2) the blake2s and poseidon
builtins are free while they are not the binding resource (they never are here), and so is the
bitwise builtin the decoder uses (≈ 5 per slot: at most 147 M of "bitwise gas" in the largest
transaction against its 302 M bill); (3) once the range checks are down, the steps bind: the
`answers` class is there (3.9 M steps vs 192 k range checks). Rule: size phases with cairo-steps
snforge numbers × 1.05 (both resources), then confirm on devnet (`tools/devnet_drive.py`, R3-A7).

## 8. Costs and levers (P4.1 done, what is left)

Where the **1.54e9** goes (devnet, `results/p41_receipts.json`): `answers` class 0.43e9 (28 %),
FRI walk 0.49e9 (32 %), Merkle trees 0.40e9 (26 %), transcript 0.07e9, router + envelopes +
calldata 0.15e9 (10 %). P4.0 was 3.81e9: FRI 1.84e9, `fri_answers` 0.68e9, Merkle 0.33e9,
transport 0.81e9.

Levers measured in isolation (snforge cairo-steps, S4 fixture; the numbers of §1):

| Lever (P4.1 brief) | Where | Effect | Status |
|---|---|---|---|
| 1. Batch inversion | FRI twiddles: one Montgomery inversion per layer (1 050 twiddles) instead of one 136-range-check exponentiation each; `fri_answers`: one inversion of all 630 denominators (through their norms) instead of 490 CM31 inversions | FRI −55 % alone; the largest single item | done (patches 0002, 0003) |
| 2. Packed / lazily-reduced arithmetic | FRI folds on 4 unreduced `felt252` limbs, three levels between reductions (bounds < 2^241), reductions by `u256` split (`2^128 ≡ 16 mod P`); `fri_answers` numerators unreduced per sample point, one reduction per row | FRI −74 % and `answers` −43 % with lever 1; range checks per fold node 28 → 0 | done; the `bounded_int` helpers are used for the last reduction step; no `u32`/felt mixing was needed beyond `u128 → M31` |
| 3. Avoid recomputation | per-layer step multiples and alpha powers hoisted; one `to_point` per subset (the other twiddles are one felt expression each); table bit reversal (143 → 19 range checks per call); `fri_answers` batches at the same point share one denominator; the queried values are iterated once (no per-column lookup) | inside the figures above (≈ 15 % of the FRI gain) | done |
| 4. Merkle verification | blake2s is free (not the binding resource); the costs were the deserialization (5–6 range checks per hash word / value) → decoder 2.1; the tree walk itself (u32 `div_rem` per node, 4 range checks) is untouched | trees (with their decode) −37 % | partly: the walk (≈ 14 k nodes × 4 range checks ≈ 90 M) is a follow-up |
| 5. Phase plumbing | the router forwards packed slices (library-call calldata 7× smaller, the 0.18e9 copy of P4.0 is gone); digests over slots; checkpoint sizes unchanged (228 / 576 felts) | transport 0.81e9 → 0.15e9 (with lever 4's decoder) | done |

What is left, in order of value:

1. **`answers` is steps-bound** (3.9 M steps, 433 M on devnet): 22 k column terms at ≈ 30 steps
   each, the decoding of 28 k values, the per-row arrays. A packed two-lane accumulation of the
   numerators (as the vendored `PackedUnreducedQM31`, 2 felt multiplications per term instead of
   4) is not possible with the shared-denominator layout (the lanes overflow); a two-column
   unrolled loop or a smaller decode buffer could bring it to ≈ 3 M steps (−0.1e9).
2. **Fold `fri_answers` into the Merkle transactions** (4 transactions): each Merkle transaction
   accumulates its trees' numerator sums per (row, sample point) — 70 × 9 reduced QM31, ≈ 320
   packed felts in the checkpoint — and the first FRI transaction finishes the rows. Saves the
   re-supply of the queried values (3 194 slots: calldata + decode + digests ≈ 0.10e9) and one
   envelope; costs the sampled section in the second Merkle transaction (254 slots) and the
   quotient constants twice. Net ≈ −0.1e9 and one transaction fewer; changes the emitter's plan
   (§9) and the checkpoint layout (§4).
3. **Merkle tree walk**: parity and parent by bitwise + exact division (1 range check + 1
   bitwise per node instead of 4 range checks): ≈ −0.06e9.
4. **qm31 opcode in `audited.json`** (R3-A9): the folds and quotients then cost a few steps per
   operation; everything here survives (the phases only get cheaper).

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
- Sponsoring (R7-A4) is orthogonal: the paymaster signs the same 5 calls.
- Cost display: 47 STRK / 1.35 $ per fact at the S5 snapshot; per game with M = 8 aggregated
  games (D6): ≈ 5.9 STRK / 0.17 $, ≈ 0.017 $ at the price floor.
- **Emitter / submitter (P4.1)**: the calldata format and the router ABI are unchanged, so
  `client/src/chain/calldata.ts` and `infra/submit` need **no format change**. What changes is
  the plan and the bounds: the recommended cut is `--fri-split 2` (5 transactions, every one
  under 40 % of the cap). Since `b00c90b`, this is also the client/CLI default; the former
  6-tx cut (`--fri-split 1,3`) remains available, including saved resumptions. The R7-A1 bounds (`l2_gas` =
  estimate × 1.15) should be re-derived from the P4.1 receipts (`answers` 466 M is the largest
  transaction now, `fri1` 295 M). The phase class hashes change (new declares, §7): a new router
  deployment, as for any verifier version (§6). Lever 2 of §8, if taken, would change the plan
  to 4 transactions and move the sampled-values section into the second Merkle transaction —
  that one is an emitter change and is not done here.

## 10. Blockers and open points

1. ~~2.5e9 target missed~~ — **met in P4.1: 1.54e9** (§3). The remaining levers (§8) are worth
   ≈ 0.3e9 together; none is required for Phase 4.
2. ~~fri1 at 90.4 % of the cap~~ — worst transaction 38.5 % (`answers`); `--fri-split 2` is the
   plan.
3. **Account class**: measured with devnet's predeployed OZ-type account; S5 saw ±19 % per
   calldata-heavy tx across account classes — re-measure with the Cartridge Controller before
   freezing bounds (R7-A1). With every transaction under 40 % this is a cost question, not a
   feasibility one.
4. **Registry switch** (`doom_fold4_min`, D11): `tools/check_registry.sh doom_fold4_min`
   regenerates the constants of both vendor copies and runs the reference, equivalence, phase and
   router suites on the S4b golden; the committed default stays `doom` until the wrapper
   switches; then redeclare, redeploy a router.
5. **Upstreaming**: the patch series is written against `cd7bc5f` with per-patch invariants
   (`vendor/patches/README.md`); a bump of the pin re-applies it (`apply.sh`) and re-runs the
   equivalence suite against the new pristine copy (`tools/vendor_ref.sh`).
6. **snforge/scarb pins**: scarb 2.18.0 (vendored verifier), starknet-foundry **0.61.0** (0.57.0
   cannot run the test artifacts of Sierra 1.8), starknet-devnet 0.10.0.

## 11. Reproduce

```bash
cd cairo/doom_contracts && sh fixtures/unpack.sh           # scarb 2.18.0, snforge 0.61.0 (.tool-versions)
scarb build                                                # 5 classes, audited libfuncs, sizes above
(cd crates/stwo_circuit_phases && snforge test)            # 67 tests: reference, equivalence + tampers, phases, packing, cost probes
(cd crates/doom_contracts && snforge test)                 # 6 tests: router 5-tx drive + rejections
tools/check_registry.sh doom_fold4_min                     # the same suites on the S4b golden (regenerated constants)
python3 tools/emit_calldata.py fixtures/n4_root_proof.txt --out calls.json          # --fri-split 2 (default)
# devnet (S5 prices): see docs/spikes/S5.md §10 for the flags; port 5091 in the P4.1 run
python3 tools/devnet_drive.py --calls calls.json --out results/p41_receipts.json \
    --accounts-file accounts.json --url http://127.0.0.1:5091/rpc --no-live
python3 tools/trace_tx.py <tx hash> --url http://127.0.0.1:5091/rpc                # per-call gas
tools/vendor_patches.sh <base commit>                      # regenerate vendor/patches/000N-*.patch from git
```

Artefacts: `cairo/doom_contracts/results/p41_receipts.json` (P4.1: 5-tx receipts verbatim, fact,
pricing) and `p41_receipts_deployment.json` (class hashes, declare gas); P4.0:
`devnet_receipts.json`, `devnet_receipts_6tx.json`, `devnet_receipts_deployment.json`,
`devnet_probe.json`.
