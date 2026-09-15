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
//! * [`PASSIVE`]: everything else.

use doom_physics::maputl::{inc, opaque_zero};
use doom_physics::{KIND_NONE, MF_COUNTKILL, MF_MISSILE, Mobj, NO_MOBJ};
use super::Patch;

/// A slot the ticker copies unchanged: a decoration, an item, the player.
pub const PASSIVE: u32 = 0;
/// A slot the ticker runs: a monster (alive, dying or a corpse) or a missile.
pub const ACTOR: u32 = 1;
/// A freed slot (`kind == KIND_NONE`).
pub const REMOVED: u32 = 2;

/// The derived index of a roster: which slots are actors, and the first
/// free slot. Three felts; `Copy`.
#[derive(Copy, Drop, PartialEq, Debug)]
pub struct Actors {
    /// The indices of the actor slots, ascending.
    pub indices: Span<u32>,
    /// The first removed slot, or `NO_MOBJ` (`doom_physics::first_free`).
    pub first_free: u32,
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

/// The index of `mobjs`, from scratch: one pass reading two fields per
/// slot. ~25 steps a slot; this is the cost every tic used to pay twice.
#[inline(never)]
pub fn scan(mut mobjs: Span<Box<Mobj>>) -> Actors {
    let mut indices: Array<u32> = array![];
    let mut first_free: u32 = NO_MOBJ;
    let mut k: u32 = opaque_zero(mobjs.len());
    while let Option::Some(boxed) = mobjs.pop_front() {
        let class = class_of(boxed.kind, boxed.flags);
        if class == ACTOR {
            indices.append(k);
        } else if class == REMOVED && first_free == NO_MOBJ {
            first_free = k;
        }
        k = inc(k);
    }
    Actors { indices: indices.span(), first_free }
}

/// The index of an empty roster: no actor, no free slot.
pub fn none() -> Actors {
    Actors { indices: array![].span(), first_free: NO_MOBJ }
}

/// `true` when writing `patches` into `before` leaves every slot in its
/// class — in which case the index of `before` is also the index of the
/// patched list. A patch past the end of the list (an appended missile), or
/// one that changes a slot's class, answers `false`: the caller rescans.
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
                if class_of(old.kind, old.flags) != class_of(new.kind, new.flags) {
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
        KIND_NONE, MF_COUNTKILL, MF_MISSILE, MF_SOLID, Mobj, NO_MOBJ, first_free, removed_mobj,
    };
    use crate::Patch;
    use crate::think::next_actor;
    use super::{ACTOR, Actors, PASSIVE, REMOVED, class_of, none, patches_keep_classes, scan};

    fn passive(kind: u32) -> Box<Mobj> {
        BoxTrait::new(Mobj { kind, flags: MF_SOLID, ..removed_mobj() })
    }

    fn monster(kind: u32) -> Box<Mobj> {
        BoxTrait::new(Mobj { kind, flags: MF_COUNTKILL + MF_SOLID, health: 20, ..removed_mobj() })
    }

    fn missile(kind: u32) -> Box<Mobj> {
        BoxTrait::new(Mobj { kind, flags: MF_MISSILE, ..removed_mobj() })
    }

    fn removed() -> Box<Mobj> {
        BoxTrait::new(removed_mobj())
    }

    /// The definition: the slots `next_actor` stops on, in order.
    fn reference(mobjs: Span<Box<Mobj>>) -> Actors {
        let mut remaining = mobjs;
        let mut out: Array<Box<Mobj>> = array![];
        let mut indices: Array<u32> = array![];
        while let Option::Some(actor) = next_actor(ref remaining, ref out) {
            indices.append(out.len());
            out.append(*actor);
        }
        assert_eq!(out.len(), mobjs.len());
        Actors { indices: indices.span(), first_free: first_free(mobjs) }
    }

    #[test]
    fn classes_follow_next_actor_and_first_free() {
        assert_eq!(class_of(KIND_NONE, MF_COUNTKILL), REMOVED);
        assert_eq!(class_of(3, MF_COUNTKILL), ACTOR);
        assert_eq!(class_of(3, MF_MISSILE + MF_SOLID), ACTOR);
        assert_eq!(class_of(3, MF_SOLID), PASSIVE);
        assert_eq!(class_of(0, 0), PASSIVE);
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
