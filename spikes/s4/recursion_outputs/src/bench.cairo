//! Step-cost bench: `scarb execute --executable-name bench --arguments <N> --print-resource-usage`.
//! Folds N synthetic segment leaves whose preimage has the shape of our segments
//! (`[program_hash, h_in, h_out, n, status]`: three "big" felts encoded on 8 words, two small
//! ones on 2 words) and returns the root `VerificationOutput.output_hash`.
use crate::tree::root_output_hash;

const PROGRAM_HASH: felt252 = 0x6289a6a7b6a5c53ddb4d4a3c1e0ea4c6e7c8a4dbe5d5f29a5e4b22a1d0f5c3c;
const GENESIS: felt252 = 0x4cd2a0e6a1b3f8e2d9c7b5a3918f7e6d5c4b3a291807f6e5d4c3b2a190807f6;

#[executable]
pub fn main(n: u32) -> Array<u32> {
    let leaf_hash: [u32; 8] = [1, 2, 3, 4, 5, 6, 7, 8];
    let mv_hash: [u32; 8] = [9, 10, 11, 12, 13, 14, 15, 16];
    let mut preimages: Array<Span<felt252>> = array![];
    let mut h_in = GENESIS;
    let mut i: u32 = 0;
    while i < n {
        let h_out = h_in * 3 + 1;
        preimages.append(array![PROGRAM_HASH, h_in, h_out, (250 + i).into(), 1].span());
        h_in = h_out;
        i += 1;
    }
    let [d0, d1, d2, d3, d4, d5, d6, d7] = root_output_hash(preimages.span(), leaf_hash, mv_hash);
    array![d0, d1, d2, d3, d4, d5, d6, d7]
}
