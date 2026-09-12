// SPDX-License-Identifier: Apache-2.0
//! Test helpers: the S4 root proof (N = 4, `spikes/s4/results/N4_doom`) as a felt stream.
use snforge_std::fs::{FileTrait, read_txt};

/// Number of felts in the fixture stream.
pub const N4_N_FELTS: u32 = 96033;

/// Expected `output_hash` of the fixture (spikes/s4/results/N4_doom/verifier_output.json).
pub fn n4_expected_output_hash() -> [u32; 8] {
    [3123785184, 3718676270, 1469581383, 660429404, 3277334853, 1494218902, 3817731027, 3170188775]
}

/// Loads `fixtures/n4_root_proof.txt` (decompress with `fixtures/unpack.sh` first).
pub fn load_n4_proof() -> Array<felt252> {
    let file = FileTrait::new("../../fixtures/n4_root_proof.txt");
    let values = read_txt(@file);
    assert!(values.len() == N4_N_FELTS, "fixture length");
    values
}
