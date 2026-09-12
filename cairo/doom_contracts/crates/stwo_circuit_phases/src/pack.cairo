// SPDX-License-Identifier: Apache-2.0
//! Packed transport of proof sections: 7 little-endian u32 limbs per felt252 slot.
//! A limb of `0xFFFFFFFF` escapes a `(low, high)` u64 pair (the two PoW nonces).
//! Mirrors `tools/emit_calldata.py::pack`.

pub const ESCAPE: u32 = 0xFFFFFFFF;

/// Decodes `packed` (7 u32 limbs per slot) into `n_values` felt252 values.
pub fn unpack(packed: Span<felt252>, n_values: u32) -> Array<felt252> {
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

/// Encodes `values` as 7 u32 limbs per slot (the inverse of `unpack`); values >= 2^32 (< 2^64)
/// take the 3-limb escape. Test/tooling helper: the client packs off-chain.
pub fn pack(values: Span<felt252>) -> Array<felt252> {
    let mut limbs: Array<felt252> = array![];
    for v in values {
        let v256: u256 = (*v).into();
        if v256 < 0x100000000 {
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
    let mut slots: Array<felt252> = array![];
    let mut limbs = limbs.span();
    while !limbs.is_empty() {
        let mut slot: felt252 = 0;
        let mut mult: felt252 = 1;
        for _ in 0..7_u32 {
            match limbs.pop_front() {
                Some(l) => { slot += *l * mult; },
                None => {},
            }
            mult *= 0x100000000;
        }
        slots.append(slot);
    }
    slots
}
