// SPDX-License-Identifier: GPL-2.0-only
//! `P_DamageMobj` and `P_KillMobj` (`p_inter.c`), on the target as a value.
//!
//! The target is the mobj the caller owns; the inflictor and the source are
//! read from the tic's `Span<Mobj>`. Player-specific bookkeeping (armor,
//! god mode, `damagecount`, dropping the weapon, `PST_DEAD`) is
//! `doom_player`'s: it reduces the damage first and reads the outcome.

use bam::point_to_angle2;
use doom_things::tables::{KIND_CLIP, KIND_PLAYER, KIND_POSSESSED, KIND_SHOTGUN, KIND_SHOTGUY};
use doom_things::thing_info;
use fixed::{BIAS, Fixed};
use prng::{Prng, PrngTrait};
use super::mobj::{
    MF_CORPSE, MF_COUNTKILL, MF_DROPOFF, MF_DROPPED, MF_FLOAT, MF_JUSTHIT, MF_NOCLIP, MF_NOGRAVITY,
    MF_SHOOTABLE, MF_SKULLFLY, MF_SOLID, Mobj, NO_MOBJ, has, without,
};
use super::spawn::{SpawnZ, set_state, spawn_mobj};
use super::world::World;

/// `BASETHRESHOLD`: tics a target is kept after retaliating.
pub const BASETHRESHOLD: u32 = 100;

/// What `damage_mobj` did.
#[derive(Copy, Drop, PartialEq, Debug)]
pub struct DamageOutcome {
    /// The target died (`P_KillMobj` ran).
    pub died: bool,
    /// The target entered its pain state.
    pub pain: bool,
    /// The target retaliated: `target.target` now points at the source and
    /// it entered its see state if it was idle.
    pub retaliated: bool,
    /// Action id of the state entered (pain, see, death), `fsm::NO_ACTION`
    /// when none, for the caller to dispatch (`P_SetMobjState` runs it).
    pub action: u32,
    /// The dying monster counted toward the kill total (`MF_COUNTKILL`).
    pub counts_kill: bool,
    /// The item `P_KillMobj` dropped, for the caller to add to the list.
    pub drop: Option<Mobj>,
}

/// `P_KillMobj` on `target` (health already ≤ 0): corpse flags, the death
/// or gib state with Doom's random tic shortening, and the dropped item.
pub fn kill_mobj(w: World, ref rng: Prng, ref target: Mobj) -> (u32, Option<Mobj>) {
    let info = thing_info(target.kind);
    target.flags = without(target.flags, MF_SHOOTABLE + MF_FLOAT + MF_SKULLFLY);
    if target.kind != super::spawn::KIND_SKULL {
        target.flags = without(target.flags, MF_NOGRAVITY);
    }
    target.flags = target.flags | MF_CORPSE | MF_DROPOFF;
    target.height = quarter(target.height);
    if target.kind == KIND_PLAYER {
        target.flags = without(target.flags, MF_SOLID);
    }
    let spawnhealth: i32 = info.spawnhealth.try_into().unwrap();
    let state = if target.health < -spawnhealth && info.xdeathstate != 0 {
        info.xdeathstate
    } else {
        info.deathstate
    };
    let action = set_state(w, ref target, state);
    let (next, roll) = rng.next(w.rndtable);
    rng = next;
    let shorten: u32 = (roll % 4).into();
    target.tics = if target.tics > shorten + 1 {
        target.tics - shorten
    } else {
        1
    };
    // Drop stuff: the same random-position-free spawn as `P_KillMobj`.
    let item = if target.kind == KIND_POSSESSED {
        KIND_CLIP
    } else if target.kind == KIND_SHOTGUY {
        KIND_SHOTGUN
    } else {
        NO_MOBJ
    };
    let drop = if item == NO_MOBJ {
        Option::None
    } else {
        let mut mo = spawn_mobj(w, item, target.x, target.y, SpawnZ::OnFloor);
        mo.flags = mo.flags | MF_DROPPED; // special versions of items
        Option::Some(mo)
    };
    (action, drop)
}

/// `h >> 2` on a positive height.
fn quarter(h: Fixed) -> Fixed {
    let v: u128 = (h.enc - BIAS).try_into().unwrap();
    let q: felt252 = (v / 4).into();
    Fixed { enc: q + BIAS }
}

/// `P_DamageMobj`: `damage` points to `target` (index `target_idx`) from
/// `inflictor` (the missile or the puncher, `NO_MOBJ` for a floor) on behalf
/// of `source` (the shooter, `NO_MOBJ`). `thrust` is Doom's
/// `!source->player || readyweapon != wp_chainsaw` test, decided by the
/// caller. Player damage must already be net of armor.
pub fn damage_mobj(
    w: World,
    mobjs: Span<Mobj>,
    ref rng: Prng,
    ref target: Mobj,
    target_idx: u32,
    inflictor: u32,
    source: u32,
    damage: u32,
    thrust: bool,
) -> DamageOutcome {
    let mut out = DamageOutcome {
        died: false,
        pain: false,
        retaliated: false,
        action: fsm::NO_ACTION,
        counts_kill: false,
        drop: Option::None,
    };
    if !has(target.flags, MF_SHOOTABLE) {
        return out; // shouldn't happen...
    }
    if target.health <= 0 {
        return out;
    }
    if has(target.flags, MF_SKULLFLY) {
        target.momx = fixed::ZERO;
        target.momy = fixed::ZERO;
        target.momz = fixed::ZERO;
    }
    // Some close combat weapons should not inflict thrust on the target.
    if inflictor != NO_MOBJ && !has(target.flags, MF_NOCLIP) && thrust {
        let inf = mobjs.at(inflictor);
        let info = thing_info(target.kind);
        let mut ang = point_to_angle2(*inf.x, *inf.y, target.x, target.y);
        // thrust = damage * (FRACUNIT >> 3) * 100 / mass
        let mass: u128 = if info.mass == 0 {
            1
        } else {
            info.mass.into()
        };
        let d: u128 = damage.into();
        let mut thrust_raw: u128 = d * 8192 * 100 / mass;
        // Make fall forwards sometimes.
        let health: felt252 = target.health.into();
        let d_felt: felt252 = damage.into();
        if damage < 40
            && fixed::felt_ge(d_felt, health + 1)
            && fixed::gt(fixed::sub(target.z, *inf.z), Fixed { enc: BIAS + 64 * 65536 }) {
            let (next, roll) = rng.next(w.rndtable);
            rng = next;
            if roll % 2 == 1 {
                ang = bam::add(ang, bam::ANG180);
                thrust_raw = thrust_raw * 4;
            }
        }
        let t: felt252 = thrust_raw.into();
        let thrust_fixed = Fixed { enc: BIAS + t };
        let (s, c) = bam::sin_cos(ang);
        target.momx = fixed::add(target.momx, fixed::mul(thrust_fixed, c));
        target.momy = fixed::add(target.momy, fixed::mul(thrust_fixed, s));
    }

    // Do the damage.
    let d: i32 = damage.try_into().unwrap();
    target.health = target.health - d;
    if target.health <= 0 {
        out.died = true;
        out.counts_kill = has(target.flags, MF_COUNTKILL);
        let (action, drop) = kill_mobj(w, ref rng, ref target);
        out.action = action;
        out.drop = drop;
        return out;
    }

    let info = thing_info(target.kind);
    let (next, roll) = rng.next(w.rndtable);
    rng = next;
    let roll32: u32 = roll.into();
    if roll32 < info.painchance && !has(target.flags, MF_SKULLFLY) {
        target.flags = target.flags | MF_JUSTHIT; // fight back!
        out.pain = true;
        out.action = set_state(w, ref target, info.painstate);
    }
    target.reaction_time = 0; // we're awake now...

    if target.threshold == 0 && source != NO_MOBJ && source != target_idx {
        // If not intent on another player, chase after this one.
        target.target = source;
        target.threshold = BASETHRESHOLD;
        out.retaliated = true;
        if target.state == info.spawnstate && info.seestate != 0 {
            out.action = set_state(w, ref target, info.seestate);
        }
    }
    out
}
