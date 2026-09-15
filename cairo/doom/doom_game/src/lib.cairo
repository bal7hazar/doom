// SPDX-License-Identifier: GPL-2.0-only
//! `doom_game` — the whole game, assembled: one `GameState`, `genesis`,
//! `step_tic`, the canonical serialization/hash (D16), the `SegmentEngine`
//! (D15) that lets `segment::run_segment` drive it, and the render snapshot
//! the real-time Worker publishes every tic.
//!
//! This crate owns no rule. Every rule lives one crate down (`doom_player`,
//! `doom_physics`, `doom_monsters`, `doom_specials`); what lives here is the
//! **order** in which they run inside a tic (`tic.cairo`, documented in the
//! README), the application of the events they report to the mobj list,
//! and the state record they all share.

pub mod engine;
pub mod level;
pub mod render;
pub mod setup;
pub mod state;
#[cfg(test)]
mod tests;
pub mod tic;

pub use engine::{GameEngine, run_segment, stats_of};
pub use level::{
    Ctx, Occupancy, SectorIndex, TOTAL_ITEMS, TOTAL_KILLS, TOTAL_SECRETS, ctx_of, no_index,
    occupancy_of, occupancy_scan,
};
pub use render::{
    MOBJ_WORDS, PLAYER_WORDS, SECTOR_WORDS, SNAPSHOT_HEADER, SNAPSHOT_VERSION, STATS_WORDS,
    snapshot,
};
pub use setup::{genesis, status_from, status_of};
pub use state::{GameState, SCALARS, TAG, VERSION, fields, from_felts, hash, serialize};
pub use tic::step_tic;
