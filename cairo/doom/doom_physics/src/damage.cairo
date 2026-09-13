// SPDX-License-Identifier: GPL-2.0-only
//! `P_DamageMobj` and `P_KillMobj` (`p_inter.c`), on the target as a value.
//!
//! The target is the mobj the caller owns; the inflictor and the source are
//! read from the tic's `Span<Box<Mobj>>`. `damage_mobj_with_defense` applies
//! player armor after raw thrust and before health/pain/death. Player owns
//! the persistent defense fields, weapon drop and `PST_DEAD`; the ticker
//! carries a temporary `PlayerDefense` so later impacts see net health.
//!
//! The public functions return a 27-felt `Mobj` and a `DamageOutcome` with
//! an `Option<Mobj>` inside: every return point and every panic site in
//! their frame costs that whole width in bytecode (S7 §2), so each has a
//! single return, the helpers take and return **scalars** (never the
//! `Mobj`), the arithmetic that can panic (the thrust) is one of them, and
//! the dropped item is spawned last.

use bam::point_to_angle2;
use doom_things::ThingInfo;
use doom_things::tables::{KIND_CLIP, KIND_PLAYER, KIND_POSSESSED, KIND_SHOTGUN, KIND_SHOTGUY};
use fixed::{BIAS, Fixed, felt_ge_narrow};
use fsm::StateTables;
use prng::Prng;
use super::maputl::to_u128;
use super::mobj::{
    MF_CORPSE, MF_COUNTKILL, MF_DROPOFF, MF_DROPPED, MF_FLOAT, MF_JUSTHIT, MF_NOCLIP, MF_NOGRAVITY,
    MF_SHOOTABLE, MF_SKULLFLY, MF_SOLID, Mobj, NO_MOBJ, has, without,
};
use super::spawn::{SpawnZ, info_of, roll, shorten_tics, spawn_in, state_entry};
use super::world::{Level, World, level_of};

/// The single player's damage bookkeeping for one monster/missile pass.
/// This belongs below `doom_player` to avoid a dependency cycle. It is not
/// serialized: the game seeds it from Player and writes it back after the pass.
#[derive(Copy, Drop, PartialEq, Debug)]
pub struct PlayerDefense {
    pub mo: u32,
    pub armor_points: u32,
    pub armor_type: u32,
    pub damagecount: u32,
    pub attacker: u32,
}

/// Historical physics/monster callers have no player defense to apply.
pub fn no_player_defense() -> PlayerDefense {
    PlayerDefense { mo: NO_MOBJ, armor_points: 0, armor_type: 0, damagecount: 0, attacker: NO_MOBJ }
}

/// P_DamageMobj's player arm, once per live impact and after raw-damage
/// thrust. The box keeps five fields out of the monster dispatch's frames.
fn absorb_impact(ref defense: Box<PlayerDefense>, target: u32, source: u32, damage: u32) -> u32 {
    let cur = defense.unbox();
    if target != cur.mo {
        return damage;
    }
    let mut saved: u32 = 0;
    let mut kind = cur.armor_type;
    if kind != 0 {
        let third: NonZero<u32> = 3;
        let half: NonZero<u32> = 2;
        let (full, _) = DivRem::div_rem(damage, if kind == 1 {
            third
        } else {
            half
        });
        saved = if cur.armor_points <= full {
            kind = 0;
            cur.armor_points
        } else {
            full
        };
    }
    let net = super::maputl::sub32(damage, saved);
    let count: felt252 = cur.damagecount.into() + net.into();
    defense =
        BoxTrait::new(
            PlayerDefense {
                armor_points: super::maputl::sub32(cur.armor_points, saved),
                armor_type: kind,
                damagecount: if felt_ge_narrow(count, 100) {
                    100
                } else {
                    super::maputl::low32(to_u128(count))
                },
                attacker: source,
                ..cur,
            },
        );
    net
}

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

/// `h >> 2` on a positive height.
fn quarter(h: Fixed) -> Fixed {
    let four: NonZero<u128> = 4;
    let (v, _) = DivRem::div_rem(to_u128(h.enc - BIAS), four);
    let q: felt252 = v.into();
    Fixed { enc: q + BIAS }
}

/// `health < -spawnhealth`: the corpse gibs.
fn gibs(health: i32, spawnhealth: u32) -> bool {
    // health + spawnhealth < 0, in the field with a bias (both terms are
    // below 2^31 in magnitude).
    let h: felt252 = health.into();
    let s: felt252 = spawnhealth.into();
    !felt_ge_narrow(h + s + BIAS, BIAS)
}

/// What `P_KillMobj` writes back: the corpse's flags, height, state and
/// tics, the action of the death state and the kind of item to drop.
#[derive(Copy, Drop)]
struct Kill {
    flags: u32,
    height: Fixed,
    state: u32,
    tics: u32,
    action: u32,
    item: u32,
}

/// `P_KillMobj` minus the drop, on the fields it reads.
fn kill_core(
    states: StateTables,
    rnd: Span<u8>,
    ref rng: Prng,
    kind: u32,
    flags: u32,
    height: Fixed,
    health: i32,
    info: ThingInfo,
) -> Kill {
    let mut flags = without(flags, MF_SHOOTABLE + MF_FLOAT + MF_SKULLFLY);
    if kind != super::spawn::KIND_SKULL {
        flags = without(flags, MF_NOGRAVITY);
    }
    flags = flags | MF_CORPSE | MF_DROPOFF;
    if kind == KIND_PLAYER {
        flags = without(flags, MF_SOLID);
    }
    let state = if info.xdeathstate != 0 && gibs(health, info.spawnhealth) {
        info.xdeathstate
    } else {
        info.deathstate
    };
    let (tics, action) = state_entry(states, state);
    // Drop stuff: the same random-position-free spawn as `P_KillMobj`.
    let item = if kind == KIND_POSSESSED {
        KIND_CLIP
    } else if kind == KIND_SHOTGUY {
        KIND_SHOTGUN
    } else {
        NO_MOBJ
    };
    Kill {
        flags, height: quarter(height), state, tics: shorten_tics(rnd, ref rng, tics), action, item,
    }
}

/// The dropped item of a kill (`MF_DROPPED` set), when there is one.
fn drop_of(lv: Level, states: StateTables, item: u32, x: Fixed, y: Fixed) -> Option<Mobj> {
    if item == NO_MOBJ {
        return Option::None;
    }
    let mut mo = spawn_in(lv, states, item, x, y, SpawnZ::OnFloor);
    mo.flags = mo.flags | MF_DROPPED; // special versions of items
    Option::Some(mo)
}

/// `P_KillMobj` on `target` (health already ≤ 0): corpse flags, the death
/// or gib state with Doom's random tic shortening, and the dropped item.
pub fn kill_mobj(w: World, ref rng: Prng, ref target: Mobj) -> (u32, Option<Mobj>) {
    let k = kill_core(
        w.states,
        w.rndtable,
        ref rng,
        target.kind,
        target.flags,
        target.height,
        target.health,
        info_of(target.kind),
    );
    target.flags = k.flags;
    target.height = k.height;
    target.state = k.state;
    target.tics = k.tics;
    (k.action, drop_of(level_of(w), w.states, k.item, target.x, target.y))
}

/// The momentum `P_DamageMobj` adds to a target hit from `inflictor`:
/// `damage * (FRACUNIT >> 3) * 100 / mass` along the angle from the
/// inflictor, quadrupled and reversed when the blow makes it fall forward.
fn thrust_of(
    rnd: Span<u8>,
    ref rng: Prng,
    mobjs: Span<Box<Mobj>>,
    inflictor: u32,
    x: Fixed,
    y: Fixed,
    z: Fixed,
    health: i32,
    mass: u32,
    damage: u32,
) -> (Fixed, Fixed) {
    let (ix, iy, iz) = match mobjs.get(inflictor) {
        Option::Some(b) => {
            let inf = b.unbox().as_snapshot().unbox();
            (*inf.x, *inf.y, *inf.z)
        },
        Option::None => (x, y, z),
    };
    let mut ang = point_to_angle2(ix, iy, x, y);
    // thrust = damage * (FRACUNIT >> 3) * 100 / mass, in the field then one
    // u128 division (a zero mass reads as 1, as in the original).
    let d_felt: felt252 = damage.into();
    let mass_opt: Option<NonZero<u128>> = to_u128(mass.into()).try_into();
    let mass_nz: NonZero<u128> = match mass_opt {
        Option::Some(m) => m,
        Option::None => 1,
    };
    let (q, _) = DivRem::div_rem(to_u128(d_felt * 819200), mass_nz);
    let mut thrust_raw: felt252 = q.into();
    // Make fall forwards sometimes.
    let h: felt252 = health.into();
    if damage < 40
        && felt_ge_narrow(d_felt, h + 1)
        && fixed::gt(fixed::sub(z, iz), Fixed { enc: BIAS + 64 * 65536 }) {
        let r = roll(ref rng, rnd);
        let two: NonZero<u8> = 2;
        let (_, odd) = DivRem::div_rem(r, two);
        if odd == 1 {
            ang = bam::add(ang, bam::ANG180);
            thrust_raw = thrust_raw * 4;
        }
    }
    let thrust_fixed = Fixed { enc: BIAS + thrust_raw };
    let (s, c) = bam::sin_cos(ang);
    (fixed::mul(thrust_fixed, c), fixed::mul(thrust_fixed, s))
}

/// `health - damage` on the signed health, in the field (no overflow
/// path: both are below 2^31).
fn hurt(health: i32, damage: u32) -> i32 {
    let h: felt252 = health.into() - damage.into();
    let r: Option<i32> = h.try_into();
    match r {
        Option::Some(v) => v,
        Option::None => health,
    }
}

/// What a surviving target's reaction writes back.
#[derive(Copy, Drop)]
struct Reaction {
    pain: bool,
    retaliated: bool,
    action: u32,
    flags: u32,
    threshold: u32,
    target: u32,
    /// The state entered, if any: `(state, tics)`.
    entered: Option<(u32, u32)>,
}

/// The reaction of a target that survived the blow (`P_DamageMobj` after
/// the health test): pain and retaliation, on the fields it reads.
fn react(
    states: StateTables,
    rnd: Span<u8>,
    ref rng: Prng,
    flags: u32,
    state: u32,
    threshold: u32,
    target: u32,
    target_idx: u32,
    source: u32,
    info: ThingInfo,
) -> Reaction {
    let r: u32 = roll(ref rng, rnd).into();
    let mut flags = flags;
    let mut state = state;
    let mut action = fsm::NO_ACTION;
    let mut entered = Option::None;
    let pain = r < info.painchance && !has(flags, MF_SKULLFLY);
    if pain {
        flags = flags | MF_JUSTHIT; // fight back!
        let (tics, a) = state_entry(states, info.painstate);
        action = a;
        state = info.painstate;
        entered = Option::Some((info.painstate, tics));
    }
    let mut threshold = threshold;
    let mut target = target;
    let retaliated = threshold == 0 && source != NO_MOBJ && source != target_idx;
    if retaliated {
        // If not intent on another player, chase after this one.
        target = source;
        threshold = BASETHRESHOLD;
        // The state *after* the pain transition, as in `P_DamageMobj`.
        if state == info.spawnstate && info.seestate != 0 {
            let (tics, a) = state_entry(states, info.seestate);
            action = a;
            entered = Option::Some((info.seestate, tics));
        }
    }
    Reaction { pain, retaliated, action, flags, threshold, target, entered }
}

/// `P_DamageMobj`: `damage` points to `target` (index `target_idx`) from
/// `inflictor` (the missile or the puncher, `NO_MOBJ` for a floor) on behalf
/// of `source` (the shooter, `NO_MOBJ`). `thrust` is Doom's
/// `!source->player || readyweapon != wp_chainsaw` test, decided by the
/// caller. Player damage must already be net of armor.
// Inline only this adapter: a second World/Mobj frame costs ~160 steps.
// The damage implementation below remains shared by both entry points.
#[inline(always)]
pub fn damage_mobj(
    w: World,
    mobjs: Span<Box<Mobj>>,
    ref rng: Prng,
    ref target: Mobj,
    target_idx: u32,
    inflictor: u32,
    source: u32,
    damage: u32,
    thrust: bool,
) -> DamageOutcome {
    let mut defense = BoxTrait::new(no_player_defense());
    damage_mobj_with_defense(
        w, mobjs, ref rng, ref target, target_idx, inflictor, source, damage, thrust, ref defense,
    )
}

/// Damage with the player's defense: raw thrust first, armor per impact,
/// then health, pain or death. A corpse never spends armor or draws again.
pub fn damage_mobj_with_defense(
    w: World,
    mobjs: Span<Box<Mobj>>,
    ref rng: Prng,
    ref target: Mobj,
    target_idx: u32,
    inflictor: u32,
    source: u32,
    damage: u32,
    thrust: bool,
    ref defense: Box<PlayerDefense>,
) -> DamageOutcome {
    let alive = has(target.flags, MF_SHOOTABLE) && target.health > 0;
    let mut died = false;
    let mut pain = false;
    let mut retaliated = false;
    let mut action = fsm::NO_ACTION;
    let mut counts_kill = false;
    let mut item = NO_MOBJ;
    // The fields the blow may change, written back once at the end.
    let mut flags = target.flags;
    let mut momx = target.momx;
    let mut momy = target.momy;
    let mut momz = target.momz;
    let mut health = target.health;
    let mut state = target.state;
    let mut tics = target.tics;
    let mut height = target.height;
    let mut reaction_time = target.reaction_time;
    let mut threshold = target.threshold;
    let mut chasing = target.target;
    if alive {
        if has(flags, MF_SKULLFLY) {
            momx = fixed::ZERO;
            momy = fixed::ZERO;
            momz = fixed::ZERO;
        }
        let info = info_of(target.kind);
        // Some close combat weapons should not inflict thrust on the target.
        if inflictor != NO_MOBJ && !has(flags, MF_NOCLIP) && thrust {
            let (dx, dy) = thrust_of(
                w.rndtable,
                ref rng,
                mobjs,
                inflictor,
                target.x,
                target.y,
                target.z,
                health,
                info.mass,
                damage,
            );
            momx = fixed::add(momx, dx);
            momy = fixed::add(momy, dy);
        }
        // Armor must precede the lethal/pain decision, but not raw thrust.
        let net = absorb_impact(ref defense, target_idx, source, damage);
        health = hurt(health, net);
        if health <= 0 {
            died = true;
            counts_kill = has(flags, MF_COUNTKILL);
            let k = kill_core(
                w.states, w.rndtable, ref rng, target.kind, flags, height, health, info,
            );
            flags = k.flags;
            height = k.height;
            state = k.state;
            tics = k.tics;
            action = k.action;
            item = k.item;
        } else {
            let r = react(
                w.states,
                w.rndtable,
                ref rng,
                flags,
                state,
                threshold,
                chasing,
                target_idx,
                source,
                info,
            );
            pain = r.pain;
            retaliated = r.retaliated;
            action = r.action;
            flags = r.flags;
            reaction_time = 0; // we're awake now...
            threshold = r.threshold;
            chasing = r.target;
            if let Option::Some((s, t)) = r.entered {
                state = s;
                tics = t;
            }
        }
    }
    target.flags = flags;
    target.momx = momx;
    target.momy = momy;
    target.momz = momz;
    target.health = health;
    target.state = state;
    target.tics = tics;
    target.height = height;
    target.reaction_time = reaction_time;
    target.threshold = threshold;
    target.target = chasing;
    DamageOutcome {
        died,
        pain,
        retaliated,
        action,
        counts_kill,
        drop: drop_of(level_of(w), w.states, item, target.x, target.y),
    }
}
