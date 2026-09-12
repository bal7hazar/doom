// SPDX-License-Identifier: Apache-2.0
//! `DoomRuns` end to end: recomposition against the Python model's goldens, the fact gate, the
//! per-member validation rules of D18, replay publication (D13/R10-A3), replay protection
//! (R10-A1), the version table and the leaderboards.
//!
//! The fact registry is `MockFactRegistry` — the consumer uses exactly one entrypoint of the
//! P4.0 router (`is_valid`), and registering a fact for real costs 3.81e9 gas. Which facts are
//! registered is therefore the test's choice, which is what makes "unregistered fact" and
//! "fact mismatch" testable at all.
use doom_runs::doom_runs::DoomRuns::{Event, MemberRejected, RunSubmitted};
use doom_runs::doom_runs::{
    BOARD_SIZE, Digest, IDoomRunsDispatcher, IDoomRunsDispatcherTrait, KIND_SCORE, KIND_TIME,
    Member, ReplayLog, Version, compute_fact, digest_of, reason, score_of, words_of,
};
use doom_runs::mock_registry::MockFactRegistry::{
    IMockFactRegistryDispatcher, IMockFactRegistryDispatcherTrait,
};
use doom_runs::segment::{LeafOutput, STATUS_ABORT, STATUS_DEAD, STATUS_EXIT, STATUS_RUNNING};
use recursion_outputs::tree::root_output_hash;
use snforge_std::{
    ContractClassTrait, DeclareResultTrait, EventSpy, EventSpyAssertionsTrait, EventSpyTrait,
    declare, spy_events, start_cheat_caller_address, stop_cheat_caller_address,
};
use starknet::ContractAddress;
use crate::fixtures;

const VERSION_ID: u32 = 1;
const LEVEL_ID: u32 = 1;

fn owner() -> ContractAddress {
    0x0FF1CE.try_into().unwrap()
}

fn player(n: felt252) -> ContractAddress {
    (0x1000 + n).try_into().unwrap()
}

/// The `reason` of the last `MemberRejected` event (keys = [selector, member_index, player],
/// data = [reason, leaf_start, leaf_len]).
fn last_reason(ref spy: EventSpy) -> felt252 {
    let events = spy.get_events().events;
    let events = events.span();
    let (_, event) = events.at(events.len() - 1);
    *event.data.span().at(0)
}

/// The `reason` of the `n`-th event counted from the end.
fn reason_from_end(ref spy: EventSpy, back: u32) -> felt252 {
    let events = spy.get_events().events;
    let events = events.span();
    let (_, event) = events.at(events.len() - back);
    *event.data.span().at(0)
}

#[derive(Drop, Copy)]
struct World {
    runs: IDoomRunsDispatcher,
    registry: IMockFactRegistryDispatcher,
}

fn setup() -> World {
    let registry_class = declare("MockFactRegistry").unwrap().contract_class();
    let (registry_address, _) = registry_class.deploy(@array![]).unwrap();
    let runs_class = declare("DoomRuns").unwrap().contract_class();
    let (runs_address, _) = runs_class.deploy(@array![owner().into()]).unwrap();
    let world = World {
        runs: IDoomRunsDispatcher { contract_address: runs_address },
        registry: IMockFactRegistryDispatcher { contract_address: registry_address },
    };
    start_cheat_caller_address(runs_address, owner());
    world.runs.add_version(VERSION_ID, version(registry_address));
    world.runs.set_genesis(VERSION_ID, LEVEL_ID, fixtures::GENESIS);
    stop_cheat_caller_address(runs_address);
    world
}

fn version(registry: ContractAddress) -> Version {
    Version {
        program_hash: fixtures::PROGRAM_HASH,
        program_hash_function: fixtures::PROGRAM_HASH_FUNCTION,
        leaf_circuit_hash: digest_of(fixtures::leaf_circuit_hash()),
        multiverifier_hash: digest_of(fixtures::multiverifier_hash()),
        registry_name: fixtures::REGISTRY_NAME,
        verifier_router: registry,
    }
}

/// Registers the fact of `leaves` (as if the router had verified that batch's root proof) and
/// submits the members.
fn submit(
    world: World, leaves: Array<LeafOutput>, members: Array<Member>, replay: Array<ReplayLog>,
) -> u32 {
    world.registry.register(world.runs.batch_fact(VERSION_ID, leaves.clone()));
    world.runs.submit_batch(VERSION_ID, leaves, members, replay)
}

fn member(n: felt252, start: u32, len: u32) -> Member {
    Member { player: player(n), level_id: LEVEL_ID, leaf_start: start, leaf_len: len }
}

fn batch_members() -> Array<Member> {
    array![member(1, 0, 2), member(2, 2, 1), member(3, 3, 3)]
}

/// A one-segment finished run, distinct per `seed`.
fn solo(seed: felt252, kills: u32, tics: u32, status: u8) -> LeafOutput {
    LeafOutput {
        version: 1,
        h_in: fixtures::GENESIS,
        h_out: seed * 7 + 1,
        tic_start: 0,
        tic_end: tics,
        status,
        inputs_commitment: seed,
        kills,
        items: 0,
        secrets: 0,
    }
}

fn logs(packed: Array<Array<felt252>>) -> Array<ReplayLog> {
    let mut out = array![];
    let mut i = 0;
    while i != packed.len() {
        out.append(ReplayLog { leaf_index: i, packed: packed.at(i).clone() });
        i += 1;
    }
    out
}

// -- recomposition -----------------------------------------------------------

/// The root `output_hash` and the fact of the 2 + 1 + 3 batch, against the Python model.
#[test]
fn recomposition_matches_the_model() {
    let world = setup();
    let leaves = fixtures::batch_leaves();
    let mut preimages = array![];
    for leaf in leaves.span() {
        preimages.append(doom_runs::segment::to_preimage(fixtures::PROGRAM_HASH, leaf));
    }
    let mut spans = array![];
    for p in preimages.span() {
        spans.append(p.span());
    }
    let output_hash = root_output_hash(
        spans.span(), fixtures::leaf_circuit_hash(), fixtures::multiverifier_hash(),
    );
    assert_eq!(output_hash, fixtures::output_hash());
    assert_eq!(compute_fact(fixtures::multiverifier_hash(), output_hash), fixtures::FACT);
    assert_eq!(world.runs.batch_fact(VERSION_ID, leaves), fixtures::FACT);
}

/// A single-leaf batch is folded with itself (S4: `fold_entries` self-fold).
#[test]
fn single_leaf_batch_self_folds() {
    let world = setup();
    assert_eq!(world.runs.batch_fact(VERSION_ID, fixtures::single_leaf()), fixtures::SINGLE_FACT);
}

#[test]
fn digest_round_trips() {
    assert_eq!(words_of(digest_of(fixtures::multiverifier_hash())), fixtures::multiverifier_hash());
    assert_eq!(
        digest_of([1, 2, 3, 4, 5, 6, 7, 8]),
        Digest {
            lo: 1
                + 2 * 0x1_0000_0000
                + 3 * 0x1_0000_0000_0000_0000
                + 4 * 0x1_0000_0000_0000_0000_0000_0000,
            hi: 5
                + 6 * 0x1_0000_0000
                + 7 * 0x1_0000_0000_0000_0000
                + 8 * 0x1_0000_0000_0000_0000_0000_0000,
        },
    );
}

// -- the fact gate -----------------------------------------------------------

#[test]
#[should_panic(expected: 'doomruns: fact not registered')]
fn unregistered_fact_is_refused() {
    let world = setup();
    world.runs.submit_batch(VERSION_ID, fixtures::batch_leaves(), batch_members(), array![]);
}

/// One tampered output word changes the recomposed `output_hash`, so the fact of the batch
/// that *was* proved no longer matches: the submission reverts as a whole.
#[test]
#[should_panic(expected: 'doomruns: fact not registered')]
fn tampered_leaf_does_not_match_the_registered_fact() {
    let world = setup();
    world.registry.register(fixtures::FACT);
    let leaves = fixtures::batch_leaves();
    let mut tampered = array![];
    let mut i = 0;
    while i != leaves.len() {
        let leaf = *leaves.at(i);
        tampered.append(if i == 1 {
            LeafOutput { kills: leaf.kills + 1, ..leaf }
        } else {
            leaf
        });
        i += 1;
    }
    world.runs.submit_batch(VERSION_ID, tampered, batch_members(), array![]);
}

#[test]
#[should_panic(expected: 'doomruns: unknown version')]
fn unknown_version_is_refused() {
    let world = setup();
    world.runs.submit_batch(7, fixtures::batch_leaves(), batch_members(), array![]);
}

#[test]
#[should_panic(expected: 'doomruns: empty batch')]
fn empty_batch_is_refused() {
    let world = setup();
    world.runs.submit_batch(VERSION_ID, array![], array![], array![]);
}

// -- the happy path ----------------------------------------------------------

#[test]
fn batch_of_three_games_is_recorded() {
    let world = setup();
    let mut spy = spy_events();
    assert_eq!(submit(world, fixtures::batch_leaves(), batch_members(), array![]), 3);

    let expected = fixtures::batch_members();
    let mut i = 0;
    while i != expected.len() {
        let (start, len, run_id) = *expected.at(i);
        assert!(world.runs.is_run_registered(run_id), "member {} registered", i);
        let run = world.runs.get_run(run_id);
        assert_eq!(run.player, player((i + 1).into()));
        assert_eq!(run.version_id, VERSION_ID);
        assert_eq!(run.level_id, LEVEL_ID);
        assert_eq!(run.n_segments, len);
        assert_eq!(run.status, STATUS_EXIT);
        assert_eq!(run.fact, fixtures::FACT);
        assert_eq!(run.tics, 35 * len);
        assert_eq!(run.score, score_of(run.kills, run.items, run.secrets));
        assert_eq!(world.runs.player_run_count(player((i + 1).into())), 1);
        assert_eq!(world.runs.player_runs(player((i + 1).into()), 0, 10), array![run_id]);
        assert!(start == start);
        i += 1;
    }

    let (_, _, first) = *expected.at(0);
    spy
        .assert_emitted(
            @array![
                (
                    world.runs.contract_address,
                    Event::RunSubmitted(
                        RunSubmitted {
                            run_id: first,
                            player: player(1),
                            version_id: VERSION_ID,
                            level_id: LEVEL_ID,
                            tics: 70,
                            kills: 4,
                            items: 1,
                            secrets: 0,
                            score: score_of(4, 1, 0),
                            n_segments: 2,
                            fact: fixtures::FACT,
                        },
                    ),
                ),
            ],
        );
}

/// `register_member` is `submit_batch` for one game: the split used when the members of a
/// batch do not fit one invoke.
#[test]
fn register_member_records_one_game() {
    let world = setup();
    world.registry.register(fixtures::FACT);
    assert!(
        world.runs.register_member(VERSION_ID, fixtures::batch_leaves(), member(2, 2, 1), array![]),
    );
    let (_, _, run_id) = *fixtures::batch_members().at(1);
    assert!(world.runs.is_run_registered(run_id));
    let (_, _, other) = *fixtures::batch_members().at(0);
    assert!(!world.runs.is_run_registered(other));
}

// -- per-member validation (D18) --------------------------------------------

/// Submits `leaves` as a single member and returns the rejection reason of the only
/// `MemberRejected` event.
fn rejection(world: World, leaves: Array<LeafOutput>) -> felt252 {
    let len = leaves.len();
    let mut spy = spy_events();
    assert_eq!(submit(world, leaves, array![member(9, 0, len)], array![]), 0);
    last_reason(ref spy)
}

#[test]
fn abort_status_is_rejected() {
    let world = setup();
    assert_eq!(rejection(world, array![solo(11, 3, 70, STATUS_ABORT)]), reason::ABORT);
}

#[test]
fn an_unfinished_run_is_rejected() {
    let world = setup();
    assert_eq!(rejection(world, array![solo(12, 3, 70, STATUS_RUNNING)]), reason::UNFINISHED);
}

#[test]
fn a_broken_state_chain_is_rejected() {
    let world = setup();
    let first = solo(13, 1, 35, STATUS_RUNNING);
    let second = LeafOutput {
        h_in: 0xBAD,
        tic_start: 35,
        tic_end: 70,
        status: STATUS_EXIT,
        ..solo(14, 2, 70, STATUS_EXIT),
    };
    assert_eq!(rejection(world, array![first, second]), reason::CHAIN);
}

#[test]
fn a_tic_gap_is_rejected() {
    let world = setup();
    let first = solo(15, 1, 35, STATUS_RUNNING);
    let second = LeafOutput {
        h_in: first.h_out,
        tic_start: 36,
        tic_end: 70,
        status: STATUS_EXIT,
        ..solo(16, 2, 70, STATUS_EXIT),
    };
    assert_eq!(rejection(world, array![first, second]), reason::TICS);
}

#[test]
fn a_terminal_non_final_segment_is_rejected() {
    let world = setup();
    let first = solo(17, 1, 35, STATUS_EXIT);
    let second = LeafOutput {
        h_in: first.h_out,
        tic_start: 35,
        tic_end: 70,
        status: STATUS_EXIT,
        ..solo(18, 2, 70, STATUS_EXIT),
    };
    assert_eq!(rejection(world, array![first, second]), reason::EARLY_END);
}

#[test]
fn a_run_not_starting_from_genesis_is_rejected() {
    let world = setup();
    let leaf = LeafOutput { h_in: 0xF00D, ..solo(19, 1, 35, STATUS_EXIT) };
    assert_eq!(rejection(world, array![leaf]), reason::GENESIS);
}

#[test]
fn a_run_not_starting_at_tic_zero_is_rejected() {
    let world = setup();
    let leaf = LeafOutput { tic_start: 7, tic_end: 42, ..solo(20, 1, 35, STATUS_EXIT) };
    assert_eq!(rejection(world, array![leaf]), reason::TIC_START);
}

#[test]
fn an_unsupported_layout_version_is_rejected() {
    let world = setup();
    let leaf = LeafOutput { version: 2, ..solo(21, 1, 35, STATUS_EXIT) };
    assert_eq!(rejection(world, array![leaf]), reason::LAYOUT);
}

#[test]
fn an_unpinned_level_is_rejected() {
    let world = setup();
    let leaves = array![solo(22, 1, 35, STATUS_EXIT)];
    let mut spy = spy_events();
    world.registry.register(world.runs.batch_fact(VERSION_ID, leaves.clone()));
    let unknown = Member { player: player(9), level_id: 42, leaf_start: 0, leaf_len: 1 };
    assert_eq!(world.runs.submit_batch(VERSION_ID, leaves, array![unknown], array![]), 0);
    assert_eq!(last_reason(ref spy), reason::LEVEL);
}

#[test]
fn an_out_of_bounds_range_is_rejected() {
    let world = setup();
    let leaves = array![solo(23, 1, 35, STATUS_EXIT)];
    let mut spy = spy_events();
    world.registry.register(world.runs.batch_fact(VERSION_ID, leaves.clone()));
    assert_eq!(
        world
            .runs
            .submit_batch(VERSION_ID, leaves, array![member(9, 0, 2), member(8, 1, 0)], array![]),
        0,
    );
    assert_eq!(reason_from_end(ref spy, 1), reason::RANGE);
    assert_eq!(reason_from_end(ref spy, 2), reason::RANGE);
}

/// A `DEAD` run is kept as an *attempt*: recorded, never on a leaderboard, never in the
/// player's run index.
#[test]
fn a_dead_run_becomes_an_attempt() {
    let world = setup();
    let leaves = array![solo(24, 5, 35, STATUS_DEAD)];
    assert_eq!(submit(world, leaves.clone(), array![member(4, 0, 1)], array![]), 1);
    let run_id = world.runs.run_id_of(VERSION_ID, LEVEL_ID, leaves);
    assert!(world.runs.is_run_registered(run_id));
    let attempt = world.runs.get_attempt(run_id);
    assert_eq!(attempt.status, STATUS_DEAD);
    assert_eq!(attempt.player, player(4));
    assert_eq!(world.runs.get_run(run_id).player, 0.try_into().unwrap());
    assert_eq!(world.runs.leaderboard_len(VERSION_ID, KIND_SCORE), 0);
    assert_eq!(world.runs.player_run_count(player(4)), 0);
}

/// The same inputs cannot be recorded twice — not by the same submitter, not by another
/// (R10-A1): the run id is a function of the commitment chain only.
#[test]
fn the_same_run_cannot_be_submitted_twice() {
    let world = setup();
    let leaves = array![solo(25, 3, 35, STATUS_EXIT)];
    assert_eq!(submit(world, leaves.clone(), array![member(5, 0, 1)], array![]), 1);
    let mut spy = spy_events();
    assert_eq!(
        world.runs.submit_batch(VERSION_ID, leaves.clone(), array![member(6, 0, 1)], array![]), 0,
    );
    assert_eq!(last_reason(ref spy), reason::REPLAYED);
    assert_eq!(
        world.runs.get_run(world.runs.run_id_of(VERSION_ID, LEVEL_ID, leaves)).player, player(5),
    );
}

/// D18: an invalid member is skipped with an event, the valid ones are recorded.
#[test]
fn a_mixed_batch_records_the_valid_members() {
    let world = setup();
    let good = solo(26, 4, 35, STATUS_EXIT);
    let bad = solo(27, 4, 35, STATUS_ABORT);
    let other = solo(28, 9, 35, STATUS_EXIT);
    let leaves = array![good, bad, other];
    let mut spy = spy_events();
    assert_eq!(
        submit(world, leaves, array![member(1, 0, 1), member(2, 1, 1), member(3, 2, 1)], array![]),
        2,
    );
    assert_eq!(world.runs.player_run_count(player(1)), 1);
    assert_eq!(world.runs.player_run_count(player(2)), 0);
    assert_eq!(world.runs.player_run_count(player(3)), 1);
    spy
        .assert_emitted(
            @array![
                (
                    world.runs.contract_address,
                    Event::MemberRejected(
                        MemberRejected {
                            member_index: 1,
                            player: player(2),
                            reason: reason::ABORT,
                            leaf_start: 1,
                            leaf_len: 1,
                        },
                    ),
                ),
            ],
        );
}

// -- replay publication (D13 / R10-A3) --------------------------------------

#[test]
fn replay_data_is_checked_and_published() {
    let world = setup();
    let leaves = fixtures::batch_leaves();
    let mut spy = spy_events();
    assert_eq!(submit(world, leaves, batch_members(), logs(fixtures::batch_logs())), 3);
    let events = spy.get_events().events;
    let mut replays = 0;
    for (_, event) in events.span() {
        // Replay: keys = [selector, run_id], data = [leaf_index, tic_start, tic_end, len, …]
        let data = event.data.span();
        if data.len() > 4 && *data.at(1) == 0 && *data.at(2) == 35 {
            replays += 1;
        }
    }
    assert_eq!(replays, 3, "one Replay per run start");
}

#[test]
fn a_log_that_does_not_match_the_commitment_is_rejected() {
    let world = setup();
    let leaves = fixtures::single_leaf();
    let mut packed = fixtures::single_log();
    let mut wrong = array![];
    let mut i = 0;
    while i != packed.len() {
        wrong.append(if i == 0 {
            *packed.at(i) + 1
        } else {
            *packed.at(i)
        });
        i += 1;
    }
    let mut spy = spy_events();
    world.registry.register(fixtures::SINGLE_FACT);
    assert_eq!(
        world.runs.submit_batch(VERSION_ID, leaves, array![member(1, 0, 1)], logs(array![wrong])),
        0,
    );
    assert_eq!(last_reason(ref spy), reason::LOG_COMMITMENT);
}

#[test]
fn a_log_of_the_wrong_length_is_rejected() {
    let world = setup();
    let mut short = fixtures::single_log();
    let _ = short.pop_front();
    let mut spy = spy_events();
    world.registry.register(fixtures::SINGLE_FACT);
    assert_eq!(
        world
            .runs
            .submit_batch(
                VERSION_ID, fixtures::single_leaf(), array![member(1, 0, 1)], logs(array![short]),
            ),
        0,
    );
    assert_eq!(last_reason(ref spy), reason::LOG_LENGTH);
}

/// Replay data must cover a member's whole range or none of it.
#[test]
fn a_partial_log_is_rejected() {
    let world = setup();
    let all = fixtures::batch_logs();
    let partial = array![ReplayLog { leaf_index: 0, packed: all.at(0).clone() }];
    let mut spy = spy_events();
    world.registry.register(fixtures::FACT);
    assert_eq!(
        world
            .runs
            .submit_batch(VERSION_ID, fixtures::batch_leaves(), array![member(1, 0, 2)], partial),
        0,
    );
    assert_eq!(last_reason(ref spy), reason::LOG_MISSING);
}

// -- leaderboards ------------------------------------------------------------

#[test]
fn leaderboards_rank_by_score_and_by_time() {
    let world = setup();
    // Three finished runs: kills 1/9/5, tics 300/100/200.
    let leaves = array![
        solo(31, 1, 300, STATUS_EXIT), solo(32, 9, 100, STATUS_EXIT), solo(33, 5, 200, STATUS_EXIT),
    ];
    assert_eq!(
        submit(world, leaves, array![member(1, 0, 1), member(2, 1, 1), member(3, 2, 1)], array![]),
        3,
    );
    let by_score = world.runs.leaderboard(VERSION_ID, KIND_SCORE, 0, 10);
    assert_eq!(by_score.len(), 3);
    assert_eq!(*by_score.at(0).value, score_of(9, 0, 0));
    assert_eq!(*by_score.at(1).value, score_of(5, 0, 0));
    assert_eq!(*by_score.at(2).value, score_of(1, 0, 0));
    assert_eq!(*by_score.at(0).player, player(2));

    let by_time = world.runs.leaderboard(VERSION_ID, KIND_TIME, 0, 10);
    assert_eq!(*by_time.at(0).value, 100);
    assert_eq!(*by_time.at(1).value, 200);
    assert_eq!(*by_time.at(2).value, 300);

    // Paging.
    let page = world.runs.leaderboard(VERSION_ID, KIND_SCORE, 1, 1);
    assert_eq!(page.len(), 1);
    assert_eq!(*page.at(0).value, score_of(5, 0, 0));
    assert_eq!(world.runs.leaderboard(VERSION_ID, KIND_SCORE, 3, 5).len(), 0);
}

/// The board holds `BOARD_SIZE` entries; a run that does not beat the cutoff pays one read and
/// is not stored.
#[test]
fn the_board_keeps_the_best_entries_only() {
    let world = setup();
    let mut leaves = array![];
    let mut members = array![];
    let mut i: u32 = 0;
    while i != BOARD_SIZE + 2 {
        leaves.append(solo((40 + i).into(), i + 1, 1000 - i, STATUS_EXIT));
        members.append(member((i + 1).into(), i, 1));
        i += 1;
    }
    assert_eq!(submit(world, leaves, members, array![]), BOARD_SIZE + 2);
    assert_eq!(world.runs.leaderboard_len(VERSION_ID, KIND_SCORE), BOARD_SIZE);
    let board = world.runs.leaderboard(VERSION_ID, KIND_SCORE, 0, 100);
    assert_eq!(board.len(), BOARD_SIZE);
    assert_eq!(*board.at(0).value, score_of(BOARD_SIZE + 2, 0, 0));
    assert_eq!(*board.at(BOARD_SIZE - 1).value, score_of(3, 0, 0));
}

// -- the version table -------------------------------------------------------

#[test]
fn the_version_table_is_readable() {
    let world = setup();
    let stored = world.runs.get_version(VERSION_ID);
    assert_eq!(stored.program_hash, fixtures::PROGRAM_HASH);
    assert_eq!(stored.program_hash_function, fixtures::PROGRAM_HASH_FUNCTION);
    assert_eq!(stored.registry_name, fixtures::REGISTRY_NAME);
    assert_eq!(words_of(stored.multiverifier_hash), fixtures::multiverifier_hash());
    assert_eq!(world.runs.genesis_of(VERSION_ID, LEVEL_ID), fixtures::GENESIS);
    assert_eq!(world.runs.genesis_of(VERSION_ID, 77), 0);
    assert!(!world.runs.is_frozen());
    assert_eq!(world.runs.owner(), owner());
}

#[test]
#[should_panic(expected: 'doomruns: not owner')]
fn a_stranger_cannot_add_a_version() {
    let world = setup();
    world.runs.add_version(2, version(world.registry.contract_address));
}

#[test]
#[should_panic(expected: 'doomruns: version exists')]
fn a_version_cannot_be_mutated() {
    let world = setup();
    start_cheat_caller_address(world.runs.contract_address, owner());
    world.runs.add_version(VERSION_ID, version(world.registry.contract_address));
}

#[test]
#[should_panic(expected: 'doomruns: frozen')]
fn freezing_closes_the_table() {
    let world = setup();
    start_cheat_caller_address(world.runs.contract_address, owner());
    world.runs.freeze();
    assert!(world.runs.is_frozen());
    world.runs.add_version(2, version(world.registry.contract_address));
}

#[test]
#[should_panic(expected: 'doomruns: frozen')]
fn freezing_closes_the_genesis_table() {
    let world = setup();
    start_cheat_caller_address(world.runs.contract_address, owner());
    world.runs.freeze();
    world.runs.set_genesis(VERSION_ID, 2, 0x1234);
}

/// A frozen table still accepts submissions — freezing pins the rules, it does not stop the
/// season.
#[test]
fn a_frozen_table_still_accepts_runs() {
    let world = setup();
    start_cheat_caller_address(world.runs.contract_address, owner());
    world.runs.freeze();
    stop_cheat_caller_address(world.runs.contract_address);
    assert_eq!(submit(world, fixtures::batch_leaves(), batch_members(), array![]), 3);
}
