// SPDX-License-Identifier: GPL-2.0-only
//! Opaque mover-height refresh: mode 0 unchanged ceiling, 1 changed ceiling,
//! 2 unchanged floor, 3 changed floor. Return every height for comparison.
use doom_game::level::refresh_heights;
use doom_game::{ctx_of, genesis};
use doom_map::LevelId;
use doom_specials::state::{Mover, MoverKind, Phase};
use fixed::Fixed;

#[executable]
fn main(n: u32, sector: u32, mode: u32) -> (Span<felt252>, Span<felt252>) {
    let mut g = genesis(LevelId::E1M1);
    let ctx = ctx_of(g.level, g.floor, g.ceil);
    let floor_mode = mode >= 2;
    let source = if floor_mode {
        g.floor
    } else {
        g.ceil
    };
    let height = *source.at(sector) + (mode % 2).into();
    g
        .specials
        .movers =
            array![
                Mover {
                    kind: if floor_mode {
                        MoverKind::PlatDownWaitUpStay
                    } else {
                        MoverKind::DoorNormal
                    },
                    phase: Phase::Waiting,
                    sector,
                    height: Fixed { enc: height },
                    top: Fixed { enc: height },
                    bottom: Fixed { enc: height },
                    count: n,
                },
            ]
        .span();
    let mut f = g.floor;
    let mut c = g.ceil;
    let mut i = 0;
    while i != n {
        // Reset the inputs each iteration: changed modes always change a value.
        let (nf, nc) = refresh_heights(ctx, g.floor, g.ceil, 1, @g.specials);
        f = nf;
        c = nc;
        i += 1;
    }
    (f, c)
}
