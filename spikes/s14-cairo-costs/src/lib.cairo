// SPDX-FileCopyrightText: 2026 Hellproof contributors
// SPDX-License-Identifier: Apache-2.0
//! Opaque CLI operands: no loop counter or compile-time operand specialization.

#[executable]
pub fn mod_operator(x: u128) -> (u128, u128) {
    (x % 256, 0)
}

#[executable]
pub fn mod_nonzero(x: u128) -> (u128, u128) {
    let d: NonZero<u128> = 256;
    let (_, r) = DivRem::div_rem(x, d);
    (r, 0)
}

#[executable]
pub fn mask_byte(x: u128) -> (u128, u128) {
    (x & 255, 0)
}

#[executable]
pub fn pair_operator(x: u128) -> (u128, u128) {
    (x / 256, x % 256)
}

#[executable]
pub fn pair_nonzero(x: u128) -> (u128, u128) {
    let d: NonZero<u128> = 256;
    DivRem::div_rem(x, d)
}

#[executable]
pub fn sparse_mask(x: u128) -> (u128, u128) {
    (x & 0x1040, 0)
}

#[executable]
pub fn sparse_arithmetic(x: u128) -> (u128, u128) {
    let two: NonZero<u128> = 2;
    let d6: NonZero<u128> = 64;
    let d12: NonZero<u128> = 4096;
    let (a, _) = DivRem::div_rem(x, d6);
    let (_, a) = DivRem::div_rem(a, two);
    let (b, _) = DivRem::div_rem(x, d12);
    let (_, b) = DivRem::div_rem(b, two);
    (a * 64 + b * 4096, 0)
}

#[executable]
pub fn sin_cos_reference(a: u32) -> (felt252, felt252) {
    let i = bam::angle_to_fine_index(a);
    (bam::finesine(i).enc, bam::finecosine(i).enc)
}

#[executable]
pub fn sin_cos_shared(a: u32) -> (felt252, felt252) {
    let (s, c) = bam::sin_cos(a);
    (s.enc, c.enc)
}
