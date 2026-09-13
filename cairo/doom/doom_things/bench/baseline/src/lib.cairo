// SPDX-License-Identifier: GPL-2.0-only
//! The "without data" side of `doom_things`'s bytecode measurement (R2-A12).
//!
//! The same crate graph and flags as `../size`, but touching no generated
//! `const` table — so the difference between the two executables' bytecode is
//! exactly what the derived tables cost. S1 §5.9: one word per `const`
//! element, and `2 340 + 14.7 × words` steps of bootloader program-hashing
//! per segment.

use doom_things::{MAX_ZERO_TIC_CHAIN, NO_DOOMEDNUM, num_kinds, num_states};

#[executable]
fn main(op: u32) -> felt252 {
    // Crate scalars only: no generated table is referenced.
    let mut acc: felt252 = op.into();
    acc += NO_DOOMEDNUM.into() + MAX_ZERO_TIC_CHAIN.into();
    acc += num_kinds().into() + num_states().into();
    acc
}
