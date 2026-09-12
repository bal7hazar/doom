// SPDX-License-Identifier: GPL-2.0-only
//! **Transitional.** The Phase-0 skeleton's hand-written `Level` (one sector,
//! one linedef, both in `Array`s), kept only because `doom_physics`,
//! `doom_player`, `doom_monsters`, `doom_specials`, `doom_game` and
//! `doom_run` still import `doom_map::{Level, Sector, LineDef, sample_level,
//! sector_at, is_line_blocking}`.
//!
//! Nothing here is used by the real level data: the compiled-in map lives in
//! `super::levels` and is read through `super::LevelMap`. This module is the
//! `doom_map` half of the D17 clean-up (which also deletes `fsm::compat` and
//! `prng::compat`) and disappears with P1.6, the PR that ports
//! `doom_physics`/`doom_player`/`doom_monsters` onto `LevelMap`.

use geom2d::Point;

#[derive(Copy, Drop, Serde, PartialEq, Debug)]
pub struct Sector {
    pub floor_height: i64,
    pub ceiling_height: i64,
    pub light_level: u8,
}

#[derive(Copy, Drop, Serde, PartialEq, Debug)]
pub struct LineDef {
    pub a: Point,
    pub b: Point,
    pub blocking: bool,
}

#[derive(Drop, Serde)]
pub struct Level {
    pub sectors: Array<Sector>,
    pub lines: Array<LineDef>,
}

/// Panics only if `id >= level.sectors.len()` (a caller bug, not a runtime
/// game condition -- ids are always derived from the same static level).
pub fn sector_at(level: @Level, id: u32) -> Sector {
    *level.sectors.at(id)
}

pub fn is_line_blocking(level: @Level, id: u32) -> bool {
    *level.lines.at(id).blocking
}

/// A tiny fixture level (one sector, one blocking line).
pub fn sample_level() -> Level {
    let mut sectors = array![];
    // 128 map units as a raw 16.16 value: `fixed::Fixed` is an offset-encoded
    // felt (`enc`), so the raw value is spelled out here rather than read out
    // of a `Fixed`.
    sectors.append(Sector { floor_height: 0, ceiling_height: 128 * 65536, light_level: 200 });

    let mut lines = array![];
    lines
        .append(
            LineDef {
                a: Point { x: fixed::from_int(0), y: fixed::from_int(0) },
                b: Point { x: fixed::from_int(64), y: fixed::from_int(0) },
                blocking: true,
            },
        );

    Level { sectors, lines }
}
