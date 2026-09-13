// SPDX-License-Identifier: GPL-2.0-only
//! Step-cost benchmark for `doom_monsters` on Freedoom E1M1.
//!
//! Differential measurement (S1 §3.1): every operation runs with `n` and
//! `2n` iterations, so bootstrap and (de)serialization cancel, and an
//! operation's `net` cost subtracts the baseline op that builds the same
//! operands. The scenes are built once, before the loop, and every iteration
//! is one real tic of `monsters_ticker` (`tic = i`), so nothing is hoisted
//! and the cost is the cost of a tic in a run.
//!
//! The two rosters the report is about:
//!
//! * **dormant**: the 29 skill-2 monsters of E1M1, with the player standing
//!   in the start alcove, from where nothing can see him and the only two
//!   monsters that are not REJECTed are `MF_AMBUSH` — so nobody ever wakes
//!   and the whole 700 tics are the dormant path;
//! * **awake**: 5 and 20 zombiemen in the first room, already chasing the
//!   player, who has enough health to survive the benchmark.

use doom_map::{LevelId, genesis, load, num_things, thing};
use doom_monsters::actions::{a_chase, a_look, check_missile_range, new_chase_dir};
use doom_monsters::event::MonsterEvent;
use doom_monsters::think::awake_count;
use doom_monsters::{Ctx, Noise, Patch, monsters_ticker, silence};
use doom_physics::{
    MF_COUNTKILL, Mobj, SpawnZ, ThingGrid, World, has, new_grid, set_state, set_thing_position,
    spawn_map_thing, spawn_mobj, world_of,
};
use doom_things::tables::{KIND_PLAYER, KIND_POSSESSED, MI_SEESTATE};
use fixed::Fixed;
use prng::{Prng, from_index};

/// Where the awake scenes stand, in map units from the Player 1 start (the
/// first room, as in `src/tests/e1m1.cairo`).
const STAND_DX: felt252 = 1600;
const STAND_DY: felt252 = 512;

fn units(u: felt252) -> Fixed {
    fixed::from_units(u)
}

/// The player, with enough health to outlive the benchmark.
fn bench_player(w: World, ref g: ThingGrid, dx: felt252, dy: felt252) -> Mobj {
    let s = genesis(LevelId::E1M1).start;
    let mut p = spawn_mobj(
        w, KIND_PLAYER, fixed::add(s.x, units(dx)), fixed::add(s.y, units(dy)), SpawnZ::OnFloor,
    );
    p.health = 1000000;
    set_thing_position(@w.map, ref g, ref p, 0);
    p
}

/// `n` zombiemen spread over the room around the player, already awake and
/// chasing mobj 0.
fn awake_scene(w: World, ref g: ThingGrid, n: u32) -> Array<Mobj> {
    let mut out: Array<Mobj> = array![];
    let p = bench_player(w, ref g, STAND_DX, STAND_DY);
    out.append(p);
    let mut k: u32 = 0;
    while k != n {
        let col: felt252 = (k % 5).into();
        let row: felt252 = (k / 5).into();
        let mut mo = spawn_mobj(
            w,
            KIND_POSSESSED,
            fixed::add(p.x, units(96 + col * 56)),
            fixed::add(p.y, units(-112 + row * 56)),
            SpawnZ::OnFloor,
        );
        set_state(w, ref mo, *MI_SEESTATE.span().at(KIND_POSSESSED));
        mo.target = 0;
        mo.reaction_time = 0;
        let idx = out.len();
        set_thing_position(@w.map, ref g, ref mo, idx);
        out.append(mo);
        k += 1;
    }
    out
}

/// The player in the start alcove and every skill-2 monster of E1M1, all
/// dormant and none of them able to see him.
fn dormant_scene(w: World, ref g: ThingGrid) -> Array<Mobj> {
    let m = load(LevelId::E1M1);
    let mut out: Array<Mobj> = array![];
    out.append(bench_player(w, ref g, 0, 0));
    let total = num_things(@m);
    let mut i: u32 = 0;
    while i != total {
        let t = thing(@m, i);
        if has(t.flags, 2) && !has(t.flags, 16) {
            match spawn_map_thing(w, t) {
                Option::Some(mo) => {
                    if has(mo.flags, MF_COUNTKILL) {
                        let idx = out.len();
                        let mut linked = mo;
                        set_thing_position(@w.map, ref g, ref linked, idx);
                        out.append(linked);
                    }
                },
                Option::None => {},
            }
        }
        i += 1;
    }
    out
}

/// One awake zombieman next to the player, its sight verdict already in the
/// R2-A3 cache: the "chase step, no sight traversal" the task budgets.
fn one_chaser(w: World, ref g: ThingGrid, tic: u32) -> (Mobj, Mobj) {
    let mut p = bench_player(w, ref g, STAND_DX, STAND_DY);
    let mut mo = spawn_mobj(w, KIND_POSSESSED, fixed::add(p.x, units(300)), p.y, SpawnZ::OnFloor);
    set_state(w, ref mo, *MI_SEESTATE.span().at(KIND_POSSESSED));
    mo.target = 0;
    mo.reaction_time = 0;
    mo.move_count = 8; // walking, not re-deciding: the common tic
    mo.sight_ok = true;
    mo.sight_sector = p.sector;
    mo.sight_expires = tic + 8;
    set_thing_position(@w.map, ref g, ref mo, 1);
    p.health = 1000000;
    (p, mo)
}

#[executable]
fn main(op: u32, n: u32) -> felt252 {
    let m = load(LevelId::E1M1);
    let w = world_of(@m);
    let players = array![0].span();
    let mut acc: felt252 = 0;
    let mut i: u32 = 0;
    let mut g: ThingGrid = new_grid();

    if op == 0 { // bare loop
        while i != n {
            i += 1;
        }
    } else if op == 1 {
        // baseline: one fresh chaser pair, linked, and nothing else
        while i != n {
            let (p, mo) = one_chaser(w, ref g, i);
            acc += p.x.enc + mo.x.enc;
            i += 1;
        }
    } else if op == 2 {
        // ticker overhead: the player alone (no monster, no missile)
        let mut mobjs = array![bench_player(w, ref g, STAND_DX, STAND_DY)];
        let mut rng: Prng = from_index(1);
        while i != n {
            let (next, r, _ev) = monsters_ticker(
                w, mobjs.span(), ref g, players, silence(), i, rng,
            );
            mobjs = next;
            rng = r;
            i += 1;
        }
        acc += rng.index.into() + mobjs.len().into();
    } else if op == 3 {
        // one dormant monster, the whole tic
        let mut mobjs = dormant_scene(w, ref g);
        let mut short: Array<Mobj> = array![*mobjs.span().at(0), *mobjs.span().at(1)];
        let mut rng: Prng = from_index(1);
        while i != n {
            let (next, r, _ev) = monsters_ticker(
                w, short.span(), ref g, players, silence(), i, rng,
            );
            short = next;
            rng = r;
            i += 1;
        }
        acc += rng.index.into() + short.len().into();
    } else if op == 4 {
        // the 29 dormant monsters of E1M1, the whole tic
        let mut mobjs = dormant_scene(w, ref g);
        let mut rng: Prng = from_index(1);
        while i != n {
            let (next, r, _ev) = monsters_ticker(
                w, mobjs.span(), ref g, players, silence(), i, rng,
            );
            mobjs = next;
            rng = r;
            i += 1;
        }
        acc += rng.index.into() + awake_count(w, mobjs.span()).into();
    } else if op == 5 {
        // 5 awake monsters
        let mut mobjs = awake_scene(w, ref g, 5);
        let mut rng: Prng = from_index(1);
        while i != n {
            let (next, r, _ev) = monsters_ticker(
                w, mobjs.span(), ref g, players, silence(), i, rng,
            );
            mobjs = next;
            rng = r;
            i += 1;
        }
        acc += rng.index.into() + awake_count(w, mobjs.span()).into();
    } else if op == 6 {
        // 20 awake monsters: past D3's window of 8
        let mut mobjs = awake_scene(w, ref g, 20);
        let mut rng: Prng = from_index(1);
        while i != n {
            let (next, r, _ev) = monsters_ticker(
                w, mobjs.span(), ref g, players, silence(), i, rng,
            );
            mobjs = next;
            rng = r;
            i += 1;
        }
        acc += rng.index.into() + awake_count(w, mobjs.span()).into();
    } else if op == 7 {
        // `A_Chase`: one walking step, sight answered from the cache
        while i != n {
            let (p, mut mo) = one_chaser(w, ref g, i);
            let mobjs = array![p, mo].span();
            let mut rng: Prng = from_index(1);
            let mut ev: Array<MonsterEvent> = array![];
            let patches: Array<Patch> = array![];
            let ctx = Ctx { w, players, noise: silence(), tic: i };
            a_chase(ctx, mobjs, ref g, ref rng, ref mo, 1, patches.span(), ref ev);
            acc += mo.x.enc + rng.index.into();
            i += 1;
        }
    } else if op == 8 {
        // `A_Look` on a dormant monster the REJECT row answers for
        while i != n {
            let (p, mut mo) = one_chaser(w, ref g, i);
            mo.target = doom_physics::NO_MOBJ;
            mo.sight_expires = 0;
            let mobjs = array![p, mo].span();
            let mut rng: Prng = from_index(1);
            let mut ev: Array<MonsterEvent> = array![];
            let ctx = Ctx { w, players, noise: silence(), tic: i };
            acc += a_look(ctx, mobjs, ref rng, ref mo, 1, ref ev).into();
            i += 1;
        }
    } else if op == 9 {
        // `P_NewChaseDir`: the direction search, with its `P_TryWalk`s
        while i != n {
            let (p, mut mo) = one_chaser(w, ref g, i);
            let mobjs = array![p, mo].span();
            let mut rng: Prng = from_index(i);
            let mut ev: Array<MonsterEvent> = array![];
            let ctx = Ctx { w, players, noise: silence(), tic: i };
            new_chase_dir(ctx, mobjs, ref g, ref rng, ref mo, 1, @p, ref ev);
            acc += mo.x.enc + mo.move_dir.into();
            i += 1;
        }
    } else if op == 10 {
        // `P_CheckMissileRange`: the probability rule, sight cached
        while i != n {
            let (p, mut mo) = one_chaser(w, ref g, i);
            let mut rng: Prng = from_index(i);
            let ctx = Ctx { w, players, noise: silence(), tic: i };
            if check_missile_range(ctx, ref rng, ref mo, @p) {
                acc += 1;
            }
            i += 1;
        }
    } else if op == 11 {
        // the scheduler's own pass over the list (29 monsters)
        let mobjs = dormant_scene(w, ref g);
        while i != n {
            acc += awake_count(w, mobjs.span()).into() + i.into();
            i += 1;
        }
    } else if op == 12 {
        // noise: `A_Look` with a sound target the listener can hear
        let sector = bench_player(w, ref g, STAND_DX, STAND_DY).sector;
        let noise = Noise { source: 0, sector };
        while i != n {
            let (p, mut mo) = one_chaser(w, ref g, i);
            mo.target = doom_physics::NO_MOBJ;
            mo.sight_expires = 0;
            let mobjs = array![p, mo].span();
            let mut rng: Prng = from_index(1);
            let mut ev: Array<MonsterEvent> = array![];
            let ctx = Ctx { w, players, noise, tic: i };
            acc += a_look(ctx, mobjs, ref rng, ref mo, 1, ref ev).into();
            i += 1;
        }
    } else if op == 13 {
        // the 29 dormant monsters with nobody to look for: isolates what
        // `A_Look`'s sight test costs inside op 4
        let mut mobjs = dormant_scene(w, ref g);
        let none = array![].span();
        let mut rng: Prng = from_index(1);
        while i != n {
            let (next, r, _ev) = monsters_ticker(w, mobjs.span(), ref g, none, silence(), i, rng);
            mobjs = next;
            rng = r;
            i += 1;
        }
        acc += rng.index.into() + mobjs.len().into();
    } else if op == 14 {
        // `mobj_thinker` alone on a dormant monster, no look due: the floor
        // of a tic (the copy, the guards, `fsm::advance`, the plumbing)
        let mobjs = dormant_scene(w, ref g);
        let short = array![*mobjs.span().at(0), *mobjs.span().at(1)].span();
        let mut rng: Prng = from_index(1);
        let mut ev: Array<MonsterEvent> = array![];
        let mut patches: Array<Patch> = array![];
        let mut spawn_at: u32 = 2;
        while i != n {
            let mut mo = *short.at(1);
            let ctx = Ctx { w, players, noise: silence(), tic: i };
            if doom_monsters::think::mobj_thinker(
                ctx,
                short,
                ref g,
                ref rng,
                ref mo,
                1,
                false,
                true,
                ref patches,
                ref ev,
                ref spawn_at,
            ) {
                acc += 1;
            }
            i += 1;
        }
        acc += mobjs.len().into();
    } else if op == 15 {
        // the floor: rebuilding the 30-mobj list, one materialised copy per
        // slot, with no thinking at all. Everything above stands on this.
        let mobjs = dormant_scene(w, ref g);
        while i != n {
            let src = mobjs.span();
            let mut copy: Array<Mobj> = array![];
            let mut k: u32 = 0;
            while k != src.len() {
                let mut mo = *src.at(k);
                mo.tics = mo.tics % 64 + i;
                copy.append(mo);
                k += 1;
            }
            acc += copy.len().into();
            i += 1;
        }
    }
    acc
}
