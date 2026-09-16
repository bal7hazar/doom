// SPDX-License-Identifier: GPL-2.0-only
//! The derived actor index (docs/design/d2-profile.md §5.1, optimisation O1).
//!
//! The roster of E1M1 holds ~210 slots of which ~30 are **actors** — the
//! monsters and missiles this crate ticks — and the rest decorations, items,
//! corpses of items and removed slots that never change on their own. The
//! D2 profile measured two full classifications of the list on every tic
//! (`next_actor` and `awake_count`), plus a third in `first_free` whenever a
//! monster was awake: ≈ 17 000 of the 26 400 steps of an idle tic.
//!
//! [`Actors`] is that classification computed once — at genesis, when a
//! state is loaded from felts — and carried across tics as **derived
//! state** (like the sector height arrays): it is never serialized, never
//! hashed, and it is rebuilt from the list itself ([`scan`]) whenever a tic
//! may have changed the class of a slot. The rebuild rule is deliberately
//! conservative — any write that *could* change a slot's class triggers a
//! full [`scan`] — so the index is, on every tic, exactly what `next_actor`
//! would have produced: the same set, in slot order.
//!
//! A slot's **class** is one of three, read from two fields:
//!
//! * [`REMOVED`]: `kind == KIND_NONE` (a slot `remove_mobj` freed; the
//!   first one is `first_free`);
//! * [`ACTOR`]: otherwise, `MF_COUNTKILL | MF_MISSILE` set (exactly
//!   `next_actor`'s test, `is_ours`);
//! * [`PASSIVE`]: everything else;
//!
//! plus one bit read from a third field, [`OFF_GRID`]: a live slot that is
//! not linked in the blockmap (`MF_NOBLOCKMAP`, or a cell of `NO_CELL`).
//! `doom_game`'s `P_ChangeSector` (docs/design/d2-profile.md O3) finds the
//! things standing in a moving sector by walking the blockmap cells of that
//! sector, and visits [`Actors::off_grid`] on top, so that the set it tests
//! is exactly the roster's. The same conservative rule keeps that list
//! right: a write that could change a slot's class *or* its membership
//! triggers a full [`scan`].

use doom_physics::maputl::{inc, opaque_zero};
use doom_physics::{KIND_NONE, MF_COUNTKILL, MF_MISSILE, MF_NOBLOCKMAP, Mobj, NO_CELL, NO_MOBJ};
use super::Patch;

/// A slot the ticker copies unchanged: a decoration, an item, the player.
pub const PASSIVE: u32 = 0;
/// A slot the ticker runs: a monster (alive, dying or a corpse) or a missile.
pub const ACTOR: u32 = 1;
/// A freed slot (`kind == KIND_NONE`).
pub const REMOVED: u32 = 2;
/// Added to [`ACTOR`] or [`PASSIVE`] by [`slot_class`] when the slot is not
/// linked in the blockmap.
pub const OFF_GRID: u32 = 4;

/// The derived index of a roster: which slots are actors, the first free
/// slot, and which live slots the blockmap cannot find. Five felts; `Copy`.
#[derive(Copy, Drop, PartialEq, Debug)]
pub struct Actors {
    /// The indices of the actor slots, ascending.
    pub indices: Span<u32>,
    /// The first removed slot, or `NO_MOBJ` (`doom_physics::first_free`).
    pub first_free: u32,
    /// The live slots not linked in the blockmap, ascending (O3): what a
    /// walk of the thing grid cannot find. On E1M1 these are the missiles
    /// in flight (Doom's missiles carry `MF_NOBLOCKMAP`).
    pub off_grid: Span<u32>,
}

/// The class of a slot from its two classifying fields.
#[inline(always)]
pub fn class_of(kind: u32, flags: u32) -> u32 {
    if kind == KIND_NONE {
        REMOVED
    } else if doom_physics::has(flags, MF_COUNTKILL + MF_MISSILE) {
        ACTOR
    } else {
        PASSIVE
    }
}

/// `next_actor`'s test: a slot this crate ticks.
#[inline(always)]
pub fn is_actor(m: @Mobj) -> bool {
    class_of(*m.kind, *m.flags) == ACTOR
}

/// Whether a live slot with these fields is linked in the blockmap
/// (`doom_physics::in_blockmap` on the fields alone, the kind being live).
#[inline(always)]
pub fn linked(flags: u32, cell: u32) -> bool {
    !doom_physics::has(flags, MF_NOBLOCKMAP) && cell != NO_CELL
}

/// The class of a slot with its [`OFF_GRID`] bit: what the index keeps
/// for the slot, and what a write must preserve for the index to survive.
pub fn slot_class(kind: u32, flags: u32, cell: u32) -> u32 {
    let class = class_of(kind, flags);
    if class != REMOVED && !linked(flags, cell) {
        class + OFF_GRID
    } else {
        class
    }
}

/// `slot_class(a) == slot_class(b)` without the sum: the two classes and
/// the two membership bits compared (a removed slot is never linked, so
/// its bit is `false` on both sides).
#[inline(always)]
pub fn same_class(ka: u32, fa: u32, ca: u32, kb: u32, fb: u32, cb: u32) -> bool {
    class_of(ka, fa) == class_of(kb, fb) && linked(fa, ca) == linked(fb, cb)
}

/// The index of `mobjs`, from scratch: one pass reading three fields per
/// slot. ~25 steps a slot; this is the cost every tic used to pay twice.
#[inline(never)]
pub fn scan(mut mobjs: Span<Box<Mobj>>) -> Actors {
    let mut indices: Array<u32> = array![];
    let mut off_grid: Array<u32> = array![];
    let mut first_free: u32 = NO_MOBJ;
    let mut k: u32 = opaque_zero(mobjs.len());
    while let Option::Some(boxed) = mobjs.pop_front() {
        let class = class_of(boxed.kind, boxed.flags);
        if class == ACTOR {
            indices.append(k);
        } else if class == REMOVED && first_free == NO_MOBJ {
            first_free = k;
        }
        if class != REMOVED && !linked(boxed.flags, boxed.cell) {
            off_grid.append(k);
        }
        k = inc(k);
    }
    Actors { indices: indices.span(), first_free, off_grid: off_grid.span() }
}

/// The index of an empty roster: no actor, no free slot, nothing off the grid.
pub fn none() -> Actors {
    Actors { indices: array![].span(), first_free: NO_MOBJ, off_grid: array![].span() }
}

/// `true` when writing `patches` into `before` leaves every slot in its
/// class (its blockmap membership included) — in which case the index of
/// `before` is also the index of the patched list. A patch past the end of
/// the list (an appended missile), or one that changes a slot's class,
/// answers `false`: the caller rescans.
///
/// Conservative on purpose: two patches on one slot are each compared with
/// the original, so a class change undone by a later patch still rescans.
pub fn patches_keep_classes(before: Span<Box<Mobj>>, mut patches: Span<Patch>) -> bool {
    let mut same = true;
    while let Option::Some(p) = patches.pop_front() {
        let new = p.mo;
        match before.get(*p.idx) {
            Option::Some(b) => {
                let old = b.unbox();
                if !same_class(old.kind, old.flags, old.cell, new.kind, new.flags, new.cell) {
                    same = false;
                    break;
                }
            },
            Option::None => {
                same = false;
                break;
            },
        }
    }
    same
}

#[cfg(test)]
mod tests {
    use doom_physics::{
        KIND_NONE, MF_COUNTKILL, MF_MISSILE, MF_NOBLOCKMAP, MF_SOLID, Mobj, NO_CELL, NO_MOBJ,
        first_free, in_blockmap, is_removed, removed_mobj,
    };
    use crate::Patch;
    use crate::think::next_actor;
    use super::{
        ACTOR, Actors, OFF_GRID, PASSIVE, REMOVED, class_of, none, patches_keep_classes, scan,
        slot_class,
    };

    /// Every live record of these tests is linked (cell 7), unless said.
    fn passive(kind: u32) -> Box<Mobj> {
        BoxTrait::new(Mobj { kind, flags: MF_SOLID, cell: 7, ..removed_mobj() })
    }

    fn monster(kind: u32) -> Box<Mobj> {
        BoxTrait::new(
            Mobj { kind, flags: MF_COUNTKILL + MF_SOLID, health: 20, cell: 7, ..removed_mobj() },
        )
    }

    fn missile(kind: u32) -> Box<Mobj> {
        BoxTrait::new(Mobj { kind, flags: MF_MISSILE, cell: 7, ..removed_mobj() })
    }

    fn removed() -> Box<Mobj> {
        BoxTrait::new(removed_mobj())
    }

    /// The definition: the slots `next_actor` stops on, in order, the first
    /// free slot, and the live slots `in_blockmap` rejects.
    fn reference(mobjs: Span<Box<Mobj>>) -> Actors {
        let mut remaining = mobjs;
        let mut out: Array<Box<Mobj>> = array![];
        let mut indices: Array<u32> = array![];
        while let Option::Some(actor) = next_actor(ref remaining, ref out) {
            indices.append(out.len());
            out.append(*actor);
        }
        assert_eq!(out.len(), mobjs.len());
        let mut off_grid: Array<u32> = array![];
        let mut k: u32 = 0;
        let mut ms = mobjs;
        while let Option::Some(b) = ms.pop_front() {
            let m = b.as_snapshot().unbox();
            if !is_removed(m) && !in_blockmap(m) {
                off_grid.append(k);
            }
            k += 1;
        }
        Actors { indices: indices.span(), first_free: first_free(mobjs), off_grid: off_grid.span() }
    }

    #[test]
    fn classes_follow_next_actor_and_first_free() {
        assert_eq!(class_of(KIND_NONE, MF_COUNTKILL), REMOVED);
        assert_eq!(class_of(3, MF_COUNTKILL), ACTOR);
        assert_eq!(class_of(3, MF_MISSILE + MF_SOLID), ACTOR);
        assert_eq!(class_of(3, MF_SOLID), PASSIVE);
        assert_eq!(class_of(0, 0), PASSIVE);
        // The blockmap bit: `MF_NOBLOCKMAP` or no cell, on a live slot only.
        assert_eq!(slot_class(3, MF_COUNTKILL, 7), ACTOR);
        assert_eq!(slot_class(3, MF_COUNTKILL + MF_NOBLOCKMAP, 7), ACTOR + OFF_GRID);
        assert_eq!(slot_class(3, MF_COUNTKILL, NO_CELL), ACTOR + OFF_GRID);
        assert_eq!(slot_class(3, MF_SOLID, NO_CELL), PASSIVE + OFF_GRID);
        assert_eq!(slot_class(KIND_NONE, MF_NOBLOCKMAP, NO_CELL), REMOVED);
        assert_eq!(slot_class(KIND_NONE, 0, 7), REMOVED);
        // A removed slot with a stale monster flag is passive for both.
        let stale = BoxTrait::new(Mobj { flags: MF_COUNTKILL, ..removed_mobj() });
        let roster = array![
            passive(17), removed(), missile(1), passive(9), monster(2), stale, monster(4),
        ]
            .span();
        let derived = scan(roster);
        assert_eq!(derived, reference(roster));
        assert_eq!(derived.indices, array![2, 4, 6].span());
        assert_eq!(derived.first_free, 1);
        assert_eq!(derived.off_grid, array![].span());
    }

    #[test]
    fn off_grid_slots_are_the_live_ones_in_blockmap_rejects() {
        // A puff-like passive with MF_NOBLOCKMAP, a monster off the grid, a
        // missile with both, a removed slot with a stale cell: the first
        // three are off the grid, in slot order; the removed one is not.
        let puff = BoxTrait::new(Mobj { kind: 9, flags: MF_NOBLOCKMAP, cell: 7, ..removed_mobj() });
        let far = BoxTrait::new(
            Mobj { kind: 2, flags: MF_COUNTKILL, health: 20, cell: NO_CELL, ..removed_mobj() },
        );
        let ghost = BoxTrait::new(
            Mobj { kind: 1, flags: MF_MISSILE + MF_NOBLOCKMAP, cell: NO_CELL, ..removed_mobj() },
        );
        let stale = BoxTrait::new(Mobj { cell: 7, flags: 0, ..removed_mobj() });
        let roster = array![passive(17), puff, monster(2), far, stale, ghost, missile(1)].span();
        let derived = scan(roster);
        assert_eq!(derived, reference(roster));
        assert_eq!(derived.indices, array![2, 3, 5, 6].span());
        assert_eq!(derived.off_grid, array![1, 3, 5].span());
        assert_eq!(derived.first_free, 4);
        // Linking or unlinking a slot, or flagging it, changes its class:
        // the index must be rescanned.
        let linked_far = array![Patch { idx: 3, mo: monster(2) }];
        assert!(!patches_keep_classes(roster, linked_far.span()));
        let unlinked = array![Patch { idx: 0, mo: puff }];
        assert!(!patches_keep_classes(roster, unlinked.span()));
        let moved = array![
            Patch { idx: 2, mo: BoxTrait::new(Mobj { cell: 8, ..monster(2).unbox() }) },
        ];
        assert!(patches_keep_classes(roster, moved.span()));
    }

    #[test]
    fn empty_and_passive_rosters_have_no_actor() {
        assert_eq!(scan(array![].span()), none());
        let roster = array![passive(1), passive(2)].span();
        assert_eq!(scan(roster), reference(roster));
        assert_eq!(scan(roster).first_free, NO_MOBJ);
        let freed = array![removed(), removed()].span();
        assert_eq!(scan(freed), reference(freed));
        assert_eq!(scan(freed).first_free, 0);
    }

    #[test]
    fn scan_matches_the_definition_on_every_spawn_death_and_reuse_step() {
        // A roster that lives through a fight: a missile spawned into a free
        // slot, one appended, a missile exploding then removed, a monster
        // dying (still an actor), an item picked up (a new free slot), a
        // dropped item reusing it, and more than eight awake monsters.
        let mut roster: Array<Box<Mobj>> = array![passive(0)];
        let mut k: u32 = 0;
        while k != 12 {
            roster.append(monster(k));
            roster.append(passive(k));
            k += 1;
        }
        roster.append(removed());
        roster.append(passive(99));
        let base = roster.span();
        assert_eq!(scan(base), reference(base));
        assert_eq!(scan(base).indices.len(), 12);
        assert_eq!(scan(base).first_free, 25);
        // Spawn into the free slot, then append.
        let mut with_missile: Array<Box<Mobj>> = array![];
        let mut src = base;
        k = 0;
        while let Option::Some(b) = src.pop_front() {
            with_missile.append(if k == 25 {
                missile(7)
            } else {
                *b
            });
            k += 1;
        }
        with_missile.append(missile(7));
        let spawned = with_missile.span();
        assert_eq!(scan(spawned), reference(spawned));
        assert_eq!(scan(spawned).indices.len(), 14);
        assert_eq!(scan(spawned).first_free, NO_MOBJ);
        // The appended missile explodes (drops MF_MISSILE), slot 25 is
        // removed, the item at 26 is picked up, monster 1 dies, and a
        // dropped item lands in the first free slot.
        let mut later: Array<Box<Mobj>> = array![];
        src = spawned;
        k = 0;
        while let Option::Some(b) = src.pop_front() {
            later
                .append(
                    if k == 27 {
                        BoxTrait::new(Mobj { flags: 0, ..b.unbox() })
                    } else if k == 25 {
                        removed()
                    } else if k == 26 {
                        removed()
                    } else if k == 1 {
                        BoxTrait::new(Mobj { health: -5, ..b.unbox() })
                    } else {
                        *b
                    },
                );
            k += 1;
        }
        let after = later.span();
        assert_eq!(scan(after), reference(after));
        assert_eq!(scan(after).indices.len(), 12);
        assert_eq!(scan(after).first_free, 25);
    }

    #[test]
    fn patches_that_keep_classes_are_told_apart_from_the_rest() {
        let roster = array![passive(0), monster(1), removed(), missile(2)].span();
        // Damage, a height clip, a countdown: same classes.
        let hurt = BoxTrait::new(Mobj { health: 1, ..roster.at(1).unbox() });
        let same = array![
            Patch { idx: 1, mo: hurt }, Patch { idx: 0, mo: passive(5) },
            Patch { idx: 3, mo: missile(2) },
        ];
        assert!(patches_keep_classes(roster, same.span()));
        assert!(patches_keep_classes(roster, array![].span()));
        // A missile into the free slot, a removal, an explosion, a pickup,
        // an append: each changes a class or the length.
        let spawn = array![Patch { idx: 2, mo: missile(2) }];
        assert!(!patches_keep_classes(roster, spawn.span()));
        let gone = array![Patch { idx: 3, mo: removed() }];
        assert!(!patches_keep_classes(roster, gone.span()));
        let exploded = array![Patch { idx: 3, mo: passive(2) }];
        assert!(!patches_keep_classes(roster, exploded.span()));
        let picked = array![Patch { idx: 0, mo: removed() }];
        assert!(!patches_keep_classes(roster, picked.span()));
        let appended = array![Patch { idx: 1, mo: hurt }, Patch { idx: 4, mo: missile(2) }];
        assert!(!patches_keep_classes(roster, appended.span()));
        // Two patches on one slot are each compared with the original.
        let undone = array![Patch { idx: 2, mo: missile(2) }, Patch { idx: 2, mo: removed() }];
        assert!(!patches_keep_classes(roster, undone.span()));
    }
}
