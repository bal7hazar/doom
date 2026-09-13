// SPDX-License-Identifier: GPL-2.0-only
//! The Freedoom E1M1 reference tests: every expected value comes from
//! `scripts/model.py`, an independent Python transcription of `p_user.c`,
//! `p_pspr.c` and `p_inter.c`, and everything geometric runs on the real
//! level through `doom_physics`.
//!
//! They cannot run on the miniature level `bench/coverage.py` compiles in,
//! which is why the coverage suite is `synthetic.cairo` instead.

use bam::Angle;
use doom_map::{LevelId, genesis, load};
use doom_physics::{
    KIND_NONE, MF_COUNTITEM, MF_DROPPED, MF_PICKUP, MF_SHOOTABLE, MF_SOLID, MF_SPECIAL, MOBJ_FELTS,
    Mobj, NO_MOBJ, ThingGrid, World, new_grid, removed_mobj, set_thing_position, world_of,
    xy_movement,
};
use doom_things::tables::KIND_PLAYER;
use fixed::{BIAS, Fixed};
use prng::from_index;
use super::vectors;
use super::super::env::{Env, PlayerEvent, env_of};
use super::super::inter::{absorb, damage_player, give_ammo, touch_special};
use super::super::state::{
    AM_CLIP, AM_SHELL, BT_ATTACK, BT_CHANGE, BT_USE, MAXHEALTH_BONUS, PLAYER_FELTS, PST_DEAD,
    PST_LIVE, WP_CHAINGUN, WP_CHAINSAW, WP_FIST, WP_NOCHANGE, WP_PISTOL, WP_SHOTGUN, ammo_of,
    max_ammo, owns, push_felts, reborn, set_ammo, spawn, weapon_bit,
};
use super::super::think::{
    S_PLAY_RUN1, calc_height, change_weapon, move_player, onground, player_stopped, player_think,
    use_lines,
};
use super::super::weapon::{
    PS_WEAPON, S_PLAY, chain, check_ammo, drop_weapon, move_psprites, set_psprite,
};

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

fn world() -> World {
    let m = load(LevelId::E1M1);
    world_of(@m)
}

/// The synthetic actor `scripts/model.py` runs on: at the origin, on a floor
/// at 0 under a ceiling far enough away that `P_CalcHeight` never clamps.
fn actor(angle: Angle) -> Mobj {
    let mut mo = removed_mobj();
    mo.kind = KIND_PLAYER;
    mo.angle = angle;
    mo.health = 100;
    mo.flags = MF_SOLID + MF_SHOOTABLE + MF_PICKUP;
    mo.radius = fixed::from_units(16);
    mo.height = fixed::from_units(56);
    mo.z = fixed::ZERO;
    mo.floorz = fixed::ZERO;
    mo.ceilingz = Fixed { enc: BIAS + 0x40000000 };
    mo.state = S_PLAY;
    mo.tics = fsm::FOREVER;
    mo.target = NO_MOBJ;
    mo
}

fn item(kind: u32, flags: u32) -> Mobj {
    let mut mo = removed_mobj();
    mo.kind = kind;
    mo.flags = flags;
    mo.z = fixed::ZERO;
    mo.height = fixed::from_units(16);
    mo
}

/// An `Env` over the real level, with `mobjs = [mo]` and the player at 0.
fn env_for(w: World, mo: Mobj, tic: u32, buttons: u32) -> Env {
    env_of(w, array![mo].span(), 0, tic, buttons)
}

fn row(data: Span<felt252>, stride: u32, i: u32, k: u32) -> felt252 {
    *data.at(i * stride + k)
}

/// A ticcmd word carrying only `buttons`.
fn buttons_word(buttons: u32) -> felt252 {
    let b: u8 = buttons.try_into().unwrap();
    ticcmd::encode(ticcmd::TicCmd { forward: 0, side: 0, angle_turn: 0, buttons: b })
}

fn u32_of(v: felt252) -> u32 {
    let u: u128 = v.try_into().unwrap();
    u.try_into().unwrap()
}

// ---------------------------------------------------------------------------
// Reference values: P_Thrust / P_MovePlayer
// ---------------------------------------------------------------------------

#[test]
fn test_thrust_vectors() {
    let w = world();
    let data = vectors::THRUST.span();
    let stride = vectors::THRUST_STRIDE;
    let n = data.len() / stride;
    let mut i: u32 = 0;
    while i != n {
        let angle: Angle = u32_of(row(data, stride, i, 0));
        let forward: i64 = row(data, stride, i, 1).try_into().unwrap();
        let side: i64 = row(data, stride, i, 2).try_into().unwrap();
        let turn: i64 = row(data, stride, i, 3).try_into().unwrap();
        let mut mo = actor(angle);
        let mut p = reborn(0, @mo);
        let e = env_for(w, mo, 0, 0);
        move_player(e, ref p, ref mo, forward, side, turn);
        assert(mo.angle == u32_of(row(data, stride, i, 4)), 'thrust angle');
        assert(mo.momx.enc == row(data, stride, i, 5), 'thrust momx');
        assert(mo.momy.enc == row(data, stride, i, 6), 'thrust momy');
        i += 1;
    }
}

#[test]
fn test_move_player_needs_the_ground() {
    let w = world();
    let mut mo = actor(0);
    mo.z = fixed::from_units(32); // airborne
    let mut p = reborn(0, @mo);
    let e = env_for(w, mo, 0, 0);
    move_player(e, ref p, ref mo, 50, 50, 1024);
    assert(mo.momx == fixed::ZERO, 'no thrust in the air');
    assert(mo.momy == fixed::ZERO, 'no side thrust in the air');
    assert(mo.angle == 1024 * 65536, 'but the turn still applies');
    // Vanilla does *not* gate the run frame on `onground`.
    assert(mo.state == S_PLAY_RUN1, 'the run frame still starts');
}

#[test]
fn test_move_player_enters_the_run_frames() {
    let w = world();
    let mut mo = actor(0);
    let mut p = reborn(0, @mo);
    let e = env_for(w, mo, 0, 0);
    move_player(e, ref p, ref mo, 25, 0, 0);
    assert(mo.state == S_PLAY_RUN1, 'walking');
    player_stopped(e, ref mo);
    assert(mo.state == S_PLAY, 'standing again');
}

// ---------------------------------------------------------------------------
// Reference values: friction, on the real map
// ---------------------------------------------------------------------------

#[test]
fn test_friction_runs() {
    let w = world();
    let g0 = genesis(LevelId::E1M1);
    let heads = vectors::FRICTION_HEAD.span();
    let data = vectors::FRICTION.span();
    let runs = heads.len() / vectors::FRICTION_HEAD_STRIDE;
    let tics = vectors::FRICTION_TICS;
    let mut r: u32 = 0;
    while r != runs {
        let angle: Angle = u32_of(row(heads, vectors::FRICTION_HEAD_STRIDE, r, 0));
        let forward: i64 = row(heads, vectors::FRICTION_HEAD_STRIDE, r, 1).try_into().unwrap();
        let side: i64 = row(heads, vectors::FRICTION_HEAD_STRIDE, r, 2).try_into().unwrap();
        let hold: u32 = u32_of(row(heads, vectors::FRICTION_HEAD_STRIDE, r, 3));
        let (mut p, mut mo) = spawn(w, 0, g0.start, angle);
        let x0 = mo.x.enc;
        let y0 = mo.y.enc;
        let mut g: ThingGrid = new_grid();
        set_thing_position(@w.map, ref g, ref mo, 0);
        let mut tic: u32 = 0;
        while tic != tics {
            let (f, s) = if tic < hold {
                (forward, side)
            } else {
                (0, 0)
            };
            let e = env_for(w, mo, tic, 0);
            move_player(e, ref p, ref mo, f, s, 0);
            calc_height(ref p, @mo, tic);
            let mobjs = array![mo].span();
            let mut events: Array<doom_physics::MoveEvent> = array![];
            let mut rng = from_index(1);
            let _ = rng;
            xy_movement(w, mobjs, ref g, ref mo, 0, f != 0 || s != 0, true, ref events);
            let k = r * tics + tic;
            assert(mo.momx.enc == *data.at(k * 4), 'friction momx');
            assert(mo.momy.enc == *data.at(k * 4 + 1), 'friction momy');
            assert(mo.x.enc - x0 + BIAS == *data.at(k * 4 + 2), 'friction x');
            assert(mo.y.enc - y0 + BIAS == *data.at(k * 4 + 3), 'friction y');
            tic += 1;
        }
        r += 1;
    }
}

// ---------------------------------------------------------------------------
// Reference values: P_CalcHeight
// ---------------------------------------------------------------------------

#[test]
fn test_calc_height_vectors() {
    let data = vectors::CALC.span();
    let stride = vectors::CALC_STRIDE;
    let n = data.len() / stride;
    let mut i: u32 = 0;
    while i != n {
        let mut mo = actor(0);
        mo.momx = Fixed { enc: row(data, stride, i, 0) };
        mo.momy = Fixed { enc: row(data, stride, i, 1) };
        let mut p = reborn(0, @mo);
        p.viewheight = Fixed { enc: row(data, stride, i, 2) };
        p.deltaviewheight = Fixed { enc: row(data, stride, i, 3) };
        let tic = u32_of(row(data, stride, i, 4));
        calc_height(ref p, @mo, tic);
        assert(p.bob.enc == row(data, stride, i, 5), 'calc bob');
        assert(p.viewheight.enc == row(data, stride, i, 6), 'calc viewheight');
        assert(p.deltaviewheight.enc == row(data, stride, i, 7), 'calc delta');
        assert(p.viewz.enc - mo.z.enc + BIAS == row(data, stride, i, 8), 'calc viewz');
        i += 1;
    }
}

#[test]
fn test_calc_height_off_the_ground_is_unclamped() {
    // Vanilla's off-ground branch assigns `viewz` twice and keeps the second,
    // which skips its own ceiling clamp.
    let mut mo = actor(0);
    mo.z = fixed::from_units(8);
    mo.ceilingz = fixed::from_units(10);
    let mut p = reborn(0, @mo);
    calc_height(ref p, @mo, 3);
    assert(p.viewz == fixed::add(mo.z, p.viewheight), 'no clamp when airborne');
}

#[test]
fn test_calc_height_clamps_under_a_low_ceiling() {
    let mut mo = actor(0);
    mo.ceilingz = fixed::from_units(20);
    let mut p = reborn(0, @mo);
    calc_height(ref p, @mo, 0);
    assert(p.viewz == fixed::from_units(16), 'eye 4 units under the ceiling');
}

// ---------------------------------------------------------------------------
// Reference values: the psprite script
// ---------------------------------------------------------------------------

#[test]
fn test_psprite_script() {
    let w = world();
    let g0 = genesis(LevelId::E1M1);
    let (mut p, mut mo) = spawn(w, 0, g0.start, g0.angle);
    let ready = chain(WP_PISTOL).ready;
    p.psp_state = ready;
    p.psp_tics = *w.states.tics.at(ready);
    p.psp_sy = Fixed { enc: BIAS + super::super::state::WEAPONTOP };
    p = set_ammo(p, AM_CLIP, 8);
    let mut g: ThingGrid = new_grid();
    set_thing_position(@w.map, ref g, ref mo, 0);
    let mut rng = from_index(1);
    let data = vectors::PSPR.span();
    let stride = vectors::PSPR_STRIDE;
    let n = data.len() / stride;
    let mut tic: u32 = 0;
    while tic != n {
        let buttons = u32_of(row(data, stride, tic, 0));
        let e = env_for(w, mo, tic, buttons);
        let mut events: Array<PlayerEvent> = array![];
        player_think(e, ref g, ref rng, ref p, ref mo, buttons_word(buttons), 0, false, ref events);
        assert(p.psp_state == u32_of(row(data, stride, tic, 1)), 'pspr state');
        assert(p.psp_tics == u32_of(row(data, stride, tic, 2)), 'pspr tics');
        assert(p.flash_state == u32_of(row(data, stride, tic, 3)), 'flash state');
        assert(ammo_of(@p, AM_CLIP) == u32_of(row(data, stride, tic, 4)), 'pspr ammo');
        assert(p.refire == u32_of(row(data, stride, tic, 5)), 'pspr refire');
        assert(p.extralight == u32_of(row(data, stride, tic, 6)), 'pspr extralight');
        assert(p.ready_weapon == u32_of(row(data, stride, tic, 7)), 'pspr ready');
        assert(p.pending_weapon == u32_of(row(data, stride, tic, 8)), 'pspr pending');
        assert(rng.index == u32_of(row(data, stride, tic, 9)), 'pspr rng draws');
        tic += 1;
    }
}

// ---------------------------------------------------------------------------
// Reference values: pickups
// ---------------------------------------------------------------------------

#[test]
fn test_pickup_vectors() {
    let data = vectors::PICKUP.span();
    let stride = vectors::PICKUP_STRIDE;
    let n = data.len() / stride;
    let mut i: u32 = 0;
    while i != n {
        let kind = u32_of(row(data, stride, i, 0));
        let flags = u32_of(row(data, stride, i, 1));
        let mut mo = actor(0);
        mo.health = row(data, stride, i, 2).try_into().unwrap();
        let mut p = reborn(0, @mo);
        p.health = u32_of(row(data, stride, i, 2));
        p.armor_points = u32_of(row(data, stride, i, 3));
        p.armor_type = u32_of(row(data, stride, i, 4));
        p = set_ammo(p, AM_CLIP, u32_of(row(data, stride, i, 5)));
        p = set_ammo(p, AM_SHELL, u32_of(row(data, stride, i, 6)));
        p.weapons = u32_of(row(data, stride, i, 7));
        p.backpack = row(data, stride, i, 8) == 1;
        let thing = item(kind, flags);
        let took = touch_special(ref p, ref mo, @thing);
        assert(took == (row(data, stride, i, 9) == 1), 'pickup took');
        assert(p.health == u32_of(row(data, stride, i, 10)), 'pickup health');
        assert(p.armor_points == u32_of(row(data, stride, i, 11)), 'pickup armor points');
        assert(p.armor_type == u32_of(row(data, stride, i, 12)), 'pickup armor type');
        assert(ammo_of(@p, 0) == u32_of(row(data, stride, i, 13)), 'pickup clip');
        assert(ammo_of(@p, 1) == u32_of(row(data, stride, i, 14)), 'pickup shell');
        assert(ammo_of(@p, 2) == u32_of(row(data, stride, i, 15)), 'pickup cell');
        assert(ammo_of(@p, 3) == u32_of(row(data, stride, i, 16)), 'pickup misl');
        assert(p.weapons == u32_of(row(data, stride, i, 17)), 'pickup weapons');
        assert(p.backpack == (row(data, stride, i, 18) == 1), 'pickup backpack');
        assert(p.pending_weapon == u32_of(row(data, stride, i, 19)), 'pickup pending');
        assert(p.itemcount == u32_of(row(data, stride, i, 20)), 'pickup itemcount');
        assert(p.bonuscount == u32_of(row(data, stride, i, 21)), 'pickup bonuscount');
        assert(p.strength == u32_of(row(data, stride, i, 22)), 'pickup strength');
        assert(p.cards == u32_of(row(data, stride, i, 23)), 'pickup cards');
        i += 1;
    }
}

#[test]
fn test_pickup_out_of_reach() {
    let mut mo = actor(0);
    let mut p = reborn(0, @mo);
    let mut high = item(doom_things::tables::KIND_MISC2, MF_SPECIAL + MF_COUNTITEM);
    high.z = fixed::from_units(80); // above the player's 56 units
    assert(!touch_special(ref p, ref mo, @high), 'too high to reach');
    let mut low = item(doom_things::tables::KIND_MISC2, MF_SPECIAL + MF_COUNTITEM);
    low.z = fixed::from_units(-9);
    assert(!touch_special(ref p, ref mo, @low), 'too low to reach');
    assert(p.itemcount == 0, 'nothing counted');
}

#[test]
fn test_a_corpse_picks_nothing_up() {
    let mut mo = actor(0);
    mo.health = 0;
    let mut p = reborn(0, @mo);
    let thing = item(doom_things::tables::KIND_MISC2, MF_SPECIAL + MF_COUNTITEM);
    assert(!touch_special(ref p, ref mo, @thing), 'dead men take nothing');
}

#[test]
fn test_unknown_gettable_thing_is_left_alone() {
    // The rocket launcher has no slot in this five-weapon roster.
    let mut mo = actor(0);
    let mut p = reborn(0, @mo);
    let thing = item(doom_things::tables::KIND_MISC27, MF_SPECIAL);
    assert(!touch_special(ref p, ref mo, @thing), 'left on the floor');
    assert(p.bonuscount == 0, 'and no bonus flash');
}

// ---------------------------------------------------------------------------
// Reference values: damage and armor
// ---------------------------------------------------------------------------

#[test]
fn test_damage_vectors() {
    let w = world();
    let data = vectors::DAMAGE.span();
    let stride = vectors::DAMAGE_STRIDE;
    let n = data.len() / stride;
    let mut i: u32 = 0;
    while i != n {
        let mut mo = actor(0);
        mo.health = row(data, stride, i, 2).try_into().unwrap();
        let mut p = reborn(0, @mo);
        p.armor_type = u32_of(row(data, stride, i, 0));
        p.armor_points = u32_of(row(data, stride, i, 1));
        p.health = u32_of(row(data, stride, i, 2));
        let damage = u32_of(row(data, stride, i, 3));
        let mut g: ThingGrid = new_grid();
        let mut rng = from_index(1);
        let mut events: Array<PlayerEvent> = array![];
        let e = env_for(w, mo, 0, 0);
        damage_player(
            e, ref g, ref rng, ref p, ref mo, ref events, NO_MOBJ, NO_MOBJ, damage, false,
        );
        assert(p.armor_type == u32_of(row(data, stride, i, 5)), 'damage armor type');
        assert(p.armor_points == u32_of(row(data, stride, i, 6)), 'damage armor points');
        assert(p.health == u32_of(row(data, stride, i, 7)), 'damage health');
        assert(p.damagecount == u32_of(row(data, stride, i, 8)), 'damage count');
        assert(p.playerstate == u32_of(row(data, stride, i, 9)), 'damage playerstate');
        i += 1;
    }
}

#[test]
fn test_green_armor_absorbs_a_third_and_blue_a_half() {
    let mut mo = actor(0);
    let mut green = reborn(0, @mo);
    green.armor_type = 1;
    green.armor_points = 100;
    assert(absorb(ref green, 30) == 20, 'green eats a third');
    assert(green.armor_points == 90, 'green spends 10');
    let mut blue = reborn(0, @mo);
    blue.armor_type = 2;
    blue.armor_points = 200;
    assert(absorb(ref blue, 30) == 15, 'blue eats a half');
    assert(blue.armor_points == 185, 'blue spends 15');
}

#[test]
fn test_armor_that_runs_out_is_dropped() {
    let mo = actor(0);
    let mut p = reborn(0, @mo);
    p.armor_type = 1;
    p.armor_points = 2;
    assert(absorb(ref p, 30) == 28, 'only 2 points left to give');
    assert(p.armor_points == 0, 'spent');
    assert(p.armor_type == 0, 'and gone');
}

#[test]
fn test_death_sets_the_segment_status() {
    let w = world();
    let mut mo = actor(0);
    let mut p = reborn(0, @mo);
    p.psp_state = chain(WP_PISTOL).ready;
    p.psp_tics = 1;
    let mut g: ThingGrid = new_grid();
    let mut rng = from_index(1);
    let mut events: Array<PlayerEvent> = array![];
    let e = env_for(w, mo, 0, 0);
    damage_player(e, ref g, ref rng, ref p, ref mo, ref events, NO_MOBJ, NO_MOBJ, 250, false);
    assert(p.health == 0, 'no health left');
    assert(p.playerstate == PST_DEAD, 'D14 status = 1');
    assert(p.psp_state == chain(WP_PISTOL).down, 'P_DropWeapon');
    assert(!doom_physics::has(mo.flags, MF_SOLID), 'a corpse is not solid');
}

#[test]
fn test_death_think_lowers_the_camera_and_ignores_input() {
    let w = world();
    let mut mo = actor(0);
    let mut p = reborn(0, @mo);
    p.playerstate = PST_DEAD;
    p.damagecount = 5;
    let mut g: ThingGrid = new_grid();
    let mut rng = from_index(1);
    let mut tic: u32 = 0;
    while tic != 40 {
        let mut events: Array<PlayerEvent> = array![];
        let e = env_for(w, mo, tic, BT_USE + BT_ATTACK);
        player_think(e, ref g, ref rng, ref p, ref mo, buttons_word(BT_USE), 0, false, ref events);
        tic += 1;
    }
    assert(p.viewheight == fixed::from_units(6), 'camera on the floor');
    assert(p.damagecount == 0, 'damage flash faded');
    assert(p.playerstate == PST_DEAD, 'no respawn on the proving path');
    assert(mo.momx == fixed::ZERO, 'the dead do not walk');
}

// ---------------------------------------------------------------------------
// The 350-tic scripted run
// ---------------------------------------------------------------------------

#[test]
fn test_scripted_walk_on_e1m1() {
    let w = world();
    let g0 = genesis(LevelId::E1M1);
    let (mut p, mut mo) = spawn(w, 0, g0.start, g0.angle);
    let ready = chain(WP_PISTOL).ready;
    p.psp_state = ready;
    p.psp_tics = *w.states.tics.at(ready);
    p.psp_sy = Fixed { enc: BIAS + super::super::state::WEAPONTOP };
    let x0 = mo.x.enc;
    let y0 = mo.y.enc;
    let mut g: ThingGrid = new_grid();
    set_thing_position(@w.map, ref g, ref mo, 0);
    let mut rng = from_index(1);

    let cmds = vectors::WALK_CMDS.span();
    let samples = vectors::WALK_SAMPLES.span();
    let sstride = vectors::WALK_SAMPLE_STRIDE;
    let mut checksum: felt252 = 0;
    let mut next_sample: u32 = 0;
    let mut tic: u32 = 0;
    while tic != vectors::WALK_TICS {
        let word = *cmds.at(tic);
        let cmd = ticcmd::decode(word);
        let e = env_for(w, mo, tic, cmd.buttons.into());
        let mut events: Array<PlayerEvent> = array![];
        player_think(e, ref g, ref rng, ref p, ref mo, word, 0, false, ref events);
        // The thinker pass `P_Ticker` runs after every `P_PlayerThink`.
        let mobjs = array![mo].span();
        let mut moves: Array<doom_physics::MoveEvent> = array![];
        let input = cmd.forward != 0 || cmd.side != 0;
        let out = xy_movement(w, mobjs, ref g, ref mo, 0, input, true, ref moves);
        if out == doom_physics::XyOutcome::Stopped {
            player_stopped(e, ref mo);
        }
        assert(onground(@mo), 'the player stays on the floor');

        let fields = array![
            mo.x.enc - x0 + BIAS, mo.y.enc - y0 + BIAS, mo.angle.into(), mo.momx.enc, mo.momy.enc,
            p.viewz.enc - mo.z.enc + BIAS, p.psp_state.into(), p.flash_state.into(),
            ammo_of(@p, AM_CLIP).into(), p.refire.into(), p.ready_weapon.into(), rng.index.into(),
        ]
            .span();
        if next_sample
            * sstride < samples.len() && *samples.at(next_sample * sstride) == tic.into() {
            let mut k: u32 = 0;
            while k != 12 {
                assert(*fields.at(k) == *samples.at(next_sample * sstride + 1 + k), 'walk sample');
                k += 1;
            }
            next_sample += 1;
        }
        let mut folded: felt252 = 0;
        let mut k: u32 = 0;
        while k != 12 {
            let weight: felt252 = (k + 1).into();
            folded += weight * *fields.at(k);
            k += 1;
        }
        let t: felt252 = (tic + 1).into();
        checksum += t * folded;
        tic += 1;
    }
    assert(next_sample * sstride == samples.len(), 'every sample checked');
    assert(checksum == vectors::WALK_CHECKSUM, 'scripted walk checksum');
}

// ---------------------------------------------------------------------------
// Weapons: switching, ammo, the fallback chain
// ---------------------------------------------------------------------------

#[test]
fn test_weapon_change_buttons() {
    let mo = actor(0);
    let mut p = reborn(0, @mo);
    change_weapon(ref p, BT_CHANGE + 8 * WP_FIST);
    assert(p.pending_weapon == WP_FIST, 'fist selected');
    p.pending_weapon = WP_NOCHANGE;
    change_weapon(ref p, BT_CHANGE + 8 * WP_SHOTGUN);
    assert(p.pending_weapon == WP_NOCHANGE, 'not owned, not selected');
    p.weapons = p.weapons + weapon_bit(WP_SHOTGUN);
    change_weapon(ref p, BT_CHANGE + 8 * WP_SHOTGUN);
    assert(p.pending_weapon == WP_SHOTGUN, 'now owned');
    p.pending_weapon = WP_NOCHANGE;
    change_weapon(ref p, BT_CHANGE + 8 * WP_PISTOL);
    assert(p.pending_weapon == WP_NOCHANGE, 'already the ready weapon');
}

#[test]
fn test_fist_button_means_chainsaw_when_owned() {
    let mo = actor(0);
    let mut p = reborn(0, @mo);
    p.weapons = p.weapons + weapon_bit(WP_CHAINSAW);
    change_weapon(ref p, BT_CHANGE + 8 * WP_FIST);
    assert(p.pending_weapon == WP_CHAINSAW, 'the saw wins');
    // …unless the saw is already up and the player is berserk.
    p.ready_weapon = WP_CHAINSAW;
    p.strength = 1;
    p.pending_weapon = WP_NOCHANGE;
    change_weapon(ref p, BT_CHANGE + 8 * WP_FIST);
    assert(p.pending_weapon == WP_FIST, 'berserk fist');
}

#[test]
fn test_check_ammo_falls_back_in_dooms_order() {
    let w = world();
    let mut mo = actor(0);
    let mut p = reborn(0, @mo);
    p = set_ammo(p, AM_CLIP, 0);
    p.ready_weapon = WP_PISTOL;
    p.psp_state = chain(WP_PISTOL).ready;
    p.psp_sy = Fixed { enc: BIAS + super::super::state::WEAPONTOP };
    let mut g: ThingGrid = new_grid();
    let mut rng = from_index(1);
    let mut events: Array<PlayerEvent> = array![];
    let e = env_for(w, mo, 0, 0);
    let ok = check_ammo(e, ref g, ref rng, ref p, ref mo, ref events, 0);
    assert(!ok, 'out of bullets');
    assert(p.pending_weapon == WP_FIST, 'down to the fist');
    assert(p.psp_state == chain(WP_PISTOL).down, 'and lowering the pistol');

    // With a shotgun and shells, the shotgun wins over the fist.
    let mut q = reborn(0, @mo);
    q.psp_sy = Fixed { enc: BIAS + super::super::state::WEAPONTOP };
    q = set_ammo(q, AM_CLIP, 0);
    q.weapons = q.weapons + weapon_bit(WP_SHOTGUN);
    q = set_ammo(q, AM_SHELL, 4);
    check_ammo(e, ref g, ref rng, ref q, ref mo, ref events, 0);
    assert(q.pending_weapon == WP_SHOTGUN, 'shotgun first');

    // …and the chaingun over the shotgun.
    let mut r = reborn(0, @mo);
    r.psp_sy = Fixed { enc: BIAS + super::super::state::WEAPONTOP };
    r = set_ammo(r, AM_CLIP, 0);
    r.weapons = r.weapons + weapon_bit(WP_SHOTGUN) + weapon_bit(WP_CHAINGUN);
    r = set_ammo(r, AM_SHELL, 4);
    check_ammo(e, ref g, ref rng, ref r, ref mo, ref events, 0);
    assert(r.pending_weapon == WP_SHOTGUN, 'the chaingun has no bullets');
}

#[test]
fn test_a_weapon_switch_lowers_then_raises() {
    let w = world();
    let mut mo = actor(0);
    let mut p = reborn(0, @mo);
    p.weapons = p.weapons + weapon_bit(WP_SHOTGUN);
    p.psp_state = chain(WP_PISTOL).ready;
    p.psp_tics = 1;
    p.psp_sy = Fixed { enc: BIAS + super::super::state::WEAPONTOP };
    p.pending_weapon = WP_SHOTGUN;
    let mut g: ThingGrid = new_grid();
    let mut rng = from_index(1);
    let mut tic: u32 = 0;
    let mut lowered = false;
    while tic != 60 {
        let mut events: Array<PlayerEvent> = array![];
        let e = env_for(w, mo, tic, 0);
        move_psprites(e, ref g, ref rng, ref p, ref mo, ref events);
        if p.psp_state == chain(WP_SHOTGUN).up {
            lowered = true;
        }
        tic += 1;
    }
    assert(lowered, 'the shotgun came up');
    assert(p.ready_weapon == WP_SHOTGUN, 'and is the ready weapon');
    assert(p.psp_state == chain(WP_SHOTGUN).ready, 'and is ready');
    assert(p.psp_sy == Fixed { enc: BIAS + super::super::state::WEAPONTOP }, 'at the top');
}

#[test]
fn test_giving_ammo_selects_a_weapon_only_from_empty() {
    let mo = actor(0);
    let mut p = reborn(0, @mo);
    p = set_ammo(p, AM_CLIP, 0);
    p.ready_weapon = WP_FIST;
    assert(give_ammo(ref p, AM_CLIP, 1), 'took a clip');
    assert(p.pending_weapon == WP_PISTOL, 'up from the fist');
    p.pending_weapon = WP_NOCHANGE;
    assert(give_ammo(ref p, AM_CLIP, 1), 'took another');
    assert(p.pending_weapon == WP_NOCHANGE, 'lower on purpose');
}

#[test]
fn test_the_backpack_doubles_every_maximum_once() {
    let mut mo = actor(0);
    let mut p = reborn(0, @mo);
    let thing = item(doom_things::tables::KIND_MISC24, MF_SPECIAL);
    assert(touch_special(ref p, ref mo, @thing), 'took the backpack');
    assert(max_ammo(@p, AM_CLIP) == 400, 'bullets doubled');
    assert(max_ammo(@p, AM_SHELL) == 100, 'shells doubled');
    assert(touch_special(ref p, ref mo, @thing), 'a second one still gives ammo');
    assert(max_ammo(@p, AM_CLIP) == 400, 'but does not double again');
}

#[test]
fn test_a_dropped_weapon_gives_one_clip_and_a_found_one_two() {
    let mut mo = actor(0);
    let mut dropped = reborn(0, @mo);
    dropped = set_ammo(dropped, AM_SHELL, 0);
    let shot_drop = item(doom_things::tables::KIND_SHOTGUN, MF_SPECIAL + MF_DROPPED);
    assert(touch_special(ref dropped, ref mo, @shot_drop), 'took it');
    assert(ammo_of(@dropped, AM_SHELL) == 4, 'one clip of shells');
    assert(owns(@dropped, WP_SHOTGUN), 'and the shotgun');

    let mut found = reborn(0, @mo);
    let shot = item(doom_things::tables::KIND_SHOTGUN, MF_SPECIAL);
    assert(touch_special(ref found, ref mo, @shot), 'took it');
    assert(ammo_of(@found, AM_SHELL) == 8, 'two clips of shells');
}

// ---------------------------------------------------------------------------
// P_UseLines
// ---------------------------------------------------------------------------

#[test]
fn test_use_lines_reports_at_most_one_special() {
    let w = world();
    let g0 = genesis(LevelId::E1M1);
    let (_, mut mo) = spawn(w, 0, g0.start, g0.angle);
    let mut g: ThingGrid = new_grid();
    set_thing_position(@w.map, ref g, ref mo, 0);
    let mut events: Array<PlayerEvent> = array![];
    let e = env_for(w, mo, 0, BT_USE);
    use_lines(e, ref g, @mo, ref events);
    assert(events.len() <= 1, 'one special line at most');
}

#[test]
fn test_use_is_edge_triggered() {
    let w = world();
    let g0 = genesis(LevelId::E1M1);
    let (mut p, mut mo) = spawn(w, 0, g0.start, g0.angle);
    let mut g: ThingGrid = new_grid();
    set_thing_position(@w.map, ref g, ref mo, 0);
    let mut rng = from_index(1);
    let word = buttons_word(BT_USE);
    let mut events: Array<PlayerEvent> = array![];
    let e = env_for(w, mo, 0, BT_USE);
    player_think(e, ref g, ref rng, ref p, ref mo, word, 0, false, ref events);
    assert(p.usedown, 'the button is down');
    let held = events.len();
    player_think(e, ref g, ref rng, ref p, ref mo, word, 0, false, ref events);
    assert(events.len() == held, 'a held button traces nothing');
    let idle = buttons_word(0);
    let e0 = env_for(w, mo, 2, 0);
    player_think(e0, ref g, ref rng, ref p, ref mo, idle, 0, false, ref events);
    assert(!p.usedown, 'released');
}

// ---------------------------------------------------------------------------
// Special sectors
// ---------------------------------------------------------------------------

#[test]
fn test_sector_damage_and_secrets_reach_the_player() {
    let w = world();
    let mut mo = actor(0);
    let mut p = reborn(0, @mo);
    let mut g: ThingGrid = new_grid();
    let mut rng = from_index(1);
    let mut events: Array<PlayerEvent> = array![];
    let e = env_for(w, mo, 0, 0);
    player_think(e, ref g, ref rng, ref p, ref mo, buttons_word(0), 5, true, ref events);
    assert(p.health == 95, 'nukage took five');
    assert(p.secretcount == 1, 'and a secret was counted');
    assert(p.damagecount == 4, 'damage flash minus one tic');
}

// ---------------------------------------------------------------------------
// Properties
// ---------------------------------------------------------------------------

#[test]
fn test_health_stays_in_range_over_every_pickup() {
    let mut mo = actor(0);
    let mut p = reborn(0, @mo);
    let kinds = array![
        doom_things::tables::KIND_MISC2, doom_things::tables::KIND_MISC12,
        doom_things::tables::KIND_MISC10, doom_things::tables::KIND_MISC11,
        doom_things::tables::KIND_MISC13,
    ]
        .span();
    let mut i: u32 = 0;
    while i != 400 {
        let thing = item(*kinds.at(i % kinds.len()), MF_SPECIAL);
        touch_special(ref p, ref mo, @thing);
        assert(p.health <= MAXHEALTH_BONUS, 'health never over 200');
        assert(p.armor_points <= 200, 'armor never over 200');
        let m: i32 = p.health.try_into().unwrap();
        assert(mo.health == m, 'mobj health mirrors');
        i += 1;
    }
    assert(p.health == MAXHEALTH_BONUS, 'and it does reach 200');
}

#[test]
fn test_ammo_never_passes_its_maximum() {
    let mo = actor(0);
    let mut p = reborn(0, @mo);
    let mut a: u32 = 0;
    while a != 4 {
        let mut i: u32 = 0;
        while i != 40 {
            give_ammo(ref p, a, 5);
            assert(ammo_of(@p, a) <= max_ammo(@p, a), 'ammo within its maximum');
            i += 1;
        }
        assert(ammo_of(@p, a) == max_ammo(@p, a), 'and it does saturate');
        a += 1;
    }
}

#[test]
fn test_view_height_stays_between_its_bounds() {
    let w = world();
    let mut mo = actor(0);
    let mut p = reborn(0, @mo);
    let mut g: ThingGrid = new_grid();
    let mut rng = from_index(1);
    let mut tic: u32 = 0;
    while tic != 120 {
        // A hard landing every 20 tics, as `z_movement` would report one.
        if tic % 20 == 0 {
            p.deltaviewheight = Fixed { enc: BIAS - 3 * 65536 };
        }
        mo.momx = fixed::from_units(6);
        let mut events: Array<PlayerEvent> = array![];
        let e = env_for(w, mo, tic, 0);
        player_think(e, ref g, ref rng, ref p, ref mo, buttons_word(0), 0, false, ref events);
        assert(fixed::le(p.viewheight, fixed::from_units(41)), 'never above VIEWHEIGHT');
        assert(
            fixed::ge(p.viewheight, Fixed { enc: BIAS + super::super::state::HALF_VIEWHEIGHT }),
            'never below VIEWHEIGHT/2',
        );
        assert(fixed::le(p.bob, Fixed { enc: BIAS + super::super::state::MAXBOB }), 'bob capped');
        tic += 1;
    }
}

#[test]
fn test_psprite_chain_terminates_from_every_weapon_state() {
    let w = world();
    let mut mo = actor(0);
    let mut g: ThingGrid = new_grid();
    let mut rng = from_index(1);
    let mut weapon: u32 = 0;
    while weapon != 5 {
        let c = chain(weapon);
        let starts = array![c.up, c.down, c.ready, c.attack, c.flash].span();
        let mut k: u32 = 0;
        while k != starts.len() {
            let mut p = reborn(0, @mo);
            p.ready_weapon = weapon;
            p.weapons = 0xFF;
            let mut events: Array<PlayerEvent> = array![];
            let e = env_for(w, mo, 0, 0);
            set_psprite(e, ref g, ref rng, ref p, ref mo, ref events, PS_WEAPON, *starts.at(k), 0);
            // Every chain lands on a state with tics left, or on none at all.
            assert(p.psp_state == 0 || p.psp_tics != 0, 'no zero-tic parking');
            k += 1;
        }
        weapon += 1;
    }
}

// ---------------------------------------------------------------------------
// Serialization (the `doom_game` schema)
// ---------------------------------------------------------------------------

#[test]
fn test_serialization_schema() {
    let w = world();
    let g0 = genesis(LevelId::E1M1);
    let (mut p, mut mo) = spawn(w, 0, g0.start, g0.angle);
    p.health = 199;
    p.armor_points = 200;
    p.armor_type = 2;
    p = set_ammo(p, AM_CLIP, 400);
    p.backpack = true;
    p.deltaviewheight = Fixed { enc: BIAS - 4 * 65536 };
    p.attacker = 42;
    p.attackdown = true;
    p.usedown = true;
    p.killcount = 53;
    p.itemcount = 99;
    p.secretcount = 4;
    let mut out: Array<felt252> = array![];
    push_felts(ref out, @p);
    assert(out.len() == PLAYER_FELTS, 'as long as fields() promises');
    assert(super::super::state::fields() == PLAYER_FELTS, 'fields agrees');
    let felts = out.span();
    let mut i: u32 = 0;
    while i != felts.len() {
        // A negative felt is ~2^251 and does not fit a `u128`, so the
        // conversion is the non-negativity assertion (A7).
        let v: u128 = (*felts.at(i)).try_into().unwrap();
        assert(v < 0x1000000000000000000, 'below 2^72');
        i += 1;
    }
    // …and the mobj beside it keeps its own schema.
    let mut mout: Array<felt252> = array![];
    doom_physics::push_felts(ref mout, @mo);
    assert(mout.len() == MOBJ_FELTS, 'mobj schema unchanged');
    assert(mo.kind != KIND_NONE, 'a live player');
}

#[test]
fn test_spawn_is_dooms_loadout() {
    let w = world();
    let g0 = genesis(LevelId::E1M1);
    let (p, mo) = spawn(w, 0, g0.start, g0.angle);
    assert(p.health == 100, '100 health');
    assert(ammo_of(@p, AM_CLIP) == 50, '50 bullets');
    assert(owns(@p, WP_FIST) && owns(@p, WP_PISTOL), 'fist and pistol');
    assert(!owns(@p, WP_SHOTGUN), 'nothing else');
    assert(p.ready_weapon == WP_PISTOL, 'pistol in hand');
    assert(p.pending_weapon == WP_NOCHANGE, 'nothing pending');
    assert(p.playerstate == PST_LIVE, 'alive');
    assert(p.cheats == 0, 'no cheats on the proving path');
    assert(p.viewz == fixed::add(mo.z, fixed::from_units(41)), 'eye at VIEWHEIGHT');
    assert(mo.kind == KIND_PLAYER, 'and a player mobj');
}

#[test]
fn test_drop_weapon_and_bring_up_round_trip() {
    let w = world();
    let mut mo = actor(0);
    let mut p = reborn(0, @mo);
    p.psp_sy = Fixed { enc: BIAS + super::super::state::WEAPONTOP };
    let mut g: ThingGrid = new_grid();
    let mut rng = from_index(1);
    let mut events: Array<PlayerEvent> = array![];
    let e = env_for(w, mo, 0, 0);
    drop_weapon(e, ref g, ref rng, ref p, ref mo, ref events);
    assert(p.psp_state == chain(WP_PISTOL).down, 'lowering');
    assert(p.psp_tics != 0, 'and animating');
}
