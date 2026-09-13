// SPDX-License-Identifier: GPL-2.0-only
//! Step-cost benchmark of a whole tic and of its subsystems on Freedoom
//! E1M1 (docs/spikes/S8-tic-profile.md).
//!
//! Differential measurement (S1 §3.1): `main(op, n)` builds a **scene** —
//! the state of one of the golden scenarios at a given tic, reached by
//! replaying its input log — then runs `op` `n` times; `measure.py` runs
//! `n` and `2n` and divides the difference, so the scene construction, the
//! bootstrap and the (de)serialization cancel. Ops that mutate the state
//! (a whole tic) run consecutive tics of the scenario's own log, so the
//! numbers are what those tics cost in a run.
//!
//! Scenes (`scene / 10`):
//!   0  idle:  tic 300 of the idle log (the player at the start, 29 dormant)
//!   1  walk:  tic 80 of the walk log (walking, one monster awake)
//!   2  fight: tic 300 of the fight log (11 awake, the pistol held)
//!   3  eight: the fight scene with the awake set cut to 8 (D3's cap exactly)
//!
//! Ops (`op % 10`):
//!   0  build the scene only (the baseline every other op is netted against)
//!   1  step_tic, consecutive tics of the log
//!   2  player_think alone (same word every time)
//!   3  monsters_ticker alone
//!   4  specials_ticker alone
//!   5  hash (open + append + seal)
//!   6  snapshot
//!   7  serialize + from_felts (a segment boundary's load)
//!   8  rebuild_list with one patch (the list pass)
//!   9  a step_tic on an idle word (no input) from the scene

use doom_game::{GameState, ctx_of, from_felts, genesis, hash, serialize, snapshot, step_tic};
use doom_map::LevelId;
use doom_monsters::{Patch, monsters_ticker, silence};
use doom_physics::{Mobj, set_state};
use doom_player::{PlayerEvent, env_of, player_think};
use doom_specials::specials_ticker;
use doom_things::tables::MI_SPAWNSTATE;
use prng::from_index;
use ticcmd::{TicCmd, encode};

fn word(forward: i64, side: i64, turn: i64, buttons: u8) -> felt252 {
    encode(TicCmd { forward, side, angle_turn: turn, buttons })
}

/// Expand `(tics, forward, side, turn, buttons)` segments into words — the
/// same logs as `src/tests/e1m1.cairo`.
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

fn idle_log() -> Array<felt252> {
    script(array![(700, 0, 0, 0, 0)].span())
}

fn walk_log() -> Array<felt252> {
    script(array![(110, 25, 0, 0, 0), (240, 0, 0, 0, 0)].span())
}

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

/// Replay `log` up to `tic` from genesis.
fn advance(log: Span<felt252>, tic: u32) -> GameState {
    let mut s = genesis(LevelId::E1M1);
    let mut k: u32 = 0;
    while k != tic {
        let (next, _) = step_tic(s, *log.at(k));
        s = next;
        k += 1;
    }
    s
}

/// Put every awake monster past the `keep`-th back to sleep (its spawn
/// state), so the round-robin window of 8 is exactly full.
fn cap_awake(state: GameState, keep: u32) -> GameState {
    let GameState {
        level, leveltime, status, noise, prng, mrng, player, mobjs, specials, floor, ceil, grid,
    } = state;
    let ctx = ctx_of(level, floor, ceil);
    let mut out: Array<Mobj> = array![];
    let mut ms = mobjs;
    let mut awake: u32 = 0;
    while let Option::Some(m) = ms.pop_front() {
        let mut mo = *m;
        if doom_monsters::is_awake(ctx.w, m) {
            awake += 1;
            if awake > keep {
                set_state(ctx.w, ref mo, *MI_SPAWNSTATE.span().at(mo.kind));
                mo.target = doom_physics::NO_MOBJ;
            }
        }
        out.append(mo);
    }
    GameState {
        level,
        leveltime,
        status,
        noise,
        prng,
        mrng,
        player,
        mobjs: out.span(),
        specials,
        floor,
        ceil,
        grid,
    }
}

fn scene(id: u32) -> (GameState, Span<felt252>, u32) {
    if id == 0 {
        let log = idle_log();
        (advance(log.span(), 300), log.span(), 300)
    } else if id == 1 {
        let log = walk_log();
        (advance(log.span(), 80), log.span(), 80)
    } else if id == 2 {
        let log = fight_log();
        (advance(log.span(), 300), log.span(), 300)
    } else {
        let log = fight_log();
        (cap_awake(advance(log.span(), 300), 8), log.span(), 300)
    }
}

#[executable]
fn main(op: u32, n: u32) -> felt252 {
    let (mut s, log, tic0) = scene(op / 10);
    let what = op % 10;
    let mut acc: felt252 = 0;
    let mut i: u32 = 0;
    if what == 0 {
        acc = hash(@s);
    } else if what == 1 {
        while i != n {
            let (next, _) = step_tic(s, *log.at(tic0 + i));
            s = next;
            i += 1;
        }
        acc = s.leveltime.into();
    } else if what == 2 {
        let ctx = ctx_of(s.level, s.floor, s.ceil);
        let w = *log.at(tic0);
        let cmd = ticcmd::decode(w);
        let mut g = doom_physics::rebuild(s.mobjs);
        let mut rng = from_index(1);
        while i != n {
            let mut p = s.player;
            let mut mo = *s.mobjs.at(0);
            let env = env_of(ctx.w, s.mobjs, 0, s.leveltime + i, cmd.buttons.into());
            let mut events: Array<PlayerEvent> = array![];
            player_think(env, ref g, ref rng, ref p, ref mo, w, 0, false, ref events);
            acc += p.viewz.enc + events.len().into();
            i += 1;
        }
    } else if what == 3 {
        let ctx = ctx_of(s.level, s.floor, s.ceil);
        let mut g = doom_physics::rebuild(s.mobjs);
        let players = array![0].span();
        let mut mobjs = s.mobjs;
        let mut rng = s.prng;
        while i != n {
            let (next, r, ev) = monsters_ticker(
                ctx.w, mobjs, ref g, players, s.noise, s.leveltime + i, rng,
            );
            mobjs = next.span();
            rng = r;
            acc += ev.len().into();
            i += 1;
        }
        acc += rng.index.into();
    } else if what == 4 {
        let ctx = ctx_of(s.level, s.floor, s.ceil);
        let occ = doom_game::Occupancy { mobjs: s.mobjs };
        let mut sp = s.specials;
        let mut rng = s.prng;
        while i != n {
            let (next, r, ev) = specials_ticker(
                @occ, sp, ctx.tables, s.leveltime + i, rng, ctx.w.rndtable,
            );
            sp = next;
            rng = r;
            acc += ev.len().into();
            i += 1;
        }
    } else if what == 5 {
        while i != n {
            acc += hash(@s);
            i += 1;
        }
    } else if what == 6 {
        while i != n {
            acc += snapshot(@s).len().into();
            i += 1;
        }
    } else if what == 7 {
        while i != n {
            let felts = serialize(@s);
            match from_felts(felts.span()) {
                Option::Some(back) => { acc += back.leveltime.into(); },
                Option::None => {},
            }
            i += 1;
        }
    } else if what == 8 {
        let ctx = ctx_of(s.level, s.floor, s.ceil);
        let mut g = doom_physics::rebuild(s.mobjs);
        let mo = *s.mobjs.at(0);
        let patch = array![Patch { idx: 1, mo: *s.mobjs.at(1) }];
        while i != n {
            let list = doom_game::tic::rebuild_list(
                ctx.w, s.mobjs, ref g, mo, 0, patch.span(), array![].span(),
            );
            acc += list.len().into();
            i += 1;
        }
    } else {
        let idle = word(0, 0, 0, 0);
        while i != n {
            let (next, _) = step_tic(s, idle);
            s = next;
            i += 1;
        }
        acc = s.leveltime.into();
    }
    let _ = silence();
    acc
}
