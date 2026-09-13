// SPDX-License-Identifier: GPL-2.0-only
//! The rules exercise: every branch of the crate, on whatever level is
//! compiled in.
//!
//! Nothing here asserts a coordinate or a linedef id, so the module runs
//! unchanged on Freedoom E1M1 under `scarb test` and on `doom_map`'s
//! miniature fixture under `bench/coverage.py` — which is what makes it the
//! coverage suite (the E1M1 reference vectors of `src/tests/e1m1.cairo`
//! cannot run on the fixture). What it checks is Doom's *rules*; the numbers
//! come from `p_user.c`, `p_pspr.c` and `p_inter.c` directly, not from
//! `scripts/model.py`.
//!
//! **Every test here is deliberately short.** `cairo-coverage` needs
//! `inlining-strategy = "avoid"`, and under that flag a test function that
//! keeps a `World`, an `Env`, a `Player` and a `Mobj` live across a few
//! hundred Sierra statements makes `universal-sierra-compiler` fail with
//! `Offset overflow`. One behaviour per test keeps every frame small.

use bam::Angle;
use doom_map::{LevelId, genesis, load};
use doom_physics::{
    MF_COUNTITEM, MF_DROPPED, MF_PICKUP, MF_SHOOTABLE, MF_SOLID, MF_SPECIAL, Mobj, NO_MOBJ, SpawnZ,
    ThingGrid, World, has, new_grid, removed_mobj, set_thing_position, spawn_mobj, world_of,
};
use doom_things::tables::{
    KIND_CHAINGUN, KIND_CLIP, KIND_MISC0, KIND_MISC1, KIND_MISC10, KIND_MISC11, KIND_MISC12,
    KIND_MISC13, KIND_MISC17, KIND_MISC18, KIND_MISC19, KIND_MISC2, KIND_MISC20, KIND_MISC21,
    KIND_MISC22, KIND_MISC23, KIND_MISC24, KIND_MISC26, KIND_MISC27, KIND_MISC28, KIND_MISC3,
    KIND_MISC4, KIND_PLAYER, KIND_POSSESSED, KIND_SHOTGUN,
};
use fixed::{BIAS, Fixed};
use prng::{Prng, from_index};
use super::super::env::{Env, PlayerEvent, env_of};
use super::super::inter::{
    absorb, count_kill, damage_player, give_ammo, give_armor, give_body, give_card, give_strength,
    give_weapon, nobody, touch_special,
};
use super::super::state::{
    AM_CELL, AM_CLIP, AM_MISL, AM_NOAMMO, AM_SHELL, BT_ATTACK, BT_CHANGE, BT_USE, CARD_BLUE,
    PLAYER_FELTS, PST_DEAD, PST_LIVE, Player, WEAPONTOP, WP_CHAINGUN, WP_CHAINSAW, WP_FIST,
    WP_NOCHANGE, WP_PISTOL, WP_SHOTGUN, ammo_of, fields, has_blue_key, max_ammo, owns, push_felts,
    reborn, set_ammo, spawn, weapon_ammo, weapon_bit,
};
use super::super::think::{
    ANG5, S_PLAY_RUN1, calc_height, change_weapon, death_think, move_player, onground,
    player_stopped, player_think, thrust, use_lines,
};
use super::super::tic::player_tic;
use super::super::weapon::{
    MAX_PSPR_DEPTH, PS_FLASH, PS_WEAPON, S_PLAY, S_PLAY_ATK, bring_up_weapon, bullet_slope, chain,
    check_ammo, drop_weapon, hit_thing, maxbob, move_psprites, set_psprite,
};

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

fn world() -> World {
    let m = load(LevelId::E1M1);
    world_of(@m)
}

/// The synthetic actor: at the origin, on a floor at 0, under a ceiling far
/// enough away that `P_CalcHeight` never clamps.
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

/// One tic's `Env`. It loads the level itself rather than taking a `World`,
/// so that no test body keeps a ~56-felt bundle live beside a `Player` and a
/// `Mobj` (see the module note on `Offset overflow`).
fn env_at(mo: Mobj, tic: u32, buttons: u32) -> Env {
    env_of(world(), array![BoxTrait::new(mo)].span(), 0, tic, buttons)
}

/// The same with a second mobj at index 1.
fn env_two(a: Mobj, b: Mobj, tic: u32, buttons: u32) -> Env {
    env_of(world(), array![BoxTrait::new(a), BoxTrait::new(b)].span(), 0, tic, buttons)
}

fn word_of(forward: i64, side: i64, turn: i64, buttons: u32) -> felt252 {
    let b: u8 = buttons.try_into().unwrap();
    ticcmd::encode(ticcmd::TicCmd { forward, side, angle_turn: turn, buttons: b })
}

fn top() -> Fixed {
    Fixed { enc: BIAS + WEAPONTOP }
}

/// A player with the pistol raised and ready.
fn ready_player() -> Player {
    let mo = actor(0);
    let mut p = reborn(0, @mo);
    p.psp_state = chain(WP_PISTOL).ready;
    p.psp_tics = *world().states.tics.at(p.psp_state);
    p.psp_sy = top();
    p
}

/// Run `n` tics of `P_MovePsprites` over a linked player with `buttons`
/// held, and return how many shots the actions reported.
fn cycle(ref p: Player, ref mo: Mobj, n: u32, buttons: u32) -> u32 {
    let mut g: ThingGrid = new_grid();
    set_thing_position(@world().map, ref g, ref mo, 0);
    let mut rng: Prng = from_index(1);
    let mut fired: u32 = 0;
    let mut tic: u32 = 0;
    while tic != n {
        let mut events: Array<PlayerEvent> = array![];
        move_psprites(env_at(mo, tic, buttons), ref g, ref rng, ref p, ref mo, ref events);
        fired += events.len();
        tic += 1;
    }
    fired
}

/// One `P_PlayerThink`, with a fresh grid and RNG.
fn think_once(ref p: Player, ref mo: Mobj, word: felt252, buttons: u32, tic: u32) {
    let mut g: ThingGrid = new_grid();
    let mut rng: Prng = from_index(1);
    let mut events: Array<PlayerEvent> = array![];
    player_think(
        env_at(mo, tic, buttons), ref g, ref rng, ref p, ref mo, word, 0, false, ref events,
    );
}

/// One `P_SetPsprite`, returning how many shots it reported and the largest
/// damage among them.
fn enter_state(ref p: Player, ref mo: Mobj, slot: u32, state: u32) -> (u32, u32) {
    let mut g: ThingGrid = new_grid();
    set_thing_position(@world().map, ref g, ref mo, 0);
    let mut rng: Prng = from_index(1);
    let mut events: Array<PlayerEvent> = array![];
    set_psprite(
        env_at(mo, 0, BT_ATTACK), ref g, ref rng, ref p, ref mo, ref events, slot, state, 0,
    );
    let seen = events.span();
    let mut worst: u32 = 0;
    let mut k: u32 = 0;
    while k != seen.len() {
        match *seen.at(k) {
            PlayerEvent::Shot((
                hit, damage,
            )) => {
                let _ = hit_thing(hit);
                if damage > worst {
                    worst = damage;
                }
            },
            _ => {},
        }
        k += 1;
    }
    (seen.len(), worst)
}

/// `P_DamageMobj` on the player, with no inflictor.
fn hurt(ref p: Player, ref mo: Mobj, damage: u32) {
    let mut g: ThingGrid = new_grid();
    let mut rng: Prng = from_index(1);
    let mut events: Array<PlayerEvent> = array![];
    damage_player(
        env_at(mo, 0, 0),
        ref g,
        ref rng,
        ref p,
        ref mo,
        ref events,
        NO_MOBJ,
        NO_MOBJ,
        damage,
        false,
    );
}

/// One `P_DeathThink` with an attacker at index 1.
fn die_facing(ref p: Player, ref mo: Mobj, killer: Mobj) {
    let mut g: ThingGrid = new_grid();
    let mut rng: Prng = from_index(1);
    let mut events: Array<PlayerEvent> = array![];
    death_think(env_two(mo, killer, 0, 0), ref g, ref rng, ref p, ref mo, ref events);
}

fn killer_east() -> Mobj {
    spawn_mobj(world(), KIND_POSSESSED, fixed::from_units(64), fixed::ZERO, SpawnZ::OnFloor)
}

fn dead_player(angle: Angle) -> (Player, Mobj) {
    let mo = actor(angle);
    let mut p = reborn(0, @mo);
    p.playerstate = PST_DEAD;
    p.attacker = 1;
    (p, mo)
}

fn takes(kind: u32, flags: u32) -> bool {
    let mut mo = actor(0);
    let mut p = reborn(0, @mo);
    p.health = 1;
    p = set_ammo(p, AM_CLIP, 0);
    touch_special(ref p, ref mo, @item(kind, flags))
}

/// `P_CheckAmmo` on `p`, with a fresh grid and RNG.
fn ammo_check(ref p: Player, ref mo: Mobj) -> bool {
    let mut g: ThingGrid = new_grid();
    let mut rng: Prng = from_index(1);
    let mut events: Array<PlayerEvent> = array![];
    check_ammo(env_at(mo, 0, 0), ref g, ref rng, ref p, ref mo, ref events, 0)
}

// ---------------------------------------------------------------------------
// state.cairo
// ---------------------------------------------------------------------------

#[test]
fn test_weapon_bits() {
    assert(weapon_bit(WP_FIST) == 1, 'fist bit');
    assert(weapon_bit(WP_PISTOL) == 2, 'pistol bit');
    assert(weapon_bit(WP_SHOTGUN) == 4, 'shotgun bit');
    assert(weapon_bit(WP_CHAINGUN) == 8, 'chaingun bit');
    assert(weapon_bit(WP_CHAINSAW) == 16, 'chainsaw bit');
    assert(weapon_bit(WP_NOCHANGE) == 0, 'no bit for wp_nochange');
}

#[test]
fn test_weapon_ammo_types() {
    assert(weapon_ammo(WP_FIST) == AM_NOAMMO, 'the fist eats nothing');
    assert(weapon_ammo(WP_PISTOL) == AM_CLIP, 'the pistol eats bullets');
    assert(weapon_ammo(WP_SHOTGUN) == AM_SHELL, 'the shotgun eats shells');
    assert(weapon_ammo(WP_CHAINGUN) == AM_CLIP, 'the chaingun eats bullets');
    assert(weapon_ammo(WP_CHAINSAW) == AM_NOAMMO, 'nor does the saw');
    assert(weapon_ammo(WP_NOCHANGE) == AM_NOAMMO, 'out of range is noammo');
}

#[test]
fn test_ammo_slots_are_independent() {
    let mo = actor(0);
    let mut p = reborn(7, @mo);
    assert(p.mo == 7, 'the mobj index is kept');
    assert(ammo_of(@p, AM_NOAMMO) == 0, 'noammo reads zero');
    assert(max_ammo(@p, AM_NOAMMO) == 0, 'and has no maximum');
    assert(max_ammo(@p, AM_MISL) == 50, 'rockets cap at 50');
    p = set_ammo(p, AM_CELL, 3);
    p = set_ammo(p, AM_MISL, 4);
    assert(ammo_of(@p, AM_CELL) == 3, 'cells written');
    assert(ammo_of(@p, AM_MISL) == 4, 'rockets written');
    assert(ammo_of(@p, AM_CLIP) == 50, 'others untouched');
}

#[test]
fn test_the_blue_card_is_given_once() {
    let mo = actor(0);
    let mut p = reborn(0, @mo);
    assert(!has_blue_key(@p), 'no key yet');
    assert(!owns(@p, WP_CHAINSAW), 'no saw either');
    give_card(ref p, CARD_BLUE);
    assert(has_blue_key(@p), 'now there is one');
    give_card(ref p, CARD_BLUE);
    assert(p.cards == CARD_BLUE, 'a second card is a no-op');
}

#[test]
fn test_spawn_and_serialize() {
    let g0 = genesis(LevelId::E1M1);
    let (p, mo) = spawn(world(), 3, g0.start, g0.angle);
    assert(p.mo == 3, 'index kept');
    assert(mo.kind == KIND_PLAYER, 'a player mobj');
    assert(p.playerstate == PST_LIVE, 'alive');
    assert(fields() == PLAYER_FELTS, 'fields agrees');
    let mut out: Array<felt252> = array![];
    push_felts(ref out, @p);
    assert(out.len() == PLAYER_FELTS, 'schema length');
}

#[test]
fn test_every_serialized_felt_is_small() {
    let mo = actor(0);
    let mut p = reborn(0, @mo);
    p.deltaviewheight = Fixed { enc: BIAS - 4 * 65536 };
    let mut out: Array<felt252> = array![];
    push_felts(ref out, @p);
    let felts = out.span();
    let mut i: u32 = 0;
    while i != felts.len() {
        let v: u128 = (*felts.at(i)).try_into().unwrap();
        assert(v < 0x1000000000000000000, 'below 2^72');
        i += 1;
    }
}

// ---------------------------------------------------------------------------
// think.cairo
// ---------------------------------------------------------------------------

#[test]
fn test_thrust_pushes_along_the_angle() {
    let mut mo = actor(0);
    thrust(ref mo, 0, 25);
    assert(fixed::gt(mo.momx, fixed::ZERO), 'east');
    // `finesine[0]` is 25, not 0 (the table samples the half-step), so
    // `momy` is a rounding crumb rather than exactly zero.
    assert(fixed::lt(mo.momy, mo.momx), 'and mostly east');
    assert(onground(@mo), 'still on the floor');
}

#[test]
fn test_strafing_right_goes_south() {
    let mut mo = actor(0);
    let mut p = reborn(0, @mo);
    move_player(env_at(mo, 0, 0), ref p, ref mo, 0, 25, 0);
    assert(fixed::lt(mo.momy, fixed::ZERO), 'strafing right goes south');
}

#[test]
fn test_a_negative_turn_wraps() {
    let mut mo = actor(0);
    let mut p = reborn(0, @mo);
    move_player(env_at(mo, 0, 0), ref p, ref mo, 0, 0, -256);
    assert(mo.angle > 0x80000000, 'a negative turn wraps');
}

#[test]
fn test_move_player_enters_the_run_frames() {
    let mut mo = actor(0);
    let mut p = reborn(0, @mo);
    move_player(env_at(mo, 0, 0), ref p, ref mo, 25, 0, 0);
    assert(mo.state == S_PLAY_RUN1, 'walking');
}

#[test]
fn test_reaction_time_blocks_one_tic() {
    let mut mo = actor(0);
    mo.reaction_time = 2;
    let mut p = reborn(0, @mo);
    think_once(ref p, ref mo, word_of(25, 0, 0, 0), 0, 0);
    assert(mo.reaction_time == 1, 'counted down');
    assert(mo.momx == fixed::ZERO, 'and no move');
}

#[test]
fn test_calc_height_airborne_is_unclamped() {
    let mut mo = actor(0);
    mo.z = fixed::from_units(16);
    let mut p = reborn(0, @mo);
    calc_height(ref p, @mo, 0);
    assert(p.viewz == fixed::add(mo.z, p.viewheight), 'airborne view');
}

#[test]
fn test_calc_height_with_cheats_takes_the_same_branch() {
    let mo = actor(0);
    let mut p = reborn(0, @mo);
    p.cheats = 1;
    calc_height(ref p, @mo, 0);
    assert(p.viewz == fixed::add(mo.z, p.viewheight), 'CF_NOMOMENTUM view');
}

#[test]
fn test_the_bob_is_capped() {
    let mut mo = actor(0);
    mo.momx = fixed::from_units(30);
    mo.momy = fixed::from_units(30);
    let mut p = reborn(0, @mo);
    calc_height(ref p, @mo, 0);
    assert(p.bob == maxbob(), 'bob clamped');
}

#[test]
fn test_the_view_springs_back_up_from_a_landing() {
    let mo = actor(0);
    let mut p = reborn(0, @mo);
    p.viewheight = fixed::from_units(10);
    p.deltaviewheight = Fixed { enc: BIAS - 65536 };
    calc_height(ref p, @mo, 1);
    assert(fixed::ge(p.viewheight, fixed::from_units(20)), 'floored at VIEWHEIGHT/2');
    assert(fixed::gt(p.deltaviewheight, fixed::ZERO), 'and pushed upward');
}

#[test]
fn test_the_view_stops_at_view_height() {
    let mo = actor(0);
    let mut p = reborn(0, @mo);
    p.viewheight = fixed::from_units(41);
    p.deltaviewheight = fixed::FRACUNIT;
    calc_height(ref p, @mo, 2);
    assert(p.viewheight == fixed::from_units(41), 'capped');
    assert(p.deltaviewheight == fixed::ZERO, 'and the spring is spent');
}

#[test]
fn test_a_dead_player_view_is_not_sprung() {
    let mo = actor(0);
    let mut p = reborn(0, @mo);
    p.playerstate = PST_DEAD;
    p.viewheight = fixed::from_units(6);
    p.deltaviewheight = fixed::FRACUNIT;
    calc_height(ref p, @mo, 3);
    assert(p.viewheight == fixed::from_units(6), 'dead men do not spring');
}

#[test]
fn test_a_dying_player_turns_toward_its_killer() {
    let (mut p, mut mo) = dead_player(0x60000000);
    die_facing(ref p, ref mo, killer_east());
    assert(mo.angle == 0x60000000 - ANG5, 'turned by ANG5');
}

#[test]
fn test_and_the_other_way_round() {
    let (mut p, mut mo) = dead_player(0xA0000000);
    die_facing(ref p, ref mo, killer_east());
    assert(mo.angle == 0xA0000000 + ANG5, 'turned the other way');
}

#[test]
fn test_nearly_facing_the_killer_snaps() {
    let (mut p, mut mo) = dead_player(0);
    p.damagecount = 3;
    die_facing(ref p, ref mo, killer_east());
    assert(mo.angle == 0, 'snapped to the killer');
    assert(p.damagecount == 2, 'and the flash faded');
}

#[test]
fn test_with_no_attacker_only_the_flash_fades() {
    let (mut p, mut mo) = dead_player(0);
    p.attacker = NO_MOBJ;
    p.damagecount = 3;
    die_facing(ref p, ref mo, killer_east());
    assert(p.damagecount == 2, 'still fading');
    assert(mo.angle == 0, 'and no turn');
}

#[test]
fn test_death_think_is_what_player_think_runs() {
    let (mut p, mut mo) = dead_player(0);
    p.attacker = NO_MOBJ; // nobody else in this one-mobj list
    think_once(ref p, ref mo, word_of(25, 25, 256, BT_USE), BT_USE, 0);
    assert(mo.momx == fixed::ZERO, 'the dead do not thrust');
    assert(mo.angle == 0, 'nor turn on command');
    assert(p.playerstate == PST_DEAD, 'and never respawn here');
}

#[test]
fn test_the_chainsaw_drags_the_player_forward() {
    let mut mo = actor(0);
    mo.flags = mo.flags | doom_physics::MF_JUSTATTACKED;
    let mut p = reborn(0, @mo);
    think_once(ref p, ref mo, word_of(0, 0, 1024, 0), 0, 0);
    assert(!has(mo.flags, doom_physics::MF_JUSTATTACKED), 'the flag is spent');
    assert(mo.angle == 0, 'the turn was dropped');
    assert(fixed::gt(mo.momx, fixed::ZERO), 'and a forward move forced');
}

#[test]
fn test_a_weapon_not_in_the_roster_is_ignored() {
    let mo = actor(0);
    let mut p = reborn(0, @mo);
    change_weapon(ref p, BT_CHANGE + 8 * 5);
    assert(p.pending_weapon == WP_NOCHANGE, 'no plasma here');
    change_weapon(ref p, BT_CHANGE + 8 * WP_CHAINGUN);
    assert(p.pending_weapon == WP_NOCHANGE, 'and none unowned');
}

#[test]
fn test_the_fist_button_prefers_the_chainsaw() {
    let mo = actor(0);
    let mut p = reborn(0, @mo);
    p.weapons = p.weapons + weapon_bit(WP_CHAINSAW);
    change_weapon(ref p, BT_CHANGE + 8 * WP_FIST);
    assert(p.pending_weapon == WP_CHAINSAW, 'the saw wins');
}

#[test]
fn test_but_a_berserk_sawyer_gets_the_fist() {
    let mo = actor(0);
    let mut p = reborn(0, @mo);
    p.weapons = p.weapons + weapon_bit(WP_CHAINSAW);
    p.ready_weapon = WP_CHAINSAW;
    p.strength = 1;
    change_weapon(ref p, BT_CHANGE + 8 * WP_FIST);
    assert(p.pending_weapon == WP_FIST, 'berserk fist wins back');
}

#[test]
fn test_use_lines_reports_one_special_at_most() {
    let mut mo = actor(0);
    let mut g: ThingGrid = new_grid();
    set_thing_position(@world().map, ref g, ref mo, 0);
    let mut k: u32 = 0;
    while k != 4 {
        mo.angle = k * 0x40000000;
        let mut events: Array<PlayerEvent> = array![];
        use_lines(env_at(mo, k, BT_USE), ref g, @mo, ref events);
        assert(events.len() <= 1, 'one special at most');
        k += 1;
    }
}

#[test]
fn test_use_lines_from_the_player_start() {
    let g0 = genesis(LevelId::E1M1);
    let (_, mut mo) = spawn(world(), 0, g0.start, g0.angle);
    let mut g: ThingGrid = new_grid();
    set_thing_position(@world().map, ref g, ref mo, 0);
    let mut events: Array<PlayerEvent> = array![];
    use_lines(env_at(mo, 0, BT_USE), ref g, @mo, ref events);
    assert(events.len() <= 1, 'one special at most');
}

#[test]
fn test_use_is_edge_triggered() {
    let mut mo = actor(0);
    let mut p = reborn(0, @mo);
    think_once(ref p, ref mo, word_of(0, 0, 0, BT_USE), BT_USE, 0);
    assert(p.usedown, 'down');
    think_once(ref p, ref mo, word_of(0, 0, 0, 0), 0, 1);
    assert(!p.usedown, 'released');
}

#[test]
fn test_player_stopped_only_from_a_run_frame() {
    let mut mo = actor(0);
    mo.state = S_PLAY_RUN1 + 3;
    player_stopped(env_at(mo, 0, 0), ref mo);
    assert(mo.state == S_PLAY, 'stopped');
}

#[test]
fn test_player_stopped_leaves_an_attack_frame_alone() {
    let mut mo = actor(0);
    mo.state = S_PLAY_ATK;
    player_stopped(env_at(mo, 0, 0), ref mo);
    assert(mo.state == S_PLAY_ATK, 'attack frame left alone');
}

#[test]
fn test_special_sector_effects() {
    let mut mo = actor(0);
    let mut p = reborn(0, @mo);
    let mut g: ThingGrid = new_grid();
    let mut rng: Prng = from_index(1);
    let mut events: Array<PlayerEvent> = array![];
    player_think(
        env_at(mo, 0, 0), ref g, ref rng, ref p, ref mo, word_of(0, 0, 0, 0), 5, true, ref events,
    );
    assert(p.health == 95, 'nukage');
    assert(p.secretcount == 1, 'secret');
    assert(p.damagecount == 4, 'flash minus one tic');
}

// ---------------------------------------------------------------------------
// weapon.cairo
// ---------------------------------------------------------------------------

#[test]
fn test_every_weapon_chain_is_in_range() {
    let n = world().states.tics.len();
    let mut weapon: u32 = 0;
    while weapon != 5 {
        let c = chain(weapon);
        assert(c.up < n && c.down < n && c.ready < n, 'chain in range');
        assert(c.attack < n && c.flash < n, 'attack and flash in range');
        weapon += 1;
    }
    assert(chain(99) == chain(WP_FIST), 'unknown weapon is the fist');
    assert(MAX_PSPR_DEPTH == 4, 'recursion bound documented');
}

#[test]
fn test_the_flash_slot_runs_its_light_actions() {
    let mut mo = actor(0);
    let mut p = reborn(0, @mo);
    enter_state(ref p, ref mo, PS_FLASH, chain(WP_PISTOL).flash);
    assert(p.flash_state == chain(WP_PISTOL).flash, 'flash set');
    assert(p.extralight == 1, 'A_Light1 ran');
}

#[test]
fn test_s_null_empties_a_slot() {
    let mut mo = actor(0);
    let mut p = reborn(0, @mo);
    enter_state(ref p, ref mo, PS_FLASH, 0);
    assert(p.flash_state == 0, 'state cleared');
    assert(p.flash_tics == 0, 'and tics with it');
}

#[test]
fn test_the_zero_tic_chain_ends_at_s_null() {
    let mut mo = actor(0);
    let mut p = reborn(0, @mo);
    let lightdone = *world().states.next_state.at(chain(WP_PISTOL).flash);
    enter_state(ref p, ref mo, PS_FLASH, lightdone);
    assert(p.extralight == 0, 'A_Light0 ran');
    assert(p.flash_state == 0, 'and the chain ended');
}

#[test]
fn test_the_pistol_fires_and_spends_a_bullet() {
    let mut p = ready_player();
    let mut mo = actor(0);
    let fired = cycle(ref p, ref mo, 30, BT_ATTACK);
    assert(fired != 0, 'the pistol fired');
    assert(ammo_of(@p, AM_CLIP) < 50, 'and spent bullets');
    assert(p.refire != 0, 'and refired while held');
}

#[test]
fn test_a_weapon_ready_bobs_the_weapon() {
    let mut p = ready_player();
    p.bob = fixed::from_units(8);
    let mut mo = actor(0);
    cycle(ref p, ref mo, 1, 0);
    assert(p.psp_sx != fixed::FRACUNIT || p.psp_sy != top(), 'the weapon swings');
    assert(!p.attackdown, 'and the trigger is up');
}

#[test]
fn test_a_switch_lowers_then_raises() {
    let mut p = ready_player();
    p.weapons = p.weapons + weapon_bit(WP_SHOTGUN);
    p.pending_weapon = WP_SHOTGUN;
    let mut mo = actor(0);
    cycle(ref p, ref mo, 80, 0);
    assert(p.ready_weapon == WP_SHOTGUN, 'switched');
    assert(p.psp_sy == top(), 'and back at the top');
    assert(p.psp_state == chain(WP_SHOTGUN).ready, 'and ready');
}

#[test]
fn test_a_dead_player_parks_the_weapon_at_the_bottom() {
    let mut p = ready_player();
    p.playerstate = PST_DEAD;
    p.health = 0;
    p.psp_state = chain(WP_PISTOL).down;
    p.psp_tics = 1;
    let mut mo = actor(0);
    cycle(ref p, ref mo, 40, 0);
    assert(p.psp_sy == fixed::from_units(128), 'parked at WEAPONBOTTOM');
    assert(p.ready_weapon == WP_PISTOL, 'and never swapped');
}

#[test]
fn test_a_player_at_zero_health_puts_the_weapon_away() {
    let mut p = ready_player();
    p.health = 0; // dying, but not yet PST_DEAD
    let mut mo = actor(0);
    cycle(ref p, ref mo, 40, 0);
    assert(p.psp_state == 0, 'the weapon is gone');
}

#[test]
fn test_bring_up_weapon_with_nothing_pending() {
    let mut p = ready_player();
    let mut mo = actor(0);
    let mut g: ThingGrid = new_grid();
    let mut rng: Prng = from_index(1);
    let mut events: Array<PlayerEvent> = array![];
    bring_up_weapon(env_at(mo, 0, 0), ref g, ref rng, ref p, ref mo, ref events, 0);
    assert(p.psp_state == chain(WP_PISTOL).up, 'the ready weapon comes up');
    assert(p.pending_weapon == WP_NOCHANGE, 'and nothing is pending');
}

#[test]
fn test_drop_weapon_starts_the_lowering() {
    let mut p = ready_player();
    let mut mo = actor(0);
    let mut g: ThingGrid = new_grid();
    let mut rng: Prng = from_index(1);
    let mut events: Array<PlayerEvent> = array![];
    drop_weapon(env_at(mo, 0, 0), ref g, ref rng, ref p, ref mo, ref events);
    assert(p.psp_state == chain(WP_PISTOL).down, 'lowering');
    assert(p.psp_tics != 0, 'and animating');
}

#[test]
fn test_a_weapon_that_needs_nothing_always_fires() {
    let mut p = ready_player();
    p.ready_weapon = WP_FIST;
    let mut mo = actor(0);
    assert(ammo_check(ref p, ref mo), 'the fist always fires');
}

#[test]
fn test_check_ammo_prefers_the_chaingun() {
    let mut p = ready_player();
    p.ready_weapon = WP_SHOTGUN;
    p = set_ammo(p, AM_SHELL, 0);
    p.weapons = p.weapons + weapon_bit(WP_SHOTGUN) + weapon_bit(WP_CHAINGUN);
    let mut mo = actor(0);
    assert(!ammo_check(ref p, ref mo), 'no shells');
    assert(p.pending_weapon == WP_CHAINGUN, 'chaingun outranks pistol');
}

#[test]
fn test_check_ammo_falls_to_the_shotgun() {
    let mut p = ready_player();
    p = set_ammo(p, AM_CLIP, 0);
    p = set_ammo(p, AM_SHELL, 4);
    p.weapons = p.weapons + weapon_bit(WP_SHOTGUN);
    let mut mo = actor(0);
    assert(!ammo_check(ref p, ref mo), 'no bullets');
    assert(p.pending_weapon == WP_SHOTGUN, 'shotgun first');
}

#[test]
fn test_check_ammo_falls_all_the_way_to_the_saw() {
    let mut p = ready_player();
    p = set_ammo(p, AM_CLIP, 0);
    p.weapons = p.weapons + weapon_bit(WP_CHAINSAW);
    let mut mo = actor(0);
    assert(!ammo_check(ref p, ref mo), 'no bullets');
    assert(p.pending_weapon == WP_CHAINSAW, 'down to the saw');
}

#[test]
fn test_check_ammo_falls_to_the_fist() {
    let mut p = ready_player();
    p = set_ammo(p, AM_CLIP, 0);
    let mut mo = actor(0);
    assert(!ammo_check(ref p, ref mo), 'no bullets');
    assert(p.pending_weapon == WP_FIST, 'down to the fist');
}

#[test]
fn test_a_punch_lands_in_dooms_damage_range() {
    let mut p = ready_player();
    p.ready_weapon = WP_FIST;
    let mut mo = actor(0);
    let (shots, worst) = enter_state(ref p, ref mo, PS_WEAPON, 6);
    assert(shots == 1, 'one punch');
    assert(worst >= 2 && worst <= 20, 'punch damage in range');
}

#[test]
fn test_berserk_multiplies_a_punch_by_ten() {
    let mut p = ready_player();
    p.ready_weapon = WP_FIST;
    p.strength = 1;
    let mut mo = actor(0);
    let (_, worst) = enter_state(ref p, ref mo, PS_WEAPON, 6);
    assert(worst > 20, 'berserk hits ten times harder');
}

#[test]
fn test_the_saw_bites() {
    let mut p = ready_player();
    p.ready_weapon = WP_CHAINSAW;
    p.weapons = p.weapons + weapon_bit(WP_CHAINSAW);
    let mut mo = actor(0);
    let (shots, _) = enter_state(ref p, ref mo, PS_WEAPON, chain(WP_CHAINSAW).attack);
    assert(shots == 1, 'the saw bit');
}

#[test]
fn test_the_saw_swings_at_a_victim() {
    let mut p = ready_player();
    p.ready_weapon = WP_CHAINSAW;
    let mut mo = actor(0);
    let mut other = killer_east();
    let mut g: ThingGrid = new_grid();
    set_thing_position(@world().map, ref g, ref mo, 0);
    set_thing_position(@world().map, ref g, ref other, 1);
    let mut rng: Prng = from_index(1);
    let mut events: Array<PlayerEvent> = array![];
    set_psprite(
        env_two(mo, other, 0, BT_ATTACK),
        ref g,
        ref rng,
        ref p,
        ref mo,
        ref events,
        PS_WEAPON,
        chain(WP_CHAINSAW).attack,
        0,
    );
    assert(events.len() == 1, 'the saw swung');
}

#[test]
fn test_the_chaingun_needs_a_bullet() {
    let mut p = ready_player();
    p.ready_weapon = WP_CHAINGUN;
    p.weapons = p.weapons + weapon_bit(WP_CHAINGUN);
    p = set_ammo(p, AM_CLIP, 0);
    let mut mo = actor(0);
    let (shots, _) = enter_state(ref p, ref mo, PS_WEAPON, chain(WP_CHAINGUN).attack);
    assert(shots == 0, 'A_FireCGun fires nothing dry');
}

#[test]
fn test_the_chaingun_fires_with_one() {
    let mut p = ready_player();
    p.ready_weapon = WP_CHAINGUN;
    p.weapons = p.weapons + weapon_bit(WP_CHAINGUN);
    p = set_ammo(p, AM_CLIP, 2);
    let mut mo = actor(0);
    let (shots, _) = enter_state(ref p, ref mo, PS_WEAPON, chain(WP_CHAINGUN).attack);
    assert(shots == 1, 'one bullet, one shot');
    assert(ammo_of(@p, AM_CLIP) == 1, 'and one spent');
}

#[test]
fn test_the_shotgun_fires_seven_pellets() {
    let mut p = ready_player();
    p.ready_weapon = WP_SHOTGUN;
    p.weapons = p.weapons + weapon_bit(WP_SHOTGUN);
    p = set_ammo(p, AM_SHELL, 8);
    let mut mo = actor(0);
    let fire = *world().states.next_state.at(chain(WP_SHOTGUN).attack);
    let (shots, _) = enter_state(ref p, ref mo, PS_WEAPON, fire);
    assert(shots == 7, 'seven pellets');
    assert(ammo_of(@p, AM_SHELL) == 7, 'one shell');
    assert(p.flash_state != 0, 'and a muzzle flash');
}

#[test]
fn test_bullet_slope_finds_nothing_to_aim_at() {
    let g0 = genesis(LevelId::E1M1);
    let (_, mut mo) = spawn(world(), 0, g0.start, g0.angle);
    let mut g: ThingGrid = new_grid();
    set_thing_position(@world().map, ref g, ref mo, 0);
    let slope = bullet_slope(world(), array![BoxTrait::new(mo)].span(), ref g, @mo, 0);
    assert(slope == fixed::ZERO, 'no target, no slope');
}

// ---------------------------------------------------------------------------
// inter.cairo
// ---------------------------------------------------------------------------

#[test]
fn test_armor_is_taken() {
    assert(takes(KIND_MISC0, MF_SPECIAL), 'green armor');
    assert(takes(KIND_MISC1, MF_SPECIAL), 'blue armor');
    assert(takes(KIND_MISC3, MF_SPECIAL), 'armor bonus');
}

#[test]
fn test_health_is_taken() {
    assert(takes(KIND_MISC2, MF_SPECIAL), 'health bonus');
    assert(takes(KIND_MISC10, MF_SPECIAL), 'stimpack');
    assert(takes(KIND_MISC11, MF_SPECIAL), 'medikit');
}

#[test]
fn test_the_key_and_the_spheres_is_taken() {
    assert(takes(KIND_MISC4, MF_SPECIAL), 'blue keycard');
    assert(takes(KIND_MISC12, MF_SPECIAL), 'soulsphere');
    assert(takes(KIND_MISC13, MF_SPECIAL), 'berserk');
}

#[test]
fn test_bullets_is_taken() {
    assert(takes(KIND_CLIP, MF_SPECIAL), 'clip');
    assert(takes(KIND_MISC17, MF_SPECIAL), 'box of bullets');
}

#[test]
fn test_shells_is_taken() {
    assert(takes(KIND_MISC22, MF_SPECIAL), 'shells');
    assert(takes(KIND_MISC23, MF_SPECIAL), 'box of shells');
}

#[test]
fn test_rockets_is_taken() {
    assert(takes(KIND_MISC18, MF_SPECIAL), 'rocket');
    assert(takes(KIND_MISC19, MF_SPECIAL), 'box of rockets');
}

#[test]
fn test_cells_is_taken() {
    assert(takes(KIND_MISC20, MF_SPECIAL), 'cell');
    assert(takes(KIND_MISC21, MF_SPECIAL), 'cell pack');
}

#[test]
fn test_the_backpack_and_the_saw_is_taken() {
    assert(takes(KIND_MISC24, MF_SPECIAL), 'backpack');
    assert(takes(KIND_MISC26, MF_SPECIAL), 'chainsaw');
}

#[test]
fn test_the_two_guns_is_taken() {
    assert(takes(KIND_CHAINGUN, MF_SPECIAL), 'chaingun');
    assert(takes(KIND_SHOTGUN, MF_SPECIAL), 'shotgun');
}

#[test]
fn test_dropped_items_are_taken_too() {
    assert(takes(KIND_CLIP, MF_SPECIAL + MF_DROPPED), 'a dropped clip');
    assert(takes(KIND_SHOTGUN, MF_SPECIAL + MF_DROPPED), 'a dropped shotgun');
}

#[test]
fn test_things_with_no_slot_are_left_alone() {
    assert(!takes(KIND_MISC27, MF_SPECIAL), 'no rocket launcher');
    assert(!takes(KIND_MISC28, MF_SPECIAL), 'no plasma rifle');
    assert(!takes(KIND_POSSESSED, MF_SPECIAL), 'a zombieman is no item');
}

#[test]
fn test_full_health_refuses_a_stimpack() {
    let mut mo = actor(0);
    let mut p = reborn(0, @mo);
    assert(!touch_special(ref p, ref mo, @item(KIND_MISC10, MF_SPECIAL)), 'no room');
    assert(touch_special(ref p, ref mo, @item(KIND_MISC2, MF_SPECIAL)), 'but a bonus fits');
}

#[test]
fn test_green_armor_under_blue_is_refused() {
    let mut mo = actor(0);
    let mut p = reborn(0, @mo);
    give_armor(ref p, 2);
    assert(!touch_special(ref p, ref mo, @item(KIND_MISC0, MF_SPECIAL)), 'green under blue');
}

#[test]
fn test_a_full_clip_refuses_more() {
    let mut mo = actor(0);
    let mut p = reborn(0, @mo);
    p = set_ammo(p, AM_CLIP, max_ammo(@p, AM_CLIP));
    assert(!touch_special(ref p, ref mo, @item(KIND_CLIP, MF_SPECIAL)), 'clip full');
}

#[test]
fn test_out_of_reach_above_and_below() {
    let mut mo = actor(0);
    let mut p = reborn(0, @mo);
    let mut high = item(KIND_MISC2, MF_SPECIAL);
    high.z = fixed::from_units(200);
    assert(!touch_special(ref p, ref mo, @high), 'out of reach above');
    let mut low = item(KIND_MISC2, MF_SPECIAL);
    low.z = fixed::from_units(-16);
    assert(!touch_special(ref p, ref mo, @low), 'out of reach below');
}

#[test]
fn test_a_corpse_takes_nothing() {
    let mut mo = actor(0);
    mo.health = 0;
    let mut p = reborn(0, @mo);
    assert(!touch_special(ref p, ref mo, @item(KIND_MISC2, MF_SPECIAL)), 'a corpse takes none');
}

#[test]
fn test_only_count_item_things_are_counted() {
    let mut mo = actor(0);
    let mut p = reborn(0, @mo);
    touch_special(ref p, ref mo, @item(KIND_MISC2, MF_SPECIAL + MF_COUNTITEM));
    assert(p.itemcount == 1, 'counted');
    touch_special(ref p, ref mo, @item(KIND_CLIP, MF_SPECIAL));
    assert(p.itemcount == 1, 'ammo is not an item');
    assert(p.bonuscount != 0, 'and the screen flashed');
}

#[test]
fn test_a_dropped_clip_is_worth_half() {
    let mut mo = actor(0);
    let mut p = reborn(0, @mo);
    p = set_ammo(p, AM_CLIP, 0);
    touch_special(ref p, ref mo, @item(KIND_CLIP, MF_SPECIAL + MF_DROPPED));
    assert(ammo_of(@p, AM_CLIP) == 5, 'half a clip');
}

#[test]
fn test_bullets_raise_the_chaingun_over_the_pistol() {
    let mo = actor(0);
    let mut p = reborn(0, @mo);
    p = set_ammo(p, AM_CLIP, 0);
    p.ready_weapon = WP_FIST;
    p.weapons = p.weapons + weapon_bit(WP_CHAINGUN);
    give_ammo(ref p, AM_CLIP, 1);
    assert(p.pending_weapon == WP_CHAINGUN, 'chaingun outranks pistol');
}

#[test]
fn test_bullets_from_empty_raise_the_pistol() {
    let mo = actor(0);
    let mut p = reborn(0, @mo);
    p = set_ammo(p, AM_CLIP, 0);
    p.ready_weapon = WP_FIST;
    give_ammo(ref p, AM_CLIP, 1);
    assert(p.pending_weapon == WP_PISTOL, 'up from the fist');
}

#[test]
fn test_ammo_on_top_of_ammo_raises_nothing() {
    let mo = actor(0);
    let mut p = reborn(0, @mo);
    p.ready_weapon = WP_FIST;
    give_ammo(ref p, AM_CLIP, 1);
    assert(p.pending_weapon == WP_NOCHANGE, 'lower on purpose');
}

#[test]
fn test_shells_raise_the_shotgun() {
    let mo = actor(0);
    let mut p = reborn(0, @mo);
    p.weapons = p.weapons + weapon_bit(WP_SHOTGUN);
    give_ammo(ref p, AM_SHELL, 1);
    assert(p.pending_weapon == WP_SHOTGUN, 'shells raise the shotgun');
}

#[test]
fn test_cells_and_rockets_raise_nothing_here() {
    let mo = actor(0);
    let mut p = reborn(0, @mo);
    give_ammo(ref p, AM_CELL, 1);
    give_ammo(ref p, AM_MISL, 1);
    assert(p.pending_weapon == WP_NOCHANGE, 'nothing to raise');
    assert(!give_ammo(ref p, AM_NOAMMO, 1), 'am_noammo gives nothing');
}

#[test]
fn test_the_backpack_doubles_every_maximum_once() {
    let mut mo = actor(0);
    let mut p = reborn(0, @mo);
    assert(touch_special(ref p, ref mo, @item(KIND_MISC24, MF_SPECIAL)), 'took it');
    assert(max_ammo(@p, AM_CLIP) == 400, 'bullets doubled');
    assert(touch_special(ref p, ref mo, @item(KIND_MISC24, MF_SPECIAL)), 'a second gives ammo');
    assert(max_ammo(@p, AM_CLIP) == 400, 'but does not double again');
}

#[test]
fn test_a_found_weapon_gives_two_clips() {
    let mut mo = actor(0);
    let mut p = reborn(0, @mo);
    touch_special(ref p, ref mo, @item(KIND_SHOTGUN, MF_SPECIAL));
    assert(ammo_of(@p, AM_SHELL) == 8, 'two clips of shells');
    assert(owns(@p, WP_SHOTGUN), 'and the shotgun');
}

#[test]
fn test_a_dropped_weapon_gives_one() {
    let mut mo = actor(0);
    let mut p = reborn(0, @mo);
    touch_special(ref p, ref mo, @item(KIND_SHOTGUN, MF_SPECIAL + MF_DROPPED));
    assert(ammo_of(@p, AM_SHELL) == 4, 'one clip of shells');
}

#[test]
fn test_a_weapon_already_owned_only_tops_up() {
    let mut mo = actor(0);
    let mut p = reborn(0, @mo);
    p = set_ammo(p, AM_CLIP, max_ammo(@p, AM_CLIP));
    assert(!give_weapon(ref p, WP_PISTOL, false), 'nothing left to give');
    assert(give_weapon(ref p, WP_CHAINSAW, false), 'the saw is new');
    assert(!give_weapon(ref p, WP_CHAINSAW, false), 'and only new once');
}

#[test]
fn test_give_body_caps_and_mirrors() {
    let mut mo = actor(0);
    let mut p = reborn(0, @mo);
    assert(!give_body(ref p, ref mo, 10), 'already at 100');
    p.health = 95;
    assert(give_body(ref p, ref mo, 25), 'healed');
    assert(p.health == 100, 'and capped');
    assert(mo.health == 100, 'and mirrored');
}

#[test]
fn test_berserk_heals_to_a_hundred() {
    let mut mo = actor(0);
    let mut p = reborn(0, @mo);
    p.health = 20;
    assert(give_strength(ref p, ref mo), 'berserk');
    assert(p.health == 100 && p.strength == 1, 'healed and strong');
}

#[test]
fn test_health_never_passes_two_hundred() {
    let mut mo = actor(0);
    let mut p = reborn(0, @mo);
    let mut i: u32 = 0;
    while i != 150 {
        touch_special(ref p, ref mo, @item(KIND_MISC2, MF_SPECIAL));
        assert(p.health <= 200, 'health never over 200');
        i += 1;
    }
    assert(p.health == 200, 'and it does reach 200');
}

#[test]
fn test_armor_never_passes_two_hundred() {
    let mut mo = actor(0);
    let mut p = reborn(0, @mo);
    let mut i: u32 = 0;
    while i != 250 {
        touch_special(ref p, ref mo, @item(KIND_MISC3, MF_SPECIAL));
        assert(p.armor_points <= 200, 'armor never over 200');
        i += 1;
    }
    assert(p.armor_type == 1, 'bare armor turns green');
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
        a += 1;
    }
}

#[test]
fn test_armor_absorbs_a_third_or_a_half() {
    let mo = actor(0);
    let mut green = reborn(0, @mo);
    green.armor_type = 1;
    green.armor_points = 100;
    assert(absorb(ref green, 30) == 20, 'green eats a third');
    assert(green.armor_points == 90, 'green spends 10');
    let mut blue = reborn(0, @mo);
    blue.armor_type = 2;
    blue.armor_points = 200;
    assert(absorb(ref blue, 30) == 15, 'blue eats a half');
}

#[test]
fn test_armor_that_runs_out_is_dropped() {
    let mo = actor(0);
    let mut p = reborn(0, @mo);
    p.armor_type = 1;
    p.armor_points = 2;
    assert(absorb(ref p, 30) == 28, 'only 2 points to give');
    assert(p.armor_points == 0 && p.armor_type == 0, 'spent and gone');
    assert(absorb(ref p, 12) == 12, 'no armor, no absorption');
    assert(nobody() == NO_MOBJ, 'the no-inflictor sentinel');
}

#[test]
fn test_a_hit_that_does_not_kill() {
    let mut mo = actor(0);
    let mut p = reborn(0, @mo);
    hurt(ref p, ref mo, 10);
    assert(p.health == 90, 'ten off');
    assert(p.damagecount == 10, 'and a flash');
    assert(p.playerstate == PST_LIVE, 'still alive');
}

#[test]
fn test_a_hit_that_kills() {
    let mut mo = actor(0);
    let mut p = reborn(0, @mo);
    hurt(ref p, ref mo, 400);
    assert(p.health == 0, 'dead');
    assert(p.damagecount == 100, 'flash capped');
    assert(p.playerstate == PST_DEAD, 'and D14 status 1');
}

#[test]
fn test_a_corpse_takes_no_more_damage() {
    let mut mo = actor(0);
    mo.health = 0;
    let mut p = reborn(0, @mo);
    p.health = 0;
    hurt(ref p, ref mo, 10);
    assert(p.health == 0, 'the dead take nothing');
}

#[test]
fn test_something_that_cannot_be_shot_is_not_hurt() {
    let mut ghost = actor(0);
    ghost.flags = 0;
    let mut p = reborn(0, @ghost);
    hurt(ref p, ref ghost, 10);
    assert(p.health == 100, 'not shootable, not hurt');
    count_kill(ref p);
    assert(p.killcount == 1, 'a kill counted');
}

// ---------------------------------------------------------------------------
// tic.cairo
// ---------------------------------------------------------------------------

#[test]
fn test_player_tic_wires_the_specials_in() {
    let m = load(LevelId::E1M1);
    let lm = doom_specials::load(LevelId::E1M1);
    let mut mo = actor(0);
    let mut p = reborn(0, @mo);
    let mut g: ThingGrid = new_grid();
    let mut rng: Prng = from_index(1);
    let (specials, _) = doom_specials::spawn_specials(
        @m, @lm, from_index(1), doom_things::rndtable(),
    );
    let mut events: Array<PlayerEvent> = array![];
    player_tic(
        env_at(mo, 0, BT_USE),
        @m,
        @lm,
        specials,
        ref g,
        ref rng,
        ref p,
        ref mo,
        word_of(0, 0, 0, BT_USE),
        ref events,
    );
    assert(p.usedown, 'the use button was seen');
}

#[test]
fn test_player_tic_skips_the_sector_when_dead() {
    let m = load(LevelId::E1M1);
    let lm = doom_specials::load(LevelId::E1M1);
    let mut mo = actor(0);
    let mut p = reborn(0, @mo);
    p.playerstate = PST_DEAD;
    let mut g: ThingGrid = new_grid();
    let mut rng: Prng = from_index(1);
    let (specials, _) = doom_specials::spawn_specials(
        @m, @lm, from_index(1), doom_things::rndtable(),
    );
    let mut events: Array<PlayerEvent> = array![];
    let (after, _) = player_tic(
        env_at(mo, 1, 0),
        @m,
        @lm,
        specials,
        ref g,
        ref rng,
        ref p,
        ref mo,
        word_of(0, 0, 0, 0),
        ref events,
    );
    assert(after.secrets == 0, 'no secret while dead');
}

