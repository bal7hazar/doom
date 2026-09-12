// SPDX-License-Identifier: GPL-2.0-only
//! Step-cost benchmark for `doom_things`.
//!
//! Differential measurement (S1 §3.1) with varying operands:
//!
//! * op 0 — bare loop;
//! * op 1 — the index arithmetic every lookup pays.

use doom_things::{
    WeaponId, flags, kind_of_doomednum, rndtable, spawn_state, states, thing_info, weapon_states,
};
use fsm::{advance, enter};
use prng::{PrngTrait, from_index};

#[executable]
fn main(op: u32, n: u32) -> felt252 {
    let t = states();
    let table = rndtable();
    let mut acc: felt252 = 0;
    let mut i: u32 = 0;

    if op == 0 { // bare loop
        while i != n {
            i += 1;
        }
    } else if op == 1 {
        // index baseline
        while i != n {
            acc += (i % 32).into();
            i += 1;
        }
    } else if op == 2 {
        // one `mobjinfo` field
        while i != n {
            acc += spawn_state(i % 32).into();
            i += 1;
        }
    } else if op == 3 {
        while i != n {
            acc += flags(i % 32).into();
            i += 1;
        }
    } else if op == 4 {
        // the whole 18-field record
        while i != n {
            let info = thing_info(i % 32);
            acc += info.spawnhealth.into() + info.radius.enc + info.flags.into();
            i += 1;
        }
    } else if op == 5 {
        // binary search over the doomednum table
        while i != n {
            acc += match kind_of_doomednum(2000 + i % 32) {
                Option::Some(k) => k.into(),
                Option::None => 0,
            };
            i += 1;
        }
    } else if op == 6 {
        // `fsm::advance`, counting down inside a state
        let mut state: u32 = 84; // the zombieman's chase chain
        let mut left: u32 = 4;
        while i != n {
            let (s, l, a) = advance(t, state, left);
            state = s;
            left = l;
            acc += a.into();
            i += 1;
        }
    } else if op == 7 {
        while i != n {
            let (tics, action) = enter(t, i % 32);
            acc += tics.into() + action.into();
            i += 1;
        }
    } else if op == 8 {
        // one RNG draw off the compiled-in table
        let mut rng = from_index(1);
        while i != n {
            let (next, v) = rng.next(table);
            rng = next;
            acc += v.into();
            i += 1;
        }
    } else if op == 9 {
        while i != n {
            let w = weapon_states(WeaponId::Pistol);
            acc += w.up.into() + w.attack.into() + (i % 32).into();
            i += 1;
        }
    }
    acc + i.into()
}
