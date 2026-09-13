// SPDX-License-Identifier: GPL-2.0-only
//! Pickups and the player's half of the damage rules — linuxdoom-1.10's
//! `p_inter.c`: `P_GiveAmmo`, `P_GiveWeapon`, `P_GiveBody`, `P_GiveArmor`,
//! `P_GiveCard`, `P_GivePower`, `P_TouchSpecialThing`, and the armor
//! absorption `P_DamageMobj` applies before a player's mobj loses health.

use doom_physics::{
    DamageOutcome, MF_COUNTITEM, MF_DROPPED, MF_SHOOTABLE, Mobj, NO_MOBJ, ThingGrid, damage_mobj,
    has,
};
use doom_things::tables::{
    KIND_CHAINGUN, KIND_CLIP, KIND_MISC0, KIND_MISC1, KIND_MISC10, KIND_MISC11, KIND_MISC12,
    KIND_MISC13, KIND_MISC17, KIND_MISC18, KIND_MISC19, KIND_MISC2, KIND_MISC20, KIND_MISC21,
    KIND_MISC22, KIND_MISC23, KIND_MISC24, KIND_MISC26, KIND_MISC3, KIND_MISC4, KIND_SHOTGUN,
};
use fixed::{BIAS, Fixed};
use prng::Prng;
use super::env::{Env, PlayerEvent, enter, leave};
use super::num::{add32, div32, inc, mul32, opaque_zero, rd32, sub32};
use super::state::{
    AM_CELL, AM_CLIP, AM_MISL, AM_NOAMMO, AM_SHELL, BONUSADD, CARD_BLUE, CLIPAMMO, MAXARMOR_BONUS,
    MAXDAMAGECOUNT, MAXHEALTH, MAXHEALTH_BONUS, PST_DEAD, Player, WP_CHAINGUN, WP_CHAINSAW, WP_FIST,
    WP_PISTOL, WP_SHOTGUN, ammo_of, max_ammo, owns, set_ammo, weapon_ammo, weapon_bit,
};
use super::weapon::drop_weapon_in;

// ---------------------------------------------------------------------------
// P_Give*
// ---------------------------------------------------------------------------

/// `P_GiveAmmo(player, ammo, num)`: `num` **clips** (0 means half a clip, as
/// a dropped weapon's does). Returns Doom's "did it do anything".
///
/// Skill 2 is neither `sk_baby` nor `sk_nightmare`, so the doubling vanilla
/// applies on those two skills is absent (D3).
pub fn give_ammo(ref p: Player, ammo: u32, num: u32) -> bool {
    let mut gave = false;
    if ammo != AM_NOAMMO && ammo < 4 {
        let max = max_ammo(@p, ammo);
        let old = ammo_of(@p, ammo);
        if old != max {
            let clip = rd32(CLIPAMMO.span(), ammo);
            let two: NonZero<u32> = 2;
            let amount = if num != 0 {
                mul32(num, clip)
            } else {
                div32(clip, two)
            };
            let raised = add32(old, amount);
            let now = if raised > max {
                max
            } else {
                raised
            };
            p = set_ammo(p, ammo, now);
            if old == 0 {
                if ammo == AM_CLIP {
                    if p.ready_weapon == WP_FIST {
                        p
                            .pending_weapon =
                                if owns(@p, WP_CHAINGUN) {
                                    WP_CHAINGUN
                                } else {
                                    WP_PISTOL
                                };
                    }
                } else if ammo == AM_SHELL {
                    if (p.ready_weapon == WP_FIST || p.ready_weapon == WP_PISTOL)
                        && owns(@p, WP_SHOTGUN) {
                        p.pending_weapon = WP_SHOTGUN;
                    }
                }
            }
            gave = true;
        }
    }
    gave
}

/// `P_GiveWeapon`: one clip with a dropped weapon, two with a found one.
pub fn give_weapon(ref p: Player, weapon: u32, dropped: bool) -> bool {
    let ammo = weapon_ammo(weapon);
    let gave_ammo = if ammo != AM_NOAMMO {
        give_ammo(ref p, ammo, if dropped {
            1
        } else {
            2
        })
    } else {
        false
    };
    if owns(@p, weapon) {
        return gave_ammo;
    }
    p.weapons = p.weapons | weapon_bit(weapon);
    p.pending_weapon = weapon;
    true
}

/// `P_GiveBody`: heal up to [`MAXHEALTH`], never past it.
pub fn give_body(ref p: Player, ref mo: Mobj, num: u32) -> bool {
    let healed = give_body_p(ref p, num);
    if healed {
        mo.health = health_i32(p.health);
    }
    healed
}

/// `P_GiveBody` without the mobj: it and `SPR_BON1`/`SPR_SOUL` all mirror
/// the new health into `mo.health`, which [`touch_special`] now does once for
/// the whole pickup — so the 27-felt `ref Mobj` stays out of the pickup
/// dispatch (S7 §8 rule 3).
fn give_body_p(ref p: Player, num: u32) -> bool {
    if p.health >= MAXHEALTH {
        return false;
    }
    let raised = add32(p.health, num);
    p.health = if raised > MAXHEALTH {
        MAXHEALTH
    } else {
        raised
    };
    true
}

/// `player->health` mirrored into `mo->health`, without the `try_into`
/// panic: health is capped at 200 by every caller, so the conversion is
/// exact, and an impossible value reads as `0` rather than aborting a proof.
fn health_i32(health: u32) -> i32 {
    match health.try_into() {
        Option::Some(v) => v,
        Option::None => 0,
    }
}

/// `P_GiveArmor`: `armortype * 100` points, and only if that is an upgrade.
pub fn give_armor(ref p: Player, armortype: u32) -> bool {
    let hits = mul32(armortype, 100);
    if p.armor_points >= hits {
        return false;
    }
    p.armor_type = armortype;
    p.armor_points = hits;
    true
}

/// `P_GiveCard`: a key is never refused, and adds [`BONUSADD`] on its own.
pub fn give_card(ref p: Player, card: u32) {
    if (p.cards & card) != 0 {
        return;
    }
    p.bonuscount = BONUSADD;
    p.cards = p.cards | card;
}

/// `P_GivePower(pw_strength)`, the berserk pack: it heals to 100 first.
pub fn give_strength(ref p: Player, ref mo: Mobj) -> bool {
    give_body(ref p, ref mo, 100);
    p.strength = 1;
    true
}

/// [`give_strength`] without the mobj (see [`give_body_p`]).
fn give_strength_p(ref p: Player) -> bool {
    give_body_p(ref p, 100);
    p.strength = 1;
    true
}

// ---------------------------------------------------------------------------
// P_TouchSpecialThing
// ---------------------------------------------------------------------------

/// `P_TouchSpecialThing(special, toucher)`: `true` when the item was taken
/// and `doom_game` must remove its mobj.
///
/// Driven by `doom_physics::MoveEvent::Touch`, which fires whenever an
/// `MF_PICKUP` mover's box overlaps an `MF_SPECIAL` thing; the reach test
/// (Doom does it here, not in `PIT_CheckThing`) is the first thing below.
pub fn touch_special(ref p: Player, ref mo: Mobj, special: @Mobj) -> bool {
    // Out of reach vertically.
    let delta = fixed::sub(*special.z, mo.z);
    if fixed::gt(delta, mo.height) || fixed::lt(delta, Fixed { enc: BIAS - 8 * 65536 }) {
        return false;
    }
    // Dead thing touching (a sliding player corpse).
    if mo.health <= 0 {
        return false;
    }
    let kind = *special.kind;
    let dropped = has(*special.flags, MF_DROPPED);
    let before = p.health;
    // Doom's one `switch (special->sprite)`, split in three so that no arm
    // of it keeps the `Player` live set alive across 150 Sierra statements:
    // past that, `universal-sierra-compiler` cannot encode the jump offsets
    // (`Offset overflow`) under `inlining-strategy = "avoid"`, which is the
    // flag `cairo-coverage` requires.
    //
    // **The mobj does not go down the dispatch** (S7 §8 rule 3): the only
    // field any pickup writes on it is `health`, which the `P_Give*` of
    // `p_inter.c` set to the player's new health — so the mirror happens
    // here, once, and 27 felts stay out of three call boundaries. The one
    // case vanilla writes and this does not is a health item taken at the
    // cap, where the value written is the one already there (`mo.health`
    // equals `player->health` whenever it is positive, which the reach test
    // above has just established).
    let took = match take_health(ref p, kind) {
        Option::Some(v) => v,
        Option::None => match take_ammo(ref p, kind, dropped) {
            Option::Some(v) => v,
            Option::None => match take_weapon(ref p, kind, dropped) {
                Option::Some(v) => v,
                // The rocket launcher and the plasma rifle can be picked up
                // in Doom but have no slot in this five-weapon roster; both
                // are multiplayer-only placements on E1M1, so nothing spawns
                // them at skill 2 and the item is left on the floor rather
                // than half-applied (README, "Known departures").
                Option::None => false,
            },
        },
    };
    if p.health != before {
        mo.health = health_i32(p.health);
    }
    if !took {
        return false;
    }
    if has(*special.flags, MF_COUNTITEM) {
        p.itemcount = inc(p.itemcount);
    }
    p.bonuscount = add32(p.bonuscount, BONUSADD);
    true
}

/// The health, armor, key and power half of `P_TouchSpecialThing`.
/// `None` when `kind` is none of them.
fn take_health(ref p: Player, kind: u32) -> Option<bool> {
    // The two armor arms and the four health arms each reach `give_armor` /
    // `give_body_p` / `bonus_health` once, with the amount as a variable: a
    // literal argument gets the callee a specialised copy of its body
    // (S7 §2, and `take_ammo` above).
    if kind == KIND_MISC0 || kind == KIND_MISC1 {
        let kinds = if kind == KIND_MISC0 {
            1
        } else {
            2
        };
        Option::Some(give_armor(ref p, kinds))
    } else if kind == KIND_MISC10 || kind == KIND_MISC11 {
        let num = if kind == KIND_MISC10 {
            10
        } else {
            25
        };
        Option::Some(give_body_p(ref p, num))
    } else if kind == KIND_MISC2 || kind == KIND_MISC12 {
        let num = if kind == KIND_MISC2 {
            1
        } else {
            100
        };
        Option::Some(bonus_health(ref p, num))
    } else if kind == KIND_MISC3 {
        Option::Some(bonus_armor(ref p))
    } else if kind == KIND_MISC4 {
        give_card(ref p, CARD_BLUE);
        Option::Some(true)
    } else if kind == KIND_MISC13 {
        give_strength_p(ref p);
        if p.ready_weapon != WP_FIST {
            p.pending_weapon = WP_FIST;
        }
        Option::Some(true)
    } else {
        Option::None
    }
}

/// The ammo half. The clip is the one item whose `MF_DROPPED` changes what
/// it gives (half a clip instead of one).
///
/// The eight arms pick `(type, clips)` and there is **one** call to
/// [`give_ammo`]: with a literal at each arm the lowering specialised the
/// callee on it, and `bench/attribute.py` found nine copies of `give_ammo`
/// for 3 562 words (S7 §2, §8 rule 4).
fn take_ammo(ref p: Player, kind: u32, dropped: bool) -> Option<bool> {
    let (ammo, clips) = if kind == KIND_CLIP {
        (AM_CLIP, if dropped {
            0
        } else {
            1
        })
    } else if kind == KIND_MISC17 {
        (AM_CLIP, 5)
    } else if kind == KIND_MISC22 {
        (AM_SHELL, 1)
    } else if kind == KIND_MISC23 {
        (AM_SHELL, 5)
    } else if kind == KIND_MISC18 {
        (AM_MISL, 1)
    } else if kind == KIND_MISC19 {
        (AM_MISL, 5)
    } else if kind == KIND_MISC20 {
        (AM_CELL, 1)
    } else if kind == KIND_MISC21 {
        (AM_CELL, 5)
    } else {
        return Option::None;
    };
    Option::Some(give_ammo(ref p, ammo, clips))
}

/// The backpack and the three weapons this roster carries as pickups.
/// One call to [`give_weapon`], for the reason [`take_ammo`] gives.
fn take_weapon(ref p: Player, kind: u32, dropped: bool) -> Option<bool> {
    if kind == KIND_MISC24 {
        return Option::Some(backpack(ref p));
    }
    let weapon = if kind == KIND_SHOTGUN {
        WP_SHOTGUN
    } else if kind == KIND_CHAINGUN {
        WP_CHAINGUN
    } else if kind == KIND_MISC26 {
        // The chainsaw takes no ammo, so `dropped` changes nothing here —
        // vanilla passes `false`.
        WP_CHAINSAW
    } else {
        return Option::None;
    };
    Option::Some(give_weapon(ref p, weapon, dropped))
}

/// `SPR_BON1` and `SPR_SOUL`: health that may go over 100%, up to 200.
fn bonus_health(ref p: Player, num: u32) -> bool {
    let raised = add32(p.health, num);
    p.health = if raised > MAXHEALTH_BONUS {
        MAXHEALTH_BONUS
    } else {
        raised
    };
    true
}

/// `SPR_BON2`: one armor point over the cap, and green armor if bare.
fn bonus_armor(ref p: Player) -> bool {
    let raised = inc(p.armor_points);
    p.armor_points = if raised > MAXARMOR_BONUS {
        MAXARMOR_BONUS
    } else {
        raised
    };
    if p.armor_type == 0 {
        p.armor_type = 1;
    }
    true
}

/// `SPR_BPAK`: double every maximum once, then one clip of each type.
fn backpack(ref p: Player) -> bool {
    if !p.backpack {
        p.backpack = true;
    }
    // `am_clip, am_shell, am_cell, am_misl`, in that order — as a loop from
    // an opaque zero, so that neither the counter nor the clip count is a
    // literal at the call site (S7 §8 rules 4 and 7).
    let one = inc(opaque_zero(p.weapons));
    let mut t = opaque_zero(p.weapons);
    while t != 4 {
        give_ammo(ref p, t, one);
        t = inc(t);
    }
    true
}

// ---------------------------------------------------------------------------
// P_DamageMobj, the player's half
// ---------------------------------------------------------------------------

/// The armor absorption of `P_DamageMobj`: green armor eats a third of the
/// damage, blue a half, and both stop when the points run out.
///
/// Returns the damage that reaches the player's health.
pub fn absorb(ref p: Player, damage: u32) -> u32 {
    let (points, kind, net) = absorb_of(p.armor_points, p.armor_type, damage);
    p.armor_points = points;
    p.armor_type = kind;
    net
}

/// [`absorb`] as a pure function: `(armor_points, armor_type, net damage)`,
/// so the caller folds the two writes into whatever rebuild it already does.
fn absorb_of(armor_points: u32, armor_type: u32, damage: u32) -> (u32, u32, u32) {
    if armor_type == 0 {
        return (armor_points, armor_type, damage);
    }
    let third: NonZero<u32> = 3;
    let half: NonZero<u32> = 2;
    let full = if armor_type == 1 {
        div32(damage, third)
    } else {
        div32(damage, half)
    };
    let (saved, kind) = if armor_points <= full {
        (armor_points, 0)
    } else {
        (full, armor_type)
    };
    (sub32(armor_points, saved), kind, sub32(damage, saved))
}

/// `P_DamageMobj` on the player: armor, `damagecount`, `attacker`, then
/// `doom_physics::damage_mobj` with the *net* damage (which is the contract
/// that crate documents), and `PST_DEAD` + `P_DropWeapon` on death.
///
/// `thrust` is Doom's `!source->player || readyweapon != wp_chainsaw`.
#[inline(always)]
pub fn damage_player(
    env: Env,
    ref g: ThingGrid,
    ref rng: Prng,
    ref p: Player,
    ref mo: Mobj,
    ref events: Array<PlayerEvent>,
    inflictor: u32,
    source: u32,
    damage: u32,
    thrust: bool,
) -> DamageOutcome {
    let (cx, mut bp, mut bm) = enter(env, @p, @mo);
    let out = damage_player_in(
        cx, ref g, ref rng, ref bp, ref bm, ref events, inflictor, source, damage, thrust,
    );
    leave(bp, bm, ref p, ref mo);
    out
}

/// [`damage_player`] on the boxed operands the tic already carries.
///
/// One `return`: `DamageOutcome` is seven felts and the compiler copies a
/// return into every branch that reaches it (S7 §8 rule 2), so the "not
/// shootable" arm and the damaged arm meet at the end.
pub(crate) fn damage_player_in(
    env: Box<Env>,
    ref g: ThingGrid,
    ref rng: Prng,
    ref p: Box<Player>,
    ref mo: Box<Mobj>,
    ref events: Array<PlayerEvent>,
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
    if has(mo.flags, MF_SHOOTABLE) && mo.health > 0 {
        // Skill 2 is not `sk_baby`, so vanilla's `damage >>= 1` does not
        // apply. `absorb` also writes `armor_points`/`armor_type`, so the
        // record is rebuilt once with everything the hit changes.
        let cur = p.unbox();
        let (armor_points, armor_type, net) = absorb_of(cur.armor_points, cur.armor_type, damage);
        let count = add32(cur.damagecount, net);
        p =
            BoxTrait::new(
                Player {
                    armor_points,
                    armor_type,
                    health: if net >= cur.health {
                        0
                    } else {
                        sub32(cur.health, net)
                    },
                    attacker: source,
                    damagecount: if count > MAXDAMAGECOUNT {
                        MAXDAMAGECOUNT
                    } else {
                        count
                    },
                    ..cur,
                },
            );
        // `damage_mobj` is `doom_physics`' and wants the record itself.
        let mut m = mo.unbox();
        out =
            damage_mobj(
                env.world.unbox(),
                env.mobjs,
                ref rng,
                ref m,
                env.me,
                inflictor,
                source,
                net,
                thrust,
            );
        mo = BoxTrait::new(m);
        if out.died {
            p = BoxTrait::new(Player { playerstate: PST_DEAD, ..p.unbox() });
            drop_weapon_in(env, ref g, ref rng, ref p, ref mo, ref events);
        }
    }
    out
}

/// `P_KillMobj`'s `source->player->killcount++`: `doom_game` calls this when
/// a `DamageOutcome` whose source was the player reports `counts_kill`.
pub fn count_kill(ref p: Player) {
    p.killcount = inc(p.killcount);
}

/// The `NO_MOBJ` sentinel, re-exported so a caller need not depend on
/// `doom_physics` just to say "no inflictor" (sector damage).
pub fn nobody() -> u32 {
    NO_MOBJ
}
