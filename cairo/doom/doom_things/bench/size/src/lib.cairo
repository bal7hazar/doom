// SPDX-License-Identifier: GPL-2.0-only
//! The "with data" side of `doom_things`'s bytecode measurement (R2-A12).
//!
//! References one element of every generated `const` table, so that none is
//! dead-code-eliminated, and does nothing else. `../baseline` is the same
//! executable without the data; `../measure.py` subtracts the two.

use doom_things::{WeaponId, rndtable, states, tables, thing_info, weapon_states};

#[executable]
fn main(op: u32) -> felt252 {
    let t = states();
    let info = thing_info(0);
    let mut acc: felt252 = op.into();
    acc += (*t.sprite.at(0)).into() + (*t.frame.at(0)).into() + (*t.tics.at(0)).into();
    acc += (*t.action_id.at(0)).into() + (*t.next_state.at(0)).into();
    acc += info.doomednum.into()
        + info.spawnstate.into()
        + info.spawnhealth.into()
        + info.seestate.into()
        + info.reactiontime.into()
        + info.painstate.into()
        + info.painchance.into()
        + info.meleestate.into()
        + info.missilestate.into()
        + info.deathstate.into()
        + info.xdeathstate.into()
        + info.raisestate.into()
        + info.speed.into()
        + info.radius.enc
        + info.height.enc
        + info.mass.into()
        + info.damage.into()
        + info.flags.into();
    acc += (*rndtable().at(0)).into();
    acc += (*tables::DOOMEDNUM_KEYS.span().at(0)).into();
    acc += (*tables::DOOMEDNUM_KINDS.span().at(0)).into();
    let weapons: Array<WeaponId> = array![
        WeaponId::Fist, WeaponId::Pistol, WeaponId::Shotgun, WeaponId::Chaingun, WeaponId::Chainsaw,
    ];
    let mut i: u32 = 0;
    while i != weapons.len() {
        let w = weapon_states(*weapons.at(i));
        acc += w.up.into() + w.down.into() + w.ready.into() + w.attack.into() + w.flash.into();
        i += 1;
    }
    acc + tables::NUM_STATES.into() + tables::NUM_KINDS.into() + tables::NUM_ACTIONS.into()
}
