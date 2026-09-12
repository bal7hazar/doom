<!--
SPDX-FileCopyrightText: 2026 Hellproof contributors
SPDX-License-Identifier: Apache-2.0
-->

# Patches to the pinned `starkware-libs/proving` monorepo

The wrapper owns no proving code: it drives the monorepo's binaries at the pinned revision
**`cd7bc5f`** (R3-A1). This directory holds the few changes it needs on top of that revision, in
`git format-patch` form, so that:

* the build is still a clone of the *upstream* repository at a pinned commit plus an auditable
  diff — not a fork nobody reviews;
* each patch is a self-contained commit with a message written for an upstream pull request, and
  can be sent as one the day we open it (G0 **D19**);
* removing a patch is deleting a file.

They are applied by [`../scripts/apply_patches.sh`](../scripts/apply_patches.sh), which
`infra/wrapper/Dockerfile` runs in its `proving` stage right after the checkout. Applying them is
idempotent — the script skips a patch that is already in the tree — and applying **none** of them
still gives a working wrapper, one that re-proves every segment (`leaf_mode = "rerun"`).

| Patch | Upstream crates | Why |
|---|---|---|
| `proving-0001-leaf-prover-from-proof.patch` | `leaf_prover`, `cairo_verifier` | a proof-only leaf entry point (D19, task P3.4b) |

---

## `proving-0001-leaf-prover-from-proof.patch`

### The problem

`leaf-prover` takes **a program and its input**. It runs the program, proves the run, verifies
that Cairo proof inside the cairo-verifier circuit, and proves the circuit. There is no way to
hand it a Cairo proof somebody else made.

That is the whole point of Hellproof: the player's browser proves the segment (`prover/wasm`, S2)
and the server folds those proofs (S4). Without this entry point the browser's proof is only an
*admission gate* — the server verifies it, throws it away, and re-runs and re-proves the same
segment itself before it can do the interesting work. Wasted, and it puts a second Cairo prover
(with its own parameters, and its own chance of disagreeing) in the trust path.

### What the patch does

`prove_leaf` is split at its `prove_cairo` call:

```
prove_leaf(program, program_input, registry)          ← unchanged signature
    run the program
    prove_cairo
    └── prove_leaf_from_proof(&proof, program, registry)      ← new, public

prove_leaf_from_proof(proof, program, registry)       ← the whole second half
    output cells → output_hash
    registry.leaf_verifier(trace_log_size)
    leaf_verifier_config / prepare_cairo_proof_for_circuit_verifier
    build_and_fill_cairo_verifier_circuit + pad_to_targets
    prove_circuit_assignment
    assert circuit_hash == registry entry
    → SerializedLeafProof
```

so the two paths are the *same code* from the circuit on, and therefore produce the same leaf
circuit and the same circuit hash by construction rather than by review.

The binary grows one mode:

```bash
leaf-prover --program leaf_simple_bootloader_compiled.json \
            --cairo_proof segment_0.proof --proof_format extended-binary \
            --circuit_registry_json registry.json --output_path leaf_0.raw.json
```

`--program_input` and `--cairo_proof` are mutually exclusive (clap `conflicts_with`); everything
else is unchanged, and a command line without `--cairo_proof` behaves exactly as before.

Library entry points, for a caller that links the crate instead of spawning it:

| Function | Takes |
|---|---|
| `prove_leaf_from_proof(&CairoProof<Blake2sMerkleHasher>, &Program, &CircuitRegistry)` | an in-memory proof |
| `prove_leaf_from_proof_files(&Path, &Path, CairoProofInputFormat, &Path)` | the four paths above |
| `read_cairo_proof(&Path, CairoProofInputFormat)` | just the deserialization |

### Why `--program` is still required in the proof-only mode

The program is *not* read from the proof, even though the proof's public memory carries it
(`verify_cairo_with_component_set` does read it from there). The verifier circuit bakes the
program in as constants, so the program determines the circuit's preprocessed root and therefore
its `circuit_hash` — the hash the patch still asserts against `registry.leaf_verifiers[…]`. Taking
the program from the proof would make the leaf describe whatever program the submitter proved.
Taking it from the caller keeps the registry the single thing that pins the leaf's identity, which
is the property the on-chain verifier constants rest on.

For Hellproof `--program` is always the same file — the leaf simple bootloader — so this costs the
caller nothing.

### Why no `--program_input`, and where the output hash comes from

The run path used to read the output cells out of the runner's output segment. The proof-only path
cannot, so **both** paths now take them from `proof.claim.public_data.public_memory.output` via
`output_hash_from_output_cells`, which already existed in `cairo_verifier::verify` for
`verify_cairo_with_component_set` and which this patch only makes `pub`.

This is not a weakening. `CairoStatement::new` guesses the digest, publishes it as the circuit's
output, splits it back into the two 128-bit memory cells and feeds those into the **public logup
sum**, which is what binds them to the proven public memory. A proof paired with an output hash
that is not its own makes the circuit invalid, and `prove_leaf` asserts `is_circuit_valid()` before
it proves anything.

So the proof-only mode needs **no program input at all**: no bootloader task description, no user
arguments, no dumped preimage. The bootloader's output preimage is still needed by the *caller* —
`stwo_run_and_prove_recursive_tree` hashes it into the leaf's node output — but that is a property
of the tree's input file, not of this binary, and the submitter supplies it.

### Which serializations are accepted, and why not the felt stream

The verifier circuit is filled from the proof's `ExtendedStarkProof.aux` (the unsorted query
locations, the Merkle decommitment aux data, the FRI aux data). Only serializations of the whole
`CairoProof` — the *extended* proof — can therefore be wrapped:

| `--proof_format` | Bytes | Produced by |
|---|---|---|
| `extended-binary` (default) | `bincode` of `CairoProof`, bzip2-wrapped or raw (sniffed by magic) | `stwo_run_and_prove --proof-format extended-binary` (bzip2-wrapped); `bincode::serialize(&proof)` in any other front end, e.g. a wasm prover |
| `extended-json` (alias `json`) | `serde_json` of `CairoProof` | anything that `serde_json::to_vec`es the proof |

Deliberately **not** accepted:

* `ProofFormat::Json` and `ProofFormat::Binary` — these are `CairoProofForRustVerifier`, which
  drops `aux` by design. They verify fine in the Rust verifier and cannot be folded.
* `ProofFormat::CairoSerde` — `CairoProof` derives `CairoSerialize` but **not** `CairoDeserialize`
  (`cairo_air::utils::deserialize_proof_from_file` panics on it), and the stream is lossy anyway:
  it omits `aux` and `preprocessed_trace_variant` entirely and transposes `queried_values`.

### Checks

The two assertions the run path made about the *prover parameters*
(`include_all_preprocessed_columns`, `lifting_size_policy == AtLeastPreprocessed`) stay where they
belong — in `prove_leaf`, which is the function that uses them. The proof-only path checks the
same properties on the proof itself, where they are facts rather than intentions:

* `proof.preprocessed_trace_variant == registry.cairo_prover_params.preprocessed_trace` (new);
* every tree, preprocessed included, lifted to one size (already there);
* the column count per trace equals the verifier config's (already there);
* `is_circuit_valid()` before proving, and `circuit_hash == registry entry` after (already there).

A proof that does not satisfy them fails while the circuit is being *built* — in seconds, before
the ~24 s / 32 GB circuit proof is started.

### Upstream status

Not yet submitted. The patch is written to be sent as is: one commit, no new dependencies beyond
`bincode` and `bzip2` (both already workspace dependencies, both already used by `cairo-air` for
this very format), no behaviour change on any existing command line, and no new `unsafe`.
