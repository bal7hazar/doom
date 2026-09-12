//! `recursion_outputs` — recomputes, on-chain, the public output of a `stwo_run_and_prove_recursive_tree`
//! root proof from the raw output preimages of its leaves.
//!
//! Byte-identity contracts mirrored here (proving @ cd7bc5f):
//! - leaf output `H1 = blake2s(cairo0_encode(output_preimage))`
//!   (`stwo_run_and_prove_recursive_tree::leaf_io::LeafInput::output_values`);
//! - fold output `blake2s(left.circuit_hash ‖ left.output ‖ right.circuit_hash ‖ right.output)`
//!   (`circuit_multiverifier::verify::build_multiverifier_circuit`), words hashed as little-endian bytes;
//! - balanced fold with odd carry; a single leaf is folded with itself (`stwo_run_and_prove_recursive_tree::fold_entries`);
//! - on-chain `VerificationOutput.output_hash = blake2s(root.circuit_hash ‖ root.output)`
//!   (`stwo_circuit_air::get_verification_output`).
pub mod bench;
pub mod blake;
pub mod encode;
pub mod tree;

#[cfg(test)]
mod tests;
#[cfg(test)]
mod fixtures;
