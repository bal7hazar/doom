// SPDX-License-Identifier: Apache-2.0
//! The recursive tree's output hashing, recomputed from the leaves.
use crate::blake::{append_digest, hash_u32s};
use crate::encode::encode_felts;

/// One tree node as the multiverifier sees it: the identity of the circuit that produced it and
/// its eight raw output words.
#[derive(Copy, Drop, Serde, Debug, PartialEq)]
pub struct Node {
    pub circuit_hash: [u32; 8],
    pub output: [u32; 8],
}

/// `H1 = blake2s(cairo0_encode(preimage))`: the leaf circuit's public output, where
/// `preimage = [task_program_hash, task_output...]` is what the leaf simple bootloader dumps.
pub fn leaf_output(preimage: Span<felt252>) -> [u32; 8] {
    hash_u32s(encode_felts(preimage).span())
}

/// The layer-0 node of a leaf.
pub fn leaf_node(leaf_circuit_hash: [u32; 8], preimage: Span<felt252>) -> Node {
    Node { circuit_hash: leaf_circuit_hash, output: leaf_output(preimage) }
}

/// The multiverifier over `(left, right)`: outputs
/// `blake2s(left.circuit_hash ‖ left.output ‖ right.circuit_hash ‖ right.output)`.
pub fn fold_pair(left: @Node, right: @Node, multiverifier_hash: [u32; 8]) -> Node {
    let mut words = array![];
    append_digest(ref words, left.circuit_hash);
    append_digest(ref words, left.output);
    append_digest(ref words, right.circuit_hash);
    append_digest(ref words, right.output);
    Node { circuit_hash: multiverifier_hash, output: hash_u32s(words.span()) }
}

/// Folds `leaves` (in order) exactly as `stwo_run_and_prove_recursive_tree` does: adjacent pairs
/// two-to-one per layer, an unpaired last entry carried up unchanged, and a single leaf folded
/// with itself. Returns the root node.
pub fn fold_tree(leaves: Span<Node>, multiverifier_hash: [u32; 8]) -> Node {
    assert!(leaves.len() > 0, "empty tree");
    if leaves.len() == 1 {
        let leaf = leaves[0];
        return fold_pair(leaf, leaf, multiverifier_hash);
    }
    let mut layer: Array<Node> = array![];
    layer.append_span(leaves);
    while layer.len() > 1 {
        let mut next: Array<Node> = array![];
        let mut pairs = layer.span();
        while let Some(left) = pairs.pop_front() {
            match pairs.pop_front() {
                Some(right) => next.append(fold_pair(left, right, multiverifier_hash)),
                None => next.append(*left),
            }
        }
        layer = next;
    }
    let root = *layer.at(0);
    root
}

/// The on-chain verifier's `VerificationOutput.output_hash`: `blake2s(circuit_hash ‖ output)`.
pub fn verification_output_hash(root: @Node) -> [u32; 8] {
    let mut words = array![];
    append_digest(ref words, root.circuit_hash);
    append_digest(ref words, root.output);
    hash_u32s(words.span())
}

/// End to end: leaf preimages (fold order) + the two circuit identities -> the root's
/// `VerificationOutput.output_hash`.
pub fn root_output_hash(
    preimages: Span<Span<felt252>>, leaf_circuit_hash: [u32; 8], multiverifier_hash: [u32; 8],
) -> [u32; 8] {
    let mut leaves: Array<Node> = array![];
    for p in preimages {
        leaves.append(leaf_node(leaf_circuit_hash, *p));
    }
    verification_output_hash(@fold_tree(leaves.span(), multiverifier_hash))
}
