// SPDX-FileCopyrightText: 2026 Hellproof contributors
// SPDX-License-Identifier: GPL-2.0-only
//! Simulation-only interactive harness. All gameplay stays in doom_game.
//! The host resumes hp_poll with [action, word]: 0 step, 1 checkpoint, 2 close.
use starknet::testing::cheatcode;

#[executable]
fn session(initial: Span<felt252>) -> Array<felt252> {
    let mut game = match doom_game::from_felts(initial) {
        Option::Some(game) => game,
        Option::None => { return array![3]; },
    };
    let _ = cheatcode::<'hp_frame'>(doom_game::render::snapshot_with_psprites(@game).span());
    loop {
        let reply = cheatcode::<'hp_poll'>(array![].span());
        let mut args = reply;
        let action = match args.pop_front() {
            Option::Some(a) => *a,
            Option::None => { return array![3]; },
        };
        if action == 0 {
            let word = match args.pop_front() {
                Option::Some(w) => *w,
                Option::None => { return array![3]; },
            };
            let (next, status) = doom_game::step_tic(game, word);
            game = next;
            let _ = cheatcode::<'hp_status'>(array![segment::status_felt(status)].span());
            let _ = cheatcode::<
                'hp_frame',
            >(doom_game::render::snapshot_with_psprites(@game).span());
        } else if action == 1 {
            let _ = cheatcode::<'hp_state'>(doom_game::serialize(@game).span());
        } else {
            return array![];
        }
    }
}

mod limit_fixture;
