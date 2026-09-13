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
use super::num::dec;
use super::state::{PST_DEAD, Player, has_blue_key};
use super::think::player_think;

/// One tic of the player, specials included.
///
/// Order is `P_Ticker`'s: the special sector the player *was* standing in is
/// resolved first (its mobj has not moved yet this tic), then
/// `P_PlayerThink`, then the use-line the think reported. `doom_game` runs
/// `specials_ticker` and the thinker pass after this returns.
#[inline(always)]
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
            sector: mo.sector,
            on_floor: mo.z.enc == doom_physics::maputl::rd(w.floor, mo.sector),
            radiation_suit: false,
        };
        let (next, effect, ev) = player_in_special_sector(s, m, lm, ps, env.tic);
        s = next;
        damage = effect.damage;
        secret = effect.secret;
        append_events(ref cues, ev);
    }

    let before = events.len();
    player_think(env, ref g, ref rng, ref p, ref mo, word, damage, secret, ref events);

    // Keep both loops outside the wide player/mobj live set (S7 §8 rule 4).
    let seen = after(events.span(), before);
    apply_uses(ref s, ref cues, BoxTrait::new(*m), BoxTrait::new(*lm), has_blue_key(@p), seen);
    (s, cues)
}

fn after(mut seen: Span<PlayerEvent>, mut skip: u32) -> Span<PlayerEvent> {
    while skip != 0 {
        match seen.pop_front() {
            Option::Some(_) => { skip = dec(skip); },
            Option::None => { break; },
        }
    }
    seen
}

fn apply_uses(
    ref s: SpecialsState,
    ref cues: Array<Event>,
    m: Box<LevelMap>,
    lm: Box<SpecialsMap>,
    blue: bool,
    mut seen: Span<PlayerEvent>,
) {
    while let Option::Some(e) = seen.pop_front() {
        match *e {
            PlayerEvent::Use((
                line, side,
            )) => {
                let (next, ev, _) = use_line(s, @m.unbox(), @lm.unbox(), line, side, player(blue));
                s = next;
                append_events(ref cues, ev);
            },
            _ => {},
        }
    }
}

fn append_events(ref out: Array<Event>, mut more: Span<Event>) {
    while let Option::Some(e) = more.pop_front() {
        out.append(*e);
    }
}
