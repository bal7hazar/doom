// SPDX-License-Identifier: GPL-2.0-only
//! The "without the AI" side of `doom_monsters`' bytecode measurement.
//!
//! It loads the same level and tables as `../size` **and calls every
//! `doom_physics` and `doom_map` entry point the AI calls**, so that all of
//! that code is already in the program: the difference between the two
//! compiled sizes is then `doom_monsters`' own code, not the 57 000 words of
//! physics it stands on (docs/DECISIONS.md D23 budgets this crate 5 000).

use doom_map::{LevelId, genesis, load, reject_of, thing};
use doom_physics::{
    MoveEvent, SpawnZ, aim_line_attack, bleeds, check_sight_cached, damage_mobj, explode_missile,
    first_free, is_removed, line_attack, new_grid, removed_mobj, set_state, set_thing_position,
    spawn_map_thing, spawn_missile, spawn_mobj, try_move, unset_thing_position, xy_movement,
    z_movement,
};
use doom_things::tables::{
    KIND_PLAYER, KIND_POSSESSED, KIND_TROOP, KIND_TROOPSHOT, MI_MELEESTATE, MI_MISSILESTATE,
    MI_RADIUS, MI_SEESTATE, MI_SPAWNSTATE, MI_SPEED,
};
use fixed::Fixed;
use prng::{PrngTrait, from_index};

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
    // The `mobjinfo` columns the AI reads one at a time.
    acc += (*MI_SPEED.span().at(KIND_TROOP)).into();
    acc += (*MI_SPAWNSTATE.span().at(KIND_TROOP)).into();
    acc += (*MI_MELEESTATE.span().at(KIND_TROOP)).into();
    acc += (*MI_MISSILESTATE.span().at(KIND_TROOP)).into();
    acc += *MI_RADIUS.span().at(KIND_TROOP);
    let (next, roll) = rng.next(w.rndtable);
    acc += roll.into() + next.index.into();
    let (state, tics, action) = fsm::advance(w.states, mon.state, mon.tics);
    acc + state.into() + tics.into() + action.into()
}
