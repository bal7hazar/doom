// SPDX-License-Identifier: Apache-2.0
//! Packed transport of proof sections: 7 little-endian u32 limbs per felt252 slot.
//! Mirrors `tools/emit_calldata.py`.
//!
//! Two encodings:
//! - `unpack_u32` (fast path): every value is a u32 (M31 values, blake2s words, lengths). Used
//!   for every section but the head. One `deconstruct_f252` and 7 appends per slot.
//! - `unpack` (escaped): a limb of `0xFFFFFFFF` escapes a `(low, high)` u64 pair — the two
//!   proof-of-work nonces of the head; a plain value >= 0xFFFFFFFF is escaped too.
//!
//! Unpacking is on the hot path of every transaction (~4 600 slots): it uses the vendored
//! `deconstruct_f252` (bounded-int `div_rem` by 2^32) and a single pass; the first version
//! (u128 divmod + an intermediate limb array + a second pass) cost ~80 k gas per slot on devnet
//! (docs/design §7).
use stwo_verifier_utils::deconstruct_f252;

pub const ESCAPE: u32 = 0xFFFFFFFF;
const SHIFT_32: felt252 = 0x100000000;

/// Number of slots a section of `n_values` escape-free values occupies.
pub fn n_slots(n_values: u32) -> u32 {
    (n_values + 6) / 7
}

/// Fast path: decodes `packed` into `n_values` felts, every limb being one value (no escapes).
/// The zero padding of the last slot is dropped.
pub fn unpack_u32(packed: Span<felt252>, n_values: u32) -> Span<felt252> {
    assert!(packed.len() == n_slots(n_values), "unpack: slot count");
    let mut values: Array<felt252> = array![];
    for slot in packed {
        let [l0, l1, l2, l3, l4, l5, l6, l7] = deconstruct_f252(*slot).unbox();
        assert!(l7 == 0, "unpack: slot overflow");
        values.append(l0.into());
        values.append(l1.into());
        values.append(l2.into());
        values.append(l3.into());
        values.append(l4.into());
        values.append(l5.into());
        values.append(l6.into());
    }
    values.span().slice(0, n_values)
}

/// Escaped decoding: `n_values` felts; values >= 2^32 (< 2^64) arrive as `ESCAPE, low, high`.
pub fn unpack(packed: Span<felt252>, n_values: u32) -> Array<felt252> {
    let mut values: Array<felt252> = array![];
    // 0: plain; 1: an escape was seen, the next limb is `low`; 2: `low` is held, next is `high`.
    let mut pending: u8 = 0;
    let mut low: felt252 = 0;
    for slot in packed {
        let [l0, l1, l2, l3, l4, l5, l6, _] = deconstruct_f252(*slot).unbox();
        push_limb(ref values, ref pending, ref low, l0);
        push_limb(ref values, ref pending, ref low, l1);
        push_limb(ref values, ref pending, ref low, l2);
        push_limb(ref values, ref pending, ref low, l3);
        push_limb(ref values, ref pending, ref low, l4);
        push_limb(ref values, ref pending, ref low, l5);
        push_limb(ref values, ref pending, ref low, l6);
    }
    assert!(pending == 0, "unpack: truncated escape");
    assert!(values.len() >= n_values, "unpack: short payload");
    // Drop the padding (the trailing zeros of the last slot).
    let mut out = array![];
    out.append_span(values.span().slice(0, n_values));
    out
}

#[inline(always)]
fn push_limb(ref values: Array<felt252>, ref pending: u8, ref low: felt252, limb: u32) {
    if pending == 0 {
        if limb == ESCAPE {
            pending = 1;
        } else {
            values.append(limb.into());
        }
    } else if pending == 1 {
        low = limb.into();
        pending = 2;
    } else {
        let high: felt252 = limb.into();
        values.append(low + high * SHIFT_32);
        pending = 0;
    }
}

/// Escaped encoding (the inverse of `unpack`). Test/tooling helper: the client packs off-chain.
pub fn pack(values: Span<felt252>) -> Array<felt252> {
    let mut limbs: Array<felt252> = array![];
    for v in values {
        let v256: u256 = (*v).into();
        if v256 < ESCAPE.into() {
            limbs.append(*v);
        } else {
            assert!(v256 < 0x10000000000000000, "pack: value does not fit the u64 escape");
            let nz32: NonZero<u128> = 0x100000000_u128.try_into().unwrap();
            let (hi, lo) = DivRem::div_rem(v256.low, nz32);
            limbs.append(ESCAPE.into());
            limbs.append(lo.into());
            limbs.append(hi.into());
        }
    }
    pack_limbs(limbs.span())
}

/// Fast-path encoding (the inverse of `unpack_u32`): every value must be < 2^32.
pub fn pack_u32(values: Span<felt252>) -> Array<felt252> {
    for v in values {
        let v256: u256 = (*v).into();
        assert!(v256 < 0x100000000, "pack_u32: value >= 2^32");
    }
    pack_limbs(values)
}

fn pack_limbs(mut limbs: Span<felt252>) -> Array<felt252> {
    let mut slots: Array<felt252> = array![];
    while !limbs.is_empty() {
        let mut slot: felt252 = 0;
        let mut mult: felt252 = 1;
        for _ in 0..7_u32 {
            match limbs.pop_front() {
                Some(l) => { slot += *l * mult; },
                None => {},
            }
            mult *= SHIFT_32;
        }
        slots.append(slot);
    }
    slots
}
