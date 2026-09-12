// SPDX-License-Identifier: GPL-2.0-only
//! The "without data" side of `doom_map`'s bytecode measurement (R2-A12).
//!
//! The same crate graph and flags as `../size`, but touching no generated
//! `const` array — so the difference between the two executables' bytecode is
//! exactly what the compiled-in level data costs. S1 §5.9: one word per
//! `const` element (measured here at 1.03, including the `span()` glue), and
//! `2 340 + 14.7 × words` steps of bootloader program-hashing per segment.

use doom_map::{ML_BLOCKING, ML_TWOSIDED, NO_SECTOR};

#[executable]
fn main(op: u32) -> felt252 {
    // Crate-level scalars only: no generated array is referenced.
    let mut acc: felt252 = op.into();
    acc += NO_SECTOR.into() + ML_TWOSIDED.into();
    if op == ML_BLOCKING {
        acc += 1;
    }
    acc
}
