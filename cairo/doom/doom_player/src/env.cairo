// SPDX-License-Identifier: GPL-2.0-only
//! What a player action reads but never writes, and what it reports back.

use doom_physics::{Hit, Mobj, World};
use fsm::StateTables;
use super::state::Player;

/// The read-only side of one tic, built once by `doom_game` and passed down
/// the (short) action chain.
///
/// **`world` is boxed on purpose.** A [`World`] is nineteen spans plus a
/// grid — about 56 felts — and Cairo copies every one of them at every call
/// boundary (D24, and the ~740 steps of argument plumbing `doom_physics`
/// measured on `xy_movement`). A `Box` is one felt: the whole bundle costs
/// one write per tic and is unboxed only by the three actions that actually
/// trace a shot. `states` is duplicated out of it because *every* psprite
/// tic reads it.
#[derive(Copy, Drop)]
pub struct Env {
    /// `doom_physics`' world (level spans + the **current** sector heights).
    pub world: Box<World>,
    /// `doom_things::states()`, hoisted out of `world` for the psprite tic.
    pub states: StateTables,
    /// The mobj list as the tic loop sees it (the player's own copy is the
    /// `ref mo` the entry points take, not this).
    pub mobjs: Span<Mobj>,
    /// Index of the player's mobj in `mobjs`.
    pub me: u32,
    /// `leveltime`: drives the view bob and the weapon bob.
    pub tic: u32,
    /// `cmd.buttons`, already decoded out of the ticcmd word (D15).
    pub buttons: u32,
}

/// Bundle one tic's read-only inputs.
pub fn env_of(w: World, mobjs: Span<Mobj>, me: u32, tic: u32, buttons: u32) -> Env {
    Env { world: BoxTrait::new(w), states: w.states, mobjs, me, tic, buttons }
}

/// Put a tic's three wide operands behind pointers, once, at a public entry
/// point (S7 §8 rule 3).
///
/// An [`Env`] is 16 felts, a `Player` 36 and a `Mobj` 27; every one of them
/// is pushed in full at every call that carries it, and a panic site or a
/// return point stores the enclosing function's whole width again. Behind a
/// `Box` each is one felt, reading a field through it is free, and only a
/// *write* pays — one `into_box` of that record's width. The whole inside of
/// this crate (`*_in`) therefore works on boxes and the public functions are
/// the wrappers that box on the way in and [`leave`] on the way out.
#[inline(always)]
pub(crate) fn enter(env: Env, p: @Player, mo: @Mobj) -> (Box<Env>, Box<Player>, Box<Mobj>) {
    (BoxTrait::new(env), BoxTrait::new(*p), BoxTrait::new(*mo))
}

/// Write the boxed records back into a public entry point's `ref`s.
#[inline(always)]
pub(crate) fn leave(bp: Box<Player>, bm: Box<Mobj>, ref p: Player, ref mo: Mobj) {
    p = bp.unbox();
    mo = bm.unbox();
}

/// What a player tic did to *other* things, for `doom_game` to apply — the
/// same "report, do not reach into another mobj" contract `doom_physics`
/// uses for `MoveEvent` and `Hit`.
#[derive(Copy, Drop, PartialEq, Debug)]
pub enum PlayerEvent {
    /// One bullet or one punch: `doom_physics::line_attack`'s verdict and
    /// the damage to apply. `doom_game` runs
    /// `damage_mobj(thing, player, player, damage)` on a `Hit::Thing` and
    /// hands the point to the renderer as a puff or blood.
    Shot: (Hit, u32),
    /// An `MF_SPECIAL` thing was picked up: remove that mobj.
    Picked: u32,
    /// `P_UseLines` stopped on a special line: `(line, side)` for
    /// `doom_specials::use_line`. [`super::tic::player_tic`] applies it; a
    /// caller driving [`super::think::player_think`] directly must.
    Use: (u32, u8),
}
