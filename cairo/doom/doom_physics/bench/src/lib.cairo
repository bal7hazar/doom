// SPDX-License-Identifier: GPL-2.0-only
//! Step-cost benchmark for `doom_physics` on Freedoom E1M1.
//!
//! Differential measurement (S1 §3.1) with **varying operands** and a
//! per-operation baseline (`base` in `budgets.json`): op 0 is the bare loop,
//! op 1 alternates a target 4 units east or west of a linked player (the
//! baseline of the movement ops), op 2 builds a fresh player record (the
//! baseline of `locate`/`spawn`). One player is linked once, before the
//! loop, and every iteration moves it or shoots from it with an operand that
//! changes with `i`, so nothing is hoisted and nothing accumulates in the
//! thing grid. Every scene is in E1M1's start hall (the open area east of
//! the player start, floor 0, ceiling 128), except the REJECT and far-sight
//! cases.

use bam::{ANG90, Angle};
use doom_map::{LevelId, genesis, load};
use doom_physics::{
    Mobj, MoveEvent, SpawnZ, ThingGrid, World, aim_line_attack, check_sight, damage_mobj,
    line_attack, locate, new_grid, path_traverse, replace, set_thing_position, slide_move,
    spawn_mobj, try_move, world_of, xy_movement, z_movement,
};
use doom_things::tables::{KIND_PLAYER, KIND_POSSESSED};
use fixed::Fixed;
use geom2d::Point;
use prng::from_index;

fn units(u: felt252) -> Fixed {
    fixed::from_units(u)
}

/// A fresh player record in the start hall, varying with `i`.
fn player_at(w: World, i: u32) -> Mobj {
    let dx: felt252 = (i % 8).into();
    spawn_mobj(w, KIND_PLAYER, units(-300 + dx), units(256), SpawnZ::OnFloor)
}

/// +4 or -4 units, alternating.
fn wiggle(i: u32) -> Fixed {
    if i % 2 == 0 {
        units(4)
    } else {
        units(-4)
    }
}

#[executable]
fn main(op: u32, n: u32) -> felt252 {
    let m = load(LevelId::E1M1);
    let w = world_of(@m);
    let start = genesis(LevelId::E1M1);
    let mut acc: felt252 = 0;
    let mut i: u32 = 0;
    let mut g: ThingGrid = new_grid();
    let mut events: Array<MoveEvent> = array![];
    let mut rng = from_index(1);
    // The one linked player every movement op works on (x = -300, cell
    // [-328, -200]); a zombieman two cells east, out of every search box
    // except the ones that want it, for the damage and thing ops.
    let mut mo = spawn_mobj(w, KIND_PLAYER, units(-300), units(256), SpawnZ::OnFloor);
    set_thing_position(@w.map, ref g, ref mo, 0);
    let mut other = spawn_mobj(w, KIND_POSSESSED, units(-100), units(256), SpawnZ::OnFloor);
    set_thing_position(@w.map, ref g, ref other, 1);
    let both = array![mo, other].span();

    if op == 0 { // bare loop
        while i != n {
            i += 1;
        }
    } else if op == 1 {
        // baseline: the alternating target
        while i != n {
            let x = fixed::add(mo.x, wiggle(i));
            acc += x.enc;
            i += 1;
        }
    } else if op == 2 {
        // baseline: a fresh record
        while i != n {
            let p = player_at(w, i);
            acc += p.x.enc;
            i += 1;
        }
    } else if op == 3 {
        // try_move, common case: 1 cell, no things, 4 units back and forth
        while i != n {
            let x = fixed::add(mo.x, wiggle(i));
            if try_move(w, both, ref g, ref mo, 0, x, mo.y, ref events).ok {
                acc += 1;
            }
            i += 1;
        }
    } else if op == 4 {
        // try_move, a monster whose box straddles the cell boundary at -200
        let mut z = spawn_mobj(w, KIND_POSSESSED, units(-204), units(256), SpawnZ::OnFloor);
        set_thing_position(@w.map, ref g, ref z, 2);
        let three = array![mo, other, z].span();
        while i != n {
            let x = fixed::add(z.x, wiggle(i));
            if try_move(w, three, ref g, ref z, 2, x, z.y, ref events).ok {
                acc += 1;
            }
            i += 1;
        }
    } else if op == 5 {
        // try_move with a zombieman 50 units east, in the search box
        // (checked, not hit)
        let mut near = spawn_mobj(w, KIND_POSSESSED, units(-250), units(256), SpawnZ::OnFloor);
        set_thing_position(@w.map, ref g, ref near, 2);
        let three = array![mo, other, near].span();
        while i != n {
            let x = fixed::add(mo.x, wiggle(i));
            if try_move(w, three, ref g, ref mo, 0, x, mo.y, ref events).ok {
                acc += 1;
            }
            i += 1;
        }
    } else if op == 6 {
        // check_sight, REJECT answers (start hall vs the exit room)
        let far = spawn_mobj(w, KIND_POSSESSED, units(-400), units(1296), SpawnZ::OnFloor);
        while i != n {
            let mut a = mo;
            a.x = fixed::add(a.x, wiggle(i));
            if check_sight(w, @a, @far) {
                acc += 1;
            }
            i += 1;
        }
    } else if op == 7 {
        // check_sight, traversal, visible, 300 units across the hall
        let b = spawn_mobj(w, KIND_POSSESSED, units(0), units(256), SpawnZ::OnFloor);
        while i != n {
            let mut a = mo;
            a.x = fixed::add(a.x, wiggle(i));
            if check_sight(w, @a, @b) {
                acc += 1;
            }
            i += 1;
        }
    } else if op == 8 {
        // check_sight, traversal, 900 units down the hall past the doorway
        let b = spawn_mobj(w, KIND_POSSESSED, units(600), units(256), SpawnZ::OnFloor);
        while i != n {
            let mut a = mo;
            a.x = fixed::add(a.x, wiggle(i));
            if check_sight(w, @a, @b) {
                acc += 1;
            }
            i += 1;
        }
    } else if op == 9 {
        // line_attack north, 188 units to the wall (a typical room shot)
        while i != n {
            let angle: Angle = ANG90 + i % 2;
            let hit = line_attack(w, both, ref g, 0, angle, units(2048), fixed::ZERO);
            acc += hit_felt(hit);
            i += 1;
        }
    } else if op == 10 {
        // line_attack east, 1 700 units down the hall (the long case)
        while i != n {
            let angle: Angle = i % 2;
            let hit = line_attack(w, both, ref g, 0, angle, units(2048), fixed::ZERO);
            acc += hit_felt(hit);
            i += 1;
        }
    } else if op == 11 {
        // aim_line_attack north, 1024 units (the wall stops it at 188)
        while i != n {
            let angle: Angle = ANG90 + i % 2;
            let aim = aim_line_attack(w, both, ref g, 0, angle, units(1024));
            acc += aim.slope.enc + aim.target.into();
            i += 1;
        }
    } else if op == 12 {
        // xy_movement + z_movement, a walking player (momentum 6 units)
        while i != n {
            mo.momx = if i % 2 == 0 {
                units(6)
            } else {
                units(-6)
            };
            xy_movement(w, both, ref g, ref mo, 0, true, true, ref events);
            z_movement(ref mo, Option::None);
            acc += mo.x.enc;
            i += 1;
        }
    } else if op == 13 {
        // set_thing_position, same cell (locate + unlink + link)
        while i != n {
            mo.x = fixed::add(mo.x, wiggle(i));
            set_thing_position(@w.map, ref g, ref mo, 0);
            acc += mo.cell.into();
            i += 1;
        }
    } else if op == 14 {
        // locate both
        while i != n {
            let x = fixed::add(mo.x, wiggle(i));
            let loc = locate(@w.map, Point { x, y: mo.y });
            acc += loc.subsector.into();
            i += 1;
        }
    } else if op == 15 {
        // damage_mobj, pain, no death, with thrust
        while i != n {
            let mut target = other;
            target.x = fixed::add(target.x, wiggle(i));
            let out = damage_mobj(w, both, ref rng, ref target, 1, 0, 0, 3, true);
            if out.pain {
                acc += 1;
            }
            acc += target.momx.enc;
            i += 1;
        }
    } else if op == 16 {
        // spawn_mobj (locate + info + state) -- the baseline op 2 itself
        while i != n {
            let p = player_at(w, i);
            acc += p.tics.into() + p.x.enc;
            i += 1;
        }
    } else if op == 17 {
        // replace on a 210-slot list (per call)
        let mut list: Array<Mobj> = array![];
        let mut k: u32 = 0;
        while k != 210 {
            list.append(mo);
            k += 1;
        }
        while i != n {
            let mut p = mo;
            p.x = fixed::add(p.x, wiggle(i));
            replace(ref list, i % 210, p);
            i += 1;
        }
        acc += (*list.at(0)).x.enc;
    } else if op == 18 {
        // slide_move against the hall's north wall (y = 444)
        while i != n {
            mo.y = units(420);
            mo.momx = wiggle(i);
            mo.momy = units(12);
            slide_move(w, both, ref g, ref mo, 0, ref events);
            acc += mo.x.enc + mo.y.enc;
            i += 1;
        }
    } else if op == 19 {
        // path_traverse, 188 units north, lines and things
        while i != n {
            let from = Point { x: fixed::add(mo.x, wiggle(i)), y: mo.y };
            let to = Point { x: from.x, y: units(444) };
            let list = path_traverse(w, both, ref g, from, to, true, 0);
            acc += list.len().into();
            i += 1;
        }
    } else if op == 99 {
        // Reference the start so the level is not dead-code-eliminated.
        acc += start.start.x.enc + start.angle.into();
    }
    acc + i.into() + events.len().into() + mo.x.enc
}

fn hit_felt(hit: doom_physics::Hit) -> felt252 {
    match hit {
        doom_physics::Hit::Nothing => 0,
        doom_physics::Hit::Wall((line, p, _)) => line.into() + p.x.enc,
        doom_physics::Hit::Thing((idx, p, _)) => idx.into() + p.y.enc,
    }
}
