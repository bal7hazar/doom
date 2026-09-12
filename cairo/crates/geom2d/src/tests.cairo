// SPDX-License-Identifier: Apache-2.0
//! Unit tests: generated reference vectors, properties (the bbox rejection
//! never drops a true crossing, antisymmetry, hoisting equivalence) and the
//! edge cases S1 §7 calls out (vertical and horizontal lines, points exactly
//! on the line, degenerate boxes).
//!
//! Vectors come from `scripts/gen_vectors.py`, which computes every expected
//! value with exact Python integers and cross-checks it against a
//! floating-point implementation of the same predicate.

mod vectors;
use fixed::{Fixed, felt_ge, from_raw, from_units};
use vectors::{
    AD_DIST, AD_DX, AD_DY, BL_AB, BL_BB, BL_BOX_B, BL_BOX_L, BL_BOX_R, BL_BOX_T, BL_CB, BL_DIAG,
    BL_SIDE, BR_BOX_B, BR_BOX_L, BR_BOX_R, BR_BOX_T, BR_CROSSES, BR_REJECT, BR_SEG_X0, BR_SEG_X1,
    BR_SEG_Y0, BR_SEG_Y1, IV_ADX, IV_ADY, IV_AX, IV_AY, IV_BDX, IV_BDY, IV_BX, IV_BY, IV_FRAC,
    PS_AB, PS_BB, PS_CB, PS_SIDE, PS_V1X_ENC, PS_V1Y_ENC, PS_V2X_ENC, PS_V2Y_ENC, PS_X_ENC,
    PS_Y_ENC,
};
use super::{
    Box, DivLine, HalfPlane, Point, SIDE_BACK, SIDE_CROSS, SIDE_FRONT, approx_distance, bbox_reject,
    box_around, box_of_segment, box_on_line_side, diagonal, divline_side, half_plane, hoist,
    intercept_fraction, point_on_side_truncated, point_side, point_side_alone, point_side_at,
};

fn pt(x: felt252, y: felt252) -> Point {
    Point { x: from_units(x), y: from_units(y) }
}

fn pt_enc(x: felt252, y: felt252) -> Point {
    Point { x: Fixed { enc: x }, y: Fixed { enc: y } }
}

fn box_enc(l: felt252, b: felt252, r: felt252, t: felt252) -> Box {
    Box {
        left: Fixed { enc: l },
        bottom: Fixed { enc: b },
        right: Fixed { enc: r },
        top: Fixed { enc: t },
    }
}

// ---------------------------------------------------------------------------
// point_side against the generated vectors
// ---------------------------------------------------------------------------

#[test]
fn test_point_side_matches_1000_reference_vectors() {
    let ab = PS_AB.span();
    let bb = PS_BB.span();
    let cb = PS_CB.span();
    let x = PS_X_ENC.span();
    let y = PS_Y_ENC.span();
    let side = PS_SIDE.span();
    assert(side.len() == 1000, '1000 vectors');
    let mut i: u32 = 0;
    while i != 1000 {
        let hp = HalfPlane { ab: *ab.at(i), bb: *bb.at(i), cb: *cb.at(i) };
        let p = pt_enc(*x.at(i), *y.at(i));
        let got: felt252 = point_side(hp, p, hoist(p)).into();
        assert(got == *side.at(i), 'point_side matches');
        i += 1;
    }
}

#[test]
fn test_half_plane_builder_reproduces_the_generated_coefficients() {
    // The offline tool and the runtime builder must agree bit for bit,
    // otherwise the generated level data and the crate disagree on sides.
    let ab = PS_AB.span();
    let bb = PS_BB.span();
    let cb = PS_CB.span();
    let v1x = PS_V1X_ENC.span();
    let v1y = PS_V1Y_ENC.span();
    let v2x = PS_V2X_ENC.span();
    let v2y = PS_V2Y_ENC.span();
    let mut i: u32 = 0;
    while i != 1000 {
        let hp = half_plane(pt_enc(*v1x.at(i), *v1y.at(i)), pt_enc(*v2x.at(i), *v2y.at(i)));
        assert(hp.ab == *ab.at(i), 'ab matches');
        assert(hp.bb == *bb.at(i), 'bb matches');
        assert(hp.cb == *cb.at(i), 'cb matches');
        i += 1;
    }
}

#[test]
fn test_point_side_variants_agree() {
    let ab = PS_AB.span();
    let bb = PS_BB.span();
    let cb = PS_CB.span();
    let x = PS_X_ENC.span();
    let y = PS_Y_ENC.span();
    let mut i: u32 = 0;
    while i != 200 {
        let hp = HalfPlane { ab: *ab.at(i), bb: *bb.at(i), cb: *cb.at(i) };
        let p = pt_enc(*x.at(i), *y.at(i));
        let rhs = hoist(p);
        let a = point_side(hp, p, rhs);
        assert(point_side_alone(hp, p) == a, 'alone matches hoisted');
        assert(point_side_at(ab, bb, cb, i, p, rhs) == a, 'planar matches');
        // The three-valued form agrees except exactly on the line.
        let d = divline_side(hp, p, rhs);
        assert(d == a || d == SIDE_CROSS, 'divline agrees or is on');
        i += 1;
    }
}

#[test]
fn test_point_side_is_antisymmetric_in_the_line_orientation() {
    let v1x = PS_V1X_ENC.span();
    let v1y = PS_V1Y_ENC.span();
    let v2x = PS_V2X_ENC.span();
    let v2y = PS_V2Y_ENC.span();
    let x = PS_X_ENC.span();
    let y = PS_Y_ENC.span();
    let mut i: u32 = 10; // skip the degenerate "point exactly on the line" cases
    while i != 210 {
        let a = pt_enc(*v1x.at(i), *v1y.at(i));
        let b = pt_enc(*v2x.at(i), *v2y.at(i));
        let p = pt_enc(*x.at(i), *y.at(i));
        let rhs = hoist(p);
        let forward = divline_side(half_plane(a, b), p, rhs);
        let backward = divline_side(half_plane(b, a), p, rhs);
        if forward == SIDE_CROSS {
            assert(backward == SIDE_CROSS, 'on the line both ways');
        } else {
            assert(forward != backward, 'reversing flips the side');
        }
        i += 1;
    }
}

// ---------------------------------------------------------------------------
// Edge cases: axis-aligned lines and points on the line
// ---------------------------------------------------------------------------

#[test]
fn test_axis_aligned_lines_and_points_on_the_line() {
    // Horizontal line west to east: Doom's `!dy` branch returns `dx > 0`
    // for a point above it, and a point exactly on it takes the same branch.
    let h = half_plane(pt(0, 0), pt(64, 0));
    assert(point_side_alone(h, pt(32, 8)) == SIDE_BACK, 'above a west-east line');
    assert(point_side_alone(h, pt(32, -8)) == SIDE_FRONT, 'below it');
    assert(point_side_alone(h, pt(32, 0)) == SIDE_BACK, 'exactly on it is back');
    // Reversed: every side flips.
    let hr = half_plane(pt(64, 0), pt(0, 0));
    assert(point_side_alone(hr, pt(32, 8)) == SIDE_FRONT, 'above a east-west line');
    assert(point_side_alone(hr, pt(32, -8)) == SIDE_BACK, 'below it');
    // Vertical line south to north.
    let v = half_plane(pt(0, 0), pt(0, 64));
    assert(point_side_alone(v, pt(8, 32)) == SIDE_FRONT, 'east of a south-north line');
    assert(point_side_alone(v, pt(-8, 32)) == SIDE_BACK, 'west of it');
    assert(point_side_alone(v, pt(0, 32)) == SIDE_BACK, 'exactly on it is back');
    // One ulp away from a vertical line still decides.
    assert(point_side_alone(v, pt_enc(fixed::BIAS + 1, from_units(32).enc)) == SIDE_FRONT, 'ulp');
}

#[test]
fn test_diagonal_flag_matches_the_slope_sign() {
    assert(diagonal(pt(0, 0), pt(10, 10)) == 0, 'positive slope');
    assert(diagonal(pt(0, 0), pt(-10, -10)) == 0, 'positive slope reversed');
    assert(diagonal(pt(0, 0), pt(10, -10)) == 1, 'negative slope');
    assert(diagonal(pt(0, 0), pt(-10, 10)) == 1, 'negative slope reversed');
    assert(diagonal(pt(0, 0), pt(10, 0)) == 0, 'horizontal');
    assert(diagonal(pt(0, 0), pt(0, 10)) == 0, 'vertical');
}

#[test]
fn test_truncated_form_matches_the_exact_one_away_from_the_line() {
    // The two agree everywhere except within one ulp of the line; the
    // vectors are built from integer vertices, so a mismatch here would be a
    // real divergence, not a rounding difference.
    let v1x = PS_V1X_ENC.span();
    let v1y = PS_V1Y_ENC.span();
    let v2x = PS_V2X_ENC.span();
    let v2y = PS_V2Y_ENC.span();
    let x = PS_X_ENC.span();
    let y = PS_Y_ENC.span();
    let side = PS_SIDE.span();
    let mut i: u32 = 10;
    let mut agreements: u32 = 0;
    while i != 210 {
        let a = pt_enc(*v1x.at(i), *v1y.at(i));
        let b = pt_enc(*v2x.at(i), *v2y.at(i));
        let p = pt_enc(*x.at(i), *y.at(i));
        let t: felt252 = point_on_side_truncated(p, a, b).into();
        if t == *side.at(i) {
            agreements += 1;
        }
        i += 1;
    }
    // Doom's truncation only differs on sub-ulp cases, which random points
    // essentially never hit: all 200 must agree.
    assert(agreements == 200, 'truncated form agrees');
}

// ---------------------------------------------------------------------------
// Bounding boxes
// ---------------------------------------------------------------------------

#[test]
fn test_bbox_reject_matches_the_vectors_and_never_drops_a_crossing() {
    let bl = BR_BOX_L.span();
    let bb = BR_BOX_B.span();
    let br = BR_BOX_R.span();
    let bt = BR_BOX_T.span();
    let x0 = BR_SEG_X0.span();
    let y0 = BR_SEG_Y0.span();
    let x1 = BR_SEG_X1.span();
    let y1 = BR_SEG_Y1.span();
    let reject = BR_REJECT.span();
    let crosses = BR_CROSSES.span();
    assert(reject.len() == 600, '600 vectors');
    let mut i: u32 = 0;
    let mut crossings: u32 = 0;
    while i != 600 {
        let b = box_enc(*bl.at(i), *bb.at(i), *br.at(i), *bt.at(i));
        let seg = box_of_segment(pt_enc(*x0.at(i), *y0.at(i)), pt_enc(*x1.at(i), *y1.at(i)));
        let got = bbox_reject(b, seg);
        let expected = *reject.at(i) == 1;
        assert(got == expected, 'bbox_reject matches');
        if *crosses.at(i) == 1 {
            crossings += 1;
            // The property: a rejection must never drop a segment that
            // really crosses the box.
            assert(!got, 'never drops a crossing');
        }
        i += 1;
    }
    assert(crossings > 250, 'enough real crossings');
}

#[test]
fn test_bbox_reject_edge_cases() {
    let a = box_enc(from_units(0).enc, from_units(0).enc, from_units(10).enc, from_units(10).enc);
    // Touching boxes are rejected, exactly like Doom's `<=` / `>=`.
    let touching = box_enc(
        from_units(10).enc, from_units(0).enc, from_units(20).enc, from_units(10).enc,
    );
    assert(bbox_reject(a, touching), 'touching is rejected');
    // One ulp of overlap is not.
    let overlapping = box_enc(
        from_units(10).enc - 1, from_units(0).enc, from_units(20).enc, from_units(10).enc,
    );
    assert(!bbox_reject(a, overlapping), 'one ulp of overlap passes');
    assert(!bbox_reject(a, a), 'a box overlaps itself');
    // Each of the four comparisons rejects on its own.
    let far_left = box_enc(
        from_units(-20).enc, from_units(0).enc, from_units(-10).enc, from_units(10).enc,
    );
    let below = box_enc(
        from_units(0).enc, from_units(-20).enc, from_units(10).enc, from_units(-10).enc,
    );
    let above = box_enc(
        from_units(0).enc, from_units(10).enc, from_units(10).enc, from_units(20).enc,
    );
    assert(bbox_reject(a, far_left), 'left');
    assert(bbox_reject(a, below), 'below');
    assert(bbox_reject(a, above), 'above');
    // A degenerate (zero-size) box strictly inside is *not* rejected -- it
    // does overlap -- but one on the boundary or outside is, because the
    // comparisons are `<=` / `>=`.
    let inside = box_enc(
        from_units(5).enc, from_units(5).enc, from_units(5).enc, from_units(5).enc,
    );
    let on_edge = box_enc(
        from_units(0).enc, from_units(5).enc, from_units(0).enc, from_units(5).enc,
    );
    let outside = box_enc(
        from_units(11).enc, from_units(5).enc, from_units(11).enc, from_units(5).enc,
    );
    assert(!bbox_reject(a, inside), 'degenerate inside overlaps');
    assert(bbox_reject(a, on_edge), 'degenerate on edge rejected');
    assert(bbox_reject(a, outside), 'degenerate outside rejected');
}

#[test]
fn test_box_around_and_box_of_segment() {
    let b = box_around(pt(100, 200), from_units(16));
    assert(b.left == from_units(84), 'left');
    assert(b.right == from_units(116), 'right');
    assert(b.bottom == from_units(184), 'bottom');
    assert(b.top == from_units(216), 'top');
    let s = box_of_segment(pt(10, -5), pt(-3, 7));
    assert(s.left == from_units(-3) && s.right == from_units(10), 'x span');
    assert(s.bottom == from_units(-5) && s.top == from_units(7), 'y span');
}

#[test]
fn test_box_on_line_side_matches_the_vectors() {
    let ab = BL_AB.span();
    let bb = BL_BB.span();
    let cb = BL_CB.span();
    let diag = BL_DIAG.span();
    let l = BL_BOX_L.span();
    let bo = BL_BOX_B.span();
    let r = BL_BOX_R.span();
    let t = BL_BOX_T.span();
    let side = BL_SIDE.span();
    assert(side.len() == 600, '600 vectors');
    let mut i: u32 = 0;
    let mut straddles: u32 = 0;
    while i != 600 {
        let hp = HalfPlane { ab: *ab.at(i), bb: *bb.at(i), cb: *cb.at(i) };
        let d: u8 = (*diag.at(i)).try_into().unwrap();
        let b = box_enc(*l.at(i), *bo.at(i), *r.at(i), *t.at(i));
        let got: felt252 = box_on_line_side(hp, d, b).into();
        assert(got == *side.at(i), 'box_on_line_side matches');
        if got == 2 {
            straddles += 1;
        }
        i += 1;
    }
    assert(straddles > 40, 'enough straddling boxes');
}

#[test]
fn test_box_on_line_side_edge_cases() {
    // A horizontal line and a box entirely above it.
    let h = half_plane(pt(0, 0), pt(64, 0));
    let above = box_enc(
        from_units(10).enc, from_units(10).enc, from_units(20).enc, from_units(20).enc,
    );
    let below = box_enc(
        from_units(10).enc, from_units(-20).enc, from_units(20).enc, from_units(-10).enc,
    );
    let straddling = box_enc(
        from_units(10).enc, from_units(-10).enc, from_units(20).enc, from_units(10).enc,
    );
    assert(box_on_line_side(h, 0, above) == SIDE_BACK, 'above');
    assert(box_on_line_side(h, 0, below) == SIDE_FRONT, 'below');
    assert(box_on_line_side(h, 0, straddling) == SIDE_CROSS, 'straddling');
    // A box whose corner touches the line is on the back side (a point on
    // the line is back), so it does not straddle.
    let touching = box_enc(
        from_units(10).enc, from_units(0).enc, from_units(20).enc, from_units(10).enc,
    );
    assert(box_on_line_side(h, 0, touching) == SIDE_BACK, 'touching is back');
    // Both diagonals of a 45 degree line.
    let d_pos = half_plane(pt(0, 0), pt(64, 64));
    let d_neg = half_plane(pt(0, 0), pt(64, -64));
    let centred = box_enc(
        from_units(-8).enc, from_units(-8).enc, from_units(8).enc, from_units(8).enc,
    );
    assert(box_on_line_side(d_pos, 0, centred) == SIDE_CROSS, 'positive diagonal');
    assert(box_on_line_side(d_neg, 1, centred) == SIDE_CROSS, 'negative diagonal');
}

// ---------------------------------------------------------------------------
// Intersections and distances
// ---------------------------------------------------------------------------

#[test]
fn test_intercept_fraction_matches_the_vectors() {
    let ax = IV_AX.span();
    let ay = IV_AY.span();
    let adx = IV_ADX.span();
    let ady = IV_ADY.span();
    let bx = IV_BX.span();
    let by = IV_BY.span();
    let bdx = IV_BDX.span();
    let bdy = IV_BDY.span();
    let frac = IV_FRAC.span();
    assert(frac.len() == 200, '200 vectors');
    let mut i: u32 = 0;
    while i != 200 {
        let v2 = DivLine {
            x: Fixed { enc: *ax.at(i) },
            y: Fixed { enc: *ay.at(i) },
            dx: Fixed { enc: *adx.at(i) },
            dy: Fixed { enc: *ady.at(i) },
        };
        let v1 = DivLine {
            x: Fixed { enc: *bx.at(i) },
            y: Fixed { enc: *by.at(i) },
            dx: Fixed { enc: *bdx.at(i) },
            dy: Fixed { enc: *bdy.at(i) },
        };
        assert(intercept_fraction(v2, v1).enc == *frac.at(i), 'intercept matches');
        i += 1;
    }
}

#[test]
fn test_intercept_fraction_edge_cases() {
    // Two parallel divlines: Doom returns 0 rather than dividing by zero.
    let a = DivLine { x: from_units(0), y: from_units(0), dx: from_units(1), dy: from_units(0) };
    let b = DivLine { x: from_units(0), y: from_units(10), dx: from_units(1), dy: from_units(0) };
    assert(intercept_fraction(a, b) == fixed::ZERO, 'parallel gives zero');
    // A ray crossing a perpendicular line halfway.
    let ray = DivLine { x: from_units(0), y: from_units(0), dx: from_units(64), dy: from_units(0) };
    let wall = DivLine {
        x: from_units(32), y: from_units(-16), dx: from_units(0), dy: from_units(32),
    };
    let f = intercept_fraction(ray, wall);
    // Halfway along a 64-unit ray, to within the 8-bit pre-shift's rounding.
    let half = fixed::HALF.enc;
    assert(felt_ge(f.enc + 64, half) && felt_ge(half + 64, f.enc), 'halfway');
}

#[test]
fn test_approx_distance_matches_the_vectors() {
    let dx = AD_DX.span();
    let dy = AD_DY.span();
    let d = AD_DIST.span();
    assert(d.len() == 200, '200 vectors');
    let mut i: u32 = 0;
    while i != 200 {
        let got = approx_distance(Fixed { enc: *dx.at(i) }, Fixed { enc: *dy.at(i) });
        assert(got.enc == *d.at(i), 'approx_distance matches');
        i += 1;
    }
}

#[test]
fn test_approx_distance_properties() {
    assert(approx_distance(from_units(0), from_units(0)) == from_units(0), 'zero');
    assert(approx_distance(from_units(10), from_units(0)) == from_units(10), 'axis');
    assert(approx_distance(from_units(-10), from_units(0)) == from_units(10), 'sign free');
    assert(approx_distance(from_units(0), from_units(-10)) == from_units(10), 'other axis');
    // Symmetric in its arguments and in the signs.
    let a = from_raw(1234567);
    let b = from_raw(-7654321);
    assert(approx_distance(a, b) == approx_distance(b, a), 'symmetric');
    assert(approx_distance(a, b) == approx_distance(fixed::neg(a), b), 'sign symmetric');
    // The octagonal approximation brackets the true distance: for a 3-4-5
    // triangle the exact distance is 5 and the approximation is 5.5.
    let d = approx_distance(from_units(3), from_units(4));
    assert(d == fixed::from_raw(5 * 65536 + 32768), '3-4-5 gives 5.5');
    // Never underestimates by more than 6 %: on the diagonal, |dx| = |dy| = 1
    // gives 1.5 against the true 1.414.
    let diag = approx_distance(from_units(1), from_units(1));
    assert(diag == fixed::from_raw(98304), 'diagonal is 1.5');
}

// ---------------------------------------------------------------------------
// Provability
// ---------------------------------------------------------------------------

#[test]
fn test_every_intermediate_stays_below_the_provability_bound() {
    // The half-plane sums are the largest values this crate builds; the
    // module documents them below 2^53. 2^54 is the assertion.
    let limit: felt252 = 0x40000000000000;
    let ab = PS_AB.span();
    let bb = PS_BB.span();
    let cb = PS_CB.span();
    let x = PS_X_ENC.span();
    let y = PS_Y_ENC.span();
    let mut i: u32 = 0;
    while i != 1000 {
        let lhs = *ab.at(i) * *y.at(i) + *bb.at(i) * *x.at(i) + *cb.at(i);
        let p = pt_enc(*x.at(i), *y.at(i));
        assert(felt_ge(lhs, 0) && !felt_ge(lhs, limit), 'half-plane sum < 2^54');
        assert(felt_ge(hoist(p), 0) && !felt_ge(hoist(p), limit), 'hoisted term < 2^54');
        i += 1;
    }
}
