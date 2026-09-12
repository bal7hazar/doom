//! Differential subsystem harness.
//!
//! `probe(op, n, ...)` calls one subsystem `n` times in a loop.  Running it at
//! n = N and n = 2N and differencing gives the cost of one call, free of any
//! attribution ambiguity in the profiler (Cairo compiles loops to recursive
//! functions, which pprof folds into their parent).

use crate::ai::{check_sight, monster_think, reject_blocks};
use crate::bam::{cosine, point_to_angle, sine};
use crate::blockmap::{collect_bbox, collect_ray};
use crate::bsp::{point_in_subsector, sector_at_fast};
use crate::fixed::felt_sub;
use crate::game::{checksum, genesis, run, step_tic};
use crate::geom::{Bbox, box_crosses_six, box_crosses_three, box_hoist, hoist, line_side_six,
    line_side_three};
use crate::mapdata::{
    BIGC, L_AB, L_BB, L_CB, L_DIAG, MON_X, MON_Y, NUM_LINES, PLAYER_SECTOR, PLAYER_X, PLAYER_Y,
};
use crate::mobj::{MONSTER_RADIUS, Opts, PLAYER_RADIUS};
use crate::physics::{path_traverse, try_move};

pub fn probe_body(op: u32, n: u32, o: Opts) -> felt252 {
    let mut acc: felt252 = 0;
    let mut i: u32 = 0;
    // step the probe point around so nothing is loop-invariant
    let step: felt252 = 4096;

    if op == 0 { // empty loop
        while i != n {
            i += 1;
        }
    } else if op == 1 { // point_in_subsector (BSP descent)
        while i != n {
            acc = acc + point_in_subsector(PLAYER_X + i.into() * step, PLAYER_Y, o.three).into();
            i += 1;
        }
    } else if op == 2 { // collect_bbox (blockmap cell iteration for a player bbox)
        while i != n {
            let x = PLAYER_X + i.into() * step;
            let bx = Bbox {
                l: x - PLAYER_RADIUS,
                r: x + PLAYER_RADIUS,
                b: PLAYER_Y - PLAYER_RADIUS,
                t: PLAYER_Y + PLAYER_RADIUS,
            };
            acc = acc + collect_bbox(bx, o.dedup).len().into();
            i += 1;
        }
    } else if op == 3 { // one box_crosses_three, coefficients read from the arrays
        let bx = Bbox {
            l: PLAYER_X - PLAYER_RADIUS,
            r: PLAYER_X + PLAYER_RADIUS,
            b: PLAYER_Y - PLAYER_RADIUS,
            t: PLAYER_Y + PLAYER_RADIUS,
        };
        let h = box_hoist(bx, BIGC);
        while i != n {
            let li = i % NUM_LINES;
            if box_crosses_three(
                *L_AB.span().at(li), *L_BB.span().at(li), *L_CB.span().at(li),
                *L_DIAG.span().at(li), bx, h,
            ) {
                acc = acc + 1;
            }
            i += 1;
        }
    } else if op == 4 { // one box_crosses_six
        let bx = Bbox {
            l: PLAYER_X - PLAYER_RADIUS,
            r: PLAYER_X + PLAYER_RADIUS,
            b: PLAYER_Y - PLAYER_RADIUS,
            t: PLAYER_Y + PLAYER_RADIUS,
        };
        while i != n {
            let li = i % NUM_LINES;
            if box_crosses_six(li, *L_DIAG.span().at(li), bx) {
                acc = acc + 1;
            }
            i += 1;
        }
    } else if op == 5 { // baseline for ops 3/4: the `i % NUM_LINES` and diag read
        while i != n {
            let li = i % NUM_LINES;
            acc = acc + *L_DIAG.span().at(li);
            i += 1;
        }
    } else if op == 6 { // full try_move for the player
        while i != n {
            let r = try_move(PLAYER_X + i.into() * step, PLAYER_Y, PLAYER_RADIUS, o);
            acc = acc + r.floorz + r.sector.into();
            i += 1;
        }
    } else if op == 7 { // check_sight, monster 0 -> player
        let g = genesis(2);
        let m = *g.mobjs.span().at(0);
        while i != n {
            if check_sight(m, PLAYER_X + i.into() * step, PLAYER_Y, PLAYER_SECTOR, o) {
                acc = acc + 1;
            }
            i += 1;
        }
    } else if op == 8 { // REJECT lookup only
        while i != n {
            if reject_blocks(i % 182, PLAYER_SECTOR) {
                acc = acc + 1;
            }
            i += 1;
        }
    } else if op == 9 { // hitscan path_traverse over 2048 units
        while i != n {
            let ex = PLAYER_X + 134217728;
            let ey = PLAYER_Y + i.into() * step;
            acc = acc + path_traverse(PLAYER_X, PLAYER_Y, ex, ey, o).into();
            i += 1;
        }
    } else if op == 10 { // one full monster think (awake, chasing)
        let g = genesis(2);
        let m = *g.mobjs.span().at(0);
        while i != n {
            let (m2, _, d) = monster_think(m, PLAYER_X, PLAYER_Y, PLAYER_SECTOR, i, 0, o);
            acc = acc + m2.x + d;
            i += 1;
        }
    } else if op == 11 { // one full step_tic, scenario 2
        let mut st = genesis(2);
        while i != n {
            st = step_tic(st, 2, o);
            i += 1;
        }
        acc = checksum(@st);
    } else if op == 12 { // one full step_tic, scenario 0 (player only)
        let mut st = genesis(0);
        while i != n {
            st = step_tic(st, 0, o);
            i += 1;
        }
        acc = checksum(@st);
    } else if op == 13 { // collect_ray over a typical sight distance
        while i != n {
            let a = collect_ray(
                *MON_X.span().at(0), *MON_Y.span().at(0), PLAYER_X + i.into() * step, PLAYER_Y,
                o.dedup,
            );
            acc = acc + a.len().into();
            i += 1;
        }
    } else if op == 14 { // sine + cosine (two table lookups + sign recovery)
        while i != n {
            let s = sine(i * 65536);
            let c = cosine(i * 65536);
            acc = acc + s.m + c.m;
            i += 1;
        }
    } else if op == 15 { // point_to_angle
        while i != n {
            let d = felt_sub(PLAYER_X + i.into() * step, PLAYER_X);
            let e = felt_sub(PLAYER_Y, PLAYER_Y - 65536);
            acc = acc + point_to_angle(d, e).into();
            i += 1;
        }
    } else if op == 16 { // genesis + checksum of a 5-mobj state
        while i != n {
            let g = genesis(2);
            acc = acc + checksum(@g);
            i += 1;
        }
    } else if op == 17 { // line_side_three, coefficients already in hand
        let h = hoist(PLAYER_X, PLAYER_Y, BIGC);
        let a = *L_AB.span().at(0);
        let b = *L_BB.span().at(0);
        let c = *L_CB.span().at(0);
        while i != n {
            acc = acc + line_side_three(a, b, c, PLAYER_X + i.into() * step, PLAYER_Y, h).into();
            i += 1;
        }
    } else if op == 18 { // line_side_six (reads six arrays)
        while i != n {
            acc = acc + line_side_six(i % NUM_LINES, PLAYER_X, PLAYER_Y).into();
            i += 1;
        }
    } else if op == 19 { // try_move for a monster (bigger radius -> more cells)
        while i != n {
            let r = try_move(
                *MON_X.span().at(0) + i.into() * step, *MON_Y.span().at(0), MONSTER_RADIUS, o,
            );
            acc = acc + r.floorz;
            i += 1;
        }
    } else if op == 20 { // sector_at_fast (uniform-cell shortcut)
        while i != n {
            acc = acc + sector_at_fast(PLAYER_X + i.into() * step, PLAYER_Y, o.three, o.fastsector)
                .into();
            i += 1;
        }
    } else if op == 21 { // the tic loop itself, doing nothing per tic
        acc = run(0, n, o);
    }
    acc + i.into()
}
