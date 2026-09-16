// SPDX-License-Identifier: GPL-2.0-only
//! The "without the player" side of `doom_player`'s bytecode measurement.
//!
//! It links the same crates as `../size` **and calls every function of them
//! that `doom_player` reaches** — `doom_physics`' traversals, hitscans,
//! damage and spawns, `doom_specials`' two triggers, `bam`'s tables,
//! `fsm::enter`, `ticcmd::decode`/`encode`, `geom2d::point_side_alone` — so
//! that the historical size difference removes most shared lower code.
//! Harness call sites and different lower-code linkage still affect the
//! difference; `attribute.py` reports source ownership separately.
//!
//! Every argument is derived from `op`, never a literal: with constants the
//! compiler propagates them into the callee and prunes branches, which made
//! `doom_specials::use_line` alone look like 12 000 words of *this* crate.

use doom_map::{LevelId, genesis, load};
use doom_physics::maputl::{line_hp, line_meta, line_opening};
use doom_physics::{
    MF_SPECIAL, Mobj, NO_MOBJ, SpawnZ, ThingGrid, World, aim_line_attack, damage_mobj, line_attack,
    new_grid, path_traverse, push_felts, removed_mobj, set_state, set_thing_position, spawn_mobj,
    spawn_player, world_of,
};
use doom_specials::{PlayerSector, player, player_in_special_sector, spawn_specials, use_line};
use doom_things::tables::{KIND_MISC2, KIND_POSSESSED};
use geom2d::{Point, point_side_alone};
use prng::from_index;
use ticcmd::TicCmd;

#[executable]
fn main(op: u32) -> felt252 {
    let m = load(LevelId::E1M1);
    let lm = doom_specials::load(LevelId::E1M1);
    let g0 = genesis(LevelId::E1M1);
    let w: World = world_of(@m);
    let mut acc: felt252 = op.into();

    let mut mo = spawn_player(w, g0.start, g0.angle);
    let mut g: ThingGrid = new_grid();
    set_thing_position(@w.map, ref g, ref mo, 0);
    let mut rng = from_index(1);
    let mobjs = array![BoxTrait::new(mo)].span();

    // `doom_physics`, as `doom_player` reaches it.
    let p1 = Point { x: mo.x, y: mo.y };
    let p2 = Point { x: fixed::add(mo.x, fixed::from_units(64)), y: mo.y };
    acc += path_traverse(w, mobjs, ref g, p1, p2, op != 0, op % 2).len().into();
    let aim = aim_line_attack(w, mobjs, ref g, op % 2, mo.angle, fixed::from_units(1024));
    acc += aim.slope.enc;
    match line_attack(w, mobjs, ref g, op % 2, mo.angle, fixed::from_units(2048), aim.slope) {
        doom_physics::Hit::Nothing => {},
        doom_physics::Hit::Wall((line, _, _)) => { acc += line.into(); },
        doom_physics::Hit::Thing((idx, _, _)) => { acc += idx.into(); },
    }
    let mut victim = spawn_mobj(w, KIND_POSSESSED, mo.x, mo.y, SpawnZ::OnFloor);
    let out = damage_mobj(w, mobjs, ref rng, ref victim, 1, NO_MOBJ, NO_MOBJ, 5 + op, op != 0);
    if out.died {
        acc += 1;
    }
    acc += set_state(w, ref victim, 84 + op % 4).into();
    let meta = line_meta(*w.map.l_packed.at(op % 8));
    acc += meta.special.into() + meta.front.into();
    let hp = line_hp(w.map.l_ab, w.map.l_bb, w.map.l_cb, op % 8);
    acc += point_side_alone(hp, p1).into();
    let open = line_opening(w.floor, w.ceil, op % 2, 1 + op % 2);
    acc += open.top.enc - open.bottom.enc;
    let mut thing: Mobj = removed_mobj();
    thing.kind = KIND_MISC2;
    thing.flags = MF_SPECIAL;
    let mut felts: Array<felt252> = array![];
    push_felts(ref felts, @thing);
    acc += felts.len().into();

    // `bam`, `fsm`, `ticcmd`, as `doom_player` reaches them.
    let (s, c) = bam::sin_cos(mo.angle);
    acc += s.enc + c.enc + bam::finesine(op % 8192).enc + bam::finecosine(op % 8192).enc;
    acc += bam::point_to_angle2(mo.x, mo.y, p2.x, p2.y).into();
    acc += bam::reduce(mo.angle.into() + 0x100000000).into();
    let (tics, action) = fsm::enter(w.states, 58 + op % 4);
    acc += tics.into() + action.into();
    // The panic-free twins of `fsm::enter` and `PrngTrait::next` that S7 §9
    // parked in `doom_physics::spawn`, and which `doom_player` now reaches
    // instead of the originals (S7 §8 rule 1).
    let (t2, a2) = doom_physics::spawn::state_entry(w.states, 58 + op % 4);
    acc += t2.into() + a2.into();
    let mut r2 = from_index(1 + op % 4);
    acc += doom_physics::spawn::roll(ref r2, doom_things::rndtable()).into();
    let f: i64 = (op % 8).into();
    let word = ticcmd::encode(TicCmd { forward: f, side: 3, angle_turn: 256, buttons: 3 });
    let cmd = ticcmd::decode(word);
    acc += cmd.forward.into() + cmd.buttons.into();

    // `doom_specials`, as `doom_player::tic` reaches it.
    let (specials, spawn_rng) = spawn_specials(@m, @lm, from_index(1), doom_things::rndtable());
    let _ = spawn_rng;
    let ps = PlayerSector { sector: mo.sector, on_floor: op != 1, radiation_suit: op == 2 };
    let (specials, effect, cues) = player_in_special_sector(specials, @m, @lm, ps, op);
    acc += effect.damage.into() + cues.len().into();
    let side: u8 = (op % 2).try_into().unwrap();
    let (specials, more, ok) = use_line(specials, @m, @lm, op % 64, side, player(op != 0));
    if ok {
        acc += 2;
    }
    acc + more.len().into() + specials.secrets.into() + mo.z.enc
}
