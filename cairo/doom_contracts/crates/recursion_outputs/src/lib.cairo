// SPDX-License-Identifier: Apache-2.0
//! `recursion_outputs` — recomputes, on-chain, the public output of a
//! `stwo_run_and_prove_recursive_tree` root proof from the raw output preimages of its leaves.
//!
//! Port of `spikes/s4/recursion_outputs` (S4, docs/spikes/S4.md §4) into the contracts
//! workspace, unchanged in logic: the spike compiled with `enable-gas = false` and
//! `cairo_test`, this package compiles under the contract workspace's `[cairo]` table and is
//! tested with snforge. It is generic over the preimage length — S4 folded 4-felt segment-stub
//! outputs, `DoomRuns` folds the 10-felt `SegmentOutput` of D14.
//!
//! Byte-identity contracts mirrored here (proving @ cd7bc5f):
//! - leaf output `H1 = blake2s(cairo0_encode(output_preimage))`
//!   (`stwo_run_and_prove_recursive_tree::leaf_io::LeafInput::output_values`);
//! - fold output `blake2s(left.circuit_hash ‖ left.output ‖ right.circuit_hash ‖
//! right.output)`
//!   (`circuit_multiverifier::verify::build_multiverifier_circuit`), words hashed as
//!   little-endian bytes;
//! - balanced fold with odd carry; a single leaf is folded with itself
//!   (`stwo_run_and_prove_recursive_tree::fold_entries`);
//! - on-chain `VerificationOutput.output_hash = blake2s(root.circuit_hash ‖ root.output)`
//!   (`stwo_circuit_air::get_verification_output`).
pub mod blake;
pub mod encode;
pub mod tree;
