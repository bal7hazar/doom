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
use super::maputl::{inc, opaque_zero};
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
#[inline(never)]
pub fn link(ref g: ThingGrid, cell: u32, idx: u32) {
    let mut old = things_in(ref g, cell);
    let mut out: Array<u32> = array![];
    while let Option::Some(v) = old.pop_front() {
        out.append(*v);
    }
    out.append(idx);
    g.cells.insert(cell.into(), NullableTrait::new(out.span()));
}

/// Unlink mobj `idx` from `cell` (`P_UnsetThingPosition`'s blockmap half).
/// A no-op if it is not there.
#[inline(never)]
pub fn unlink(ref g: ThingGrid, cell: u32, idx: u32) {
    let mut old = things_in(ref g, cell);
    let mut out: Array<u32> = array![];
    while let Option::Some(v) = old.pop_front() {
        if *v != idx {
            out.append(*v);
        }
    }
    g.cells.insert(cell.into(), NullableTrait::new(out.span()));
}

/// `unlink` then `link` of the same mobj in the same cell, in one rewrite:
/// the mobj ends up last in the cell's list, exactly as the pair would leave
/// it — and when it already is last (a cell holding just this thing, the
/// common case), the list is left untouched (S7).
#[inline(never)]
pub fn relink(ref g: ThingGrid, cell: u32, idx: u32) {
    let list = things_in(ref g, cell);
    let n = list.len();
    if n != 0 {
        if let Option::Some(last) = list.get(n - 1) {
            if *last.unbox() == idx {
                return;
            }
        }
    }
    let mut old = list;
    let mut out: Array<u32> = array![];
    while let Option::Some(v) = old.pop_front() {
        if *v != idx {
            out.append(*v);
        }
    }
    out.append(idx);
    g.cells.insert(cell.into(), NullableTrait::new(out.span()));
}

/// Rebuild the grid from the mobjs' own `cell` fields — what `doom_game`
/// does once at the start of a segment, after deserializing the state.
pub fn rebuild(mut mobjs: Span<Mobj>) -> ThingGrid {
    let mut g = new_grid();
    let mut i: u32 = opaque_zero(mobjs.len());
    while let Option::Some(m) = mobjs.pop_front() {
        if in_blockmap(m) {
            link(ref g, *m.cell, i);
        }
        i = inc(i);
    }
    g
}
