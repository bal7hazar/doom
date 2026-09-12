// SPDX-License-Identifier: GPL-2.0-only
//! What starts a special: `P_SpawnSpecials`, `P_UseSpecialLine`,
//! `P_CrossSpecialLine`, `P_PlayerInSpecialSector` (p_spec.c), the
//! `EV_Do*` spawners (p_doors.c, p_plats.c, p_floor.c) and the
//! `P_Find*Surrounding` queries they all rest on.
//!
//! # Where the line comes from
//!
//! `P_UseLines` (p_map.c) traces a `USERANGE = 64 * FRACUNIT` ray from the
//! player and stops at the first line it can use. That trace is geometry and
//! belongs to `doom_physics`; this crate takes the **line it found** and
//! answers what happens ([`use_line`]). `P_CrossSpecialLine` is the same
//! split: `doom_physics` notices the crossing during `P_TryMove`, and
//! [`cross_line`] decides what it triggers.
//!
//! `P_ShootSpecialLine` has nothing to do on E1M1 — the map carries no
//! gun-activated special (`tools/wad/REPORT-e1m1.md`: specials 1, 2, 11, 23,
//! 26, 62, 88, 117 only) — so it is deliberately absent rather than written
//! and never called.
//!
//! # Switch textures
//!
//! `P_ChangeSwitchTexture` (p_switch.c) swaps a linedef's texture and starts
//! a `BUTTONTIME` timer that swaps it back. Neither the texture nor the
//! timer is ever read by the simulation, so both stay out of the hashed
//! state: the switch is emitted as an [`super::Event`] for the renderer, and
//! only the part that *does* change behaviour — `line->special = 0` on a
//! once-only switch — is kept, in [`SpecialsState::used`].

use doom_map::{LevelMap, NO_SECTOR};
use fixed::Fixed;
use prng::{Prng, PrngTrait};
use super::level::{SpecialsMap, neighbour, neighbours, tag_sector, tag_sectors};
use super::state::{
    Heights, Light, LightKind, Mover, MoverKind, Phase, SpecialsState, ceiling_of, floor_of,
    heights, mover_index, sector_special, set_mover, set_u32,
};
use super::thinkers::{
    Event, PLATSPEED, PLATWAIT, VDOORSPEED, VDOORWAIT, cue, event, next_light_tic,
};

/// Doom's `ML_SECRET`: a monster never opens a secret door.
pub const ML_SECRET: u32 = 32;

/// `MAXINT` in `fixed` encoding, the seed of
/// `P_FindLowestCeilingSurrounding`.
const MAXINT: Fixed = Fixed { enc: fixed::BIAS + 0x7FFFFFFF };
/// `-500 * FRACUNIT`, the seed of `P_FindHighestFloorSurrounding`.
const MINUS_500: Fixed = Fixed { enc: fixed::BIAS - 32768000 };

// ---------------------------------------------------------------------------
// P_Find*Surrounding
// ---------------------------------------------------------------------------

/// `P_FindLowestFloorSurrounding(sec)`: the lowest floor among `sec` and its
/// neighbours, on the **dynamic** heights (a lift parked at the bottom is
/// what the next lift sees).
pub fn find_lowest_floor_surrounding(h: @Heights, lm: @SpecialsMap, sector: u32) -> Fixed {
    let (from, to) = neighbours(lm, sector);
    let mut lowest = floor_of(h, sector);
    let mut k = from;
    while k != to {
        let other = floor_of(h, neighbour(lm, k));
        if fixed::lt(other, lowest) {
            lowest = other;
        }
        k += 1;
    }
    lowest
}

/// `P_FindHighestFloorSurrounding(sec)`: the highest neighbouring floor,
/// seeded at `-500 * FRACUNIT` and **not** including `sec` itself.
pub fn find_highest_floor_surrounding(h: @Heights, lm: @SpecialsMap, sector: u32) -> Fixed {
    let (from, to) = neighbours(lm, sector);
    let mut highest = MINUS_500;
    let mut k = from;
    while k != to {
        let other = floor_of(h, neighbour(lm, k));
        if fixed::gt(other, highest) {
            highest = other;
        }
        k += 1;
    }
    highest
}

/// `P_FindLowestCeilingSurrounding(sec)`: the lowest neighbouring ceiling,
/// seeded at `MAXINT` and **not** including `sec` itself — this is the
/// height a door opens to, minus four units.
pub fn find_lowest_ceiling_surrounding(h: @Heights, lm: @SpecialsMap, sector: u32) -> Fixed {
    let (from, to) = neighbours(lm, sector);
    let mut lowest = MAXINT;
    let mut k = from;
    while k != to {
        let other = ceiling_of(h, neighbour(lm, k));
        if fixed::lt(other, lowest) {
            lowest = other;
        }
        k += 1;
    }
    lowest
}

/// `P_FindMinSurroundingLight(sector, max)`, at spawn time — every light
/// level is still `doom_map`'s, because `P_SpawnSpecials` changes none.
fn find_min_surrounding_light(m: @LevelMap, lm: @SpecialsMap, sector: u32, max: u32) -> u32 {
    let (from, to) = neighbours(lm, sector);
    let mut min = max;
    let mut k = from;
    while k != to {
        let other = doom_map::sector(m, neighbour(lm, k)).light;
        if other < min {
            min = other;
        }
        k += 1;
    }
    min
}

// ---------------------------------------------------------------------------
// P_SpawnSpecials
// ---------------------------------------------------------------------------

/// `P_SpawnSpecials` (p_spec.c): the state of a level at tic 0.
///
/// Seeds the slot arrays from `doom_map`, spawns one light thinker per
/// light-special sector in ascending sector id (which is the order
/// `P_SpawnSpecials` visits them, and therefore the order `P_Random` is
/// drawn in — three draws on E1M1, one per `P_SpawnLightFlash`; a
/// synchronised strobe draws nothing), and clears `sector->special` on the
/// sectors those thinkers take over. Secret sectors (special 9) and damaging
/// sectors (special 7) keep their special: `P_PlayerInSpecialSector` reads
/// it every tic.
pub fn spawn_specials(
    m: @LevelMap, lm: @SpecialsMap, rng: Prng, table: Span<u8>,
) -> (SpecialsState, Prng) {
    let mut prng = rng;

    let mut ceilings: Array<felt252> = array![];
    let ceil_sectors = *lm.ceil_sectors;
    let mut i: u32 = 0;
    while i != ceil_sectors.len() {
        ceilings.append(doom_map::sector_ceiling(m, *ceil_sectors.at(i)).enc);
        i += 1;
    }

    let mut floors: Array<felt252> = array![];
    let floor_sectors = *lm.floor_sectors;
    i = 0;
    while i != floor_sectors.len() {
        floors.append(doom_map::sector_floor(m, *floor_sectors.at(i)).enc);
        i += 1;
    }

    let mut lights: Array<Light> = array![];
    let mut soonest: u32 = 0xFFFFFFFF;
    let light_sectors = *lm.light_sectors;
    i = 0;
    while i != light_sectors.len() {
        let id = *light_sectors.at(i);
        let info = doom_map::sector(m, id);
        let max = info.light;
        let min = find_min_surrounding_light(m, lm, id, max);
        let light = if info.special == 1 {
            // `P_SpawnLightFlash`: count = (P_Random() & maxtime) + 1.
            let (next_rng, roll) = prng.next(table);
            prng = next_rng;
            let count: u32 = (roll.into() & super::thinkers::FLASH_MAXTIME) + 1;
            Light {
                kind: LightKind::Flash,
                sector: id,
                light: max,
                maxlight: max,
                minlight: min,
                hi_time: super::thinkers::FLASH_MAXTIME,
                lo_time: super::thinkers::FLASH_MINTIME,
                next: count - 1,
            }
        } else {
            // `P_SpawnStrobeFlash(sector, SLOWDARK, inSync = 1)`: a strobe
            // whose neighbours are no darker than itself goes fully dark.
            let floor_min = if min == max {
                0
            } else {
                min
            };
            Light {
                kind: LightKind::Strobe,
                sector: id,
                light: max,
                maxlight: max,
                minlight: floor_min,
                hi_time: super::thinkers::STROBEBRIGHT,
                lo_time: super::thinkers::SLOWDARK,
                next: 0,
            }
        };
        if light.next < soonest {
            soonest = light.next;
        }
        lights.append(light);
        i += 1;
    }

    let mut specials: Array<u32> = array![];
    let special_sectors = *lm.special_sectors;
    i = 0;
    while i != special_sectors.len() {
        let info = doom_map::sector(m, *special_sectors.at(i));
        // `P_SpawnLightFlash` / `P_SpawnStrobeFlash` both end with
        // `sector->special = 0` ("nothing special about it during
        // gameplay"); a secret sector keeps its 9 until it is counted.
        specials.append(if info.special == 1 || info.special == 12 {
            0
        } else {
            info.special
        });
        i += 1;
    }

    (
        SpecialsState {
            ceilings: ceilings.span(),
            floors: floors.span(),
            specials: specials.span(),
            lights: lights.span(),
            next_light: soonest,
            movers: array![].span(),
            used: array![].span(),
            secrets: 0,
            exit: false,
        },
        prng,
    )
}

// ---------------------------------------------------------------------------
// EV_Do*
// ---------------------------------------------------------------------------

/// `P_ChangeSwitchTexture(line, use_again)`, minus the texture and the
/// `BUTTONTIME` timer: emit the render cue, and retire the linedef when the
/// switch is once-only.
fn change_switch_texture(
    state: SpecialsState, line: u32, use_again: bool, ref events: Array<Event>,
) -> SpecialsState {
    let mut s = state;
    events
        .append(Event { kind: event::SWITCH, subject: line, value: if use_again {
            1
        } else {
            0
        } });
    if !use_again {
        let mut used: Array<u32> = array![];
        let old = s.used;
        let mut i: u32 = 0;
        while i != old.len() {
            used.append(*old.at(i));
            i += 1;
        }
        used.append(line);
        s.used = used.span();
    }
    s
}

/// Copy the mover list, so a new thinker can be appended to it.
fn clone_movers(movers: Span<Mover>) -> Array<Mover> {
    let mut out: Array<Mover> = array![];
    let mut i: u32 = 0;
    while i != movers.len() {
        out.append(*movers.at(i));
        i += 1;
    }
    out
}

/// `EV_DoDoor(line, open)` (p_doors.c) — the only remote door type E1M1
/// carries (linedef special 2, W1 "open and stay").
///
/// Returns the new state and Doom's `rtn`: whether at least one sector
/// started moving, which is what the caller turns into a switch flip.
pub fn ev_do_door(
    state: SpecialsState,
    m: @LevelMap,
    lm: @SpecialsMap,
    tag: u32,
    kind: MoverKind,
    ref events: Array<Event>,
) -> (SpecialsState, bool) {
    let mut s = state;
    let view = heights(@s, m, lm);
    let (from, to) = tag_sectors(lm, tag);
    let mut movers = clone_movers(s.movers);
    let mut started = false;
    let mut k = from;
    while k != to {
        let id = tag_sector(lm, k);
        let slot = *(*lm.ceil_slot).at(id);
        // `if (sec->specialdata) continue;`
        if mover_index(@s, id).is_none() && slot != super::level::NO_SLOT {
            started = true;
            let top = fixed::sub(
                find_lowest_ceiling_surrounding(@view, lm, id),
                Fixed { enc: fixed::BIAS + super::thinkers::DOOR_HEADROOM },
            );
            let here = ceiling_of(@view, id);
            if top.enc != here.enc {
                events.append(cue(event::DOOR_OPEN, id));
            }
            movers
                .append(
                    Mover {
                        kind,
                        phase: Phase::Up,
                        sector: id,
                        slot,
                        height: here,
                        top,
                        bottom: floor_of(@view, id),
                        speed: Fixed { enc: fixed::BIAS + VDOORSPEED },
                        wait: VDOORWAIT,
                        count: 0,
                    },
                );
        }
        k += 1;
    }
    s.movers = movers.span();
    (s, started)
}

/// `EV_DoPlat(line, downWaitUpStay, 0)` (p_plats.c) — linedef specials 62
/// (switch, repeatable) and 88 (walk, repeatable, monsters may trigger).
pub fn ev_do_plat(
    state: SpecialsState, m: @LevelMap, lm: @SpecialsMap, tag: u32, ref events: Array<Event>,
) -> (SpecialsState, bool) {
    let mut s = state;
    let view = heights(@s, m, lm);
    let (from, to) = tag_sectors(lm, tag);
    let mut movers = clone_movers(s.movers);
    let mut started = false;
    let mut k = from;
    while k != to {
        let id = tag_sector(lm, k);
        let slot = *(*lm.floor_slot).at(id);
        if mover_index(@s, id).is_none() && slot != super::level::NO_SLOT {
            started = true;
            let here = floor_of(@view, id);
            let mut low = find_lowest_floor_surrounding(@view, lm, id);
            if fixed::gt(low, here) {
                low = here;
            }
            events.append(cue(event::PLAT_START, id));
            movers
                .append(
                    Mover {
                        kind: MoverKind::PlatDownWaitUpStay,
                        phase: Phase::Down,
                        sector: id,
                        slot,
                        height: here,
                        top: here,
                        bottom: low,
                        speed: Fixed { enc: fixed::BIAS + PLATSPEED },
                        wait: PLATWAIT,
                        count: 0,
                    },
                );
        }
        k += 1;
    }
    s.movers = movers.span();
    (s, started)
}

/// `EV_DoFloor(line, lowerFloorToLowest)` (p_floor.c) — linedef special 23.
pub fn ev_do_floor(
    state: SpecialsState, m: @LevelMap, lm: @SpecialsMap, tag: u32, ref events: Array<Event>,
) -> (SpecialsState, bool) {
    let mut s = state;
    let view = heights(@s, m, lm);
    let (from, to) = tag_sectors(lm, tag);
    let mut movers = clone_movers(s.movers);
    let mut started = false;
    let mut k = from;
    while k != to {
        let id = tag_sector(lm, k);
        let slot = *(*lm.floor_slot).at(id);
        if mover_index(@s, id).is_none() && slot != super::level::NO_SLOT {
            started = true;
            let here = floor_of(@view, id);
            movers
                .append(
                    Mover {
                        kind: MoverKind::FloorLowerToLowest,
                        phase: Phase::Down,
                        sector: id,
                        slot,
                        height: here,
                        top: here,
                        bottom: find_lowest_floor_surrounding(@view, lm, id),
                        speed: Fixed { enc: fixed::BIAS + super::thinkers::FLOORSPEED },
                        wait: 0,
                        count: 0,
                    },
                );
        }
        k += 1;
    }
    s.movers = movers.span();
    (s, started)
}

/// `EV_VerticalDoor(line, thing)` (p_doors.c): the manual doors, which take
/// the line's **back** sector and ignore its tag.
///
/// Re-triggering a door that is already running is the interesting half: a
/// door on its way **down reverses and goes back up**, whatever touched it;
/// a door that is open or opening starts closing, but **only for a player**
/// ("JDC: bad guys never close doors").
fn ev_vertical_door(
    state: SpecialsState,
    m: @LevelMap,
    lm: @SpecialsMap,
    line: u32,
    special: u32,
    actor: Actor,
    ref events: Array<Event>,
) -> SpecialsState {
    let mut s = state;
    if special == 26 {
        // Blue lock. `if (!p) return;` then the key test.
        if !actor.is_player {
            return s;
        }
        if !actor.blue_key {
            events.append(cue(event::LOCKED, line));
            return s;
        }
    }
    let (_, back) = doom_map::linedef_sectors(m, line);
    if back == NO_SECTOR {
        return s;
    }
    let slot = *(*lm.ceil_slot).at(back);
    if slot == super::level::NO_SLOT {
        return s;
    }
    let blazing = special == 117;

    match mover_index(@s, back) {
        Option::Some(index) => {
            let mut mv = *(s.movers).at(index);
            if mv.phase == Phase::Down {
                mv.phase = Phase::Up;
                events
                    .append(cue(if blazing {
                        event::BLAZE_OPEN
                    } else {
                        event::DOOR_OPEN
                    }, back));
            } else {
                if !actor.is_player {
                    return s;
                }
                mv.phase = Phase::Down;
                events
                    .append(
                        cue(if blazing {
                            event::BLAZE_CLOSE
                        } else {
                            event::DOOR_CLOSE
                        }, back),
                    );
            }
            s.movers = set_mover(s.movers, index, mv);
            return s;
        },
        Option::None => {},
    }

    let view = heights(@s, m, lm);
    events.append(cue(if blazing {
        event::BLAZE_OPEN
    } else {
        event::DOOR_OPEN
    }, back));
    let top = fixed::sub(
        find_lowest_ceiling_surrounding(@view, lm, back),
        Fixed { enc: fixed::BIAS + super::thinkers::DOOR_HEADROOM },
    );
    let mut movers = clone_movers(s.movers);
    movers
        .append(
            Mover {
                kind: if blazing {
                    MoverKind::DoorBlazeRaise
                } else {
                    MoverKind::DoorNormal
                },
                phase: Phase::Up,
                sector: back,
                slot,
                height: ceiling_of(@view, back),
                top,
                bottom: floor_of(@view, back),
                speed: Fixed {
                    enc: fixed::BIAS
                        + if blazing {
                            super::thinkers::BLAZESPEED
                        } else {
                            VDOORSPEED
                        },
                },
                wait: VDOORWAIT,
                count: 0,
            },
        );
    s.movers = movers.span();
    s
}

// ---------------------------------------------------------------------------
// The three entry points
// ---------------------------------------------------------------------------

/// What `doom_game` knows about whoever touched the line — the whole of
/// `mobj_t*` that `P_UseSpecialLine` and `P_CrossSpecialLine` actually read.
#[derive(Copy, Drop, Serde, PartialEq, Debug)]
pub struct Actor {
    /// `thing->player != NULL`.
    pub is_player: bool,
    /// `player->cards[it_bluecard] || player->cards[it_blueskull]`.
    pub blue_key: bool,
}

/// A player, an unarmed monster: the two actors the tests and `doom_game`
/// build most often.
pub fn player(blue_key: bool) -> Actor {
    Actor { is_player: true, blue_key }
}

pub fn monster() -> Actor {
    Actor { is_player: false, blue_key: false }
}

/// `P_UseSpecialLine(thing, line, side)` (p_spec.c): the "use" button.
///
/// `doom_physics` runs `P_UseLines`' `USERANGE` trace and hands over the
/// line it stopped at; this decides what that line does. The `bool` is
/// Doom's return value — `true` when the line was a usable special, which is
/// what makes `P_UseLines` stop tracing.
pub fn use_line(
    state: SpecialsState, m: @LevelMap, lm: @SpecialsMap, line: u32, side: u8, actor: Actor,
) -> (SpecialsState, Span<Event>, bool) {
    let mut s = state;
    let mut events: Array<Event> = array![];
    // "Use the back sides of VERY SPECIAL lines": type 124 only, which E1M1
    // does not carry.
    if side != 0 {
        return (s, events.span(), false);
    }
    let (special, tag) = super::state::line_special(@s, m, line);
    if !actor.is_player {
        // A monster never opens a secret door, and of this map's specials
        // only the plain manual door (type 1) is monster-usable at all.
        if (doom_map::linedef_flags(m, line) / ML_SECRET) % 2 == 1 {
            return (s, events.span(), false);
        }
        if special != 1 {
            return (s, events.span(), false);
        }
    }
    if special == 1 || special == 26 || special == 117 {
        s = ev_vertical_door(s, m, lm, line, special, actor, ref events);
        return (s, events.span(), true);
    }
    if special == 11 {
        // Exit level. `P_ChangeSwitchTexture(line, 0)` then `G_ExitLevel()`.
        s = change_switch_texture(s, line, false, ref events);
        s.exit = true;
        events.append(cue(event::EXIT, line));
        return (s, events.span(), true);
    }
    if special == 23 {
        let (next, started) = ev_do_floor(s, m, lm, tag, ref events);
        s = next;
        if started {
            s = change_switch_texture(s, line, false, ref events);
        }
        return (s, events.span(), true);
    }
    if special == 62 {
        let (next, started) = ev_do_plat(s, m, lm, tag, ref events);
        s = next;
        if started {
            s = change_switch_texture(s, line, true, ref events);
        }
        return (s, events.span(), true);
    }
    (s, events.span(), false)
}

/// `P_CrossSpecialLine(linenum, side, thing)` (p_spec.c): a walk trigger.
///
/// `side` is kept for the signature's sake — none of E1M1's walk triggers
/// is side-dependent — and the monster filter is Doom's: of the specials
/// this map carries, only the repeatable lift (88) is on the list of
/// triggers "that other things can activate".
pub fn cross_line(
    state: SpecialsState, m: @LevelMap, lm: @SpecialsMap, line: u32, side: u8, actor: Actor,
) -> (SpecialsState, Span<Event>) {
    let mut s = state;
    let mut events: Array<Event> = array![];
    let (special, tag) = super::state::line_special(@s, m, line);
    if !actor.is_player && special != 88 {
        return (s, events.span());
    }
    if special == 2 {
        // W1 "open and stay". Vanilla clears `line->special` whether or not
        // a sector actually moved.
        let (next, _) = ev_do_door(s, m, lm, tag, MoverKind::DoorOpen, ref events);
        s = next;
        let mut used: Array<u32> = array![];
        let old = s.used;
        let mut i: u32 = 0;
        while i != old.len() {
            used.append(*old.at(i));
            i += 1;
        }
        used.append(line);
        s.used = used.span();
        return (s, events.span());
    }
    if special == 88 {
        let (next, _) = ev_do_plat(s, m, lm, tag, ref events);
        return (next, events.span());
    }
    (s, events.span())
}

// ---------------------------------------------------------------------------
// P_PlayerInSpecialSector
// ---------------------------------------------------------------------------

/// The part of `player_t` that `P_PlayerInSpecialSector` reads.
#[derive(Copy, Drop, Serde, PartialEq, Debug)]
pub struct PlayerSector {
    /// `player->mo->subsector->sector`.
    pub sector: u32,
    /// `player->mo->z == sector->floorheight` — "has hitten ground".
    pub on_floor: bool,
    /// `player->powers[pw_ironfeet]`, the radiation suit.
    pub radiation_suit: bool,
}

/// What one tic in a special sector does to the player.
#[derive(Copy, Drop, Serde, PartialEq, Debug)]
pub struct SectorEffect {
    /// Health to subtract this tic (`P_DamageMobj(player->mo, ..., 5)`).
    pub damage: u32,
    /// A secret was counted this tic.
    pub secret: bool,
}

/// The damage half of `P_PlayerInSpecialSector`, without the state change:
/// sector special 7 ("NUKAGE DAMAGE") takes 5 health every 32 tics
/// (`if (!(leveltime & 0x1f))`) from a player standing on the floor without
/// a radiation suit. E1M1 carries no other damaging special.
pub fn sector_damage(
    s: @SpecialsState, m: @LevelMap, lm: @SpecialsMap, p: PlayerSector, tic: u32,
) -> u32 {
    if !p.on_floor {
        return 0;
    }
    if sector_special(s, m, lm, p.sector) != 7 {
        return 0;
    }
    if p.radiation_suit {
        return 0;
    }
    if tic % 32 != 0 {
        return 0;
    }
    5
}

/// `P_PlayerInSpecialSector(player)` (p_spec.c).
///
/// Secret sectors (special 9) count **once**: the tally goes up and
/// `sector->special` is cleared, so standing in the same sector again does
/// nothing.
pub fn player_in_special_sector(
    state: SpecialsState, m: @LevelMap, lm: @SpecialsMap, p: PlayerSector, tic: u32,
) -> (SpecialsState, SectorEffect, Span<Event>) {
    let mut s = state;
    let mut events: Array<Event> = array![];
    let mut effect = SectorEffect { damage: 0, secret: false };
    if !p.on_floor {
        return (s, effect, events.span());
    }
    let special = sector_special(@s, m, lm, p.sector);
    if special == 7 {
        effect.damage = sector_damage(@s, m, lm, p, tic);
    } else if special == 9 {
        s.secrets += 1;
        effect.secret = true;
        let slot = *(*lm.special_slot).at(p.sector);
        s.specials = set_u32(s.specials, slot, 0);
        events.append(cue(event::SECRET, p.sector));
    }
    (s, effect, events.span())
}

/// `next_light_tic` re-exported for the invariant test and for `doom_game`,
/// which rebuilds the cache when it loads a state from outside.
pub fn light_cache(state: @SpecialsState) -> u32 {
    next_light_tic(*state.lights)
}
