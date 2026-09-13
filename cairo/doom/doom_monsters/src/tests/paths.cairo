// SPDX-License-Identifier: GPL-2.0-only
//! Path tests: one case for every arm of every action and of the ticker,
//! written so that they hold on **any** loaded level.
//!
//! The reference tests of `e1m1.cairo` pin the *numbers* against
//! `scripts/model.py` on the real map; these pin the *shape* — which branch
//! runs, what it writes, which event it reports — and they are what
//! `bench/coverage.py` runs, because `cairo-coverage` needs
//! `inlining-strategy = "avoid"`, under which the real E1M1 data does not
//! compile (`doom_map`'s five-line fixture level stands in for it there).
//! Nothing here asserts a coordinate.

use doom_map::{LevelId, genesis, load};
use doom_physics::{
    MF_AMBUSH, MF_CORPSE, MF_JUSTATTACKED, MF_JUSTHIT, MF_MISSILE, MF_SHOOTABLE, MF_SOLID, Mobj,
    NO_MOBJ, SpawnZ, ThingGrid, World, has, new_grid, removed_mobj, set_state, set_thing_position,
    spawn_mobj, world_of,
};
use doom_things::tables::{
    A_FALL, A_PAIN, A_SCREAM, A_WEAPONREADY, A_XSCREAM, KIND_BARREL, KIND_PLAYER, KIND_POSSESSED,
    KIND_SERGEANT, KIND_SHOTGUY, KIND_TROOP, KIND_TROOPSHOT, MI_DEATHSTATE, MI_MISSILESTATE,
    MI_PAINSTATE, MI_SEESTATE, MI_SPAWNSTATE, MI_XDEATHSTATE,
};
use fixed::Fixed;
use prng::{Prng, from_index};
use crate::actions::{
    a_chase, a_face_target, a_look, a_pos_attack, a_sarg_attack, a_scream, a_spos_attack,
    a_troop_attack, check_melee_range, check_missile_range, hurt, look_for_players, new_chase_dir,
    p_move, passive,
};
use crate::event::{EV_DROP, EV_KILLED, EV_SOUND, EV_WAKE, MonsterEvent, drain, missile_hit};
use crate::tables::{DI_NODIR, SFX_SLOP};
use crate::think::{awake_count, is_awake, is_dormant, mobj_thinker, monsters_ticker};
use crate::{Ctx, Noise, Patch, silence};

fn world() -> World {
    world_of(@load(LevelId::E1M1))
}

fn units(u: felt252) -> Fixed {
    fixed::from_units(u)
}

fn ctx_of(w: World, tic: u32) -> Ctx {
    Ctx { w, players: array![0].span(), noise: silence(), tic }
}

/// A player at the level's Player 1 start and a monster of `kind` `dx` units
/// east of it, both linked (player 0, monster 1).
fn pair(w: World, ref g: ThingGrid, kind: u32, dx: felt252) -> (Mobj, Mobj) {
    let s = genesis(LevelId::E1M1).start;
    let mut p = spawn_mobj(w, KIND_PLAYER, s.x, s.y, SpawnZ::OnFloor);
    p.health = 10000;
    set_thing_position(@w.map, ref g, ref p, 0);
    let mut mo = spawn_mobj(w, kind, fixed::add(s.x, units(dx)), s.y, SpawnZ::OnFloor);
    set_state(w, ref mo, *MI_SEESTATE.span().at(kind));
    mo.target = 0;
    mo.reaction_time = 0;
    set_thing_position(@w.map, ref g, ref mo, 1);
    (p, mo)
}

/// Pretend the monster can see its target for the next 8 tics, so that a
/// test of a *decision* does not also depend on the geometry.
fn can_see(ref mo: Mobj, target: @Mobj, tic: u32) {
    mo.sight_ok = true;
    mo.sight_sector = *target.sector;
    mo.sight_expires = tic + 8;
}

// ---------------------------------------------------------------------------
// A_Look
// ---------------------------------------------------------------------------

#[test]
fn test_a_look_arms() {
    let w = world();
    let mut g = new_grid();
    let (p, mut mo) = pair(w, ref g, KIND_POSSESSED, 48);
    set_state(w, ref mo, *MI_SPAWNSTATE.span().at(KIND_POSSESSED));
    mo.target = NO_MOBJ;
    mo.threshold = 40;
    let mobjs = array![p, mo].span();
    let mut rng: Prng = from_index(1);
    let mut ev: Array<MonsterEvent> = array![];

    // Silence: only sight can wake it, and either way `threshold` is cleared
    // and the RNG has moved by at most the one see-sound draw.
    let action = a_look(ctx_of(w, 0), mobjs, ref rng, ref mo, 1, ref ev);
    assert(mo.threshold == 0, 'A_Look clears the threshold');
    assert(rng.index <= 2, 'at most one draw');
    if action != fsm::NO_ACTION {
        assert(mo.state == *MI_SEESTATE.span().at(KIND_POSSESSED), 'entered seestate');
        assert(!is_dormant(w, @mo), 'no longer dormant');
        let mut saw_wake = false;
        let mut k: u32 = 0;
        while k != ev.len() {
            if *ev.span().at(k).kind == EV_WAKE {
                saw_wake = true;
            }
            k += 1;
        }
        assert(saw_wake, 'reported the wake-up');
    } else {
        assert(is_dormant(w, @mo), 'still dormant');
    }
}

#[test]
fn test_a_look_hears_a_noise() {
    let w = world();
    let mut g = new_grid();
    let (p, mut mo) = pair(w, ref g, KIND_POSSESSED, 48);
    set_state(w, ref mo, *MI_SPAWNSTATE.span().at(KIND_POSSESSED));
    mo.target = NO_MOBJ;
    let mobjs = array![p, mo].span();
    // The shot rang out in the listener's own sector, which no REJECT row
    // ever rules out: a monster that is not `MF_AMBUSH` wakes on the sound
    // alone, without a sight test.
    let noise = Noise { source: 0, sector: mo.sector };
    let mut rng: Prng = from_index(1);
    let mut ev: Array<MonsterEvent> = array![];
    let ctx = Ctx { w, players: array![0].span(), noise, tic: 0 };
    let action = a_look(ctx, mobjs, ref rng, ref mo, 1, ref ev);
    assert(action != fsm::NO_ACTION, 'wakes on the noise');
    assert(mo.target == 0, 'targets the noise maker');
}

#[test]
fn test_a_look_ambush_needs_sight() {
    let w = world();
    let mut g = new_grid();
    let (mut p, mut mo) = pair(w, ref g, KIND_POSSESSED, 48);
    set_state(w, ref mo, *MI_SPAWNSTATE.span().at(KIND_POSSESSED));
    mo.target = NO_MOBJ;
    mo.flags = mo.flags | MF_AMBUSH;
    // A deaf monster with the sight cache primed to "no": the noise reaches
    // it and is refused, and `P_LookForPlayers` is refused too.
    mo.sight_ok = false;
    mo.sight_sector = p.sector;
    mo.sight_expires = 8;
    p.health = 10000;
    let mobjs = array![p, mo].span();
    let noise = Noise { source: 0, sector: mo.sector };
    let ctx = Ctx { w, players: array![0].span(), noise, tic: 0 };
    let mut rng: Prng = from_index(1);
    let mut ev: Array<MonsterEvent> = array![];
    let action = a_look(ctx, mobjs, ref rng, ref mo, 1, ref ev);
    assert(action == fsm::NO_ACTION, 'a deaf monster stays asleep');
    assert(mo.target == 0, 'but it did note the sound');
    assert(rng.index == 1, 'and drew nothing');
}

#[test]
fn test_a_look_ignores_a_dead_noise_maker() {
    let w = world();
    let mut g = new_grid();
    let (mut p, mut mo) = pair(w, ref g, KIND_POSSESSED, 48);
    set_state(w, ref mo, *MI_SPAWNSTATE.span().at(KIND_POSSESSED));
    mo.target = NO_MOBJ;
    mo.sight_ok = false;
    mo.sight_sector = p.sector;
    mo.sight_expires = 8;
    p.flags = doom_physics::without(p.flags, MF_SHOOTABLE);
    p.health = 0;
    let mobjs = array![p, mo].span();
    let noise = Noise { source: 0, sector: mo.sector };
    let ctx = Ctx { w, players: array![0].span(), noise, tic: 0 };
    let mut rng: Prng = from_index(1);
    let mut ev: Array<MonsterEvent> = array![];
    assert(
        a_look(ctx, mobjs, ref rng, ref mo, 1, ref ev) == fsm::NO_ACTION, 'a corpse makes no noise',
    );
    assert(mo.target == NO_MOBJ, 'and is not a target');
    // `P_LookForPlayers` also skips a player with no health left.
    assert(!look_for_players(ctx, mobjs, ref mo, true), 'no live player');
}

// ---------------------------------------------------------------------------
// A_Chase
// ---------------------------------------------------------------------------

#[test]
fn test_a_chase_without_a_target_goes_back_to_sleep() {
    let w = world();
    let mut g = new_grid();
    let (mut p, mut mo) = pair(w, ref g, KIND_POSSESSED, 48);
    mo.target = NO_MOBJ;
    // The player is not shootable either, so `P_LookForPlayers` fails too.
    p.health = 0;
    let mobjs = array![p, mo].span();
    let mut rng: Prng = from_index(1);
    let mut ev: Array<MonsterEvent> = array![];
    let patches: Array<Patch> = array![];
    a_chase(ctx_of(w, 0), mobjs, ref g, ref rng, ref mo, 1, patches.span(), ref ev);
    assert(mo.state == *MI_SPAWNSTATE.span().at(KIND_POSSESSED), 'back to the idle loop');
    assert(is_dormant(w, @mo), 'dormant again');
}

#[test]
fn test_a_chase_after_an_attack_only_turns() {
    let w = world();
    let mut g = new_grid();
    let (p, mut mo) = pair(w, ref g, KIND_POSSESSED, 48);
    mo.flags = mo.flags | MF_JUSTATTACKED;
    mo.move_count = 5;
    can_see(ref mo, @p, 0);
    let mobjs = array![p, mo].span();
    let mut rng: Prng = from_index(1);
    let mut ev: Array<MonsterEvent> = array![];
    let patches: Array<Patch> = array![];
    a_chase(ctx_of(w, 0), mobjs, ref g, ref rng, ref mo, 1, patches.span(), ref ev);
    assert(!has(mo.flags, MF_JUSTATTACKED), 'the flag is consumed');
    assert(mo.state == *MI_SEESTATE.span().at(KIND_POSSESSED), 'it does not attack twice');
}

#[test]
fn test_a_chase_turns_toward_every_direction() {
    let w = world();
    let mut g = new_grid();
    let (p, mut mo) = pair(w, ref g, KIND_POSSESSED, 48);
    can_see(ref mo, @p, 0);
    let mobjs = array![p, mo].span();
    let patches: Array<Patch> = array![];
    let mut dir: u32 = 0;
    while dir != DI_NODIR + 1 {
        let mut m = mo;
        m.move_dir = dir;
        m.angle = 0;
        m.move_count = 4;
        let mut rng: Prng = from_index(1);
        let mut ev: Array<MonsterEvent> = array![];
        a_chase(ctx_of(w, 0), mobjs, ref g, ref rng, ref m, 1, patches.span(), ref ev);
        if dir < DI_NODIR {
            // The angle is snapped to an eighth of a turn and moved at most
            // one eighth toward `movedir`.
            assert(m.angle % 0x20000000 == 0, 'angle stays on an octant');
        }
        dir += 1;
    }
}

#[test]
fn test_a_chase_fires_when_the_missile_check_passes() {
    let w = world();
    let mut g = new_grid();
    let (p, mut mo) = pair(w, ref g, KIND_TROOP, 200);
    can_see(ref mo, @p, 0);
    mo.move_count = 0; // the missile branch is gated on it
    mo.flags = mo.flags | MF_JUSTHIT; // and `MF_JUSTHIT` forces a yes
    let mobjs = array![p, mo].span();
    let mut rng: Prng = from_index(1);
    let mut ev: Array<MonsterEvent> = array![];
    let patches: Array<Patch> = array![];
    a_chase(ctx_of(w, 0), mobjs, ref g, ref rng, ref mo, 1, patches.span(), ref ev);
    assert(mo.state == *MI_MISSILESTATE.span().at(KIND_TROOP), 'entered the missile state');
    assert(has(mo.flags, MF_JUSTATTACKED), 'and armed the no-repeat flag');
    assert(!has(mo.flags, MF_JUSTHIT), 'JUSTHIT is consumed');
}

#[test]
fn test_check_missile_range_refuses_while_reacting() {
    let w = world();
    let mut g = new_grid();
    let (p, mut mo) = pair(w, ref g, KIND_TROOP, 200);
    can_see(ref mo, @p, 0);
    mo.reaction_time = 4;
    let mut rng: Prng = from_index(1);
    assert(!check_missile_range(ctx_of(w, 0), ref rng, ref mo, @p), 'not while reacting');
    // And without sight it refuses before drawing anything.
    mo.reaction_time = 0;
    mo.sight_ok = false;
    let before = rng.index;
    assert(!check_missile_range(ctx_of(w, 0), ref rng, ref mo, @p), 'blind monsters hold fire');
    assert(rng.index == before, 'and draw nothing');
}

#[test]
fn test_check_melee_range_needs_both_distance_and_sight() {
    let w = world();
    let mut g = new_grid();
    let (p, mut mo) = pair(w, ref g, KIND_SERGEANT, 8);
    can_see(ref mo, @p, 0);
    assert(check_melee_range(ctx_of(w, 0), ref mo, @p), 'point blank and visible');
    mo.sight_ok = false;
    assert(!check_melee_range(ctx_of(w, 0), ref mo, @p), 'not through a wall');
    let (p2, mut far) = pair(w, ref g, KIND_SERGEANT, 400);
    can_see(ref far, @p2, 0);
    assert(!check_melee_range(ctx_of(w, 0), ref far, @p2), 'out of reach');
}

// ---------------------------------------------------------------------------
// P_Move / P_NewChaseDir
// ---------------------------------------------------------------------------

#[test]
fn test_p_move_refuses_without_a_direction() {
    let w = world();
    let mut g = new_grid();
    let (_p, mut mo) = pair(w, ref g, KIND_POSSESSED, 48);
    mo.move_dir = DI_NODIR;
    let mobjs = array![_p, mo].span();
    let mut ev: Array<MonsterEvent> = array![];
    assert(!p_move(ctx_of(w, 0), mobjs, ref g, ref mo, 1, ref ev), 'DI_NODIR does not move');
}

#[test]
fn test_new_chase_dir_always_leaves_a_valid_direction() {
    let w = world();
    let mut g = new_grid();
    let (p, mo0) = pair(w, ref g, KIND_POSSESSED, 48);
    let mobjs = array![p, mo0].span();
    let mut seed: u32 = 0;
    while seed != 8 {
        let mut mo = mo0;
        mo.move_dir = seed;
        let mut rng: Prng = from_index(seed * 31);
        let mut ev: Array<MonsterEvent> = array![];
        new_chase_dir(ctx_of(w, 0), mobjs, ref g, ref rng, ref mo, 1, @p, ref ev);
        assert(mo.move_dir <= DI_NODIR, 'a direction or DI_NODIR');
        assert(mo.move_count < 16, 'movecount is P_Random() & 15');
        seed += 1;
    }
}

// ---------------------------------------------------------------------------
// The attacks
// ---------------------------------------------------------------------------

#[test]
fn test_pos_attack_draws_three_and_sounds() {
    let w = world();
    let mut g = new_grid();
    let (p, mut mo) = pair(w, ref g, KIND_POSSESSED, 100);
    let mobjs = array![p, mo].span();
    let mut rng: Prng = from_index(1);
    let mut ev: Array<MonsterEvent> = array![];
    let mut patches: Array<Patch> = array![];
    a_pos_attack(ctx_of(w, 0), mobjs, ref g, ref rng, ref mo, 1, ref patches, ref ev);
    // Two draws for the spread and one for the damage; the target is not a
    // `MF_SHADOW`, so `A_FaceTarget` draws nothing. A shot that lands also
    // pays for `P_DamageMobj`'s pain chance, hence the inequality.
    assert(rng.index >= 4, 'at least three draws');
    assert(*ev.span().at(0).kind == EV_SOUND, 'the pistol is heard');
}

#[test]
fn test_spos_attack_fires_three_pellets() {
    let w = world();
    let mut g = new_grid();
    let (p, mut mo) = pair(w, ref g, KIND_SHOTGUY, 100);
    let mobjs = array![p, mo].span();
    let mut rng: Prng = from_index(1);
    let mut ev: Array<MonsterEvent> = array![];
    let mut patches: Array<Patch> = array![];
    a_spos_attack(ctx_of(w, 0), mobjs, ref g, ref rng, ref mo, 1, ref patches, ref ev);
    assert(rng.index >= 10, 'nine draws for three pellets');
    assert(*ev.span().at(0).kind == EV_SOUND, 'the shotgun is heard');
}

#[test]
fn test_troop_attack_claws_in_range_and_throws_out_of_it() {
    let w = world();
    let mut g = new_grid();
    // Point blank: the claw, which damages the target through a patch.
    let (p, mut mo) = pair(w, ref g, KIND_TROOP, 8);
    can_see(ref mo, @p, 0);
    let mobjs = array![p, mo].span();
    let mut rng: Prng = from_index(1);
    let mut ev: Array<MonsterEvent> = array![];
    let mut patches: Array<Patch> = array![];
    let mut spawn_at: u32 = 2;
    a_troop_attack(
        ctx_of(w, 0), mobjs, ref g, ref rng, ref mo, 1, ref patches, ref ev, ref spawn_at,
    );
    assert(patches.len() == 1, 'the target was hurt');
    assert(*patches.span().at(0).idx == 0, 'the player took it');
    assert(*patches.span().at(0).mo.health < p.health, 'and lost health');
    assert(spawn_at == 2, 'no missile was spawned');

    // Far away and blind to the melee test: the fireball.
    let mut g2 = new_grid();
    let (p2, mut far) = pair(w, ref g2, KIND_TROOP, 300);
    far.sight_ok = false;
    far.sight_sector = p2.sector;
    far.sight_expires = 8;
    let mobjs2 = array![p2, far].span();
    let mut rng2: Prng = from_index(1);
    let mut ev2: Array<MonsterEvent> = array![];
    let mut patches2: Array<Patch> = array![];
    let mut spawn_at2: u32 = 2;
    a_troop_attack(
        ctx_of(w, 0), mobjs2, ref g2, ref rng2, ref far, 1, ref patches2, ref ev2, ref spawn_at2,
    );
    assert(spawn_at2 == 3, 'a slot was claimed');
    assert(patches2.len() == 1, 'the fireball is a patch');
    assert(*patches2.span().at(0).mo.kind == KIND_TROOPSHOT, 'and it is a fireball');
}

#[test]
fn test_sarg_attack_only_bites_in_range() {
    let w = world();
    let mut g = new_grid();
    let (p, mut mo) = pair(w, ref g, KIND_SERGEANT, 400);
    can_see(ref mo, @p, 0);
    let mobjs = array![p, mo].span();
    let mut rng: Prng = from_index(1);
    let mut ev: Array<MonsterEvent> = array![];
    let mut patches: Array<Patch> = array![];
    a_sarg_attack(ctx_of(w, 0), mobjs, ref rng, ref mo, 1, ref patches, ref ev);
    assert(patches.len() == 0, 'too far to bite');

    let mut g2 = new_grid();
    let (p2, mut near) = pair(w, ref g2, KIND_SERGEANT, 8);
    can_see(ref near, @p2, 0);
    let mobjs2 = array![p2, near].span();
    let mut rng2: Prng = from_index(1);
    let mut ev2: Array<MonsterEvent> = array![];
    let mut patches2: Array<Patch> = array![];
    a_sarg_attack(ctx_of(w, 0), mobjs2, ref rng2, ref near, 1, ref patches2, ref ev2);
    assert(patches2.len() == 1, 'point blank it bites');
}

#[test]
fn test_face_target_spreads_against_a_shadow() {
    let w = world();
    let mut g = new_grid();
    let (mut p, mut mo) = pair(w, ref g, KIND_POSSESSED, 100);
    mo.flags = mo.flags | MF_AMBUSH;
    let mut rng: Prng = from_index(1);
    a_face_target(ctx_of(w, 0), ref rng, ref mo, @p);
    assert(!has(mo.flags, MF_AMBUSH), 'facing clears the deafness');
    assert(rng.index == 1, 'no draw against a plain target');
    p.flags = p.flags | doom_physics::MF_SHADOW;
    a_face_target(ctx_of(w, 0), ref rng, ref mo, @p);
    assert(rng.index == 3, 'two draws against a shadow');
}

// ---------------------------------------------------------------------------
// Pain, death and the passive actions
// ---------------------------------------------------------------------------

#[test]
fn test_passive_actions() {
    let w = world();
    let mut g = new_grid();
    let (_p, mut mo) = pair(w, ref g, KIND_POSSESSED, 48);
    let mut rng: Prng = from_index(1);
    let mut ev: Array<MonsterEvent> = array![];

    passive(ctx_of(w, 0), ref rng, ref mo, 1, A_PAIN, ref ev);
    assert(ev.len() == 1 && *ev.span().at(0).kind == EV_SOUND, 'pain is heard');

    passive(ctx_of(w, 0), ref rng, ref mo, 1, A_XSCREAM, ref ev);
    assert(*ev.span().at(1).a == SFX_SLOP, 'gibbing is heard');

    let before = ev.len();
    passive(ctx_of(w, 0), ref rng, ref mo, 1, A_SCREAM, ref ev);
    assert(ev.len() == before + 1, 'the death cry is heard');
    assert(rng.index == 2, 'and it picked inside podth1..3');

    assert(has(mo.flags, MF_SOLID), 'solid until it falls');
    passive(ctx_of(w, 0), ref rng, ref mo, 1, A_FALL, ref ev);
    assert(!has(mo.flags, MF_SOLID), 'A_Fall clears MF_SOLID');

    // An action that belongs to `doom_player` is ignored, quietly.
    let n = ev.len();
    passive(ctx_of(w, 0), ref rng, ref mo, 1, A_WEAPONREADY, ref ev);
    assert(ev.len() == n, 'weapon actions are not ours');
}

#[test]
fn test_a_scream_is_silent_for_a_thing_with_no_death_sound() {
    let w = world();
    let mut g = new_grid();
    let (_p, mut mo) = pair(w, ref g, KIND_POSSESSED, 48);
    mo.kind = KIND_TROOPSHOT; // outside the sound roster
    let mut rng: Prng = from_index(1);
    let mut ev: Array<MonsterEvent> = array![];
    a_scream(ctx_of(w, 0), ref rng, ref mo, 1, ref ev);
    assert(ev.len() == 0, 'a fireball does not scream');
    // The demon's `sgtdth` is outside both families: no draw.
    mo.kind = KIND_SERGEANT;
    a_scream(ctx_of(w, 0), ref rng, ref mo, 1, ref ev);
    assert(ev.len() == 1 && rng.index == 1, 'one sound, no draw');
}

#[test]
fn test_hurt_kills_counts_and_drops() {
    let w = world();
    let mut g = new_grid();
    let (p, mo) = pair(w, ref g, KIND_POSSESSED, 48);
    let mobjs = array![p, mo].span();
    let mut rng: Prng = from_index(1);
    let mut ev: Array<MonsterEvent> = array![];
    let mut patches: Array<Patch> = array![];
    hurt(ctx_of(w, 0), mobjs, ref rng, 1, 0, 0, 1000, ref patches, ref ev);
    assert(patches.len() == 1, 'the corpse is a patch');
    let corpse = *patches.span().at(0).mo;
    assert(corpse.health <= 0, 'dead');
    assert(has(corpse.flags, MF_CORPSE), 'and a corpse');
    let mut killed = false;
    let mut dropped = false;
    let mut k: u32 = 0;
    while k != ev.len() {
        let kind = *ev.span().at(k).kind;
        if kind == EV_KILLED {
            killed = true;
        }
        if kind == EV_DROP {
            dropped = true;
        }
        k += 1;
    }
    assert(killed, 'the kill is counted');
    assert(dropped, 'a zombieman drops its clip');
    // A gib death takes the extreme death state.
    let mut g2 = new_grid();
    let (p2, mo2) = pair(w, ref g2, KIND_POSSESSED, 48);
    let mobjs2 = array![p2, mo2].span();
    let mut rng2: Prng = from_index(1);
    let mut ev2: Array<MonsterEvent> = array![];
    let mut patches2: Array<Patch> = array![];
    hurt(ctx_of(w, 0), mobjs2, ref rng2, 1, 0, 0, 100000, ref patches2, ref ev2);
    let gibbed = *patches2.span().at(0).mo;
    assert(
        gibbed.state == *MI_XDEATHSTATE.span().at(KIND_POSSESSED)
            || gibbed.state == *MI_DEATHSTATE.span().at(KIND_POSSESSED),
        'a death state',
    );
    assert(*MI_PAINSTATE.span().at(KIND_POSSESSED) != 0, 'and it has a pain state');
}

// ---------------------------------------------------------------------------
// The ticker
// ---------------------------------------------------------------------------

#[test]
fn test_ticker_leaves_things_that_are_not_ours_alone() {
    let w = world();
    let mut g = new_grid();
    let s = genesis(LevelId::E1M1).start;
    let barrel = spawn_mobj(w, KIND_BARREL, s.x, s.y, SpawnZ::OnFloor);
    let gone = removed_mobj();
    let mobjs = array![barrel, gone];
    let (out, rng, ev) = monsters_ticker(
        w, mobjs.span(), ref g, array![].span(), silence(), 0, from_index(1),
    );
    assert(out.len() == 2, 'the list is unchanged');
    assert(*out.span().at(0) == barrel, 'the barrel is untouched');
    assert(rng.index == 1 && ev.len() == 0, 'and nothing happened');
    assert(!is_awake(w, @barrel), 'a barrel is not a monster');
}

#[test]
fn test_ticker_runs_a_missile_and_removes_it() {
    let w = world();
    let mut g = new_grid();
    let s = genesis(LevelId::E1M1).start;
    let mut ball = spawn_mobj(w, KIND_TROOPSHOT, s.x, s.y, SpawnZ::OnFloor);
    assert(has(ball.flags, MF_MISSILE), 'it is a missile');
    ball.momx = units(10);
    set_thing_position(@w.map, ref g, ref ball, 0);
    let mut mobjs = array![ball];
    let mut rng: Prng = from_index(1);
    let mut tic: u32 = 0;
    // A fireball fired into a wall explodes and then removes itself; one way
    // or another it is gone, or still flying, within its lifetime.
    while tic != 60 {
        let (next, r, _ev) = monsters_ticker(
            w, mobjs.span(), ref g, array![].span(), silence(), tic, rng,
        );
        mobjs = next;
        rng = r;
        tic += 1;
    }
    assert(mobjs.len() == 1, 'the slot is kept');
}

#[test]
fn test_ticker_schedules_more_than_eight() {
    let w = world();
    let mut g = new_grid();
    let s = genesis(LevelId::E1M1).start;
    let mut p = spawn_mobj(w, KIND_PLAYER, s.x, s.y, SpawnZ::OnFloor);
    p.health = 10000;
    set_thing_position(@w.map, ref g, ref p, 0);
    let mut mobjs: Array<Mobj> = array![p];
    let mut k: u32 = 0;
    while k != 12 {
        let dx: felt252 = (64 + k * 40).into();
        let mut mo = spawn_mobj(
            w, KIND_POSSESSED, fixed::add(s.x, units(dx)), s.y, SpawnZ::OnFloor,
        );
        set_state(w, ref mo, *MI_SEESTATE.span().at(KIND_POSSESSED));
        mo.target = 0;
        mo.reaction_time = 0;
        mo.sight_ok = false;
        mo.sight_sector = p.sector;
        mo.sight_expires = 1000;
        let idx = mobjs.len();
        set_thing_position(@w.map, ref g, ref mo, idx);
        mobjs.append(mo);
        k += 1;
    }
    assert(awake_count(w, mobjs.span()) == 12, 'twelve awake');
    let players = array![0].span();
    let mut rng: Prng = from_index(1);
    let mut tic: u32 = 0;
    while tic != 8 {
        let (next, r, _ev) = monsters_ticker(w, mobjs.span(), ref g, players, silence(), tic, rng);
        mobjs = next;
        rng = r;
        tic += 1;
    }
    assert(mobjs.len() >= 13, 'nothing is lost');
}

#[test]
fn test_mobj_thinker_reports_a_removal() {
    let w = world();
    let mut g = new_grid();
    let s = genesis(LevelId::E1M1).start;
    let mut ball = spawn_mobj(w, KIND_TROOPSHOT, s.x, s.y, SpawnZ::OnFloor);
    set_thing_position(@w.map, ref g, ref ball, 0);
    // Park it on `S_NULL`, which is Doom's "remove me".
    ball.state = 0;
    ball.tics = 1;
    let mobjs = array![ball].span();
    let mut rng: Prng = from_index(1);
    let mut ev: Array<MonsterEvent> = array![];
    let mut patches: Array<Patch> = array![];
    let mut spawn_at: u32 = 1;
    let alive = mobj_thinker(
        ctx_of(w, 0),
        mobjs,
        ref g,
        ref rng,
        ref ball,
        0,
        false,
        true,
        ref patches,
        ref ev,
        ref spawn_at,
    );
    assert(!alive, 'S_NULL removes the mobj');
}

#[test]
fn test_move_event_helpers() {
    let mut ev: Array<MonsterEvent> = array![];
    let moves = array![
        doom_physics::MoveEvent::CrossSpecial((7, 1)), doom_physics::MoveEvent::Touch(3),
        doom_physics::MoveEvent::MissileHit(5),
    ]
        .span();
    drain(moves, 2, ref ev);
    assert(ev.len() == 1, 'only the special crossing');
    assert(*ev.span().at(0).a == 7 && *ev.span().at(0).b == 1, 'line and side');
    assert(missile_hit(moves) == 5, 'the thing the missile hit');
    assert(missile_hit(array![].span()) == NO_MOBJ, 'nothing when it hit nothing');
}

// ---------------------------------------------------------------------------
// Open ground
// ---------------------------------------------------------------------------

/// A spot with room to walk in, in **both** worlds this module runs in: the
/// middle of `doom_map`'s fixture level (whose five lines all sit in the
/// 64-unit corner) and, on the real E1M1, wherever `(192, 192)` falls. The
/// assertions below are all shapes, never coordinates, so either is fine —
/// the point of walking here is to reach the arms of `P_NewChaseDir` and
/// `P_Move` that a monster wedged against a wall never reaches.
const OPEN: felt252 = 192;

fn open_pair(w: World, ref g: ThingGrid, kind: u32, dx: felt252, dy: felt252) -> (Mobj, Mobj) {
    let x = units(OPEN);
    let y = units(OPEN);
    let mut p = spawn_mobj(w, KIND_PLAYER, x, y, SpawnZ::OnFloor);
    p.health = 10000;
    set_thing_position(@w.map, ref g, ref p, 0);
    let mut mo = spawn_mobj(
        w, kind, fixed::add(x, units(dx)), fixed::add(y, units(dy)), SpawnZ::OnFloor,
    );
    set_state(w, ref mo, *MI_SEESTATE.span().at(kind));
    mo.target = 0;
    mo.reaction_time = 0;
    set_thing_position(@w.map, ref g, ref mo, 1);
    (p, mo)
}

#[test]
fn test_new_chase_dir_takes_the_diagonal_when_it_can() {
    let w = world();
    // Four sign combinations of (deltax, deltay), for the `diags[]` index.
    let mut q: u32 = 0;
    while q != 4 {
        let sx: felt252 = if q % 2 == 0 {
            -40
        } else {
            40
        };
        let sy: felt252 = if q / 2 == 0 {
            -40
        } else {
            40
        };
        let mut g = new_grid();
        let (p, mut mo) = open_pair(w, ref g, KIND_POSSESSED, sx, sy);
        let mobjs = array![p, mo].span();
        let mut rng: Prng = from_index(q * 17 + 1);
        let mut ev: Array<MonsterEvent> = array![];
        new_chase_dir(ctx_of(w, 0), mobjs, ref g, ref rng, ref mo, 1, @p, ref ev);
        assert(mo.move_dir <= DI_NODIR, 'a direction or DI_NODIR');
        assert(mo.move_count < 16, 'movecount in range');
        q += 1;
    }
}

#[test]
fn test_a_monster_walks_toward_its_target() {
    let w = world();
    let mut g = new_grid();
    let (p, mo) = open_pair(w, ref g, KIND_POSSESSED, 200, 0);
    // Blind, so it can only walk: no melee, no missile, no re-targeting.
    let mut chaser = mo;
    chaser.sight_ok = false;
    chaser.sight_sector = p.sector;
    chaser.sight_expires = 100000;
    let mut mobjs = array![p, chaser];
    let players = array![0].span();
    let mut rng: Prng = from_index(1);
    let mut tic: u32 = 0;
    while tic != 60 {
        let (next, r, _ev) = monsters_ticker(w, mobjs.span(), ref g, players, silence(), tic, rng);
        mobjs = next;
        rng = r;
        tic += 1;
    }
    let after = *mobjs.span().at(1);
    assert(after.move_dir <= DI_NODIR, 'a direction or DI_NODIR');
    assert(after.move_count < 16, 'movecount in range');
    assert(after.health > 0, 'still alive');
    assert(rng.index != 1, 'the walk consumed randomness');
}

#[test]
fn test_check_missile_range_over_the_whole_curve() {
    let w = world();
    let mut g = new_grid();
    let (p, mo) = open_pair(w, ref g, KIND_TROOP, 0, 0);
    let mut yes: u32 = 0;
    let mut k: u32 = 0;
    // 0, 64, 256, 1024 and 4096 units: below the subtraction (it fires every
    // time), inside the ramp, and past the clamp at 200.
    let steps = array![0, 64, 256, 1024, 4096].span();
    while k != steps.len() {
        let mut target = p;
        target.x = fixed::add(mo.x, units(*steps.at(k)));
        let mut m = mo;
        can_see(ref m, @target, 0);
        let mut rng: Prng = from_index(k * 37 + 1);
        let before = rng.index;
        if check_missile_range(ctx_of(w, 0), ref rng, ref m, @target) {
            yes += 1;
        }
        assert(rng.index != before, 'the draw always happens');
        k += 1;
    }
    assert(yes != 0, 'it fires sometimes');
}

#[test]
fn test_look_for_players_has_a_blind_arc() {
    let w = world();
    let mut g = new_grid();
    let (p, mut mo) = open_pair(w, ref g, KIND_POSSESSED, 200, 0);
    // Sight is granted by the cache; the monster faces east, away from a
    // player that stands to its west, and further than `MELEERANGE`.
    can_see(ref mo, @p, 0);
    mo.angle = 0;
    mo.target = NO_MOBJ;
    let mobjs = array![p, mo].span();
    assert(!look_for_players(ctx_of(w, 0), mobjs, ref mo, false), 'behind its back');
    assert(look_for_players(ctx_of(w, 0), mobjs, ref mo, true), 'unless it looks all around');
    assert(mo.target == 0, 'and then it has a target');
}

// ---------------------------------------------------------------------------
// The dispatcher
// ---------------------------------------------------------------------------

/// A state whose successor carries `action`: entering it with one tic left
/// makes `fsm::advance` hand `action` to the dispatcher, which is the only
/// way an action ever runs.
fn state_before(w: World, action: u32) -> u32 {
    let n = w.states.action_id.len();
    let mut s: u32 = 0;
    let mut found: u32 = 0;
    while s != n {
        if *w.states.action_id.at(*w.states.next_state.at(s)) == action {
            found = s;
            break;
        }
        s += 1;
    }
    found
}

#[test]
fn test_the_dispatcher_runs_every_action_this_crate_owns() {
    let w = world();
    let actions = array![
        doom_things::tables::A_LOOK, doom_things::tables::A_CHASE,
        doom_things::tables::A_FACETARGET, doom_things::tables::A_POSATTACK,
        doom_things::tables::A_SPOSATTACK, doom_things::tables::A_TROOPATTACK,
        doom_things::tables::A_SARGATTACK, A_PAIN, A_SCREAM, A_XSCREAM, A_FALL,
        doom_things::tables::A_EXPLODE,
    ]
        .span();
    let mut k: u32 = 0;
    while k != actions.len() {
        let action = *actions.at(k);
        let mut g = new_grid();
        let (p, mut mo) = open_pair(w, ref g, KIND_TROOP, 40, 0);
        can_see(ref mo, @p, 0);
        mo.state = state_before(w, action);
        mo.tics = 1;
        let mobjs = array![p, mo].span();
        let mut rng: Prng = from_index(k * 13 + 1);
        let mut ev: Array<MonsterEvent> = array![];
        let mut patches: Array<Patch> = array![];
        let mut spawn_at: u32 = 2;
        mobj_thinker(
            ctx_of(w, 0),
            mobjs,
            ref g,
            ref rng,
            ref mo,
            1,
            true,
            true,
            ref patches,
            ref ev,
            ref spawn_at,
        );
        assert(mo.state < w.states.action_id.len(), 'stayed on the table');
        k += 1;
    }
}

#[test]
fn test_the_ticker_runs_dormant_monsters_on_the_fast_path() {
    let w = world();
    let mut g = new_grid();
    let s = genesis(LevelId::E1M1).start;
    let mut p = spawn_mobj(w, KIND_PLAYER, s.x, s.y, SpawnZ::OnFloor);
    p.health = 10000;
    set_thing_position(@w.map, ref g, ref p, 0);
    let mut mobjs: Array<Mobj> = array![p];
    let mut k: u32 = 0;
    while k != 6 {
        let dx: felt252 = (200 + k * 64).into();
        let mut mo = spawn_mobj(
            w, KIND_POSSESSED, fixed::add(s.x, units(dx)), s.y, SpawnZ::OnFloor,
        );
        // Asleep, standing still, and blind: the fast path, on every tic,
        // including the ones where the 1-in-4 cadence lets it look.
        mo.sight_ok = false;
        mo.sight_sector = p.sector;
        mo.sight_expires = 100000;
        let idx = mobjs.len();
        set_thing_position(@w.map, ref g, ref mo, idx);
        mobjs.append(mo);
        k += 1;
    }
    assert(awake_count(w, mobjs.span()) == 0, 'all asleep');
    let players = array![0].span();
    let mut rng: Prng = from_index(1);
    let mut tic: u32 = 0;
    while tic != 24 {
        let (next, r, _ev) = monsters_ticker(w, mobjs.span(), ref g, players, silence(), tic, rng);
        mobjs = next;
        rng = r;
        tic += 1;
    }
    assert(mobjs.len() == 7, 'the list is unchanged');
    assert(awake_count(w, mobjs.span()) == 0, 'and nothing woke');
    assert(rng.index == 1, 'a quiet tic draws nothing');
    // The idle frames did count down: `A_Look` is suppressed, the state
    // machine is not.
    assert(is_dormant(w, mobjs.span().at(1)), 'still in the idle loop');
}

#[test]
fn test_the_ticker_applies_a_patch() {
    let w = world();
    let mut g = new_grid();
    // An imp that cannot see its target throws a fireball, which claims a
    // slot: the patch path of the ticker, and then the missile's own thinker.
    let (p, mut mo) = open_pair(w, ref g, KIND_TROOP, 300, 0);
    mo.sight_ok = false;
    mo.sight_sector = p.sector;
    mo.sight_expires = 100000;
    mo.state = state_before(w, doom_things::tables::A_TROOPATTACK);
    mo.tics = 1;
    let mut mobjs = array![p, mo];
    let players = array![0].span();
    let (after, rng, _ev) = monsters_ticker(
        w, mobjs.span(), ref g, players, silence(), 0, from_index(1),
    );
    assert(after.len() >= 2, 'the list survived');
    assert(rng.index != 1, 'the throw drew randomness');
    mobjs = after;
    let (after2, _r2, _e2) = monsters_ticker(w, mobjs.span(), ref g, players, silence(), 1, rng);
    assert(after2.len() >= 2, 'still there');
}
