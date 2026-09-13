// SPDX-License-Identifier: GPL-2.0-only
//! Exercise the public monster pass on a real serialized game state.
//! Emit every output field: no checksum pin or reduced event count can
//! conceal a difference in the before/after comparison.
use doom_monsters::monsters_ticker_with_defense;
use doom_physics::{PlayerDefense, push_felts};

#[executable]
fn main(state: Array<felt252>) -> Array<felt252> {
    let g = doom_game::from_felts(state.span()).expect('valid probe state');
    let w = doom_game::ctx_of(g.level, g.floor, g.ceil).w;
    let mut grid = g.grid;
    let mut defense = PlayerDefense {
        mo: g.player.mo,
        armor_points: g.player.armor_points,
        armor_type: g.player.armor_type,
        damagecount: g.player.damagecount,
        attacker: g.player.attacker,
    };
    let (mobjs, rng, events) = monsters_ticker_with_defense(
        w, g.mobjs, ref grid, array![g.player.mo].span(), g.noise, g.leveltime, g.prng, ref defense,
    );
    let mut out = array![
        rng.index.into(), defense.mo.into(), defense.armor_points.into(), defense.armor_type.into(),
        defense.damagecount.into(), defense.attacker.into(), mobjs.len().into(),
    ];
    let mut ms = mobjs.span();
    while let Option::Some(m) = ms.pop_front() {
        push_felts(ref out, m);
    }
    out.append(events.len().into());
    let mut es = events.span();
    while let Option::Some(e) = es.pop_front() {
        out.append((*e.kind).into());
        out.append((*e.who).into());
        out.append((*e.a).into());
        out.append((*e.b).into());
        out.append(*e.at.x.enc);
        out.append(*e.at.y.enc);
    }
    let order = doom_physics::grid::canonical_order(@grid, mobjs.span());
    out.append(order.len().into());
    out.append_span(order.span());
    out
}
