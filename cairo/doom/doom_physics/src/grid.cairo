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
//! nothing at all. Membership alone is derived; visitation order is not.
//! `doom_game` schema 2 commits [`canonical_order`] at boundaries and restores
//! the lists exactly. [`rebuild`] is only for a fresh grid, not a saved game.
//!
//! S1 §7's warning against `Felt252Dict` was about indexing the mobjs
//! themselves (51 steps per insert/get pair on *every* access of *every*
//! tic); here the dict is touched a few times per tic, and the alternative —
//! scanning every mobj on every `P_TryMove` — is O(n) at ~25 steps per mobj.

use core::dict::{Felt252Dict, Felt252DictEntryTrait};
use core::nullable::{FromNullableResult, NullableTrait, match_nullable};
use super::maputl::{inc, opaque_zero};
use super::mobj::{Mobj, in_blockmap};

/// The per-cell thing lists. `Destruct` squashes the dict when it is
/// dropped, once per segment.
#[derive(Destruct, Default)]
pub struct ThingGrid {
    cells: Felt252Dict<Nullable<Span<u32>>>,
    // Immutable snapshots can read this append-only journal. The canonical
    // state records only each cell's last list, never the journal history.
    journal: Array<(u32, Span<u32>)>,
}

/// An empty grid.
pub fn new_grid() -> ThingGrid {
    ThingGrid { cells: Default::default(), journal: array![] }
}

/// The mobj indices linked into `cell` (empty when none).
pub fn things_in(ref g: ThingGrid, cell: u32) -> Span<u32> {
    // `entry` + `finalize` are the explicitly panic-free form of `get`.
    let (entry, value) = g.cells.entry(cell.into());
    g.cells = entry.finalize(value);
    match match_nullable(value) {
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
    let list = out.span();
    g.cells.insert(cell.into(), NullableTrait::new(list));
    g.journal.append((cell, list));
}

/// Restore an already validated complete cell list at a serialization
/// boundary. The visitation order is unchanged; the journal needs only one
/// final entry rather than every intermediate prefix made by `link`.
/// Returns false without changing an existing cell, so the reader can
/// reject duplicate cells using this dictionary instead of a second one.
pub fn restore_cell(ref g: ThingGrid, cell: u32, members: Span<u32>) -> bool {
    let (entry, previous) = g.cells.entry(cell.into());
    match match_nullable(previous) {
        FromNullableResult::Null => {
            g.cells = entry.finalize(NullableTrait::new(members));
            g.journal.append((cell, members));
            true
        },
        FromNullableResult::NotNull(_) => {
            g.cells = entry.finalize(previous);
            false
        },
    }
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
    let list = out.span();
    g.cells.insert(cell.into(), NullableTrait::new(list));
    g.journal.append((cell, list));
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
    let list = out.span();
    g.cells.insert(cell.into(), NullableTrait::new(list));
    g.journal.append((cell, list));
}

/// Rebuild membership from the mobjs' own `cell` fields for a fresh grid.
/// Saved states restore their committed visitation order with `restore_cell`.
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

/// Canonical cell order is the first live mobj index in each cell; the
/// *members* retain their exact historical visitation order. Replaying the
/// journal into a temporary dict makes this O(history + roster + members),
/// only at a hash/serialization boundary, and permits an immutable snapshot.
/// Its per-cell visited bit also replaces a separate seen-cell dictionary.
/// Format: [n_cells, cell, n_members, member_indices..., ...].
pub fn canonical_order(g: @ThingGrid, mut mobjs: Span<Mobj>) -> Array<felt252> {
    let mut latest: Felt252Dict<Nullable<(bool, Span<u32>)>> = Default::default();
    let mut history = g.journal.span();
    while let Option::Some(record) = history.pop_front() {
        let (cell, list) = *record;
        latest.insert(cell.into(), NullableTrait::new((false, list)));
    }
    let mut body: Array<felt252> = array![];
    let mut count: u32 = 0;
    while let Option::Some(m) = mobjs.pop_front() {
        if in_blockmap(m) {
            let cell = *m.cell;
            let (entry, value) = latest.entry(cell.into());
            let (done, mut list) = match match_nullable(value) {
                FromNullableResult::Null => (false, array![].span()),
                FromNullableResult::NotNull(v) => v.unbox(),
            };
            latest = entry.finalize(NullableTrait::new((true, list)));
            if !done {
                body.append(cell.into());
                body.append(list.len().into());
                while let Option::Some(idx) = list.pop_front() {
                    body.append((*idx).into());
                }
                count = inc(count);
            }
        }
    }
    let mut out = array![count.into()];
    out.append_span(body.span());
    out
}
