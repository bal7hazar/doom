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
use super::num::{add32, div32, inc, mul32, rd32, sub32};
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
    if ammo == AM_NOAMMO || ammo >= 4 {
        return false;
    }
    let max = max_ammo(@p, ammo);
    let old = ammo_of(@p, ammo);
    if old == max {
        return false;
    }
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
    if old != 0 {
        // "If non zero ammo, don't change up weapons, player was lower on
        // purpose."
        return true;
    }
    if ammo == AM_CLIP {
        if p.ready_weapon == WP_FIST {
            p.pending_weapon = if owns(@p, WP_CHAINGUN) {
                WP_CHAINGUN
            } else {
                WP_PISTOL
            };
        }
    } else if ammo == AM_SHELL {
        if (p.ready_weapon == WP_FIST || p.ready_weapon == WP_PISTOL) && owns(@p, WP_SHOTGUN) {
            p.pending_weapon = WP_SHOTGUN;
        }
    }
    // `am_cell` and `am_misl` select the plasma rifle and the rocket
    // launcher, neither of which this roster carries.
    true
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
    if p.health >= MAXHEALTH {
        return false;
    }
    let raised = add32(p.health, num);
    p.health = if raised > MAXHEALTH {
        MAXHEALTH
    } else {
        raised
    };
    mo.health = health_i32(p.health);
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
    // Doom's one `switch (special->sprite)`, split in three so that no arm
    // of it keeps the `Player` + `Mobj` live set alive across 150 Sierra
    // statements: past that, `universal-sierra-compiler` cannot encode the
    // jump offsets (`Offset overflow`) under `inlining-strategy = "avoid"`,
    // which is the flag `cairo-coverage` requires.
    let took = match take_health(ref p, ref mo, kind) {
        Option::Some(v) => v,
        Option::None => match take_ammo(ref p, kind, dropped) {
            Option::Some(v) => v,
            Option::None => match take_weapon(ref p, ref mo, kind, dropped) {
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
fn take_health(ref p: Player, ref mo: Mobj, kind: u32) -> Option<bool> {
    if kind == KIND_MISC0 {
        Option::Some(give_armor(ref p, 1))
    } else if kind == KIND_MISC1 {
        Option::Some(give_armor(ref p, 2))
    } else if kind == KIND_MISC2 {
        Option::Some(bonus_health(ref p, ref mo, 1))
    } else if kind == KIND_MISC3 {
        Option::Some(bonus_armor(ref p))
    } else if kind == KIND_MISC4 {
        give_card(ref p, CARD_BLUE);
        Option::Some(true)
    } else if kind == KIND_MISC10 {
        Option::Some(give_body(ref p, ref mo, 10))
    } else if kind == KIND_MISC11 {
        Option::Some(give_body(ref p, ref mo, 25))
    } else if kind == KIND_MISC12 {
        Option::Some(bonus_health(ref p, ref mo, 100))
    } else if kind == KIND_MISC13 {
        give_strength(ref p, ref mo);
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
fn take_ammo(ref p: Player, kind: u32, dropped: bool) -> Option<bool> {
    if kind == KIND_CLIP {
        Option::Some(give_ammo(ref p, AM_CLIP, if dropped {
            0
        } else {
            1
        }))
    } else if kind == KIND_MISC17 {
        Option::Some(give_ammo(ref p, AM_CLIP, 5))
    } else if kind == KIND_MISC22 {
        Option::Some(give_ammo(ref p, AM_SHELL, 1))
    } else if kind == KIND_MISC23 {
        Option::Some(give_ammo(ref p, AM_SHELL, 5))
    } else if kind == KIND_MISC18 {
        Option::Some(give_ammo(ref p, AM_MISL, 1))
    } else if kind == KIND_MISC19 {
        Option::Some(give_ammo(ref p, AM_MISL, 5))
    } else if kind == KIND_MISC20 {
        Option::Some(give_ammo(ref p, AM_CELL, 1))
    } else if kind == KIND_MISC21 {
        Option::Some(give_ammo(ref p, AM_CELL, 5))
    } else {
        Option::None
    }
}

/// The backpack and the three weapons this roster carries as pickups.
fn take_weapon(ref p: Player, ref mo: Mobj, kind: u32, dropped: bool) -> Option<bool> {
    if kind == KIND_MISC24 {
        Option::Some(backpack(ref p))
    } else if kind == KIND_SHOTGUN {
        Option::Some(give_weapon(ref p, WP_SHOTGUN, dropped))
    } else if kind == KIND_CHAINGUN {
        Option::Some(give_weapon(ref p, WP_CHAINGUN, dropped))
    } else if kind == KIND_MISC26 {
        // The chainsaw takes no ammo, so `dropped` changes nothing here —
        // vanilla passes `false`.
        Option::Some(give_weapon(ref p, WP_CHAINSAW, dropped))
    } else {
        let _ = mo;
        Option::None
    }
}

/// `SPR_BON1` and `SPR_SOUL`: health that may go over 100%, up to 200.
fn bonus_health(ref p: Player, ref mo: Mobj, num: u32) -> bool {
    let raised = add32(p.health, num);
    p.health = if raised > MAXHEALTH_BONUS {
        MAXHEALTH_BONUS
    } else {
        raised
    };
    mo.health = health_i32(p.health);
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
    give_ammo(ref p, AM_CLIP, 1);
    give_ammo(ref p, AM_SHELL, 1);
    give_ammo(ref p, AM_CELL, 1);
    give_ammo(ref p, AM_MISL, 1);
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
