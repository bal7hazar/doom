// SPDX-License-Identifier: GPL-2.0-only
//! `player_t` (`d_player.h`), its constants, its spawn value and its
//! serialization schema.
//!
//! Semantics are linuxdoom-1.10's; the record drops what a single-player,
//! no-cheat, no-network run never reads (`didsecret`, `message`, `fixedcolormap`,
//! `colormap`, `viewangle`/`lookdir`, the four unreachable powers, the frag
//! table, `attackerz`) and derives what is a pure function of something else
//! (`maxammo`, from [`Player::backpack`]; the flash psprite's `sx`/`sy`,
//! which `P_MovePsprites` copies from the weapon's every tic).

use bam::Angle;
use doom_physics::{MF_NOTDMATCH, Mobj, World, spawn_player};
use fixed::Fixed;
use geom2d::Point;
use super::num::{add32, rd32};

// ---------------------------------------------------------------------------
// Constants (p_local.h, p_pspr.h, p_inter.c, d_items.c)
// ---------------------------------------------------------------------------

/// `VIEWHEIGHT`, 41 units: the eye above the player's feet.
pub const VIEWHEIGHT: felt252 = 41 * 65536;
/// `VIEWHEIGHT / 2`, the floor `P_CalcHeight` springs back from.
pub const HALF_VIEWHEIGHT: felt252 = 1343488;
/// `MAXBOB`, 16 units: the ceiling on the view-bob amplitude.
pub const MAXBOB: felt252 = 0x100000;
/// `USERANGE`, 64 units: how far `P_UseLines` traces.
pub const USERANGE: felt252 = 64 * 65536;
/// `LOWERSPEED` / `RAISESPEED`, 6 units per tic.
pub const RAISESPEED: felt252 = 6 * 65536;
/// `WEAPONBOTTOM`, the off-screen `sy` of a lowered weapon.
pub const WEAPONBOTTOM: felt252 = 128 * 65536;
/// `WEAPONTOP`, the `sy` of a raised weapon.
pub const WEAPONTOP: felt252 = 32 * 65536;
/// `MAXHEALTH`: the cap a medikit or a stimpack heals to.
pub const MAXHEALTH: u32 = 100;
/// The cap a health bonus or a soulsphere may reach.
pub const MAXHEALTH_BONUS: u32 = 200;
/// The cap an armor bonus may reach.
pub const MAXARMOR_BONUS: u32 = 200;
/// `BONUSADD`: tics of screen flash a pickup adds.
pub const BONUSADD: u32 = 6;
/// The `damagecount` ceiling (`P_DamageMobj`: "teleport stomp does 10k").
pub const MAXDAMAGECOUNT: u32 = 100;

/// `MAXMOVE`-scaled thrust per unit of `cmd.forwardmove`/`sidemove`
/// (`P_MovePlayer`: `cmd->forwardmove * 2048`).
pub const MOVE_UNIT: felt252 = 2048;

// Buttons (`d_event.h`). `ticcmd`'s `buttons` byte is Doom's own.
/// `BT_ATTACK`.
pub const BT_ATTACK: u32 = 1;
/// `BT_USE`.
pub const BT_USE: u32 = 2;
/// `BT_CHANGE`: the low weapon bits carry the weapon to switch to.
pub const BT_CHANGE: u32 = 4;
/// `BT_WEAPONMASK`.
pub const BT_WEAPONMASK: u32 = 8 + 16 + 32;
/// `BT_WEAPONSHIFT`.
pub const BT_WEAPONSHIFT: u32 = 8;
/// The same, as the `NonZero` literal `P_PlayerThink` divides by: `/` on a
/// `u32` keeps a "division by zero" arm the compiler does not fold, and that
/// arm costs the enclosing function its whole return width (S7 §8 rule 1).
pub const BT_WEAPONSHIFT_NZ: NonZero<u32> = 8;

// Weapons, compacted to the five `doom_things::WeaponId` carries.
/// `wp_fist`.
pub const WP_FIST: u32 = 0;
/// `wp_pistol`.
pub const WP_PISTOL: u32 = 1;
/// `wp_shotgun`.
pub const WP_SHOTGUN: u32 = 2;
/// `wp_chaingun`.
pub const WP_CHAINGUN: u32 = 3;
/// `wp_chainsaw`.
pub const WP_CHAINSAW: u32 = 4;
/// `wp_nochange`.
pub const WP_NOCHANGE: u32 = 5;
/// Number of weapons this roster carries.
pub const NUM_WEAPONS: u32 = 5;

/// `player->weaponowned[]` as a bit per weapon: `1 << WP_*`.
pub fn weapon_bit(weapon: u32) -> u32 {
    if weapon == WP_FIST {
        1
    } else if weapon == WP_PISTOL {
        2
    } else if weapon == WP_SHOTGUN {
        4
    } else if weapon == WP_CHAINGUN {
        8
    } else if weapon == WP_CHAINSAW {
        16
    } else {
        0
    }
}

// Ammo (`ammotype_t`).
/// `am_clip`.
pub const AM_CLIP: u32 = 0;
/// `am_shell`.
pub const AM_SHELL: u32 = 1;
/// `am_cell`.
pub const AM_CELL: u32 = 2;
/// `am_misl`.
pub const AM_MISL: u32 = 3;
/// `am_noammo`: a weapon that consumes nothing.
pub const AM_NOAMMO: u32 = 4;

/// `maxammo[]` (p_inter.c), before the backpack doubles it.
pub const MAXAMMO: [u32; 4] = [200, 50, 300, 50];
/// `clipammo[]` (p_inter.c): what "one clip" of each type is worth.
pub const CLIPAMMO: [u32; 4] = [10, 4, 20, 1];
/// `weaponinfo[].ammo` (d_items.c) for the five weapons above.
pub const WEAPON_AMMO: [u32; 5] = [AM_NOAMMO, AM_CLIP, AM_SHELL, AM_CLIP, AM_NOAMMO];
/// The weapon Doom's `BT_WEAPONMASK` value selects. Doom numbers its nine
/// weapons `fist, pistol, shotgun, chaingun, missile, plasma, bfg, chainsaw`
/// and the three this roster does not carry map to [`WP_NOCHANGE`], which
/// `P_PlayerThink`'s "do I own it?" test then refuses.
pub const WEAPON_OF_BUTTON: [u32; 8] = [
    WP_FIST, WP_PISTOL, WP_SHOTGUN, WP_CHAINGUN, WP_NOCHANGE, WP_NOCHANGE, WP_NOCHANGE, WP_CHAINSAW,
];

// Cards (`card_t`). Freedoom E1M1 carries the blue keycard and nothing else
// (`tools/wad/REPORT-e1m1.md`), so one bit is the whole set; the field is a
// bitset rather than a `bool` so a second key costs a constant, not a field.
/// `it_bluecard`.
pub const CARD_BLUE: u32 = 1;

/// `PST_LIVE`.
pub const PST_LIVE: u32 = 0;
/// `PST_DEAD` — D14's `status = 1` for the segment output.
pub const PST_DEAD: u32 = 1;

/// Felts [`push_felts`] appends.
pub const PLAYER_FELTS: u32 = 36;

/// Bias added to the signed `deltaviewheight`/`viewz`-style felts is not
/// needed: every `Fixed` is already offset-encoded (`fixed::BIAS`).
///
/// One player. Every field is a `u32`, a `bool` or a `Fixed` (< 2^33), so
/// every serialized felt is non-negative and below 2^72 (PLAN.md A7).
#[derive(Copy, Drop, PartialEq, Debug)]
pub struct Player {
    /// Index of the player's `Mobj` in `doom_game`'s list.
    pub mo: u32,
    /// [`PST_LIVE`] or [`PST_DEAD`].
    pub playerstate: u32,
    /// `player->health`, mirrored into `mo.health` — in `[0, 200]`.
    pub health: u32,
    pub armor_points: u32,
    /// 0 (none), 1 (green, absorbs a third) or 2 (blue, absorbs a half).
    pub armor_type: u32,
    /// `player->ammo[]`, one field per [`AM_CLIP`]…[`AM_MISL`] rather than a
    /// `[u32; 4]`: a fixed-size array *in a struct* makes
    /// `universal-sierra-compiler` 2.19.3 fail (`Deferred(Const) does not
    /// match OutputVarReferenceInfo::ZeroSized`) under the
    /// `inlining-strategy = "avoid"` that `cairo-coverage` needs, and four
    /// fields also read for free where the array cost a `Span` index.
    pub ammo_clip: u32,
    pub ammo_shell: u32,
    pub ammo_cell: u32,
    pub ammo_misl: u32,
    /// `player->backpack`: [`MAXAMMO`] is doubled while true.
    pub backpack: bool,
    /// `player->weaponowned[]` as a bitset ([`weapon_bit`]).
    pub weapons: u32,
    pub ready_weapon: u32,
    /// [`WP_NOCHANGE`] when no switch is pending.
    pub pending_weapon: u32,
    /// `player->cards[]` as a bitset ([`CARD_BLUE`]).
    pub cards: u32,
    /// `player->powers[pw_strength]`, the berserk counter (the only power
    /// reachable on E1M1 at skill 2). Non-zero means "berserk"; it counts up
    /// for the palette, exactly as vanilla does.
    pub strength: u32,
    /// The eye height above the floor of the level, `mo.z + viewheight + bob`.
    pub viewz: Fixed,
    pub viewheight: Fixed,
    pub deltaviewheight: Fixed,
    /// `P_CalcHeight`'s bob amplitude, also read by `A_WeaponReady`.
    pub bob: Fixed,
    /// `ps_weapon`: the weapon psprite's state, tics left and offsets.
    pub psp_state: u32,
    pub psp_tics: u32,
    pub psp_sx: Fixed,
    pub psp_sy: Fixed,
    /// `ps_flash`: the muzzle-flash psprite (its `sx`/`sy` are the weapon's).
    pub flash_state: u32,
    pub flash_tics: u32,
    /// `player->extralight`, the muzzle flash's light bump (renderer only).
    pub extralight: u32,
    pub damagecount: u32,
    pub bonuscount: u32,
    /// The mobj that last hurt the player (`doom_physics::NO_MOBJ` for none).
    pub attacker: u32,
    pub attackdown: bool,
    pub usedown: bool,
    /// `player->refire`: consecutive tics of held fire, which turns off the
    /// pistol's and the chaingun's first-shot accuracy.
    pub refire: u32,
    /// Always `0`: the proving path has no cheats. Kept as a field because
    /// `P_PlayerThink` and `P_DamageMobj` branch on it, and a fork that wants
    /// `CF_NOCLIP` should not have to change the hash schema.
    pub cheats: u32,
    pub killcount: u32,
    pub itemcount: u32,
    pub secretcount: u32,
}

/// `player->ammo[type]`, `0` for [`AM_NOAMMO`].
pub fn ammo_of(p: @Player, ammo: u32) -> u32 {
    if ammo == AM_CLIP {
        *p.ammo_clip
    } else if ammo == AM_SHELL {
        *p.ammo_shell
    } else if ammo == AM_CELL {
        *p.ammo_cell
    } else if ammo == AM_MISL {
        *p.ammo_misl
    } else {
        0
    }
}

/// `player->ammo[type] = value`.
pub fn set_ammo(p: Player, ammo: u32, value: u32) -> Player {
    if ammo == AM_CLIP {
        Player { ammo_clip: value, ..p }
    } else if ammo == AM_SHELL {
        Player { ammo_shell: value, ..p }
    } else if ammo == AM_CELL {
        Player { ammo_cell: value, ..p }
    } else if ammo == AM_MISL {
        Player { ammo_misl: value, ..p }
    } else {
        p
    }
}

/// `player->maxammo[type]`: [`MAXAMMO`], doubled while the backpack is held.
pub fn max_ammo(p: @Player, ammo: u32) -> u32 {
    if ammo >= 4 {
        return 0;
    }
    let base = rd32(MAXAMMO.span(), ammo);
    if *p.backpack {
        add32(base, base)
    } else {
        base
    }
}

/// `player->weaponowned[weapon]`.
pub fn owns(p: @Player, weapon: u32) -> bool {
    (*p.weapons & weapon_bit(weapon)) != 0
}

/// `player->cards[it_bluecard]`, which is all `doom_specials::Actor` asks for.
pub fn has_blue_key(p: @Player) -> bool {
    (*p.cards & CARD_BLUE) != 0
}

/// `weaponinfo[weapon].ammo`.
pub fn weapon_ammo(weapon: u32) -> u32 {
    if weapon >= NUM_WEAPONS {
        return AM_NOAMMO;
    }
    rd32(WEAPON_AMMO.span(), weapon)
}

// ---------------------------------------------------------------------------
// Spawning
// ---------------------------------------------------------------------------

/// `G_PlayerReborn` + `P_SpawnPlayer`: a fresh player at a map start, with
/// Doom's initial loadout (fist and pistol, 50 bullets, 100 health).
///
/// The `Mobj` comes from `doom_physics::spawn_mobj`, so that the player is a
/// map object like any other; `mo` is the index `doom_game` will store it at.
pub fn spawn(w: World, index: u32, start: Point, angle: Angle) -> (Player, Mobj) {
    let mut mo = spawn_player(w, start, angle);
    // `P_SpawnPlayer`: the player is never a deathmatch thing.
    mo.flags = mo.flags & (0xFFFFFFFF - MF_NOTDMATCH);
    (reborn(index, @mo), mo)
}

/// `G_PlayerReborn`: the loadout half of [`spawn`], over a mobj that already
/// exists (which is what the tests and a `doom_game` restart need).
pub fn reborn(index: u32, mo: @Mobj) -> Player {
    Player {
        mo: index,
        playerstate: PST_LIVE,
        health: MAXHEALTH,
        armor_points: 0,
        armor_type: 0,
        ammo_clip: 50,
        ammo_shell: 0,
        ammo_cell: 0,
        ammo_misl: 0,
        backpack: false,
        weapons: weapon_bit(WP_FIST) + weapon_bit(WP_PISTOL),
        ready_weapon: WP_PISTOL,
        pending_weapon: WP_NOCHANGE,
        cards: 0,
        strength: 0,
        viewz: Fixed { enc: *mo.z.enc + VIEWHEIGHT },
        viewheight: Fixed { enc: fixed::BIAS + VIEWHEIGHT },
        deltaviewheight: fixed::ZERO,
        bob: fixed::ZERO,
        psp_state: 0,
        psp_tics: 0,
        psp_sx: fixed::FRACUNIT,
        psp_sy: Fixed { enc: fixed::BIAS + WEAPONBOTTOM },
        flash_state: 0,
        flash_tics: 0,
        extralight: 0,
        damagecount: 0,
        bonuscount: 0,
        attacker: doom_physics::NO_MOBJ,
        attackdown: false,
        usedown: false,
        refire: 0,
        cheats: 0,
        killcount: 0,
        itemcount: 0,
        secretcount: 0,
    }
}

// ---------------------------------------------------------------------------
// Serialization (the `doom_game` schema)
// ---------------------------------------------------------------------------

/// Number of felts [`push_felts`] appends, for `state_hash::open` (D16).
pub fn fields() -> u32 {
    PLAYER_FELTS
}

/// Append the [`PLAYER_FELTS`] felts of `p`, in this fixed order:
///
/// ```text
/// mo, playerstate, health, armor_points, armor_type,
/// ammo_clip, ammo_shell, ammo_cell, ammo_misl, backpack, weapons, ready_weapon, pending_weapon,
/// cards, strength, viewz, viewheight, deltaviewheight, bob,
/// psp_state, psp_tics, psp_sx, psp_sy, flash_state, flash_tics,
/// extralight, damagecount, bonuscount, attacker, attackdown, usedown,
/// refire, cheats, killcount, itemcount, secretcount
/// ```
///
/// `Fixed` fields are their `enc` (< 2^33), every other one is a `u32` or a
/// bit: every felt is non-negative and below 2^72 (A7).
pub fn push_felts(ref out: Array<felt252>, p: @Player) {
    out.append((*p.mo).into());
    out.append((*p.playerstate).into());
    out.append((*p.health).into());
    out.append((*p.armor_points).into());
    out.append((*p.armor_type).into());
    out.append((*p.ammo_clip).into());
    out.append((*p.ammo_shell).into());
    out.append((*p.ammo_cell).into());
    out.append((*p.ammo_misl).into());
    out.append(bit(*p.backpack));
    out.append((*p.weapons).into());
    out.append((*p.ready_weapon).into());
    out.append((*p.pending_weapon).into());
    out.append((*p.cards).into());
    out.append((*p.strength).into());
    out.append(*p.viewz.enc);
    out.append(*p.viewheight.enc);
    out.append(*p.deltaviewheight.enc);
    out.append(*p.bob.enc);
    out.append((*p.psp_state).into());
    out.append((*p.psp_tics).into());
    out.append(*p.psp_sx.enc);
    out.append(*p.psp_sy.enc);
    out.append((*p.flash_state).into());
    out.append((*p.flash_tics).into());
    out.append((*p.extralight).into());
    out.append((*p.damagecount).into());
    out.append((*p.bonuscount).into());
    out.append((*p.attacker).into());
    out.append(bit(*p.attackdown));
    out.append(bit(*p.usedown));
    out.append((*p.refire).into());
    out.append((*p.cheats).into());
    out.append((*p.killcount).into());
    out.append((*p.itemcount).into());
    out.append((*p.secretcount).into());
}

fn bit(b: bool) -> felt252 {
    if b {
        1
    } else {
        0
    }
}
