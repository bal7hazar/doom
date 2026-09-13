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
pub mod event;
pub mod tables;

#[cfg(test)]
mod tests;
pub mod think;
use doom_physics::{Mobj, World};
pub use event::{
    EV_BLOOD, EV_CROSS, EV_DROP, EV_KILLED, EV_PUFF, EV_SOUND, EV_USE, EV_WAKE, MonsterEvent,
};
pub use think::{awake_count, in_window, is_awake, is_dormant, mobj_thinker, monsters_ticker};

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
    pub mo: Mobj,
}

/// The read-only half of a tic: everything an action needs besides the mobj
/// it is running on.
#[derive(Copy, Drop)]
pub struct Ctx {
    pub w: World,
    /// The mobj indices of the players (one, in a single-player run).
    pub players: Span<u32>,
    pub noise: Noise,
    pub tic: u32,
}

/// Mobj `i` as it stands *now*: the pending patch if the tic has already
/// rewritten it, the list otherwise. The patch list holds at most a handful
/// of entries per tic, so the scan is cheaper than any index.
pub fn read_mobj(mobjs: Span<Mobj>, patches: Span<Patch>, i: u32) -> Mobj {
    let n = patches.len();
    let mut k: u32 = 0;
    let mut found = *mobjs.at(i);
    while k != n {
        let p = *patches.at(k);
        if p.idx == i {
            found = p.mo;
        }
        k += 1;
    }
    found
}
