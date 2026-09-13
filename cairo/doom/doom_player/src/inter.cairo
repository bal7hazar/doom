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
use super::env::{Env, PlayerEvent};
use super::state::{
    AM_CELL, AM_CLIP, AM_MISL, AM_NOAMMO, AM_SHELL, BONUSADD, CARD_BLUE, CLIPAMMO, MAXARMOR_BONUS,
    MAXDAMAGECOUNT, MAXHEALTH, MAXHEALTH_BONUS, PST_DEAD, Player, WP_CHAINGUN, WP_CHAINSAW, WP_FIST,
    WP_PISTOL, WP_SHOTGUN, ammo_of, max_ammo, owns, set_ammo, weapon_ammo, weapon_bit,
};
use super::weapon::drop_weapon;

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
    let clip = *CLIPAMMO.span().at(ammo);
    let amount = if num != 0 {
        num * clip
    } else {
        clip / 2
    };
    let raised = old + amount;
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
    let raised = p.health + num;
    p.health = if raised > MAXHEALTH {
        MAXHEALTH
    } else {
        raised
    };
    mo.health = p.health.try_into().unwrap();
    true
}

/// `P_GiveArmor`: `armortype * 100` points, and only if that is an upgrade.
pub fn give_armor(ref p: Player, armortype: u32) -> bool {
    let hits = armortype * 100;
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
    let took = if kind == KIND_MISC0 {
        give_armor(ref p, 1)
    } else if kind == KIND_MISC1 {
        give_armor(ref p, 2)
    } else if kind == KIND_MISC2 {
        bonus_health(ref p, ref mo, 1)
    } else if kind == KIND_MISC3 {
        bonus_armor(ref p)
    } else if kind == KIND_MISC4 {
        give_card(ref p, CARD_BLUE);
        true
    } else if kind == KIND_MISC10 {
        give_body(ref p, ref mo, 10)
    } else if kind == KIND_MISC11 {
        give_body(ref p, ref mo, 25)
    } else if kind == KIND_MISC12 {
        bonus_health(ref p, ref mo, 100)
    } else if kind == KIND_MISC13 {
        give_strength(ref p, ref mo);
        if p.ready_weapon != WP_FIST {
            p.pending_weapon = WP_FIST;
        }
        true
    } else if kind == KIND_CLIP {
        give_ammo(ref p, AM_CLIP, if dropped {
            0
        } else {
            1
        })
    } else if kind == KIND_MISC17 {
        give_ammo(ref p, AM_CLIP, 5)
    } else if kind == KIND_MISC22 {
        give_ammo(ref p, AM_SHELL, 1)
    } else if kind == KIND_MISC23 {
        give_ammo(ref p, AM_SHELL, 5)
    } else if kind == KIND_MISC18 {
        give_ammo(ref p, AM_MISL, 1)
    } else if kind == KIND_MISC19 {
        give_ammo(ref p, AM_MISL, 5)
    } else if kind == KIND_MISC20 {
        give_ammo(ref p, AM_CELL, 1)
    } else if kind == KIND_MISC21 {
        give_ammo(ref p, AM_CELL, 5)
    } else if kind == KIND_MISC24 {
        backpack(ref p)
    } else if kind == KIND_SHOTGUN {
        give_weapon(ref p, WP_SHOTGUN, dropped)
    } else if kind == KIND_CHAINGUN {
        give_weapon(ref p, WP_CHAINGUN, dropped)
    } else if kind == KIND_MISC26 {
        give_weapon(ref p, WP_CHAINSAW, false)
    } else {
        // The rocket launcher and the plasma rifle are gettable in Doom but
        // have no slot in this five-weapon roster; both are multiplayer-only
        // placements on E1M1, so nothing spawns them at skill 2 and the item
        // is left on the floor rather than half-applied (README).
        false
    };
    if !took {
        return false;
    }
    if has(*special.flags, MF_COUNTITEM) {
        p.itemcount += 1;
    }
    p.bonuscount += BONUSADD;
    true
}

/// `SPR_BON1` and `SPR_SOUL`: health that may go over 100%, up to 200.
fn bonus_health(ref p: Player, ref mo: Mobj, num: u32) -> bool {
    let raised = p.health + num;
    p.health = if raised > MAXHEALTH_BONUS {
        MAXHEALTH_BONUS
    } else {
        raised
    };
    mo.health = p.health.try_into().unwrap();
    true
}

/// `SPR_BON2`: one armor point over the cap, and green armor if bare.
fn bonus_armor(ref p: Player) -> bool {
    let raised = p.armor_points + 1;
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
    if p.armor_type == 0 {
        return damage;
    }
    let mut saved = if p.armor_type == 1 {
        damage / 3
    } else {
        damage / 2
    };
    if p.armor_points <= saved {
        saved = p.armor_points;
        p.armor_type = 0;
    }
    p.armor_points -= saved;
    damage - saved
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
    let mut out = DamageOutcome {
        died: false,
        pain: false,
        retaliated: false,
        action: fsm::NO_ACTION,
        counts_kill: false,
        drop: Option::None,
    };
    if !has(mo.flags, MF_SHOOTABLE) || mo.health <= 0 {
        return out;
    }
    // Skill 2 is not `sk_baby`, so vanilla's `damage >>= 1` does not apply.
    let net = absorb(ref p, damage);
    p.health = if net >= p.health {
        0
    } else {
        p.health - net
    };
    p.attacker = source;
    let count = p.damagecount + net;
    p.damagecount = if count > MAXDAMAGECOUNT {
        MAXDAMAGECOUNT
    } else {
        count
    };
    let w = env.world.unbox();
    out = damage_mobj(w, env.mobjs, ref rng, ref mo, env.me, inflictor, source, net, thrust);
    if out.died {
        p.playerstate = PST_DEAD;
        drop_weapon(env, ref g, ref rng, ref p, ref mo, ref events);
    }
    out
}

/// `P_KillMobj`'s `source->player->killcount++`: `doom_game` calls this when
/// a `DamageOutcome` whose source was the player reports `counts_kill`.
pub fn count_kill(ref p: Player) {
    p.killcount += 1;
}

/// The `NO_MOBJ` sentinel, re-exported so a caller need not depend on
/// `doom_physics` just to say "no inflictor" (sector damage).
pub fn nobody() -> u32 {
    NO_MOBJ
}
