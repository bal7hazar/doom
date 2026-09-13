// SPDX-License-Identifier: Apache-2.0
//! Typed decoding of the fast-path packed sections (7 little-endian u32 limbs per felt252,
//! `pack.cairo`) straight into the verifier's types — one pass, no intermediate felt array, no
//! cairo-serde (P4.1 lever 3/5).
//!
//! Range checks are what Starknet bills (1 600 gas each, the binding VM resource): the P4.0
//! path cost 3 per value to unpack (`deconstruct_f252`: 6 bounded divisions per slot) plus 2–3
//! per value to deserialize (`felt252 -> u32 -> M31`). Here a slot is split once (`felt252 ->
//! u256`, 3 range checks), its limbs isolated with the bitwise builtin (free while it is not
//! the binding resource) and exact divisions by 2^32 in the field (multiples of 2^32 divide
//! exactly), re-typed as `u128` where needed (1 range check each: 5 per slot), and every value
//! is then typed with a single range check (`u128 -> M31` constrain, `u128 -> u32` downcast):
//! 8 range checks per slot + 1 per value ≈ 2.1 per value.
//!
//! Soundness: a slot is a canonical integer below the prime (`u256_from_felt252`); the seven
//! limbs are the unique base-2^32 digits of its low 224 bits provided the value is below 2^224,
//! which the last limb's typing check (`< 2^32`) enforces; every value is range-checked to its
//! type exactly as the cairo-serde deserialization did (`M31`: `< P`; words: `< 2^32`).
//! Decoding is therefore a function of the slots: a Poseidon digest of the slots binds the
//! decoded values (`machine.cairo`: `d_sampled`, `d_queried`).
use bounded_int::{BoundedInt, ConstrainHelper, constrain};
use stwo_verifier_core::fields::m31::{M31, M31InnerT, M31Trait, P};
use stwo_verifier_core::fields::qm31::{QM31, QM31Trait};
use stwo_verifier_core::fri::FriLayerProof;
use stwo_verifier_core::vcs::blake2s_hasher::{Blake2sHash, Blake2sMerkleHasher};
use stwo_verifier_core::vcs::verifier::MerkleDecommitment;
use crate::pack::n_slots;

/// `2^-32 mod PRIME`: exact division of a multiple of 2^32 in the field.
const INV_2_32: felt252 = 0x7fffffff8000010ffffffef0000000000000000000000000000000000000001;
const MASK_32: u128 = 0xffffffff;

impl U128ConstrainP of ConstrainHelper<u128, P> {
    type LowT = M31InnerT;
    type HighT = BoundedInt<P, 0xffffffffffffffffffffffffffffffff>;
}

/// The 7 limbs of every slot, each a `u128` below 2^32 (the last limb of a slot is below 2^32
/// only if the slot is below 2^224; a larger slot makes it larger and fails the typing of the
/// value read from it — the reader panics, as the P4.0 `unpack: slot overflow` did).
/// `n_values` limbs are kept (the zero padding of the last slot is dropped); panics if
/// `packed` does not hold exactly `n_slots(n_values)` slots.
pub fn unpack_limbs(packed: Span<felt252>, n_values: u32) -> Span<u128> {
    assert!(packed.len() == n_slots(n_values), "unpack: slot count");
    let mut limbs: Array<u128> = array![];
    for slot in packed {
        let u256 { low, high } = (*slot).into();
        // low = l0 + l1 2^32 + l2 2^64 + l3 2^96
        let l0 = low & MASK_32;
        let r1: u128 = ((low - l0).into() * INV_2_32).try_into().unwrap();
        let l1 = r1 & MASK_32;
        let r2: u128 = ((r1 - l1).into() * INV_2_32).try_into().unwrap();
        let l2 = r2 & MASK_32;
        let l3: u128 = ((r2 - l2).into() * INV_2_32).try_into().unwrap();
        // high = l4 + l5 2^32 + l6 2^64 (+ l7 2^96, which must be zero)
        let l4 = high & MASK_32;
        let r5: u128 = ((high - l4).into() * INV_2_32).try_into().unwrap();
        let l5 = r5 & MASK_32;
        let l6: u128 = ((r5 - l5).into() * INV_2_32).try_into().unwrap();
        limbs.append(l0);
        limbs.append(l1);
        limbs.append(l2);
        limbs.append(l3);
        limbs.append(l4);
        limbs.append(l5);
        limbs.append(l6);
    }
    limbs.span().slice(0, n_values)
}

/// A u32 word (a length prefix, a hash word).
#[inline]
pub fn read_u32(ref limbs: Span<u128>) -> u32 {
    (*limbs.pop_front().expect('decode: short')).try_into().expect('decode: not a u32')
}

/// An M31 value (range-checked below P, as the cairo-serde `M31` deserialization).
#[inline]
pub fn read_m31(ref limbs: Span<u128>) -> M31 {
    match constrain::<u128, P>(*limbs.pop_front().expect('decode: short')) {
        Ok(inner) => M31Trait::new(inner),
        Err(_) => core::panic_with_felt252('decode: not an M31'),
    }
}

#[inline]
pub fn read_qm31(ref limbs: Span<u128>) -> QM31 {
    let a = read_m31(ref limbs);
    let b = read_m31(ref limbs);
    let c = read_m31(ref limbs);
    let d = read_m31(ref limbs);
    QM31Trait::from_fixed_array([a, b, c, d])
}

#[inline]
pub fn read_hash(ref limbs: Span<u128>) -> Blake2sHash {
    let w0 = read_u32(ref limbs);
    let w1 = read_u32(ref limbs);
    let w2 = read_u32(ref limbs);
    let w3 = read_u32(ref limbs);
    let w4 = read_u32(ref limbs);
    let w5 = read_u32(ref limbs);
    let w6 = read_u32(ref limbs);
    let w7 = read_u32(ref limbs);
    Blake2sHash { hash: BoxTrait::new([w0, w1, w2, w3, w4, w5, w6, w7]) }
}

/// cairo-serde `Span<M31>`: length prefix then the values.
pub fn read_m31_span(ref limbs: Span<u128>) -> Span<M31> {
    let n = read_u32(ref limbs);
    let mut out = array![];
    for _ in 0..n {
        out.append(read_m31(ref limbs));
    }
    out.span()
}

/// cairo-serde `Span<Hash>`.
pub fn read_hash_span(ref limbs: Span<u128>) -> Span<Blake2sHash> {
    let n = read_u32(ref limbs);
    let mut out = array![];
    for _ in 0..n {
        out.append(read_hash(ref limbs));
    }
    out.span()
}

/// cairo-serde `MerkleDecommitment<Blake2sMerkleHasher>`.
pub fn read_decommitment(ref limbs: Span<u128>) -> MerkleDecommitment<Blake2sMerkleHasher> {
    MerkleDecommitment { hash_witness: read_hash_span(ref limbs) }
}

/// cairo-serde `Span<Span<Span<QM31>>>` (the sampled values: per tree, per column, the mask).
pub fn read_sampled_values(ref limbs: Span<u128>) -> Span<Span<Span<QM31>>> {
    let n_trees = read_u32(ref limbs);
    let mut trees = array![];
    for _ in 0..n_trees {
        let n_columns = read_u32(ref limbs);
        let mut columns = array![];
        for _ in 0..n_columns {
            let n_samples = read_u32(ref limbs);
            let mut samples = array![];
            for _ in 0..n_samples {
                samples.append(read_qm31(ref limbs));
            }
            columns.append(samples.span());
        }
        trees.append(columns.span());
    }
    trees.span()
}

/// cairo-serde `Array<FriLayerProof>`: per layer `fri_witness` (`Span<QM31>`), `decommitment`
/// (`Span<Hash>`), `commitment` (`Hash`).
pub fn read_fri_layers(ref limbs: Span<u128>) -> Array<FriLayerProof> {
    let n_layers = read_u32(ref limbs);
    let mut layers = array![];
    for _ in 0..n_layers {
        let n_witness = read_u32(ref limbs);
        let mut fri_witness = array![];
        for _ in 0..n_witness {
            fri_witness.append(read_qm31(ref limbs));
        }
        let decommitment = read_decommitment(ref limbs);
        let commitment = read_hash(ref limbs);
        layers.append(FriLayerProof { fri_witness: fri_witness.span(), decommitment, commitment });
    }
    layers
}

/// Asserts a section was consumed exactly.
pub fn end(limbs: Span<u128>) {
    assert(limbs.is_empty(), 'decode: trailing data');
}
