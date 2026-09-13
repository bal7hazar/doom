// SPDX-License-Identifier: GPL-2.0-only
//! Expected health and armor use p_inter.c's integer rules per impact.
//! The fixed random stream isolates attack/pain/death order independently
//! of the implementation's computed result; no replay pin is regenerated.
use doom_map::LevelId;
use doom_monsters::{monsters_ticker_with_defense, silence};
use doom_physics::{
    MF_CORPSE, MF_JUSTHIT, MF_SHOOTABLE, MF_SOLID, Mobj, NO_MOBJ, PlayerDefense, SpawnZ, World,
    damage_mobj_with_defense, has, new_grid, set_thing_position, spawn_mobj,
};
use doom_things::tables::{
    A_POSATTACK, A_SARGATTACK, KIND_PLAYER, KIND_POSSESSED, KIND_SERGEANT, KIND_TROOPSHOT,
    MI_DEATHSTATE, MI_PAINSTATE,
};
use prng::from_index;
use crate::genesis;
use crate::level::ctx_of;

fn defense(points: u32, kind: u32) -> PlayerDefense {
    PlayerDefense {
        mo: 0, armor_points: points, armor_type: kind, damagecount: 0, attacker: NO_MOBJ,
    }
}
fn setup(health: i32) -> (World, Mobj) {
    let g = genesis(LevelId::E1M1);
    (ctx_of(g.level, g.floor, g.ceil).w, Mobj { health, ..*g.mobjs.at(0) })
}

#[test]
fn two_small_hits_round_armor_separately() {
    let (w, mut mo) = setup(100);
    let list = array![mo, mo, mo].span();
    let mut d = BoxTrait::new(defense(100, 1));
    let mut rng = from_index(1);
    let a = damage_mobj_with_defense(w, list, ref rng, ref mo, 0, NO_MOBJ, 1, 2, false, ref d);
    let b = damage_mobj_with_defense(w, list, ref rng, ref mo, 0, NO_MOBJ, 2, 2, false, ref d);
    // floor(2/3) + floor(2/3) = 0; floor(4/3) would incorrectly save 1.
    assert(mo.health == 96, 'four net, not three');
    assert(d.armor_points == 100 && d.armor_type == 1, 'no armor spent');
    assert(d.damagecount == 4 && d.attacker == 2, 'last actual impact');
    assert(!a.died && !b.died && a.pain && b.pain, 'two surviving reactions');
    assert(rng.index == 3, 'two pain draws: 8,109');
}

#[test]
fn armor_is_exhausted_between_impacts() {
    let (w, mut mo) = setup(100);
    let list = array![mo, mo].span();
    let mut d = BoxTrait::new(defense(3, 1));
    let mut rng = from_index(1);
    let _ = damage_mobj_with_defense(w, list, ref rng, ref mo, 0, NO_MOBJ, 1, 9, false, ref d);
    assert(mo.health == 94 && d.armor_type == 0 && d.armor_points == 0, 'first uses last armor');
    let _ = damage_mobj_with_defense(w, list, ref rng, ref mo, 0, NO_MOBJ, 1, 9, false, ref d);
    assert(mo.health == 85 && d.damagecount == 15, 'second wholly unarmored');
    assert(rng.index == 3, 'two pain draws');
}

#[test]
fn raw_lethal_hit_survives_without_death_side_effects() {
    let (w, mut mo) = setup(10);
    let before = mo;
    let list = array![mo, mo, mo].span();
    let mut d = BoxTrait::new(defense(100, 2));
    let mut rng = from_index(1);
    let first = damage_mobj_with_defense(w, list, ref rng, ref mo, 0, NO_MOBJ, 1, 12, false, ref d);
    assert(!first.died && first.pain && first.drop.is_none(), 'pain, not death or drop');
    assert(mo.health == 4 && d.armor_points == 94, 'twelve raw, six net');
    assert(mo.height == before.height, 'not quartered');
    assert(mo.flags == (before.flags | MF_JUSTHIT), 'only live pain flag added');
    assert(mo.tics == *w.states.tics.at(mo.state), 'exact pain duration');
    assert(
        !has(mo.flags, MF_CORPSE) && (has(mo.flags, MF_SHOOTABLE) && has(mo.flags, MF_SOLID)),
        'live flags',
    );
    assert(mo.state == *MI_PAINSTATE.span().at(KIND_PLAYER), 'pain state');
    assert(rng.index == 2, 'only first pain draw');
    let next = damage_mobj_with_defense(w, list, ref rng, ref mo, 0, NO_MOBJ, 2, 3, false, ref d);
    assert(!next.died && next.pain && mo.health == 2, 'later hit still applies');
    assert(d.armor_points == 93 && d.damagecount == 8 && d.attacker == 2, 'per-hit bookkeeping');
    assert(rng.index == 3, 'second pain draw not skipped');
}

#[test]
fn true_death_happens_once_and_keeps_exact_corpse_state() {
    let (w, mut mo) = setup(10);
    let original_height = mo.height;
    let original_flags = mo.flags;
    let list = array![mo, mo, mo].span();
    let mut d = BoxTrait::new(defense(20, 2));
    let mut rng = from_index(1);
    let first = damage_mobj_with_defense(w, list, ref rng, ref mo, 0, NO_MOBJ, 1, 30, false, ref d);
    assert(first.died && !first.pain && first.drop.is_none(), 'one real death');
    assert(mo.health == -5 && d.armor_points == 5, 'fifteen net');
    assert(mo.state == *MI_DEATHSTATE.span().at(KIND_PLAYER), 'normal death state');
    // First draw 8: 8 & 3 = 0, so the death duration is unchanged.
    assert(mo.tics == *w.states.tics.at(mo.state), 'exact death duration');
    assert(mo.height == fixed::div(original_height, fixed::from_units(4)), 'quartered height');
    assert(
        has(mo.flags, MF_CORPSE) && !has(mo.flags, MF_SHOOTABLE) && !has(mo.flags, MF_SOLID),
        'corpse flags',
    );
    let expected_flags = doom_physics::without(original_flags, MF_SHOOTABLE + MF_SOLID)
        | MF_CORPSE
        | doom_physics::MF_DROPOFF;
    assert(mo.flags == expected_flags, 'exact player corpse flags');
    assert(rng.index == 2, 'one death shortening draw');
    let dead = mo;
    let saved = d.unbox();
    let again = damage_mobj_with_defense(w, list, ref rng, ref mo, 0, NO_MOBJ, 2, 30, false, ref d);
    assert(!again.died && !again.pain && mo == dead, 'corpse unchanged');
    assert(d.unbox() == saved && rng.index == 2, 'no damage after death');
}

#[test]
fn armor_does_not_reduce_raw_thrust_or_its_fall_forward_draw() {
    let (w, mut source) = setup(100);
    let mut defended = source;
    source.x = fixed::sub(source.x, fixed::from_units(64));
    defended.health = 10;
    defended.z = fixed::add(source.z, fixed::from_units(80));
    let mut bare = defended;
    let list = array![defended, source].span();
    let mut d = BoxTrait::new(defense(100, 2));
    let mut no_armor = BoxTrait::new(defense(0, 0));
    let mut r1 = from_index(1);
    let mut r2 = from_index(1);
    let a = damage_mobj_with_defense(w, list, ref r1, ref defended, 0, 1, 1, 12, true, ref d);
    let b = damage_mobj_with_defense(w, list, ref r2, ref bare, 0, 1, 1, 12, true, ref no_armor);
    assert(!a.died && b.died, 'net damage decides death');
    assert(defended.momx == bare.momx && defended.momy == bare.momy, 'same raw-damage thrust');
    assert(r1.index == 3 && r2.index == 3, 'raw fall-forward then reaction');
}

fn before_action(w: World, action: u32) -> u32 {
    let mut state: u32 = 0;
    while state < w.states.next_state.len() {
        let next = *w.states.next_state.at(state);
        if *w.states.action_id.at(next) == action {
            return state;
        }
        state += 1;
    }
    panic!("action missing");
}

#[test]
fn second_monster_attacks_after_raw_lethal_but_net_surviving_bite() {
    let (mut w, mut me) = setup(10);
    // Independent stream: bite=(2%10+1)*4=12, pain=0,
    // bite=(0%10+1)*4=4, pain=0. Four draws, no death.
    let mut bytes: Array<u8> = array![0, 2];
    let mut n: u32 = 2;
    while n < 256 {
        bytes.append(0);
        n += 1;
    }
    w.rndtable = bytes.span();
    let mut a = spawn_mobj(
        w, KIND_SERGEANT, fixed::sub(me.x, fixed::from_units(48)), me.y, SpawnZ::OnFloor,
    );
    let mut b = spawn_mobj(
        w, KIND_SERGEANT, fixed::add(me.x, fixed::from_units(48)), me.y, SpawnZ::OnFloor,
    );
    let state = before_action(w, A_SARGATTACK);
    a.state = state;
    a.tics = 1;
    a.target = 0;
    b.state = state;
    b.tics = 1;
    b.target = 0;
    a.sight_expires = 100;
    a.sight_sector = me.sector;
    a.sight_ok = true;
    b.sight_expires = 100;
    b.sight_sector = me.sector;
    b.sight_ok = true;
    let mut grid = new_grid();
    set_thing_position(@w.map, ref grid, ref me, 0);
    set_thing_position(@w.map, ref grid, ref a, 1);
    set_thing_position(@w.map, ref grid, ref b, 2);
    let mut d = defense(100, 2);
    let (out, rng, events) = monsters_ticker_with_defense(
        w, array![me, a, b].span(), ref grid, array![0].span(), silence(), 0, from_index(1), ref d,
    );
    let after = *out.at(0);
    assert(after.health == 2, 'later attacker keeps its hit');
    assert(d.armor_points == 92 && d.damagecount == 8 && d.attacker == 2, 'two actual bites');
    assert(rng.index == 5, 'bite,pain,bite,pain');
    assert(after.height == me.height && !has(after.flags, MF_CORPSE), 'never became a corpse');
    assert(
        (has(after.flags, MF_SHOOTABLE)
            && has(after.flags, MF_SOLID)
            && has(after.flags, MF_JUSTHIT)),
        'alive and in pain',
    );
    assert(after.state == *MI_PAINSTATE.span().at(KIND_PLAYER), 'pain state preserved');
    let mut ev = events.span();
    while let Option::Some(e) = ev.pop_front() {
        assert(
            *e.kind != doom_monsters::EV_KILLED && *e.kind != doom_monsters::EV_DROP,
            'no death effects',
        );
    }
}


#[test]
fn hitscan_then_missile_share_the_remaining_armor() {
    let (mut w, mut me) = setup(10);
    let mut bytes: Array<u8> = array![];
    let mut n: u32 = 0;
    while n < 256 {
        bytes.append(0);
        n += 1;
    }
    w.rndtable = bytes.span();
    let mut shooter = spawn_mobj(
        w, KIND_POSSESSED, fixed::add(me.x, fixed::from_units(48)), me.y, SpawnZ::OnFloor,
    );
    shooter.state = before_action(w, A_POSATTACK);
    shooter.tics = 1;
    shooter.target = 0;
    let mut ball = spawn_mobj(
        w,
        KIND_TROOPSHOT,
        fixed::sub(me.x, fixed::from_units(30)),
        me.y,
        SpawnZ::At(fixed::add(me.z, fixed::from_units(32))),
    );
    ball.target = 1;
    ball.momx = fixed::from_units(10);
    let mut grid = new_grid();
    set_thing_position(@w.map, ref grid, ref me, 0);
    set_thing_position(@w.map, ref grid, ref shooter, 1);
    set_thing_position(@w.map, ref grid, ref ball, 2);
    let mut d = defense(1, 1);
    let (out, rng, events) = monsters_ticker_with_defense(
        w,
        array![me, shooter, ball].span(),
        ref grid,
        array![0].span(),
        silence(),
        0,
        from_index(1),
        ref d,
    );
    // Zero spread, (0 % 5 + 1) * 3 = 3 bullet damage, saves the last armor
    // point. Missile (0 % 8 + 1) * 3 = 3 now hits unarmored: 10 - 2 - 3.
    assert(*out.at(0).health == 5, 'bullet then missile damage');
    assert(d.armor_points == 0 && d.armor_type == 0, 'armor exhausted by bullet');
    assert(d.damagecount == 5 && d.attacker == 1, 'missile source is its owner');
    // Spread x2, bullet, pain, missile, pain, explosion duration.
    assert(rng.index == 8, 'seven draws in impact order');
    assert(!has(*out.at(2).flags, doom_physics::MF_MISSILE), 'missile exploded');
    let mut saw_bullet = false;
    let mut ev = events.span();
    while let Option::Some(e) = ev.pop_front() {
        if *e.kind == doom_monsters::EV_BLOOD && *e.who == 1 && *e.a == 0 && *e.b == 3 {
            saw_bullet = true;
        }
        assert(
            *e.kind != doom_monsters::EV_KILLED && *e.kind != doom_monsters::EV_DROP,
            'no death effects',
        );
    }
    assert(saw_bullet, 'hitscan really landed');
}

#[test]
fn game_tic_synchronizes_only_net_damage_after_both_attacks() {
    let mut g = genesis(LevelId::E1M1);
    let w = ctx_of(g.level, g.floor, g.ceil).w;
    let mut me = *g.mobjs.at(0);
    me.health = 21;
    g.player.health = 21;
    g.player.armor_points = 100;
    g.player.armor_type = 2;
    let mut a = spawn_mobj(
        w, KIND_SERGEANT, fixed::sub(me.x, fixed::from_units(48)), me.y, SpawnZ::OnFloor,
    );
    let mut b = spawn_mobj(
        w, KIND_SERGEANT, fixed::add(me.x, fixed::from_units(48)), me.y, SpawnZ::OnFloor,
    );
    let state = before_action(w, A_SARGATTACK);
    a.state = state;
    a.tics = 1;
    a.target = 0;
    b.state = state;
    b.tics = 1;
    b.target = 0;
    a.sight_expires = 100;
    a.sight_sector = me.sector;
    a.sight_ok = true;
    b.sight_expires = 100;
    b.sight_sector = me.sector;
    b.sight_ok = true;
    let mut grid = new_grid();
    set_thing_position(@w.map, ref grid, ref me, 0);
    set_thing_position(@w.map, ref grid, ref a, 1);
    set_thing_position(@w.map, ref grid, ref b, 2);
    g.grid = grid;
    g.mobjs = array![me, a, b].span();
    g.prng = from_index(1);
    // Keep this integration fixture focused on combat RNG: no random lights.
    g.specials.lights = array![].span();
    let cmd = ticcmd::encode(ticcmd::TicCmd { forward: 0, side: 0, angle_turn: 0, buttons: 0 });
    let (after, status) = crate::step_tic(g, cmd);
    // Actual Doom table: attack 8 -> 36, pain 109, attack 220 -> 4,
    // pain 222. Blue armor saves 18 + 2, leaving 21 - 20 = 1.
    assert(status == segment::Status::Running, 'still running');
    assert(
        after.player.health == 1 && *after.mobjs.at(0).health == 1, 'records agree after two hits',
    );
    assert(
        after.player.armor_points == 80 && after.player.armor_type == 2,
        'armor applied once per hit',
    );
    assert(
        after.player.damagecount == 20 && after.player.attacker == 2, 'final defense synchronized',
    );
    assert(after.player.playerstate == doom_player::PST_LIVE, 'never marked dead');
    assert(*after.mobjs.at(0).height == me.height, 'no corpse resurrection');
    assert(after.prng.index == 5, 'four attack and reaction draws');
}


#[test]
fn defense_is_scoped_to_its_player_and_damage_flash_saturates() {
    let (w, mut me) = setup(100);
    let mut other = me;
    let list = array![me, other, other].span();
    let before = PlayerDefense { damagecount: 98, ..defense(100, 2) };
    let mut d = BoxTrait::new(before);
    let mut rng = from_index(1);
    let _ = damage_mobj_with_defense(w, list, ref rng, ref other, 1, NO_MOBJ, 2, 6, false, ref d);
    assert(other.health == 94 && d.unbox() == before, 'other target has no armor');
    let _ = damage_mobj_with_defense(w, list, ref rng, ref me, 0, NO_MOBJ, 2, 6, false, ref d);
    assert(me.health == 97 && d.armor_points == 97, 'player saves three');
    assert(d.damagecount == 100 && d.attacker == 2, 'flash caps at one hundred');
    assert(rng.index == 3, 'one pain draw per target');
}

#[test]
fn later_wall_puff_does_not_replace_the_actual_attacker() {
    let (mut w, mut me) = setup(100);
    // First shot: no spread, 3 damage, pain draw. Second shot: a 255-byte
    // spread (~22 degrees) misses and makes a wall puff with a=0. That is
    // an event payload, not evidence that player mobj 0 was damaged.
    let mut bytes: Array<u8> = array![0, 0, 0, 0, 0, 255, 0, 0];
    let mut n: u32 = 8;
    while n < 256 {
        bytes.append(0);
        n += 1;
    }
    w.rndtable = bytes.span();
    let mut hit = spawn_mobj(
        w, KIND_POSSESSED, fixed::add(me.x, fixed::from_units(48)), me.y, SpawnZ::OnFloor,
    );
    let mut miss = spawn_mobj(
        w, KIND_POSSESSED, fixed::sub(me.x, fixed::from_units(64)), me.y, SpawnZ::OnFloor,
    );
    let state = before_action(w, A_POSATTACK);
    hit.state = state;
    hit.tics = 1;
    hit.target = 0;
    miss.state = state;
    miss.tics = 1;
    miss.target = 0;
    let mut grid = new_grid();
    set_thing_position(@w.map, ref grid, ref me, 0);
    set_thing_position(@w.map, ref grid, ref hit, 1);
    set_thing_position(@w.map, ref grid, ref miss, 2);
    let mut d = defense(100, 1);
    let (out, rng, events) = monsters_ticker_with_defense(
        w,
        array![me, hit, miss].span(),
        ref grid,
        array![0].span(),
        silence(),
        0,
        from_index(1),
        ref d,
    );
    assert(*out.at(0).health == 98 && d.armor_points == 99, 'only first shot damaged');
    assert(d.attacker == 1 && d.damagecount == 2, 'miss cannot change attacker');
    assert(rng.index == 8, 'second shot draws no pain');
    let mut received = false;
    let mut missed_after = false;
    let mut ev = events.span();
    while let Option::Some(e) = ev.pop_front() {
        if *e.kind == doom_monsters::EV_BLOOD && *e.who == 1 && *e.a == 0 {
            received = true;
        }
        if *e.kind == doom_monsters::EV_PUFF && *e.who == 2 && *e.a == 0 {
            assert(received, 'wall puff follows real impact');
            missed_after = true;
        }
    }
    assert(received && missed_after, 'impact then wall puff');
}
