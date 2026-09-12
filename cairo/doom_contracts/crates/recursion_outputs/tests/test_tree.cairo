// SPDX-License-Identifier: Apache-2.0
//! Tests against the monorepo's committed goldens (proving @ cd7bc5f,
//! `crates/stwo_run_and_prove_recursive_tree/test_data/goldens/four_leaves/`) and its unit-test
//! vectors. Our own N = 1..4 pipeline fixtures are in `fixtures.cairo` (generated).
use recursion_outputs::blake::hash_u32s;
use recursion_outputs::encode::{encode_felts, felt_to_u32_limbs};
use recursion_outputs::tree::{Node, fold_pair, fold_tree, leaf_node, leaf_output, root_output_hash};

/// `simple_output_compiled.json`'s Blake program hash (golden `leaf_preimage.json[0]`).
const GOLDEN_PROGRAM_HASH: felt252 =
    1433852663250257978909904594223798547176815246431631498282706690602142197827;

fn golden_preimage() -> Span<felt252> {
    array![GOLDEN_PROGRAM_HASH, 11, 13, 17].span()
}

/// `root_packed.json`: the leaf circuit hash (canonical_small registry, pow 16) ...
fn golden_leaf_hash() -> [u32; 8] {
    [3537394242, 2036955938, 977379425, 18658195, 2047086281, 1158214858, 1109627913, 1626585834]
}

/// ... and the multiverifier circuit hash (production shape).
fn golden_mv_hash() -> [u32; 8] {
    [2778240789, 595050618, 3335645252, 1425055821, 2347129469, 4252222049, 2423842600, 2537515023]
}

#[test]
fn blake2s_empty_and_known_vectors() {
    // blake2s-256("") = 69217a30 79908094 e1116932 5c9dda37 ... (RFC 7693 test vector), LE words.
    let empty = hash_u32s(array![].span());
    assert_eq!(*empty.span()[0], 0x307a2169);
    assert_eq!(*empty.span()[1], 0x94809079);
}

#[test]
fn felt_limbs_are_little_endian() {
    let limbs = felt_to_u32_limbs(0x1_0000_0002);
    assert_eq!(limbs, [2, 1, 0, 0, 0, 0, 0, 0]);
}

#[test]
fn encoding_small_and_big_felts() {
    // Small (< 2^63): [high, low].
    let words = encode_felts(array![0x1_0000_0002].span());
    assert_eq!(words.span(), array![1, 2].span());
    // 2^63 is big: 8 words, MSB flag on the first.
    let words = encode_felts(array![0x8000_0000_0000_0000].span());
    assert_eq!(words.span(), array![0x80000000, 0, 0, 0, 0, 0, 0x80000000, 0].span());
}

/// `test_leaf_output_values_derived_from_preimage` in the recursive tree crate.
#[test]
fn leaf_output_matches_upstream_vector() {
    let h1 = leaf_output(golden_preimage());
    assert_eq!(
        h1,
        [
            1603116091, 3258597502, 2711032228, 4175407283, 343882323, 1898618121, 1344732087,
            1064799167,
        ],
    );
}

/// The golden `root_outputs.json`: four identical leaves folded two-to-one, two layers.
#[test]
fn golden_four_leaves_root_outputs() {
    let leaf = leaf_node(golden_leaf_hash(), golden_preimage());
    let root = fold_tree(array![leaf, leaf, leaf, leaf].span(), golden_mv_hash());
    assert_eq!(root.circuit_hash, golden_mv_hash());
    assert_eq!(
        root.output,
        [
            897652633, 1382572116, 3969946465, 347296500, 2153515991, 2472657789, 1975506022,
            3786147232,
        ],
    );
}

/// Manual fold of the same tree, to pin the topology (pairs (0,1) and (2,3), then the two).
#[test]
fn golden_four_leaves_manual_topology() {
    let leaf = leaf_node(golden_leaf_hash(), golden_preimage());
    let mid = fold_pair(@leaf, @leaf, golden_mv_hash());
    let root = fold_pair(@mid, @mid, golden_mv_hash());
    assert_eq!(root, fold_tree(array![leaf, leaf, leaf, leaf].span(), golden_mv_hash()));
}

/// Odd carry: with three leaves the third is carried to layer 2 unchanged.
#[test]
fn three_leaves_carry_topology() {
    let leaf = leaf_node(golden_leaf_hash(), golden_preimage());
    let other = Node { circuit_hash: golden_leaf_hash(), output: [1, 2, 3, 4, 5, 6, 7, 8] };
    let expected = fold_pair(@fold_pair(@leaf, @leaf, golden_mv_hash()), @other, golden_mv_hash());
    assert_eq!(fold_tree(array![leaf, leaf, other].span(), golden_mv_hash()), expected);
}

/// Single leaf: self-fold (the same node in both multiverifier slots).
#[test]
fn single_leaf_self_fold() {
    let leaf = leaf_node(golden_leaf_hash(), golden_preimage());
    assert_eq!(
        fold_tree(array![leaf].span(), golden_mv_hash()), fold_pair(@leaf, @leaf, golden_mv_hash()),
    );
}

#[test]
fn root_output_hash_is_deterministic_and_order_sensitive() {
    let a = array![GOLDEN_PROGRAM_HASH, 1, 2, 250, 1].span();
    let b = array![GOLDEN_PROGRAM_HASH, 2, 3, 251, 1].span();
    let ab = root_output_hash(array![a, b].span(), golden_leaf_hash(), golden_mv_hash());
    let ba = root_output_hash(array![b, a].span(), golden_leaf_hash(), golden_mv_hash());
    assert_eq!(ab, root_output_hash(array![a, b].span(), golden_leaf_hash(), golden_mv_hash()));
    assert_ne!(ab, ba);
}

/// D4 (S4b): switching the task's `program_hash_function` from blake to poseidon changes nothing
/// in this library — the leaf bootloader's preimage keeps its shape, `[program_hash,
/// outputs…]`, and only `preimage[0]` changes value. Both hashes below are the ones the leaf
/// bootloader actually dumped for `segment_stub` (`results/N2_doom/` and
/// `results/N2_doom_poseidon/`), and the matching root hashes are pinned by
/// `fixtures::fixture_n2_doom{,_poseidon}`.
///
/// The consequence for the consumer contract: the program hash it pins per season is the one of
/// the *chosen* hash function; a root proved with the other one recomposes to a different
/// `output_hash` and must be rejected.
#[test]
fn program_hash_function_binds_the_root() {
    const BLAKE_PROGRAM_HASH: felt252 =
        2784737126826178369939993031080194949960354326733421464854849544232566095676;
    const POSEIDON_PROGRAM_HASH: felt252 =
        3123429690541791732247651535885863506882260532123250961348241600396459994871;
    let outputs = array![
        1, 2171758236178030472946753621190837933414225933392145722773936413471492471342, 250, 1,
    ];
    let mut blake_preimage = array![BLAKE_PROGRAM_HASH];
    blake_preimage.append_span(outputs.span());
    let mut poseidon_preimage = array![POSEIDON_PROGRAM_HASH];
    poseidon_preimage.append_span(outputs.span());
    assert_ne!(leaf_output(blake_preimage.span()), leaf_output(poseidon_preimage.span()));
    assert_ne!(
        root_output_hash(
            array![blake_preimage.span()].span(), golden_leaf_hash(), golden_mv_hash(),
        ),
        root_output_hash(
            array![poseidon_preimage.span()].span(), golden_leaf_hash(), golden_mv_hash(),
        ),
    );
}
