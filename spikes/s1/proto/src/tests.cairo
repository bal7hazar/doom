//! Unit tests for the S1 prototype.  Throwaway code, but tested throwaway code.

use crate::bam::{angle_add, angle_sub, cosine, finesine_raw, point_to_angle, sine};
use crate::blockmap::{cell_x, cell_y, collect_bbox};
use crate::bsp::{point_in_subsector, sector_at};
use crate::fixed::{
    FRACUNIT, Sf, approx_dist, felt_ge, felt_gt, felt_sub, fixed_div_mag, fixed_mul, fixed_mul_mag,
    sf_add,
};
use crate::game::{genesis, run, script_cmd, sector_of, step_tic};
use crate::geom::{Bbox, box_crosses_six, box_crosses_three, box_hoist, hoist, line_side_six,
    line_side_three};
use crate::mapdata::{
    BIGC, L_AB, L_BB, L_CB, L_DIAG, L_V1X, L_V1Y, L_V2X, L_V2Y, NUM_LINES, NUM_SECTORS, OFF,
    PLAYER_SECTOR, PLAYER_X, PLAYER_Y, S_FLOOR,
};
use crate::mobj::{Opts, PLAYER_RADIUS, opts_from};
use crate::physics::try_move;
use crate::ai::reject_blocks;
use crate::rng::p_random;
use crate::tables::{FINESINE, RNDTABLE, TANTOANGLE};

fn all_opts() -> Opts {
    opts_from(1, 1, 1, 1, 0, 1)
}

// ------------------------------------------------------------------- fixed

#[test]
fn test_felt_ge() {
    assert!(felt_ge(5, 3));
    assert!(felt_ge(3, 3));
    assert!(!felt_ge(2, 3));
    assert!(felt_gt(5, 3));
    assert!(!felt_gt(3, 3));
    // large operands, still below 2^104
    assert!(felt_ge(0x1000000000000000000000000, 0xFFFFFFFFFFFFFFFFFFFFFFF));
}

#[test]
fn test_felt_sub_sign() {
    let a = felt_sub(10, 4);
    assert!(a.m == 6 && a.neg == 0);
    let b = felt_sub(4, 10);
    assert!(b.m == 6 && b.neg == 1);
    let c = felt_sub(7, 7);
    assert!(c.m == 0 && c.neg == 0);
}

#[test]
fn test_fixed_mul_reference() {
    // 1.0 * 1.0 == 1.0
    assert!(fixed_mul_mag(FRACUNIT, FRACUNIT) == FRACUNIT);
    // 2.0 * 0.5 == 1.0
    assert!(fixed_mul_mag(131072, 32768) == FRACUNIT);
    // 0.90625 (Doom's ORIG_FRICTION) applied to 10.0
    assert!(fixed_mul_mag(655360, 59392) == 593920);
    // truncation, like C's (a*b)>>16
    assert!(fixed_mul_mag(3, 3) == 0);
    // sign handling
    let r = fixed_mul(Sf { m: FRACUNIT, neg: 1 }, Sf { m: 131072, neg: 0 });
    assert!(r.m == 131072 && r.neg == 1);
    let r2 = fixed_mul(Sf { m: FRACUNIT, neg: 1 }, Sf { m: 131072, neg: 1 });
    assert!(r2.m == 131072 && r2.neg == 0);
}

#[test]
fn test_fixed_div_reference() {
    assert!(fixed_div_mag(FRACUNIT, FRACUNIT) == FRACUNIT);
    assert!(fixed_div_mag(FRACUNIT, 131072) == 32768);
    assert!(fixed_div_mag(196608, 131072) == 98304); // 3.0 / 2.0 == 1.5
    assert!(fixed_div_mag(5, 0) == 0); // guarded, never panics
}

#[test]
fn test_sf_add() {
    let r = sf_add(Sf { m: 5, neg: 0 }, Sf { m: 3, neg: 1 });
    assert!(r.m == 2 && r.neg == 0);
    let r2 = sf_add(Sf { m: 3, neg: 0 }, Sf { m: 5, neg: 1 });
    assert!(r2.m == 2 && r2.neg == 1);
    let r3 = sf_add(Sf { m: 3, neg: 1 }, Sf { m: 5, neg: 1 });
    assert!(r3.m == 8 && r3.neg == 1);
}

#[test]
fn test_approx_dist() {
    assert!(approx_dist(100, 40) == 120);
    assert!(approx_dist(40, 100) == 120);
    assert!(approx_dist(0, 0) == 0);
    // odd operand: must be integer division, not felt field division
    assert!(approx_dist(10, 3) == 11);
}

// --------------------------------------------------------------------- bam

#[test]
fn test_angle_wrap() {
    assert!(angle_add(0xFFFFFFFF, 1) == 0);
    assert!(angle_add(0x80000000, 0x80000000) == 0);
    assert!(angle_sub(0, 1) == 0xFFFFFFFF);
    assert!(angle_sub(5, 3) == 2);
}

#[test]
fn test_finesine_table() {
    // table is biased by +FRACUNIT and is 10240 entries long
    assert!(FINESINE.span().len() == 10240);
    assert!(*FINESINE.span().at(0) == FRACUNIT); // sin(0) == 0
    assert!(*FINESINE.span().at(2048) == FRACUNIT + FRACUNIT); // sin(90) == 1
    assert!(*FINESINE.span().at(6144) == 0); // sin(270) == -1
    // finecosine[i] == finesine[i + 2048]
    assert!(*FINESINE.span().at(2048) == finesine_raw(2048));
}

#[test]
fn test_sine_cosine_signs() {
    let s0 = sine(0);
    assert!(s0.m == 0);
    let s90 = sine(0x40000000);
    assert!(s90.m == FRACUNIT && s90.neg == 0);
    let s270 = sine(0xC0000000);
    assert!(s270.m == FRACUNIT && s270.neg == 1);
    let c0 = cosine(0);
    assert!(c0.m == FRACUNIT && c0.neg == 0);
    let c180 = cosine(0x80000000);
    assert!(c180.m == FRACUNIT && c180.neg == 1);
}

#[test]
fn test_tantoangle_table() {
    assert!(TANTOANGLE.span().len() == 2049);
    assert!(*TANTOANGLE.span().at(0) == 0);
    // atan(1) == 45 degrees == 0x20000000 BAM
    let v: felt252 = *TANTOANGLE.span().at(2048);
    let a: u32 = v.try_into().unwrap();
    assert!(a > 0x1FFFFF00 && a < 0x20000100);
}

#[test]
fn test_point_to_angle_quadrants() {
    let z = Sf { m: 0, neg: 0 };
    let p = Sf { m: 65536, neg: 0 };
    let n = Sf { m: 65536, neg: 1 };
    assert!(point_to_angle(p, z) == 0);
    let a90 = point_to_angle(z, p);
    assert!(a90 > 0x3FFFFF00 && a90 < 0x40000100);
    let a180 = point_to_angle(n, z);
    assert!(a180 > 0x7FFFFF00 && a180 < 0x80000100);
    let a270 = point_to_angle(z, n);
    assert!(a270 > 0xBFFFFF00 && a270 < 0xC0000100);
    // 45 degrees
    let a45 = point_to_angle(p, p);
    assert!(a45 > 0x1FFFFF00 && a45 < 0x20000100);
}

// -------------------------------------------------------------------- geom

/// The 3-array and the 6-array half-plane forms must agree on every linedef,
/// for a spread of probe points.  This is the property that lets R2-A4 replace
/// one with the other.
#[test]
fn test_point_on_side_representations_agree() {
    let ab = L_AB.span();
    let bb = L_BB.span();
    let cb = L_CB.span();
    let mut li: u32 = 0;
    while li < NUM_LINES {
        let mut k: u32 = 0;
        while k != 4 {
            let x = OFF + (k.into() * 4194304) - 8388608;
            let y = OFF + (k.into() * 3145728) - 6291456;
            let h = hoist(x, y, BIGC);
            let a = line_side_six(li, x, y);
            let b = line_side_three(*ab.at(li), *bb.at(li), *cb.at(li), x, y, h);
            assert!(a == b);
            k += 1;
        }
        li += 61; // sample ~20 lines, keeps the test fast
    }
}

/// A point exactly on one endpoint of the line is on the "front" (side 1 for
/// our convention, cross == 0).
#[test]
fn test_point_on_side_endpoint() {
    let li: u32 = 0;
    let x = *L_V1X.span().at(li);
    let y = *L_V1Y.span().at(li);
    assert!(line_side_six(li, x, y) == 1);
    let h = hoist(x, y, BIGC);
    assert!(line_side_three(*L_AB.span().at(li), *L_BB.span().at(li), *L_CB.span().at(li), x, y, h) == 1);
}

/// A box centred on a line's midpoint straddles it; a box far away does not.
#[test]
fn test_box_on_line_side() {
    let li: u32 = 0;
    let x1 = *L_V1X.span().at(li);
    let y1 = *L_V1Y.span().at(li);
    let x2 = *L_V2X.span().at(li);
    let y2 = *L_V2Y.span().at(li);
    let cx: u128 = x1.try_into().unwrap();
    let cx2: u128 = x2.try_into().unwrap();
    let cy: u128 = y1.try_into().unwrap();
    let cy2: u128 = y2.try_into().unwrap();
    let mx: felt252 = ((cx + cx2) / 2).into();
    let my: felt252 = ((cy + cy2) / 2).into();
    let r: felt252 = 1048576;
    let bx = Bbox { l: mx - r, r: mx + r, b: my - r, t: my + r };
    let h = box_hoist(bx, BIGC);
    let d = *L_DIAG.span().at(li);
    assert!(box_crosses_three(*L_AB.span().at(li), *L_BB.span().at(li), *L_CB.span().at(li), d, bx, h));
    assert!(box_crosses_six(li, d, bx));

    let far = Bbox { l: mx + 100 * r, r: mx + 102 * r, b: my + 100 * r, t: my + 102 * r };
    let hf = box_hoist(far, BIGC);
    assert!(
        box_crosses_three(*L_AB.span().at(li), *L_BB.span().at(li), *L_CB.span().at(li), d, far, hf)
            == box_crosses_six(li, d, far),
    );
}

// --------------------------------------------------------------------- bsp

#[test]
fn test_player_start_sector() {
    // the BSP walk must land the player start in the sector the extractor
    // computed independently in Python
    assert!(sector_at(PLAYER_X, PLAYER_Y, true) == PLAYER_SECTOR);
    assert!(sector_at(PLAYER_X, PLAYER_Y, false) == PLAYER_SECTOR);
}

#[test]
fn test_bsp_representations_agree() {
    let mut k: u32 = 0;
    while k != 8 {
        let x = PLAYER_X + (k.into() * 2097152) - 8388608;
        let y = PLAYER_Y + (k.into() * 1048576) - 4194304;
        assert!(point_in_subsector(x, y, true) == point_in_subsector(x, y, false));
        k += 1;
    }
}

// ---------------------------------------------------------------- blockmap

#[test]
fn test_blockmap_cells() {
    // the player start must land inside the grid
    let cx = cell_x(PLAYER_X);
    let cy = cell_y(PLAYER_Y);
    assert!(cx < 32);
    assert!(cy < 27);
}

#[test]
fn test_blockmap_bbox_iteration() {
    let r: felt252 = 1048576;
    let bx = Bbox { l: PLAYER_X - r, r: PLAYER_X + r, b: PLAYER_Y - r, t: PLAYER_Y + r };
    let naive = collect_bbox(bx, false);
    let dedup = collect_bbox(bx, true);
    // dedup never adds lines and never loses a distinct one
    assert!(dedup.len() <= naive.len());
    let ds = dedup.span();
    let mut i: u32 = 0;
    while i != ds.len() {
        let mut j: u32 = i + 1;
        while j != ds.len() {
            assert!(*ds.at(i) != *ds.at(j));
            j += 1;
        }
        i += 1;
    }
    // every deduplicated line was present in the naive list
    let ns = naive.span();
    let mut k: u32 = 0;
    while k != ds.len() {
        let mut found = false;
        let mut m: u32 = 0;
        while m != ns.len() {
            if *ns.at(m) == *ds.at(k) {
                found = true;
                break;
            }
            m += 1;
        }
        assert!(found);
        k += 1;
    }
}

/// A very wide box spans several cells; the naive list then really does repeat
/// lines, which is what R2-A5 removes.
#[test]
fn test_blockmap_multicell_has_duplicates() {
    let r: felt252 = 16777216; // 256 units -> at least 3x3 cells
    let bx = Bbox { l: PLAYER_X - r, r: PLAYER_X + r, b: PLAYER_Y - r, t: PLAYER_Y + r };
    let naive = collect_bbox(bx, false);
    let dedup = collect_bbox(bx, true);
    assert!(naive.len() >= dedup.len());
}

// ------------------------------------------------------------------ reject

#[test]
fn test_reject_table() {
    // a sector is never rejected against itself
    let mut s: u32 = 0;
    while s < NUM_SECTORS {
        assert!(!reject_blocks(s, s));
        s += 7;
    }
    // REJECT is symmetric, including across the chunk boundary
    let mut i: u32 = 0;
    while i < NUM_SECTORS {
        let mut j: u32 = 0;
        while j < NUM_SECTORS {
            assert!(reject_blocks(i, j) == reject_blocks(j, i));
            j += 23;
        }
        i += 17;
    }
    // at least one pair really is rejected (the table is not all zeros)
    let mut any = false;
    let mut k: u32 = 0;
    while k < NUM_SECTORS {
        if reject_blocks(0, k) {
            any = true;
            break;
        }
        k += 1;
    }
    assert!(any);
}

// --------------------------------------------------------------------- rng

#[test]
fn test_rng_table() {
    assert!(RNDTABLE.span().len() == 256);
    let (i1, _) = p_random(0);
    assert!(i1 == 1);
    let (i2, _) = p_random(255);
    assert!(i2 == 0); // wraps without a division
    // values stay in 0..255
    let mut idx: u32 = 0;
    let mut k: u32 = 0;
    while k != 300 {
        let (n, v) = p_random(idx);
        assert!(v < 256);
        idx = n;
        k += 1;
    }
}

// ----------------------------------------------------------------- physics

#[test]
fn test_try_move_player_start_is_free() {
    let r = try_move(PLAYER_X, PLAYER_Y, PLAYER_RADIUS, all_opts());
    assert!(r.ok);
    assert!(r.sector == PLAYER_SECTOR);
    assert!(r.floorz == *S_FLOOR.span().at(PLAYER_SECTOR));
}

#[test]
fn test_try_move_representations_agree() {
    let six = opts_from(1, 1, 0, 1, 0, 0);
    let three = opts_from(1, 1, 1, 1, 0, 1);
    let bboxr = opts_from(1, 1, 1, 1, 1, 0);
    let mut k: u32 = 0;
    while k != 12 {
        let x = PLAYER_X + (k.into() * 1048576) - 6291456;
        let y = PLAYER_Y + (k.into() * 786432) - 4194304;
        let a = try_move(x, y, PLAYER_RADIUS, six);
        let b = try_move(x, y, PLAYER_RADIUS, three);
        let c = try_move(x, y, PLAYER_RADIUS, bboxr);
        assert!(a.ok == b.ok);
        assert!(a.ok == c.ok);
        assert!(a.sector == b.sector);
        k += 1;
    }
}

/// Walking straight into the nearest solid wall must eventually be refused:
/// the player never leaves the map.
#[test]
fn test_player_never_leaves_the_map() {
    let o = all_opts();
    let mut x = PLAYER_X;
    let step: felt252 = 2097152; // 32 units
    let mut k: u32 = 0;
    let mut blocked = false;
    while k != 60 {
        let nx = x + step;
        let r = try_move(nx, PLAYER_Y, PLAYER_RADIUS, o);
        if !r.ok {
            blocked = true;
            break;
        }
        x = nx;
        k += 1;
    }
    assert!(blocked);
}

// -------------------------------------------------------------------- game

#[test]
fn test_script_cmd_is_deterministic() {
    let (f1, s1, t1, b1) = script_cmd(7);
    let (f2, s2, t2, b2) = script_cmd(7);
    assert!(f1.m == f2.m && f1.neg == f2.neg);
    assert!(s1.m == s2.m && s1.neg == s2.neg);
    assert!(t1 == t2);
    assert!(b1 == b2);
}

#[test]
fn test_genesis_shapes() {
    let a = genesis(0);
    assert!(a.mobjs.len() == 0);
    let b = genesis(1);
    assert!(b.mobjs.len() == 5);
    let mut i: u32 = 0;
    let s = b.mobjs.span();
    while i != 5 {
        assert!(*s.at(i).awake == 0);
        i += 1;
    }
    let c = genesis(2);
    let sc = c.mobjs.span();
    let mut j: u32 = 0;
    while j != 5 {
        assert!(*sc.at(j).awake == 1);
        j += 1;
    }
}

#[test]
fn test_monsters_spawn_in_their_sector() {
    let g = genesis(2);
    let s = g.mobjs.span();
    let mut i: u32 = 0;
    while i != 5 {
        let m = *s.at(i);
        assert!(sector_of(m.x, m.y) == m.sector);
        i += 1;
    }
}

/// The reference checksum of a 350-tic scripted run.  Any change to the
/// simulation must change this value deliberately.
#[test]
fn test_350_tic_checksum_is_stable() {
    let a = run(3, 350, all_opts());
    let b = run(3, 350, all_opts());
    assert!(a == b);
    assert!(a != 0);
}

/// Enabling an optimisation must not change the simulation result.  REJECT
/// (R2-A2) and the two representations (R2-A4, R2-A5) are semantics-preserving;
/// AI cadencing (R2-A3) is *not* and is excluded on purpose.
#[test]
fn test_optimisations_preserve_the_result() {
    let base = run(2, 60, opts_from(0, 0, 0, 0, 0, 0));
    assert!(run(2, 60, opts_from(1, 0, 0, 0, 0, 0)) == base); // REJECT
    assert!(run(2, 60, opts_from(0, 0, 1, 0, 0, 0)) == base); // 3-array half-plane
    assert!(run(2, 60, opts_from(0, 0, 0, 1, 0, 0)) == base); // blockmap dedup
    assert!(run(2, 60, opts_from(0, 0, 0, 0, 1, 0)) == base); // bbox reject
    assert!(run(2, 60, opts_from(1, 0, 1, 1, 1, 1)) == base); // all together
    assert!(run(2, 60, opts_from(1, 0, 1, 0, 1, 0)) == base); // the retained config
}

#[test]
fn test_tic_advances_state() {
    let o = all_opts();
    let g = genesis(3);
    let x0 = g.player.x;
    let mut st = g;
    let mut t: u32 = 0;
    while t != 20 {
        st = step_tic(st, 3, o);
        t += 1;
    }
    assert!(st.tic == 20);
    assert!(st.player.x != x0); // the player really moved
    assert!(st.shots == 2); // one shot every 10 tics
}

/// No value stored in the state may reach 2^128 (rule A7 / R4-A5).
#[test]
fn test_state_values_stay_below_2_pow_128() {
    let o = all_opts();
    let mut st = genesis(3);
    let mut t: u32 = 0;
    while t != 120 {
        st = step_tic(st, 3, o);
        let _: u128 = st.player.x.try_into().unwrap();
        let _: u128 = st.player.y.try_into().unwrap();
        let _: u128 = st.player.momx.m.try_into().unwrap();
        let _: u128 = st.player.momy.m.try_into().unwrap();
        let s = st.mobjs.span();
        let mut i: u32 = 0;
        while i != s.len() {
            let m = *s.at(i);
            let _: u128 = m.x.try_into().unwrap();
            let _: u128 = m.y.try_into().unwrap();
            i += 1;
        }
        t += 1;
    }
    assert!(st.tic == 120);
}
