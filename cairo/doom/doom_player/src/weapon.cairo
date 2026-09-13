// SPDX-License-Identifier: GPL-2.0-only
//! The player's weapon sprites and the actions their states run —
//! linuxdoom-1.10's `p_pspr.c`, over `doom_things`' `weaponinfo` chains and
//! `fsm`'s state columns.
//!
//! Cairo has no function pointers, so a state carries an **action id**
//! (D15); [`run_action`] is this crate's dispatch table for the eleven ids
//! `d_items.c`'s five weapon chains can reach.
//!
//! # Everything crosses a call behind a pointer (S7 §8 rule 3)
//!
//! The chain is five levels deep on an idle tic (`move_psprites` →
//! `tick_slot` → `set_psprite` → `run_action` → `A_WeaponReady`). Carrying
//! the `Player` (36 felts), the `Mobj` (27) and the [`Env`] (16) by value or
//! by `ref` cost **79 felts in and 63 out at every level** — and, because a
//! panic site stores the enclosing function's whole return width, 63 more
//! at every panic site and every return point of every one of them.
//!
//! So the public entry points below are thin wrappers that box their
//! operands once. These adapters are inlined: an extra call would push the
//! wide public records before boxing them. The shared algorithms stay out
//! of the adapter, and the whole chain (`*_in`) carries `Box<Env>`,
//! `Box<Player>` and `Box<Mobj>` — one felt each. Reading a field through a
//! box is free (`unbox` emits nothing, the field is a double dereference);
//! only a **write** pays, one `into_box` of the record's width, and an idle
//! tic writes three fields. That is the trade S7 §4.3 measured: 26 steps for
//! a boxed call against 91 for the struct by value.

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
use super::env::{Env, PlayerEvent, enter, leave};
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

/// Write one slot's `(state, tics)`, in one `into_box`: the two arms pick
/// the four values, and the record is rebuilt once (two struct literals
/// would keep two 36-felt live sets alive, S7 §4.2).
///
/// **A slot that already holds `(state, tics)` is not rebuilt.** Rebuilding
/// a boxed `Player` reads 36 felts and writes 36 (measured at 111 steps);
/// two comparisons decide it. That is not a rare case: every "ready" and
/// "hold" state in `p_pspr.c` re-enters itself with the same tic count, so
/// `A_WeaponReady` reaches this with nothing to change on every tic a weapon
/// is simply up.
fn set_slot(ref p: Box<Player>, slot: u32, state: u32, tics: u32) {
    let cur = p.unbox();
    let (ws, wt, fs, ft) = if slot == PS_WEAPON {
        (state, tics, cur.flash_state, cur.flash_tics)
    } else {
        (cur.psp_state, cur.psp_tics, state, tics)
    };
    if ws == cur.psp_state && wt == cur.psp_tics && fs == cur.flash_state && ft == cur.flash_tics {
        return;
    }
    p =
        BoxTrait::new(
            Player { psp_state: ws, psp_tics: wt, flash_state: fs, flash_tics: ft, ..cur },
        );
}

#[inline(always)]
fn slot_state(p: Box<Player>, slot: u32) -> u32 {
    if slot == PS_WEAPON {
        p.psp_state
    } else {
        p.flash_state
    }
}

#[inline(always)]
fn slot_tics(p: Box<Player>, slot: u32) -> u32 {
    if slot == PS_WEAPON {
        p.psp_tics
    } else {
        p.flash_tics
    }
}

/// `P_SetPsprite(player, slot, stnum)`: enter `stnum`, run its action, and
/// chain while the state it lands on has zero tics.
///
/// `stnum == 0` (`S_NULL`) empties the slot, which is Doom's `psp->state =
/// NULL`. The zero-tic chain is bounded by
/// `doom_things::MAX_ZERO_TIC_CHAIN` (measured at 1 on this roster) and the
/// action's own re-entry by [`MAX_PSPR_DEPTH`].
#[inline(always)]
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
    let (cx, mut bp, mut bm) = enter(env, @p, @mo);
    set_psprite_in(cx, ref g, ref rng, ref bp, ref bm, ref events, slot, stnum, depth);
    leave(bp, bm, ref p, ref mo);
}

fn set_psprite_in(
    env: Box<Env>,
    ref g: ThingGrid,
    ref rng: Prng,
    ref p: Box<Player>,
    ref mo: Box<Mobj>,
    ref events: Array<PlayerEvent>,
    slot: u32,
    stnum: u32,
    depth: u32,
) {
    // `env.states` is read through the box at each use rather than hoisted:
    // ten felts held live across the loop's merges and across `run_action_in`
    // would be re-stored at every one of them (S7 §4.2).
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
            run_action_in(env, ref g, ref rng, ref p, ref mo, ref events, action, inc(depth));
        }
        // Doom re-reads `psp->state` here: the action may have replaced it,
        // in which case the nested call already ran the whole chain.
        let now = slot_state(p, slot);
        if now == 0 || now != st {
            break;
        }
        if slot_tics(p, slot) != 0 {
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
#[inline(always)]
pub fn move_psprites(
    env: Env,
    ref g: ThingGrid,
    ref rng: Prng,
    ref p: Player,
    ref mo: Mobj,
    ref events: Array<PlayerEvent>,
) {
    let (cx, mut bp, mut bm) = enter(env, @p, @mo);
    move_psprites_in(cx, ref g, ref rng, ref bp, ref bm, ref events);
    leave(bp, bm, ref p, ref mo);
}

pub(crate) fn move_psprites_in(
    env: Box<Env>,
    ref g: ThingGrid,
    ref rng: Prng,
    ref p: Box<Player>,
    ref mo: Box<Mobj>,
    ref events: Array<PlayerEvent>,
) {
    tick_slot(env, ref g, ref rng, ref p, ref mo, ref events, PS_WEAPON);
    tick_slot(env, ref g, ref rng, ref p, ref mo, ref events, PS_FLASH);
}

fn tick_slot(
    env: Box<Env>,
    ref g: ThingGrid,
    ref rng: Prng,
    ref p: Box<Player>,
    ref mo: Box<Mobj>,
    ref events: Array<PlayerEvent>,
    slot: u32,
) {
    let st = slot_state(p, slot);
    if st == 0 {
        return;
    }
    let tics = slot_tics(p, slot);
    if tics == fsm::FOREVER {
        return;
    }
    if tics > 1 {
        set_slot(ref p, slot, st, dec(tics));
        return;
    }
    let next = rd32(env.unbox().states.next_state, st);
    set_psprite_in(env, ref g, ref rng, ref p, ref mo, ref events, slot, next, 0);
}

// ---------------------------------------------------------------------------
// P_BringUpWeapon / P_CheckAmmo / P_FireWeapon / P_DropWeapon
// ---------------------------------------------------------------------------

/// `P_BringUpWeapon`: start raising [`Player::pending_weapon`].
#[inline(always)]
pub fn bring_up_weapon(
    env: Env,
    ref g: ThingGrid,
    ref rng: Prng,
    ref p: Player,
    ref mo: Mobj,
    ref events: Array<PlayerEvent>,
    depth: u32,
) {
    let (cx, mut bp, mut bm) = enter(env, @p, @mo);
    bring_up_weapon_in(cx, ref g, ref rng, ref bp, ref bm, ref events, depth);
    leave(bp, bm, ref p, ref mo);
}

fn bring_up_weapon_in(
    env: Box<Env>,
    ref g: ThingGrid,
    ref rng: Prng,
    ref p: Box<Player>,
    ref mo: Box<Mobj>,
    ref events: Array<PlayerEvent>,
    depth: u32,
) {
    let cur = p.unbox();
    let up = if cur.pending_weapon == WP_NOCHANGE {
        cur.ready_weapon
    } else {
        cur.pending_weapon
    };
    let newstate = chain(up).up;
    p =
        BoxTrait::new(
            Player {
                pending_weapon: WP_NOCHANGE, psp_sy: Fixed { enc: BIAS + WEAPONBOTTOM }, ..cur,
            },
        );
    set_psprite_in(env, ref g, ref rng, ref p, ref mo, ref events, PS_WEAPON, newstate, depth);
}

/// `P_DropWeapon`: start lowering the ready weapon (death, or a switch).
#[inline(always)]
pub fn drop_weapon(
    env: Env,
    ref g: ThingGrid,
    ref rng: Prng,
    ref p: Player,
    ref mo: Mobj,
    ref events: Array<PlayerEvent>,
) {
    let (cx, mut bp, mut bm) = enter(env, @p, @mo);
    drop_weapon_in(cx, ref g, ref rng, ref bp, ref bm, ref events);
    leave(bp, bm, ref p, ref mo);
}

pub(crate) fn drop_weapon_in(
    env: Box<Env>,
    ref g: ThingGrid,
    ref rng: Prng,
    ref p: Box<Player>,
    ref mo: Box<Mobj>,
    ref events: Array<PlayerEvent>,
) {
    let down = chain(p.unbox().ready_weapon).down;
    set_psprite_in(env, ref g, ref rng, ref p, ref mo, ref events, PS_WEAPON, down, 0);
}

/// `P_CheckAmmo`: `true` when the ready weapon can fire; otherwise pick the
/// weapon to fall back to and start lowering the current one.
///
/// The fallback order is Doom's, minus the four weapons this roster does not
/// carry: chaingun, shotgun, pistol, chainsaw, fist.
#[inline(always)]
pub fn check_ammo(
    env: Env,
    ref g: ThingGrid,
    ref rng: Prng,
    ref p: Player,
    ref mo: Mobj,
    ref events: Array<PlayerEvent>,
    depth: u32,
) -> bool {
    let (cx, mut bp, mut bm) = enter(env, @p, @mo);
    let ok = check_ammo_in(cx, ref g, ref rng, ref bp, ref bm, ref events, depth);
    leave(bp, bm, ref p, ref mo);
    ok
}

fn check_ammo_in(
    env: Box<Env>,
    ref g: ThingGrid,
    ref rng: Prng,
    ref p: Box<Player>,
    ref mo: Box<Mobj>,
    ref events: Array<PlayerEvent>,
    depth: u32,
) -> bool {
    let cur = p.unbox();
    let ammo = weapon_ammo(cur.ready_weapon);
    if ammo == AM_NOAMMO || ammo_of(@cur, ammo) >= 1 {
        return true;
    }
    let pending = if owns(@cur, WP_CHAINGUN) && ammo_of(@cur, weapon_ammo(WP_CHAINGUN)) != 0 {
        WP_CHAINGUN
    } else if owns(@cur, WP_SHOTGUN) && ammo_of(@cur, weapon_ammo(WP_SHOTGUN)) != 0 {
        WP_SHOTGUN
    } else if ammo_of(@cur, weapon_ammo(WP_PISTOL)) != 0 {
        WP_PISTOL
    } else if owns(@cur, WP_CHAINSAW) {
        WP_CHAINSAW
    } else {
        WP_FIST
    };
    let down = chain(cur.ready_weapon).down;
    p = BoxTrait::new(Player { pending_weapon: pending, ..cur });
    set_psprite_in(env, ref g, ref rng, ref p, ref mo, ref events, PS_WEAPON, down, depth);
    false
}

/// `P_FireWeapon`.
fn fire_weapon(
    env: Box<Env>,
    ref g: ThingGrid,
    ref rng: Prng,
    ref p: Box<Player>,
    ref mo: Box<Mobj>,
    ref events: Array<PlayerEvent>,
    depth: u32,
) {
    if !check_ammo_in(env, ref g, ref rng, ref p, ref mo, ref events, depth) {
        return;
    }
    enter_mobj_state(env, ref mo, S_PLAY_ATK);
    let atk = chain(p.unbox().ready_weapon).attack;
    set_psprite_in(env, ref g, ref rng, ref p, ref mo, ref events, PS_WEAPON, atk, depth);
}

/// `P_SetMobjState` on the player's own mobj: `fsm::enter` without the
/// `doom_physics::set_state` wrapper, which would want the whole `World`.
fn enter_mobj_state(env: Box<Env>, ref mo: Box<Mobj>, state: u32) {
    let (tics, _) = state_entry(env.unbox().states, state);
    mo = BoxTrait::new(Mobj { state, tics, ..mo.unbox() });
}

// ---------------------------------------------------------------------------
// The action dispatch
// ---------------------------------------------------------------------------

/// Run the action of a psprite state (D15: `fsm` hands back the id, the
/// caller dispatches).
#[inline(always)]
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
    let (cx, mut bp, mut bm) = enter(env, @p, @mo);
    run_action_in(cx, ref g, ref rng, ref bp, ref bm, ref events, action, depth);
    leave(bp, bm, ref p, ref mo);
}

fn run_action_in(
    env: Box<Env>,
    ref g: ThingGrid,
    ref rng: Prng,
    ref p: Box<Player>,
    ref mo: Box<Mobj>,
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
    } else if action == A_PUNCH || action == A_SAW {
        // One arm, with `saw` computed: two arms with a literal each gave the
        // lowering two copies of `a_melee`'s 2 184 words (S7 §2).
        a_melee(env, ref g, ref rng, ref p, ref mo, ref events, action == A_SAW);
    } else if action == A_LIGHT0 {
        set_extralight(ref p, 0);
    } else if action == A_LIGHT1 {
        set_extralight(ref p, 1);
    } else if action == A_LIGHT2 {
        set_extralight(ref p, 2);
    }
}

/// `A_Light0`/`1`/`2`, out of line so the three arms of the dispatch share
/// one `into_box` (S7 §8 rule 6).
#[inline(never)]
fn set_extralight(ref p: Box<Player>, level: u32) {
    p = BoxTrait::new(Player { extralight: level, ..p.unbox() });
}

/// `A_WeaponReady`.
fn a_weapon_ready(
    env: Box<Env>,
    ref g: ThingGrid,
    ref rng: Prng,
    ref p: Box<Player>,
    ref mo: Box<Mobj>,
    ref events: Array<PlayerEvent>,
    depth: u32,
) {
    if mo.unbox().state == S_PLAY_ATK {
        enter_mobj_state(env, ref mo, S_PLAY);
    }
    let cur = p.unbox();
    if cur.pending_weapon != WP_NOCHANGE || cur.health == 0 {
        let down = chain(cur.ready_weapon).down;
        set_psprite_in(env, ref g, ref rng, ref p, ref mo, ref events, PS_WEAPON, down, depth);
        return;
    }
    if (env.unbox().buttons & BT_ATTACK) != 0 {
        // Doom lets the rocket launcher and the BFG require a re-press;
        // neither is in this roster, so every weapon fires while held.
        p = BoxTrait::new(Player { attackdown: true, ..cur });
        fire_weapon(env, ref g, ref rng, ref p, ref mo, ref events, depth);
        return;
    }
    // Bob the weapon with the player's speed. One `into_box` for the three
    // fields: `attackdown` is written on this arm too.
    let idx = fine_of(128, env.unbox().tic);
    let bob = cur.bob;
    let sx = fixed::add(fixed::FRACUNIT, fixed::mul(bob, bam::finecosine(idx)));
    let top = Fixed { enc: BIAS + WEAPONTOP };
    let sy = fixed::add(top, fixed::mul(bob, bam::finesine(half_fine(idx))));
    // Same rule as `set_slot`: three comparisons rather than a 111-step
    // rebuild of the record with the values it already holds (a weapon that
    // is up over a player who is not moving bobs by zero).
    if sx == cur.psp_sx && sy == cur.psp_sy && !cur.attackdown {
        return;
    }
    p = BoxTrait::new(Player { attackdown: false, psp_sx: sx, psp_sy: sy, ..cur });
}

/// `A_ReFire`.
fn a_refire(
    env: Box<Env>,
    ref g: ThingGrid,
    ref rng: Prng,
    ref p: Box<Player>,
    ref mo: Box<Mobj>,
    ref events: Array<PlayerEvent>,
    depth: u32,
) {
    let cur = p.unbox();
    if (env.unbox().buttons & BT_ATTACK) != 0
        && cur.pending_weapon == WP_NOCHANGE
        && cur.health != 0 {
        p = BoxTrait::new(Player { refire: inc(cur.refire), ..cur });
        fire_weapon(env, ref g, ref rng, ref p, ref mo, ref events, depth);
    } else {
        p = BoxTrait::new(Player { refire: 0, ..cur });
        check_ammo_in(env, ref g, ref rng, ref p, ref mo, ref events, depth);
    }
}

/// `A_Lower`.
fn a_lower(
    env: Box<Env>,
    ref g: ThingGrid,
    ref rng: Prng,
    ref p: Box<Player>,
    ref mo: Box<Mobj>,
    ref events: Array<PlayerEvent>,
    depth: u32,
) {
    let cur = p.unbox();
    let sy = Fixed { enc: cur.psp_sy.enc + RAISESPEED };
    let bottom = Fixed { enc: BIAS + WEAPONBOTTOM };
    // Choose the continuation before rebuilding the same 36 fields once:
    // 0 keeps the current state, 1 hides the psprite, 2 raises the next weapon.
    let (sy, weapon, next) = if fixed::lt(sy, bottom) {
        (sy, cur.ready_weapon, 0)
    } else if cur.playerstate == PST_DEAD {
        (bottom, cur.ready_weapon, 0)
    } else if cur.health == 0 {
        // The player is dead but has not entered PST_DEAD yet: take the
        // weapon off the screen for good.
        (sy, cur.ready_weapon, 1)
    } else {
        (sy, cur.pending_weapon, 2)
    };
    p = BoxTrait::new(Player { psp_sy: sy, ready_weapon: weapon, ..cur });
    if next == 1 {
        set_psprite_in(env, ref g, ref rng, ref p, ref mo, ref events, PS_WEAPON, 0, depth);
    } else if next == 2 {
        bring_up_weapon_in(env, ref g, ref rng, ref p, ref mo, ref events, depth);
    }
}

/// `A_Raise`.
fn a_raise(
    env: Box<Env>,
    ref g: ThingGrid,
    ref rng: Prng,
    ref p: Box<Player>,
    ref mo: Box<Mobj>,
    ref events: Array<PlayerEvent>,
    depth: u32,
) {
    let cur = p.unbox();
    let raised = Fixed { enc: cur.psp_sy.enc - RAISESPEED };
    let top = Fixed { enc: BIAS + WEAPONTOP };
    let moving = fixed::gt(raised, top);
    let sy = if moving {
        raised
    } else {
        top
    };
    p = BoxTrait::new(Player { psp_sy: sy, ..cur });
    if !moving {
        let ready = chain(cur.ready_weapon).ready;
        set_psprite_in(env, ref g, ref rng, ref p, ref mo, ref events, PS_WEAPON, ready, depth);
    }
}

// ---------------------------------------------------------------------------
// The guns
// ---------------------------------------------------------------------------

/// `A_FirePistol` (`shots = 1`) and `A_FireShotgun` (`shots = 7`): they
/// differ only in how many pellets leave the barrel and, for the shotgun,
/// in never being accurate.
fn a_fire_gun(
    env: Box<Env>,
    ref g: ThingGrid,
    ref rng: Prng,
    ref p: Box<Player>,
    ref mo: Box<Mobj>,
    ref events: Array<PlayerEvent>,
    shots: u32,
    depth: u32,
) {
    enter_mobj_state(env, ref mo, S_PLAY_ATK);
    let cur = p.unbox();
    let ammo = weapon_ammo(cur.ready_weapon);
    // `P_CheckAmmo` ran first, so the counter is at least one; `dec` is that
    // subtraction without the underflow panic (S7 §8 rule 1).
    let spent = set_ammo(cur, ammo, dec(ammo_of(@cur, ammo)));
    let flash = chain(cur.ready_weapon).flash;
    p = BoxTrait::new(spent);
    set_psprite_in(env, ref g, ref rng, ref p, ref mo, ref events, PS_FLASH, flash, depth);
    // `refire` and the angle are read *after* the flash, as `A_FirePistol`
    // does (the flash states only run `A_Light*`, so neither can change).
    let accurate = shots == 1 && p.unbox().refire == 0;
    shoot(env, ref g, ref rng, ref events, mo.unbox().angle, shots, accurate);
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
    env: Box<Env>,
    ref g: ThingGrid,
    ref rng: Prng,
    ref p: Box<Player>,
    ref mo: Box<Mobj>,
    ref events: Array<PlayerEvent>,
    depth: u32,
) {
    let cur = p.unbox();
    let ammo = weapon_ammo(cur.ready_weapon);
    if ammo_of(@cur, ammo) == 0 {
        return;
    }
    a_fire_gun(env, ref g, ref rng, ref p, ref mo, ref events, 1, depth);
}

/// `P_BulletSlope` + `shots` × `P_GunShot`.
///
/// The `Player` and the `Mobj` do not come along: `line_attack` reads the
/// shooter out of `env.mobjs` (which is the list as the tic began, exactly
/// as `P_PlayerThink` running before the thinker pass guarantees), so all
/// this needs of the mobj is the angle it fires along.
fn shoot(
    env: Box<Env>,
    ref g: ThingGrid,
    ref rng: Prng,
    ref events: Array<PlayerEvent>,
    an: Angle,
    shots: u32,
    accurate: bool,
) {
    let e = env.unbox();
    let w = e.world.unbox();
    let mobjs = e.mobjs;
    let me = e.me;
    let slope = bullet_slope_at(w, mobjs, ref g, an, me);
    let rnd = w.rndtable;
    let mut k: u32 = 0;
    while k != shots {
        let three: NonZero<u8> = 3;
        let (_, r) = DivRem::div_rem(roll(ref rng, rnd), three);
        let damage: u32 = mul32(5, add32(r.into(), 1));
        let angle = if accurate {
            an
        } else {
            spread(an, sub_roll(ref rng, rnd))
        };
        let hit = line_attack(w, mobjs, ref g, me, angle, MISSILERANGE, slope);
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
#[inline(always)]
pub fn bullet_slope(
    w: World, mobjs: Span<Box<Mobj>>, ref g: ThingGrid, mo: @Mobj, me: u32,
) -> Fixed {
    bullet_slope_at(w, mobjs, ref g, *mo.angle, me)
}

/// [`bullet_slope`] on the angle alone: the public form takes a `@Mobj`,
/// which Cairo pushes in full (27 felts) because a snapshot is not pruned to
/// the field that is read (S7 §4.3).
///
/// **The two side traces only happen when the first found nothing**, which
/// is `P_BulletSlope`'s own short-circuit: `if (!linetarget)`. A shot with a
/// target in front of the player costs one `P_AimLineAttack`; a shot into
/// empty space costs three (README, "Measured step costs").
fn bullet_slope_at(
    w: World, mobjs: Span<Box<Mobj>>, ref g: ThingGrid, an: Angle, me: u32,
) -> Fixed {
    let aim = aim_line_attack(w, mobjs, ref g, me, an, AIMRANGE);
    if aim.target != NO_MOBJ {
        return aim.slope;
    }
    let left = bam::add(an, 0x4000000); // 1 << 26
    let aim = aim_line_attack(w, mobjs, ref g, me, left, AIMRANGE);
    if aim.target != NO_MOBJ {
        return aim.slope;
    }
    let right = bam::sub(left, 0x8000000); // 2 << 26
    aim_line_attack(w, mobjs, ref g, me, right, AIMRANGE).slope
}

/// `angle + (P_SubRandom() << 18)`, reduced once in the field (S1 §7).
fn spread(angle: Angle, sub: felt252) -> Angle {
    bam::reduce(angle.into() + sub * 262144 + 0x100000000)
}

/// `A_Punch` and `A_Saw`: the two melee attacks, which differ in damage,
/// range, how they turn toward what they hit, and `MF_JUSTATTACKED`.
fn a_melee(
    env: Box<Env>,
    ref g: ThingGrid,
    ref rng: Prng,
    ref p: Box<Player>,
    ref mo: Box<Mobj>,
    ref events: Array<PlayerEvent>,
    saw: bool,
) {
    let e = env.unbox();
    let w = e.world.unbox();
    let mobjs = e.mobjs;
    let me = e.me;
    let rnd = w.rndtable;
    let ten: NonZero<u8> = 10;
    let (_, r) = DivRem::div_rem(roll(ref rng, rnd), ten);
    let base: u32 = mul32(2, add32(r.into(), 1));
    let damage = if !saw && p.unbox().strength != 0 {
        mul32(base, 10)
    } else {
        base
    };
    let cur = mo.unbox();
    let angle = spread(cur.angle, sub_roll(ref rng, rnd));
    let range = if saw {
        Fixed { enc: MELEERANGE.enc + 1 }
    } else {
        MELEERANGE
    };
    let aim = aim_line_attack(w, mobjs, ref g, me, angle, range);
    let hit = line_attack(w, mobjs, ref g, me, angle, range, aim.slope);
    events.append(PlayerEvent::Shot((hit, damage)));
    if aim.target == NO_MOBJ {
        return;
    }
    let t = match mobjs.get(aim.target) {
        Option::Some(b) => b.unbox().as_snapshot().unbox(),
        Option::None => { return; },
    };
    let facing = point_to_angle2(cur.x, cur.y, *t.x, *t.y);
    if !saw {
        mo = BoxTrait::new(Mobj { angle: facing, ..cur });
        return;
    }
    // `A_Saw` turns toward the target by at most ANG90/20 a tic.
    let delta = bam::sub(facing, cur.angle);
    let turned = if delta > 0x80000000 {
        if delta < NEG_SAW_STEP {
            bam::add(facing, SAW_SNAP)
        } else {
            bam::sub(cur.angle, SAW_STEP)
        }
    } else if delta > SAW_STEP {
        bam::sub(facing, SAW_SNAP)
    } else {
        bam::add(cur.angle, SAW_STEP)
    };
    mo = BoxTrait::new(Mobj { angle: turned, flags: cur.flags | MF_JUSTATTACKED, ..cur });
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
