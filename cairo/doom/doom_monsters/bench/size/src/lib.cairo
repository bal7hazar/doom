// SPDX-License-Identifier: GPL-2.0-only
//! The "with the AI" side of `doom_monsters`' bytecode measurement:
//! `../baseline` verbatim, plus one call to every public entry point of this
//! crate, so that nothing is dead-code-eliminated. The difference between
//! the two compiled sizes is `doom_monsters`' own code.
//!
//! Measured twice (`measure.py` prints both):
//!
//! * with the default `full_api` feature — the **whole public surface**,
//!   sixteen entry points that each take the 72-felt `Ctx` and the actor by
//!   `ref`;
//! * without it — **the ticker alone**, which is what `doom_game` calls and
//!   therefore what ends up in the proved program that D29 budgets at
//!   15 000 words.
//!
//! The difference between the two is the price of the public boundary; see
//! ../../README.md.

use doom_map::{LevelId, genesis, load, reject_of, thing};
use doom_monsters::actions::{
    a_chase, a_face_target, a_look, a_pos_attack, a_sarg_attack, a_scream, a_spos_attack,
    a_troop_attack, check_melee_range, check_missile_range, hurt, look_for_players, new_chase_dir,
    p_move, passive,
};
use doom_monsters::event::{drain, event, missile_hit, sound};
use doom_monsters::think::{awake_count, in_window, is_awake, is_dormant, mobj_thinker};
use doom_monsters::{Ctx, MonsterEvent, Patch, monsters_ticker, read_mobj, silence};
use doom_physics::{
    Mobj, MoveEvent, SpawnZ, ThingGrid, World, aim_line_attack, bleeds, check_sight_cached,
    damage_mobj, explode_missile, first_free, is_removed, line_attack, new_grid, removed_mobj,
    set_state, set_thing_position, spawn_map_thing, spawn_missile, spawn_mobj, try_move,
    unset_thing_position, xy_movement, z_movement,
};
use doom_things::tables::{
    A_PAIN, KIND_PLAYER, KIND_POSSESSED, KIND_TROOP, KIND_TROOPSHOT, MI_MELEESTATE, MI_MISSILESTATE,
    MI_RADIUS, MI_SEESTATE, MI_SPAWNSTATE, MI_SPEED,
};
use fixed::Fixed;
use prng::{Prng, PrngTrait, from_index};

#[executable]
fn main(op: u32) -> felt252 {
    let m = load(LevelId::E1M1);
    let g = genesis(LevelId::E1M1);
    let w = doom_physics::world_of(@m);
    let t = thing(@m, 0);
    let mut acc: felt252 = op.into();
    acc += g.start.x.enc + t.position.x.enc;

    let mut grid = new_grid();
    let mut rng = from_index(op);
    let mut events: Array<MoveEvent> = array![];
    let mut player = spawn_mobj(w, KIND_PLAYER, g.start.x, g.start.y, SpawnZ::OnFloor);
    set_thing_position(@w.map, ref grid, ref player, 0);
    let mut mon = spawn_mobj(
        w,
        KIND_POSSESSED,
        fixed::add(g.start.x, fixed::from_units(200)),
        g.start.y,
        SpawnZ::OnFloor,
    );
    set_thing_position(@w.map, ref grid, ref mon, 1);
    let mut list = array![player, mon];
    let mobjs = list.span();

    // -- the same physics calls as `../baseline` ----------------------------
    let x = fixed::add(mon.x, Fixed { enc: 0x100000000 + 4 * 65536 });
    if try_move(w, mobjs, ref grid, ref mon, 1, x, mon.y, ref events).ok {
        acc += 1;
    }
    xy_movement(w, mobjs, ref grid, ref mon, 1, false, false, ref events);
    z_movement(ref mon, Option::None);
    if check_sight_cached(w, ref mon, @player, 1, 8) {
        acc += 2;
    }
    if reject_of(w.map.reject, w.map.reject_stride, w.map.pow2, mon.sector, player.sector) {
        acc += 4;
    }
    let aim = aim_line_attack(w, mobjs, ref grid, 1, mon.angle, fixed::from_units(2048));
    acc += aim.slope.enc;
    match line_attack(w, mobjs, ref grid, 1, mon.angle, fixed::from_units(2048), aim.slope) {
        doom_physics::Hit::Nothing => {},
        doom_physics::Hit::Wall((line, _, _)) => { acc += line.into(); },
        doom_physics::Hit::Thing((idx, _, _)) => { acc += idx.into(); },
    }
    let mut victim = player;
    let out = damage_mobj(w, mobjs, ref rng, ref victim, 0, 1, 1, 5, true);
    acc += out.action.into();
    match out.drop {
        Option::Some(d) => { acc += d.kind.into(); },
        Option::None => {},
    }
    let (missile, exploded) = spawn_missile(
        w, mobjs, ref grid, ref rng, @mon, 1, @player, KIND_TROOPSHOT, 2, ref events,
    );
    let mut fireball = missile;
    if exploded {
        acc += 8;
    }
    acc += explode_missile(w, ref rng, ref fireball).into();
    acc += set_state(w, ref mon, *MI_SEESTATE.span().at(KIND_POSSESSED)).into();
    unset_thing_position(ref grid, @fireball, 2);
    acc += first_free(mobjs).into();
    if is_removed(@removed_mobj()) {
        acc += 16;
    }
    if bleeds(@player) {
        acc += 32;
    }
    match spawn_map_thing(w, t) {
        Option::Some(mo) => { acc += mo.kind.into(); },
        Option::None => {},
    }
    acc += (*MI_SPEED.span().at(KIND_TROOP)).into();
    acc += (*MI_SPAWNSTATE.span().at(KIND_TROOP)).into();
    acc += (*MI_MELEESTATE.span().at(KIND_TROOP)).into();
    acc += (*MI_MISSILESTATE.span().at(KIND_TROOP)).into();
    acc += *MI_RADIUS.span().at(KIND_TROOP);
    let (nrng, roll) = rng.next(w.rndtable);
    rng = nrng;
    acc += roll.into();
    let (state, tics, action) = fsm::advance(w.states, mon.state, mon.tics);
    acc += state.into() + tics.into() + action.into();

    // -- and every public entry point of `doom_monsters` --------------------
    acc += public_surface(w, mobjs, ref grid, ref rng, ref mon, @player, events.span(), op);
    let players = array![0].span();
    let (after, r2, ev2) = monsters_ticker(w, mobjs, ref grid, players, silence(), op, rng);
    acc + after.len().into() + r2.index.into() + ev2.len().into()
}

/// One call to every public entry point of the crate, so that nothing is
/// dead-code-eliminated: the sixteen that take a `Ctx`, plus the scheduler
/// and event helpers.
#[cfg(feature: "full_api")]
#[inline(always)]
fn public_surface(
    w: World,
    mobjs: Span<Mobj>,
    ref grid: ThingGrid,
    ref rng: Prng,
    ref mon: Mobj,
    player: @Mobj,
    events: Span<MoveEvent>,
    op: u32,
) -> felt252 {
    let mut acc: felt252 = 0;
    let players = array![0].span();
    let ctx = Ctx { w, players, noise: silence(), tic: op };
    let mut ev: Array<MonsterEvent> = array![];
    let mut patches: Array<Patch> = array![];
    let mut spawn_at: u32 = 2;
    mon.target = 0;
    mon.reaction_time = 0;

    acc += a_look(ctx, mobjs, ref rng, ref mon, 1, ref ev).into();
    acc += a_chase(ctx, mobjs, ref grid, ref rng, ref mon, 1, patches.span(), ref ev).into();
    a_face_target(ctx, ref rng, ref mon, player);
    if check_melee_range(ctx, ref mon, player) {
        acc += 64;
    }
    if check_missile_range(ctx, ref rng, ref mon, player) {
        acc += 128;
    }
    if look_for_players(ctx, mobjs, ref mon, true) {
        acc += 256;
    }
    if p_move(ctx, mobjs, ref grid, ref mon, 1, ref ev) {
        acc += 512;
    }
    new_chase_dir(ctx, mobjs, ref grid, ref rng, ref mon, 1, player, ref ev);
    a_pos_attack(ctx, mobjs, ref grid, ref rng, ref mon, 1, ref patches, ref ev);
    a_spos_attack(ctx, mobjs, ref grid, ref rng, ref mon, 1, ref patches, ref ev);
    a_troop_attack(ctx, mobjs, ref grid, ref rng, ref mon, 1, ref patches, ref ev, ref spawn_at);
    a_sarg_attack(ctx, mobjs, ref rng, ref mon, 1, ref patches, ref ev);
    a_scream(ctx, ref rng, ref mon, 1, ref ev);
    passive(ctx, ref rng, ref mon, 1, A_PAIN, ref ev);
    hurt(ctx, mobjs, ref rng, 0, 1, 1, 3, ref patches, ref ev);
    if mobj_thinker(
        ctx, mobjs, ref grid, ref rng, ref mon, 1, true, true, ref patches, ref ev, ref spawn_at,
    ) {
        acc += 1024;
    }
    if is_dormant(w, @mon) {
        acc += 2048;
    }
    if is_awake(w, @mon) {
        acc += 4096;
    }
    if in_window(0, op, 9) {
        acc += 8192;
    }
    acc += awake_count(w, mobjs).into();
    acc += read_mobj(mobjs, patches.span(), 0).kind.into();
    drain(events, 1, ref ev);
    acc += missile_hit(events).into();
    ev.append(event(1, 1, 2, 3));
    ev.append(sound(1, 4));
    acc + ev.len().into()
}

/// Without `full_api`: only what `doom_game` calls, so that the measurement
/// is the crate's contribution to the *proved* program.
#[cfg(not(feature: "full_api"))]
#[inline(always)]
fn public_surface(
    w: World,
    mobjs: Span<Mobj>,
    ref grid: ThingGrid,
    ref rng: Prng,
    ref mon: Mobj,
    player: @Mobj,
    events: Span<MoveEvent>,
    op: u32,
) -> felt252 {
    mon.target = 0;
    mon.reaction_time = 0;
    (mobjs.len() + events.len() + op).into()
}
