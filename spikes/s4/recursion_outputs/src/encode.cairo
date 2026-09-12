//! The Cairo0 "encode_felt252_data" word encoding the leaf simple bootloader hashes its output
//! preimage with (`starknet_types_core::hash::Blake2Felt252::encode_felts_to_u32s`,
//! `stwo_verifier_utils::blake2s::encode_felt_in_limbs_to_array`):
//! - a felt `< 2^63` becomes 2 words `[high, low]` of its low 64 bits (big-endian word order);
//! - any other felt becomes its 8 big-endian u32 words with the MSB of the first word set.
use core::traits::DivRem;

const MSB_U32: u32 = 0x80000000;
const TWO_POW_32: u128 = 0x100000000;

/// The eight u32 limbs of a felt, little-endian (limb 0 is the least significant).
pub fn felt_to_u32_limbs(x: felt252) -> [u32; 8] {
    let v: u256 = x.into();
    let nz: NonZero<u128> = TWO_POW_32.try_into().unwrap();
    let (q, w0) = DivRem::div_rem(v.low, nz);
    let (q, w1) = DivRem::div_rem(q, nz);
    let (w3, w2) = DivRem::div_rem(q, nz);
    let (q, w4) = DivRem::div_rem(v.high, nz);
    let (q, w5) = DivRem::div_rem(q, nz);
    let (w7, w6) = DivRem::div_rem(q, nz);
    [
        w0.try_into().unwrap(), w1.try_into().unwrap(), w2.try_into().unwrap(),
        w3.try_into().unwrap(), w4.try_into().unwrap(), w5.try_into().unwrap(),
        w6.try_into().unwrap(), w7.try_into().unwrap(),
    ]
}

/// Appends the encoding of one felt to `out`.
pub fn encode_felt(x: felt252, ref out: Array<u32>) {
    let [v0, v1, v2, v3, v4, v5, v6, v7] = felt_to_u32_limbs(x);
    if v2 == 0 && v3 == 0 && v4 == 0 && v5 == 0 && v6 == 0 && v7 == 0 && v1 < MSB_U32 {
        out.append(v1);
        out.append(v0);
    } else {
        out.append(v7 + MSB_U32);
        out.append(v6);
        out.append(v5);
        out.append(v4);
        out.append(v3);
        out.append(v2);
        out.append(v1);
        out.append(v0);
    }
}

/// The word encoding of a felt list (the bytes `H1` is computed over).
pub fn encode_felts(mut felts: Span<felt252>) -> Array<u32> {
    let mut out = array![];
    for x in felts {
        encode_felt(*x, ref out);
    }
    out
}
