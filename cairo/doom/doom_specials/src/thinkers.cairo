// SPDX-License-Identifier: GPL-2.0-only
//! One tic of every running special: `T_VerticalDoor` (p_doors.c),
//! `T_PlatRaise` (p_plats.c), `T_MoveFloor` (p_floor.c), `T_StrobeFlash` and
//! `T_LightFlash` (p_lights.c), all sharing `T_MovePlane` (p_floor.c).
//!
//! # What `doom_specials` cannot answer on its own
//!
//! `T_MovePlane` moves a plane and then asks `P_ChangeSector` (p_map.c)
//! whether every mobj in the sector still fits between the floor and the
//! ceiling; if one does not, the move is undone and a closing door reverses.
//! That question needs the blockmap and the mobj list, which belong to
//! `doom_physics` and `doom_game`. It is the *only* thing this crate asks of
//! them, and it arrives as the one-method [`SectorBlocking`] trait.
//!
//! # Vanilla constants
//!
//! From `p_spec.h` and the thinkers themselves, at 35 tics per second:
//!
//! | Constant | Value | Where |
//! |---|---:|---|
//! | `VDOORSPEED` | `2 * FRACUNIT` | door, per tic |
//! | `VDOORWAIT` | 150 tics (≈ 4.3 s) | door, open |
//! | blazing door speed | `4 * VDOORSPEED` | special 117 |
//! | `PLATSPEED` | `FRACUNIT` | lift base speed |
//! | `downWaitUpStay` speed | `4 * PLATSPEED` | `EV_DoPlat` |
//! | `PLATWAIT` | 3 s = 105 tics | lift, down |
//! | `FLOORSPEED` | `FRACUNIT` | floor movers |
//! | `STROBEBRIGHT` | 5 tics | strobe, bright phase |
//! | `SLOWDARK` | 35 tics | strobe, dark phase (special 12) |
//! | flash `maxtime` / `mintime` | 64 / 7 | `P_SpawnLightFlash` |

use doom_map::LevelMap;
use fixed::Fixed;
use prng::{Prng, PrngTrait};
use super::level::SpecialsMap;
use super::state::{
    Heights, Light, LightKind, Mover, MoverKind, Phase, SpecialsState, ceiling_of, floor_of,
    heights, moves_ceiling, set_felt,
};

// ---------------------------------------------------------------------------
// Vanilla constants (p_spec.h)
// ---------------------------------------------------------------------------

/// `VDOORSPEED`, raw 16.16 units per tic.
pub const VDOORSPEED: felt252 = 131072;
/// `VDOORWAIT`, tics a `normal` or `blazeRaise` door stays open.
pub const VDOORWAIT: u32 = 150;
/// `VDOORSPEED * 4`, the blazing door of linedef special 117.
pub const BLAZESPEED: felt252 = 524288;
/// `PLATSPEED * 4`, the speed `EV_DoPlat` gives `downWaitUpStay`.
pub const PLATSPEED: felt252 = 262144;
/// `35 * PLATWAIT`, tics a lift waits at the bottom.
pub const PLATWAIT: u32 = 105;
/// `FLOORSPEED`, raw 16.16 units per tic.
pub const FLOORSPEED: felt252 = 65536;
/// `4 * FRACUNIT`, the gap `EV_DoDoor` leaves under the lowest surrounding
/// ceiling.
pub const DOOR_HEADROOM: felt252 = 262144;
/// `STROBEBRIGHT`, tics of the bright phase.
pub const STROBEBRIGHT: u32 = 5;
/// `FASTDARK`, the dark phase of a fast strobe (sector special 2; not on
/// E1M1, kept because `P_SpawnStrobeFlash` takes it as an argument).
pub const FASTDARK: u32 = 15;
/// `SLOWDARK`, the dark phase of the slow strobe of sector special 12.
pub const SLOWDARK: u32 = 35;
/// `flash->maxtime`, the mask `P_SpawnLightFlash` gives the bright phase.
pub const FLASH_MAXTIME: u32 = 64;
/// `flash->mintime`, the mask of the dark phase.
pub const FLASH_MINTIME: u32 = 7;

// ---------------------------------------------------------------------------
// The one callback into the world
// ---------------------------------------------------------------------------

/// `P_ChangeSector(sector, crush = false)` (p_map.c): with `sector`'s planes
/// at `floor` and `ceiling`, is there a mobj inside it that no longer fits?
///
/// Doom answers by walking the blockmap blocks of the sector's bounding box
/// and running `PIT_ChangeSector` on every mobj it finds. That is
/// `doom_physics`/`doom_game` territory, so this crate takes the answer as a
/// callback instead of reaching for a blockmap it must not know about.
///
/// Only closing doors act on it on E1M1 (a blocked door reverses); no
/// linedef special of this map crushes, so the `crush` argument of
/// `T_MovePlane` is always `false` and is not part of this interface.
pub trait SectorBlocking<W> {
    fn nofit(self: @W, sector: u32, floor: Fixed, ceiling: Fixed) -> bool;
}

/// A world where nothing is ever in the way — the behaviour before
/// `doom_physics` lands, and what the property tests use to isolate the
/// timing from the geometry.
#[derive(Copy, Drop, Serde, PartialEq, Debug)]
pub struct NeverBlocked {}

pub impl NeverBlockedBlocking of SectorBlocking<NeverBlocked> {
    fn nofit(self: @NeverBlocked, sector: u32, floor: Fixed, ceiling: Fixed) -> bool {
        false
    }
}

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

/// The kinds of [`Event`] the ticker and the triggers emit. Sounds carry
/// Doom's `sfx_*` name in the comment; nothing here changes the simulation,
/// it is all for the renderer and the audio layer.
pub mod event {
    /// `sfx_doropn`, a normal door starts opening. Subject: sector.
    pub const DOOR_OPEN: u8 = 1;
    /// `sfx_dorcls`, a normal door starts closing. Subject: sector.
    pub const DOOR_CLOSE: u8 = 2;
    /// `sfx_bdopn`, a blazing door starts opening. Subject: sector.
    pub const BLAZE_OPEN: u8 = 3;
    /// `sfx_bdcls`, a blazing door slams. Subject: sector.
    pub const BLAZE_CLOSE: u8 = 4;
    /// `sfx_pstart`, a lift starts moving. Subject: sector.
    pub const PLAT_START: u8 = 5;
    /// `sfx_pstop`, a lift stops. Subject: sector.
    pub const PLAT_STOP: u8 = 6;
    /// `sfx_stnmov`, a floor grinds (every 8 tics, as `T_MoveFloor` does).
    pub const FLOOR_MOVE: u8 = 7;
    /// `P_ChangeSwitchTexture`: flip this linedef's switch texture.
    /// Subject: linedef. Value: 1 when the switch may be used again.
    pub const SWITCH: u8 = 8;
    /// A sector's plane moved this tic. Subject: sector. Value: 1 for a
    /// ceiling, 0 for a floor.
    pub const SECTOR_MOVED: u8 = 9;
    /// A secret sector was counted. Subject: sector.
    pub const SECRET: u8 = 10;
    /// `G_ExitLevel`. Subject: the linedef that did it.
    pub const EXIT: u8 = 11;
    /// A locked door refused to open (`sfx_oof`, `PD_BLUEK`).
    /// Subject: linedef.
    pub const LOCKED: u8 = 12;
}

/// One render/audio cue. Never read back by the simulation, so it is not
/// part of the hashed state.
#[derive(Copy, Drop, Serde, PartialEq, Debug)]
pub struct Event {
    pub kind: u8,
    /// Sector id or linedef id, per [`event`].
    pub subject: u32,
    pub value: u32,
}

pub fn cue(kind: u8, subject: u32) -> Event {
    Event { kind, subject, value: 0 }
}

// ---------------------------------------------------------------------------
// T_MovePlane
// ---------------------------------------------------------------------------

/// `T_MovePlane` returned `ok`: the plane moved a whole `speed`.
pub const RES_OK: u8 = 0;
/// `crushed`: something was in the way and the move was undone.
pub const RES_CRUSHED: u8 = 1;
/// `pastdest`: the plane reached (and was clamped to) its destination.
pub const RES_PASTDEST: u8 = 2;

/// `T_MovePlane(sector, speed, dest, crush = false, plane, direction)`.
///
/// The clamp is Doom's, strict comparison included: a plane that lands
/// *exactly* on `dest` returns `ok` and only reports `pastdest` on the
/// following tic, which is why a door's travel is one tic longer than
/// `distance / speed`.
///
/// With `crush == false` all four of Doom's plane/direction cases collapse
/// to the same shape — move, ask `P_ChangeSector`, undo and report on a
/// refusal — so this is one function instead of four.
pub fn move_plane<W, +SectorBlocking<W>, +Drop<W>>(
    world: @W, h: @Heights, mover: Mover, dest: Fixed, up: bool,
) -> (Fixed, u8) {
    let candidate = if up {
        fixed::add(mover.height, mover.speed)
    } else {
        fixed::sub(mover.height, mover.speed)
    };
    let past = if up {
        fixed::gt(candidate, dest)
    } else {
        fixed::lt(candidate, dest)
    };
    let target = if past {
        dest
    } else {
        candidate
    };
    let (floor, ceiling) = if moves_ceiling(mover.kind) {
        (floor_of(h, mover.sector), target)
    } else {
        (target, ceiling_of(h, mover.sector))
    };
    if world.nofit(mover.sector, floor, ceiling) {
        // Vanilla restores `lastpos` and calls `P_ChangeSector` again; the
        // plane simply does not move this tic.
        return (mover.height, if past {
            RES_PASTDEST
        } else {
            RES_CRUSHED
        });
    }
    (target, if past {
        RES_PASTDEST
    } else {
        RES_OK
    })
}

// ---------------------------------------------------------------------------
// The plane thinkers
// ---------------------------------------------------------------------------

/// One tic of `T_VerticalDoor`. The `bool` is `false` when the thinker
/// removed itself (`P_RemoveThinker`); the `Mover` still carries the height
/// the plane stopped at, which the caller latches.
fn tick_door<W, +SectorBlocking<W>, +Drop<W>>(
    world: @W, h: @Heights, mover: Mover, ref events: Array<Event>,
) -> (Mover, bool) {
    let mut mv = mover;
    let blazing = mv.kind == MoverKind::DoorBlazeRaise;
    match mv.phase {
        Phase::Waiting => {
            if mv.count != 0 {
                mv.count -= 1;
            }
            if mv.count == 0 {
                mv.phase = Phase::Down;
                events
                    .append(
                        cue(
                            if blazing {
                                event::BLAZE_CLOSE
                            } else {
                                event::DOOR_CLOSE
                            }, mv.sector,
                        ),
                    );
            }
            (mv, true)
        },
        Phase::Down => {
            // `T_VerticalDoor` closes onto the sector's *current* floor.
            let dest = floor_of(h, mv.sector);
            let (height, res) = move_plane(world, h, mv, dest, false);
            let moved = height.enc != mv.height.enc;
            mv.height = height;
            if moved {
                events.append(Event { kind: event::SECTOR_MOVED, subject: mv.sector, value: 1 });
            }
            if res == RES_PASTDEST {
                if blazing {
                    events.append(cue(event::BLAZE_CLOSE, mv.sector));
                }
                (mv, false)
            } else if res == RES_CRUSHED {
                // "DO NOT GO BACK UP" applies to `close`/`blazeClose` only;
                // every door type this map carries reverses.
                mv.phase = Phase::Up;
                events.append(cue(event::DOOR_OPEN, mv.sector));
                (mv, true)
            } else {
                (mv, true)
            }
        },
        Phase::Up => {
            let top = mv.top;
            let (height, res) = move_plane(world, h, mv, top, true);
            let moved = height.enc != mv.height.enc;
            mv.height = height;
            if moved {
                events.append(Event { kind: event::SECTOR_MOVED, subject: mv.sector, value: 1 });
            }
            if res != RES_PASTDEST {
                return (mv, true);
            }
            if mv.kind == MoverKind::DoorOpen {
                return (mv, false);
            }
            mv.phase = Phase::Waiting;
            mv.count = mv.wait;
            (mv, true)
        },
    }
}

/// One tic of `T_PlatRaise`, restricted to `downWaitUpStay`.
fn tick_plat<W, +SectorBlocking<W>, +Drop<W>>(
    world: @W, h: @Heights, mover: Mover, ref events: Array<Event>,
) -> (Mover, bool) {
    let mut mv = mover;
    match mv.phase {
        Phase::Up => {
            let top = mv.top;
            let (height, res) = move_plane(world, h, mv, top, true);
            let moved = height.enc != mv.height.enc;
            mv.height = height;
            if moved {
                events.append(Event { kind: event::SECTOR_MOVED, subject: mv.sector, value: 0 });
            }
            if res == RES_CRUSHED {
                mv.count = mv.wait;
                mv.phase = Phase::Down;
                events.append(cue(event::PLAT_START, mv.sector));
                return (mv, true);
            }
            if res == RES_PASTDEST {
                // `downWaitUpStay` ends here: `P_RemoveActivePlat`.
                events.append(cue(event::PLAT_STOP, mv.sector));
                return (mv, false);
            }
            (mv, true)
        },
        Phase::Down => {
            let bottom = mv.bottom;
            let (height, res) = move_plane(world, h, mv, bottom, false);
            let moved = height.enc != mv.height.enc;
            mv.height = height;
            if moved {
                events.append(Event { kind: event::SECTOR_MOVED, subject: mv.sector, value: 0 });
            }
            if res == RES_PASTDEST {
                mv.count = mv.wait;
                mv.phase = Phase::Waiting;
                events.append(cue(event::PLAT_STOP, mv.sector));
            }
            (mv, true)
        },
        Phase::Waiting => {
            if mv.count != 0 {
                mv.count -= 1;
            }
            if mv.count == 0 {
                mv.phase = if mv.height.enc == mv.bottom.enc {
                    Phase::Up
                } else {
                    Phase::Down
                };
                events.append(cue(event::PLAT_START, mv.sector));
            }
            (mv, true)
        },
    }
}

/// One tic of `T_MoveFloor`, restricted to `lowerFloorToLowest`.
fn tick_floor<W, +SectorBlocking<W>, +Drop<W>>(
    world: @W, h: @Heights, mover: Mover, tic: u32, ref events: Array<Event>,
) -> (Mover, bool) {
    let mut mv = mover;
    let bottom = mv.bottom;
    let (height, res) = move_plane(world, h, mv, bottom, false);
    let moved = height.enc != mv.height.enc;
    mv.height = height;
    if moved {
        events.append(Event { kind: event::SECTOR_MOVED, subject: mv.sector, value: 0 });
    }
    // `if (!(leveltime & 7)) S_StartSound(&sec->soundorg, sfx_stnmov)`.
    if tic % 8 == 0 {
        events.append(cue(event::FLOOR_MOVE, mv.sector));
    }
    (mv, res != RES_PASTDEST)
}

// ---------------------------------------------------------------------------
// The light thinkers
// ---------------------------------------------------------------------------

/// One flip of `T_StrobeFlash` or `T_LightFlash`, at absolute tic `tic`.
///
/// Doom counts down (`if (--flash->count) return;`); [`Light::next`] holds
/// the **absolute tic of the next flip** instead, which is the same
/// information (`count = next - tic`) and lets [`specials_ticker`] skip all
/// nine of E1M1's light thinkers with a single comparison on the 39 tics out
/// of 40 where none of them is due.
fn flip_light(light: Light, tic: u32, rng: Prng, table: Span<u8>) -> (Light, Prng) {
    let mut l = light;
    match l.kind {
        LightKind::Strobe => {
            if l.light == l.minlight {
                l.light = l.maxlight;
                l.next = tic + l.hi_time;
            } else {
                l.light = l.minlight;
                l.next = tic + l.lo_time;
            }
            (l, rng)
        },
        LightKind::Flash => {
            if l.light == l.maxlight {
                l.light = l.minlight;
                let (next_rng, roll) = rng.next(table);
                l.next = tic + (roll.into() & l.lo_time) + 1;
                (l, next_rng)
            } else {
                l.light = l.maxlight;
                let (next_rng, roll) = rng.next(table);
                l.next = tic + (roll.into() & l.hi_time) + 1;
                (l, next_rng)
            }
        },
    }
}

// ---------------------------------------------------------------------------
// The ticker
// ---------------------------------------------------------------------------

/// The earliest tic at which any light thinker flips — the cached
/// `min(lights.next)` [`SpecialsState::next_light`] carries.
pub fn next_light_tic(lights: Span<Light>) -> u32 {
    let mut best: u32 = 0xFFFFFFFF;
    let mut i: u32 = 0;
    while i != lights.len() {
        let l = *lights.at(i);
        if l.next < best {
            best = l.next;
        }
        i += 1;
    }
    best
}

/// Run every active special for one tic.
///
/// Returns the new state, the advanced `P_Random` cursor (only
/// `T_LightFlash` draws) and the render/audio cues of this tic. When
/// nothing is running the state comes back **unchanged** — `Span` is
/// `Copy`, so no array is rebuilt and the tic costs a handful of
/// comparisons.
pub fn specials_ticker<W, +SectorBlocking<W>, +Drop<W>>(
    world: @W,
    state: SpecialsState,
    m: @LevelMap,
    lm: @SpecialsMap,
    tic: u32,
    rng: Prng,
    table: Span<u8>,
) -> (SpecialsState, Prng, Span<Event>) {
    let mut s = state;
    let mut prng = rng;
    let mut events: Array<Event> = array![];

    // --- lights -----------------------------------------------------------
    if tic >= s.next_light {
        let lights = s.lights;
        let mut rebuilt: Array<Light> = array![];
        let mut soonest: u32 = 0xFFFFFFFF;
        let mut i: u32 = 0;
        while i != lights.len() {
            let l = *lights.at(i);
            let out = if l.next <= tic {
                let (flipped, next_rng) = flip_light(l, tic, prng, table);
                prng = next_rng;
                flipped
            } else {
                l
            };
            if out.next < soonest {
                soonest = out.next;
            }
            rebuilt.append(out);
            i += 1;
        }
        s.lights = rebuilt.span();
        s.next_light = soonest;
    }

    // --- plane movers -----------------------------------------------------
    let movers = s.movers;
    if movers.len() != 0 {
        let view = heights(@s, m, lm);
        let mut kept: Array<Mover> = array![];
        let mut ceilings = s.ceilings;
        let mut floors = s.floors;
        let mut i: u32 = 0;
        while i != movers.len() {
            let mv = *movers.at(i);
            let result = match mv.kind {
                MoverKind::DoorNormal => tick_door(world, @view, mv, ref events),
                MoverKind::DoorOpen => tick_door(world, @view, mv, ref events),
                MoverKind::DoorBlazeRaise => tick_door(world, @view, mv, ref events),
                MoverKind::PlatDownWaitUpStay => tick_plat(world, @view, mv, ref events),
                MoverKind::FloorLowerToLowest => tick_floor(world, @view, mv, tic, ref events),
            };
            let (next, keep) = result;
            if keep {
                kept.append(next);
            } else if moves_ceiling(next.kind) {
                // `P_RemoveThinker`: the plane keeps the height it stopped
                // at, so it is latched into the slot array.
                ceilings = set_felt(ceilings, next.slot, next.height.enc);
            } else {
                floors = set_felt(floors, next.slot, next.height.enc);
            }
            i += 1;
        }
        s.movers = kept.span();
        s.ceilings = ceilings;
        s.floors = floors;
    }

    (s, prng, events.span())
}
