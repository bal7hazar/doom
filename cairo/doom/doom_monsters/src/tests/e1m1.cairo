// SPDX-License-Identifier: GPL-2.0-only
//! Reference tests on Freedoom E1M1, against the vectors of
//! `scripts/model.py` (`vectors.cairo`) plus the scripted scenarios.

use core::poseidon::poseidon_hash_span;
use doom_map::{LevelId, genesis, load, num_things, thing};
use doom_physics::{
    MF_AMBUSH, MF_COUNTKILL, MOBJ_FELTS, Mobj, NO_MOBJ, SpawnZ, ThingGrid, World, has, new_grid,
    push_felts, set_thing_position, spawn_map_thing, spawn_mobj, world_of,
};
use doom_things::tables::{
    A_CHASE, A_LOOK, KIND_PLAYER, KIND_POSSESSED, KIND_SERGEANT, KIND_TROOP, MI_MELEESTATE,
    MI_MISSILESTATE, MI_PAINSTATE, MI_SEESTATE, MI_SPAWNSTATE,
};
use fixed::Fixed;
use prng::{Prng, from_index};
use crate::actions::{a_look, check_melee_range, check_missile_range, new_chase_dir};
use crate::event::MonsterEvent;
use crate::think::monsters_ticker;
use crate::{Ctx, LOOK_CADENCE, Patch, silence};
use super::vectors::{
    CHAINS, CHASE, CHASEDIRS, CHASE_EVERY, CHASE_SETUP, CHASE_TICS, LOOKS, MELEES, MISSILE_RANGES,
};

/// The checksum of the 700-tic E1M1 scenario below: a Poseidon hash of every
/// mobj's 27 serialized felts plus the RNG cursor, at every 50th tic. It is a
/// **regression pin**, not an independent expectation — the semantics are
/// pinned by the reference vectors above, and this catches a silent change of
/// behaviour anywhere in the loop. Regenerate it on purpose only (PLAN.md
/// §3.1 rule 5): the test prints the value it computed.
const SCENARIO_CHECKSUM: felt252 =
    0x6e3b89227ce072ce90807cd3477c1702e0e21b22fba18c801340a32480a1d2e;

/// Skill-2 monsters on E1M1.
const SCENARIO_MONSTERS: u32 = 29;

/// The readable half of the pin: how many of them are awake at the busiest
/// tic (past D3's window of 8, so the round robin really does slide), how
/// many events the 700 tics report, and how long the list has grown by the
/// end (fireballs and the clips a dead zombieman drops).
const SCENARIO_AWAKE_MAX: u32 = 11;
const SCENARIO_EVENTS: u32 = 277;
const SCENARIO_FINAL_MOBJS: u32 = 35;

fn world() -> World {
    world_of(@load(LevelId::E1M1))
}

fn fx(enc: felt252) -> Fixed {
    Fixed { enc }
}

fn u32_of(v: felt252) -> u32 {
    let u: u128 = v.try_into().unwrap();
    u.try_into().unwrap()
}

fn ctx_of(w: World, players: Span<u32>, tic: u32) -> Ctx {
    Ctx { w, players, noise: silence(), tic }
}

/// A monster of `kind` at `(x, y)` on its floor, linked in `g` under `idx`.
fn linked(w: World, ref g: ThingGrid, kind: u32, x: Fixed, y: Fixed, idx: u32) -> Mobj {
    let mut mo = spawn_mobj(w, kind, x, y, SpawnZ::OnFloor);
    set_thing_position(@w.map, ref g, ref mo, idx);
    mo
}

// ---------------------------------------------------------------------------
// P_NewChaseDir
// ---------------------------------------------------------------------------

#[test]
fn test_new_chase_dir_vectors() {
    let w = world();
    let v = CHASEDIRS.span();
    let n = v.len() / 12;
    let players = array![1].span();
    let mut i: u32 = 0;
    let mut stepped: u32 = 0;
    while i != n {
        let b = i * 12;
        let mut g = new_grid();
        let mut mo = linked(w, ref g, KIND_POSSESSED, fx(*v.at(b)), fx(*v.at(b + 1)), 0);
        let tgt = linked(w, ref g, KIND_PLAYER, fx(*v.at(b + 2)), fx(*v.at(b + 3)), 1);
        mo.move_dir = u32_of(*v.at(b + 4));
        let mut rng: Prng = from_index(u32_of(*v.at(b + 5)));
        let mobjs = array![mo, tgt].span();
        let mut ev: Array<MonsterEvent> = array![];
        new_chase_dir(ctx_of(w, players, 0), mobjs, ref g, ref rng, ref mo, 0, @tgt, ref ev);
        assert(mo.move_dir == u32_of(*v.at(b + 6)), 'movedir');
        assert(mo.x.enc == *v.at(b + 7), 'x');
        assert(mo.y.enc == *v.at(b + 8), 'y');
        assert(mo.move_count == u32_of(*v.at(b + 9)), 'movecount');
        assert(rng.index == u32_of(*v.at(b + 10)), 'rng index');
        stepped += u32_of(*v.at(b + 11));
        i += 1;
    }
    assert(stepped > n / 4, 'most cases step');
}

// ---------------------------------------------------------------------------
// P_CheckMissileRange
// ---------------------------------------------------------------------------

#[test]
fn test_check_missile_range_vectors() {
    let w = world();
    let start = genesis(LevelId::E1M1).start;
    let v = MISSILE_RANGES.span();
    let n = v.len() / 6;
    let players = array![1].span();
    let mut i: u32 = 0;
    let mut fired: u32 = 0;
    while i != n {
        let b = i * 6;
        // The distance rule only; sight is primed in the R2-A3 cache so that
        // the geometry does not enter the comparison (it has its own tests).
        let kind = if *v.at(b + 1) == 1 {
            KIND_TROOP
        } else {
            KIND_POSSESSED
        };
        let mut mo = spawn_mobj(w, kind, start.x, start.y, SpawnZ::OnFloor);
        let mut tgt = spawn_mobj(w, KIND_PLAYER, start.x, start.y, SpawnZ::OnFloor);
        tgt.x = Fixed { enc: mo.x.enc + *v.at(b) - fixed::BIAS };
        mo.reaction_time = u32_of(*v.at(b + 2));
        mo.sight_ok = true;
        mo.sight_sector = tgt.sector;
        mo.sight_expires = 1;
        let mut rng: Prng = from_index(u32_of(*v.at(b + 3)));
        let ok = check_missile_range(ctx_of(w, players, 0), ref rng, ref mo, @tgt);
        assert(ok == (*v.at(b + 4) == 1), 'missile range verdict');
        assert(rng.index == u32_of(*v.at(b + 5)), 'missile range rng');
        fired += u32_of(*v.at(b + 4));
        i += 1;
    }
    assert(fired != 0 && fired != n, 'both outcomes covered');
}

// ---------------------------------------------------------------------------
// P_CheckMeleeRange
// ---------------------------------------------------------------------------

#[test]
fn test_check_melee_range_vectors() {
    let w = world();
    let v = MELEES.span();
    let n = v.len() / 9;
    let players = array![1].span();
    let mut i: u32 = 0;
    let mut hits: u32 = 0;
    while i != n {
        let b = i * 9;
        let mut mo = spawn_mobj(w, KIND_SERGEANT, fx(*v.at(b)), fx(*v.at(b + 1)), SpawnZ::OnFloor);
        let tgt = spawn_mobj(w, KIND_PLAYER, fx(*v.at(b + 3)), fx(*v.at(b + 4)), SpawnZ::OnFloor);
        assert(mo.z.enc == *v.at(b + 2), 'monster floor');
        assert(tgt.z.enc == *v.at(b + 5), 'target floor');
        assert(mo.sector == u32_of(*v.at(b + 7)), 'monster sector');
        let ok = check_melee_range(ctx_of(w, players, 0), ref mo, @tgt);
        assert(ok == (*v.at(b + 8) == 1), 'melee verdict');
        hits += u32_of(*v.at(b + 8));
        i += 1;
    }
    assert(hits != 0, 'some pairs are in range');
}

// ---------------------------------------------------------------------------
// A_Look
// ---------------------------------------------------------------------------

#[test]
fn test_a_look_vectors() {
    let w = world();
    let v = LOOKS.span();
    let n = v.len() / 9;
    let players = array![1].span();
    let mut i: u32 = 0;
    let mut woke: u32 = 0;
    while i != n {
        let b = i * 9;
        let mut mo = spawn_mobj(w, KIND_POSSESSED, fx(*v.at(b)), fx(*v.at(b + 1)), SpawnZ::OnFloor);
        mo.angle = u32_of(*v.at(b + 3));
        let player = spawn_mobj(
            w, KIND_PLAYER, fx(*v.at(b + 4)), fx(*v.at(b + 5)), SpawnZ::OnFloor,
        );
        assert(mo.z.enc == *v.at(b + 2), 'monster floor');
        assert(player.z.enc == *v.at(b + 6), 'player floor');
        let mobjs = array![mo, player].span();
        let mut rng: Prng = from_index(1);
        let mut ev: Array<MonsterEvent> = array![];
        let action = a_look(ctx_of(w, players, 0), mobjs, ref rng, ref mo, 0, ref ev);
        let wake = *v.at(b + 8) == 1;
        assert((action != fsm::NO_ACTION) == wake, 'wake');
        if wake {
            assert(mo.target == 1, 'targets the player');
            assert(mo.state == *MI_SEESTATE.span().at(KIND_POSSESSED), 'enters seestate');
            // The zombieman's see sound picks inside `posit1..3`: one draw.
            assert(rng.index == 2, 'one see-sound draw');
        } else {
            assert(mo.state == *MI_SPAWNSTATE.span().at(KIND_POSSESSED), 'stays idle');
            assert(rng.index == 1, 'no draw when asleep');
        }
        woke += u32_of(*v.at(b + 8));
        i += 1;
    }
    assert(woke != 0 && woke != n, 'both outcomes covered');
}

// ---------------------------------------------------------------------------
// The `info.c` chains
// ---------------------------------------------------------------------------

#[test]
fn test_state_chains_match_the_model() {
    let w = world();
    let v = CHAINS.span();
    let n = v.len() / 5;
    let mut i: u32 = 0;
    while i != n {
        let b = i * 5;
        let state = u32_of(*v.at(b + 1));
        let (tics, action) = fsm::enter(w.states, state);
        assert(tics == u32_of(*v.at(b + 2)), 'chain tics');
        assert(action == u32_of(*v.at(b + 3)), 'chain action');
        assert(*w.states.next_state.at(state) == u32_of(*v.at(b + 4)), 'chain next');
        i += 1;
    }
    // The five kinds, in the order `gen_chains` emits them: spawn is the
    // `A_Look` loop, see is the `A_Chase` loop.
    let kinds = array![KIND_POSSESSED, 2, KIND_TROOP, KIND_SERGEANT, 5].span();
    let mut k: u32 = 0;
    while k != 5 {
        let kind = *kinds.at(k);
        let spawn = *MI_SPAWNSTATE.span().at(kind);
        let see = *MI_SEESTATE.span().at(kind);
        assert(*w.states.action_id.at(spawn) == A_LOOK, 'spawn looks');
        assert(*w.states.action_id.at(see) == A_CHASE, 'see chases');
        assert(*MI_PAINSTATE.span().at(kind) != 0, 'has a pain state');
        k += 1;
    }
    // Only the two zombies are pure hitscanners; only the imp has both.
    assert(*MI_MELEESTATE.span().at(KIND_POSSESSED) == 0, 'zombieman has no melee');
    assert(*MI_MISSILESTATE.span().at(KIND_SERGEANT) == 0, 'demon has no missile');
    assert(*MI_MELEESTATE.span().at(KIND_TROOP) != 0, 'imp claws');
    assert(*MI_MISSILESTATE.span().at(KIND_TROOP) != 0, 'imp throws');
}

// ---------------------------------------------------------------------------
// The 300-tic chase scenario
// ---------------------------------------------------------------------------

#[test]
fn test_chase_scenario_matches_the_model() {
    let w = world();
    let s = CHASE_SETUP.span();
    let mut g = new_grid();
    let mut mo = linked(w, ref g, KIND_POSSESSED, fx(*s.at(0)), fx(*s.at(1)), 0);
    let tgt = linked(w, ref g, KIND_PLAYER, fx(*s.at(2)), fx(*s.at(3)), 1);
    // Already awake, chasing a target it cannot see: pure movement.
    doom_physics::set_state(w, ref mo, *MI_SEESTATE.span().at(KIND_POSSESSED));
    mo.target = 1;
    mo.reaction_time = 0;
    let players = array![1].span();
    let mut mobjs = array![mo, tgt];
    let mut rng: Prng = from_index(1);
    let expect = CHASE.span();
    let mut tic: u32 = 0;
    while tic != CHASE_TICS {
        let (next, r, _ev) = monsters_ticker(w, mobjs.span(), ref g, players, silence(), tic, rng);
        mobjs = next;
        rng = r;
        if tic % CHASE_EVERY == CHASE_EVERY - 1 {
            let b = (tic / CHASE_EVERY) * 7;
            let m = mobjs.span().at(0);
            assert(*m.x.enc == *expect.at(b), 'chase x');
            assert(*m.y.enc == *expect.at(b + 1), 'chase y');
            assert(*m.move_dir == u32_of(*expect.at(b + 2)), 'chase movedir');
            assert(*m.move_count == u32_of(*expect.at(b + 3)), 'chase movecount');
            assert(*m.state == u32_of(*expect.at(b + 4)), 'chase state');
            assert(*m.tics == u32_of(*expect.at(b + 5)), 'chase tics');
            assert(rng.index == u32_of(*expect.at(b + 6)), 'chase rng');
        }
        tic += 1;
    }
}

// ---------------------------------------------------------------------------
// The 700-tic scripted scenario
// ---------------------------------------------------------------------------

/// Skill 2 ("Hurt me plenty", D3) is `MTF_NORMAL`; `MTF_NOTSINGLE` things do
/// not spawn in a single-player run.
fn spawns_at_skill_2(flags: u32) -> bool {
    has(flags, 2) && !has(flags, 16)
}

/// Where the scenario's player stands, as an offset in map units from the
/// Player 1 start: the first room the start corridor opens into. **Standing
/// on the start spot itself is a scenario in which nothing happens** — see
/// `test_the_start_alcove_is_quiet`, which pins that fact — so the scripted
/// run puts the player one room in, where six skill-2 monsters have line of
/// sight to him and the fight the task describes actually starts.
const STAND_DX: felt252 = 1600;
const STAND_DY: felt252 = 512;

/// Every skill-2 monster of E1M1, plus the player as mobj 0 — the list the
/// scenario ticks. `dx`/`dy` offset the player from the Player 1 start.
fn scenario_mobjs(w: World, ref g: ThingGrid, dx: felt252, dy: felt252) -> Array<Mobj> {
    let m = load(LevelId::E1M1);
    let start = genesis(LevelId::E1M1);
    let mut out: Array<Mobj> = array![];
    let px = fixed::add(start.start.x, fixed::from_units(dx));
    let py = fixed::add(start.start.y, fixed::from_units(dy));
    let mut player = spawn_mobj(w, KIND_PLAYER, px, py, SpawnZ::OnFloor);
    player.angle = start.angle;
    set_thing_position(@w.map, ref g, ref player, 0);
    out.append(player);
    let n = num_things(@m);
    let mut i: u32 = 0;
    while i != n {
        let t = thing(@m, i);
        if spawns_at_skill_2(t.flags) {
            match spawn_map_thing(w, t) {
                Option::Some(mo) => {
                    if has(mo.flags, MF_COUNTKILL) {
                        let idx = out.len();
                        let mut linked_mo = mo;
                        set_thing_position(@w.map, ref g, ref linked_mo, idx);
                        out.append(linked_mo);
                    }
                },
                Option::None => {},
            }
        }
        i += 1;
    }
    out
}

/// **The start alcove is quiet.** Not one of E1M1's 29 skill-2 monsters can
/// see the Player 1 start, and the only two whose sector the REJECT row does
/// not rule out are `MF_AMBUSH` — deaf, in Doom's own sense: they answer a
/// noise only if they can also see its source. So a player who stands on the
/// start spot and empties his pistol into the wall wakes nobody, in this
/// crate and in vanilla alike. This test pins that (and exercises the
/// `MF_AMBUSH` arm of `A_Look`'s noise path) — it is the reason the scripted
/// scenario below stands one room further in.
#[test]
fn test_the_start_alcove_is_quiet() {
    let w = world();
    let mut g = new_grid();
    let mut mobjs = scenario_mobjs(w, ref g, 0, 0);
    let players = array![0].span();
    let noise = crate::Noise { source: 0, sector: *mobjs.span().at(0).sector };
    let mut rng: Prng = from_index(1);
    let mut heard: u32 = 0;
    let mut i: u32 = 1;
    while i != mobjs.len() {
        let m = mobjs.span().at(i);
        if !doom_map::reject_of(
            w.map.reject, w.map.reject_stride, w.map.pow2, *m.sector, noise.sector,
        ) {
            heard += 1;
            assert(has(*m.flags, MF_AMBUSH), 'the two who hear are deaf');
        }
        i += 1;
    }
    assert(heard == 2, 'two sectors are not REJECTed');
    let mut tic: u32 = 0;
    while tic != 60 {
        let (next, r, _) = monsters_ticker(w, mobjs.span(), ref g, players, noise, tic, rng);
        mobjs = next;
        rng = r;
        tic += 1;
    }
    assert(crate::think::awake_count(w, mobjs.span()) == 0, 'nobody wakes at the start');
    assert(rng.index == 1, 'and nothing draws');
}

/// The 700-tic scripted scenario: the player stands still one room past the
/// start ([`STAND_DX`]/[`STAND_DY`]) and fires one shot on tic 0
/// (`P_NoiseAlert`). Six zombies have line of sight to him from there; they
/// wake through `A_Look`, walk up with `A_Chase`/`P_NewChaseDir` and open
/// fire.
#[test]
fn test_scripted_700_tics_on_e1m1() {
    let w = world();
    let mut g = new_grid();
    let mut mobjs = scenario_mobjs(w, ref g, STAND_DX, STAND_DY);
    assert(mobjs.len() == SCENARIO_MONSTERS + 1, 'skill-2 monster count');
    let players = array![0].span();
    let noise = crate::Noise { source: 0, sector: *mobjs.span().at(0).sector };
    let mut rng: Prng = from_index(1);
    let mut digest: Array<felt252> = array![];
    let mut awake_max: u32 = 0;
    let mut events: u32 = 0;
    let mut ambush: u32 = 0;
    let mut k: u32 = 0;
    while k != mobjs.len() {
        if has(*mobjs.span().at(k).flags, MF_AMBUSH) {
            ambush += 1;
        }
        k += 1;
    }
    let mut tic: u32 = 0;
    while tic != 700 {
        let (next, r, ev) = monsters_ticker(w, mobjs.span(), ref g, players, noise, tic, rng);
        mobjs = next;
        rng = r;
        events += ev.len();
        let a = crate::think::awake_count(w, mobjs.span());
        if a > awake_max {
            awake_max = a;
        }
        if tic % 50 == 49 {
            let mut i: u32 = 0;
            while i != mobjs.len() {
                push_felts(ref digest, mobjs.span().at(i));
                i += 1;
            }
            digest.append(rng.index.into());
        }
        tic += 1;
    }
    // The player never moves and never shoots, so only sight wakes anyone.
    assert(awake_max == SCENARIO_AWAKE_MAX, 'awake peak');
    assert(awake_max > crate::WINDOW, 'the window slides');
    assert(events == SCENARIO_EVENTS, 'event count');
    assert(mobjs.len() == SCENARIO_FINAL_MOBJS, 'final list length');
    assert(ambush > 0, 'E1M1 has ambush monsters');
    assert(digest.len() >= 14 * (MOBJ_FELTS * SCENARIO_MONSTERS + 1), 'digest shape');
    let sum = poseidon_hash_span(digest.span());
    // `assert!` prints the value that was actually computed, which is what a
    // deliberate regeneration needs.
    assert!(sum == SCENARIO_CHECKSUM, "scenario checksum {}", sum);
}

/// The scheduler's own promise on the real map: with `n <= 8` awake, every
/// awake monster is visited every tic; the ticker never loses a mobj.
#[test]
fn test_scenario_list_is_stable() {
    let w = world();
    let mut g = new_grid();
    let mut mobjs = scenario_mobjs(w, ref g, STAND_DX, STAND_DY);
    let n0 = mobjs.len();
    let players = array![0].span();
    let mut rng: Prng = from_index(1);
    let mut tic: u32 = 0;
    while tic != 40 {
        let (next, r, _) = monsters_ticker(w, mobjs.span(), ref g, players, silence(), tic, rng);
        mobjs = next;
        rng = r;
        assert(mobjs.len() >= n0, 'no slot is lost');
        tic += 1;
    }
    // Nothing shot anything, so every monster is still alive and countable.
    let mut alive: u32 = 0;
    let mut i: u32 = 1;
    while i != mobjs.len() {
        if *mobjs.span().at(i).health > 0 {
            alive += 1;
        }
        i += 1;
    }
    assert(alive == SCENARIO_MONSTERS, 'all monsters alive');
    assert(NO_MOBJ == 0xFFFF && LOOK_CADENCE == 4, 'constants');
}

/// A monster's `Patch` list is what carries a damaged target out of the tic;
/// the type is part of the public API, so it is exercised here.
#[test]
fn test_patch_reads_back() {
    let w = world();
    let start = genesis(LevelId::E1M1).start;
    let mo = spawn_mobj(w, KIND_POSSESSED, start.x, start.y, SpawnZ::OnFloor);
    let mut hurt_mo = mo;
    hurt_mo.health = 3;
    let mobjs = array![mo].span();
    let patches = array![Patch { idx: 0, mo: hurt_mo }].span();
    assert(crate::read_mobj(mobjs, patches, 0).health == 3, 'patch wins');
    assert(crate::read_mobj(mobjs, array![].span(), 0).health == mo.health, 'list otherwise');
}
