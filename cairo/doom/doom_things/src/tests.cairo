// SPDX-License-Identifier: GPL-2.0-only
//! Tests for the tables derived from linuxdoom-1.10.
//!
//! The reference values are the ones an independent read of `info.c` gives
//! (chain shapes, tic counts, action order, `mobjinfo` fields), spelled out
//! here rather than regenerated, so that a change in the generator that
//! silently reshuffles ids fails.

use fsm::{FOREVER, NO_ACTION, advance, enter, row, validate};
use prng::{PrngTrait, from_index, is_valid_table};
use super::{
    MobjType, NO_DOOMEDNUM, WeaponId, flags, info_of, kind_of_doomednum, num_kinds, num_states,
    rndtable, spawn_state, states, tables, thing_info, weapon_states,
};

/// Longest run of consecutive zero-tic states, the bound `MAX_ZERO_TIC_CHAIN`
/// publishes.
fn zero_tic_chain(start: u32) -> u32 {
    let tables = states();
    let mut current = start;
    let mut n: u32 = 0;
    while n != super::num_states() {
        if *tables.tics.at(current) != 0 {
            break;
        }
        n += 1;
        current = *tables.next_state.at(current);
    }
    n
}

// ---------------------------------------------------------------------------
// Shape of the tables
// ---------------------------------------------------------------------------

#[test]
fn test_fsm_validate_passes() {
    assert(validate(states()), 'fsm::validate');
}

#[test]
fn test_table_sizes() {
    let t = states();
    assert(num_states() == 266, 'states');
    assert(num_kinds() == 48, 'kinds');
    assert(tables::NUM_ACTIONS == 26, 'actions');
    assert(t.sprite.len() == num_states(), 'sprite column');
    assert(t.frame.len() == num_states(), 'frame column');
    assert(t.tics.len() == num_states(), 'tics column');
    assert(t.action_id.len() == num_states(), 'action column');
    assert(t.next_state.len() == num_states(), 'next column');
    assert(tables::MI_DOOMEDNUM.span().len() == num_kinds(), 'mobjinfo column');
    assert(tables::DOOMEDNUM_KEYS.span().len() == tables::DOOMEDNUM_KINDS.span().len(), 'lookup');
}

#[test]
fn test_state_zero_is_s_null() {
    // `fsm` reserves row 0 of the action column for `NO_ACTION`, and Doom's
    // S_NULL is the state a dead thing ends in.
    let r = row(states(), 0).unwrap();
    assert(r.action_id == NO_ACTION, 'S_NULL has no action');
    assert(r.tics == FOREVER, 'S_NULL never leaves');
    assert(r.next_state == 0, 'S_NULL points at itself');
}

#[test]
fn test_every_referenced_state_and_action_exists() {
    let t = states();
    let n = num_states();
    let mut i: u32 = 0;
    while i != n {
        assert(*t.next_state.at(i) < n, 'next_state in range');
        assert(*t.action_id.at(i) < tables::NUM_ACTIONS, 'action id in range');
        assert(*t.sprite.at(i) < 64, 'sprite id in range');
        i += 1;
    }
    let k = num_kinds();
    let mut j: u32 = 0;
    while j != k {
        let info = thing_info(j);
        assert(info.spawnstate < n, 'spawnstate');
        assert(info.seestate < n, 'seestate');
        assert(info.painstate < n, 'painstate');
        assert(info.meleestate < n, 'meleestate');
        assert(info.missilestate < n, 'missilestate');
        assert(info.deathstate < n, 'deathstate');
        assert(info.xdeathstate < n, 'xdeathstate');
        assert(info.raisestate < n, 'raisestate');
        j += 1;
    }
}

#[test]
fn test_every_chain_terminates_or_loops() {
    // Floyd's cycle detection from every state: either the walk reaches a
    // `FOREVER` state (it terminates, like every death chain) or the tortoise
    // meets the hare (it loops, like every idle and walk chain). Nothing runs
    // off the end, and nothing can walk for ever *without* looping -- which is
    // what makes a bounded `while tics_left == 0` chain safe.
    let t = states();
    let n = num_states();
    let mut start: u32 = 0;
    let mut terminating: u32 = 0;
    let mut looping: u32 = 0;
    while start != n {
        let mut slow = start;
        let mut fast = start;
        let mut steps: u32 = 0;
        let verdict = loop {
            if *t.tics.at(slow) == FOREVER || *t.tics.at(fast) == FOREVER {
                break 1_u32; // terminates
            }
            slow = *t.next_state.at(slow);
            fast = *t.next_state.at(*t.next_state.at(fast));
            steps += 1;
            if slow == fast {
                break 2_u32; // loops
            }
            if steps == n {
                break 0_u32; // impossible in a finite graph
            }
        };
        assert(verdict != 0, 'chain neither ends nor loops');
        if verdict == 1 {
            terminating += 1;
        } else {
            looping += 1;
        }
        start += 1;
    }
    assert(terminating + looping == n, 'every state classified');
    assert(looping != 0, 'some chains loop');
    assert(terminating != 0, 'some chains terminate');
}

#[test]
fn test_zero_tic_chains_are_bounded() {
    // Doom's `P_SetMobjState` loops while the state it enters has `tics == 0`;
    // `fsm` leaves that to the caller, and this roster's longest such run is
    // `MAX_ZERO_TIC_CHAIN`, so a bounded loop is enough (D15).
    let t = states();
    let n = num_states();
    let mut i: u32 = 0;
    let mut zero: u32 = 0;
    let mut longest: u32 = 0;
    while i != n {
        if *t.tics.at(i) == 0 {
            zero += 1;
            let chain = zero_tic_chain(i);
            if chain > longest {
                longest = chain;
            }
        }
        i += 1;
    }
    assert(zero == 3, 'three zero-tic states');
    assert(longest == super::MAX_ZERO_TIC_CHAIN, 'MAX_ZERO_TIC_CHAIN is right');
}

// ---------------------------------------------------------------------------
// Vanilla chains, spot-checked against info.c
// ---------------------------------------------------------------------------

#[test]
fn test_zombieman_idle_chain() {
    // S_POSS_STND <-> S_POSS_STND2, 10 tics each, both A_Look.
    let t = states();
    let info = thing_info(tables::KIND_POSSESSED);
    let stand = info.spawnstate;
    // `fsm::enter` is `P_SetMobjState`: it answers with the tics to count
    // down and the action to run now, not with the state id.
    let (tics, action_on_entry) = enter(t, stand);
    assert(tics == 10, 'ten tics');
    assert(action_on_entry == tables::A_LOOK, 'A_Look on entry');
    let mut s = stand;
    let mut left = tics;
    let mut k: u32 = 0;
    let mut action = NO_ACTION;
    while k != 10 {
        let (ns, nl, a) = advance(t, s, left);
        s = ns;
        left = nl;
        action = a;
        k += 1;
    }
    assert(s == stand + 1, 'second idle frame');
    assert(action == tables::A_LOOK, 'A_Look');
    assert(left == 10, 'ten tics again');
    // ... and back again.
    let mut k2: u32 = 0;
    while k2 != 10 {
        let (ns, nl, _) = advance(t, s, left);
        s = ns;
        left = nl;
        k2 += 1;
    }
    assert(s == stand, 'idle chain is a two-state loop');
}

#[test]
fn test_zombieman_chase_chain_is_an_eight_frame_loop() {
    let t = states();
    let info = thing_info(tables::KIND_POSSESSED);
    let run = info.seestate;
    let mut s = run;
    let mut left = *t.tics.at(run);
    assert(left == 4, 'four tics per frame');
    let mut frames: u32 = 0;
    while frames != 8 {
        let mut k: u32 = 0;
        while k != 4 {
            let (ns, nl, a) = advance(t, s, left);
            if nl == 4 {
                assert(a == tables::A_CHASE, 'A_Chase on entry');
            }
            s = ns;
            left = nl;
            k += 1;
        }
        frames += 1;
    }
    assert(s == run, 'eight frames and back');
}

#[test]
fn test_zombieman_attack_pain_and_death_chains() {
    let t = states();
    let info = thing_info(tables::KIND_POSSESSED);
    // Attack: A_FaceTarget (10 tics), A_PosAttack (8), then 8 idle tics back
    // to the chase chain.
    let atk = info.missilestate;
    assert(*t.action_id.at(atk) == tables::A_FACETARGET, 'A_FaceTarget');
    assert(*t.tics.at(atk) == 10, 'ten tics');
    assert(*t.action_id.at(atk + 1) == tables::A_POSATTACK, 'A_PosAttack');
    assert(*t.tics.at(atk + 1) == 8, 'eight tics');
    assert(*t.action_id.at(atk + 2) == NO_ACTION, 'no action');
    assert(*t.next_state.at(atk + 2) == info.seestate, 'back to the chase');

    // Pain: one silent frame, then A_Pain, then the chase chain.
    let pain = info.painstate;
    assert(*t.action_id.at(pain) == NO_ACTION, 'pain frame 1');
    assert(*t.action_id.at(pain + 1) == tables::A_PAIN, 'A_Pain');
    assert(*t.next_state.at(pain + 1) == info.seestate, 'pain returns to chase');
    assert(info.painchance == 200, 'painchance');

    // Death: 5 frames, A_Scream then A_Fall, ending on a FOREVER corpse.
    let die = info.deathstate;
    assert(*t.action_id.at(die + 1) == tables::A_SCREAM, 'A_Scream');
    assert(*t.action_id.at(die + 2) == tables::A_FALL, 'A_Fall');
    assert(*t.tics.at(die + 4) == FOREVER, 'corpse stays');
    assert(*t.next_state.at(die + 4) == 0, 'corpse points at S_NULL');

    // Gib death: 9 frames, A_XScream then A_Fall.
    let xdie = info.xdeathstate;
    assert(*t.action_id.at(xdie + 1) == tables::A_XSCREAM, 'A_XScream');
    assert(*t.action_id.at(xdie + 2) == tables::A_FALL, 'A_Fall');
    assert(*t.tics.at(xdie + 8) == FOREVER, 'gibs stay');
}

// ---------------------------------------------------------------------------
// mobjinfo
// ---------------------------------------------------------------------------

#[test]
fn test_monster_spot_values() {
    let zombie = thing_info(tables::KIND_POSSESSED);
    assert(zombie.doomednum == 3004, 'zombieman doomednum');
    assert(zombie.spawnhealth == 20, 'zombieman health');
    assert(zombie.speed == 8, 'zombieman speed');
    assert(zombie.radius == fixed::from_units(20), 'zombieman radius');
    assert(zombie.height == fixed::from_units(56), 'zombieman height');
    assert(zombie.mass == 100, 'zombieman mass');
    assert(zombie.reactiontime == 8, 'zombieman reactiontime');

    let sergeant = thing_info(tables::KIND_SHOTGUY);
    assert(sergeant.doomednum == 9, 'shotgun guy doomednum');
    assert(sergeant.spawnhealth == 30, 'shotgun guy health');
    assert(sergeant.painchance == 170, 'shotgun guy painchance');

    let imp = thing_info(tables::KIND_TROOP);
    assert(imp.doomednum == 3001, 'imp doomednum');
    assert(imp.spawnhealth == 60, 'imp health');
    assert(imp.meleestate != 0, 'imp has a melee attack');
    assert(imp.missilestate != 0, 'imp has a fireball');

    let demon = thing_info(tables::KIND_SERGEANT);
    assert(demon.doomednum == 3002, 'demon doomednum');
    assert(demon.spawnhealth == 150, 'demon health');
    assert(demon.speed == 10, 'demon speed');
    assert(demon.radius == fixed::from_units(30), 'demon radius');
    assert(demon.missilestate == 0, 'demon has no ranged attack');

    let spectre = thing_info(tables::KIND_SHADOWS);
    assert(spectre.doomednum == 58, 'spectre doomednum');
    assert(spectre.spawnstate == demon.spawnstate, 'spectre shares demon states');
    assert(spectre.spawnhealth == demon.spawnhealth, 'spectre shares demon health');
    // MF_SHADOW = 1 << 18 is what makes a spectre hard to see and to hit.
    assert(spectre.flags / 262144 % 2 == 1, 'spectre is MF_SHADOW');
    assert(demon.flags / 262144 % 2 == 0, 'demon is not');
}

#[test]
fn test_monsters_are_solid_shootable_and_counted() {
    // MF_SOLID | MF_SHOOTABLE | MF_COUNTKILL, the three bits `doom_physics`
    // and the kill tally read.
    let kinds: Array<u32> = array![
        tables::KIND_POSSESSED, tables::KIND_SHOTGUY, tables::KIND_TROOP, tables::KIND_SERGEANT,
        tables::KIND_SHADOWS,
    ];
    let mut i: u32 = 0;
    while i != kinds.len() {
        let f = flags(*kinds.at(i));
        assert(f / 2 % 2 == 1, 'MF_SOLID');
        assert(f / 4 % 2 == 1, 'MF_SHOOTABLE');
        assert(f / 4194304 % 2 == 1, 'MF_COUNTKILL');
        i += 1;
    }
}

#[test]
fn test_projectiles_and_effects() {
    let fireball = thing_info(tables::KIND_TROOPSHOT);
    assert(fireball.doomednum == NO_DOOMEDNUM, 'fireball is spawn-only');
    assert(fireball.damage == 3, 'fireball damage');
    assert(fireball.speed == 10 * 65536, 'fireball speed is 16.16');
    assert(fireball.flags / 65536 % 2 == 1, 'MF_MISSILE');
    assert(fireball.flags / 512 % 2 == 1, 'MF_NOGRAVITY');

    let puff = thing_info(tables::KIND_PUFF);
    assert(puff.doomednum == NO_DOOMEDNUM, 'puff is spawn-only');
    assert(puff.flags / 16 % 2 == 1, 'puff is MF_NOBLOCKMAP');

    let blood = thing_info(tables::KIND_BLOOD);
    assert(blood.doomednum == NO_DOOMEDNUM, 'blood is spawn-only');

    // The barrel is a decoration that is nonetheless shootable and explodes.
    let barrel = thing_info(tables::KIND_BARREL);
    assert(barrel.doomednum == 2035, 'barrel doomednum');
    assert(barrel.spawnhealth == 20, 'barrel health');
    assert(barrel.flags / 4 % 2 == 1, 'barrel is MF_SHOOTABLE');
    // S_BEXP..S_BEXP5: A_Scream on frame 2, A_Explode on frame 4.
    assert(*states().action_id.at(barrel.deathstate + 1) == tables::A_SCREAM, 'A_Scream');
    assert(*states().action_id.at(barrel.deathstate + 3) == tables::A_EXPLODE, 'A_Explode');
}

#[test]
fn test_doomednum_lookup_round_trips() {
    let n = num_kinds();
    let mut i: u32 = 0;
    let mut placeable: u32 = 0;
    while i != n {
        let d = thing_info(i).doomednum;
        if d != NO_DOOMEDNUM {
            match kind_of_doomednum(d) {
                Option::Some(k) => {
                    assert(k == i, 'round trip');
                    placeable += 1;
                },
                Option::None => { assert(false, 'doomednum not found'); },
            }
        }
        i += 1;
    }
    assert(placeable == 44, 'placeable kinds');
    // A player start has no `mobjinfo` entry: `P_SpawnMapThing` handles it
    // before the catalogue is consulted.
    assert(kind_of_doomednum(1).is_none(), 'player start');
    assert(kind_of_doomednum(11).is_none(), 'deathmatch start');
    assert(kind_of_doomednum(9999).is_none(), 'unknown type');
    assert(kind_of_doomednum(3004) == Option::Some(tables::KIND_POSSESSED), 'zombieman');
    assert(kind_of_doomednum(3001) == Option::Some(tables::KIND_TROOP), 'imp');
    assert(kind_of_doomednum(2035) == Option::Some(tables::KIND_BARREL), 'barrel');
    assert(spawn_state(tables::KIND_BARREL) == thing_info(tables::KIND_BARREL).spawnstate, 'spawn');
}

#[test]
fn test_doomednum_keys_are_sorted() {
    // The binary search depends on it.
    let keys = tables::DOOMEDNUM_KEYS.span();
    let mut i: u32 = 1;
    while i != keys.len() {
        assert(*keys.at(i) > *keys.at(i - 1), 'sorted and unique');
        i += 1;
    }
}

// ---------------------------------------------------------------------------
// Weapons
// ---------------------------------------------------------------------------

#[test]
fn test_weapon_chains() {
    let n = num_states();
    let weapons: Array<WeaponId> = array![
        WeaponId::Fist, WeaponId::Pistol, WeaponId::Shotgun, WeaponId::Chaingun, WeaponId::Chainsaw,
    ];
    let mut i: u32 = 0;
    while i != weapons.len() {
        let w = weapon_states(*weapons.at(i));
        assert(w.up < n && w.down < n && w.ready < n && w.attack < n, 'weapon states in range');
        assert(w.flash < n, 'flash state in range');
        assert(w.up != w.down, 'up and down differ');
        i += 1;
    }
    // The fist is the only weapon with no muzzle flash.
    assert(weapon_states(WeaponId::Fist).flash == 0, 'fist has no flash');
    assert(weapon_states(WeaponId::Pistol).flash != 0, 'pistol flashes');
    // A_Punch is on the fist's attack chain, A_FirePistol on the pistol's.
    let t = states();
    assert(*t.action_id.at(weapon_states(WeaponId::Fist).attack + 1) == tables::A_PUNCH, 'A_Punch');
    assert(
        *t.action_id.at(weapon_states(WeaponId::Pistol).attack + 1) == tables::A_FIREPISTOL,
        'A_FirePistol',
    );
    assert(
        *t.action_id.at(weapon_states(WeaponId::Chaingun).attack) == tables::A_FIRECGUN,
        'A_FireCGun',
    );
}

// ---------------------------------------------------------------------------
// RNG table
// ---------------------------------------------------------------------------

#[test]
fn test_rndtable_checksum_and_spot_values() {
    let table = rndtable();
    assert(table.len() == 256, '256 entries');
    assert(is_valid_table(table), 'prng accepts it');
    let mut sum: u32 = 0;
    let mut i: u32 = 0;
    while i != 256 {
        sum += (*table.at(i)).into();
        i += 1;
    }
    // Doom's `rndtable` sums to 32 986 -- the cheapest single number that
    // pins all 256 bytes at once.
    assert(sum == 32986, 'rndtable checksum');
    assert(*table.at(0) == 0, 'rnd[0]');
    assert(*table.at(1) == 8, 'rnd[1]');
    assert(*table.at(2) == 109, 'rnd[2]');
    assert(*table.at(3) == 220, 'rnd[3]');
    assert(*table.at(255) == 249, 'rnd[255]');
}

#[test]
fn test_prng_over_the_table_matches_doom_order() {
    // Doom's `P_Random` increments *before* reading, so a run that starts at
    // cursor 1 sees rndtable[1], [2], [3]... `prng::next` reads then advances.
    let table = rndtable();
    let mut rng = from_index(1);
    let (next, a) = rng.next(table);
    rng = next;
    let (next, b) = rng.next(table);
    rng = next;
    let (_, c) = rng.next(table);
    assert(a == 8 && b == 109 && c == 220, 'doom order from cursor 1');
}

// ---------------------------------------------------------------------------
// The transitional catalogue must agree with the generated one
// ---------------------------------------------------------------------------

#[test]
fn test_compat_catalogue_matches_the_generated_tables() {
    let kinds: Array<MobjType> = array![MobjType::Player, MobjType::Zombieman, MobjType::Imp];
    let mut i: u32 = 0;
    while i != kinds.len() {
        let old = info_of(*kinds.at(i));
        let new = thing_info(super::compat::kind_of(*kinds.at(i)));
        assert(old.health == new.spawnhealth, 'health agrees');
        assert(old.radius == new.radius, 'radius agrees');
        assert(old.height == new.height, 'height agrees');
        i += 1;
    }
}

// ---------------------------------------------------------------------------
// Provability (A7)
// ---------------------------------------------------------------------------

#[test]
fn test_every_table_value_stays_small() {
    // Everything here is a `u32` or a `Fixed` below 2^33, so the whole crate
    // is far under the 2^72 threshold S0 measured (PLAN.md A7).
    let limit: felt252 = 0x200000000; // 2^33
    let n = num_kinds();
    let mut i: u32 = 0;
    while i != n {
        let info = thing_info(i);
        assert(fixed::felt_ge(limit, info.radius.enc), 'radius below 2^33');
        assert(fixed::felt_ge(limit, info.height.enc), 'height below 2^33');
        assert(info.radius.enc != 0, 'radius is encoded');
        i += 1;
    }
}
