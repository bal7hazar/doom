// SPDX-License-Identifier: GPL-2.0-only

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

/// A tiny fixture level (one sector, one blocking line) standing in for the
/// real E1M1 extraction until `tools/wad` lands (PLAN.md §3.1, task 1).
pub fn sample_level() -> Level {
    let mut sectors = array![];
    // 128 map units as a raw 16.16 value: `fixed::Fixed` is now an
    // offset-encoded felt (`enc`), so the raw value is spelled out here
    // rather than read out of a `Fixed`.
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

#[cfg(test)]
mod tests {
    use super::{is_line_blocking, sample_level, sector_at};

    #[test]
    fn test_sector_at_reads_sample_data() {
        let level = sample_level();
        let sector = sector_at(@level, 0);
        assert(sector.floor_height == 0, 'floor height');
        assert(sector.light_level == 200, 'light level');
    }

    #[test]
    fn test_is_line_blocking() {
        let level = sample_level();
        assert(is_line_blocking(@level, 0), 'sample line blocks');
    }
}
