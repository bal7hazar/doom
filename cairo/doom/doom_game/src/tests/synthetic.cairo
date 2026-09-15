// SPDX-License-Identifier: GPL-2.0-only
//! Level-independent glue tests: the state record, the readers, the status
//! rule, the ABORT paths, the event appliers on hand-built mobjs. They
//! assert no coordinate of E1M1, so `bench/coverage.py` runs them on
//! `doom_map`'s miniature level as well.

use doom_map::LevelId;
use doom_monsters::actors::scan;
use doom_monsters::{Ctx as MonsterCtx, EV_CROSS, EV_DROP, EV_KILLED, EV_SOUND, MonsterEvent, Patch};
use doom_physics::{
    Hit, MF_DROPPED, MF_NOBLOCKMAP, MF_SHOOTABLE, MF_SPECIAL, Mobj, MoveEvent, NO_CELL, NO_MOBJ,
    SpawnZ, ThingGrid, has, is_removed, new_grid, removed_mobj, set_thing_position, spawn_mobj,
};
use doom_player::{PST_DEAD, PST_LIVE, PlayerEvent, WP_CHAINSAW, env_of};
use doom_specials::state::{Mover, MoverKind, Phase, set_felt};
use doom_specials::{SectorBlocking, SpecialsState};
use doom_things::tables::{KIND_CLIP, KIND_MISC2, KIND_POSSESSED};
use fixed::Fixed;
use geom2d::Point;
use prng::from_index;
use segment::{Status, from_felts as output_from_felts, to_felts};
use ticcmd::{TicCmd, encode};
use crate::level::{
    SectorIndex, contains, ctx_of, moving_sectors, nofit_scan, occupancy_of, occupancy_scan,
    refresh_heights, things_of_sector,
};
use crate::tic::{
    apply_monster_events, apply_move_events, apply_player_events, clip_patches, clip_patches_scan,
    height_clip, place_drops, rebuild_list, reconcile_player,
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
    g.actors = scan(g.mobjs);
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
    g.actors = scan(g.mobjs);
    g.grid = grid;
    assert_state_roundtrip(@g);
    // The same unlink/tombstone transition used by the missile ticker.
    doom_physics::unset_thing_position(ref g.grid, @missile, 1);
    let mut out = array![BoxTrait::new(player), BoxTrait::new(removed_mobj())];
    g.mobjs = out.span();
    g.actors = scan(g.mobjs);
    assert_state_roundtrip(@g);
    let mut clip = spawn_mobj(w, KIND_CLIP, player.x, player.y, SpawnZ::OnFloor);
    clip.flags = clip.flags | MF_DROPPED;
    place_drops(w, ref g.grid, ref out, array![BoxTrait::new(clip)].span());
    g.mobjs = out.span();
    g.actors = scan(g.mobjs);
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
    let occ = occupancy_scan(mobjs);
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
    let dead = occupancy_scan(array![BoxTrait::new(corpse)].span());
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
    g.actors = scan(g.mobjs);
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

// ---------------------------------------------------------------------------
// O3: the clip and the occupancy by blockmap cells, against the scans
// ---------------------------------------------------------------------------

/// Two patch lists are the same patches in the same order.
fn assert_same_patches(mut a: Span<Patch>, mut b: Span<Patch>) {
    assert(a.len() == b.len(), 'same number of patches');
    while let Option::Some(x) = a.pop_front() {
        let y = b.pop_front().unwrap();
        assert(*x.idx == *y.idx, 'same slot');
        assert(x.mo.unbox() == y.mo.unbox(), 'same record');
    }
}

/// A roster that exercises every case the scan answers on: the genesis
/// things in their grid, a monster copy off the blockmap (`MF_NOBLOCKMAP`),
/// another with no cell, a removed slot whose stale `sector` is a clipping
/// sector, a damaged patch on a clipped monster, a pickup patch (removed)
/// on a clipped item still linked in the grid — and the clipping sectors
/// given twice (two movers on one sector). The clip and the occupancy read
/// off the cells must produce exactly what the scans produce.
fn o3_roster() -> (GameState, Array<Box<Mobj>>, ThingGrid, Span<u32>, Array<Patch>, u32, u32) {
    let g = genesis(LevelId::E1M1);
    let GameState {
        level,
        leveltime,
        status,
        noise,
        prng,
        mrng,
        player,
        mobjs,
        specials,
        floor,
        ceil,
        grid,
        actors: _,
    } = g;
    let me = player.mo;
    // Three monsters of different rooms and an item: their sectors move.
    let a: u32 = 5;
    let b: u32 = 20;
    let c: u32 = 40;
    let mut item: u32 = 0;
    let mut k: u32 = 1;
    while k != mobjs.len() {
        if has(mobjs.at(k).flags, MF_SPECIAL) && item == 0 {
            item = k;
        }
        k += 1;
    }
    assert(item != 0, 'an item to pick up');
    let sa = mobjs.at(a).sector;
    let sb = mobjs.at(b).sector;
    let sc = mobjs.at(c).sector;
    let si = mobjs.at(item).sector;
    let clip = array![sa, sb, 10, sc, si, sa].span();
    let mut roster: Array<Box<Mobj>> = array![];
    let mut src = mobjs;
    while let Option::Some(m) = src.pop_front() {
        roster.append(*m);
    }
    let n = roster.len();
    // Off the blockmap, in a clipping sector: the scan clips them, the grid
    // cannot find them (`Actors::off_grid` does).
    let mut ghost = mobjs.at(a).unbox();
    ghost.flags = ghost.flags | MF_NOBLOCKMAP;
    ghost.cell = NO_CELL;
    roster.append(BoxTrait::new(ghost));
    let mut far = mobjs.at(b).unbox();
    far.cell = NO_CELL;
    far.z = fixed::add(far.z, fixed::from_units(24));
    roster.append(BoxTrait::new(far));
    // A removed slot whose stale sector is clipping: skipped by both.
    let mut stale = removed_mobj();
    stale.sector = sc;
    roster.append(BoxTrait::new(stale));
    // The patches of the tic so far: the player, monster `a` shot, the
    // item picked up (its slot removed while the grid still lists it).
    let mut hurt = mobjs.at(a).unbox();
    hurt.health = hurt.health - 3;
    let sorted = array![
        Patch { idx: me, mo: *mobjs.at(me) }, Patch { idx: a, mo: BoxTrait::new(hurt) },
        Patch { idx: item, mo: BoxTrait::new(removed_mobj()) },
    ];
    let back = GameState {
        level,
        leveltime,
        status,
        noise,
        prng,
        mrng,
        player,
        mobjs,
        specials,
        floor,
        ceil,
        grid: new_grid(),
        actors: scan(mobjs),
    };
    (back, roster, grid, clip, sorted, me, n)
}

#[test]
fn test_clip_by_cells_matches_the_scan_on_a_synthetic_roster() {
    let (g, roster, mut grid, clip, sorted, me, n) = o3_roster();
    let ctx = ctx_of(g.level, g.floor, g.ceil);
    let w = BoxTrait::new(ctx.w);
    let mobjs = roster.span();
    let index = SectorIndex { cells: ctx.m.s_cells, off_grid: scan(mobjs).off_grid };
    assert(index.off_grid == array![n, n + 1].span(), 'two slots off the grid');
    let mut sorted_a: Array<Patch> = array![];
    let mut sorted_b: Array<Patch> = array![];
    let mut ps = sorted.span();
    while let Option::Some(p) = ps.pop_front() {
        sorted_a.append(*p);
        sorted_b.append(*p);
    }
    let expected = clip_patches_scan(w, mobjs, ref grid, sorted_a, clip, me);
    let got = clip_patches(w, mobjs, ref grid, sorted_b, clip, me, index);
    assert_same_patches(expected.span(), got.span());
    // The clip did something: the off-grid pair, the hurt monster (its
    // patch composed), the two other monsters and the item's neighbours.
    assert(expected.len() > sorted.len() + 4, 'things were clipped');
    let mut seen_ghost = false;
    let mut seen_far = false;
    let mut seen_item = false;
    let mut hurt_composed = false;
    let mut es = expected.span();
    while let Option::Some(p) = es.pop_front() {
        if *p.idx == n {
            seen_ghost = true;
        }
        if *p.idx == n + 1 {
            // Lifted off its floor before the clip: `P_ThingHeightClip`
            // leaves a hovering thing off the floor (under the ceiling).
            seen_far = true;
            assert(p.mo.z != p.mo.floorz, 'hovering');
        }
        if *p.idx == n + 2 {
            assert(false, 'a removed slot is never clipped');
        }
        if *p.idx == 5 {
            hurt_composed = p.mo.health == mobjs.at(5).health - 3;
        }
        if *p.idx == g.player.mo {
            assert(p.mo.unbox() == mobjs.at(g.player.mo).unbox(), 'the player is not clipped');
        }
        let picked = *p.idx != me && is_removed(@p.mo.unbox());
        if picked {
            seen_item = true;
        }
    }
    assert(seen_ghost && seen_far, 'off-grid things clipped');
    assert(hurt_composed, 'the patch was clipped');
    assert(seen_item, 'the pickup patch is kept as is');
}

#[test]
fn test_occupancy_by_cells_matches_the_scan_on_a_synthetic_roster() {
    let (g, roster, mut grid, clip, _, me, n) = o3_roster();
    let ctx = ctx_of(g.level, g.floor, g.ceil);
    let mobjs = roster.span();
    let index = SectorIndex { cells: ctx.m.s_cells, off_grid: scan(mobjs).off_grid };
    // One mover per clipping sector, the player's sector too (it blocks
    // by index), and a sector with nothing in it.
    let pmo = mobjs.at(me).unbox();
    let mut sectors: Array<u32> = array![pmo.sector, 3];
    sectors.append_span(clip);
    let mut movers: Array<Mover> = array![];
    let mut ss = sectors.span();
    while let Option::Some(s) = ss.pop_front() {
        movers
            .append(
                Mover {
                    kind: MoverKind::DoorNormal,
                    phase: Phase::Down,
                    sector: *s,
                    height: fixed::ZERO,
                    top: fixed::ZERO,
                    bottom: fixed::ZERO,
                    count: 0,
                },
            );
    }
    let mut specials = g.specials;
    specials.movers = movers.span();
    let occ = occupancy_of(ref grid, mobjs, me, ctx.w.map.grid, index, @specials);
    assert(occ.sectors.len() == movers.len(), 'one list per mover');
    let rooms = array![0, 8, 24, 40, 55, 56, 57, 64, 128].span();
    let mut asked: u32 = 0;
    let mut blocked: u32 = 0;
    let mut ss = sectors.span();
    while let Option::Some(s) = ss.pop_front() {
        let floor = Fixed { enc: *g.floor.at(*s) };
        let mut rs = rooms;
        while let Option::Some(r) = rs.pop_front() {
            let room = fixed::from_units(*r);
            let expected = nofit_scan(mobjs, *s, room);
            assert(occ.nofit(*s, floor, fixed::add(floor, room)) == expected, 'same verdict');
            asked += 1;
            if expected {
                blocked += 1;
            }
        }
    }
    assert(asked == 9 * sectors.len() && blocked != 0 && blocked != asked, 'both verdicts met');
    // The off-grid monster blocks too, through `off_grid`; a sector no list
    // was gathered for holds nothing.
    let sb = mobjs.at(20).sector;
    assert(occ.nofit(sb, fixed::ZERO, fixed::from_units(8)), 'blocked');
    let mut only_far: Array<Box<Mobj>> = array![];
    let mut k: u32 = 0;
    while k != mobjs.len() {
        only_far.append(if k == n + 1 {
            *mobjs.at(k)
        } else {
            BoxTrait::new(removed_mobj())
        });
        k += 1;
    }
    let far_index = SectorIndex { cells: ctx.m.s_cells, off_grid: scan(only_far.span()).off_grid };
    assert(far_index.off_grid == array![n + 1].span(), 'the far one only');
    let far_occ = occupancy_of(ref grid, only_far.span(), me, ctx.w.map.grid, far_index, @specials);
    assert(far_occ.nofit(sb, fixed::ZERO, fixed::from_units(8)), 'off-grid blocks');
    assert(!far_occ.nofit(sb, fixed::ZERO, fixed::from_units(128)), 'off-grid fits');
    assert(nofit_scan(only_far.span(), sb, fixed::from_units(8)), 'the scan agrees');
    assert(!occ.nofit(181, fixed::ZERO, fixed::ZERO), 'unlisted: nothing');
}

#[test]
fn test_things_of_sector_walks_the_cells_of_the_range() {
    // Every genesis thing is found by the walk of its own sector's range,
    // and the walk of an empty range (past the table) finds nothing.
    let g = genesis(LevelId::E1M1);
    let GameState { level, floor, ceil, mobjs, grid, .. } = g;
    let mut grid = grid;
    let ctx = ctx_of(level, floor, ceil);
    let mut k: u32 = 0;
    let mut found_total: u32 = 0;
    while k != mobjs.len() {
        let m = mobjs.at(k);
        let things = things_of_sector(ref grid, ctx.m.s_cells, ctx.w.map.grid, m.sector);
        assert(contains(things, k), 'found in its sector range');
        found_total += things.len();
        k += 1;
    }
    // The walks visit far fewer candidates than the scans read (210 slots
    // per clipped sector): about a fifth, the big outdoor sector included.
    println!("things_of_sector: {} candidates over {} walks", found_total, mobjs.len());
    assert(found_total * 4 < mobjs.len() * mobjs.len(), 'small candidate sets');
    let none = things_of_sector(ref grid, ctx.m.s_cells, ctx.w.map.grid, 5000);
    assert(none.len() == 0, 'past the table: nothing');
    let empty = things_of_sector(ref grid, array![].span(), ctx.w.map.grid, 0);
    assert(empty.len() == 0, 'no table: nothing');
}

#[test]
fn test_off_grid_slots_are_the_noblockmap_things() {
    // Every live slot Doom does not link into the blockmap (`MF_NOBLOCKMAP`:
    // on E1M1 the missiles in flight; nothing collides with them) is in
    // the derived index for the cell walk to visit — the scan of a moving
    // sector clipped them — and no other live slot is. Genesis links every
    // thing; a fireball spawned at the player's feet is off the grid.
    let mut g = genesis(LevelId::E1M1);
    assert(g.actors.off_grid.len() == 0, 'genesis links everything');
    let w = ctx_of(g.level, g.floor, g.ceil).w;
    let player = g.mobjs.at(0).unbox();
    let mut ball = spawn_mobj(
        w, doom_things::tables::KIND_TROOPSHOT, player.x, player.y, SpawnZ::OnFloor,
    );
    assert(has(ball.flags, MF_NOBLOCKMAP), 'a missile is NOBLOCKMAP');
    let mut roster: Array<Box<Mobj>> = array![];
    let mut src = g.mobjs;
    while let Option::Some(m) = src.pop_front() {
        roster.append(*m);
    }
    set_thing_position(@w.map, ref g.grid, ref ball, roster.len());
    roster.append(BoxTrait::new(ball));
    g.mobjs = roster.span();
    g.actors = scan(g.mobjs);
    let off = g.actors.off_grid;
    assert(off == array![g.mobjs.len() - 1].span(), 'the fireball only');
    let mut k: u32 = 0;
    let mut listed: u32 = 0;
    while k != g.mobjs.len() {
        let m = g.mobjs.at(k);
        let unlinked = !is_removed(m.as_snapshot().unbox())
            && !doom_physics::in_blockmap(m.as_snapshot().unbox());
        if unlinked {
            assert(has(m.flags, MF_NOBLOCKMAP), 'off the grid by its flag');
            assert(contains(off, k), 'listed');
            listed += 1;
        } else {
            assert(!contains(off, k), 'not listed');
        }
        k += 1;
    }
    assert(listed == off.len(), 'exactly the unlinked slots');
    assert_state_roundtrip(@g);
}

