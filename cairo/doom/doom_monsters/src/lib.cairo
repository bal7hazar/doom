// SPDX-License-Identifier: GPL-2.0-only
//! **Skeleton** (rewritten in P1.8 on top of `doom_physics`): a monster is a
//! position, a health, an awake flag and an `fsm` state over the generated
//! `doom_things` tables.

use doom_things::{rndtable, states, thing_info};
use fixed::{add, from_int};
use geom2d::Point;
use prng::{Prng, PrngTrait};

#[derive(Copy, Drop, Serde, PartialEq, Debug)]
pub struct MonsterState {
    pub position: Point,
    pub health: u32,
    pub awake: bool,
    pub state: u32,
    pub tics: u32,
}

/// Spawn a monster of `kind` (a `doom_things::tables::KIND_*`) in its
/// `spawnstate`.
pub fn spawn(kind: u32, position: Point) -> MonsterState {
    let info = thing_info(kind);
    let (tics, _) = fsm::enter(states(), info.spawnstate);
    MonsterState { position, health: info.spawnhealth, awake: false, state: info.spawnstate, tics }
}

/// A_Look's dice: always draws one byte of `rndtable` (RNG consumption is
/// replay-stable whatever the outcome), waking the monster when the roll is
/// below `wake_threshold`. Waking is one-directional.
pub fn look(monster: MonsterState, rng: Prng, wake_threshold: u8) -> (MonsterState, Prng) {
    let (next, roll) = rng.next(rndtable());
    let awake = monster.awake || roll < wake_threshold;
    (
        MonsterState {
            position: monster.position,
            health: monster.health,
            awake,
            state: monster.state,
            tics: monster.tics,
        },
        next,
    )
}

/// A_Chase's step: while awake, move `delta_y` map units along `y`
/// (collision is wired in by P1.8). A no-op while asleep.
pub fn chase(monster: MonsterState, delta_y: i64) -> MonsterState {
    if !monster.awake {
        return monster;
    }
    MonsterState {
        position: Point { x: monster.position.x, y: add(monster.position.y, from_int(delta_y)) },
        health: monster.health,
        awake: monster.awake,
        state: monster.state,
        tics: monster.tics,
    }
}

/// One tic of the state machine; returns the action id `fsm::advance` hands
/// back for the caller to dispatch (`fsm::NO_ACTION` when none).
pub fn advance_state(monster: MonsterState) -> (MonsterState, u32) {
    let (state, tics, action) = fsm::advance(states(), monster.state, monster.tics);
    (
        MonsterState {
            position: monster.position, health: monster.health, awake: monster.awake, state, tics,
        },
        action,
    )
}

#[cfg(test)]
mod tests {
    use doom_things::tables::KIND_POSSESSED;
    use fixed::from_int;
    use geom2d::Point;
    use prng::from_index;
    use super::{advance_state, chase, look, spawn};

    fn origin() -> Point {
        Point { x: from_int(0), y: from_int(0) }
    }

    #[test]
    fn test_asleep_monster_never_moves() {
        let monster = spawn(KIND_POSSESSED, origin());
        assert(chase(monster, 10).position == monster.position, 'asleep monster stays put');
    }

    #[test]
    fn test_look_always_consumes_one_draw() {
        let (_, rng) = look(spawn(KIND_POSSESSED, origin()), from_index(5), 0);
        assert(rng.index == 6, 'consumes exactly one draw');
    }

    #[test]
    fn test_look_wakes_when_roll_below_threshold() {
        let (woken, _) = look(spawn(KIND_POSSESSED, origin()), from_index(0), 255);
        assert(woken.awake, 'wakes with max threshold');
    }

    #[test]
    fn test_look_is_one_directional() {
        let (woken, rng) = look(spawn(KIND_POSSESSED, origin()), from_index(0), 255);
        let (still_awake, _) = look(woken, rng, 0);
        assert(still_awake.awake, 'stays awake');
    }

    #[test]
    fn test_advance_state_counts_down_the_spawn_state() {
        let monster = spawn(KIND_POSSESSED, origin());
        let (next, _) = advance_state(monster);
        assert(next.tics + 1 == monster.tics || next.state != monster.state, 'one tic elapsed');
    }
}
