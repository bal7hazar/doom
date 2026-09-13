// SPDX-License-Identifier: GPL-2.0-only
//! The wiring between [`super::think::player_think`] and `doom_specials`:
//! `P_PlayerInSpecialSector` before the think, `P_UseSpecialLine` after it.
//!
//! `doom_game` may call this, or drive `player_think` itself and apply the
//! two triggers where it prefers; the crate's hot path does not depend on
//! `doom_specials`' types, so a caller that keeps its own specials state
//! pays nothing for them.

use doom_map::LevelMap;
use doom_physics::{Mobj, ThingGrid};
use doom_specials::{
    Event, PlayerSector, SpecialsMap, SpecialsState, player, player_in_special_sector, use_line,
};
use prng::Prng;
use super::env::{Env, PlayerEvent};
use super::state::{PST_DEAD, Player, has_blue_key};
use super::think::player_think;

/// One tic of the player, specials included.
///
/// Order is `P_Ticker`'s: the special sector the player *was* standing in is
/// resolved first (its mobj has not moved yet this tic), then
/// `P_PlayerThink`, then the use-line the think reported. `doom_game` runs
/// `specials_ticker` and the thinker pass after this returns.
pub fn player_tic(
    env: Env,
    m: @LevelMap,
    lm: @SpecialsMap,
    specials: SpecialsState,
    ref g: ThingGrid,
    ref rng: Prng,
    ref p: Player,
    ref mo: Mobj,
    word: felt252,
    ref events: Array<PlayerEvent>,
) -> (SpecialsState, Array<Event>) {
    let mut s = specials;
    let mut cues: Array<Event> = array![];
    let mut damage: u32 = 0;
    let mut secret = false;
    if p.playerstate != PST_DEAD {
        let w = env.world.unbox();
        let ps = PlayerSector {
            sector: mo.sector, on_floor: mo.z.enc == *w.floor.at(mo.sector), radiation_suit: false,
        };
        let (next, effect, ev) = player_in_special_sector(s, m, lm, ps, env.tic);
        s = next;
        damage = effect.damage;
        secret = effect.secret;
        append_events(ref cues, ev);
    }

    let before = events.len();
    player_think(env, ref g, ref rng, ref p, ref mo, word, damage, secret, ref events);

    // Apply whatever `P_UseLines` found.
    let seen = events.span();
    let n = seen.len();
    let mut k = before;
    while k != n {
        match *seen.at(k) {
            PlayerEvent::Use((
                line, side,
            )) => {
                let (next, ev, _) = use_line(s, m, lm, line, side, player(has_blue_key(@p)));
                s = next;
                append_events(ref cues, ev);
            },
            _ => {},
        }
        k += 1;
    }
    (s, cues)
}

fn append_events(ref out: Array<Event>, more: Span<Event>) {
    let n = more.len();
    let mut k: u32 = 0;
    while k != n {
        out.append(*more.at(k));
        k += 1;
    }
}
