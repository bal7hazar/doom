// SPDX-License-Identifier: GPL-2.0-only
//! Step-cost benchmark for `doom_specials`.
//!
//! Differential measurement (S1 §3.1): every operation runs `n` and `2n`
//! times and the difference is divided by `n`, which cancels bootstrap and
//! (de)serialization. The per-tic operations are real simulation loops — the
//! state genuinely advances — so nothing can be hoisted out of the loop; the
//! per-call ones vary their operand with the counter for the same reason.
//!
//! * op 0 — bare loop;
//! * op 1 — the hoisted `Heights` snapshot alone, the baseline of the two
//!   height reads;
//! * op 11 — `fields`, the baseline of the serialization op.

use doom_map::LevelId;
use doom_specials::state::{Mover, MoverKind, Phase, SectorTables, SpecialsState};
use doom_specials::thinkers::NeverBlocked;
use doom_specials::{
    ceiling_of, fields, find_lowest_ceiling_surrounding, floor_of, heights, player, sector_tables,
    serialize, spawn_specials, specials_ticker, use_line,
};
use doom_things::rndtable;
use fixed::Fixed;
use prng::from_index;

/// A handful of the map's DR door lines, to vary `use_line`'s operand.
const DOOR_LINES: [u32; 8] = [55, 201, 203, 345, 389, 391, 442, 446];

/// An empty state: no light thinker, no mover, no slot. The floor of what
/// `specials_ticker` can cost.
fn empty_state() -> SpecialsState {
    SpecialsState {
        ceilings: array![].span(),
        floors: array![].span(),
        specials: array![].span(),
        lights: array![].span(),
        next_light: 0xFFFFFFFF,
        movers: array![].span(),
        used: array![].span(),
        secrets: 0,
        exit: false,
    }
}

/// The spawn state with one door climbing toward a ceiling it will not reach
/// inside the measurement, so that every tic exercises `T_MovePlane`.
fn state_with_door(state: SpecialsState, t: SectorTables) -> SpecialsState {
    let mut s = state;
    let view = heights(@s, t);
    s
        .movers =
            array![
                Mover {
                    kind: MoverKind::DoorNormal,
                    phase: Phase::Up,
                    sector: 10,
                    height: ceiling_of(@view, 10),
                    top: Fixed { enc: fixed::BIAS + 0x40000000 },
                    bottom: floor_of(@view, 10),
                    count: 0,
                },
            ]
        .span();
    s
}

/// The same, for a lift on its way down.
fn state_with_plat(state: SpecialsState, t: SectorTables) -> SpecialsState {
    let mut s = state;
    let view = heights(@s, t);
    s
        .movers =
            array![
                Mover {
                    kind: MoverKind::PlatDownWaitUpStay,
                    phase: Phase::Down,
                    sector: 98,
                    height: floor_of(@view, 98),
                    top: floor_of(@view, 98),
                    bottom: Fixed { enc: fixed::BIAS - 0x40000000 },
                    count: 0,
                },
            ]
        .span();
    s
}

#[executable]
fn main(op: u32, n: u32) -> felt252 {
    let m = doom_map::load(LevelId::E1M1);
    let lm = doom_specials::load(LevelId::E1M1);
    let table = rndtable();
    let world = NeverBlocked {};
    let (spawned, rng) = spawn_specials(@m, @lm, from_index(1), table);
    let tables = sector_tables(@m, @lm);
    let mut acc: felt252 = 0;
    let mut i: u32 = 0;

    if op == 0 { // bare loop
        while i != n {
            i += 1;
        }
    } else if op == 1 {
        // the hoisted snapshot alone, baseline of ops 2 and 3
        while i != n {
            let view = heights(@spawned, tables);
            acc += (*view.ceil_slot.at(i % 182)).into();
            i += 1;
        }
    } else if op == 2 {
        // a static sector's ceiling: slot lookup, then `doom_map`
        while i != n {
            let view = heights(@spawned, tables);
            acc += ceiling_of(@view, i % 182).enc;
            i += 1;
        }
    } else if op == 3 {
        // a slotted sector's floor: slot lookup, then the dynamic array
        let floor_sectors: Span<u32> = lm.floor_sectors;
        while i != n {
            let view = heights(@spawned, tables);
            acc += floor_of(@view, *floor_sectors.at(i % 5)).enc;
            i += 1;
        }
    } else if op == 4 {
        // ticker, nothing running at all
        let mut s = empty_state();
        let mut prng = rng;
        while i != n {
            let (next, next_rng, events) = specials_ticker(@world, s, tables, i, prng, table);
            s = next;
            prng = next_rng;
            acc += events.len().into();
            i += 1;
        }
    } else if op == 5 {
        // ticker, E1M1's nine light thinkers and no mover
        let mut s = spawned;
        let mut prng = rng;
        while i != n {
            let (next, next_rng, events) = specials_ticker(@world, s, tables, i, prng, table);
            s = next;
            prng = next_rng;
            acc += events.len().into();
            i += 1;
        }
    } else if op == 6 {
        // ticker, nine lights plus one door moving every tic
        let mut s = state_with_door(spawned, tables);
        let mut prng = rng;
        while i != n {
            let (next, next_rng, events) = specials_ticker(@world, s, tables, i, prng, table);
            s = next;
            prng = next_rng;
            acc += events.len().into();
            i += 1;
        }
    } else if op == 7 {
        // ticker, nine lights plus one lift moving every tic
        let mut s = state_with_plat(spawned, tables);
        let mut prng = rng;
        while i != n {
            let (next, next_rng, events) = specials_ticker(@world, s, tables, i, prng, table);
            s = next;
            prng = next_rng;
            acc += events.len().into();
            i += 1;
        }
    } else if op == 8 {
        // `P_UseSpecialLine` on a manual door: the whole trigger path,
        // `P_FindLowestCeilingSurrounding` included
        let lines = DOOR_LINES.span();
        while i != n {
            let (s, _, ok) = use_line(spawned, @m, @lm, *lines.at(i % 8), 0, player(false));
            acc += s.movers.len().into() + if ok {
                1
            } else {
                0
            };
            i += 1;
        }
    } else if op == 9 {
        // canonical serialization of the whole dynamic state
        while i != n {
            let mut s = spawned;
            s.secrets = i;
            acc += serialize(@s).len().into();
            i += 1;
        }
    } else if op == 10 {
        // `P_FindLowestCeilingSurrounding` on its own
        while i != n {
            let view = heights(@spawned, tables);
            acc += find_lowest_ceiling_surrounding(@view, @lm, i % 182).enc;
            i += 1;
        }
    } else if op == 12 {
        // ticker, nine lights plus one door merely *waiting*: the cost of
        // carrying a thinker through a tic without moving a plane.
        let mut s = state_with_door(spawned, tables);
        let mut waiting = *s.movers.at(0);
        waiting.phase = Phase::Waiting;
        waiting.count = 4000000000;
        s.movers = array![waiting].span();
        let mut prng = rng;
        while i != n {
            let (next, next_rng, events) = specials_ticker(@world, s, tables, i, prng, table);
            s = next;
            prng = next_rng;
            acc += events.len().into();
            i += 1;
        }
    } else if op == 11 {
        // `fields`, the length `doom_game` opens its buffer with
        while i != n {
            let mut s = spawned;
            s.secrets = i;
            acc += fields(@s).into();
            i += 1;
        }
    }
    acc + i.into()
}
