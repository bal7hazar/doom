// SPDX-License-Identifier: GPL-2.0-only
//! The blockmap's **thing** lists (`blocklinks` of `p_maputl.c`), the
//! dynamic half of the blockmap: which mobjs stand in which cell.
//!
//! Doom threads every mobj into a doubly linked list per cell
//! (`bnext`/`bprev`). Those pointers cannot live inside an immutable
//! `Array<Mobj>`, so the lists live here, in a `Felt252Dict` keyed by cell
//! whose value is a `Span<u32>` of mobj indices. Reading a cell is one dict
//! `get` (~35 steps); linking or unlinking rebuilds that one short span
//! (a handful of appends), and a mobj that stays in its cell — the common
//! case, a thing moves less than 30 units per tic in a 128-unit cell — costs
//! nothing at all. The dict is derived data: `rebuild` recreates it from the
//! mobjs' `cell` fields at the start of a segment, so it is **not** part of
//! the hashed state and never needs serializing.
//!
//! S1 §7's warning against `Felt252Dict` was about indexing the mobjs
//! themselves (51 steps per insert/get pair on *every* access of *every*
//! tic); here the dict is touched a few times per tic, and the alternative —
//! scanning every mobj on every `P_TryMove` — is O(n) at ~25 steps per mobj.

use core::dict::Felt252Dict;
use core::nullable::{FromNullableResult, NullableTrait, match_nullable};
use super::mobj::{Mobj, in_blockmap};

/// The per-cell thing lists. `Destruct` squashes the dict when it is
/// dropped, once per segment.
#[derive(Destruct, Default)]
pub struct ThingGrid {
    cells: Felt252Dict<Nullable<Span<u32>>>,
}

/// An empty grid.
pub fn new_grid() -> ThingGrid {
    ThingGrid { cells: Default::default() }
}

/// The mobj indices linked into `cell` (empty when none).
pub fn things_in(ref g: ThingGrid, cell: u32) -> Span<u32> {
    match match_nullable(g.cells.get(cell.into())) {
        FromNullableResult::Null => array![].span(),
        FromNullableResult::NotNull(v) => v.unbox(),
    }
}

/// Link mobj `idx` into `cell` (`P_SetThingPosition`'s blockmap half).
pub fn link(ref g: ThingGrid, cell: u32, idx: u32) {
    let old = things_in(ref g, cell);
    let mut out: Array<u32> = array![];
    let n = old.len();
    let mut k: u32 = 0;
    while k != n {
        out.append(*old.at(k));
        k += 1;
    }
    out.append(idx);
    g.cells.insert(cell.into(), NullableTrait::new(out.span()));
}

/// Unlink mobj `idx` from `cell` (`P_UnsetThingPosition`'s blockmap half).
/// A no-op if it is not there.
pub fn unlink(ref g: ThingGrid, cell: u32, idx: u32) {
    let old = things_in(ref g, cell);
    let mut out: Array<u32> = array![];
    let n = old.len();
    let mut k: u32 = 0;
    while k != n {
        let v = *old.at(k);
        if v != idx {
            out.append(v);
        }
        k += 1;
    }
    g.cells.insert(cell.into(), NullableTrait::new(out.span()));
}

/// Rebuild the grid from the mobjs' own `cell` fields — what `doom_game`
/// does once at the start of a segment, after deserializing the state.
pub fn rebuild(mobjs: Span<Mobj>) -> ThingGrid {
    let mut g = new_grid();
    let n = mobjs.len();
    let mut i: u32 = 0;
    while i != n {
        let m = mobjs.at(i);
        if in_blockmap(m) {
            link(ref g, *m.cell, i);
        }
        i += 1;
    }
    g
}
