// SPDX-License-Identifier: GPL-2.0-only
//! The per-level tables `doom_specials` owns, and the accessors that read
//! them.
//!
//! `doom_map` ships what the *simulation* reads on every tic; three things
//! only the specials need are generated here instead, out of `doom_map`'s
//! own constants, by `scripts/gen_specials.py`:
//!
//! * **sector adjacency** — `getNextSector` (p_spec.c) over `sec->lines`,
//!   deduplicated. Every `P_Find*Surrounding` is a min or a max over the
//!   neighbours' heights or light levels, so dropping the duplicate lines
//!   between the same pair of sectors cannot change an answer;
//! * **tag → sectors** — the iteration `P_FindSectorFromLineTag` performs by
//!   rescanning all 182 sectors for each match;
//! * **slot maps** — which sectors the dynamic state keeps a cell for, see
//!   [`super::state`].
//!
//! Layout follows `doom_map`'s rule (`pack iff 14.7 × felts_saved / K >
//! extra_steps × accesses_per_tic`, at K = 100): the slot maps are **planar**
//! because `doom_physics` reads a sector height through `CEIL_SLOT` /
//! `FLOOR_SLOT` tens of times per tic, while adjacency and the tag lists are
//! **packed** eight 8-bit ids per felt because they are read only when a
//! special fires.

pub mod e1m1;
use doom_map::LevelId;

/// Every span of one level's specials tables. Built once by [`load`] and
/// passed by snapshot, like `doom_map::LevelMap`.
#[derive(Copy, Drop)]
pub struct SpecialsMap {
    /// `[adj_start[s], adj_start[s + 1])` indexes sector `s`'s neighbours.
    pub adj_start: Span<u32>,
    /// Neighbour sector ids, eight 8-bit ids per felt.
    pub adj_packed: Span<felt252>,
    /// Distinct tags, ascending — the key column of [`tag_sectors`].
    pub tag_keys: Span<u32>,
    /// `[tag_start[k], tag_start[k + 1])` indexes tag `tag_keys[k]`.
    pub tag_start: Span<u32>,
    /// Sectors per tag, ascending id, eight 8-bit ids per felt.
    pub tag_packed: Span<felt252>,
    /// Sector → slot of the dynamic ceiling array, or [`NO_SLOT`].
    pub ceil_slot: Span<u32>,
    /// Sector → slot of the dynamic floor array, or [`NO_SLOT`].
    pub floor_slot: Span<u32>,
    /// Sector → light thinker index, or [`NO_SLOT`].
    pub light_slot: Span<u32>,
    /// Sector → slot of the dynamic `sector->special` array, or [`NO_SLOT`].
    pub special_slot: Span<u32>,
    /// Slot → sector, the inverses used when a slot array is built.
    pub ceil_sectors: Span<u32>,
    pub floor_sectors: Span<u32>,
    pub light_sectors: Span<u32>,
    pub special_sectors: Span<u32>,
    /// `2^(8 k)`, the shift of the k-th id inside a packed felt.
    pub shift8: Span<felt252>,
}

/// Sentinel of the `*_slot` columns: this sector never changes that way, so
/// its value is always `doom_map`'s.
pub const NO_SLOT: u32 = e1m1::NO_SLOT;

/// Ids per packed felt (8 × 8 bits = 64, below 2^72 — PLAN.md A7).
pub const PER_FELT: u32 = e1m1::ADJ_PER_FELT;

/// Bundle the generated tables of `level` into spans. Pure and total; call
/// it once per segment, next to `doom_map::load`.
pub fn load(level: LevelId) -> SpecialsMap {
    match level {
        LevelId::E1M1 => SpecialsMap {
            adj_start: e1m1::ADJ_START.span(),
            adj_packed: e1m1::ADJ_PACKED.span(),
            tag_keys: e1m1::TAG_KEYS.span(),
            tag_start: e1m1::TAG_START.span(),
            tag_packed: e1m1::TAG_PACKED.span(),
            ceil_slot: e1m1::CEIL_SLOT.span(),
            floor_slot: e1m1::FLOOR_SLOT.span(),
            light_slot: e1m1::LIGHT_SLOT.span(),
            special_slot: e1m1::SPECIAL_SLOT.span(),
            ceil_sectors: e1m1::CEIL_SECTORS.span(),
            floor_sectors: e1m1::FLOOR_SECTORS.span(),
            light_sectors: e1m1::LIGHT_SECTORS.span(),
            special_sectors: e1m1::SPECIAL_SECTORS.span(),
            shift8: e1m1::SHIFT8.span(),
        },
    }
}

/// One 8-bit id out of a packed span: `(felt / 2^(8 k)) % 256`, the same
/// `u128` extraction `doom_map` uses (never `/` on a `felt252`, which is a
/// field division).
fn unpack(items: Span<felt252>, shift8: Span<felt252>, k: u32) -> u32 {
    let word: u128 = (*items.at(k / PER_FELT)).try_into().unwrap();
    let shift: u128 = (*shift8.at(k % PER_FELT)).try_into().unwrap();
    ((word / shift) % 256).try_into().unwrap()
}

/// `[from, to)` of sector `s`'s neighbours — the sectors `getNextSector`
/// yields over `sec->lines`, deduplicated.
pub fn neighbours(lm: @SpecialsMap, s: u32) -> (u32, u32) {
    (*(*lm.adj_start).at(s), *(*lm.adj_start).at(s + 1))
}

/// The `k`-th entry of the neighbour stream (`k` from [`neighbours`]).
pub fn neighbour(lm: @SpecialsMap, k: u32) -> u32 {
    unpack(*lm.adj_packed, *lm.shift8, k)
}

/// `[from, to)` of the sectors carrying `tag`, ascending id — the whole
/// `while ((secnum = P_FindSectorFromLineTag(line, secnum)) >= 0)` loop,
/// precomputed. Empty when no sector carries the tag.
pub fn tag_sectors(lm: @SpecialsMap, tag: u32) -> (u32, u32) {
    let keys = *lm.tag_keys;
    let mut i: u32 = 0;
    let mut found: u32 = keys.len();
    while i != keys.len() {
        if *keys.at(i) == tag {
            found = i;
            break;
        }
        i += 1;
    }
    if found == keys.len() {
        return (0, 0);
    }
    (*(*lm.tag_start).at(found), *(*lm.tag_start).at(found + 1))
}

/// The `k`-th entry of the tag stream (`k` from [`tag_sectors`]).
pub fn tag_sector(lm: @SpecialsMap, k: u32) -> u32 {
    unpack(*lm.tag_packed, *lm.shift8, k)
}
