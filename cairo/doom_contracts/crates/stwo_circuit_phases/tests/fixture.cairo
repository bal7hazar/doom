// SPDX-License-Identifier: Apache-2.0
//! Test fixtures: real root proofs of the recursive tree as felt streams (`fixtures/*.txt`,
//! decompress with `fixtures/unpack.sh`). The fixture is selected by the number in
//! `fixtures/selected.txt` (`tools/check_registry.sh` switches it) so that the same suite
//! validates a regenerated constant set — the constants are compile-time, so only one registry
//! can be tested per build:
//!
//! | `selected.txt` | registry (`tools/gen_multiverifier_consts.py --registry …`) | proof |
//! |---|---|---|
//! | `1` | `doom` (multiverifier = production, `a5989715…`) | `spikes/s4/results/N4_doom`, 96 033 felts |
//! | `2` | `doom_fold4_min` (`02b34360…`, docs/spikes/S4b.md) | `spikes/s4/results/N2_doom_fold4_min`, 96 509 felts |
//!
//! The expected `output_hash` is `blake2s(multiverifier_hash ‖ program_output)` (computed
//! off-chain, `tools/emit_calldata.py` sibling check); for `n4` it is also the hash printed by
//! the monolithic verifier (`verifier_output.json`).
use snforge_std::fs::{FileTrait, read_txt};

#[derive(Drop, Copy)]
pub struct Fixture {
    pub path: felt252,
    pub n_felts: u32,
    pub output_hash: [u32; 8],
    pub multiverifier_hash: [u32; 8],
}

/// The number in `fixtures/selected.txt`.
pub fn selected() -> felt252 {
    let sel = read_txt(@FileTrait::new("../../fixtures/selected.txt"));
    assert!(sel.len() == 1, "fixtures/selected.txt: one number expected");
    *sel.at(0)
}

pub fn fixture() -> Fixture {
    if selected() == 2 {
        Fixture {
            path: 'n2_fold4min_root_proof.txt',
            n_felts: 96509,
            output_hash: [
                3728663878, 1670890090, 2536343223, 1016822265, 1923844992, 548677462,
                1938506889, 1214927871,
            ],
            multiverifier_hash: [
                0x02b34360, 0xcf03feac, 0x315fdae9, 0xbc006aeb, 0x398199e8, 0x57cb9591,
                0x6ab22e55, 0x9f7fac34,
            ],
        }
    } else {
        Fixture {
            path: 'n4_root_proof.txt',
            n_felts: 96033,
            output_hash: [
                3123785184, 3718676270, 1469581383, 660429404, 3277334853, 1494218902,
                3817731027, 3170188775,
            ],
            multiverifier_hash: [
                0xa5989715, 0x2377c07a, 0xc6d1e844, 0x54f0a04d, 0x8be65a7d, 0xfd73c261,
                0x9078e728, 0x973f680f,
            ],
        }
    }
}

/// Expected `output_hash` of the selected fixture.
pub fn expected_output_hash() -> [u32; 8] {
    fixture().output_hash
}

/// Loads the selected fixture's felt stream.
pub fn load_proof() -> Array<felt252> {
    let f = fixture();
    let mut path: ByteArray = "../../fixtures/";
    path.append_word(f.path, felt_len(f.path));
    let file = FileTrait::new(path);
    let values = read_txt(@file);
    assert!(values.len() == f.n_felts, "fixture length");
    values
}

#[test]
fn fixture_selector() {
    println!("fixtures/selected.txt = {} -> {}", selected(), fixture().path);
}

/// Byte length of a short-string felt.
fn felt_len(s: felt252) -> u32 {
    let mut v: u256 = s.into();
    let mut n = 0;
    while v != 0 {
        v = v / 256;
        n += 1;
    }
    n
}
