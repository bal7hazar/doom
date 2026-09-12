// SPDX-License-Identifier: GPL-2.0-only

use doom_map::Level;
use doom_physics::can_move;
use doom_things::{MobjType, info_of};
use fixed::{add, from_int};
use fsm::{StateDef, Timer, start as fsm_start, tick as fsm_tick};
use geom2d::Point;
use prng::next as prng_next;

#[derive(Copy, Drop, Serde, PartialEq, Debug)]
pub struct MonsterState {
    pub position: Point,
    pub health: u32,
    pub awake: bool,
    pub timer: Timer,
}

pub fn spawn(
    kind: MobjType, position: Point, states: Span<StateDef>, initial_state: u32,
) -> MonsterState {
    let info = info_of(kind);
    MonsterState {
        position, health: info.health, awake: false, timer: fsm_start(states, initial_state),
    }
}

/// A_Look: always draws one RNG byte (so RNG consumption is replay-stable
/// regardless of the outcome), waking the monster if the roll is below
/// `wake_threshold`. Waking is one-directional: an awake monster stays
/// awake.
pub fn look(monster: MonsterState, rng_index: u8, wake_threshold: u8) -> (MonsterState, u8) {
    let (roll, next_index) = prng_next(rng_index);
    let awake = monster.awake || roll < wake_threshold;
    (
        MonsterState {
            position: monster.position, health: monster.health, awake, timer: monster.timer,
        },
        next_index,
    )
}

/// A_Chase: while awake, take one step of `delta_y` toward the target,
/// respecting `doom_physics::can_move`. A no-op while asleep.
pub fn chase(level: @Level, monster: MonsterState, delta_y: i64) -> MonsterState {
    if !monster.awake {
        return monster;
    }
    let step = from_int(delta_y);
    let new_position = Point { x: monster.position.x, y: add(monster.position.y, step) };
    if can_move(level, monster.position, new_position) {
        MonsterState {
            position: new_position,
            health: monster.health,
            awake: monster.awake,
            timer: monster.timer,
        }
    } else {
        monster
    }
}

/// Tick the monster's `fsm::Timer` by one tic.
pub fn advance_state(states: Span<StateDef>, monster: MonsterState) -> MonsterState {
    MonsterState {
        position: monster.position,
        health: monster.health,
        awake: monster.awake,
        timer: fsm_tick(states, monster.timer),
    }
}

#[cfg(test)]
mod tests {
    use doom_map::sample_level;
    use doom_things::MobjType;
    use fixed::from_int;
    use fsm::StateDef;
    use geom2d::Point;
    use super::{chase, look, spawn};

    fn sample_states() -> Array<StateDef> {
        let mut states = array![];
        states.append(StateDef { duration: 4, next: 0 });
        states
    }

    fn origin() -> Point {
        Point { x: from_int(0), y: from_int(0) }
    }

    #[test]
    fn test_asleep_monster_never_moves() {
        let level = sample_level();
        let states = sample_states();
        let monster = spawn(MobjType::Zombieman, origin(), states.span(), 0);
        let moved = chase(@level, monster, 10);
        assert(moved.position == monster.position, 'asleep monster stays put');
    }

    #[test]
    fn test_look_always_consumes_one_draw() {
        let states = sample_states();
        let monster = spawn(MobjType::Zombieman, origin(), states.span(), 0);
        let (_, next_index) = look(monster, 5, 0);
        assert(next_index == 6, 'consumes exactly one draw');
    }

    #[test]
    fn test_look_wakes_when_roll_below_threshold() {
        let states = sample_states();
        let monster = spawn(MobjType::Zombieman, origin(), states.span(), 0);
        // wake_threshold 255 makes the wake condition true for every roll.
        let (woken, _) = look(monster, 0, 255);
        assert(woken.awake, 'wakes with max threshold');
    }

    #[test]
    fn test_look_is_one_directional() {
        let states = sample_states();
        let mut monster = spawn(MobjType::Zombieman, origin(), states.span(), 0);
        let (woken, next_index) = look(monster, 0, 255);
        assert(woken.awake, 'wakes up');
        // Even with a threshold of 0 (never wakes on its own), an already
        // awake monster stays awake.
        let (still_awake, _) = look(woken, next_index, 0);
        assert(still_awake.awake, 'stays awake');
    }
}
