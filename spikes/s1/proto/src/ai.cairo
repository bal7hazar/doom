//! Monster AI: A_Look / A_Chase / attack decision and P_CheckSight.
//!
//! Sight uses a **blockmap ray**, not a BSP traversal.  Justification (see
//! docs/spikes/S1.md): P_CheckSight's BSP walk costs one half-plane test per
//! interior node plus a divline intersection per seg of every crossed
//! subsector, and the node walk alone is ~10 levels deep on E1M1 (681 nodes).
//! The blockmap walk visits `dist/128 + 1` cells holding 4.2 linedefs each and
//! needs no division, so it is both cheaper and bounded by a quantity we can
//! cap (sight range).

use crate::bam::{angle_add, cosine, point_to_angle, sine};
use crate::fixed::{Sf, approx_dist, felt_ge, felt_sub, fixed_mul, bias_add};
use crate::mapdata::{NUM_SECTORS, REJECT_C0, REJECT_C1, REJECT_ROWS_PER_CHUNK};
use crate::mobj::{
    MELEE_RANGE, MISSILE_RANGE, MONSTER_RADIUS, MONSTER_SPEED, Mobj, Opts, ST_MELEE, ST_MISSILE,
    ST_SEE,
};
use crate::physics::{seg_crosses_line, try_move};
use crate::blockmap::collect_ray;
use crate::mapdata::{L_BLOCKING, L_TWOSIDED};
use crate::rng::p_random;

/// REJECT lookup: `true` when the two sectors are provably mutually invisible.
///
/// The table is one felt per sector pair, chunked because a const fixed-size
/// array cannot exceed 32767 elements in Cairo 2.16 (the CASM type size is an
/// i16).  Bit-packing the rows instead would need a variable shift, which
/// without the bitwise builtin means a u256 division: far more expensive than
/// the extra chunk comparison.
#[inline(always)]
pub fn reject_blocks(s1: u32, s2: u32) -> bool {
    if s1 < REJECT_ROWS_PER_CHUNK {
        *REJECT_C0.span().at(s1 * NUM_SECTORS + s2) == 1
    } else {
        *REJECT_C1.span().at((s1 - REJECT_ROWS_PER_CHUNK) * NUM_SECTORS + s2) == 1
    }
}

/// P_CheckSight-lite.
pub fn check_sight(m: Mobj, px: felt252, py: felt252, psec: u32, opts: Opts) -> bool {
    if opts.reject && reject_blocks(m.sector, psec) {
        return false;
    }
    let lines = collect_ray(m.x, m.y, px, py, opts.dedup);
    let s = lines.span();
    let n = s.len();
    let mut i: u32 = 0;
    let mut visible = true;
    while i != n {
        let lf: felt252 = *s.at(i);
        let li: u32 = lf.try_into().unwrap();
        i += 1;
        if *L_TWOSIDED.span().at(li) == 1 && *L_BLOCKING.span().at(li) == 0 {
            continue;
        }
        if seg_crosses_line(li, m.x, m.y, px, py, opts) {
            visible = false;
            break;
        }
    }
    visible
}

/// 8-direction movement table, as (cos, sin) signed pairs scaled by speed.
fn dir_delta(dir: u32, speed: felt252) -> (Sf, Sf) {
    let ang: u32 = dir * 0x20000000_u32; // 45 degrees per step
    (fixed_mul(cosine(ang), Sf { m: speed, neg: 0 }),
     fixed_mul(sine(ang), Sf { m: speed, neg: 0 }))
}

/// P_Move-lite.
fn p_move(m: Mobj, opts: Opts) -> (Mobj, bool) {
    let (dx, dy) = dir_delta(m.movedir, MONSTER_SPEED);
    let nx = bias_add(m.x, dx);
    let ny = bias_add(m.y, dy);
    let r = try_move(nx, ny, MONSTER_RADIUS, opts);
    if r.ok {
        let mut n = m;
        n.x = nx;
        n.y = ny;
        n.sector = r.sector;
        n.floorz = r.floorz;
        (n, true)
    } else {
        (m, false)
    }
}

/// A_Look + A_Chase + attack decision for one monster.
pub fn monster_think(
    m: Mobj, px: felt252, py: felt252, psec: u32, tic: u32, rng: u32, opts: Opts,
) -> (Mobj, u32, felt252) {
    let mut n = m;
    let mut r = rng;
    let mut damage: felt252 = 0;

    if n.tics != 0 {
        n.tics -= 1;
    }

    if n.awake == 0 {
        // ---- A_Look: dormant.  R2-A3 runs it 1 tic in 4, staggered by id.
        let due = if opts.cadence {
            (tic + n.id) % 4 == 0
        } else {
            true
        };
        if due {
            if check_sight(n, px, py, psec, opts) {
                n.awake = 1;
                n.state = ST_SEE;
                n.tics = 8;
                n.threshold = 20;
            }
        }
        return (n, r, damage);
    }

    // ---- awake: A_Chase
    let dx = felt_sub(px, n.x);
    let dy = felt_sub(py, n.y);
    let dist = approx_dist(dx.m, dy.m);

    if felt_ge(MELEE_RANGE, dist) {
        // melee attack
        n.state = ST_MELEE;
        let (r2, v) = p_random(r);
        r = r2;
        damage = ((v % 8) + 1).into();
        n.tics = 8;
        return (n, r, damage);
    }

    // missile decision needs line of sight; R2-A3 caches it for `threshold` tics
    if felt_ge(MISSILE_RANGE, dist) {
        let cached = opts.cadence && n.threshold != 0 && n.sight_tic + 8 > tic;
        let los = if cached {
            n.sight_ok == 1
        } else {
            let v = check_sight(n, px, py, psec, opts);
            n.sight_ok = if v {
                1
            } else {
                0
            };
            n.sight_tic = tic;
            v
        };
        if los {
            let (r2, v) = p_random(r);
            r = r2;
            if v < 40 {
                n.state = ST_MISSILE;
                n.angle = point_to_angle(dx, dy);
                n.tics = 8;
                let (r3, w) = p_random(r);
                r = r3;
                damage = ((w % 8) + 1).into();
                return (n, r, damage);
            }
        }
    }

    // walk towards the player
    n.state = ST_SEE;
    if n.movecount == 0 {
        // P_NewChaseDir-lite: face the player, then snap to the nearest of the
        // eight directions.
        let a = point_to_angle(dx, dy);
        n.movedir = (angle_add(a, 0x10000000_u32) / 0x20000000_u32) % 8;
        n.movecount = 4;
    }
    let (n2, moved) = p_move(n, opts);
    n = n2;
    if !moved {
        let (r2, v) = p_random(r);
        r = r2;
        n.movedir = (n.movedir + 1 + (v % 3)) % 8;
        n.movecount = 0;
    } else {
        n.movecount -= 1;
    }
    if n.threshold != 0 {
        n.threshold -= 1;
    }
    (n, r, damage)
}
