// SPDX-License-Identifier: Apache-2.0
//! S11 candidate only: tagged BLAKE2s-256 over exact nine-byte felt encodings.
use core::blake::{blake2s_compress, blake2s_finalize};
use core::box::BoxTrait;
use core::traits::DivRem;

const IV: [u32; 8] = [
    0x6B08E647, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A, 0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19,
];
const TWO72: u128 = 0x1000000000000000000;

/// Exact BLAKE2s-256 compression/finalization from core, including partial
/// final u32. The supplied words have zero unused bytes and total_bytes is
/// the unpadded message length. A full last block is finalized, never followed
/// by a spurious zero block.
fn digest_words(mut words: Span<u32>, total_bytes: u32) -> [u32; 8] {
    let mut state = BoxTrait::new(IV);
    let mut count = 0;
    while words.len() > 16 {
        let message = words.multi_pop_front::<16>().unwrap();
        count += 64;
        state = blake2s_compress(state, count, *message);
    }
    let n = words.len();
    let mut last = array![];
    last.append_span(words);
    for _ in n..16 {
        last.append(0);
    }
    blake2s_finalize(state, total_bytes, *last.span().try_into().unwrap()).unbox()
}

/// Header: ASCII domain[16], schema u32LE=2, encoding u32LE=1, n u64LE.
/// Every input felt, including the existing schema header, follows as 9LE.
/// Returns None on values outside the explicitly supported <2^72 domain.
pub fn digest(mut data: Span<felt252>) -> Option<[u32; 8]> {
    let n = data.len();
    // core's byte counter is u32; checked before length arithmetic.
    if n > 477218584 {
        return Option::None;
    }
    let mut words: Array<u32> = array![0x532e5048, 0x45544154, 0x5332422e, 0x39, 2, 1, n, 0];
    let mut carry: u128 = 0;
    let mut factor: u128 = 1;
    while let Option::Some(value) = data.pop_front() {
        let x: u128 = (*value).try_into()?;
        if x >= TWO72 {
            return Option::None;
        }
        // At most 72+24=96 bits, strictly within u128.
        let packed = x * factor + carry;
        let (upper, lower) = DivRem::div_rem(packed, 0x10000000000000000);
        let (w1, w0) = DivRem::div_rem(lower, 0x100000000);
        words.append(w0.try_into().unwrap());
        words.append(w1.try_into().unwrap());
        if factor == 0x1000000 {
            words.append(upper.try_into().unwrap());
            carry = 0;
            factor = 1;
        } else {
            carry = upper;
            factor *= 256;
        }
    }
    if factor != 1 {
        words.append(carry.try_into().unwrap());
    }
    Option::Some(digest_words(words.span(), 32 + n * 9))
}

/// All 256 digest bits participate. Field arithmetic implements integer
/// little-endian reduction mod p, rather than truncating high digest bits.
pub fn reduce(digest: [u32; 8]) -> felt252 {
    let [d0, d1, d2, d3, d4, d5, d6, d7] = digest;
    let base: felt252 = 0x100000000;
    ((((((d7.into() * base + d6.into()) * base + d5.into()) * base + d4.into()) * base + d3.into())
        * base
        + d2.into())
        * base
        + d1.into())
        * base
        + d0.into()
}

pub fn hash(data: Span<felt252>) -> Option<felt252> {
    Option::Some(reduce(digest(data)?))
}
