// SPDX-License-Identifier: GPL-2.0-only
//! The player's weapon sprites and the actions their states run —
//! linuxdoom-1.10's `p_pspr.c`, over `doom_things`' `weaponinfo` chains and
//! `fsm`'s state columns.
//!
//! Cairo has no function pointers, so a state carries an **action id**
//! (D15); [`run_action`] is this crate's dispatch table for the eleven ids
//! `d_items.c`'s five weapon chains can reach.

use bam::{Angle, point_to_angle2};
use doom_physics::spawn::{roll, state_entry};
use doom_physics::{
    AIMRANGE, Hit, MELEERANGE, MF_JUSTATTACKED, MISSILERANGE, Mobj, NO_MOBJ, ThingGrid, World,
    aim_line_attack, line_attack,
};
use doom_things::tables::{
    A_FIRECGUN, A_FIREPISTOL, A_FIRESHOTGUN, A_LIGHT0, A_LIGHT1, A_LIGHT2, A_LOWER, A_PUNCH,
    A_RAISE, A_REFIRE, A_SAW, A_WEAPONREADY,
};
use doom_things::{WeaponId, WeaponStates, weapon_states};
use fixed::{BIAS, Fixed};
use prng::Prng;
use super::env::{Env, PlayerEvent};
use super::num::{add32, dec, fine_of, half_fine, inc, mul32, rd32};
use super::state::{
    AM_NOAMMO, BT_ATTACK, MAXBOB, PST_DEAD, Player, RAISESPEED, WEAPONBOTTOM, WEAPONTOP,
    WP_CHAINGUN, WP_CHAINSAW, WP_FIST, WP_NOCHANGE, WP_PISTOL, WP_SHOTGUN, ammo_of, owns, set_ammo,
    weapon_ammo,
};

/// `ps_weapon`.
pub const PS_WEAPON: u32 = 0;
/// `ps_flash`.
pub const PS_FLASH: u32 = 1;

/// How deep an action may re-enter [`set_psprite`].
///
/// Doom's `P_SetPsprite` calls the entered state's action, which may set the
/// psprite again (`A_Lower` → `P_BringUpWeapon`, `A_WeaponReady` →
/// `P_FireWeapon`). The deepest chain the five weapon tables can produce is
/// three (`A_Lower` → up state → `A_Raise` → ready state → `A_WeaponReady`);
/// the bound is here so that no input can make the proving path loop (R4-A2).
pub const MAX_PSPR_DEPTH: u32 = 4;

/// `ANG90 / 20`, the most `A_Saw` turns toward its victim in one tic, and
/// `ANG90 / 21`, the angle it then snaps to. Folded here (a `/` on `u32` at
/// the use site keeps a "division by zero" arm, S7 §8 rule 1).
const SAW_STEP: u32 = 0x40000000 / 20;
const SAW_SNAP: u32 = 0x40000000 / 21;
/// `-SAW_STEP` as an unsigned `angle_t`.
const NEG_SAW_STEP: u32 = 0xFFFFFFFF - SAW_STEP + 1;

/// `S_PLAY`, the player mobj's idle state.
pub const S_PLAY: u32 = 58;
/// `S_PLAY_ATK1`, the firing pose.
///
/// Vanilla's muzzle-flash actions set `S_PLAY_ATK2` (the full-bright frame),
/// which `doom_things`' generator does not emit — no `mobjinfo` field and no
/// weapon chain reaches it, only C action code does. `A_WeaponReady` sends
/// the mobj back to `S_PLAY` on the next ready tic either way, so the
/// departure is one sprite frame on the tic a gun fires (README).
pub const S_PLAY_ATK: u32 = 63;

// ---------------------------------------------------------------------------
// weaponinfo
// ---------------------------------------------------------------------------

/// `weaponinfo[weapon]`, the five state ids of `d_items.c`.
pub fn chain(weapon: u32) -> WeaponStates {
    weapon_states(
        if weapon == WP_PISTOL {
            WeaponId::Pistol
        } else if weapon == WP_SHOTGUN {
            WeaponId::Shotgun
        } else if weapon == WP_CHAINGUN {
            WeaponId::Chaingun
        } else if weapon == WP_CHAINSAW {
            WeaponId::Chainsaw
        } else {
            WeaponId::Fist
        },
    )
}

// ---------------------------------------------------------------------------
// The two psprite slots
// ---------------------------------------------------------------------------

fn set_slot(ref p: Player, slot: u32, state: u32, tics: u32) {
    if slot == PS_WEAPON {
        p.psp_state = state;
        p.psp_tics = tics;
    } else {
        p.flash_state = state;
        p.flash_tics = tics;
    }
}

fn slot_state(p: @Player, slot: u32) -> u32 {
    if slot == PS_WEAPON {
        *p.psp_state
    } else {
        *p.flash_state
    }
}

fn slot_tics(p: @Player, slot: u32) -> u32 {
    if slot == PS_WEAPON {
        *p.psp_tics
    } else {
        *p.flash_tics
    }
}

/// `P_SetPsprite(player, slot, stnum)`: enter `stnum`, run its action, and
/// chain while the state it lands on has zero tics.
///
/// `stnum == 0` (`S_NULL`) empties the slot, which is Doom's `psp->state =
/// NULL`. The zero-tic chain is bounded by
/// `doom_things::MAX_ZERO_TIC_CHAIN` (measured at 1 on this roster) and the
/// action's own re-entry by [`MAX_PSPR_DEPTH`].
pub fn set_psprite(
    env: Env,
    ref g: ThingGrid,
    ref rng: Prng,
    ref p: Player,
    ref mo: Mobj,
    ref events: Array<PlayerEvent>,
    slot: u32,
    stnum: u32,
    depth: u32,
) {
    let mut st = stnum;
    let mut guard: u32 = 0;
    loop {
        if st == 0 {
            set_slot(ref p, slot, 0, 0);
            break;
        }
        let (tics, action) = state_entry(env.states, st);
        set_slot(ref p, slot, st, tics);
        if action != fsm::NO_ACTION && depth < MAX_PSPR_DEPTH {
            run_action(env, ref g, ref rng, ref p, ref mo, ref events, action, depth + 1);
        }
        // Doom re-reads `psp->state` here: the action may have replaced it,
        // in which case the nested call already ran the whole chain.
        let now = slot_state(@p, slot);
        if now == 0 || now != st {
            break;
        }
        if slot_tics(@p, slot) != 0 {
            break;
        }
        st = rd32(env.states.next_state, st);
        guard = inc(guard);
        if guard > doom_things::MAX_ZERO_TIC_CHAIN {
            break;
        }
    }
}

/// `P_MovePsprites`: one tic of both psprites, then the flash follows the
/// weapon's offsets (Doom copies them unconditionally).
pub fn move_psprites(
    env: Env,
    ref g: ThingGrid,
    ref rng: Prng,
    ref p: Player,
    ref mo: Mobj,
    ref events: Array<PlayerEvent>,
) {
    tick_slot(env, ref g, ref rng, ref p, ref mo, ref events, PS_WEAPON);
    tick_slot(env, ref g, ref rng, ref p, ref mo, ref events, PS_FLASH);
}

fn tick_slot(
    env: Env,
    ref g: ThingGrid,
    ref rng: Prng,
    ref p: Player,
    ref mo: Mobj,
    ref events: Array<PlayerEvent>,
    slot: u32,
) {
    let st = slot_state(@p, slot);
    if st == 0 {
        return;
    }
    let tics = slot_tics(@p, slot);
    if tics == fsm::FOREVER {
        return;
    }
    if tics > 1 {
        set_slot(ref p, slot, st, dec(tics));
        return;
    }
    let next = rd32(env.states.next_state, st);
    set_psprite(env, ref g, ref rng, ref p, ref mo, ref events, slot, next, 0);
}

// ---------------------------------------------------------------------------
// P_BringUpWeapon / P_CheckAmmo / P_FireWeapon / P_DropWeapon
// ---------------------------------------------------------------------------

/// `P_BringUpWeapon`: start raising [`Player::pending_weapon`].
pub fn bring_up_weapon(
    env: Env,
    ref g: ThingGrid,
    ref rng: Prng,
    ref p: Player,
    ref mo: Mobj,
    ref events: Array<PlayerEvent>,
    depth: u32,
) {
    if p.pending_weapon == WP_NOCHANGE {
        p.pending_weapon = p.ready_weapon;
    }
    let newstate = chain(p.pending_weapon).up;
    p.pending_weapon = WP_NOCHANGE;
    p.psp_sy = Fixed { enc: BIAS + WEAPONBOTTOM };
    set_psprite(env, ref g, ref rng, ref p, ref mo, ref events, PS_WEAPON, newstate, depth);
}

/// `P_DropWeapon`: start lowering the ready weapon (death, or a switch).
pub fn drop_weapon(
    env: Env,
    ref g: ThingGrid,
    ref rng: Prng,
    ref p: Player,
    ref mo: Mobj,
    ref events: Array<PlayerEvent>,
) {
    let down = chain(p.ready_weapon).down;
    set_psprite(env, ref g, ref rng, ref p, ref mo, ref events, PS_WEAPON, down, 0);
}

/// `P_CheckAmmo`: `true` when the ready weapon can fire; otherwise pick the
/// weapon to fall back to and start lowering the current one.
///
/// The fallback order is Doom's, minus the four weapons this roster does not
/// carry: chaingun, shotgun, pistol, chainsaw, fist.
pub fn check_ammo(
    env: Env,
    ref g: ThingGrid,
    ref rng: Prng,
    ref p: Player,
    ref mo: Mobj,
    ref events: Array<PlayerEvent>,
    depth: u32,
) -> bool {
    let ammo = weapon_ammo(p.ready_weapon);
    if ammo == AM_NOAMMO || ammo_of(@p, ammo) >= 1 {
        return true;
    }
    p
        .pending_weapon =
            if owns(@p, WP_CHAINGUN) && ammo_of(@p, weapon_ammo(WP_CHAINGUN)) != 0 {
                WP_CHAINGUN
            } else if owns(@p, WP_SHOTGUN) && ammo_of(@p, weapon_ammo(WP_SHOTGUN)) != 0 {
                WP_SHOTGUN
            } else if ammo_of(@p, weapon_ammo(WP_PISTOL)) != 0 {
                WP_PISTOL
            } else if owns(@p, WP_CHAINSAW) {
                WP_CHAINSAW
            } else {
                WP_FIST
            };
    let down = chain(p.ready_weapon).down;
    set_psprite(env, ref g, ref rng, ref p, ref mo, ref events, PS_WEAPON, down, depth);
    false
}

/// `P_FireWeapon`.
fn fire_weapon(
    env: Env,
    ref g: ThingGrid,
    ref rng: Prng,
    ref p: Player,
    ref mo: Mobj,
    ref events: Array<PlayerEvent>,
    depth: u32,
) {
    if !check_ammo(env, ref g, ref rng, ref p, ref mo, ref events, depth) {
        return;
    }
    enter_mobj_state(env, ref mo, S_PLAY_ATK);
    let atk = chain(p.ready_weapon).attack;
    set_psprite(env, ref g, ref rng, ref p, ref mo, ref events, PS_WEAPON, atk, depth);
}

/// `P_SetMobjState` on the player's own mobj: `fsm::enter` without the
/// `doom_physics::set_state` wrapper, which would want the whole `World`.
fn enter_mobj_state(env: Env, ref mo: Mobj, state: u32) {
    let (tics, _) = state_entry(env.states, state);
    mo.state = state;
    mo.tics = tics;
}

// ---------------------------------------------------------------------------
// The action dispatch
// ---------------------------------------------------------------------------

/// Run the action of a psprite state (D15: `fsm` hands back the id, the
/// caller dispatches).
pub fn run_action(
    env: Env,
    ref g: ThingGrid,
    ref rng: Prng,
    ref p: Player,
    ref mo: Mobj,
    ref events: Array<PlayerEvent>,
    action: u32,
    depth: u32,
) {
    if action == A_WEAPONREADY {
        a_weapon_ready(env, ref g, ref rng, ref p, ref mo, ref events, depth);
    } else if action == A_LOWER {
        a_lower(env, ref g, ref rng, ref p, ref mo, ref events, depth);
    } else if action == A_RAISE {
        a_raise(env, ref g, ref rng, ref p, ref mo, ref events, depth);
    } else if action == A_REFIRE {
        a_refire(env, ref g, ref rng, ref p, ref mo, ref events, depth);
    } else if action == A_FIREPISTOL {
        a_fire_gun(env, ref g, ref rng, ref p, ref mo, ref events, 1, depth);
    } else if action == A_FIRESHOTGUN {
        a_fire_gun(env, ref g, ref rng, ref p, ref mo, ref events, 7, depth);
    } else if action == A_FIRECGUN {
        a_fire_cgun(env, ref g, ref rng, ref p, ref mo, ref events, depth);
    } else if action == A_PUNCH {
        a_melee(env, ref g, ref rng, ref p, ref mo, ref events, false);
    } else if action == A_SAW {
        a_melee(env, ref g, ref rng, ref p, ref mo, ref events, true);
    } else if action == A_LIGHT0 {
        p.extralight = 0;
    } else if action == A_LIGHT1 {
        p.extralight = 1;
    } else if action == A_LIGHT2 {
        p.extralight = 2;
    }
}

/// `A_WeaponReady`.
fn a_weapon_ready(
    env: Env,
    ref g: ThingGrid,
    ref rng: Prng,
    ref p: Player,
    ref mo: Mobj,
    ref events: Array<PlayerEvent>,
    depth: u32,
) {
    if mo.state == S_PLAY_ATK {
        enter_mobj_state(env, ref mo, S_PLAY);
    }
    if p.pending_weapon != WP_NOCHANGE || p.health == 0 {
        let down = chain(p.ready_weapon).down;
        set_psprite(env, ref g, ref rng, ref p, ref mo, ref events, PS_WEAPON, down, depth);
        return;
    }
    if (env.buttons & BT_ATTACK) != 0 {
        // Doom lets the rocket launcher and the BFG require a re-press;
        // neither is in this roster, so every weapon fires while held.
        p.attackdown = true;
        fire_weapon(env, ref g, ref rng, ref p, ref mo, ref events, depth);
        return;
    }
    p.attackdown = false;
    // Bob the weapon with the player's speed.
    let idx = fine_of(128, env.tic);
    p.psp_sx = fixed::add(fixed::FRACUNIT, fixed::mul(p.bob, bam::finecosine(idx)));
    let top = Fixed { enc: BIAS + WEAPONTOP };
    p.psp_sy = fixed::add(top, fixed::mul(p.bob, bam::finesine(half_fine(idx))));
}

/// `A_ReFire`.
fn a_refire(
    env: Env,
    ref g: ThingGrid,
    ref rng: Prng,
    ref p: Player,
    ref mo: Mobj,
    ref events: Array<PlayerEvent>,
    depth: u32,
) {
    if (env.buttons & BT_ATTACK) != 0 && p.pending_weapon == WP_NOCHANGE && p.health != 0 {
        p.refire = inc(p.refire);
        fire_weapon(env, ref g, ref rng, ref p, ref mo, ref events, depth);
    } else {
        p.refire = 0;
        check_ammo(env, ref g, ref rng, ref p, ref mo, ref events, depth);
    }
}

/// `A_Lower`.
fn a_lower(
    env: Env,
    ref g: ThingGrid,
    ref rng: Prng,
    ref p: Player,
    ref mo: Mobj,
    ref events: Array<PlayerEvent>,
    depth: u32,
) {
    p.psp_sy = Fixed { enc: p.psp_sy.enc + RAISESPEED };
    if fixed::lt(p.psp_sy, Fixed { enc: BIAS + WEAPONBOTTOM }) {
        return;
    }
    if p.playerstate == PST_DEAD {
        p.psp_sy = Fixed { enc: BIAS + WEAPONBOTTOM };
        return;
    }
    if p.health == 0 {
        // The player is dead but has not entered PST_DEAD yet: take the
        // weapon off the screen for good.
        set_psprite(env, ref g, ref rng, ref p, ref mo, ref events, PS_WEAPON, 0, depth);
        return;
    }
    p.ready_weapon = p.pending_weapon;
    bring_up_weapon(env, ref g, ref rng, ref p, ref mo, ref events, depth);
}

/// `A_Raise`.
fn a_raise(
    env: Env,
    ref g: ThingGrid,
    ref rng: Prng,
    ref p: Player,
    ref mo: Mobj,
    ref events: Array<PlayerEvent>,
    depth: u32,
) {
    p.psp_sy = Fixed { enc: p.psp_sy.enc - RAISESPEED };
    if fixed::gt(p.psp_sy, Fixed { enc: BIAS + WEAPONTOP }) {
        return;
    }
    p.psp_sy = Fixed { enc: BIAS + WEAPONTOP };
    let ready = chain(p.ready_weapon).ready;
    set_psprite(env, ref g, ref rng, ref p, ref mo, ref events, PS_WEAPON, ready, depth);
}

// ---------------------------------------------------------------------------
// The guns
// ---------------------------------------------------------------------------

/// `A_FirePistol` (`shots = 1`) and `A_FireShotgun` (`shots = 7`): they
/// differ only in how many pellets leave the barrel and, for the shotgun,
/// in never being accurate.
fn a_fire_gun(
    env: Env,
    ref g: ThingGrid,
    ref rng: Prng,
    ref p: Player,
    ref mo: Mobj,
    ref events: Array<PlayerEvent>,
    shots: u32,
    depth: u32,
) {
    enter_mobj_state(env, ref mo, S_PLAY_ATK);
    let ammo = weapon_ammo(p.ready_weapon);
    // `P_CheckAmmo` ran first, so the counter is at least one; `dec` is that
    // subtraction without the underflow panic (S7 §8 rule 1).
    p = set_ammo(p, ammo, dec(ammo_of(@p, ammo)));
    let flash = chain(p.ready_weapon).flash;
    set_psprite(env, ref g, ref rng, ref p, ref mo, ref events, PS_FLASH, flash, depth);
    let accurate = shots == 1 && p.refire == 0;
    shoot(env, ref g, ref rng, @mo, ref events, shots, accurate);
}

/// `A_FireCGun`.
///
/// Vanilla picks the flash state as `flashstate + (psp->state - S_CHAIN1)`,
/// so the chaingun alternates two flash frames. `doom_things`' compacted
/// state ids do not keep `S_CHAINFLASH2` adjacent to `S_CHAINFLASH1` (it is
/// not reachable from any table), so this fires the first flash frame every
/// tic — a renderer-only difference, on a weapon that is not obtainable on
/// E1M1 at skill 2 (README, "Known departures").
fn a_fire_cgun(
    env: Env,
    ref g: ThingGrid,
    ref rng: Prng,
    ref p: Player,
    ref mo: Mobj,
    ref events: Array<PlayerEvent>,
    depth: u32,
) {
    let ammo = weapon_ammo(p.ready_weapon);
    if ammo_of(@p, ammo) == 0 {
        return;
    }
    a_fire_gun(env, ref g, ref rng, ref p, ref mo, ref events, 1, depth);
}

/// `P_BulletSlope` + `shots` × `P_GunShot`.
fn shoot(
    env: Env,
    ref g: ThingGrid,
    ref rng: Prng,
    mo: @Mobj,
    ref events: Array<PlayerEvent>,
    shots: u32,
    accurate: bool,
) {
    let w = env.world.unbox();
    let slope = bullet_slope(w, env.mobjs, ref g, mo, env.me);
    let rnd = w.rndtable;
    let mut k: u32 = 0;
    while k != shots {
        let three: NonZero<u8> = 3;
        let (_, r) = DivRem::div_rem(roll(ref rng, rnd), three);
        let damage: u32 = mul32(5, add32(r.into(), 1));
        let angle = if accurate {
            *mo.angle
        } else {
            spread(*mo.angle, sub_roll(ref rng, rnd))
        };
        let hit = line_attack(w, env.mobjs, ref g, env.me, angle, MISSILERANGE, slope);
        events.append(PlayerEvent::Shot((hit, damage)));
        k = inc(k);
    }
}

/// `P_SubRandom()` as a felt, without a panic path: `doom_physics`' twin of
/// `PrngTrait::next` twice, subtracted in the field (the `i32` difference
/// carries an overflow check for a value that is always in `[-255, 255]`).
/// The two draws happen in Doom's order, so the cursor moves identically.
fn sub_roll(ref rng: Prng, table: Span<u8>) -> felt252 {
    let a = roll(ref rng, table);
    let b = roll(ref rng, table);
    let x: felt252 = a.into();
    let y: felt252 = b.into();
    x - y
}

/// `P_BulletSlope`: aim straight ahead, then a degree either side.
pub fn bullet_slope(w: World, mobjs: Span<Mobj>, ref g: ThingGrid, mo: @Mobj, me: u32) -> Fixed {
    let an = *mo.angle;
    let aim = aim_line_attack(w, mobjs, ref g, me, an, AIMRANGE);
    if aim.target != NO_MOBJ {
        return aim.slope;
    }
    let an = bam::add(an, 0x4000000); // 1 << 26
    let aim = aim_line_attack(w, mobjs, ref g, me, an, AIMRANGE);
    if aim.target != NO_MOBJ {
        return aim.slope;
    }
    let an = bam::sub(an, 0x8000000); // 2 << 26
    aim_line_attack(w, mobjs, ref g, me, an, AIMRANGE).slope
}

/// `angle + (P_SubRandom() << 18)`, reduced once in the field (S1 §7).
fn spread(angle: Angle, sub: felt252) -> Angle {
    bam::reduce(angle.into() + sub * 262144 + 0x100000000)
}

/// `A_Punch` and `A_Saw`: the two melee attacks, which differ in damage,
/// range, how they turn toward what they hit, and `MF_JUSTATTACKED`.
fn a_melee(
    env: Env,
    ref g: ThingGrid,
    ref rng: Prng,
    ref p: Player,
    ref mo: Mobj,
    ref events: Array<PlayerEvent>,
    saw: bool,
) {
    let w = env.world.unbox();
    let rnd = w.rndtable;
    let ten: NonZero<u8> = 10;
    let (_, r) = DivRem::div_rem(roll(ref rng, rnd), ten);
    let base: u32 = mul32(2, add32(r.into(), 1));
    let damage = if !saw && p.strength != 0 {
        mul32(base, 10)
    } else {
        base
    };
    let angle = spread(mo.angle, sub_roll(ref rng, rnd));
    let range = if saw {
        Fixed { enc: MELEERANGE.enc + 1 }
    } else {
        MELEERANGE
    };
    let aim = aim_line_attack(w, env.mobjs, ref g, env.me, angle, range);
    let hit = line_attack(w, env.mobjs, ref g, env.me, angle, range, aim.slope);
    events.append(PlayerEvent::Shot((hit, damage)));
    if aim.target == NO_MOBJ {
        return;
    }
    let t = match env.mobjs.get(aim.target) {
        Option::Some(b) => b.unbox(),
        Option::None => { return; },
    };
    let facing = point_to_angle2(mo.x, mo.y, *t.x, *t.y);
    if !saw {
        mo.angle = facing;
        return;
    }
    // `A_Saw` turns toward the target by at most ANG90/20 a tic.
    let delta = bam::sub(facing, mo.angle);
    mo
        .angle =
            if delta > 0x80000000 {
                if delta < NEG_SAW_STEP {
                    bam::add(facing, SAW_SNAP)
                } else {
                    bam::sub(mo.angle, SAW_STEP)
                }
            } else if delta > SAW_STEP {
                bam::sub(facing, SAW_SNAP)
            } else {
                bam::add(mo.angle, SAW_STEP)
            };
    mo.flags = mo.flags | MF_JUSTATTACKED;
}

/// `MAXBOB` re-exported for the tests, which check `P_CalcHeight`'s clamp.
pub fn maxbob() -> Fixed {
    Fixed { enc: BIAS + MAXBOB }
}

/// Whether a [`Hit`] landed on a thing (the tests and `doom_game` both ask).
pub fn hit_thing(h: Hit) -> Option<u32> {
    match h {
        Hit::Thing((idx, _, _)) => Option::Some(idx),
        _ => Option::None,
    }
}
