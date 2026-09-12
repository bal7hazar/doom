// SPDX-License-Identifier: GPL-2.0-only
//! The "without data" side of `doom_things`'s bytecode measurement (R2-A12).
//!
//! The same crate graph and flags as `../size`, but touching no generated
//! `const` table — so the difference between the two executables' bytecode is
//! exactly what the derived tables cost. S1 §5.9: one word per `const`
//! element, and `2 340 + 14.7 × words` steps of bootloader program-hashing
//! per segment.

use doom_things::{MobjType, info_of};

#[executable]
fn main(op: u32) -> felt252 {
    // The transitional hand-written catalogue: no generated constant.
    let info = info_of(MobjType::Zombieman);
    let mut acc: felt252 = op.into();
    acc += info.health.into() + info.radius.enc + info.height.enc;
    acc
}
