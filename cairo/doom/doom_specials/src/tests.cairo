// SPDX-License-Identifier: GPL-2.0-only
//! `doom_specials` against an independent model.
//!
//! Reference values come from `scripts/reference.py`, a Python
//! transcription of linuxdoom-1.10's `p_spec.c` / `p_doors.c` /
//! `p_plats.c` / `p_floor.c` / `p_lights.c` that reads the same E1M1
//! constants and shares no code with the Cairo side; it writes
//! `src/tests/vectors.cairo`. On top of those there are properties (heights
//! monotone between endpoints, no thinker leaks, once vs repeatable) and
//! the edge cases the task statement calls out (a door re-triggered while
//! closing reverses, a lift re-triggered while waiting is ignored, the exit
//! switch ends the level on the spot).

mod vectors;
use doom_map::{LevelId, LevelMap};
use doom_things::rndtable;
use fixed::Fixed;
use prng::{Prng, from_index};
use super::level::{SpecialsMap, tag_sector, tag_sectors};
use super::state::{Phase, SpecialsState, set_felt};
use super::thinkers::{NeverBlocked, SectorBlocking, event};
use super::triggers::PlayerSector;
use super::{
    ceiling_of, cross_line, fields, find_highest_floor_surrounding, find_lowest_ceiling_surrounding,
    find_lowest_floor_surrounding, floor_of, has_mover, hash, heights_of, line_special, monster,
    next_light_tic, player, player_in_special_sector, sector_damage, sector_light, sector_special,
    sector_tables, serialize, spawn_specials, specials_ticker, use_line,
};

/// A world where every mobj is too tall for a ceiling below `limit` — the
/// stand-in for someone standing in a doorway, so that the closing door's
/// `P_ChangeSector` reversal can be tested without `doom_physics`.
#[derive(Copy, Drop)]
struct BlockBelow {
    limit: Fixed,
}

impl BlockBelowBlocking of SectorBlocking<BlockBelow> {
    fn nofit(self: @BlockBelow, sector: u32, floor: Fixed, ceiling: Fixed) -> bool {
        fixed::lt(ceiling, *self.limit)
    }
}

fn setup() -> (LevelMap, SpecialsMap, SpecialsState, Prng) {
    let m = doom_map::load(LevelId::E1M1);
    let lm = super::load(LevelId::E1M1);
    // D24: both RNG streams start at `from_index(1)` to reproduce Doom's
    // draw order.
    let (state, rng) = spawn_specials(@m, @lm, from_index(1), rndtable());
    (m, lm, state, rng)
}

fn run_tics(
    state: SpecialsState, m: @LevelMap, lm: @SpecialsMap, from: u32, count: u32, rng: Prng,
) -> (SpecialsState, Prng) {
    let world = NeverBlocked {};
    let tables = sector_tables(m, lm);
    let mut s = state;
    let mut prng = rng;
    let mut tic = from;
    while tic != from + count {
        let (next, next_rng, _) = specials_ticker(@world, s, tables, tic, prng, rndtable());
        s = next;
        prng = next_rng;
        tic += 1;
    }
    (s, prng)
}

// ---------------------------------------------------------------------------
// Reference values
// ---------------------------------------------------------------------------

#[test]
fn test_spawn_lights_match_the_python_model() {
    let (_, _, s, _) = setup();
    assert(s.lights.len() == vectors::NUM_LIGHTS, 'nine light thinkers');
    let expected = vectors::SPAWN_LIGHTS.span();
    let mut i: u32 = 0;
    while i != vectors::NUM_LIGHTS {
        let l = *s.lights.at(i);
        let base = i * 8;
        assert(l.sector == *expected.at(base), 'light sector');
        let kind: u32 = match l.kind {
            super::LightKind::Flash => 0,
            super::LightKind::Strobe => 1,
        };
        assert(kind == *expected.at(base + 1), 'light kind');
        assert(l.light == *expected.at(base + 2), 'light level');
        assert(l.maxlight == *expected.at(base + 3), 'light maxlight');
        assert(l.minlight == *expected.at(base + 4), 'light minlight');
        assert(l.hi_time == *expected.at(base + 5), 'light hi_time');
        assert(l.lo_time == *expected.at(base + 6), 'light lo_time');
        assert(l.next == *expected.at(base + 7), 'light next');
        i += 1;
    }
}

#[test]
fn test_spawn_consumes_one_draw_per_flashing_light() {
    let (_, _, _, rng) = setup();
    // `P_SpawnLightFlash` draws once; `P_SpawnStrobeFlash(.., inSync = 1)`
    // does not. E1M1 has three flashing sectors, so the cursor moves 1 -> 4.
    assert(rng.index == vectors::SPAWN_RNG, 'three P_Random draws');
}

#[test]
fn test_spawn_clears_the_light_sectors_special_only() {
    let (m, lm, s, _) = setup();
    let mut i: u32 = 0;
    while i != vectors::NUM_LIGHTS {
        let l = *s.lights.at(i);
        assert(sector_special(@s, @m, @lm, l.sector) == 0, 'light special cleared');
        i += 1;
    }
    // The four secret sectors and the three damaging ones keep theirs.
    assert(sector_special(@s, @m, @lm, 52) == 9, 'secret kept');
    assert(sector_special(@s, @m, @lm, 23) == 7, 'damage kept');
}

#[test]
fn test_manual_door_topheights_match_the_python_model() {
    let (m, lm, s, _) = setup();
    let view = heights_of(@s, @m, @lm);
    let rows = vectors::MANUAL_DOORS.span();
    let mut i: u32 = 0;
    while i != vectors::NUM_MANUAL_DOORS {
        let base = i * 4;
        let line: u32 = (*rows.at(base)).try_into().unwrap();
        let sector: u32 = (*rows.at(base + 1)).try_into().unwrap();
        let (_, back) = doom_map::linedef_sectors(@m, line);
        assert(back == sector, 'door back sector');
        assert(ceiling_of(@view, sector).enc == *rows.at(base + 2), 'door ceiling at spawn');
        let top = fixed::sub(
            find_lowest_ceiling_surrounding(@view, @lm, sector),
            Fixed { enc: fixed::BIAS + super::thinkers::DOOR_HEADROOM },
        );
        assert(top.enc == *rows.at(base + 3), 'door topheight');
        i += 1;
    }
}

#[test]
fn test_tagged_specials_reach_the_expected_sectors() {
    let (m, lm, _, _) = setup();
    let rows = vectors::TAGGED.span();
    let mut i: u32 = 0;
    while i != vectors::NUM_TAGGED {
        let base = i * 4;
        let line = *rows.at(base);
        let special = *rows.at(base + 1);
        let tag = *rows.at(base + 2);
        let sector = *rows.at(base + 3);
        let (got_special, got_tag) = doom_map::linedef_special(@m, line);
        assert(got_special == special, 'tagged line special');
        assert(got_tag == tag, 'tagged line tag');
        let (from, to) = tag_sectors(@lm, tag);
        let mut k = from;
        let mut found = false;
        while k != to {
            if tag_sector(@lm, k) == sector {
                found = true;
                break;
            }
            k += 1;
        }
        assert(found, 'tag reaches the sector');
        i += 1;
    }
}

#[test]
fn test_light_timeline_matches_vanilla() {
    let (m, lm, state, rng) = setup();
    let world = NeverBlocked {};
    let tables = sector_tables(@m, @lm);
    let expected = vectors::LIGHT_TIMELINE.span();
    let mut s = state;
    let mut prng = rng;
    let mut tic: u32 = 0;
    let mut sample: u32 = 0;
    while tic != vectors::LIGHT_SAMPLES * 10 {
        let (next, next_rng, _) = specials_ticker(@world, s, tables, tic, prng, rndtable());
        s = next;
        prng = next_rng;
        if tic % 10 == 0 {
            let mut k: u32 = 0;
            while k != vectors::NUM_LIGHTS {
                let l = *s.lights.at(k);
                assert(
                    sector_light(@s, @m, @lm, l.sector) == *expected.at(sample * 9 + k),
                    'light timeline',
                );
                k += 1;
            }
            sample += 1;
        }
        tic += 1;
    }
}

#[test]
fn test_scripted_seven_hundred_tic_run() {
    let (m, lm, state, rng) = setup();
    let world = NeverBlocked {};
    let tables = sector_tables(@m, @lm);
    let mut s = state;
    let mut prng = rng;
    let door_sector = vectors::SEQ_DOOR_SECTOR;
    let lift_sector = vectors::SEQ_LIFT_SECTOR;
    let samples = vectors::SEQ_SAMPLES.span();
    let mut checksum: felt252 = 0;
    let mut sample: u32 = 0;
    let mut door_open_tic: u32 = 0xFFFFFFFF;
    let mut door_close_tic: u32 = 0xFFFFFFFF;
    let mut door_done_tic: u32 = 0xFFFFFFFF;
    let mut lift_bottom_tic: u32 = 0xFFFFFFFF;
    let mut lift_up_tic: u32 = 0xFFFFFFFF;
    let mut lift_done_tic: u32 = 0xFFFFFFFF;
    let mut tic: u32 = 0;
    while tic != vectors::SEQ_TICS {
        if tic == 10 {
            let (next, _, _) = use_line(s, @m, @lm, vectors::SEQ_DOOR_LINE, 0, player(false));
            s = next;
        }
        if tic == 200 {
            let (next, _, _) = use_line(s, @m, @lm, vectors::SEQ_LIFT_LINE, 0, player(false));
            s = next;
        }
        if tic == 400 {
            let (next, _) = cross_line(s, @m, @lm, vectors::SEQ_WALK_LIFT_LINE, 0, player(false));
            s = next;
        }
        let before_door = phase_of(@s, door_sector);
        let before_lift = phase_of(@s, lift_sector);
        let (next, next_rng, _) = specials_ticker(@world, s, tables, tic, prng, rndtable());
        s = next;
        prng = next_rng;
        let after_door = phase_of(@s, door_sector);
        let after_lift = phase_of(@s, lift_sector);
        if before_door == 1 && after_door == 2 && door_open_tic == 0xFFFFFFFF {
            door_open_tic = tic;
        }
        if before_door == 2 && after_door == 3 && door_close_tic == 0xFFFFFFFF {
            door_close_tic = tic;
        }
        if before_door != 0 && after_door == 0 && door_done_tic == 0xFFFFFFFF {
            door_done_tic = tic;
        }
        if before_lift == 3 && after_lift == 2 && lift_bottom_tic == 0xFFFFFFFF {
            lift_bottom_tic = tic;
        }
        if before_lift == 2 && after_lift == 1 && lift_up_tic == 0xFFFFFFFF {
            lift_up_tic = tic;
        }
        if before_lift != 0 && after_lift == 0 && lift_done_tic == 0xFFFFFFFF {
            lift_done_tic = tic;
        }

        let view = heights_of(@s, @m, @lm);
        let ceiling = ceiling_of(@view, door_sector).enc;
        let floor = floor_of(@view, lift_sector).enc;
        let mut lights: felt252 = 0;
        let mut k: u32 = 0;
        while k != vectors::NUM_LIGHTS {
            let l = *s.lights.at(k);
            lights += l.light.into();
            k += 1;
        }
        let folded = ceiling + 5 * floor + 11 * lights;
        checksum += (tic.into() + 1) * folded;
        if tic % vectors::SEQ_SAMPLE_EVERY == 0 {
            let base = sample * 4;
            assert(*samples.at(base) == tic.into(), 'sample tic');
            assert(*samples.at(base + 1) == ceiling, 'sample ceiling');
            assert(*samples.at(base + 2) == floor, 'sample floor');
            assert(*samples.at(base + 3) == lights, 'sample lights');
            sample += 1;
        }
        tic += 1;
    }
    assert(sample == vectors::NUM_SEQ_SAMPLES, 'every sample checked');
    assert(checksum == vectors::SEQ_CHECKSUM, 'scripted run checksum');
    assert(door_open_tic == vectors::SEQ_DOOR_OPEN_TIC, 'door open tic');
    assert(door_close_tic == vectors::SEQ_DOOR_CLOSE_TIC, 'door close tic');
    assert(door_done_tic == vectors::SEQ_DOOR_DONE_TIC, 'door done tic');
    assert(lift_bottom_tic == vectors::SEQ_LIFT_BOTTOM_TIC, 'lift bottom tic');
    assert(lift_up_tic == vectors::SEQ_LIFT_UP_TIC, 'lift up tic');
    assert(lift_done_tic == vectors::SEQ_LIFT_DONE_TIC, 'lift done tic');
}

/// 0 = no thinker, 1 = up, 2 = waiting, 3 = down.
fn phase_of(s: @SpecialsState, sector: u32) -> u32 {
    let movers = *s.movers;
    let mut i: u32 = 0;
    let mut out: u32 = 0;
    while i != movers.len() {
        let mv = *movers.at(i);
        if mv.sector == sector {
            out = match mv.phase {
                Phase::Up => 1,
                Phase::Waiting => 2,
                Phase::Down => 3,
            };
            break;
        }
        i += 1;
    }
    out
}

// ---------------------------------------------------------------------------
// Properties
// ---------------------------------------------------------------------------

#[test]
fn test_door_height_is_monotone_between_its_endpoints() {
    let (m, lm, state, rng) = setup();
    let world = NeverBlocked {};
    let tables = sector_tables(@m, @lm);
    let (mut s, _, _) = use_line(state, @m, @lm, 55, 0, player(false));
    let sector = 10;
    let start = ceiling_of(@heights_of(@s, @m, @lm), sector);
    let top = *(s.movers.at(0)).top;
    let mut prng = rng;
    let mut previous = start;
    let mut tic: u32 = 0;
    // Up to the moment it starts closing again.
    while tic != 200 {
        let (next, next_rng, _) = specials_ticker(@world, s, tables, tic, prng, rndtable());
        s = next;
        prng = next_rng;
        let now = ceiling_of(@heights_of(@s, @m, @lm), sector);
        assert(fixed::ge(now, previous), 'ceiling never dips');
        assert(fixed::ge(top, now), 'ceiling never overshoots');
        assert(fixed::ge(now, start), 'ceiling never goes below');
        previous = now;
        tic += 1;
    }
    assert(previous.enc == top.enc, 'door reached topheight');
}

#[test]
fn test_no_thinker_leaks_and_the_height_is_latched() {
    let (m, lm, state, rng) = setup();
    let (s0, _, _) = use_line(state, @m, @lm, 55, 0, player(false));
    let closed = ceiling_of(@heights_of(@s0, @m, @lm), 10);
    let (s1, _) = run_tics(s0, @m, @lm, 0, 400, rng);
    assert(s1.movers.len() == 0, 'no thinker left running');
    assert(!has_mover(@s1, 10), 'sector free again');
    // A `normal` door ends exactly where it started, and the latched value
    // in the slot array is that height, not `doom_map`'s stale copy.
    assert(ceiling_of(@heights_of(@s1, @m, @lm), 10).enc == closed.enc, 'door back to its floor');
    assert(
        fixed::lt(ceiling_of(@heights_of(@s1, @m, @lm), 10), *(s0.movers.at(0)).top), 'and closed',
    );
}

#[test]
fn test_walk_trigger_fires_once_and_switch_lift_repeats() {
    let (m, lm, state, rng) = setup();
    // Linedef 528 is W1 "door open and stay" (tag 5 -> sector 77).
    let (s0, _) = cross_line(state, @m, @lm, 528, 0, player(false));
    assert(s0.movers.len() == 1, 'first cross opens the door');
    let (special, _) = line_special(@s0, @m, 528);
    assert(special == 0, 'W1 line is spent');
    let (s1, _) = run_tics(s0, @m, @lm, 0, 400, rng);
    assert(s1.movers.len() == 0, 'door open and stay is done');
    let (s2, _) = cross_line(s1, @m, @lm, 528, 0, player(false));
    assert(s2.movers.len() == 0, 'a W1 line never fires twice');

    // Linedef 594 is SR "lift down-wait-up-stay" (tag 1 -> sector 98).
    let (s3, _, used) = use_line(s2, @m, @lm, 594, 0, player(false));
    assert(used, 'switch is usable');
    assert(s3.movers.len() == 1, 'lift starts');
    let (s4, _) = run_tics(s3, @m, @lm, 0, 400, rng);
    assert(s4.movers.len() == 0, 'lift finished');
    let (s5, _, _) = use_line(s4, @m, @lm, 594, 0, player(false));
    assert(s5.movers.len() == 1, 'SR lift fires again');
}

#[test]
fn test_once_only_switches_retire_their_linedef() {
    let (m, lm, state, _) = setup();
    // 23 is S1 "floor lower to lowest" (tag 3 -> three sectors).
    let (s0, _, _) = use_line(state, @m, @lm, 753, 0, player(false));
    assert(s0.movers.len() == 3, 'three tagged floors move');
    let (special, _) = line_special(@s0, @m, 753);
    assert(special == 0, 'S1 switch is spent');
    assert(s0.used.len() == 1, 'one retired linedef');
}

#[test]
fn test_serialization_is_self_describing_and_provable() {
    let (m, lm, state, rng) = setup();
    let (s0, _, _) = use_line(state, @m, @lm, 55, 0, player(false));
    let (s1, _) = run_tics(s0, @m, @lm, 0, 30, rng);
    let felts = serialize(@s1);
    // `open` writes three header felts, `fields` promises the rest.
    assert(felts.len() == fields(@s1) + 3, 'declared length is honest');
    let span = felts.span();
    let mut i: u32 = 0;
    while i != span.len() {
        let v: u128 = (*span.at(i)).try_into().unwrap();
        assert(v < 0x1000000000000000000_u128, 'every felt below 2^72');
        i += 1;
    }
    assert(hash(@s1) != hash(@state), 'hash follows the state');
    assert(hash(@s1) == hash(@s1), 'hash is deterministic');
}

#[test]
fn test_next_light_cache_matches_the_thinkers() {
    let (m, lm, state, rng) = setup();
    assert(state.next_light == next_light_tic(state.lights), 'cache holds at spawn');
    let mut s = state;
    let mut prng = rng;
    let world = NeverBlocked {};
    let tables = sector_tables(@m, @lm);
    let mut tic: u32 = 0;
    while tic != 120 {
        let (next, next_rng, _) = specials_ticker(@world, s, tables, tic, prng, rndtable());
        s = next;
        prng = next_rng;
        assert(s.next_light == next_light_tic(s.lights), 'cache holds every tic');
        tic += 1;
    }
}

#[test]
fn test_ticker_leaves_a_quiet_state_untouched() {
    let (m, lm, state, rng) = setup();
    // Past the last scheduled light flip of the first 2 000 tics there is
    // nothing to run at all; the state must come back identical.
    let (quiet, prng) = run_tics(state, @m, @lm, 0, 40, rng);
    let before = hash(@quiet);
    let world = NeverBlocked {};
    let tic = quiet.next_light - 1;
    let (after, _, events) = specials_ticker(
        @world, quiet, sector_tables(@m, @lm), tic, prng, rndtable(),
    );
    assert(hash(@after) == before, 'nothing changed');
    assert(events.len() == 0, 'no cues');
}

// ---------------------------------------------------------------------------
// Edge cases
// ---------------------------------------------------------------------------

#[test]
fn test_door_retriggered_while_closing_reverses() {
    let (m, lm, state, rng) = setup();
    let (s0, _, _) = use_line(state, @m, @lm, 55, 0, player(false));
    // Open, wait out `VDOORWAIT`, and catch it on the way down.
    let (s1, prng) = run_tics(s0, @m, @lm, 0, 240, rng);
    assert(phase_of(@s1, 10) == 3, 'door is closing');
    let falling = ceiling_of(@heights_of(@s1, @m, @lm), 10);
    let (s2, events, _) = use_line(s1, @m, @lm, 55, 0, player(false));
    assert(phase_of(@s2, 10) == 1, 'door reversed to opening');
    assert(*(events.at(0)).kind == event::DOOR_OPEN, 'it announces reopening');
    let (s3, _) = run_tics(s2, @m, @lm, 240, 5, prng);
    assert(fixed::gt(ceiling_of(@heights_of(@s3, @m, @lm), 10), falling), 'and it climbs again');
}

#[test]
fn test_door_retriggered_while_open_closes_for_a_player_only() {
    let (m, lm, state, rng) = setup();
    let (s0, _, _) = use_line(state, @m, @lm, 55, 0, player(false));
    let (s1, _) = run_tics(s0, @m, @lm, 0, 100, rng);
    assert(phase_of(@s1, 10) == 2, 'door is waiting open');
    // "JDC: bad guys never close doors".
    let (s2, _, _) = use_line(s1, @m, @lm, 55, 0, monster());
    assert(phase_of(@s2, 10) == 2, 'a monster leaves it open');
    let (s3, _, _) = use_line(s2, @m, @lm, 55, 0, player(false));
    assert(phase_of(@s3, 10) == 3, 'a player closes it early');
}

#[test]
fn test_plat_retriggered_while_waiting_is_ignored() {
    let (m, lm, state, rng) = setup();
    let (s0, _, _) = use_line(state, @m, @lm, 594, 0, player(false));
    let (s1, _) = run_tics(s0, @m, @lm, 0, 60, rng);
    assert(phase_of(@s1, 98) == 2, 'lift waits at the bottom');
    let waiting = *(s1.movers.at(0)).count;
    // `EV_DoPlat` skips a sector that already has `specialdata`.
    let (s2, _, _) = use_line(s1, @m, @lm, 594, 0, player(false));
    assert(s2.movers.len() == 1, 'still exactly one thinker');
    assert(*(s2.movers.at(0)).count == waiting, 'countdown untouched');
    let (s3, _) = cross_line(s2, @m, @lm, 593, 0, player(false));
    assert(s3.movers.len() == 1, 'a walk retrigger is ignored too');
}

#[test]
fn test_locked_door_needs_the_blue_key() {
    let (m, lm, state, _) = setup();
    // Linedef 421 is DR "blue key door" (back sector 71).
    let (s0, events, ok) = use_line(state, @m, @lm, 421, 0, player(false));
    assert(ok, 'the line was usable');
    assert(s0.movers.len() == 0, 'no key, no door');
    assert(*(events.at(0)).kind == event::LOCKED, 'it says so');
    let (s1, _, _) = use_line(state, @m, @lm, 421, 0, player(true));
    assert(s1.movers.len() == 1, 'with the key it opens');
    assert(*(s1.movers.at(0)).sector == 71, 'the back sector moves');
    // A monster gets nothing, key or not.
    let (s2, _, _) = use_line(state, @m, @lm, 421, 0, monster());
    assert(s2.movers.len() == 0, 'monsters cannot use it');
}

#[test]
fn test_secret_is_counted_once() {
    let (m, lm, state, _) = setup();
    let inside = PlayerSector { sector: 52, on_floor: true, radiation_suit: false };
    let (s0, effect, events) = player_in_special_sector(state, @m, @lm, inside, 7);
    assert(effect.secret, 'secret found');
    assert(s0.secrets == 1, 'tally went up');
    assert(*(events.at(0)).kind == event::SECRET, 'cue emitted');
    assert(sector_special(@s0, @m, @lm, 52) == 0, 'special cleared');
    let (s1, again, _) = player_in_special_sector(s0, @m, @lm, inside, 8);
    assert(!again.secret, 'not counted twice');
    assert(s1.secrets == 1, 'tally unchanged');
    // In the air, nothing happens at all.
    let airborne = PlayerSector { sector: 86, on_floor: false, radiation_suit: false };
    let (s2, nothing, _) = player_in_special_sector(s1, @m, @lm, airborne, 9);
    assert(!nothing.secret, 'must be on the floor');
    assert(s2.secrets == 1, 'tally still unchanged');
}

#[test]
fn test_damaging_sector_takes_five_every_thirty_two_tics() {
    let (m, lm, state, _) = setup();
    let here = PlayerSector { sector: 23, on_floor: true, radiation_suit: false };
    assert(sector_damage(@state, @m, @lm, here, 64) == 5, 'hurts on a multiple of 32');
    assert(sector_damage(@state, @m, @lm, here, 65) == 0, 'and not in between');
    let suited = PlayerSector { sector: 23, on_floor: true, radiation_suit: true };
    assert(sector_damage(@state, @m, @lm, suited, 64) == 0, 'the suit protects');
    let airborne = PlayerSector { sector: 23, on_floor: false, radiation_suit: false };
    assert(sector_damage(@state, @m, @lm, airborne, 64) == 0, 'must have landed');
    let harmless = PlayerSector { sector: 0, on_floor: true, radiation_suit: false };
    assert(sector_damage(@state, @m, @lm, harmless, 64) == 0, 'ordinary sector');
    let (s, effect, _) = player_in_special_sector(state, @m, @lm, here, 64);
    assert(effect.damage == 5, 'the full call agrees');
    assert(s.secrets == 0, 'and counts no secret');
}

#[test]
fn test_exit_switch_ends_the_level_immediately() {
    let (m, lm, state, _) = setup();
    assert(!state.exit, 'not exiting yet');
    let (s0, events, ok) = use_line(state, @m, @lm, 407, 0, player(false));
    assert(ok, 'the exit switch is usable');
    assert(s0.exit, 'status EXIT on the spot');
    assert(events.len() == 2, 'switch cue and exit cue');
    assert(*(events.at(0)).kind == event::SWITCH, 'texture flips');
    assert(*(events.at(1)).kind == event::EXIT, 'level ends');
    let (special, _) = line_special(@s0, @m, 407);
    assert(special == 0, 'S1 exit is spent');
}

#[test]
fn test_monster_filters() {
    let (m, lm, state, _) = setup();
    // A monster may open a plain DR door...
    let (s0, _, ok) = use_line(state, @m, @lm, 55, 0, monster());
    assert(ok, 'usable by a monster');
    assert(s0.movers.len() == 1, 'and it opens');
    // ...but not a switch.
    let (s1, _, ok2) = use_line(state, @m, @lm, 594, 0, monster());
    assert(!ok2, 'switches are not for monsters');
    assert(s1.movers.len() == 0, 'nothing started');
    // Walk triggers: only the repeatable lift is on Doom's list.
    let (s2, _) = cross_line(state, @m, @lm, 528, 0, monster());
    assert(s2.movers.len() == 0, 'W1 door ignores monsters');
    let (s3, _) = cross_line(state, @m, @lm, 593, 0, monster());
    assert(s3.movers.len() == 1, 'WR lift accepts them');
}

#[test]
fn test_using_a_line_from_its_back_side_does_nothing() {
    let (m, lm, state, _) = setup();
    let (s, events, ok) = use_line(state, @m, @lm, 55, 1, player(false));
    assert(!ok, 'back side is not usable');
    assert(s.movers.len() == 0, 'nothing started');
    assert(events.len() == 0, 'and nothing announced');
}

#[test]
fn test_a_line_without_a_special_does_nothing() {
    let (m, lm, state, _) = setup();
    let (s0, _, ok) = use_line(state, @m, @lm, 0, 0, player(false));
    assert(!ok, 'plain line');
    assert(s0.movers.len() == 0, 'nothing started');
    let (s1, _) = cross_line(state, @m, @lm, 0, 0, player(false));
    assert(s1.movers.len() == 0, 'crossing it does nothing either');
}

#[test]
fn test_blocked_door_reverses_and_a_blocked_lift_keeps_going() {
    let (m, lm, state, rng) = setup();
    let (s0, _, _) = use_line(state, @m, @lm, 55, 0, player(false));
    // Let it open and wait, then close into a world where anything below
    // the halfway mark does not fit.
    let (s1, prng) = run_tics(s0, @m, @lm, 0, 240, rng);
    assert(phase_of(@s1, 10) == 3, 'closing');
    let stuck = ceiling_of(@heights_of(@s1, @m, @lm), 10);
    let world = BlockBelow { limit: stuck };
    let tables = sector_tables(@m, @lm);
    let mut s = s1;
    let mut tic: u32 = 240;
    while tic != 244 {
        let (next, _, _) = specials_ticker(@world, s, tables, tic, prng, rndtable());
        s = next;
        tic += 1;
    }
    assert(phase_of(@s, 10) == 1, 'a blocked door goes back up');
    assert(fixed::ge(ceiling_of(@heights_of(@s, @m, @lm), 10), stuck), 'it never sank');
}

#[test]
fn test_floor_lower_to_lowest_reaches_the_lowest_neighbour() {
    let (m, lm, state, rng) = setup();
    let view = heights_of(@state, @m, @lm);
    let target = find_lowest_floor_surrounding(@view, @lm, 76);
    let (s0, _, _) = use_line(state, @m, @lm, 753, 0, player(false));
    let (s1, _) = run_tics(s0, @m, @lm, 0, 500, rng);
    assert(s1.movers.len() == 0, 'all three floors settled');
    assert(floor_of(@heights_of(@s1, @m, @lm), 76).enc == target.enc, 'lowered to the lowest');
}

#[test]
fn test_find_surrounding_queries_agree_with_the_map() {
    let (m, lm, state, _) = setup();
    let view = heights_of(@state, @m, @lm);
    // The lowest surrounding floor includes the sector itself...
    let lowest = find_lowest_floor_surrounding(@view, @lm, 98);
    assert(fixed::ge(floor_of(@view, 98), lowest), 'lowest is not above us');
    // ...the highest one does not, and the lowest ceiling is what a door
    // opens under.
    let highest = find_highest_floor_surrounding(@view, @lm, 98);
    assert(fixed::ge(highest, lowest), 'highest is not below lowest');
    let ceiling = find_lowest_ceiling_surrounding(@view, @lm, 10);
    assert(fixed::ge(ceiling, floor_of(@view, 10)), 'a ceiling is above a floor');
}

#[test]
fn test_static_sectors_read_straight_from_doom_map() {
    let (m, lm, state, _) = setup();
    let view = heights_of(@state, @m, @lm);
    // Sector 0 carries no special and no tag, so it has no slot at all.
    assert(floor_of(@view, 0).enc == doom_map::sector_floor(@m, 0).enc, 'static floor');
    assert(ceiling_of(@view, 0).enc == doom_map::sector_ceiling(@m, 0).enc, 'static ceiling');
    assert(sector_light(@state, @m, @lm, 0) == doom_map::sector(@m, 0).light, 'static light');
    assert(sector_special(@state, @m, @lm, 0) == 0, 'static special');
}

#[test]
fn test_blazing_door_is_four_times_faster() {
    let (m, lm, state, rng) = setup();
    // Linedef 1162 is the map's only DR blazing door (back sector 84).
    let (s0, events, _) = use_line(state, @m, @lm, 1162, 0, player(false));
    assert(*(events.at(0)).kind == event::BLAZE_OPEN, 'blazing cue');
    let kind = *(s0.movers.at(0)).kind;
    assert(
        super::speed_of(kind).enc == fixed::BIAS + super::thinkers::BLAZESPEED,
        'four times VDOORSPEED',
    );
    let start = ceiling_of(@heights_of(@s0, @m, @lm), 84);
    let (s1, _) = run_tics(s0, @m, @lm, 0, 1, rng);
    let after = ceiling_of(@heights_of(@s1, @m, @lm), 84);
    assert(fixed::sub(after, start).enc == fixed::BIAS + super::thinkers::BLAZESPEED, 'one tic');
}


#[test]
fn test_set_felt_preserves_prefix_and_suffix_at_every_position() {
    let mut values: Array<felt252> = array![];
    let mut n = 1;
    while n != 184 {
        values.append(n.into());
        // Exercise singleton, first, middle and last positions, including
        // the 182-sector array; expected values come from an indexed oracle.
        if n == 1 || n == 5 || n == 15 || n == 182 || n == 183 {
            let mut index = 0;
            while index != n {
                let actual = set_felt(values.span(), index, 999);
                assert(actual.len() == n, 'same length');
                let mut j = 0;
                while j != n {
                    let expected = if j == index {
                        999
                    } else {
                        (j + 1).into()
                    };
                    assert(*actual.at(j) == expected, 'only selected value changes');
                    j += 1;
                }
                index += 1;
            }
        }
        n += 1;
    }
}
