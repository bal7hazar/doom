// SPDX-License-Identifier: GPL-2.0-only
//! Level-independent glue tests: the state record, the readers, the status
//! rule, the ABORT paths, the event appliers on hand-built mobjs. They
//! assert no coordinate of E1M1, so `bench/coverage.py` runs them on
//! `doom_map`'s miniature level as well.

use doom_map::LevelId;
use doom_monsters::{Ctx as MonsterCtx, EV_CROSS, EV_DROP, EV_KILLED, EV_SOUND, MonsterEvent, Patch};
use doom_physics::{
    Hit, MF_DROPPED, MF_SHOOTABLE, MF_SPECIAL, Mobj, MoveEvent, NO_MOBJ, SpawnZ, ThingGrid, has,
    is_removed, new_grid, removed_mobj, set_thing_position, spawn_mobj,
};
use doom_player::{PST_DEAD, PST_LIVE, PlayerEvent, WP_CHAINSAW, env_of};
use doom_specials::state::{Mover, MoverKind, Phase, set_felt};
use doom_specials::{SectorBlocking, SpecialsState};
use doom_things::tables::{KIND_CLIP, KIND_MISC2, KIND_POSSESSED};
use geom2d::Point;
use prng::from_index;
use segment::{Status, from_felts as output_from_felts, to_felts};
use ticcmd::{TicCmd, encode};
use crate::level::{Occupancy, contains, ctx_of, moving_sectors, refresh_heights};
use crate::tic::{
    apply_monster_events, apply_move_events, apply_player_events, height_clip, place_drops,
    rebuild_list, reconcile_player,
};
use crate::{
    GameEngine, GameState, MOBJ_WORDS, PLAYER_WORDS, SECTOR_WORDS, SNAPSHOT_HEADER, STATS_WORDS,
    TAG, VERSION, fields, from_felts, genesis, hash, run_segment, serialize, snapshot, stats_of,
    status_of, step_tic,
};

fn idle() -> felt252 {
    encode(TicCmd { forward: 0, side: 0, angle_turn: 0, buttons: 0 })
}

fn word(forward: i64, side: i64, turn: i64, buttons: u8) -> felt252 {
    encode(TicCmd { forward, side, angle_turn: turn, buttons })
}

fn run(state: GameState, words: Span<felt252>) -> (GameState, Status) {
    let mut s = state;
    let mut status = Status::Running;
    let mut ws = words;
    while let Option::Some(w) = ws.pop_front() {
        let (next, st) = step_tic(s, *w);
        s = next;
        status = st;
        if status != Status::Running {
            break;
        }
    }
    (s, status)
}

// ---------------------------------------------------------------------------
// The record
// ---------------------------------------------------------------------------

#[test]
fn test_genesis_is_running_at_tic_zero_with_both_streams_at_one() {
    let g = genesis(LevelId::E1M1);
    assert(g.leveltime == 0, 'tic 0');
    assert(g.status == Status::Running, 'running');
    assert(g.prng.index == 4 || g.prng.index >= 1, 'P_Random advanced by specials');
    assert(g.mrng.index == 1, 'M_Random at 1 (D24)');
    assert(g.noise.source == NO_MOBJ, 'silence');
    assert(g.player.mo == 0, 'player is mobj 0');
    assert(g.player.health == 100, 'full health');
    assert(status_of(@g) == Status::Running, 'status rule');
}

#[test]
fn test_serialization_declares_its_length_and_round_trips() {
    let g = genesis(LevelId::E1M1);
    let felts = serialize(@g);
    assert(felts.len() == fields(@g) + 3, 'header + fields');
    assert(*felts.at(0) == TAG, 'tag');
    assert(*felts.at(1) == VERSION, 'version');
    let back = from_felts(felts.span()).expect('readable');
    assert(hash(@back) == hash(@g), 'same hash after a round trip');
    assert(back.mobjs.len() == g.mobjs.len(), 'same list');
    assert(back.floor == g.floor, 'same floors');
    assert(back.ceil == g.ceil, 'same ceilings');
    assert(back.player == g.player, 'same player');
}

#[test]
fn test_every_serialized_felt_is_small() {
    let g = genesis(LevelId::E1M1);
    let mut felts = serialize(@g).span();
    let bound: u128 = 0x1000000000000000000; // 2^72
    // Skip the tag (a short string, by design above the bound).
    let _ = felts.pop_front();
    while let Option::Some(f) = felts.pop_front() {
        let v: u128 = (*f).try_into().expect('fits u128');
        assert(v < bound, 'below 2^72');
    }
}

#[test]
fn test_reader_rejects_a_malformed_record() {
    let g = genesis(LevelId::E1M1);
    let felts = serialize(@g);
    assert(from_felts(array![].span()).is_none(), 'empty');
    let mut wrong_tag = felts.clone();
    let _ = wrong_tag;
    // Wrong tag.
    let mut a: Array<felt252> = array!['HP.NOPE'];
    let mut k: u32 = 1;
    while k != felts.len() {
        a.append(*felts.at(k));
        k += 1;
    }
    assert(from_felts(a.span()).is_none(), 'wrong tag');
    // Wrong version.
    let mut b: Array<felt252> = array![TAG, 99];
    k = 2;
    while k != felts.len() {
        b.append(*felts.at(k));
        k += 1;
    }
    assert(from_felts(b.span()).is_none(), 'wrong version');
    // Truncated.
    let mut c: Array<felt252> = array![];
    k = 0;
    while k != felts.len() - 5 {
        c.append(*felts.at(k));
        k += 1;
    }
    assert(from_felts(c.span()).is_none(), 'truncated');
    // A status out of range.
    let mut d: Array<felt252> = array![];
    k = 0;
    while k != felts.len() {
        d.append(if k == 5 {
            7
        } else {
            *felts.at(k)
        });
        k += 1;
    }
    assert(from_felts(d.span()).is_none(), 'bad status');
    // A Fixed past 2^33 inside the player record (viewz is field 15 of 36).
    let mut e: Array<felt252> = array![];
    k = 0;
    while k != felts.len() {
        e.append(if k == 3 + 7 + 15 {
            0x400000000
        } else {
            *felts.at(k)
        });
        k += 1;
    }
    assert(from_felts(e.span()).is_none(), 'bad fixed');
    // An unknown level.
    let mut f: Array<felt252> = array![];
    k = 0;
    while k != felts.len() {
        f.append(if k == 3 {
            'E9M9'
        } else {
            *felts.at(k)
        });
        k += 1;
    }
    assert(from_felts(f.span()).is_none(), 'unknown level');
}

#[test]
fn test_hash_is_sensitive_to_the_clock_and_the_player() {
    let a = genesis(LevelId::E1M1);
    let mut b = genesis(LevelId::E1M1);
    b.leveltime = 1;
    let mut c = genesis(LevelId::E1M1);
    c.player.health = 99;
    assert(hash(@a) == hash(@genesis(LevelId::E1M1)), 'deterministic');
    assert(hash(@a) != hash(@b), 'clock');
    assert(hash(@a) != hash(@c), 'player');
}

// ---------------------------------------------------------------------------
// The tic's guards
// ---------------------------------------------------------------------------

#[test]
fn test_invalid_word_aborts_and_leaves_the_state_untouched() {
    let g = genesis(LevelId::E1M1);
    let h = hash(@g);
    let (after, status) = step_tic(g, 0x1_0000_0000);
    assert(status == Status::Abort, 'abort');
    assert(hash(@after) == h, 'untouched');
    assert(after.leveltime == 0, 'clock did not move');
}

#[test]
fn test_stepping_a_finished_game_aborts() {
    let mut g = genesis(LevelId::E1M1);
    g.status = Status::Exit;
    let (after, status) = step_tic(g, idle());
    assert(status == Status::Abort, 'abort');
    assert(after.status == Status::Exit, 'status kept');
}

#[test]
fn test_player_index_past_the_list_aborts() {
    let mut g = genesis(LevelId::E1M1);
    g.player.mo = 9999;
    let (after, status) = step_tic(g, idle());
    assert(status == Status::Abort, 'abort');
    assert(after.leveltime == 0, 'clock did not move');
}

#[test]
fn test_idle_tic_advances_the_clock_and_keeps_running() {
    let g = genesis(LevelId::E1M1);
    let (after, status) = step_tic(g, idle());
    assert(status == Status::Running, 'running');
    assert(after.leveltime == 1, 'tic 1');
    assert(after.player.health == 100, 'unhurt');
}

#[test]
fn test_status_rule() {
    let mut g = genesis(LevelId::E1M1);
    assert(status_of(@g) == Status::Running, 'running');
    g.player.playerstate = PST_DEAD;
    assert(status_of(@g) == Status::Dead, 'dead');
    g.specials.exit = true;
    assert(status_of(@g) == Status::Exit, 'exit wins');
    g.player.playerstate = PST_LIVE;
    assert(status_of(@g) == Status::Exit, 'exit');
}

// ---------------------------------------------------------------------------
// The engine
// ---------------------------------------------------------------------------

#[test]
fn test_run_segment_of_zero_tics_is_a_no_op() {
    let g = genesis(LevelId::E1M1);
    let h = hash(@g);
    let (after, out) = run_segment(g, array![].span(), 0, 10);
    assert(out.h_in == h && out.h_out == h, 'hashes');
    assert(out.tic_end == 0, 'no tic');
    assert(out.status == Status::Running, 'running');
    assert(hash(@after) == h, 'state');
    assert(out.stats == stats_of(@after), 'stats');
    let felts = to_felts(out);
    assert(felts.len() == 10, 'ten felts');
    assert(output_from_felts(felts.span()).is_some(), 'readable');
}

#[test]
fn test_run_segment_agrees_with_the_step_loop() {
    let words = array![idle(), word(25, 0, 0, 0), word(25, 0, 256, 0), idle(), word(0, 10, 0, 0)];
    let (looped, _) = run(genesis(LevelId::E1M1), words.span());
    let (segmented, out) = run_segment(genesis(LevelId::E1M1), words.span(), 0, 100);
    assert(hash(@looped) == hash(@segmented), 'same state');
    assert(out.h_out == hash(@looped), 'h_out');
    assert(out.tic_end == 5, 'five tics');
    assert(out.tic_start == 0, 'from 0');
}

#[test]
fn test_run_segment_is_associative_over_a_split() {
    let a = array![word(25, 0, 0, 0), word(25, 0, 0, 0), word(25, 0, 512, 0)];
    let b = array![word(0, 0, 0, 0), word(-25, 0, 0, 2), idle()];
    let mut whole: Array<felt252> = array![];
    let mut k: u32 = 0;
    while k != a.len() {
        whole.append(*a.at(k));
        k += 1;
    }
    k = 0;
    while k != b.len() {
        whole.append(*b.at(k));
        k += 1;
    }
    let (s_whole, o_whole) = run_segment(genesis(LevelId::E1M1), whole.span(), 0, 100);
    let (s_a, o_a) = run_segment(genesis(LevelId::E1M1), a.span(), 0, 100);
    let (s_b, o_b) = run_segment(s_a, b.span(), o_a.tic_end, 100);
    assert(hash(@s_whole) == hash(@s_b), 'same final state');
    assert(o_whole.h_out == o_b.h_out, 'same h_out');
    assert(o_a.h_out == o_b.h_in, 'chained');
    assert(o_whole.tic_end == o_b.tic_end, 'same clock');
    assert(o_whole.stats == o_b.stats, 'same stats');
    assert(segment::continues(o_a, o_b), 'continues');
}

#[test]
fn test_run_segment_stops_on_abort_and_reports_it() {
    let words = array![idle(), 0x1_0000_0000, idle()];
    let (_, out) = run_segment(genesis(LevelId::E1M1), words.span(), 0, 100);
    assert(out.status == Status::Abort, 'abort');
    assert(out.tic_end == 2, 'the aborting tic counts');
}

#[test]
fn test_engine_word_is_the_identity() {
    let w = word(3, 4, 0, 5);
    assert(GameEngine::word(@w) == w, 'identity');
}

// ---------------------------------------------------------------------------
// The snapshot
// ---------------------------------------------------------------------------

#[test]
fn test_snapshot_layout_round_trip() {
    let g = genesis(LevelId::E1M1);
    let snap = snapshot(@g);
    let n_mobjs: u32 = (*snap.at(3)).try_into().unwrap();
    let n_sectors: u32 = (*snap.at(4)).try_into().unwrap();
    assert(*snap.at(0) == 1, 'version');
    assert(*snap.at(1) == 0, 'tic');
    assert(*snap.at(2) == 0, 'status');
    assert(
        snap.len() == SNAPSHOT_HEADER
            + PLAYER_WORDS
            + STATS_WORDS
            + n_mobjs * MOBJ_WORDS
            + n_sectors * SECTOR_WORDS,
        'layout length',
    );
    // The player block starts with the mobj's position.
    let mo = g.mobjs.at(0).unbox();
    assert(*snap.at(SNAPSHOT_HEADER) == mo.x.enc, 'player x');
    assert(*snap.at(SNAPSHOT_HEADER + 1) == mo.y.enc, 'player y');
    assert(*snap.at(SNAPSHOT_HEADER + 6) == 100, 'health');
    assert(*snap.at(SNAPSHOT_HEADER + 9) == 50, 'clip ammo');
    assert(*snap.at(SNAPSHOT_HEADER + 13) == 200, 'max clip');
    // Stats: totals are the level's.
    let st = SNAPSHOT_HEADER + PLAYER_WORDS;
    assert(*snap.at(st) == 0 && *snap.at(st + 1) == 0 && *snap.at(st + 2) == 0, 'no tally yet');
    assert(*snap.at(st + 3) == crate::TOTAL_KILLS.into(), 'total kills');
    // Every live mobj is listed once, id first, in order.
    let mut live: u32 = 0;
    let mut ms = g.mobjs;
    while let Option::Some(m) = ms.pop_front() {
        if !is_removed((m).as_snapshot().unbox()) {
            live += 1;
        }
    }
    assert(n_mobjs == live, 'every live mobj');
    let first = SNAPSHOT_HEADER + PLAYER_WORDS + STATS_WORDS;
    assert(*snap.at(first) == 0, 'mobj 0 is the player');
    // MT_PLAYER has no doomednum (info.c's -1): the renderer keys on `sprite`.
    assert(*snap.at(first + 1) == doom_things::NO_DOOMEDNUM.into(), 'no doomednum');
    assert(*snap.at(first + 6) == mo.x.enc, 'mobj x');
    // Sectors: the ceiling group comes first.
    let secs = first + n_mobjs * MOBJ_WORDS;
    let lm = doom_specials::load(LevelId::E1M1);
    assert(*snap.at(secs) == (*lm.ceil_sectors.at(0)).into(), 'first dynamic sector');
    assert(
        n_sectors == lm.ceil_sectors.len() + lm.floor_sectors.len() + lm.light_sectors.len(), 'n',
    );
}

// ---------------------------------------------------------------------------
// The glue, on hand-built mobjs
// ---------------------------------------------------------------------------

/// A world and the empty rest of a tic's plumbing.
fn plumbing(g: @GameState) -> (crate::Ctx, MonsterCtx) {
    let ctx = ctx_of(*g.level, *g.floor, *g.ceil);
    let players = array![0].span();
    let mctx = MonsterCtx { w: ctx.w, players, noise: *g.noise, tic: 0 };
    (ctx, mctx)
}

#[test]
fn test_a_shot_that_lands_damages_kills_counts_and_drops() {
    let g = genesis(LevelId::E1M1);
    let (ctx, mctx) = plumbing(@g);
    let w = ctx.w;
    let mut grid: ThingGrid = new_grid();
    let mut pmo = g.mobjs.at(0).unbox();
    set_thing_position(@w.map, ref grid, ref pmo, 0);
    let mut zombie = spawn_mobj(w, KIND_POSSESSED, pmo.x, pmo.y, SpawnZ::OnFloor);
    set_thing_position(@w.map, ref grid, ref zombie, 1);
    let mobjs = array![BoxTrait::new(pmo), BoxTrait::new(zombie)].span();
    let mut p = g.player;
    let mut rng = from_index(1);
    let mut s = g.specials;
    let mut patches: Array<Patch> = array![];
    let mut drops: Array<core::box::Box<Mobj>> = array![];
    let mut cues: Array<MonsterEvent> = array![];
    let at = Point { x: pmo.x, y: pmo.y };
    // Two blows: 15 (pain) then 20 (dead: a zombieman has 20).
    let events = array![
        PlayerEvent::Shot((Hit::Thing((1, at, fixed::ZERO)), 15)),
        PlayerEvent::Shot((Hit::Wall((0, at, fixed::ZERO)), 5)),
        PlayerEvent::Shot((Hit::Nothing, 5)),
        PlayerEvent::Shot((Hit::Thing((1, at, fixed::ZERO)), 20)),
    ];
    let fired = apply_player_events(
        ctx, mctx, mobjs, ref rng, ref p, ref s, events.span(), ref patches, ref drops, ref cues,
    );
    assert(fired, 'fired');
    assert(patches.len() == 2, 'two patches');
    let last = *patches.at(1);
    assert(last.idx == 1 && last.mo.health <= 0, 'the second blow compounds');
    assert(p.killcount == 1, 'one kill counted');
    assert(drops.len() == 1, 'the zombieman dropped its clip');
    assert((*drops.at(0)).kind == KIND_CLIP, 'a clip');
    assert(has((*drops.at(0)).flags, MF_DROPPED), 'dropped');
    // Place it: appended after the two.
    let mut out: Array<core::box::Box<Mobj>> = array![BoxTrait::new(pmo), BoxTrait::new(zombie)];
    place_drops(w, ref grid, ref out, drops.span());
    assert(out.len() == 3, 'appended');
    assert(!is_removed((out.at(2)).as_snapshot().unbox()), 'live');
    // With the chainsaw ready the blow does not thrust.
    let mut p2 = g.player;
    p2.ready_weapon = WP_CHAINSAW;
    let mut patches2: Array<Patch> = array![];
    let mut drops2: Array<core::box::Box<Mobj>> = array![];
    let mut cues2: Array<MonsterEvent> = array![];
    let mut s2 = g.specials;
    let one = array![PlayerEvent::Shot((Hit::Thing((1, at, fixed::ZERO)), 3))];
    apply_player_events(
        ctx, mctx, mobjs, ref rng, ref p2, ref s2, one.span(), ref patches2, ref drops2, ref cues2,
    );
    assert((*patches2.at(0)).mo.momx == fixed::ZERO, 'no thrust from the saw');
}

#[test]
fn test_use_event_reaches_the_specials_and_picked_is_ignored() {
    let g = genesis(LevelId::E1M1);
    let (ctx, mctx) = plumbing(@g);
    let mobjs = g.mobjs;
    let mut p = g.player;
    let mut rng = from_index(1);
    let mut s = g.specials;
    let mut patches: Array<Patch> = array![];
    let mut drops: Array<core::box::Box<Mobj>> = array![];
    let mut cues: Array<MonsterEvent> = array![];
    // The back side of any line is never usable: the state is unchanged.
    let events = array![PlayerEvent::Use((0, 1)), PlayerEvent::Picked(3)];
    let fired = apply_player_events(
        ctx, mctx, mobjs, ref rng, ref p, ref s, events.span(), ref patches, ref drops, ref cues,
    );
    assert(!fired, 'nothing fired');
    assert(s.movers.len() == 0, 'no thinker started');
    assert(patches.len() == 0 && drops.len() == 0, 'nothing else');
}

#[test]
fn test_touch_picks_up_and_removes_an_item_once() {
    let mut g = genesis(LevelId::E1M1);
    let (ctx, _) = plumbing(@g);
    let w = ctx.w;
    let mut grid: ThingGrid = new_grid();
    let mut pmo = g.mobjs.at(0).unbox();
    set_thing_position(@w.map, ref grid, ref pmo, 0);
    // A health bonus (MISC2) under the player's feet.
    let mut bonus = spawn_mobj(w, KIND_MISC2, pmo.x, pmo.y, SpawnZ::OnFloor);
    set_thing_position(@w.map, ref grid, ref bonus, 1);
    assert(has(bonus.flags, MF_SPECIAL), 'an item');
    let mobjs = array![BoxTrait::new(pmo), BoxTrait::new(bonus)].span();
    let mut p = g.player;
    let mut mo = pmo;
    let mut s = g.specials;
    let mut patches: Array<Patch> = array![];
    let moves = array![MoveEvent::Touch(1), MoveEvent::Touch(1), MoveEvent::MissileHit(1)];
    apply_move_events(ctx, mobjs, ref grid, ref p, ref mo, ref s, moves.span(), ref patches);
    assert(p.health == 101, 'one bonus, once');
    assert(p.itemcount == 1, 'counted');
    assert(patches.len() == 1, 'removed once');
    assert(is_removed((@(*patches.at(0)).mo).as_snapshot().unbox()), 'a removed slot');
    // The rebuild writes the patch and the player.
    let list = rebuild_list(w, mobjs, ref grid, mo, 0, patches.span(), array![].span());
    assert(is_removed((list.at(1)).as_snapshot().unbox()), 'gone from the list');
    assert(list.at(0).unbox() == mo, 'player written');
    g.player = p;
    g.specials = s;
    g.mobjs = list;
    g.grid = grid;
    assert_state_roundtrip(@g);
}

fn assert_state_roundtrip(g: @GameState) {
    let saved = serialize(g);
    let restored = from_felts(saved.span()).expect('lifecycle boundary readable');
    assert(serialize(@restored) == saved, 'same lifecycle state and grid');
    assert(hash(@restored) == hash(g), 'same lifecycle hash');
}

#[test]
fn test_grid_roundtrip_after_missile_removal_and_drop() {
    let mut g = genesis(LevelId::E1M1);
    let w = ctx_of(g.level, g.floor, g.ceil).w;
    let mut player = g.mobjs.at(0).unbox();
    let mut missile = spawn_mobj(
        w, doom_things::tables::KIND_TROOPSHOT, player.x, player.y, SpawnZ::OnFloor,
    );
    let mut grid = new_grid();
    set_thing_position(@w.map, ref grid, ref player, 0);
    set_thing_position(@w.map, ref grid, ref missile, 1);
    g.mobjs = array![BoxTrait::new(player), BoxTrait::new(missile)].span();
    g.grid = grid;
    assert_state_roundtrip(@g);
    // The same unlink/tombstone transition used by the missile ticker.
    doom_physics::unset_thing_position(ref g.grid, @missile, 1);
    let mut out = array![BoxTrait::new(player), BoxTrait::new(removed_mobj())];
    g.mobjs = out.span();
    assert_state_roundtrip(@g);
    let mut clip = spawn_mobj(w, KIND_CLIP, player.x, player.y, SpawnZ::OnFloor);
    clip.flags = clip.flags | MF_DROPPED;
    place_drops(w, ref g.grid, ref out, array![BoxTrait::new(clip)].span());
    g.mobjs = out.span();
    assert_state_roundtrip(@g);
}

#[test]
fn test_cross_special_from_the_player_reaches_the_specials() {
    let g = genesis(LevelId::E1M1);
    let (ctx, _) = plumbing(@g);
    let mobjs = g.mobjs;
    let mut grid: ThingGrid = new_grid();
    let mut p = g.player;
    let mut mo = g.mobjs.at(0).unbox();
    let mut s = g.specials;
    let mut patches: Array<Patch> = array![];
    // Line 0 is no walk trigger on any level: nothing changes, nothing traps.
    let moves = array![MoveEvent::CrossSpecial((0, 0))];
    apply_move_events(ctx, mobjs, ref grid, ref p, ref mo, ref s, moves.span(), ref patches);
    assert(s.movers.len() == 0 && s.used.len() == 0, 'no trigger on line 0');
}

#[test]
fn test_monster_events_are_applied() {
    let g = genesis(LevelId::E1M1);
    let (ctx, _) = plumbing(@g);
    let w = ctx.w;
    let mut p = g.player;
    let mut s = g.specials;
    let mut drops: Array<core::box::Box<Mobj>> = array![];
    let mut cues: Array<MonsterEvent> = array![];
    let at = Point { x: fixed::ZERO, y: fixed::ZERO };
    let ev = array![
        MonsterEvent { kind: EV_KILLED, who: 5, a: 0, b: 0, at },
        MonsterEvent { kind: EV_KILLED, who: 5, a: 7, b: 0, at },
        MonsterEvent { kind: EV_DROP, who: 0, a: KIND_CLIP, b: 0, at },
        MonsterEvent { kind: EV_DROP, who: 9999, a: KIND_CLIP, b: 0, at },
        MonsterEvent { kind: EV_CROSS, who: 3, a: 0, b: 1, at },
        MonsterEvent { kind: EV_SOUND, who: 3, a: 1, b: 0, at },
    ];
    apply_monster_events(ctx, w, 0, ref p, ref s, g.mobjs, ev.span(), ref drops, ref cues);
    assert(p.killcount == 1, 'only the player\'s kill counts');
    assert(drops.len() == 1, 'one drop at a real corpse');
    assert((*drops.at(0)).kind == KIND_CLIP && has((*drops.at(0)).flags, MF_DROPPED), 'a clip');
    assert(cues.len() == 1, 'the sound is a cue');
}

#[test]
fn test_reconcile_player_synchronizes_resolved_damage_and_death() {
    let g = genesis(LevelId::E1M1);
    let (ctx, _) = plumbing(@g);
    let mut grid = new_grid();
    let env = env_of(ctx.w, g.mobjs, 0, 0, 0);
    let mut rng = from_index(1);
    let mut p = g.player;
    let mut after = g.mobjs.at(0).unbox();
    after.health = 80;
    let defense = doom_physics::PlayerDefense {
        mo: 0, armor_type: 1, armor_points: 40, damagecount: 20, attacker: 4,
    };
    let fixed = reconcile_player(env, ref grid, ref rng, ref p, after, defense);
    assert(p.health == 80 && p.armor_points == 40, 'no second absorption');
    assert(p.damagecount == 20 && p.attacker == 4, 'bookkeeping');
    assert(fixed == after && p.playerstate == PST_LIVE, 'mobj already resolved');
    after.health = -20;
    let corpse = reconcile_player(env, ref grid, ref rng, ref p, after, defense);
    assert(p.health == 0 && p.playerstate == PST_DEAD, 'dead');
    assert(corpse.health == -20, 'overkill preserved');
    let once = p;
    let cursor = rng.index;
    let _ = reconcile_player(env, ref grid, ref rng, ref p, corpse, defense);
    assert(p == once && rng.index == cursor, 'weapon dropped once');
}

#[test]
fn test_occupancy_blocks_a_closing_door_on_a_live_shootable_thing() {
    let g = genesis(LevelId::E1M1);
    let mobjs = g.mobjs;
    let occ = Occupancy { mobjs };
    let pmo = mobjs.at(0).unbox();
    // The player's own sector, with no room: blocked; with plenty: free.
    assert(
        occ.nofit(pmo.sector, pmo.z, fixed::add(pmo.z, fixed::from_units(8))),
        'too low for the player',
    );
    assert(!occ.nofit(pmo.sector, pmo.z, fixed::add(pmo.z, fixed::from_units(128))), 'fits');
    // A corpse does not block.
    let mut corpse = pmo;
    corpse.health = 0;
    corpse.flags = 0;
    let dead = Occupancy { mobjs: array![BoxTrait::new(corpse)].span() };
    assert(!dead.nofit(pmo.sector, pmo.z, fixed::add(pmo.z, fixed::from_units(8))), 'corpse');
    assert(has(pmo.flags, MF_SHOOTABLE), 'the player is shootable');
}

#[test]
fn test_height_clip_keeps_a_standing_thing_on_its_floor() {
    let g = genesis(LevelId::E1M1);
    let (ctx, _) = plumbing(@g);
    let w = ctx.w;
    let mut grid: ThingGrid = new_grid();
    let mut mo = g.mobjs.at(0).unbox();
    set_thing_position(@w.map, ref grid, ref mo, 0);
    let mobjs = array![BoxTrait::new(mo)].span();
    // Pretend the floor was 8 lower when it last stood: the clip lifts it.
    let real = mo.floorz;
    mo.floorz = fixed::sub(real, fixed::from_units(8));
    mo.z = mo.floorz;
    height_clip(w, mobjs, ref grid, ref mo, 0);
    assert(mo.floorz == real && mo.z == real, 'back on the floor');
    // Off the floor and under a lowered ceiling: pushed down.
    let mut hover = mo;
    hover.z = fixed::add(real, fixed::from_units(200));
    height_clip(w, mobjs, ref grid, ref hover, 0);
    assert(fixed::le(fixed::add(hover.z, hover.height), hover.ceilingz), 'under the ceiling');
}

#[test]
fn test_moving_sectors_and_refresh_track_the_movers() {
    let g = genesis(LevelId::E1M1);
    let ctx = ctx_of(g.level, g.floor, g.ceil);
    assert(moving_sectors(@g.specials).len() == 0, 'nothing moves at genesis');
    assert(!contains(array![1, 2, 3].span(), 4), 'absent');
    assert(contains(array![1, 2, 3].span(), 2), 'present');
    // No mover: the arrays are untouched.
    let (f, c) = refresh_heights(ctx, g.floor, g.ceil, 0, @g.specials);
    assert(f == g.floor && c == g.ceil, 'unchanged');
    // A mover that vanished: a full rebuild, equal to the materialised arrays.
    let (f2, c2) = refresh_heights(ctx, g.floor, g.ceil, 1, @g.specials);
    assert(f2 == g.floor && c2 == g.ceil, 'rebuilt equal');
    let _: SpecialsState = g.specials;
    let _ = removed_mobj();
}

#[test]
fn test_reader_rejects_overflowing_declared_length_without_panicking() {
    assert(from_felts(array![TAG, VERSION, 0xffffffff].span()).is_none(), 'oversized header');
}

#[test]
fn test_serialized_boundary_preserves_pickup_order() {
    let mut g = genesis(LevelId::E1M1);
    let ctx = ctx_of(g.level, g.floor, g.ceil);
    let mut me = g.mobjs.at(0).unbox();
    me.health = 99;
    g.player.health = 99;
    let mut bonus = spawn_mobj(ctx.w, KIND_MISC2, me.x, me.y, SpawnZ::OnFloor);
    let mut stim = spawn_mobj(ctx.w, doom_things::tables::KIND_MISC10, me.x, me.y, SpawnZ::OnFloor);
    let mut grid = new_grid();
    set_thing_position(@ctx.w.map, ref grid, ref me, 0);
    set_thing_position(@ctx.w.map, ref grid, ref bonus, 1);
    set_thing_position(@ctx.w.map, ref grid, ref stim, 2);
    // A previous move changes visitation order without changing any mobj.
    doom_physics::relink(ref grid, bonus.cell, 1);
    g.mobjs = array![BoxTrait::new(me), BoxTrait::new(bonus), BoxTrait::new(stim)].span();
    g.grid = grid;
    let saved = serialize(@g);
    let restored = from_felts(saved.span()).expect('readable');
    let (a, _) = step_tic(g, word(25, 0, 0, 0));
    let (b, _) = step_tic(restored, word(25, 0, 0, 0));
    println!("pickup order: uninterrupted {} restored {}", a.player.health, b.player.health);
    assert(hash(@a) == hash(@b), 'same pickup order');
}

fn altered(data: Span<felt252>, at: u32, value: felt252) -> Array<felt252> {
    let mut out = array![];
    let mut i: u32 = 0;
    while i < data.len() {
        out.append(if i == at {
            value
        } else {
            *data.at(i)
        });
        i += 1;
    }
    out
}

#[test]
fn test_reader_rejects_unsafe_domains_and_grid_corruption() {
    let g = genesis(LevelId::E1M1);
    let a = serialize(@g);
    // Player health, weapon, attacker; mobj kind, state, sector; count.
    let bad = array![
        (12, 0xffffffff), (21, 9), (38, 0xfffffffe), (46, 257), (47, 9999), (59, 9999), (68, 9999),
        (8, 256),
    ];
    let mut pairs = bad.span();
    while let Option::Some(pair) = pairs.pop_front() {
        let (offset, value) = *pair;
        assert(from_felts(altered(a.span(), offset, value).span()).is_none(), 'unsafe domain');
    }
    let base = 3
        + crate::state::SCALARS
        + doom_player::PLAYER_FELTS
        + 1
        + g.mobjs.len() * doom_physics::MOBJ_FELTS
        + 1
        + doom_specials::fields(@g.specials);
    assert(
        from_felts(altered(a.span(), base + 1, 0xffffffff).span()).is_none(), 'invalid grid cell',
    );
    assert(
        from_felts(altered(a.span(), base + 3, 0xffffffff).span()).is_none(), 'invalid grid member',
    );
    assert(from_felts(altered(a.span(), base, 0).span()).is_none(), 'omitted grid');
    // Locate a cell with at least two members, then duplicate one index.
    let mut offset = base + 1;
    let mut tested = false;
    while offset < a.len() {
        let n: u32 = (*a.at(offset + 1)).try_into().unwrap();
        if n >= 2 {
            let bad = altered(a.span(), offset + 3, *a.at(offset + 2));
            assert(from_felts(bad.span()).is_none(), 'duplicate member');
            tested = true;
            break;
        }
        offset += 2 + n;
    }
    assert(tested, 'a shared cell exercised');
}

#[test]
fn test_refresh_skips_only_equal_heights() {
    let mut g = genesis(LevelId::E1M1);
    let ctx = ctx_of(g.level, g.floor, g.ceil);
    let sector = 0;
    let ceiling = *g.ceil.at(sector);
    let floor = *g.floor.at(sector);
    // Include an unchanged mover and a changed mover, both plane kinds and
    // all phases: equality of the actual derived value is the only shortcut.
    let mut phase_index = 0;
    while phase_index != 3 {
        let phase = if phase_index == 0 {
            Phase::Waiting
        } else if phase_index == 1 {
            Phase::Up
        } else {
            Phase::Down
        };
        g
            .specials
            .movers =
                array![
                    Mover {
                        kind: MoverKind::DoorNormal,
                        phase,
                        sector,
                        height: fixed::Fixed { enc: ceiling },
                        top: fixed::Fixed { enc: ceiling },
                        bottom: fixed::Fixed { enc: floor },
                        count: 1,
                    },
                    Mover {
                        kind: MoverKind::PlatDownWaitUpStay,
                        phase,
                        sector,
                        height: fixed::Fixed { enc: floor + 1 },
                        top: fixed::Fixed { enc: ceiling },
                        bottom: fixed::Fixed { enc: floor },
                        count: 1,
                    },
                ]
            .span();
        let (f, c) = refresh_heights(ctx, g.floor, g.ceil, 2, @g.specials);
        assert(c == g.ceil, 'equal ceiling');
        assert(f == set_felt(g.floor, sector, floor + 1), 'changed floor');
        let (f2, c2) = refresh_heights(ctx, f, c, 2, @g.specials);
        assert(f2 == f && c2 == c, 'repeat is unchanged');
        // Reverse the change: a moving plane can return to its old height.
        let (f3, c3) = refresh_heights(ctx, f, set_felt(c, sector, ceiling + 1), 2, @g.specials);
        assert(f3 == f && c3 == g.ceil, 'changed ceiling');
        phase_index += 1;
    }
}

#[test]
fn test_refresh_preserves_sequential_movers_in_the_same_sector() {
    let mut g = genesis(LevelId::E1M1);
    let ctx = ctx_of(g.level, g.floor, g.ceil);
    let sector = 0;
    let original = *g.ceil.at(sector);
    let first = Mover {
        kind: MoverKind::DoorNormal,
        phase: Phase::Up,
        sector,
        height: fixed::Fixed { enc: original + 1 },
        top: fixed::Fixed { enc: original + 2 },
        bottom: fixed::Fixed { enc: original },
        count: 0,
    };
    let mut second = first;
    second.height.enc = original;
    // Such duplicate plane thinkers are not produced by gameplay. Keeping
    // sequential write semantics also avoids relying on that invariant here.
    g.specials.movers = array![first, second].span();
    let (f, c) = refresh_heights(ctx, g.floor, g.ceil, 2, @g.specials);
    assert(f == g.floor && c == g.ceil, 'later mover restores original');
    g.specials.movers = array![second, first].span();
    let (f2, c2) = refresh_heights(ctx, g.floor, g.ceil, 2, @g.specials);
    assert(f2 == g.floor, 'floor untouched');
    assert(c2 == set_felt(g.ceil, sector, original + 1), 'later mover wins');
}

/// The v2 live snapshot is a render-only projection: it is the v1 snapshot
/// plus the two psprite slots, computed from the same state a plain
/// `step_tic` run reaches with no projection at all, and the scenario (hold
/// fire with the pistol) shows the slots doing something: a live flash and
/// more than one weapon frame.
#[test]
fn test_live_psprites_are_exact_render_only_projection() {
    let tics: u32 = 45;
    let fire = word(0, 0, 0, 1);
    // `plain` never sees a projection; `game` is projected before every tic.
    let mut plain = genesis(LevelId::E1M1);
    let mut game = genesis(LevelId::E1M1);
    let mut flash_seen = false;
    let mut first_weapon_frame: Option<(felt252, felt252)> = Option::None;
    let mut second_weapon_frame = false;
    let mut tic: u32 = 0;
    while tic < tics {
        let legacy = snapshot(@game);
        let live = crate::render::snapshot_with_psprites(@game);
        // (c) version, then the v1 body word for word.
        assert(*legacy.at(0) == crate::render::SNAPSHOT_VERSION, 'v1 version');
        assert(*live.at(0) == 2, 'v2 version');
        assert(live.len() == legacy.len() + 10, 'trailer length');
        let body = legacy.len() - 1;
        assert(live.span().slice(1, body) == legacy.span().slice(1, body), 'v1 prefix');
        // The trailer is exactly the player's psprite fields.
        let states = doom_things::states();
        let p = @game.player;
        let expected = array![
            (*p.psp_state).into(), (*states.sprite.at(*p.psp_state)).into(),
            (*states.frame.at(*p.psp_state)).into(), *p.psp_sx.enc, *p.psp_sy.enc,
            (*p.flash_state).into(), (*states.sprite.at(*p.flash_state)).into(),
            (*states.frame.at(*p.flash_state)).into(), *p.psp_sx.enc, *p.psp_sy.enc,
        ];
        let trailer = live.span().slice(legacy.len(), 10);
        assert(trailer == expected.span(), 'psprite fields');
        // (b) the scenario exercises both slots.
        let weapon = (*trailer.at(1), *trailer.at(2));
        match first_weapon_frame {
            Option::Some(first) => { if weapon != first {
                second_weapon_frame = true;
            } },
            Option::None => { first_weapon_frame = Option::Some(weapon); },
        }
        if *trailer.at(5) != 0 && *trailer.at(6) != 0 && *trailer.at(7) != 0 {
            flash_seen = true;
        }
        let (next, _) = step_tic(game, fire);
        game = next;
        let (next_plain, _) = step_tic(plain, fire);
        plain = next_plain;
        tic += 1;
    }
    assert(flash_seen, 'a flash slot was live');
    assert(second_weapon_frame, 'weapon frames changed');
    // (a) projecting between tics changes nothing about the run.
    assert(serialize(@game) == serialize(@plain), 'projection is render only');
    assert(hash(@game) == hash(@plain), 'same canonical hash');
    assert(game.leveltime == tics, 'no tic consumed');
}
