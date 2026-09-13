// SPDX-License-Identifier: GPL-2.0-only
//! Property tests: statements that must hold for *every* case, checked over
//! the generated vectors and over the scheduler's whole domain.

use doom_map::{LevelId, genesis, load};
use doom_physics::{
    BASETHRESHOLD, MoveEvent, NO_MOBJ, SpawnZ, World, check_position, damage_mobj, new_grid,
    set_state, set_thing_position, spawn_mobj, world_of,
};
use doom_things::tables::{KIND_PLAYER, KIND_POSSESSED, MI_SEESTATE};
use fixed::Fixed;
use prng::{Prng, from_index};
use crate::actions::{a_chase, new_chase_dir};
use crate::event::MonsterEvent;
use crate::think::in_window;
use crate::{Ctx, WINDOW, silence};
use super::vectors::{CHASEDIRS, CHASE_SETUP};

/// Largest awake population the round-robin property is checked over.
const WINDOW_TEST_MAX: u32 = 25;

fn world() -> World {
    world_of(@load(LevelId::E1M1))
}

fn fx(enc: felt252) -> Fixed {
    Fixed { enc }
}

fn u32_of(v: felt252) -> u32 {
    let u: u128 = v.try_into().unwrap();
    u.try_into().unwrap()
}

/// **A monster never walks into a blocking line.** Every `P_NewChaseDir`
/// vector ends on a position `P_CheckPosition` still accepts, with the floor
/// and ceiling the crate recorded.
#[test]
fn test_a_monster_never_steps_into_a_wall() {
    let w = world();
    let v = CHASEDIRS.span();
    let n = v.len() / 12;
    let players = array![1].span();
    let mut i: u32 = 0;
    let mut moved: u32 = 0;
    while i != n {
        let b = i * 12;
        let mut g = new_grid();
        let mut mo = spawn_mobj(w, KIND_POSSESSED, fx(*v.at(b)), fx(*v.at(b + 1)), SpawnZ::OnFloor);
        set_thing_position(@w.map, ref g, ref mo, 0);
        let mut tgt = spawn_mobj(
            w, KIND_PLAYER, fx(*v.at(b + 2)), fx(*v.at(b + 3)), SpawnZ::OnFloor,
        );
        set_thing_position(@w.map, ref g, ref tgt, 1);
        mo.move_dir = u32_of(*v.at(b + 4));
        let mobjs = array![mo, tgt].span();
        let mut rng: Prng = from_index(u32_of(*v.at(b + 5)));
        let mut ev: Array<MonsterEvent> = array![];
        let ctx = Ctx { w, players, noise: silence(), tic: 0 };
        new_chase_dir(ctx, mobjs, ref g, ref rng, ref mo, 0, @tgt, ref ev);
        assert(mo.move_count < 16, 'movecount below 16');
        assert(mo.move_dir <= 8, 'movedir stays a direction');
        if *v.at(b + 11) == 1 {
            // It stepped: the destination must still be a legal standing
            // place. (A monster that could not move stays where the
            // generator put it, which is a subsector centroid and need not
            // be one -- `P_NewChaseDir` is not asked to fix that.)
            let mut moves: Array<MoveEvent> = array![];
            let c = check_position(w, mobjs, ref g, @mo, 0, mo.x, mo.y, ref moves);
            assert(c.ok, 'ends somewhere legal');
            assert(mo.floorz == c.floorz, 'floorz is where it moved to');
            moved += 1;
        }
        i += 1;
    }
    assert(moved > n / 4, 'most cases step');
}

/// **`threshold` decrements on every `A_Chase` and clears when the target
/// dies.** `BASETHRESHOLD` is what `P_DamageMobj` arms it with.
#[test]
fn test_threshold_decrements_and_clears() {
    let w = world();
    let s = CHASE_SETUP.span();
    let mut g = new_grid();
    let mut mo = spawn_mobj(w, KIND_POSSESSED, fx(*s.at(0)), fx(*s.at(1)), SpawnZ::OnFloor);
    set_thing_position(@w.map, ref g, ref mo, 0);
    let mut tgt = spawn_mobj(w, KIND_PLAYER, fx(*s.at(2)), fx(*s.at(3)), SpawnZ::OnFloor);
    set_thing_position(@w.map, ref g, ref tgt, 1);
    set_state(w, ref mo, *MI_SEESTATE.span().at(KIND_POSSESSED));
    mo.target = 1;
    mo.reaction_time = 0;
    mo.threshold = BASETHRESHOLD;
    let players = array![1].span();
    let mut rng: Prng = from_index(1);
    let mut ev: Array<MonsterEvent> = array![];
    let mut patches: Array<crate::Patch> = array![];
    let mut k: u32 = 0;
    while k != 10 {
        let mobjs = array![mo, tgt].span();
        let ctx = Ctx { w, players, noise: silence(), tic: k };
        let before = mo.threshold;
        a_chase(ctx, mobjs, ref g, ref rng, ref mo, 0, patches.span(), ref ev);
        assert(mo.threshold + 1 == before, 'one tic of threshold');
        k += 1;
    }
    // A dead target clears it outright.
    let mut rng2: Prng = from_index(1);
    let dead_idx = 1;
    let mobjs = array![mo, tgt].span();
    damage_mobj(w, mobjs, ref rng2, ref tgt, dead_idx, NO_MOBJ, NO_MOBJ, 1000, false);
    assert(tgt.health <= 0, 'target is dead');
    let mobjs = array![mo, tgt].span();
    let ctx = Ctx { w, players, noise: silence(), tic: 11 };
    a_chase(ctx, mobjs, ref g, ref rng, ref mo, 0, patches.span(), ref ev);
    assert(mo.threshold == 0, 'dead target clears threshold');
    let _ = patches;
}

/// **The round robin visits every awake monster within `ceil(n / 8)` tics**,
/// for every population up to [`WINDOW_TEST_MAX`] and from every starting
/// tic, and it visits exactly `min(n, 8)` of them per tic.
#[test]
fn test_round_robin_covers_everyone() {
    let mut n: u32 = 1;
    while n != WINDOW_TEST_MAX {
        let tics = (n + WINDOW - 1) / WINDOW;
        let mut t0: u32 = 0;
        while t0 != 5 {
            let mut rank: u32 = 0;
            while rank != n {
                let mut seen = false;
                let mut t: u32 = 0;
                while t != tics {
                    if in_window(rank, t0 + t, n) {
                        seen = true;
                    }
                    t += 1;
                }
                assert(seen, 'every rank is visited');
                rank += 1;
            }
            // Exactly `min(n, 8)` ranks are in the window on any one tic.
            let mut count: u32 = 0;
            let mut rank2: u32 = 0;
            while rank2 != n {
                if in_window(rank2, t0, n) {
                    count += 1;
                }
                rank2 += 1;
            }
            let expect = if n < WINDOW {
                n
            } else {
                WINDOW
            };
            assert(count == expect, 'the window holds 8');
            t0 += 1;
        }
        n += 1;
    }
}

/// **Nothing below the cap is ever de-scheduled**: with eight awake monsters
/// or fewer the crate behaves exactly as vanilla would.
#[test]
fn test_no_descheduling_below_the_cap() {
    let mut n: u32 = 1;
    while n != WINDOW + 1 {
        let mut rank: u32 = 0;
        while rank != n {
            let mut t: u32 = 0;
            while t != 20 {
                assert(in_window(rank, t, n), 'always in the window');
                t += 1;
            }
            rank += 1;
        }
        n += 1;
    }
}

/// **RNG consumption is a function of the inputs alone.** The same case
/// replayed twice consumes exactly the same draws — the property C2 rests on.
#[test]
fn test_rng_consumption_is_deterministic() {
    let w = world();
    let start = genesis(LevelId::E1M1).start;
    let players = array![1].span();
    let mut a: u32 = 0;
    let mut b: u32 = 0;
    let mut pass: u32 = 0;
    while pass != 2 {
        let mut g = new_grid();
        let mut mo = spawn_mobj(w, KIND_POSSESSED, start.x, start.y, SpawnZ::OnFloor);
        set_thing_position(@w.map, ref g, ref mo, 0);
        let mut tgt = spawn_mobj(
            w, KIND_PLAYER, fixed::add(start.x, fixed::from_units(200)), start.y, SpawnZ::OnFloor,
        );
        set_thing_position(@w.map, ref g, ref tgt, 1);
        set_state(w, ref mo, *MI_SEESTATE.span().at(KIND_POSSESSED));
        mo.target = 1;
        let mobjs = array![mo, tgt].span();
        let mut rng: Prng = from_index(1);
        let mut ev: Array<MonsterEvent> = array![];
        let patches: Array<crate::Patch> = array![];
        let ctx = Ctx { w, players, noise: silence(), tic: 3 };
        a_chase(ctx, mobjs, ref g, ref rng, ref mo, 0, patches.span(), ref ev);
        if pass == 0 {
            a = rng.index;
        } else {
            b = rng.index;
        }
        pass += 1;
    }
    assert(a == b, 'same draws both times');
}

#[test]
fn test_window_uses_full_product_near_clock_limit() {
    // Independent integer reference: multiplying before modulo must retain
    // bits above u32 at t >= 2^29. D14 still permits these tics.
    let times = array![0x1fffffff_u64, 0x20000000, 0x20000001, 0x3fffffff, 0x40000000];
    let mut ts = times.span();
    while let Option::Some(t) = ts.pop_front() {
        let mut rank: u32 = 0;
        while rank < 9 {
            let wide_rank: u64 = rank.into();
            let start = (8 * *t) % 9;
            let expected = (wide_rank + 9 - start) % 9 < 8;
            assert(in_window(rank, (*t).try_into().unwrap(), 9) == expected, 'full clock product');
            rank += 1;
        }
    }
}
