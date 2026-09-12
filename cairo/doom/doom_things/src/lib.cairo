// SPDX-License-Identifier: GPL-2.0-only
//! Doom's *thing* data: `mobjinfo`, the `info.c` state machine, the weapon
//! chains and the RNG table, for everything Freedoom E1M1 can spawn.
//!
//! The numbers are **derived from** id Software's linuxdoom-1.10 —
//! `info.c`'s `states` and `mobjinfo`, `m_random.c`'s `rndtable`,
//! `d_items.c`'s `weaponinfo` — by `scripts/gen_things.py`, which remaps the
//! ids to a compact range (266 of Doom's 967 states, 48 of its 137 mobj
//! types) and re-emits them as planar `const` columns in
//! [`tables`]. No C code is copied.
//!
//! # What this crate is, and is not
//!
//! It is **data plus lookups**: `fsm` runs the state machine, `prng` draws
//! from the table, `doom_monsters` and `doom_player` implement the actions.
//! Cairo has no function pointers, so a state carries an **action id**
//! ([`tables::A_CHASE`] and friends, listed in `generated/actions.md`) that
//! `fsm::advance` hands back for the caller to dispatch on (D15). Row 0 is
//! `S_NULL`, whose action is `fsm::NO_ACTION = 0`, exactly as `fsm` requires.
//!
//! # Zero-tic states
//!
//! Doom's `P_SetMobjState` loops while the state it enters has `tics == 0`.
//! `fsm` deliberately does not (an unbounded loop has no place on a proving
//! path): entering such a state leaves `tics_left == 0` and the caller
//! chains. [`MAX_ZERO_TIC_CHAIN`] is the longest such chain in this table,
//! measured by the crate's tests, and is the bound `doom_monsters` should
//! use (D15/D17).

pub mod compat;
pub mod tables;

#[cfg(test)]
mod tests;

pub use compat::{MobjInfo, MobjType, info_of};
use fixed::Fixed;
use fsm::StateTables;

/// `MI_DOOMEDNUM` of an entry that cannot be placed on a map (Doom's `-1`).
pub const NO_DOOMEDNUM: u32 = 0xFFFF;

/// Longest chain of zero-tic states in this table, measured by
/// `test_zero_tic_chains_are_bounded`. `doom_monsters`/`doom_player` bound
/// their `while tics_left == 0` loop with it instead of looping freely
/// (D15: no unbounded loop on the proving path).
pub const MAX_ZERO_TIC_CHAIN: u32 = 1;

/// One `mobjinfo` entry, the fields the simulation reads.
///
/// Sounds are dropped: the client plays them off the serialized state, and
/// nothing in the proven core branches on them.
#[derive(Copy, Drop, Serde, PartialEq, Debug)]
pub struct ThingInfo {
    /// THINGS type id, [`NO_DOOMEDNUM`] when the entry is spawn-only.
    pub doomednum: u32,
    pub spawnstate: u32,
    pub spawnhealth: u32,
    pub seestate: u32,
    pub reactiontime: u32,
    pub painstate: u32,
    pub painchance: u32,
    pub meleestate: u32,
    pub missilestate: u32,
    pub deathstate: u32,
    pub xdeathstate: u32,
    pub raisestate: u32,
    /// Map units per move for a walker, 16.16 for a projectile — the raw
    /// `info.c` value, because Doom uses the field both ways.
    pub speed: u32,
    pub radius: Fixed,
    pub height: Fixed,
    pub mass: u32,
    pub damage: u32,
    /// Raw `MF_*` word.
    pub flags: u32,
}

/// The five state columns, in `fsm::StateTables` order.
///
/// `fsm::validate` is checked once by this crate's tests, so the hot path
/// does not have to.
pub fn states() -> StateTables {
    StateTables {
        sprite: tables::STATE_SPRITE.span(),
        frame: tables::STATE_FRAME.span(),
        tics: tables::STATE_TICS.span(),
        action_id: tables::STATE_ACTION.span(),
        next_state: tables::STATE_NEXT.span(),
    }
}

/// Doom's 256-entry `rndtable`, the span `prng::PrngTrait` indexes.
///
/// **Doom's `P_Random` increments *before* reading** (`prndindex =
/// (prndindex + 1) & 0xff; return rndtable[prndindex]`), while
/// `prng::next` reads then advances. A run that wants Doom's own sequence
/// therefore starts at `prng::from_index(1)`, not `prng::new()`.
pub fn rndtable() -> Span<u8> {
    tables::RNDTABLE.span()
}

/// Number of `mobjinfo` entries.
pub fn num_kinds() -> u32 {
    tables::NUM_KINDS
}

/// Number of states.
pub fn num_states() -> u32 {
    tables::NUM_STATES
}

/// The `mobjinfo` entry of `kind` (one of `tables::KIND_*`).
pub fn thing_info(kind: u32) -> ThingInfo {
    ThingInfo {
        doomednum: *tables::MI_DOOMEDNUM.span().at(kind),
        spawnstate: *tables::MI_SPAWNSTATE.span().at(kind),
        spawnhealth: *tables::MI_SPAWNHEALTH.span().at(kind),
        seestate: *tables::MI_SEESTATE.span().at(kind),
        reactiontime: *tables::MI_REACTIONTIME.span().at(kind),
        painstate: *tables::MI_PAINSTATE.span().at(kind),
        painchance: *tables::MI_PAINCHANCE.span().at(kind),
        meleestate: *tables::MI_MELEESTATE.span().at(kind),
        missilestate: *tables::MI_MISSILESTATE.span().at(kind),
        deathstate: *tables::MI_DEATHSTATE.span().at(kind),
        xdeathstate: *tables::MI_XDEATHSTATE.span().at(kind),
        raisestate: *tables::MI_RAISESTATE.span().at(kind),
        speed: *tables::MI_SPEED.span().at(kind),
        radius: Fixed { enc: *tables::MI_RADIUS.span().at(kind) },
        height: Fixed { enc: *tables::MI_HEIGHT.span().at(kind) },
        mass: *tables::MI_MASS.span().at(kind),
        damage: *tables::MI_DAMAGE.span().at(kind),
        flags: *tables::MI_FLAGS.span().at(kind),
    }
}

/// The spawn state of `kind` — the single field `P_SpawnMobj` needs, without
/// building a whole [`ThingInfo`].
pub fn spawn_state(kind: u32) -> u32 {
    *tables::MI_SPAWNSTATE.span().at(kind)
}

/// The `MF_*` flags of `kind`.
pub fn flags(kind: u32) -> u32 {
    *tables::MI_FLAGS.span().at(kind)
}

/// The kind a THINGS `doomednum` spawns, or `None` when the map places a
/// thing this roster does not know (a player start, or a type from another
/// map).
///
/// Binary search over the sorted `DOOMEDNUM_KEYS`: `P_SpawnMapThing` calls
/// it once per thing at genesis, never during a tic.
pub fn kind_of_doomednum(doomednum: u32) -> Option<u32> {
    let keys = tables::DOOMEDNUM_KEYS.span();
    let mut low: u32 = 0;
    let mut high: u32 = keys.len();
    while low != high {
        let mid = (low + high) / 2;
        let key = *keys.at(mid);
        if key == doomednum {
            return Option::Some(*tables::DOOMEDNUM_KINDS.span().at(mid));
        }
        if key < doomednum {
            low = mid + 1;
        } else {
            high = mid;
        }
    }
    Option::None
}

/// The five state ids of one `weaponinfo` entry.
#[derive(Copy, Drop, Serde, PartialEq, Debug)]
pub struct WeaponStates {
    pub up: u32,
    pub down: u32,
    pub ready: u32,
    pub attack: u32,
    pub flash: u32,
}

/// The weapons reachable on E1M1. The shotgun and the chaingun are here even
/// though their *pickups* are all multiplayer-only or easy-only at skill 2,
/// because `P_KillMobj` drops an `MT_SHOTGUN` for every shotgun guy.
#[derive(Copy, Drop, Serde, PartialEq, Debug)]
pub enum WeaponId {
    Fist,
    Pistol,
    Shotgun,
    Chaingun,
    Chainsaw,
}

/// The state chain of `weapon`, from `d_items.c`'s `weaponinfo`.
pub fn weapon_states(weapon: WeaponId) -> WeaponStates {
    let row = match weapon {
        WeaponId::Fist => tables::WEAPON_FIST,
        WeaponId::Pistol => tables::WEAPON_PISTOL,
        WeaponId::Shotgun => tables::WEAPON_SHOTGUN,
        WeaponId::Chaingun => tables::WEAPON_CHAINGUN,
        WeaponId::Chainsaw => tables::WEAPON_CHAINSAW,
    };
    let s = row.span();
    WeaponStates {
        up: *s.at(0), down: *s.at(1), ready: *s.at(2), attack: *s.at(3), flash: *s.at(4),
    }
}
