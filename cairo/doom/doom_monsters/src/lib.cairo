// SPDX-License-Identifier: GPL-2.0-only
//! The monster AI of a Doom-like tic — the `p_enemy.c` half of
//! linuxdoom-1.10 (GPL-2.0-only; semantics derived, no C copied) — for the
//! five kinds Freedoom E1M1 can put in front of the player: the zombieman,
//! the shotgun guy, the imp, the demon and the spectre.
//!
//! # Shape
//!
//! * A monster is a `doom_physics::Mobj`. This crate reads and writes the
//!   AI fields Doom keeps on one (`target`, `threshold`, `move_dir`,
//!   `move_count`, `reaction_time`, `flags`, `state`, `tics`) and asks
//!   `doom_physics` for everything geometric.
//! * A state carries an **action id** (`doom_things`), not a function
//!   pointer; [`think::mobj_thinker`] counts the state's `tics` down through
//!   `fsm::advance` and dispatches that id in a single `match` (D15).
//! * Nothing this crate does to another mobj is written in place: a damaged
//!   target, a dropped item, a spawned fireball come back as a [`Patch`] or
//!   a [`MonsterEvent`], and [`monsters_ticker`] applies the patches in one
//!   rebuild at the end of the tic (the `doom_physics` README's rule).
//!
//! # Scheduling (docs/G0.md D3)
//!
//! [`monsters_ticker`] is the whole tic. Per tic, and by construction:
//!
//! * **every** monster and missile runs `P_XYMovement` and `P_ZMovement`
//!   and counts its state down — movement is never skipped, or a
//!   de-scheduled monster would freeze in mid-fall;
//! * a **dormant** monster (one whose state's action is `A_Look`) runs
//!   `A_Look` only on the tics where `tic % 4 == id % 4`
//!   ([`LOOK_CADENCE`], R2-A3), so the four phases spread the crate's
//!   only unbounded cost — a sight traversal — across four tics;
//! * an **awake** monster runs `A_Chase` only inside a round-robin window
//!   of [`WINDOW`] = 8 (D3). The window is a pure function of `tic` and of
//!   the awake set at the start of the tic: see [`think::in_window`].
//!
//! Sight always goes through `doom_physics::check_sight_cached` with
//! [`SIGHT_TTL`] = 8 tics (R2-A3), which is what keeps a chase step off the
//! 7 000–10 000-step traversal path on all but one tic in eight.

pub mod actions;
pub mod actors;
pub mod event;
pub mod tables;

#[cfg(test)]
mod tests;
pub mod think;
pub use actors::Actors;
use doom_physics::{Mobj, World, maputl};
pub use event::{
    EV_BLOOD, EV_CROSS, EV_DROP, EV_KILLED, EV_PUFF, EV_SOUND, EV_USE, EV_WAKE, MonsterEvent,
};
pub use think::{
    awake_count, awake_count_in, in_window, is_awake, is_dormant, mobj_thinker, monsters_ticker,
    monsters_ticker_indexed, monsters_ticker_with_defense,
};

/// How many tics a sight verdict is cached for (R2-A3; the `doom_physics`
/// README asks `doom_monsters` for `ttl >= 8`).
pub const SIGHT_TTL: u32 = 8;

/// `A_Look` runs on one tic in four, phased by the mobj's own index so that
/// the dormant monsters of a map do not all look on the same tic (D3).
pub const LOOK_CADENCE: u32 = 4;

/// How many awake monsters `A_Chase` on one tic (D3).
pub const WINDOW: u32 = 8;

/// Where the last noise was made, Doom's per-sector `soundtarget` reduced to
/// the one fact a single-player run needs.
///
/// `doom_game` sets it when the player fires (`P_NoiseAlert`) and clears it
/// with `silence()`. Which monsters hear it is
/// [`actions`]' business — see the README for why the REJECT row answers
/// that question here instead of a flood over the sector graph.
#[derive(Copy, Drop, Serde, PartialEq, Debug, Default)]
pub struct Noise {
    /// The mobj that made the noise, or `doom_physics::NO_MOBJ`.
    pub source: u32,
    /// The sector it was made in.
    pub sector: u32,
}

/// No noise: nothing has been fired.
pub fn silence() -> Noise {
    Noise { source: doom_physics::NO_MOBJ, sector: 0 }
}

/// A write to a mobj the ticker's pass has already gone past (a damaged
/// target, a fireball claiming a free slot), applied in one rebuild at the
/// end of the tic.
#[derive(Copy, Drop)]
pub struct Patch {
    pub idx: u32,
    pub mo: Box<Mobj>,
}

/// The read-only half of a tic: everything an action needs besides the mobj
/// it is running on.
///
/// This is the **public boundary** type; inside the crate every call carries
/// the one-pointer [`Env`] instead (see it for why).
#[derive(Copy, Drop)]
pub struct Ctx {
    pub w: World,
    /// The mobj indices of the players (one, in a single-player run).
    pub players: Span<u32>,
    pub noise: Noise,
    pub tic: u32,
}

/// Payload of the crate's read-only context: six felts with the 67-felt
/// [`World`] behind one pointer. [`Env`] boxes this payload too, so loops
/// and calls carry one pointer rather than copying its six felts.
///
/// docs/spikes/S7.md §8 rule 3: a struct pushed at a call costs one word of
/// bytecode and one step per felt, a `Box` costs one, and reading a field
/// through a box is free. A `Ctx` crossing the six call levels of the
/// dispatcher chain (`monsters_ticker` → `mobj_thinker` → `think_state` →
/// `run_chain` → `dispatch` → an action → `p_move`) was 4 980 words of
/// `store_temp<Ctx>` and ~430 steps per thinking monster per tic. The
/// `World` is rebuilt on the stack only where `doom_physics` asks for one,
/// which is where those felts had to be pushed anyway.
#[derive(Copy, Drop)]
pub(crate) struct EnvData {
    pub w: Box<World>,
    pub players: Span<u32>,
    pub noise: Noise,
    pub tic: u32,
}

/// Read-only context passed through the entire action chain as one felt.
pub(crate) type Env = Box<EnvData>;

/// The [`Env`] of a public [`Ctx`], at the one boundary that pays for it.
#[inline(always)]
pub(crate) fn env_of(ctx: Ctx) -> Env {
    BoxTrait::new(
        EnvData { w: BoxTrait::new(ctx.w), players: ctx.players, noise: ctx.noise, tic: ctx.tic },
    )
}

/// Slot `i` of the list, or a removed slot past its end.
///
/// `get` + `match` instead of `at`: an `at` is a panic site, and a panic
/// site costs the enclosing function its whole return width in bytecode and
/// makes every caller up the stack panicking too (S7 §8 rule 1). `i` is
/// always in range here — every caller has compared it with `mobjs.len()`.
///
/// The existing one-felt box is returned without materialising the record.
/// Only an out-of-range lookup constructs a removed slot.
#[inline(always)]
pub fn mobj_at(mobjs: Span<Box<Mobj>>, i: u32) -> Box<Mobj> {
    match mobjs.get(i) {
        Option::Some(b) => *b.unbox(),
        Option::None => BoxTrait::new(doom_physics::removed_mobj()),
    }
}

/// Mobj `i` as it stands *now*: the pending patch if the tic has already
/// rewritten it, the list otherwise. The patch list holds at most a handful
/// of entries per tic, so the scan is cheaper than any index.
pub fn read_mobj(mobjs: Span<Box<Mobj>>, patches: Span<Patch>, i: u32) -> Box<Mobj> {
    read_boxed(mobjs, patches, i)
}

/// Shared ordered scan behind [`read_mobj`]. Both roster and patches retain
/// their original boxes; the last matching patch wins without allocating
/// another actor record (S7 §8 rules 3 and 4).
pub(crate) fn read_boxed(mobjs: Span<Box<Mobj>>, patches: Span<Patch>, i: u32) -> Box<Mobj> {
    let n = patches.len();
    // `opaque_zero`, not `0`: a literal as a loop-carried start makes the
    // compiler emit a second, specialised copy of the loop body (S7 §8
    // rule 4).
    let mut k: u32 = maputl::opaque_zero(n);
    let mut found = mobj_at(mobjs, i);
    while k != n {
        match patches.get(k) {
            Option::Some(b) => {
                let p = *b.unbox();
                if p.idx == i {
                    found = p.mo;
                }
            },
            Option::None => {},
        }
        k = maputl::inc(k);
    }
    found
}
