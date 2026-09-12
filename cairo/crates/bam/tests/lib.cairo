// SPDX-License-Identifier: Apache-2.0
//! Integration tests: the public API as an external consumer sees it.
//!
//! Must stay **loop-free** — `scarb test` computes gas for the integration
//! target even though the workspace disables it, and Cairo lowers `while`
//! into recursive functions, which makes that computation fail. Everything
//! that iterates lives in `src/tests.cairo`.

use bam::{
    ANG0, ANG180, ANG270, ANG45, ANG90, Angle, FINEANGLES, SLOPERANGE, add, angle_to_fine_index,
    cosine, finecosine, finesine, neg, point_to_angle, point_to_angle2, reduce, sin_cos, sine,
    slope_div, sub, tantoangle,
};
use fixed::{from_raw, from_units};

#[test]
fn test_public_api_is_usable_from_outside_the_crate() {
    let a: Angle = ANG90;
    assert(add(a, ANG270) == ANG0, 'add wraps');
    assert(sub(ANG0, ANG90) == ANG270, 'sub wraps');
    assert(neg(ANG90) == ANG270, 'neg');
    assert(reduce(0x1C0000000) == 0xC0000000, 'reduce');
    assert(angle_to_fine_index(ANG180) == 4096, 'fine index');
    assert(angle_to_fine_index(0xFFFFFFFF) < FINEANGLES, 'fine index in range');
    assert(finesine(2047) == from_raw(65535), 'finesine peak');
    assert(finecosine(0) == finesine(2048), 'finecosine is shifted');
    assert(sine(ANG90) == from_raw(65535), 'sine');
    assert(cosine(ANG0) == from_raw(65535), 'cosine');
    assert(tantoangle(0) == ANG0, 'tantoangle floor');
    assert(tantoangle(2048) == ANG45, 'tantoangle ceiling');
    assert(slope_div(0, 0) == SLOPERANGE, 'slope_div saturates');
}

#[test]
fn test_sin_cos_and_point_to_angle_from_outside() {
    let (s, c) = sin_cos(ANG0);
    assert(s == sine(ANG0) && c == cosine(ANG0), 'sin_cos pair');
    assert(point_to_angle(from_units(0), from_units(0)) == ANG0, 'degenerate');
    assert(point_to_angle(from_units(64), from_units(0)) == ANG0, 'east');
    assert(point_to_angle(from_units(0), from_units(-64)) == ANG270, 'south');
    assert(
        point_to_angle2(from_units(1), from_units(1), from_units(65), from_units(1)) == ANG0,
        'point_to_angle2',
    );
}
