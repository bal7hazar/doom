// SPDX-License-Identifier: GPL-2.0-only
//! What a tic of monster AI reports to its caller.
//!
//! Everything a monster does to the *world* rather than to itself leaves an
//! event: a sound for the renderer, a puff or a splash of blood, a special
//! line to hand to `doom_specials`, a kill to count, an item to spawn. The
//! record is one flat struct rather than an `enum`, because in Cairo every
//! variant of an `enum` with different payloads costs its own match arm and
//! its own construction code at every site (S1 §5.9), and a renderer event
//! is read, never branched on, by the proving path.

use doom_physics::maputl::{inc, opaque_zero};
use doom_physics::{MoveEvent, NO_MOBJ};
use geom2d::Point;

/// `a` is the sound id (this crate's [`super::tables`] numbering).
pub const EV_SOUND: u32 = 1;
/// A bullet puff at `at`; `a` is the mobj it hit, or `0` for a wall.
pub const EV_PUFF: u32 = 2;
/// Blood at `at`; `a` is the mobj hit and `b` the damage.
pub const EV_BLOOD: u32 = 3;
/// A monster crossed a walk-triggered special: `a` is the linedef and `b`
/// the side it came from. `doom_game` hands it to
/// `doom_specials::cross_line` with a non-player `Actor` (only E1M1's
/// repeatable lift, special 88, answers to a monster).
pub const EV_CROSS: u32 = 4;
/// A monster's walk was refused by linedef `a`: vanilla `P_Move` would call
/// `P_UseSpecialLine` on it to push a door open.
pub const EV_USE: u32 = 5;
/// The `MF_COUNTKILL` mobj `who` died; `a` is who killed it.
pub const EV_KILLED: u32 = 6;
/// The kill of `who` dropped an item of kind `a` at `at` — `doom_game`
/// gives it a slot (`first_free`/`push`) and links it.
pub const EV_DROP: u32 = 7;
/// Monster `who` woke up and is now chasing mobj `a`.
pub const EV_WAKE: u32 = 8;

/// One thing that happened during [`super::monsters_ticker`].
#[derive(Copy, Drop, Serde, PartialEq, Debug)]
pub struct MonsterEvent {
    /// One of the `EV_*` constants above.
    pub kind: u32,
    /// The mobj the event is about.
    pub who: u32,
    /// First payload, per `kind`.
    pub a: u32,
    /// Second payload, per `kind`.
    pub b: u32,
    /// Where it happened; `fixed::ZERO` twice when the kind carries no
    /// point.
    pub at: Point,
}

/// An event with no point.
pub fn event(kind: u32, who: u32, a: u32, b: u32) -> MonsterEvent {
    MonsterEvent { kind, who, a, b, at: Point { x: fixed::ZERO, y: fixed::ZERO } }
}

/// [`EV_SOUND`].
pub fn sound(who: u32, id: u32) -> MonsterEvent {
    event(EV_SOUND, who, id, 0)
}

/// Translate the `MoveEvent`s a `try_move` produced into [`EV_CROSS`]
/// events for `who`. `Touch` is ignored (a monster has no `MF_PICKUP`) and
/// `MissileHit` is handled by the caller, which owns the RNG order.
pub fn drain(moves: Span<MoveEvent>, who: u32, ref ev: Array<MonsterEvent>) {
    let n = moves.len();
    let mut k: u32 = opaque_zero(n);
    while k != n {
        match moves.get(k) {
            Option::Some(b) => {
                match *b.unbox() {
                    MoveEvent::CrossSpecial((
                        line, side,
                    )) => { ev.append(event(EV_CROSS, who, line, side.into())); },
                    _ => {},
                }
            },
            Option::None => {},
        }
        k = inc(k);
    }
}

/// The mobj a missile's move ran into, or [`NO_MOBJ`].
pub fn missile_hit(moves: Span<MoveEvent>) -> u32 {
    let n = moves.len();
    let mut k: u32 = opaque_zero(n);
    let mut hit = NO_MOBJ;
    while k != n {
        match moves.get(k) {
            Option::Some(b) => {
                match *b.unbox() {
                    MoveEvent::MissileHit(idx) => { hit = idx; },
                    _ => {},
                }
            },
            Option::None => {},
        }
        k = inc(k);
    }
    hit
}
