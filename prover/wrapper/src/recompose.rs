// SPDX-FileCopyrightText: 2026 Hellproof contributors
// SPDX-License-Identifier: Apache-2.0

//! Recomputing the root of the recursive tree from the leaves' preimages — the Rust twin of
//! `spikes/s4/recursion_outputs/src/tree.cairo` (which is what the on-chain consumer runs).
//!
//! The wrapper uses it to check its own output: after a fold it recomputes the root's eight
//! output words from the submitted preimages and compares them with the `program_output.json`
//! the tree wrote. A mismatch means the wrapper batched something other than what it says it
//! batched, and the batch is failed instead of being handed to a client.

use crate::felt::{Felt, hash_u32s, leaf_output_words};

/// One tree node: the circuit that produced it and its eight raw output words.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Node {
    pub circuit_hash: [u32; 8],
    pub output: [u32; 8],
}

pub fn leaf_node(leaf_circuit_hash: [u32; 8], preimage: &[Felt]) -> Node {
    Node { circuit_hash: leaf_circuit_hash, output: leaf_output_words(preimage) }
}

/// The multiverifier over `(left, right)`:
/// `blake2s(left.circuit_hash ‖ left.output ‖ right.circuit_hash ‖ right.output)`.
pub fn fold_pair(left: &Node, right: &Node, multiverifier_hash: [u32; 8]) -> Node {
    let mut words = Vec::with_capacity(32);
    words.extend_from_slice(&left.circuit_hash);
    words.extend_from_slice(&left.output);
    words.extend_from_slice(&right.circuit_hash);
    words.extend_from_slice(&right.output);
    Node { circuit_hash: multiverifier_hash, output: hash_u32s(&words) }
}

/// Folds the leaves exactly as `stwo_run_and_prove_recursive_tree` does: adjacent pairs per
/// layer, an unpaired last entry carried up unchanged, and a single leaf folded with itself.
pub fn fold_tree(leaves: &[Node], multiverifier_hash: [u32; 8]) -> Option<Node> {
    if leaves.is_empty() {
        return None;
    }
    if leaves.len() == 1 {
        return Some(fold_pair(&leaves[0], &leaves[0], multiverifier_hash));
    }
    let mut layer = leaves.to_vec();
    while layer.len() > 1 {
        let mut next = Vec::with_capacity(layer.len().div_ceil(2));
        let mut it = layer.chunks(2);
        while let Some(chunk) = it.next() {
            match chunk {
                [l, r] => next.push(fold_pair(l, r, multiverifier_hash)),
                [odd] => next.push(*odd),
                _ => unreachable!(),
            }
        }
        layer = next;
    }
    Some(layer[0])
}

/// The on-chain verifier's `VerificationOutput.output_hash`: `blake2s(circuit_hash ‖ output)`.
pub fn verification_output_hash(root: &Node) -> [u32; 8] {
    let mut words = Vec::with_capacity(16);
    words.extend_from_slice(&root.circuit_hash);
    words.extend_from_slice(&root.output);
    hash_u32s(&words)
}

/// End to end: leaf preimages in fold order plus the two circuit identities.
pub fn root_from_preimages(
    preimages: &[Vec<Felt>],
    leaf_circuit_hash: [u32; 8],
    multiverifier_hash: [u32; 8],
) -> Option<Node> {
    let leaves: Vec<Node> =
        preimages.iter().map(|p| leaf_node(leaf_circuit_hash, p)).collect();
    fold_tree(&leaves, multiverifier_hash)
}

/// Pulls the leaf preimages and the two circuit hashes out of a `packed_output.json`.
pub fn parse_packed_output(
    packed: &serde_json::Value,
) -> anyhow::Result<(Vec<Vec<Felt>>, [u32; 8], [u32; 8])> {
    let mut preimages = vec![];
    let mut leaf_hash = None;
    let mut mv_hash = None;
    walk(packed, &mut preimages, &mut leaf_hash, &mut mv_hash)?;
    Ok((
        preimages,
        leaf_hash.ok_or_else(|| anyhow::anyhow!("no leaf in packed_output"))?,
        mv_hash.ok_or_else(|| anyhow::anyhow!("no multiverifier in packed_output"))?,
    ))
}

fn walk(
    node: &serde_json::Value,
    preimages: &mut Vec<Vec<Felt>>,
    leaf_hash: &mut Option<[u32; 8]>,
    mv_hash: &mut Option<[u32; 8]>,
) -> anyhow::Result<()> {
    let comp = node
        .get("Composite")
        .ok_or_else(|| anyhow::anyhow!("expected a Composite node"))?;
    let hash = words8(&comp["circuit_hash"])?;
    let subs = comp["subtasks"]
        .as_array()
        .ok_or_else(|| anyhow::anyhow!("Composite without subtasks"))?;
    if subs.len() == 1 && subs[0].get("Plain").is_some() {
        *leaf_hash = Some(hash);
        let felts = subs[0]["Plain"]["output_preimage"]
            .as_array()
            .ok_or_else(|| anyhow::anyhow!("Plain without output_preimage"))?;
        preimages.push(
            felts
                .iter()
                .map(|f| Felt::parse(f.as_str().unwrap_or_default()))
                .collect::<anyhow::Result<_>>()?,
        );
        return Ok(());
    }
    *mv_hash = Some(hash);
    for s in subs {
        walk(s, preimages, leaf_hash, mv_hash)?;
    }
    Ok(())
}

fn words8(v: &serde_json::Value) -> anyhow::Result<[u32; 8]> {
    let arr = v.as_array().ok_or_else(|| anyhow::anyhow!("not an array"))?;
    if arr.len() != 8 {
        anyhow::bail!("expected 8 words, got {}", arr.len());
    }
    let mut out = [0u32; 8];
    for (o, v) in out.iter_mut().zip(arr) {
        *o = v.as_u64().ok_or_else(|| anyhow::anyhow!("not a word"))? as u32;
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The committed S4 runs: for each N, the packed tree carries the leaves' preimages and the
    /// two circuit hashes, `program_output.json` is the root's raw output and
    /// `verifier_output.json` is what the on-chain verifier printed for that root proof.
    fn check(packed: &str, program_output: &str, verifier_output: &str) {
        let packed: serde_json::Value = serde_json::from_str(packed).unwrap();
        let (preimages, leaf_hash, mv_hash) = parse_packed_output(&packed).unwrap();
        let root = root_from_preimages(&preimages, leaf_hash, mv_hash).unwrap();

        let expected: Vec<u32> = serde_json::from_str(program_output).unwrap();
        assert_eq!(root.output.to_vec(), expected, "root output words");

        let expected: Vec<u32> = serde_json::from_str(verifier_output).unwrap();
        assert_eq!(
            verification_output_hash(&root).to_vec(),
            expected,
            "VerificationOutput.output_hash"
        );
    }

    #[test]
    fn reproduces_the_s4_run_with_one_leaf_folded_with_itself() {
        check(
            include_str!("../../../spikes/s4/results/N1_doom/packed_output.json"),
            include_str!("../../../spikes/s4/results/N1_doom/program_output.json"),
            include_str!("../../../spikes/s4/results/N1_doom/verifier_output.json"),
        );
    }

    #[test]
    fn reproduces_the_s4_run_with_two_leaves() {
        check(
            include_str!("../../../spikes/s4/results/N2_doom/packed_output.json"),
            include_str!("../../../spikes/s4/results/N2_doom/program_output.json"),
            include_str!("../../../spikes/s4/results/N2_doom/verifier_output.json"),
        );
    }

    /// N = 3 exercises the odd-entry carry.
    #[test]
    fn reproduces_the_s4_run_with_three_leaves() {
        check(
            include_str!("../../../spikes/s4/results/N3_doom/packed_output.json"),
            include_str!("../../../spikes/s4/results/N3_doom/program_output.json"),
            include_str!("../../../spikes/s4/results/N3_doom/verifier_output.json"),
        );
    }

    #[test]
    fn reproduces_the_s4_run_with_four_leaves() {
        check(
            include_str!("../../../spikes/s4/results/N4_doom/packed_output.json"),
            include_str!("../../../spikes/s4/results/N4_doom/program_output.json"),
            include_str!("../../../spikes/s4/results/N4_doom/verifier_output.json"),
        );
    }

    #[test]
    fn the_fold_order_matters() {
        let packed: serde_json::Value =
            serde_json::from_str(include_str!("../../../spikes/s4/results/N2_doom/packed_output.json"))
                .unwrap();
        let (mut preimages, leaf_hash, mv_hash) = parse_packed_output(&packed).unwrap();
        let straight = root_from_preimages(&preimages, leaf_hash, mv_hash).unwrap();
        preimages.reverse();
        let reversed = root_from_preimages(&preimages, leaf_hash, mv_hash).unwrap();
        assert_ne!(straight, reversed, "swapping two leaves must change the root");
    }
}
