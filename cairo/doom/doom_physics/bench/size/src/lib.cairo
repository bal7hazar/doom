// SPDX-License-Identifier: GPL-2.0-only
//! The "with physics" side of `doom_physics`'s bytecode measurement: every
//! public entry point called once, on the real level, so that nothing is
//! dead-code-eliminated. `../baseline` loads the same data and calls none
//! of them.

use doom_map::{LevelId, genesis, load, thing};
use doom_physics::{
    MoveEvent, SpawnZ, aim_line_attack, check_sight, check_sight_cached, damage_mobj,
    explode_missile, line_attack, new_grid, push_felts, rebuild, replace, set_thing_position,
    slide_move, slide_move_lite, spawn_map_thing, spawn_missile, spawn_mobj, try_move, world_of,
    xy_movement, z_movement,
};
use doom_things::tables::{KIND_POSSESSED, KIND_TROOP, KIND_TROOPSHOT};
use fixed::Fixed;
use prng::from_index;

#[executable]
fn main(op: u32) -> felt252 {
    let m = load(LevelId::E1M1);
    let g = genesis(LevelId::E1M1);
    let w = world_of(@m);
    let t = thing(@m, 0);
    let mut acc: felt252 = op.into();
    acc += g.start.x.enc + t.position.x.enc;

    let mut grid = new_grid();
    let mut rng = from_index(op);
    let mut events: Array<MoveEvent> = array![];
    let mut player = spawn_mobj(w, KIND_POSSESSED, g.start.x, g.start.y, SpawnZ::OnFloor);
    set_thing_position(@w.map, ref grid, ref player, 0);
    let mut imp = spawn_mobj(
        w, KIND_TROOP, fixed::add(g.start.x, fixed::from_units(200)), g.start.y, SpawnZ::OnFloor,
    );
    set_thing_position(@w.map, ref grid, ref imp, 1);
    let mut list = array![player, imp];
    let mobjs = list.span();

    let x = fixed::add(player.x, Fixed { enc: 0x100000000 + 4 * 65536 });
    if try_move(w, mobjs, ref grid, ref player, 0, x, player.y, ref events).ok {
        acc += 1;
    }
    player.momx = fixed::from_units(3);
    xy_movement(w, mobjs, ref grid, ref player, 0, true, true, ref events);
    z_movement(ref player, Option::Some(mobjs.at(1)));
    slide_move(w, mobjs, ref grid, ref player, 0, ref events);
    slide_move_lite(w, mobjs, ref grid, ref player, 0, ref events);
    if check_sight(w, @player, @imp) {
        acc += 2;
    }
    if check_sight_cached(w, ref imp, @player, 3, 4) {
        acc += 4;
    }
    let aim = aim_line_attack(w, mobjs, ref grid, 0, player.angle, fixed::from_units(1024));
    acc += aim.slope.enc;
    match line_attack(w, mobjs, ref grid, 0, player.angle, fixed::from_units(2048), aim.slope) {
        doom_physics::Hit::Nothing => {},
        doom_physics::Hit::Wall((line, _, _)) => { acc += line.into(); },
        doom_physics::Hit::Thing((idx, _, _)) => { acc += idx.into(); },
    }
    let out = damage_mobj(w, mobjs, ref rng, ref imp, 1, 0, 0, 5, true);
    if out.pain {
        acc += 8;
    }
    let (mut ball, exploded) = spawn_missile(
        w, mobjs, ref grid, ref rng, @imp, 1, @player, KIND_TROOPSHOT, 2, ref events,
    );
    if exploded {
        acc += 16;
    }
    explode_missile(w, ref rng, ref ball);
    match spawn_map_thing(w, t) {
        Option::Some(mo) => { acc += mo.z.enc; },
        Option::None => {},
    }
    replace(ref list, 1, imp);
    let mut felts: Array<felt252> = array![];
    push_felts(ref felts, @player);
    let mut g2 = rebuild(list.span());
    acc += doom_physics::things_in(ref g2, player.cell).len().into();
    acc + felts.len().into() + events.len().into()
}
