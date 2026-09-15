// SPDX-License-Identifier: GPL-2.0-only
//! The "with physics" side of `doom_physics`'s bytecode measurement: every
//! public entry point called once, on the real level, so that nothing is
//! dead-code-eliminated. `../baseline` loads the same data and calls none
//! of them.
//!
//! Every scalar argument is derived from `op` rather than written as a
//! literal: Cairo 2.16 specialises a function on the constant arguments of
//! a call site (S7 §2), and a specialised copy of `xy_movement` measured
//! 936 words that no game caller would produce.

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
    // `zero` is 0 for every `op` below 1000, and unknown to the compiler.
    let zero: u32 = op / 1000;
    let one: u32 = zero + 1;
    let two: u32 = zero + 2;
    let zf: felt252 = zero.into();
    let yes: bool = zero == 0;

    let mut grid = new_grid();
    let mut rng = from_index(op);
    let mut events: Array<MoveEvent> = array![];
    let mut player = spawn_mobj(w, KIND_POSSESSED + zero, g.start.x, g.start.y, SpawnZ::OnFloor);
    set_thing_position(@w.map, ref grid, ref player, zero);
    let mut imp = spawn_mobj(
        w,
        KIND_TROOP + zero,
        fixed::add(g.start.x, fixed::from_units(200 + zf)),
        g.start.y,
        SpawnZ::OnFloor,
    );
    set_thing_position(@w.map, ref grid, ref imp, one);
    let mut list = array![BoxTrait::new(player), BoxTrait::new(imp)];
    let mobjs = list.span();

    let x = fixed::add(player.x, Fixed { enc: 0x100000000 + 4 * 65536 + zf });
    if try_move(w, mobjs, ref grid, ref player, zero, x, player.y, ref events).ok {
        acc += 1;
    }
    player.momx = fixed::from_units(3 + zf);
    xy_movement(w, mobjs, ref grid, ref player, zero, yes, yes, ref events);
    z_movement(ref player, Option::Some(mobjs.at(one).as_snapshot().unbox()));
    slide_move(w, mobjs, ref grid, ref player, zero, ref events);
    slide_move_lite(w, mobjs, ref grid, ref player, zero, ref events);
    if check_sight(w, @player, @imp) {
        acc += 2;
    }
    if check_sight_cached(w, ref imp, @player, zero + 3, zero + 4) {
        acc += 4;
    }
    let aim = aim_line_attack(w, mobjs, ref grid, zero, player.angle, fixed::from_units(1024 + zf));
    acc += aim.slope.enc;
    match line_attack(
        w, mobjs, ref grid, zero, player.angle, fixed::from_units(2048 + zf), aim.slope,
    ) {
        doom_physics::Hit::Nothing => {},
        doom_physics::Hit::Wall((line, _, _)) => { acc += line.into(); },
        doom_physics::Hit::Thing((idx, _, _)) => { acc += idx.into(); },
    }
    let out = damage_mobj(w, mobjs, ref rng, ref imp, one, zero, zero, zero + 5, yes);
    if out.pain {
        acc += 8;
    }
    let (mut ball, exploded) = spawn_missile(
        w, mobjs, ref grid, ref rng, @imp, one, @player, KIND_TROOPSHOT + zero, two, ref events,
    );
    if exploded {
        acc += 16;
    }
    explode_missile(w, ref rng, ref ball);
    match spawn_map_thing(w, t) {
        Option::Some(mo) => { acc += mo.z.enc; },
        Option::None => {},
    }
    replace(ref list, one, BoxTrait::new(imp));
    let mut felts: Array<felt252> = array![];
    push_felts(ref felts, @player);
    let mut g2 = rebuild(list.span());
    acc += doom_physics::things_in(ref g2, player.cell).len().into();
    acc + felts.len().into() + events.len().into()
}
