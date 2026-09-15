// SPDX-License-Identifier: GPL-2.0-only
//! Step-cost benchmark for `doom_player` on Freedoom E1M1.
//!
//! Differential measurement (S1 §3.1) with **varying operands** and a
//! per-operation baseline (`base` in `budgets.json`): op 0 is the bare loop
//! and op 1 the operand builder every player op shares — a fresh copy of the
//! player record and of its mobj, plus the tic's [`Env`] (which boxes the
//! `World`). Restoring the two records on every iteration is what keeps a firing
//! run from emptying the clip and a damaged player from dying, so nothing
//! accumulates and nothing is hoisted.
//!
//! The player stands at E1M1's Player 1 start, linked in the thing grid.

use doom_map::{LevelId, genesis, load};
use doom_physics::{
    MF_SHOOTABLE, MF_SPECIAL, Mobj, NO_MOBJ, ThingGrid, World, new_grid, removed_mobj,
    set_thing_position, world_of,
};
use doom_player::{
    Env, Player, PlayerEvent, calc_height, damage_player, env_of, hit_thing, move_psprites,
    player_think, push_felts, spawn, touch_special, use_lines,
};
use doom_things::tables::{KIND_MISC2, KIND_POSSESSED};
use prng::from_index;
use ticcmd::TicCmd;

fn word(forward: i64, side: i64, buttons: u8) -> felt252 {
    ticcmd::encode(TicCmd { forward, side, angle_turn: 0, buttons })
}

/// A health bonus one unit away, varying with `i` so nothing is hoisted.
///
/// `kind` is derived from `i` too (`i - i` is a zero the compiler cannot
/// see): a literal there let the lowering specialise `touch_special` and
/// `take_health` on it, folding the 22-arm dispatch to the one arm this
/// measures — S7 §8 rule 7, and 950 words of a duplicate in `bench/size`.
fn bonus(i: u32) -> Mobj {
    let mut mo = removed_mobj();
    mo.kind = KIND_MISC2 + (i - i);
    mo.flags = MF_SPECIAL + 0x800000; // MF_COUNTITEM
    mo.z = fixed::from_units((i % 4).into());
    mo.height = fixed::from_units(16);
    mo
}

/// A shootable thing `dist` units straight in front of `base`, sized like a
/// former human.
///
/// It is what tells a *typical* shot from a *missed* one: `P_BulletSlope`
/// tries the player's own angle first and only widens by a degree either
/// side `if (!linetarget)`, so a shot with something in front of the barrel
/// costs one `P_AimLineAttack` and a shot into an empty hall costs three
/// (and the `P_LineAttack` that follows stops at the thing instead of
/// walking `MISSILERANGE` of cells).
fn target_in_front(base: Mobj, dist: felt252) -> Mobj {
    let (s, c) = bam::sin_cos(base.angle);
    let d = fixed::from_units(dist);
    let mut t = removed_mobj();
    // A real kind: `linkable` refuses to put a `KIND_NONE` (removed) thing
    // in the grid, so an aim trace would never see it.
    t.kind = KIND_POSSESSED;
    t.x = fixed::add(base.x, fixed::mul(d, c));
    t.y = fixed::add(base.y, fixed::mul(d, s));
    t.z = base.z;
    t.radius = fixed::from_units(20);
    t.height = fixed::from_units(56);
    t.flags = MF_SHOOTABLE;
    t.health = 60;
    t
}

#[executable]
fn main(op: u32, n: u32) -> felt252 {
    let m = load(LevelId::E1M1);
    let w: World = world_of(@m);
    let g0 = genesis(LevelId::E1M1);
    let (p0, mo0) = spawn(w, 0, g0.start, g0.angle);
    let mut base_p = p0;
    // Ready the pistol, as `doom_game` does at genesis.
    let ready = doom_player::chain(doom_player::WP_PISTOL).ready;
    base_p.psp_state = ready;
    base_p.psp_tics = *w.states.tics.at(ready);
    base_p.psp_sy = fixed::from_units(32);
    let mut g: ThingGrid = new_grid();
    let mut linked = mo0;
    set_thing_position(@w.map, ref g, ref linked, 0);
    let base_mo = linked;
    let mut rng = from_index(1);
    let mut acc: felt252 = 0;
    let mut i: u32 = 0;

    let idle = word(0, 0, 0);
    let walk = word(25, 0, 0);
    let fire = word(0, 0, 1);
    let use_it = word(0, 0, 2);

    if op == 0 { // bare loop
        while i != n {
            i += 1;
        }
    } else if op == 1 {
        // baseline: the two restored records and the tic's Env
        while i != n {
            let q = base_p;
            let mo = base_mo;
            let e = env_of(w, array![BoxTrait::new(mo)].span(), 0, i, 0);
            acc += q.health.into() + mo.x.enc + e.tic.into();
            i += 1;
        }
    } else if op == 2 {
        // P_PlayerThink, idle: no input, no buttons, the pistol ready
        while i != n {
            let mut q = base_p;
            let mut mo = base_mo;
            let e = env_of(w, array![BoxTrait::new(mo)].span(), 0, i, 0);
            let mut events: Array<PlayerEvent> = array![];
            player_think(e, ref g, ref rng, ref q, ref mo, idle, 0, false, ref events);
            acc += q.viewz.enc;
            i += 1;
        }
    } else if op == 3 {
        // P_PlayerThink, walking forward (thrust + the run frame)
        while i != n {
            let mut q = base_p;
            let mut mo = base_mo;
            let e = env_of(w, array![BoxTrait::new(mo)].span(), 0, i, 0);
            let mut events: Array<PlayerEvent> = array![];
            player_think(e, ref g, ref rng, ref q, ref mo, walk, 0, false, ref events);
            acc += mo.momx.enc;
            i += 1;
        }
    } else if op == 4 {
        // one psprite tic (the ready state's A_WeaponReady, no fire)
        while i != n {
            let mut q = base_p;
            let mut mo = base_mo;
            let e = env_of(w, array![BoxTrait::new(mo)].span(), 0, i, 0);
            let mut events: Array<PlayerEvent> = array![];
            move_psprites(e, ref g, ref rng, ref q, ref mo, ref events);
            acc += q.psp_sy.enc;
            i += 1;
        }
    } else if op == 5 {
        // P_TouchSpecialThing on a health bonus
        while i != n {
            let mut q = base_p;
            let mut mo = base_mo;
            let thing = bonus(i);
            if touch_special(ref q, ref mo, @thing) {
                acc += 1;
            }
            i += 1;
        }
    } else if op == 6 {
        // the serialization schema
        while i != n {
            let mut q = base_p;
            q.bonuscount = i % 7;
            let mo = base_mo;
            let mut out: Array<felt252> = array![];
            push_felts(ref out, @q);
            acc += out.len().into() + mo.x.enc;
            i += 1;
        }
    } else if op == 7 {
        // P_CalcHeight alone
        while i != n {
            let mut q = base_p;
            let mut mo = base_mo;
            mo.momx = fixed::from_units((i % 8).into());
            calc_height(ref q, @mo, i);
            acc += q.viewz.enc + mo.x.enc + q.health.into();
            i += 1;
        }
    } else if op == 8 {
        // P_UseLines: the USERANGE trace in front of the player
        while i != n {
            let mut mo = base_mo;
            mo.angle = mo.angle + i % 2;
            let e = env_of(w, array![BoxTrait::new(mo)].span(), 0, i, 2);
            let mut events: Array<PlayerEvent> = array![];
            use_lines(e, ref g, @mo, ref events);
            acc += events.len().into();
            i += 1;
        }
    } else if op == 9 {
        // P_PlayerThink with the trigger held: the whole A_FirePistol path
        // (P_BulletSlope's three P_AimLineAttack tries and one P_LineAttack)
        while i != n {
            let mut q = base_p;
            q.psp_state = doom_player::chain(doom_player::WP_PISTOL).attack;
            q.psp_tics = 1;
            let mut mo = base_mo;
            let e = env_of(w, array![BoxTrait::new(mo)].span(), 0, i, 1);
            let mut events: Array<PlayerEvent> = array![];
            player_think(e, ref g, ref rng, ref q, ref mo, fire, 0, false, ref events);
            acc += events.len().into();
            i += 1;
        }
    } else if op == 10 {
        // P_DamageMobj on the player, armor absorption included
        while i != n {
            let mut q = base_p;
            q.armor_type = 1;
            q.armor_points = 100;
            let mut mo = base_mo;
            let e = env_of(w, array![BoxTrait::new(mo)].span(), 0, i, 0);
            let mut events: Array<PlayerEvent> = array![];
            damage_player(
                e, ref g, ref rng, ref q, ref mo, ref events, NO_MOBJ, NO_MOBJ, 5 + i % 3, false,
            );
            acc += q.health.into();
            i += 1;
        }
    } else if op == 12 {
        // baseline: the two restored records, without the tic's Env -- the
        // baseline of the three ops that never build one
        while i != n {
            let q = base_p;
            let mo = base_mo;
            acc += q.health.into() + mo.x.enc + i.into();
            i += 1;
        }
    } else if op == 13 {
        // P_PlayerThink firing the pistol at a thing 128 units in front: the
        // typical shot, where `P_BulletSlope` short-circuits on the first
        // `P_AimLineAttack`. Compare with op 9, the same shot into the empty
        // hall (three aim traces and a 2 048-unit `P_LineAttack`).
        let mut tgt = target_in_front(base_mo, 128);
        set_thing_position(@w.map, ref g, ref tgt, 1);
        while i != n {
            let mut q = base_p;
            q.psp_state = doom_player::chain(doom_player::WP_PISTOL).attack;
            q.psp_tics = 1;
            let mut mo = base_mo;
            let e = env_of(w, array![BoxTrait::new(mo), BoxTrait::new(tgt)].span(), 0, i, 1);
            let mut events: Array<PlayerEvent> = array![];
            player_think(e, ref g, ref rng, ref q, ref mo, fire, 0, false, ref events);
            // 1000 per pellet that found the thing, so the caller can check
            // with `--print-program-output` that the target really was hit.
            let mut seen = events.span();
            while let Option::Some(ev) = seen.pop_front() {
                match *ev {
                    PlayerEvent::Shot((
                        h, _,
                    )) => {
                        acc += match hit_thing(h) {
                            Option::Some(_) => 1000,
                            Option::None => 1,
                        };
                    },
                    _ => {},
                }
            }
            i += 1;
        }
    } else if op == 11 {
        // P_PlayerThink with the use button held (the trace runs once, then
        // `usedown` latches): the edge case `doom_game` pays on a door press
        while i != n {
            let mut q = base_p;
            let mut mo = base_mo;
            let e = env_of(w, array![BoxTrait::new(mo)].span(), 0, i, 2);
            let mut events: Array<PlayerEvent> = array![];
            player_think(e, ref g, ref rng, ref q, ref mo, use_it, 0, false, ref events);
            acc += events.len().into();
            i += 1;
        }
    }
    acc
}

/// Keeps the unused-import checker honest about the two re-exported types the
/// signatures above mention.
fn _types(e: Env, p: Player) -> u32 {
    e.tic + p.health
}
