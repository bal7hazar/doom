// SPDX-License-Identifier: Apache-2.0
//! Blake2s-256 over a list of u32 words, each word contributing its 4 little-endian bytes —
//! the `blake2s_u32s` of the circuits crate and `stwo_verifier_utils::blake2s::hash_u32s` of the
//! on-chain verifier (mirrored from the latter, Apache-2.0, starkware-libs/proving @ cd7bc5f).
use core::blake::{blake2s_compress, blake2s_finalize};
use core::box::BoxTrait;

pub const BLAKE2S_256_INITIAL_STATE: [u32; 8] = [
    0x6B08E647, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A, 0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19,
];

/// `blake2s(le_bytes(values))`, digest as eight little-endian u32 words.
pub fn hash_u32s(mut values: Span<u32>) -> [u32; 8] {
    let mut state = BoxTrait::new(BLAKE2S_256_INITIAL_STATE);
    let mut byte_count = 0;
    if let Some(mut msg) = values.multi_pop_front::<16>() {
        byte_count += 64;
        while let Some(head) = values.multi_pop_front::<16>() {
            state = blake2s_compress(state, byte_count, *msg);
            msg = head;
            byte_count += 64;
        }
        if values.is_empty() {
            return blake2s_finalize(state, byte_count, *msg).unbox();
        }
        state = blake2s_compress(state, byte_count, *msg);
    }
    // Pad the remaining values to a full 16-word block and finalize on it.
    let mut msg = array![];
    let i = values.len();
    msg.append_span(values);
    for _ in i..16 {
        msg.append(0);
    }
    byte_count += i * 4;
    blake2s_finalize(state, byte_count, *msg.span().try_into().unwrap()).unbox()
}

/// Appends the eight words of a digest to `out`.
pub fn append_digest(ref out: Array<u32>, digest: @[u32; 8]) {
    let [d0, d1, d2, d3, d4, d5, d6, d7] = *digest;
    out.append(d0);
    out.append(d1);
    out.append(d2);
    out.append(d3);
    out.append(d4);
    out.append(d5);
    out.append(d6);
    out.append(d7);
}
