// SPDX-License-Identifier: Apache-2.0
//! Packing round-trips and the unpack cost on a real transaction payload (the `begin` tx's
//! trees 0/1 = ~4 300 slots). `bench_unpack_u128_divmod` is the first implementation
//! (u256/u128 divmod + a second pass), kept here as the cost reference.
use stwo_circuit_phases::pack::{ESCAPE, n_slots, pack, pack_u32, unpack, unpack_u32};
use stwo_circuit_phases::sections::split;
use super::fixture::load_proof;

/// Trees 0 and 1 (queried values + decommitments): escape-free, 4 334 slots.
fn trees01_values() -> Array<felt252> {
    let sec = split(load_proof().span());
    let mut flat = array![];
    flat.append_span(sec.queried_values.at(0).span());
    flat.append_span(sec.decommitments.at(0).span());
    flat.append_span(sec.queried_values.at(1).span());
    flat.append_span(sec.decommitments.at(1).span());
    flat
}

/// The first `unpack` (u256 → u128 divmod, intermediate limb array), for the cost comparison.
fn unpack_u128_divmod(packed: Span<felt252>, n_values: u32) -> Array<felt252> {
    let nz32: NonZero<u128> = 0x100000000_u128.try_into().unwrap();
    let mut limbs: Array<u32> = array![];
    for slot in packed {
        let v: u256 = (*slot).into();
        let (q, l0) = DivRem::div_rem(v.low, nz32);
        let (q, l1) = DivRem::div_rem(q, nz32);
        let (l3, l2) = DivRem::div_rem(q, nz32);
        let (q, l4) = DivRem::div_rem(v.high, nz32);
        let (l6, l5) = DivRem::div_rem(q, nz32);
        limbs.append(l0.try_into().unwrap());
        limbs.append(l1.try_into().unwrap());
        limbs.append(l2.try_into().unwrap());
        limbs.append(l3.try_into().unwrap());
        limbs.append(l4.try_into().unwrap());
        limbs.append(l5.try_into().unwrap());
        limbs.append(l6.try_into().unwrap());
    }
    let limbs = limbs.span();
    let mut values: Array<felt252> = array![];
    let mut i: usize = 0;
    while values.len() != n_values {
        let limb = *limbs[i];
        if limb == ESCAPE {
            let lo: felt252 = (*limbs[i + 1]).into();
            let hi: felt252 = (*limbs[i + 2]).into();
            values.append(lo + hi * 0x100000000);
            i += 3;
        } else {
            values.append(limb.into());
            i += 1;
        }
    }
    values
}

fn first_mismatch(a: Span<felt252>, b: Span<felt252>) -> Option<u32> {
    let mut i = 0;
    let mut r = None;
    while i < a.len() && i < b.len() {
        if *a.at(i) != *b.at(i) {
            r = Some(i);
            break;
        }
        i += 1;
    }
    r
}

#[test]
fn pack_roundtrip_whole_proof() {
    let values = load_proof();
    let packed = pack(values.span());
    assert!(packed.len() == 13720, "13720 slots (2 escapes)");
    let back = unpack(packed.span(), values.len());
    assert!(back.len() == values.len(), "length");
    assert!(first_mismatch(back.span(), values.span()).is_none(), "roundtrip");
}

#[test]
fn pack_u32_roundtrip_section() {
    let values = trees01_values();
    let packed = pack_u32(values.span());
    assert!(packed.len() == n_slots(values.len()), "slot count");
    let back = unpack_u32(packed.span(), values.len());
    assert!(back.len() == values.len(), "length");
    assert!(first_mismatch(back, values.span()).is_none(), "roundtrip");
}

#[test]
fn pack_escapes_u64_and_escape_marker() {
    let values = array![1, 0xFFFFFFFF, 0x100000000, 0xFFFFFFFFFFFFFFFF, 7, 0, 0x123456789ab, 0xFFFFFFFE];
    let packed = pack(values.span());
    assert!(unpack(packed.span(), values.len()) == values, "escape roundtrip");
}

#[test]
#[should_panic(expected: "pack_u32: value >= 2^32")]
fn pack_u32_rejects_wide_values() {
    pack_u32(array![1, 0x100000000].span());
}

#[test]
fn bench_0_payload_only() {
    let values = trees01_values();
    let packed = pack_u32(values.span());
    assert!(packed.len() > 4000);
}

#[test]
fn bench_unpack_u32_fast_path() {
    let values = trees01_values();
    let packed = pack_u32(values.span());
    let back = unpack_u32(packed.span(), values.len());
    assert!(back.len() == values.len());
}

#[test]
fn bench_unpack_escaped_single_pass() {
    let values = trees01_values();
    let packed = pack_u32(values.span());
    let back = unpack(packed.span(), values.len());
    assert!(back.len() == values.len());
}

#[test]
fn bench_unpack_u128_divmod() {
    let values = trees01_values();
    let packed = pack_u32(values.span());
    let back = unpack_u128_divmod(packed.span(), values.len());
    assert!(back.len() == values.len());
}
