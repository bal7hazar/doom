// SPDX-License-Identifier: GPL-2.0-only
//! The player of a Doom-like tic: `p_user.c`, `p_pspr.c` and the player's
//! half of `p_inter.c` from linuxdoom-1.10 (GPL-2.0-only; semantics derived,
//! no C copied), over `doom_physics`' geometry and `doom_things`' tables.
//!
//! # Shape
//!
//! * A [`Player`] is a value — 36 felts once serialized ([`push_felts`]) —
//!   next to the `Mobj` it drives, which `doom_physics` owns. Every entry
//!   point takes both by `ref` and returns nothing.
//! * An [`Env`] is what a tic reads and never writes. Its `World` is
//!   **boxed**: a world is ~56 felts and Cairo copies a struct at every call
//!   boundary, so the psprite chain would pay for it on every idle tic (D24).
//! * A function that would touch *another* mobj reports it instead
//!   ([`PlayerEvent`]), exactly as `doom_physics` does: a shot is a
//!   `doom_physics::Hit` plus its damage, a pickup is the index to remove, a
//!   use is the line for `doom_specials`.
//!
//! # Entry points
//!
//! | | |
//! |---|---|
//! | [`spawn`] | `G_PlayerReborn` + `P_SpawnPlayer` |
//! | [`player_think`] | `P_PlayerThink` for one already-decoded ticcmd word (D15) |
//! | [`player_tic`] | the same, with `doom_specials`' two triggers wired in |
//! | [`touch_special`] | `P_TouchSpecialThing`, from `MoveEvent::Touch` |
//! | [`damage_player`] | `P_DamageMobj` with the armor absorption |
//! | [`push_felts`] | the serialization schema `doom_game` splices in |
//!
//! # Cost discipline
//!
//! The rules of docs/spikes/S7.md §8, which `doom_physics` measured on
//! itself: **no panic site on the proving path** (`num`, and
//! `doom_physics`' panic-free table twins), **nothing wide across a call**,
//! **one return per wide function**,
//! one small function per loop, and no second monomorphisation of a heavy
//! generic (the use-line trace goes through `doom_physics::path_traverse`,
//! not through the `Traverser` trait). Felt-first arithmetic below 2^72,
//! planar `const` spans where the table is *data* — and `if` trees where it
//! is a dispatch, which is measured, not assumed (README).
//! `bench/measure.py` asserts the per-function budgets and both bytecode
//! figures; `bench/attribute.py` says where every word goes.

pub mod compat;
pub mod env;
pub mod inter;
/// Panic-free scalar arithmetic (S7 §8 rule 1). Crate-private: it is a cost
/// discipline, not an API.
mod num;
pub mod state;

#[cfg(test)]
mod tests;
pub mod think;
pub mod tic;
pub mod weapon;

pub use compat::{PlayerState, apply_damage, spawn as spawn_skeleton, think as think_skeleton};
pub use env::{Env, PlayerEvent, env_of};
pub use inter::{
    absorb, count_kill, damage_player, give_ammo, give_armor, give_body, give_card, give_strength,
    give_weapon, touch_special,
};
pub use state::{
    AM_CELL, AM_CLIP, AM_MISL, AM_NOAMMO, AM_SHELL, BONUSADD, BT_ATTACK, BT_CHANGE, BT_USE,
    BT_WEAPONMASK, CARD_BLUE, CLIPAMMO, MAXAMMO, MAXARMOR_BONUS, MAXBOB, MAXHEALTH, MAXHEALTH_BONUS,
    PLAYER_FELTS, PST_DEAD, PST_LIVE, Player, USERANGE, VIEWHEIGHT, WP_CHAINGUN, WP_CHAINSAW,
    WP_FIST, WP_NOCHANGE, WP_PISTOL, WP_SHOTGUN, ammo_of, fields, has_blue_key, max_ammo, owns,
    push_felts, set_ammo, spawn, weapon_ammo, weapon_bit,
};
pub use think::{
    calc_height, change_weapon, death_think, move_player, onground, player_stopped, player_think,
    thrust, use_lines,
};
pub use tic::player_tic;
pub use weapon::{
    MAX_PSPR_DEPTH, PS_FLASH, PS_WEAPON, S_PLAY, S_PLAY_ATK, bring_up_weapon, bullet_slope, chain,
    check_ammo, drop_weapon, hit_thing, move_psprites, set_psprite,
};
