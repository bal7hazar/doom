//! Spike S1 - throwaway Cairo prototype of a Doom tic on Freedoom E1M1.
//!
//! Not production code: it exists to produce steps/tic numbers and design
//! recommendations for the real crates (`fixed`, `bam`, `geom2d`, `bsp`,
//! `blockmap`, `doom_physics`).
//!
//! Executable entry point:
//!   main(scenario, n_tics, reject, cadence, three, dedup, bboxreject)
//!
//! scenario: 0 player only | 1 +5 dormant monsters | 2 +5 chasing monsters
//!           3 = 2 plus one hitscan every 10 tics
//! The five flags switch the R2 optimisations on and off one at a time.

pub mod ai;
pub mod bam;
pub mod blockmap;
pub mod bsp;
pub mod fixed;
pub mod game;
pub mod geom;
pub mod mapdata;
pub mod mapdata_packed;
pub mod mobj;
pub mod physics;
pub mod probe;
pub mod rng;
pub mod tables;

#[cfg(test)]
mod tests;

use game::run;
use mobj::opts_from;
use probe::probe_body;

#[executable]
fn main(
    scenario: u32,
    n_tics: u32,
    reject: u32,
    cadence: u32,
    three: u32,
    dedup: u32,
    bboxreject: u32,
    fastsector: u32,
) -> felt252 {
    run(scenario, n_tics, opts_from(reject, cadence, three, dedup, bboxreject, fastsector))
}

/// Differential subsystem harness (see `probe.cairo`).
#[executable]
fn probe_main(
    op: u32,
    n: u32,
    reject: u32,
    cadence: u32,
    three: u32,
    dedup: u32,
    bboxreject: u32,
    fastsector: u32,
) -> felt252 {
    probe_body(op, n, opts_from(reject, cadence, three, dedup, bboxreject, fastsector))
}
