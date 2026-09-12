// SPDX-License-Identifier: GPL-2.0-only
//! The "without data" side of `doom_map`'s bytecode measurement (R2-A12).
//!
//! The same crate graph and flags as `../size`, but touching no generated
//! `const` array — so the difference between the two executables' bytecode is
//! exactly what the compiled-in level data costs. S1 §5.9: one word per
//! `const` element (measured here at 1.03, including the `span()` glue), and
//! `2 340 + 14.7 × words` steps of bootloader program-hashing per segment.

use doom_map::{is_line_blocking, sample_level, sector_at};

#[executable]
fn main(op: u32) -> felt252 {
    // The transitional fixture level: hand-written, no generated constant.
    let level = sample_level();
    let mut acc: felt252 = op.into();
    acc += sector_at(@level, 0).light_level.into();
    if is_line_blocking(@level, 0) {
        acc += 1;
    }
    acc
}
