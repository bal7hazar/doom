// SPDX-License-Identifier: GPL-2.0-only
//! Golden replays on Freedoom E1M1 and everything that reads a real
//! coordinate. Each replay is a scripted input log from genesis; its final
//! hash and stats are pinned. A changed pin means the simulation changed:
//! regenerate it on purpose (PLAN.md §3.1 rule 5), never silently — the
//! test prints what it computed.

use doom_map::LevelId;
use doom_physics::{MF_COUNTITEM, MF_COUNTKILL, has, is_removed};
use doom_player::PST_DEAD;
use segment::Status;
use ticcmd::{TicCmd, encode};
use crate::{
    GameState, TOTAL_ITEMS, TOTAL_KILLS, TOTAL_SECRETS, genesis, hash, run_segment, stats_of,
    step_tic,
};

fn word(forward: i64, side: i64, turn: i64, buttons: u8) -> felt252 {
    encode(TicCmd { forward, side, angle_turn: turn, buttons })
}

/// Expand `(tics, forward, side, turn, buttons)` segments into words.
fn script(mut segs: Span<(u32, i64, i64, i64, u8)>) -> Array<felt252> {
    let mut out: Array<felt252> = array![];
    while let Option::Some(seg) = segs.pop_front() {
        let (tics, f, s, t, b) = *seg;
        let w = word(f, s, t, b);
        let mut k: u32 = 0;
        while k != tics {
            out.append(w);
            k += 1;
        }
    }
    out
}

fn run(state: GameState, words: Span<felt252>) -> (GameState, Status) {
    run_traced(state, words, 0)
}

/// `run`, printing the player every `every` tics (0: silent) — the tool for
/// scripting a new log.
fn run_traced(state: GameState, words: Span<felt252>, every: u32) -> (GameState, Status) {
    let mut s = state;
    let mut status = Status::Running;
    let mut ws = words;
    while let Option::Some(w) = ws.pop_front() {
        let (next, st) = step_tic(s, *w);
        s = next;
        status = st;
        if every != 0 && s.leveltime % every == 0 {
            trace(@s);
        }
        if status != Status::Running {
            break;
        }
    }
    (s, status)
}

fn trace(s: @GameState) {
    let mo = *(*s.mobjs).at(*s.player.mo);
    let st = stats_of(s);
    let ctx = crate::ctx_of(*s.level, *s.floor, *s.ceil);
    println!(
        "tic {} x {} y {} z {} sector {} angle {} health {} kills {} awake {} movers {} noise {}",
        *s.leveltime,
        fixed::to_units(mo.x),
        fixed::to_units(mo.y),
        fixed::to_units(mo.z),
        mo.sector,
        mo.angle,
        *s.player.health,
        st.kills,
        doom_monsters::awake_count(ctx.w, *s.mobjs),
        (*s.specials.movers).len(),
        *s.noise.sector,
    );
    let mut ms = *s.mobjs;
    let mut i: u32 = 0;
    while let Option::Some(m) = ms.pop_front() {
        if doom_monsters::is_awake(ctx.w, m) {
            println!(
                "    awake {} kind {} x {} y {} health {} state {}",
                i,
                *m.kind,
                fixed::to_units(*m.x),
                fixed::to_units(*m.y),
                *m.health,
                *m.state,
            );
        }
        i += 1;
    }
}

// ---------------------------------------------------------------------------
// Genesis
// ---------------------------------------------------------------------------

#[test]
fn test_genesis_spawns_the_level() {
    let g = genesis(LevelId::E1M1);
    let mut kills: u32 = 0;
    let mut items: u32 = 0;
    let mut ms = g.mobjs;
    while let Option::Some(m) = ms.pop_front() {
        assert(!is_removed(m), 'no hole at genesis');
        if has(*m.flags, MF_COUNTKILL) {
            kills += 1;
        }
        if has(*m.flags, MF_COUNTITEM) {
            items += 1;
        }
    }
    assert(kills == TOTAL_KILLS, 'total kills');
    assert(items == TOTAL_ITEMS, 'total items');
    let mut secrets: u32 = 0;
    let m = doom_map::load(LevelId::E1M1);
    let mut i: u32 = 0;
    while i != doom_map::num_sectors(@m) {
        if doom_map::sector(@m, i).special == 9 {
            secrets += 1;
        }
        i += 1;
    }
    assert(secrets == TOTAL_SECRETS, 'total secrets');
    assert(g.mobjs.len() > 150 && g.mobjs.len() < 256, 'the roster fits');
    assert(g.specials.lights.len() == 9, 'nine light thinkers');
}

// ---------------------------------------------------------------------------
// The scripted logs
// ---------------------------------------------------------------------------

/// 700 tics of nothing at the Player 1 start.
fn idle_log() -> Array<felt252> {
    script(array![(700, 0, 0, 0, 0)].span())
}

/// East out of the start room, over the walk-triggered lift (linedef 596,
/// WR 88) which lowers under the player, down into the trench (sector 17).
fn walk_log() -> Array<felt252> {
    script(array![(110, 25, 0, 0, 0), (240, 0, 0, 0, 0)].span())
}

/// The walk, then north-east across the trench and north up the door
/// corridor (sector 93) with USE pressed every 35 tics: the DR door
/// (linedef 577 -> sector 10) opens on the first press within `USERANGE`
/// and the player walks through as soon as the opening is 56 units. The
/// two zombiemen of the trench are awake and shooting all along (one of
/// them stands in the corridor's mouth for a while), so the log keeps the
/// forward key down rather than trusting a timing.
fn door_log() -> Array<felt252> {
    let mut segs: Array<(u32, i64, i64, i64, u8)> = array![
        (136, 25, 0, 0, 0), (1, 0, 0, 10240, 0), (25, 25, 0, 0, 0), (1, 0, 0, 6144, 0),
    ];
    let mut k: u32 = 0;
    while k != 5 {
        segs.append((34, 25, 0, 0, 0));
        segs.append((1, 25, 0, 0, 2));
        k += 1;
    }
    segs.append((12, 0, 0, 0, 0));
    script(segs.span())
}

/// The walk into the trench, then the pistol held while the aim sweeps
/// from 36 degrees down to the east in 2.8-degree steps, twice over — the
/// zombieman of the corridor mouth (30 degrees off) is awake from the
/// fall, the one in the trench wakes on the first shot, and both walk into
/// the line of fire.
fn fight_log() -> Array<felt252> {
    let mut segs: Array<(u32, i64, i64, i64, u8)> = array![(110, 25, 0, 0, 0), (1, 0, 0, 6656, 0)];
    let mut round: u32 = 0;
    while round != 2 {
        let mut k: u32 = 0;
        while k != 13 {
            segs.append((20, 0, 0, 0, 1));
            segs.append((1, 0, 0, -512, 1));
            k += 1;
        }
        segs.append((1, 0, 0, 6656, 1));
        round += 1;
    }
    segs.append((41, 0, 0, 0, 1));
    script(segs.span())
}

/// The walk to the zombiemen without firing back: the player waits to die.
fn death_log() -> Array<felt252> {
    script(array![(150, 25, 0, 0, 0), (1, 0, 0, 1792, 0), (1049, 0, 0, 0, 0)].span())
}

/// Pinned final hashes and stats. A zero pin is "not yet pinned": the test
/// prints the value and fails.
const IDLE_V1_HASH: felt252 =
    2153606983378364918731315774236787078519694294296420268027668792811803518728;
const IDLE_HASH: felt252 =
    2156929299860618434340270683399317251723592578997214595893226167015506269488;
const WALK_V1_HASH: felt252 =
    39841880533417028430921014231592644327184952983595253635262055579997356896;
const WALK_HASH: felt252 =
    3462572684582230757027468800465421350164007866179957854524195282835990262921;
// R4: only Player.attacker changed in this replay (132 -> 64; serialized
// offset 38). A late EV_PUFF from a wall (a=0) used to overwrite the real
// damage source. These two hashes are the old states with that single field
// replaced, checked independently with Python Poseidon; every other felt
// and the idle/walk/fight/death pins are unchanged. damage_order's received
// shot followed by a wall puff tests the rule without relying on these pins.
const DOOR_V1_HASH: felt252 =
    1810708824505134600273062095662412677489351130252411842415652833719272239165;
const DOOR_HASH: felt252 =
    263744128839628815935196177788227752803091067547544797918898629454962125944;
const FIGHT_V1_HASH: felt252 =
    1532869039222309804296551618310848711341877344954734786015860209771621064852;
const FIGHT_HASH: felt252 =
    1609348354717009447474707322230094655457362319666387447877072993886890408972;
const DEATH_V1_HASH: felt252 =
    2945023360227877718775127057908218198185833009002510623948511571322548243465;
const DEATH_HASH: felt252 =
    1827285648027806617056651336177441561786598671369093960976531423658312820056;

fn check(name: felt252, state: @GameState, pin: felt252, v1_pin: felt252) {
    // Explicit schema migration: only the committed grid order and version
    // may change. The five existing gameplay records retain their v1 pins.
    let record = crate::serialize(state);
    let base = crate::state::SCALARS
        + doom_player::PLAYER_FELTS
        + 1
        + (*state.mobjs).len() * doom_physics::MOBJ_FELTS
        + 1
        + doom_specials::fields(state.specials);
    let mut legacy = state_hash::open(crate::TAG, 1, base);
    legacy.append_span(record.span().slice(3, base));
    assert(state_hash::seal(legacy.span()) == v1_pin, 'v1 gameplay golden unchanged');
    let h = hash(state);
    if h != pin {
        println!("{}: hash {} (pinned {})", name, h, pin);
        let st = stats_of(state);
        println!(
            "  tic {} kills {} items {} secrets {} health {} mobjs {}",
            *state.leveltime,
            st.kills,
            st.items,
            st.secrets,
            *state.player.health,
            (*state.mobjs).len(),
        );
        let mo = *(*state.mobjs).at(*state.player.mo);
        println!(
            "  x {} y {} z {} sector {} floorz {}",
            mo.x.enc,
            mo.y.enc,
            mo.z.enc,
            mo.sector,
            mo.floorz.enc,
        );
    }
    assert(h == pin, 'pinned hash');
}

#[test]
fn test_replay_idle() {
    let (s, status) = run(genesis(LevelId::E1M1), idle_log().span());
    assert(status == Status::Running, 'still running');
    assert(s.leveltime == 700, '700 tics');
    let st = stats_of(@s);
    assert(st.kills == 0 && st.items == 0 && st.secrets == 0, 'nothing happened');
    check('idle', @s, IDLE_HASH, IDLE_V1_HASH);
}

#[test]
fn test_replay_walk() {
    let (s, status) = run(genesis(LevelId::E1M1), walk_log().span());
    assert(status == Status::Running, 'still running');
    let mo = *s.mobjs.at(0);
    assert(mo.sector == 17, 'down in the trench');
    assert(mo.z.enc == fixed::from_units(-128).enc, 'on the trench floor');
    let st = stats_of(@s);
    assert(st.items == 1 && st.kills == 0, 'one pickup on the way');
    assert(s.player.health == 77, 'shot at on the way down');
    check('walk', @s, WALK_HASH, WALK_V1_HASH);
}

#[test]
fn test_replay_door() {
    let (s, status) = run(genesis(LevelId::E1M1), door_log().span());
    assert(status == Status::Running, 'still running');
    let mo = *s.mobjs.at(0);
    assert(fixed::gt(mo.y, fixed::from_units(560)), 'through the door');
    assert(mo.sector == 56, 'in the room behind it');
    assert(s.specials.used.len() == 0 && s.specials.movers.len() == 1, 'the door is a thinker');
    let st = stats_of(@s);
    assert(st.items == 3 && st.kills == 0, 'three pickups');
    assert(s.player.health == 70, 'health 70');
    check('door', @s, DOOR_HASH, DOOR_V1_HASH);
}

#[test]
fn test_replay_fight() {
    let (s, status) = run(genesis(LevelId::E1M1), fight_log().span());
    let st = stats_of(@s);
    assert(status == Status::Running, 'still running');
    assert(st.kills == 1 && st.items == 1, 'one kill, one pickup');
    assert(s.player.health == 92, 'health 92');
    assert(s.leveltime == 700, '700 tics');
    let ctx = crate::ctx_of(s.level, s.floor, s.ceil);
    assert(doom_monsters::awake_count(ctx.w, s.mobjs) == 11, '11 awake at the end');
    check('fight', @s, FIGHT_HASH, FIGHT_V1_HASH);
}

#[test]
fn test_replay_death() {
    let (s, status) = run(genesis(LevelId::E1M1), death_log().span());
    assert(status == Status::Dead, 'dead');
    assert(s.player.playerstate == PST_DEAD && s.player.health == 0, 'PST_DEAD');
    assert(s.leveltime == 846, 'dead on tic 846');
    assert(stats_of(@s).items == 2, 'two pickups before');
    check('death', @s, DEATH_HASH, DEATH_V1_HASH);
}

#[test]
fn test_segment_over_the_walk_matches_the_loop() {
    let log = walk_log();
    let (looped, _) = run(genesis(LevelId::E1M1), log.span());
    let (segmented, out) = run_segment(genesis(LevelId::E1M1), log.span(), 0, 1000);
    assert(hash(@looped) == hash(@segmented), 'same state');
    assert(out.h_out == hash(@looped), 'h_out');
    assert(out.tic_end == log.len(), 'every tic ran');
}

/// A process boundary reconstructs derived data; associativity must hold
/// across that boundary, not only while keeping the same in-memory grid.
#[test]
fn test_fight_is_associative_across_serialized_boundaries() {
    let log = fight_log();
    let (whole, _) = run(genesis(LevelId::E1M1), log.span());
    let mut sliced = genesis(LevelId::E1M1);
    let mut start: u32 = 0;
    while start < log.len() {
        let count = if log.len() - start > 25 {
            25
        } else {
            log.len() - start
        };
        let saved = crate::serialize(@sliced);
        sliced = crate::from_felts(saved.span()).expect('boundary readable');
        let (next, _) = run(sliced, log.span().slice(start, count));
        sliced = next;
        start += count;
    }
    assert(hash(@whole) == hash(@sliced), 'serialized split associative');
}
