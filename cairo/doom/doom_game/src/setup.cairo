// SPDX-License-Identifier: GPL-2.0-only
//! Tic 0: `P_SetupLevel`'s state — the player at the Player 1 start, every
//! skill-2 THINGS entry spawned in map order, the specials spawned after
//! them (so `P_Random` is drawn in Doom's order: the light thinkers draw,
//! the map things do not), both RNG streams at `from_index(1)` (D24).

use doom_map::{LevelId, genesis as level_genesis, num_things, thing};
use doom_monsters::silence;
use doom_physics::{new_grid, set_thing_position, spawn_map_thing};
use doom_player::{PST_DEAD, PlayerEvent, bring_up_weapon, env_of, spawn};
use doom_specials::spawn_specials;
use doom_things::rndtable;
use prng::from_index;
use segment::Status;
use super::level::{ctx_of, materialise_heights};
use super::state::GameState;

/// The state a run starts from. `status` is `Running`; the segment chain
/// starts at `hash(@genesis(level))`.
pub fn genesis(level: LevelId) -> GameState {
    let m = doom_map::load(level);
    let ctx = ctx_of(level, m.s_floor, m.s_ceil);
    let w = ctx.w;
    let g0 = level_genesis(level);
    let mut grid = new_grid();
    let mut mobjs = array![];

    // The player first, at index 0.
    let (player, mut pmo) = spawn(w, 0, g0.start, g0.angle);
    set_thing_position(@w.map, ref grid, ref pmo, 0);
    mobjs.append(pmo);

    // Then every map thing, in THINGS order (skill 2 already filtered by
    // `doom_map`; starts and unknown types spawn nothing).
    let n = num_things(@m);
    let mut i: u32 = 0;
    while i != n {
        match spawn_map_thing(w, thing(@m, i)) {
            Option::Some(mo) => {
                let idx = mobjs.len();
                let mut linked = mo;
                set_thing_position(@w.map, ref grid, ref linked, idx);
                mobjs.append(linked);
            },
            Option::None => {},
        }
        i = i + 1;
    }

    // `P_SetupPsprites`: raise the pistol (no draw).
    let mut p = player;
    let mut pmo_up = *mobjs.span().at(0);
    let mut rng = from_index(1);
    let mut events: Array<PlayerEvent> = array![];
    let env = env_of(w, mobjs.span(), 0, 0, 0);
    bring_up_weapon(env, ref grid, ref rng, ref p, ref pmo_up, ref events, 0);

    let (specials, prng) = spawn_specials(@m, @ctx.lm, rng, rndtable());
    let (floor, ceil) = materialise_heights(@m, @ctx.lm, @specials);
    GameState {
        level,
        leveltime: 0,
        status: Status::Running,
        noise: silence(),
        prng,
        mrng: from_index(1),
        player: p,
        mobjs: mobjs.span(),
        specials,
        floor,
        ceil,
        grid,
    }
}

/// D14's status of a state: `EXIT` once the exit switch fired, else `DEAD`
/// on `PST_DEAD`, else `RUNNING`. `Abort` is never derived — it is what
/// `step_tic` reports on an invalid input.
pub fn status_of(s: @GameState) -> Status {
    status_from(*s.specials.exit, *s.player.playerstate)
}

/// The same rule on the two fields it reads.
pub fn status_from(exit: bool, playerstate: u32) -> Status {
    if exit {
        Status::Exit
    } else if playerstate == PST_DEAD {
        Status::Dead
    } else {
        Status::Running
    }
}
