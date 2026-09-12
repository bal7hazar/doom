# doom_contracts — the on-chain verifier workspace

**Does**: verifies a Stwo *circuit* proof (the root of the recursive tree, ~96 k felts) on
Starknet in 5–6 transactions, with every proof section passed as **calldata** and only a
32-byte checkpoint hash in storage between transactions, then registers the fact
`poseidon(circuit_hash ‖ output_hash)` and answers `is_valid(fact)`. Design, measurements and
the soundness argument: [`docs/design/onchain-verifier.md`](../../docs/design/onchain-verifier.md).

It also holds the **consumer** side: `DoomRuns` recomposes the batch's root `output_hash` from
the ten public felts of each segment, requires the fact to be registered, and records one game
per member — validation rules, gas and open points in
[`docs/design/doomruns.md`](../../docs/design/doomruns.md).

## Layout

| Path | What |
|---|---|
| `vendor/stwo_cairo_verifier/` | the verifier crates of `starkware-libs/proving` pinned at **`cd7bc5f`** (`VENDOR.md`, visibility-only patch); `circuit_air/src/{multiverifier_consts,preprocessed_columns}.cairo` are **generated** from a registry (`tools/gen_multiverifier_consts.py`) |
| `crates/stwo_circuit_phases/` | library: the phase machine (`machine.cairo`: `begin` / `merkle` / `answers` / `fri_layers`), the packed transport (`pack.cairo`), the section splitter used by tests (`sections.cairo`); tests = monolithic reference, end-to-end phases with checkpoint round-trips, tamper rejections, cost probe, packing benchmarks |
| `crates/recursion_outputs/` | library: the recursive tree's output hashing recomputed from the leaves (blake2s leaf output, two-to-one fold with odd carry and single-leaf self-fold, `VerificationOutput.output_hash`); port of `spikes/s4/recursion_outputs`, tests = upstream goldens + the real S4 root proofs |
| `crates/doom_runs/` | contracts: `DoomRuns` (version table, run records, leaderboards, replay publication) and `MockFactRegistry` (tests/drives only); tests = recomposition against the Python model, the fact gate, every member-level rejection, replay data, boards, governance |
| `crates/doom_contracts/` | contracts: `StwoPhasesBegin` / `StwoPhasesMerkle` / `StwoPhasesFri` (stateless library classes), `StwoCircuitRouter` (checkpoints, sequencing, facts), `StwoCircuitMonolithic` (measurement only); tests = the router driven over a real proof + rejections |
| `fixtures/` | real root proofs as one-felt-per-line text (gzipped; `sh fixtures/unpack.sh`): `n4_root_proof` (S4, registry `doom`), `n2_fold4min_root_proof` (S4b, registry `doom_fold4_min`); `selected.txt` picks the one the tests use (1 / 2) |
| `tools/` | `emit_calldata.py` (proof → per-transaction packed calldata), `devnet_drive.py` (declare, deploy, drive, receipts, pricing), `trace_tx.py` (per-call gas of a tx), `devnet_probe.py` (transport calibration), `gen_multiverifier_consts.py`, `check_registry.sh`, `doomruns_model.py` (independent Python model + fixture generator), `doomruns_drive.py` (consumer drive) |
| `results/` | devnet receipts of the 5-tx and 6-tx drives, deployment (class hashes, declare gas), transport probe, `doomruns_receipts.json` (consumer drive, N = 1…480) |

## Toolchain

`.tool-versions`: **scarb 2.18.0** (required by the vendored verifier), **starknet-foundry
0.61.0** (0.57.0 cannot run the Sierra 1.8 test artifacts), starknet-devnet 0.10.0 for the
drives. This workspace is deliberately not a member of `cairo/Scarb.toml`: contracts need gas
enabled while `doom_run` needs it disabled, and Scarb honours one `[cairo]` table per workspace.
snforge is configured with `tracked_resource = "cairo-steps"`: that is what devnet/blockifier
0.14.4 bills (the default sierra-gas mode understates by 1.4–3.5×).

```bash
sh fixtures/unpack.sh
scarb build                                   # audited libfuncs; class sizes in the design doc §7
(cd crates/stwo_circuit_phases && snforge test)
(cd crates/doom_contracts && snforge test)
tools/check_registry.sh doom_fold4_min        # conformance of regenerated constants (R3-A5)
```

## Transaction flow (client side)

```
python3 tools/emit_calldata.py root.proof --out calls.json [--fri-split 1,3]   # 5 or 6 txs
tx1 begin(proof_id, head, head_n, payload, lens, trees=[0,1])      -> state S1 (228 felts)
tx2 merkle(proof_id, S1, payload, lens, trees=[2,3])               -> S2
tx3 answers(proof_id, S2, payload=[sampled, qv0..qv3], lens)       -> S3 (576 felts)
tx4 fri(proof_id, S3, layers 0-1, n_values)                        -> S4
tx5 fri(proof_id, S4, layers 2-5, n_values)                        -> fact registered
```

Each transaction's calldata is ≤ 4 627 felts; the state returned by a transaction is the
`state` argument of the next (`tools/devnet_drive.py` threads it from the trace's retdata).
