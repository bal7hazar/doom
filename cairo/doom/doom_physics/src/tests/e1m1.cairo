// SPDX-License-Identifier: GPL-2.0-only
//! Reference tests on Freedoom E1M1, against the vectors of
//! `scripts/model.py` (`vectors.cairo`), plus the property tests and the
//! scripted walk.

use blockmap::{cell_index, cell_of};
use core::poseidon::poseidon_hash_span;
use doom_map::{LevelId, load, num_things, reject_of, subsector_at, thing, things};
use doom_things::tables::{
    KIND_BARREL, KIND_CLIP, KIND_PLAYER, KIND_POSSESSED, KIND_SHOTGUN, KIND_SHOTGUY, KIND_TROOP,
    KIND_TROOPSHOT,
};
use doom_things::thing_info;
use fixed::{BIAS, Fixed};
use geom2d::Point;
use prng::from_index;
use crate::damage::damage_mobj;
use crate::grid::new_grid;
use crate::hitscan::{Hit, aim_line_attack, line_attack};
use crate::mobj::{
    MF_AMBUSH, MF_CORPSE, MF_COUNTKILL, MF_DROPOFF, MF_DROPPED, MF_JUSTHIT, MF_MISSILE,
    MF_SHOOTABLE, MOBJ_FELTS, Mobj, NO_MOBJ, has, push_felts,
};
use crate::movement::{
    Blocker, MoveEvent, XyOutcome, check_position, try_move, xy_movement, z_movement,
};
use crate::position::{locate, set_thing_position};
use crate::sight::{check_sight, check_sight_cached};
use crate::spawn::{FIREBALL, SpawnZ, explode_missile, spawn_map_thing, spawn_missile, spawn_mobj};
use crate::world::{World, world_of};
use super::vectors::{FRICTIONS, MOVES, NO_LINE, SHOTS, SIGHTS, WALK};

fn world() -> World {
    world_of(@load(LevelId::E1M1))
}

fn fx(enc: felt252) -> Fixed {
    Fixed { enc }
}

fn units(u: felt252) -> Fixed {
    fixed::from_units(u)
}

/// A thing of `kind` at `(x, y, z)`, unlinked.
fn at(w: World, kind: u32, x: Fixed, y: Fixed, z: Fixed) -> Mobj {
    spawn_mobj(w, kind, x, y, SpawnZ::At(z))
}

/// The player at E1M1's start, standing on its floor.
fn player_at_start(w: World) -> Mobj {
    let g = doom_map::genesis(LevelId::E1M1);
    spawn_mobj(w, KIND_PLAYER, g.start.x, g.start.y, SpawnZ::OnFloor)
}

fn count_crossings(events: Span<MoveEvent>) -> (u32, u32) {
    let mut n: u32 = 0;
    let mut first: u32 = NO_LINE;
    let mut k: u32 = 0;
    while k != events.len() {
        match *events.at(k) {
            MoveEvent::CrossSpecial((line, _)) => {
                if n == 0 {
                    first = line;
                }
                n += 1;
            },
            _ => {},
        }
        k += 1;
    }
    (n, first)
}

// ---------------------------------------------------------------------------
// Movement against the Python model of P_CheckPosition / P_TryMove
// ---------------------------------------------------------------------------

#[test]
fn test_moves_match_the_python_model() {
    let w = world();
    let v = MOVES.span();
    let n = v.len() / 15;
    let mut g = new_grid();
    let mut i: u32 = 0;
    let mut accepted: u32 = 0;
    while i != n {
        let b = i * 15;
        let monster = *v.at(b + 5) == 1;
        let kind = if monster {
            KIND_POSSESSED
        } else {
            KIND_PLAYER
        };
        let mo = at(w, kind, fx(*v.at(b)), fx(*v.at(b + 1)), fx(*v.at(b + 2)));
        assert(fixed::to_units(mo.radius) == *v.at(b + 3), 'radius');
        assert(fixed::to_units(mo.height) == *v.at(b + 4), 'height');
        let x = fixed::add(mo.x, fx(*v.at(b + 6)));
        let y = fixed::add(mo.y, fx(*v.at(b + 7)));
        let expected_ok = *v.at(b + 8) == 1;
        let blocker: u32 = (*v.at(b + 12)).try_into().unwrap();
        let mobjs = array![BoxTrait::new(mo)].span();
        let mut events: Array<MoveEvent> = array![];
        let c = check_position(w, mobjs, ref g, @mo, 0, x, y, ref events);
        if blocker != NO_LINE {
            assert(!c.ok, 'line blocks');
            assert(c.blocker == Blocker::Line(blocker), 'same blocking line');
        } else {
            assert(c.ok, 'lines clear');
            assert(c.floorz.enc == *v.at(b + 9), 'tmfloorz');
            assert(c.ceilingz.enc == *v.at(b + 10), 'tmceilingz');
            assert(c.dropoffz.enc == *v.at(b + 11), 'tmdropoffz');
        }
        let mut moved = mo;
        let verdict = try_move(w, mobjs, ref g, ref moved, 0, x, y, ref events);
        assert(verdict.ok == expected_ok, 'try_move verdict');
        if expected_ok {
            accepted += 1;
            assert(moved.x == x && moved.y == y, 'moved there');
            assert(moved.floorz.enc == *v.at(b + 9), 'floorz kept');
            assert(moved.ceilingz.enc == *v.at(b + 10), 'ceilingz kept');
            let (crossed, first) = count_crossings(events.span());
            let expected_crossed: u32 = (*v.at(b + 13)).try_into().unwrap();
            assert(crossed == expected_crossed, 'crossed specials');
            if expected_crossed != 0 {
                let expected_first: u32 = (*v.at(b + 14)).try_into().unwrap();
                assert(first == expected_first, 'first special');
            }
            // R2-A11: the cached cell is the cell of the new position.
            match cell_of(w.map.grid, Point { x, y }) {
                Option::Some((
                    cx, cy,
                )) => { assert(moved.cell == cell_index(w.map.grid, cx, cy), 'cell cache'); },
                Option::None => { assert(moved.cell == crate::mobj::NO_CELL, 'off-grid cell'); },
            }
            assert(
                moved.subsector == subsector_at(@load(LevelId::E1M1), Point { x, y }), 'subsector',
            );
        } else {
            assert(moved.x == mo.x && moved.y == mo.y, 'stayed');
        }
        i += 1;
    }
    assert(accepted > 100 && accepted < n, 'both outcomes exercised');
}

#[test]
fn test_friction_matches_the_python_model() {
    // A thing in the open part of the start hall: 12 tics of momentum never
    // reach a wall, and the floor is flat, so only the friction acts.
    let w = world();
    let v = FRICTIONS.span();
    let n = v.len() / 4;
    let mut i: u32 = 0;
    while i != n {
        let b = i * 4;
        let mut g = new_grid();
        let mut mo = spawn_mobj(w, KIND_POSSESSED, units(-350), units(256), SpawnZ::OnFloor);
        mo.momx = fx(*v.at(b));
        mo.momy = fx(*v.at(b + 1));
        let mobjs = array![BoxTrait::new(mo)].span();
        let mut events: Array<MoveEvent> = array![];
        let mut t: u32 = 0;
        while t != 12 {
            xy_movement(w, mobjs, ref g, ref mo, 0, false, true, ref events);
            t += 1;
        }
        assert(mo.momx.enc == *v.at(b + 2), 'momx after 12 tics');
        assert(mo.momy.enc == *v.at(b + 3), 'momy after 12 tics');
        assert(events.len() == 0, 'no wall touched');
        i += 1;
    }
}

// ---------------------------------------------------------------------------
// Sight against the exact/float models (REJECT agreement + traversal)
// ---------------------------------------------------------------------------

#[test]
fn test_sight_matches_the_python_models() {
    let w = world();
    let v = SIGHTS.span();
    let n = v.len() / 10;
    let mut i: u32 = 0;
    let mut visible: u32 = 0;
    while i != n {
        let b = i * 10;
        let t1 = at(w, KIND_PLAYER, fx(*v.at(b)), fx(*v.at(b + 1)), fx(*v.at(b + 2)));
        let t2 = at(w, KIND_PLAYER, fx(*v.at(b + 3)), fx(*v.at(b + 4)), fx(*v.at(b + 5)));
        let s1: u32 = (*v.at(b + 6)).try_into().unwrap();
        let s2: u32 = (*v.at(b + 7)).try_into().unwrap();
        assert(t1.sector == s1 && t2.sector == s2, 'sectors located');
        let rejected = reject_of(w.map.reject, w.map.reject_stride, w.map.pow2, s1, s2);
        assert(rejected == (*v.at(b + 8) == 1), 'REJECT agrees');
        let expected = *v.at(b + 9) == 1;
        assert(check_sight(w, @t1, @t2) == expected, 'sight verdict');
        if expected {
            visible += 1;
        }
        i += 1;
    }
    assert(visible > 50, 'enough visible pairs');
}

#[test]
fn test_sight_cache_holds_for_ttl_tics_and_the_same_sector() {
    let w = world();
    let v = SIGHTS.span();
    // The first visible pair.
    let mut i: u32 = 0;
    while *v.at(i * 10 + 9) != 1 {
        i += 1;
    }
    let b = i * 10;
    let mut looker = at(w, KIND_POSSESSED, fx(*v.at(b)), fx(*v.at(b + 1)), fx(*v.at(b + 2)));
    let target = at(w, KIND_PLAYER, fx(*v.at(b + 3)), fx(*v.at(b + 4)), fx(*v.at(b + 5)));
    assert(check_sight_cached(w, ref looker, @target, 10, 4), 'fresh verdict');
    assert(looker.sight_ok && looker.sight_expires == 14, 'cached');
    assert(looker.sight_sector == target.sector, 'cache keyed by sector');
    // Within the ttl the cache answers, even for a stale flag.
    looker.sight_ok = false;
    assert(!check_sight_cached(w, ref looker, @target, 13, 4), 'cache hit');
    // Past it, the line is traced again.
    assert(check_sight_cached(w, ref looker, @target, 14, 4), 'cache expired');
    assert(looker.sight_expires == 18, 'renewed');
    // A target in another sector invalidates it.
    let mut elsewhere = target;
    elsewhere.sector += 1;
    looker.sight_ok = false;
    looker.sight_sector = target.sector;
    looker.sight_expires = 100;
    let _ = check_sight_cached(w, ref looker, @elsewhere, 15, 4);
    assert(looker.sight_sector == elsewhere.sector, 'rekeyed');
}

// ---------------------------------------------------------------------------
// Hitscan against the float ray cast
// ---------------------------------------------------------------------------

#[test]
fn test_shots_match_the_python_ray_cast() {
    let w = world();
    let v = SHOTS.span();
    let n = v.len() / 9;
    let mut g = new_grid();
    let tolerance: felt252 = 2 * 65536;
    let mut i: u32 = 0;
    while i != n {
        let b = i * 9;
        let shooter = at(w, KIND_PLAYER, fx(*v.at(b)), fx(*v.at(b + 1)), fx(*v.at(b + 2)));
        let angle: u32 = (*v.at(b + 3)).try_into().unwrap();
        let slope = fx(*v.at(b + 4));
        let range = units(*v.at(b + 5));
        let expected_line: u32 = (*v.at(b + 6)).try_into().unwrap();
        let mobjs = array![BoxTrait::new(shooter)].span();
        match line_attack(w, mobjs, ref g, 0, angle, range, slope) {
            Hit::Wall((
                line, p, _z,
            )) => {
                assert(line == expected_line, 'same line hit');
                assert(fixed::felt_ge(p.x.enc + tolerance, *v.at(b + 7)), 'puff x low');
                assert(fixed::felt_ge(*v.at(b + 7) + tolerance, p.x.enc), 'puff x high');
                assert(fixed::felt_ge(p.y.enc + tolerance, *v.at(b + 8)), 'puff y low');
                assert(fixed::felt_ge(*v.at(b + 8) + tolerance, p.y.enc), 'puff y high');
            },
            _ => { assert(false, 'a wall is hit'); },
        }
        i += 1;
    }
}

// ---------------------------------------------------------------------------
// Things: blocking, pickups, missiles (through the thing grid)
// ---------------------------------------------------------------------------

#[test]
fn test_things_block_touch_and_get_hit() {
    let w = world();
    let mut g = new_grid();
    let mut player = player_at_start(w);
    set_thing_position(@w.map, ref g, ref player, 0);
    // A zombieman 30 units east: radii 16 + 20 = 36 > 30 - 10.
    let mut zombie = at(w, KIND_POSSESSED, units(-386), units(256), fixed::ZERO);
    set_thing_position(@w.map, ref g, ref zombie, 1);
    let mut events: Array<MoveEvent> = array![];
    let mobjs = array![BoxTrait::new(player), BoxTrait::new(zombie)].span();
    let mut p = player;
    let v = try_move(w, mobjs, ref g, ref p, 0, units(-406), p.y, ref events);
    assert(!v.ok && v.blocker == Blocker::Thing(1), 'solid thing blocks');
    // Moving away is fine.
    let v = try_move(w, mobjs, ref g, ref p, 0, units(-426), p.y, ref events);
    assert(v.ok, 'moving away');
    assert(events.len() == 0, 'no event');

    // An ammo clip in the way: touched, not blocking.
    let mut clip = at(w, KIND_CLIP, units(-386), units(256), fixed::ZERO);
    set_thing_position(@w.map, ref g, ref clip, 2);
    let mobjs = array![BoxTrait::new(player), BoxTrait::new(zombie), BoxTrait::new(clip)].span();
    let mut p = player;
    let mut events: Array<MoveEvent> = array![];
    let v = try_move(w, mobjs, ref g, ref p, 0, units(-436), p.y, ref events);
    assert(v.ok, 'clip does not block');
    assert(events.len() == 0, 'clip not reached');
    // A monster cannot pick up (and, 38 units away, is clear of the player).
    let mut z = zombie;
    let v = try_move(w, mobjs, ref g, ref z, 1, units(-378), z.y, ref events);
    assert(v.ok && events.len() == 0, 'monsters ignore items');
    // The player touches it (MF_PICKUP) when the boxes overlap.
    let mut lone = player;
    let mut g2 = new_grid();
    set_thing_position(@w.map, ref g2, ref lone, 0);
    let mut clip2 = clip;
    set_thing_position(@w.map, ref g2, ref clip2, 1);
    let mobjs2 = array![BoxTrait::new(lone), BoxTrait::new(clip2)].span();
    let v = try_move(w, mobjs2, ref g2, ref lone, 0, units(-400), lone.y, ref events);
    assert(v.ok, 'walks over the clip');
    assert(events.len() == 1, 'one touch');
    assert(*events.at(0) == MoveEvent::Touch(1), 'touch event');

    // A fireball flying into the zombieman hits it; over its head, not.
    let mut g3 = new_grid();
    let mut z3 = zombie;
    set_thing_position(@w.map, ref g3, ref z3, 0);
    let mut ball = at(w, KIND_TROOPSHOT, units(-356), units(256), units(20));
    set_thing_position(@w.map, ref g3, ref ball, 1);
    let mobjs3 = array![BoxTrait::new(z3), BoxTrait::new(ball)].span();
    let mut events: Array<MoveEvent> = array![];
    let v = try_move(w, mobjs3, ref g3, ref ball, 1, units(-376), ball.y, ref events);
    assert(!v.ok && v.blocker == Blocker::Thing(0), 'missile stops on the thing');
    assert(*events.at(0) == MoveEvent::MissileHit(0), 'hit event');
    let mut high = ball;
    high.z = units(60); // over its head (56), under the ceiling
    let mut events: Array<MoveEvent> = array![];
    let v = try_move(w, mobjs3, ref g3, ref high, 1, units(-376), high.y, ref events);
    assert(v.ok && events.len() == 0, 'flies over');
    // A monster's missile does not hurt its own kind.
    let mut g4 = new_grid();
    let mut z4 = zombie;
    set_thing_position(@w.map, ref g4, ref z4, 0);
    let mut other = at(w, KIND_POSSESSED, units(-300), units(256), fixed::ZERO);
    set_thing_position(@w.map, ref g4, ref other, 2);
    let mut kin = ball;
    kin.target = 2; // shot by the other zombieman
    set_thing_position(@w.map, ref g4, ref kin, 1);
    let mobjs4 = array![BoxTrait::new(z4), BoxTrait::new(kin), BoxTrait::new(other)].span();
    let mut events: Array<MoveEvent> = array![];
    let v = try_move(w, mobjs4, ref g4, ref kin, 1, units(-376), kin.y, ref events);
    assert(!v.ok && v.blocker == Blocker::Thing(0), 'explodes on kin');
    assert(events.len() == 0, 'but does no damage');
}

#[test]
fn test_hitscan_hits_a_thing_and_aims_at_it() {
    let w = world();
    let mut g = new_grid();
    let mut player = player_at_start(w);
    set_thing_position(@w.map, ref g, ref player, 0);
    let mut zombie = at(w, KIND_POSSESSED, units(-316), units(256), fixed::ZERO);
    set_thing_position(@w.map, ref g, ref zombie, 1);
    let mobjs = array![BoxTrait::new(player), BoxTrait::new(zombie)].span();
    let aim = aim_line_attack(w, mobjs, ref g, 0, player.angle, crate::hitscan::AIMRANGE);
    assert(aim.target == 1, 'auto-aim finds it');
    match line_attack(w, mobjs, ref g, 0, player.angle, crate::hitscan::MISSILERANGE, aim.slope) {
        Hit::Thing((
            idx, p, _,
        )) => {
            assert(idx == 1, 'the zombieman is hit');
            // Blood 10 units short of the crossing with its box diagonal,
            // which the level shot crosses at the thing's centre (x = -316).
            assert(fixed::lt(p.x, units(-325)) && fixed::gt(p.x, units(-327)), 'blood in front');
        },
        _ => { assert(false, 'thing hit'); },
    }
    // Aiming with nothing in the cone: slope 0, no target.
    let empty = array![BoxTrait::new(player)].span();
    let mut g2 = new_grid();
    let aim = aim_line_attack(w, empty, ref g2, 0, player.angle, crate::hitscan::AIMRANGE);
    assert(aim.target == NO_MOBJ && aim.slope == fixed::ZERO, 'no target');
}

// ---------------------------------------------------------------------------
// Damage, pain, death and drops (info.c semantics)
// ---------------------------------------------------------------------------

#[test]
fn test_damage_pain_retaliation_and_thrust() {
    let w = world();
    let player = player_at_start(w);
    let mut zombie = at(w, KIND_POSSESSED, units(-316), units(256), fixed::ZERO);
    let mobjs = array![BoxTrait::new(player), BoxTrait::new(zombie)].span();
    let mut rng = from_index(1); // P_Random's first byte is 8 < painchance 200
    let info = thing_info(KIND_POSSESSED);
    let out = damage_mobj(w, mobjs, ref rng, ref zombie, 1, 0, 0, 5, true);
    assert(!out.died && out.pain && out.retaliated, 'pain and retaliation');
    assert(zombie.health == 15, 'health');
    assert(zombie.state == info.painstate, 'pain state');
    assert(has(zombie.flags, MF_JUSTHIT), 'just hit');
    assert(zombie.target == 0 && zombie.threshold == 100, 'chases the player');
    assert(zombie.reaction_time == 0, 'awake');
    assert(fixed::gt(zombie.momx, fixed::ZERO), 'thrust away from the player');
    assert(rng.index == 2, 'one draw for the pain chance');
    // Already chasing: no re-targeting while the threshold holds.
    let mut rng2 = from_index(200);
    let out2 = damage_mobj(w, mobjs, ref rng2, ref zombie, 1, 0, 0, 1, false);
    assert(!out2.retaliated, 'threshold holds');
    assert(zombie.health == 14, 'health again');
}

#[test]
fn test_death_gib_and_drops() {
    let w = world();
    let player = player_at_start(w);
    let mut rng = from_index(1);
    let info = thing_info(KIND_POSSESSED);

    let mut zombie = at(w, KIND_POSSESSED, units(-316), units(256), fixed::ZERO);
    let mobjs = array![BoxTrait::new(player), BoxTrait::new(zombie)].span();
    let out = damage_mobj(w, mobjs, ref rng, ref zombie, 1, 0, 0, 20, false);
    assert(out.died && out.counts_kill, 'dies');
    assert(zombie.health == 0, 'health zero');
    assert(zombie.state == info.deathstate, 'death state');
    assert(has(zombie.flags, MF_CORPSE + MF_DROPOFF), 'corpse');
    assert(!has(zombie.flags, MF_SHOOTABLE), 'not shootable');
    assert(fixed::to_units(zombie.height) == 14, 'height quartered');
    assert(zombie.tics >= 1, 'tics stay positive');
    match out.drop {
        Option::Some(d) => {
            assert(d.kind == KIND_CLIP && has(d.flags, MF_DROPPED), 'drops a clip');
            assert(d.x == zombie.x && d.y == zombie.y, 'where it died');
            assert(d.z == d.floorz, 'on the floor');
        },
        Option::None => { assert(false, 'zombieman drops'); },
    }

    // Enough damage gibs.
    let mut gibbed = at(w, KIND_POSSESSED, units(-316), units(256), fixed::ZERO);
    let out = damage_mobj(w, mobjs, ref rng, ref gibbed, 1, 0, 0, 60, false);
    assert(out.died && gibbed.state == info.xdeathstate, 'gibbed');

    // A shotgun guy drops a shotgun, an imp nothing, a barrel nothing.
    let mut sarge = at(w, KIND_SHOTGUY, units(-316), units(256), fixed::ZERO);
    let out = damage_mobj(w, mobjs, ref rng, ref sarge, 1, 0, 0, 100, false);
    assert(out.died && out.drop.unwrap().kind == KIND_SHOTGUN, 'drops a shotgun');
    let mut imp = at(w, KIND_TROOP, units(-316), units(256), fixed::ZERO);
    let out = damage_mobj(w, mobjs, ref rng, ref imp, 1, 0, 0, 100, false);
    assert(out.died && out.drop.is_none(), 'imp drops nothing');
    let mut barrel = at(w, KIND_BARREL, units(-316), units(256), fixed::ZERO);
    let out = damage_mobj(w, mobjs, ref rng, ref barrel, 1, NO_MOBJ, NO_MOBJ, 5, false);
    assert(!out.died && !out.pain, 'barrel has no pain chance');
    let out = damage_mobj(w, mobjs, ref rng, ref barrel, 1, NO_MOBJ, NO_MOBJ, 50, false);
    assert(out.died && !out.counts_kill && out.drop.is_none(), 'barrel dies quietly');
    assert(barrel.state == thing_info(KIND_BARREL).deathstate, 'barrel death state');

    // A corpse takes no more damage.
    let out = damage_mobj(w, mobjs, ref rng, ref zombie, 1, 0, 0, 5, false);
    assert(!out.died && !out.pain, 'already dead');
}

#[test]
fn test_missiles_spawn_and_explode() {
    let w = world();
    let mut g = new_grid();
    let mut player = player_at_start(w);
    set_thing_position(@w.map, ref g, ref player, 0);
    let mut imp = at(w, KIND_TROOP, units(-216), units(256), fixed::ZERO);
    set_thing_position(@w.map, ref g, ref imp, 1);
    let mobjs = array![BoxTrait::new(player), BoxTrait::new(imp)].span();
    let mut rng = from_index(1);
    let mut events: Array<MoveEvent> = array![];
    let (ball, exploded) = spawn_missile(
        w, mobjs, ref g, ref rng, @imp, 1, @player, FIREBALL, 2, ref events,
    );
    assert(!exploded, 'open hall');
    assert(ball.kind == KIND_TROOPSHOT && ball.target == 1, 'fireball from the imp');
    assert(has(ball.flags, MF_MISSILE), 'is a missile');
    assert(fixed::lt(ball.momx, units(-9)) && fixed::gt(ball.momx, units(-11)), 'speed 10 west');
    assert(ball.angle > bam::ANG90 && ball.angle < bam::ANG270, 'aimed west');
    assert(fixed::ge(ball.z, units(32)) && fixed::le(ball.z, units(40)), 'launched at 32');
    assert(ball.cell != crate::mobj::NO_CELL, 'linked');
    let mut b = ball;
    let action = explode_missile(w, ref rng, ref b);
    assert(!has(b.flags, MF_MISSILE), 'no longer a missile');
    assert(b.state == thing_info(KIND_TROOPSHOT).deathstate, 'explosion state');
    assert(b.momx == fixed::ZERO && b.momz == fixed::ZERO, 'stopped');
    assert(action == fsm::NO_ACTION, 'silent first frame');
}

// ---------------------------------------------------------------------------
// Spawning the map's things
// ---------------------------------------------------------------------------

#[test]
fn test_map_things_spawn_on_their_floor() {
    let m = load(LevelId::E1M1);
    let w = world_of(@m);
    let n = num_things(@m);
    let mut i: u32 = 0;
    let mut spawned: u32 = 0;
    let mut monsters: u32 = 0;
    let mut ambush: u32 = 0;
    while i != n {
        let t = thing(@m, i);
        match spawn_map_thing(w, t) {
            Option::Some(mo) => {
                spawned += 1;
                if has(mo.flags, MF_COUNTKILL) {
                    monsters += 1;
                }
                if has(mo.flags, MF_AMBUSH) {
                    ambush += 1;
                }
                assert(mo.subsector == subsector_at(@m, t.position), 'located');
                if has(mo.flags, crate::mobj::MF_SPAWNCEILING) {
                    assert(mo.z == fixed::sub(mo.ceilingz, mo.height), 'hangs');
                } else {
                    assert(mo.z == mo.floorz, 'stands');
                }
                assert(mo.angle == t.angle, 'faces the map angle');
                assert(mo.health > 0 || !has(mo.flags, MF_SHOOTABLE), 'alive');
            },
            Option::None => {},
        }
        i += 1;
    }
    assert(spawned == n - 12, 'everything but the 12 starts');
    assert(monsters == 29, '29 monsters at skill 2');
    assert(ambush > 0, 'some ambushers');
    assert(things(@m).len() == n, 'span');
}

// ---------------------------------------------------------------------------
// Properties
// ---------------------------------------------------------------------------

#[test]
fn test_z_stays_between_floor_and_ceiling_while_falling() {
    let w = world();
    let mut mo = player_at_start(w);
    mo.z = fixed::sub(mo.ceilingz, mo.height);
    let mut t: u32 = 0;
    let mut landed = false;
    while t != 60 {
        let out = z_movement(ref mo, Option::None);
        assert(fixed::ge(mo.z, mo.floorz), 'above the floor');
        assert(fixed::le(fixed::add(mo.z, mo.height), mo.ceilingz), 'below the ceiling');
        if out.landed {
            landed = true;
            assert(fixed::is_neg(out.hard_landing), 'a 72-unit fall hurts');
        }
        t += 1;
    }
    assert(landed && mo.z == mo.floorz && mo.momz == fixed::ZERO, 'at rest on the floor');
}

#[test]
fn test_momentum_decays_to_zero() {
    let w = world();
    let mut g = new_grid();
    let mut mo = spawn_mobj(w, KIND_POSSESSED, units(-300), units(256), SpawnZ::OnFloor);
    mo.momx = units(5);
    mo.momy = units(3);
    let mobjs = array![BoxTrait::new(mo)].span();
    let mut events: Array<MoveEvent> = array![];
    let mut t: u32 = 0;
    let mut stopped_at: u32 = 0;
    while t != 100 {
        let out = xy_movement(w, mobjs, ref g, ref mo, 0, false, true, ref events);
        if out == XyOutcome::Stopped && stopped_at == 0 {
            stopped_at = t;
        }
        t += 1;
    }
    assert(stopped_at > 10 && stopped_at < 60, 'stops after some tics');
    assert(mo.momx == fixed::ZERO && mo.momy == fixed::ZERO, 'momentum gone');
}

#[test]
fn test_serialization_schema() {
    let w = world();
    let mut mo = player_at_start(w);
    mo.health = -5;
    mo.sight_ok = true;
    let mut out: Array<felt252> = array![];
    push_felts(ref out, @mo);
    assert(out.len() == MOBJ_FELTS, '27 felts');
    let limit: u128 = 0x1000000000000000000; // 2^72
    let mut k: u32 = 0;
    while k != out.len() {
        let v: u128 = (*out.at(k)).try_into().unwrap();
        assert(v < limit, 'below 2^72');
        k += 1;
    }
    assert(*out.at(11) == 0x80000000 - 5, 'biased health');
    assert(*out.at(26) == 1, 'sight flag');
    assert(*out.at(1) == mo.x.enc, 'x is enc');
}

#[test]
fn test_locate_agrees_with_doom_map() {
    let m = load(LevelId::E1M1);
    let w = world_of(@m);
    let v = MOVES.span();
    let mut i: u32 = 0;
    while i != 40 {
        let p = Point { x: fx(*v.at(i * 15)), y: fx(*v.at(i * 15 + 1)) };
        let loc = locate(@w.map, p);
        assert(loc.subsector == subsector_at(@m, p), 'subsector');
        let (cx, cy) = cell_of(w.map.grid, p).unwrap();
        assert(loc.cell == cell_index(w.map.grid, cx, cy), 'cell');
        assert(loc.sector == doom_map::subsector_sector(@m, loc.subsector), 'sector');
        i += 1;
    }
}

// ---------------------------------------------------------------------------
// The scripted 350-tic walk
// ---------------------------------------------------------------------------

/// `(tics, angle, forwardmove)`: the same script as `model.py`'s
/// `WALK_SCRIPT`.
fn walk_script() -> Span<(u32, u32, felt252)> {
    array![
        (40, 0, 25), (30, 0, 0), (10, bam::ANG90, 25), (25, bam::ANG90, 0), (10, bam::ANG270, 25),
        (25, bam::ANG270, 0), (40, bam::ANG180, 25), (30, bam::ANG180, 0), (20, 0, 25), (120, 0, 0),
    ]
        .span()
}

/// Poseidon over every serialized player state of the walk, pinned. A
/// change here means the movement semantics changed; regenerate it on
/// purpose (PLAN.md §3.1 rule 5), never silently.
const WALK_CHECKSUM: felt252 =
    1089200422975845693249522638751978692740113386640880924543921699687562627070;

#[test]
fn test_scripted_walk_matches_the_model_and_its_checksum() {
    let w = world();
    let mut g = new_grid();
    let mut player = player_at_start(w);
    set_thing_position(@w.map, ref g, ref player, 0);
    let mobjs = array![BoxTrait::new(player)].span();
    let script = walk_script();
    let checkpoints = WALK.span();
    let mut hashed: Array<felt252> = array![];
    let mut tic: u32 = 0;
    let mut seg: u32 = 0;
    while seg != script.len() {
        let (tics, angle, forward) = *script.at(seg);
        seg += 1;
        let mut t: u32 = 0;
        while t != tics {
            t += 1;
            // P_MovePlayer: turn, then P_Thrust(angle, forwardmove * 2048).
            player.angle = angle;
            if forward != 0 {
                let (s, c) = bam::sin_cos(angle);
                let move = Fixed { enc: BIAS + forward * 2048 };
                player.momx = fixed::add(player.momx, fixed::mul(move, c));
                player.momy = fixed::add(player.momy, fixed::mul(move, s));
            }
            let mut events: Array<MoveEvent> = array![];
            xy_movement(w, mobjs, ref g, ref player, 0, forward != 0, true, ref events);
            z_movement(ref player, Option::None);
            push_felts(ref hashed, @player);
            tic += 1;
            if tic % 50 == 0 {
                let k = (tic / 50 - 1) * 4;
                assert(player.x.enc == *checkpoints.at(k), 'x at checkpoint');
                assert(player.y.enc == *checkpoints.at(k + 1), 'y at checkpoint');
                assert(player.momx.enc == *checkpoints.at(k + 2), 'momx at checkpoint');
                assert(player.momy.enc == *checkpoints.at(k + 3), 'momy at checkpoint');
            }
        }
    }
    assert(tic == 350, '350 tics');
    assert(player.momx == fixed::ZERO && player.momy == fixed::ZERO, 'at rest');
    // The walk ends back in the start room, west of its doorway.
    assert(
        fixed::gt(player.x, units(-300)) && fixed::lt(player.x, units(-200)), 'back in the room',
    );
    let checksum = poseidon_hash_span(hashed.span());
    if WALK_CHECKSUM != 0 {
        assert(checksum == WALK_CHECKSUM, 'walk checksum');
    }
}
