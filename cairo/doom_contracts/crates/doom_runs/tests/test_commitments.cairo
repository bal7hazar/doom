// SPDX-License-Identifier: Apache-2.0
//! The open-prover extension of `DoomRuns` (D35): a player commits a played game with its
//! packed input log and a bounty in escrow, anyone proves it and submits it, the bounty goes to
//! the submitter, an unproved commitment is reclaimable after expiry.
//!
//! The fee token is `MockERC20` (a minimal `mint`/`approve`/`transfer`/`transfer_from`), the
//! fact registry is `MockFactRegistry` as in `test_doom_runs.cairo`.
use doom_runs::doom_runs::DoomRuns::{
    CommitmentProved, CommitmentReclaimed, Event, RunCommitted, RunLog,
};
use doom_runs::doom_runs::{
    IDoomRunsDispatcher, IDoomRunsDispatcherTrait, LOG_CHUNK, Member, ReplayLog, TAG_COMMIT,
    Version, commit_status, commitment_id_of, digest_of, reason,
};
use doom_runs::mock_registry::MockFactRegistry::{
    IMockFactRegistryDispatcher, IMockFactRegistryDispatcherTrait,
};
use doom_runs::segment::{LeafOutput, STATUS_EXIT, commit_log, packed_len};
use snforge_std::{
    ContractClassTrait, DeclareResultTrait, EventSpy, EventSpyAssertionsTrait, EventSpyTrait,
    declare, spy_events, start_cheat_block_number, start_cheat_caller_address,
    stop_cheat_caller_address,
};
use starknet::ContractAddress;
use crate::fixtures;
use doom_runs::mock_erc20::MockERC20::{IMockERC20Dispatcher, IMockERC20DispatcherTrait};

const VERSION_ID: u32 = 1;
const LEVEL_ID: u32 = 1;
/// Blocks before an unproved commitment can be reclaimed.
const EXPIRY: u64 = 100;
const BOUNTY: u256 = 1_000;
const FUNDS: u256 = 10_000;

fn owner() -> ContractAddress {
    0x0FF1CE.try_into().unwrap()
}

fn player(n: felt252) -> ContractAddress {
    (0x1000 + n).try_into().unwrap()
}

fn prover(n: felt252) -> ContractAddress {
    (0x9000 + n).try_into().unwrap()
}

#[derive(Drop, Copy)]
struct World {
    runs: IDoomRunsDispatcher,
    registry: IMockFactRegistryDispatcher,
    token: IMockERC20Dispatcher,
}

/// Deploys the three contracts, pins the version and the level, funds player 1 with `FUNDS`
/// and lets `DoomRuns` spend them.
fn setup() -> World {
    let registry_class = declare("MockFactRegistry").unwrap().contract_class();
    let (registry_address, _) = registry_class.deploy(@array![]).unwrap();
    let token_class = declare("MockERC20").unwrap().contract_class();
    let (token_address, _) = token_class.deploy(@array![]).unwrap();
    let runs_class = declare("DoomRuns").unwrap().contract_class();
    let (runs_address, _) = runs_class
        .deploy(@array![owner().into(), token_address.into(), EXPIRY.into()])
        .unwrap();
    let world = World {
        runs: IDoomRunsDispatcher { contract_address: runs_address },
        registry: IMockFactRegistryDispatcher { contract_address: registry_address },
        token: IMockERC20Dispatcher { contract_address: token_address },
    };
    start_cheat_caller_address(runs_address, owner());
    world.runs.add_version(VERSION_ID, version(registry_address));
    world.runs.set_genesis(VERSION_ID, LEVEL_ID, fixtures::GENESIS);
    stop_cheat_caller_address(runs_address);

    world.token.mint(player(1), FUNDS);
    start_cheat_caller_address(token_address, player(1));
    world.token.approve(runs_address, FUNDS);
    stop_cheat_caller_address(token_address);
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

fn member(n: felt252, start: u32, len: u32) -> Member {
    Member { player: player(n), level_id: LEVEL_ID, leaf_start: start, leaf_len: len }
}

/// `commit_run` as `who`.
fn commit(
    world: World, who: ContractAddress, packed: Array<felt252>, tics: u32, bounty: u256,
) -> felt252 {
    start_cheat_caller_address(world.runs.contract_address, who);
    let id = world.runs.commit_run(VERSION_ID, LEVEL_ID, packed.span(), tics, bounty);
    stop_cheat_caller_address(world.runs.contract_address);
    id
}

/// Registers the batch's fact (as if the router had verified it) and has `by` submit one
/// member — the prover's transaction.
fn prove(
    world: World,
    by: ContractAddress,
    leaves: Array<LeafOutput>,
    member: Member,
    replay: Array<ReplayLog>,
) -> bool {
    world.registry.register(world.runs.batch_fact(VERSION_ID, leaves.clone()));
    start_cheat_caller_address(world.runs.contract_address, by);
    let accepted = world.runs.register_member(VERSION_ID, leaves, member, replay);
    stop_cheat_caller_address(world.runs.contract_address);
    accepted
}

fn balance(world: World, who: ContractAddress) -> u256 {
    world.token.balance_of(who)
}

/// Moves the block number to the commitment's `expires_at`, and returns it.
fn expire(world: World, id: felt252) -> u64 {
    let expires_at = world.runs.get_commitment(id).expires_at;
    start_cheat_block_number(world.runs.contract_address, expires_at);
    expires_at
}

/// The third game of the synthetic batch (leaves 3..6, three 35-tic segments, player 3): its
/// per-segment logs as replay data, and the whole run's packed log — their concatenation,
/// since every segment spans a multiple of 7 tics.
fn game3_replay() -> Array<ReplayLog> {
    let all = fixtures::batch_logs();
    array![
        ReplayLog { leaf_index: 3, packed: all.at(3).clone() },
        ReplayLog { leaf_index: 4, packed: all.at(4).clone() },
        ReplayLog { leaf_index: 5, packed: all.at(5).clone() },
    ]
}

fn game3_packed() -> Array<felt252> {
    let all = fixtures::batch_logs();
    let mut packed = array![];
    let mut i = 3;
    while i != 6 {
        for w in all.at(i).span() {
            packed.append(*w);
        }
        i += 1;
    }
    packed
}

fn game3_run_id() -> felt252 {
    let (_, _, run_id) = *fixtures::batch_members().at(2);
    run_id
}

/// The `reason` of the last `MemberRejected` event.
fn last_reason(ref spy: EventSpy) -> felt252 {
    let events = spy.get_events().events;
    let events = events.span();
    let (_, event) = events.at(events.len() - 1);
    *event.data.span().at(0)
}

// -- committing --------------------------------------------------------------

/// The commitment is recorded, the bounty escrowed, and the whole log published with it.
#[test]
fn commit_run_records_escrows_and_publishes_the_log() {
    let world = setup();
    let mut spy = spy_events();
    let id = commit(world, player(1), fixtures::single_log(), 35, BOUNTY);

    let expected_commitment = commit_log(fixtures::single_log().span());
    assert_eq!(id, commitment_id_of(VERSION_ID, LEVEL_ID, player(1), expected_commitment));
    assert_eq!(
        id,
        core::poseidon::poseidon_hash_span(
            array![
                TAG_COMMIT, VERSION_ID.into(), LEVEL_ID.into(), player(1).into(),
                expected_commitment,
            ]
                .span(),
        ),
    );

    let c = world.runs.get_commitment(id);
    assert_eq!(c.player, player(1));
    assert_eq!(c.version_id, VERSION_ID);
    assert_eq!(c.level_id, LEVEL_ID);
    assert_eq!(c.genesis, fixtures::GENESIS);
    assert_eq!(c.inputs_commitment, expected_commitment);
    assert_eq!(c.tics, 35);
    assert_eq!(c.bounty, BOUNTY);
    assert_eq!(c.expires_at, c.created_block + EXPIRY);
    assert_eq!(c.status, commit_status::PENDING);
    assert_eq!(c.run_id, 0);
    assert_eq!(c.prover, 0.try_into().unwrap());
    assert_eq!(world.runs.commitment_of(VERSION_ID, LEVEL_ID, player(1), expected_commitment), c);
    assert_eq!(world.runs.commitment_count(), 1);
    assert_eq!(world.runs.fee_token(), world.token.contract_address);
    assert_eq!(world.runs.expiry_blocks(), EXPIRY);

    assert_eq!(balance(world, player(1)), FUNDS - BOUNTY);
    assert_eq!(balance(world, world.runs.contract_address), BOUNTY);

    spy
        .assert_emitted(
            @array![
                (
                    world.runs.contract_address,
                    Event::RunCommitted(
                        RunCommitted {
                            commitment_id: id,
                            player: player(1),
                            version_id: VERSION_ID,
                            level_id: LEVEL_ID,
                            genesis: fixtures::GENESIS,
                            inputs_commitment: expected_commitment,
                            tics: 35,
                            bounty: BOUNTY,
                            expires_at: c.expires_at,
                            n_chunks: 1,
                        },
                    ),
                ),
                (
                    world.runs.contract_address,
                    Event::RunLog(
                        RunLog {
                            commitment_id: id,
                            chunk: 0,
                            offset: 0,
                            packed: fixtures::single_log().span(),
                        },
                    ),
                ),
            ],
        );
}

#[test]
#[should_panic(expected: 'doomruns: commitment exists')]
fn a_pending_commitment_cannot_be_committed_again() {
    let world = setup();
    commit(world, player(1), fixtures::single_log(), 35, BOUNTY);
    commit(world, player(1), fixtures::single_log(), 35, 0);
}

/// Five felts encode 29..35 tics; 36 tics would need six.
#[test]
#[should_panic(expected: 'doomruns: packed length')]
fn a_packed_log_of_the_wrong_length_is_refused() {
    let world = setup();
    assert_eq!(packed_len(36), 6);
    commit(world, player(1), fixtures::single_log(), 36, BOUNTY);
}

#[test]
#[should_panic(expected: 'doomruns: empty run')]
fn an_empty_run_cannot_be_committed() {
    let world = setup();
    commit(world, player(1), array![], 0, 0);
}

#[test]
#[should_panic(expected: 'doomruns: unknown level')]
fn an_unpinned_level_cannot_be_committed() {
    let world = setup();
    start_cheat_caller_address(world.runs.contract_address, player(1));
    world.runs.commit_run(VERSION_ID, 42, fixtures::single_log().span(), 35, 0);
}

/// The escrow is a `transfer_from`: no allowance, no commitment.
#[test]
#[should_panic(expected: 'mock: allowance')]
fn a_bounty_needs_an_allowance() {
    let world = setup();
    world.token.mint(player(2), FUNDS);
    commit(world, player(2), fixtures::single_log(), 35, BOUNTY);
}

/// `expiry_blocks = 0` would let a player reclaim in the block a prover submits.
#[test]
fn a_zero_expiry_is_refused_at_deployment() {
    let runs_class = declare("DoomRuns").unwrap().contract_class();
    let token: ContractAddress = 0xFEE.try_into().unwrap();
    assert!(runs_class.deploy(@array![owner().into(), token.into(), 0]).is_err());
    assert!(runs_class.deploy(@array![owner().into(), token.into(), 1]).is_ok());
}

// -- proving -----------------------------------------------------------------

/// Anyone submits the proved run; the bounty goes to that caller, not to the player.
#[test]
fn a_third_party_prover_earns_the_bounty() {
    let world = setup();
    let id = commit(world, player(1), fixtures::single_log(), 35, BOUNTY);
    let mut spy = spy_events();
    assert!(prove(world, prover(1), fixtures::single_leaf(), member(1, 0, 1), array![]));

    let c = world.runs.get_commitment(id);
    assert_eq!(c.status, commit_status::PROVED);
    assert_eq!(c.run_id, fixtures::SINGLE_RUN_ID);
    assert_eq!(c.prover, prover(1));
    assert!(world.runs.is_run_registered(fixtures::SINGLE_RUN_ID));
    assert_eq!(world.runs.get_run(fixtures::SINGLE_RUN_ID).player, player(1));

    assert_eq!(balance(world, prover(1)), BOUNTY);
    assert_eq!(balance(world, world.runs.contract_address), 0);
    assert_eq!(balance(world, player(1)), FUNDS - BOUNTY);

    spy
        .assert_emitted(
            @array![
                (
                    world.runs.contract_address,
                    Event::CommitmentProved(
                        CommitmentProved {
                            commitment_id: id,
                            run_id: fixtures::SINGLE_RUN_ID,
                            prover: prover(1),
                            player: player(1),
                            bounty: BOUNTY,
                        },
                    ),
                ),
            ],
        );
    assert_eq!(world.runs.pending_commitments(0, 10), (array![], 1));
}

/// A run of several segments is bound to its commitment through the replay logs: their
/// concatenation is the committed log.
#[test]
fn a_multi_segment_run_settles_through_its_replay_logs() {
    let world = setup();
    world.token.mint(player(3), FUNDS);
    start_cheat_caller_address(world.token.contract_address, player(3));
    world.token.approve(world.runs.contract_address, FUNDS);
    stop_cheat_caller_address(world.token.contract_address);
    let packed = game3_packed();
    assert_eq!(packed.len(), packed_len(105));
    let id = commit(world, player(3), packed, 105, BOUNTY);

    assert!(prove(world, prover(2), fixtures::batch_leaves(), member(3, 3, 3), game3_replay()));
    let c = world.runs.get_commitment(id);
    assert_eq!(c.status, commit_status::PROVED);
    assert_eq!(c.run_id, game3_run_id());
    assert_eq!(c.prover, prover(2));
    assert_eq!(world.runs.get_run(game3_run_id()).n_segments, 3);
    assert_eq!(balance(world, prover(2)), BOUNTY);
}

/// Without the replay logs the contract cannot relate the per-segment commitments to the
/// committed log: the run is recorded as before D35, the commitment stays pending.
#[test]
fn a_multi_segment_run_without_replay_is_recorded_but_settles_nothing() {
    let world = setup();
    let id = commit(world, player(3), game3_packed(), 105, 0);
    assert!(prove(world, prover(2), fixtures::batch_leaves(), member(3, 3, 3), array![]));
    assert!(world.runs.is_run_registered(game3_run_id()));
    assert_eq!(world.runs.get_commitment(id).status, commit_status::PENDING);
    assert_eq!(balance(world, prover(2)), 0);
}

/// A member whose inputs are not the committed ones is accepted as a run and settles nothing:
/// no link, no bounty.
#[test]
fn a_run_with_other_inputs_settles_nothing() {
    let world = setup();
    let id = commit(world, player(1), fixtures::nine_tic_log(), 9, BOUNTY);
    assert!(prove(world, prover(1), fixtures::single_leaf(), member(1, 0, 1), array![]));
    assert!(world.runs.is_run_registered(fixtures::SINGLE_RUN_ID));
    let c = world.runs.get_commitment(id);
    assert_eq!(c.status, commit_status::PENDING);
    assert_eq!(c.run_id, 0);
    assert_eq!(balance(world, prover(1)), 0);
    assert_eq!(balance(world, world.runs.contract_address), BOUNTY);
}

/// The same log committed with another tic count (five felts also encode 34 tics) is another
/// game: the 35-tic run does not settle it.
#[test]
fn a_commitment_with_another_tic_count_settles_nothing() {
    let world = setup();
    let id = commit(world, player(1), fixtures::single_log(), 34, BOUNTY);
    assert!(prove(world, prover(1), fixtures::single_leaf(), member(1, 0, 1), array![]));
    assert_eq!(world.runs.get_commitment(id).status, commit_status::PENDING);
    assert_eq!(balance(world, prover(1)), 0);
}

/// The same inputs committed by another player are another commitment: a run recorded for
/// player 1 leaves player 2's commitment pending.
#[test]
fn another_players_commitment_is_not_settled() {
    let world = setup();
    let id = commit(world, player(2), fixtures::single_log(), 35, 0);
    assert!(prove(world, prover(1), fixtures::single_leaf(), member(1, 0, 1), array![]));
    assert_eq!(world.runs.get_commitment(id).status, commit_status::PENDING);
}

/// Once settled, a commitment is settled: the run is registered (R10-A1), so a second
/// submission is rejected and pays nobody, and the commitment cannot be re-created.
#[test]
fn a_commitment_is_settled_once() {
    let world = setup();
    let id = commit(world, player(1), fixtures::single_log(), 35, BOUNTY);
    assert!(prove(world, prover(1), fixtures::single_leaf(), member(1, 0, 1), array![]));
    let mut spy = spy_events();
    assert!(!prove(world, prover(2), fixtures::single_leaf(), member(1, 0, 1), array![]));
    assert_eq!(last_reason(ref spy), reason::REPLAYED);
    assert_eq!(balance(world, prover(1)), BOUNTY);
    assert_eq!(balance(world, prover(2)), 0);
    let c = world.runs.get_commitment(id);
    assert_eq!(c.status, commit_status::PROVED);
    assert_eq!(c.prover, prover(1));
}

#[test]
#[should_panic(expected: 'doomruns: commitment exists')]
fn a_proved_commitment_cannot_be_committed_again() {
    let world = setup();
    commit(world, player(1), fixtures::single_log(), 35, BOUNTY);
    assert!(prove(world, prover(1), fixtures::single_leaf(), member(1, 0, 1), array![]));
    commit(world, player(1), fixtures::single_log(), 35, BOUNTY);
}

/// A zero bounty is a plain publication: settled, no token call.
#[test]
fn a_zero_bounty_commitment_is_settled_without_transfer() {
    let world = setup();
    let id = commit(world, player(1), fixtures::single_log(), 35, 0);
    assert_eq!(balance(world, player(1)), FUNDS);
    assert!(prove(world, prover(1), fixtures::single_leaf(), member(1, 0, 1), array![]));
    let c = world.runs.get_commitment(id);
    assert_eq!(c.status, commit_status::PROVED);
    assert_eq!(c.bounty, 0);
    assert_eq!(balance(world, prover(1)), 0);
    assert_eq!(balance(world, world.runs.contract_address), 0);
}

// -- reclaiming --------------------------------------------------------------

#[test]
#[should_panic(expected: 'doomruns: not expired')]
fn reclaim_before_expiry_is_refused() {
    let world = setup();
    let id = commit(world, player(1), fixtures::single_log(), 35, BOUNTY);
    let created = world.runs.get_commitment(id).created_block;
    start_cheat_block_number(world.runs.contract_address, created + EXPIRY - 1);
    start_cheat_caller_address(world.runs.contract_address, player(1));
    world.runs.reclaim(id);
}

#[test]
fn reclaim_after_expiry_refunds_the_bounty() {
    let world = setup();
    let id = commit(world, player(1), fixtures::single_log(), 35, BOUNTY);
    let created = world.runs.get_commitment(id).created_block;
    let mut spy = spy_events();
    start_cheat_block_number(world.runs.contract_address, created + EXPIRY);
    start_cheat_caller_address(world.runs.contract_address, player(1));
    world.runs.reclaim(id);
    stop_cheat_caller_address(world.runs.contract_address);

    let c = world.runs.get_commitment(id);
    assert_eq!(c.status, commit_status::RECLAIMED);
    assert_eq!(balance(world, player(1)), FUNDS);
    assert_eq!(balance(world, world.runs.contract_address), 0);
    spy
        .assert_emitted(
            @array![
                (
                    world.runs.contract_address,
                    Event::CommitmentReclaimed(
                        CommitmentReclaimed {
                            commitment_id: id, player: player(1), bounty: BOUNTY,
                        },
                    ),
                ),
            ],
        );
    assert_eq!(world.runs.pending_commitments(0, 10), (array![], 1));

    // A proof that lands afterwards records the run but earns nothing.
    assert!(prove(world, prover(1), fixtures::single_leaf(), member(1, 0, 1), array![]));
    assert_eq!(world.runs.get_commitment(id).status, commit_status::RECLAIMED);
    assert_eq!(balance(world, prover(1)), 0);
}

#[test]
#[should_panic(expected: 'doomruns: not player')]
fn only_the_player_can_reclaim() {
    let world = setup();
    let id = commit(world, player(1), fixtures::single_log(), 35, BOUNTY);
    expire(world, id);
    start_cheat_caller_address(world.runs.contract_address, prover(1));
    world.runs.reclaim(id);
}

#[test]
#[should_panic(expected: 'doomruns: not pending')]
fn a_settled_commitment_cannot_be_reclaimed() {
    let world = setup();
    let id = commit(world, player(1), fixtures::single_log(), 35, BOUNTY);
    assert!(prove(world, prover(1), fixtures::single_leaf(), member(1, 0, 1), array![]));
    expire(world, id);
    start_cheat_caller_address(world.runs.contract_address, player(1));
    world.runs.reclaim(id);
}

#[test]
#[should_panic(expected: 'doomruns: not pending')]
fn an_unknown_commitment_cannot_be_reclaimed() {
    let world = setup();
    start_cheat_caller_address(world.runs.contract_address, player(1));
    world.runs.reclaim(0x1234);
}

/// `freeze` pins the version table; it does not touch the escrows.
#[test]
fn a_frozen_table_keeps_reclaim_open() {
    let world = setup();
    let id = commit(world, player(1), fixtures::single_log(), 35, BOUNTY);
    start_cheat_caller_address(world.runs.contract_address, owner());
    world.runs.freeze();
    stop_cheat_caller_address(world.runs.contract_address);
    assert!(world.runs.is_frozen());

    expire(world, id);
    start_cheat_caller_address(world.runs.contract_address, player(1));
    world.runs.reclaim(id);
    stop_cheat_caller_address(world.runs.contract_address);
    assert_eq!(world.runs.get_commitment(id).status, commit_status::RECLAIMED);
    assert_eq!(balance(world, player(1)), FUNDS);

    // ... nor does it close `commit_run`.
    let again = commit(world, player(1), fixtures::nine_tic_log(), 9, BOUNTY);
    assert_eq!(world.runs.get_commitment(again).status, commit_status::PENDING);
}

/// A reclaimed commitment may be posted again (a new escrow, a new expiry, a new index entry).
#[test]
fn a_reclaimed_commitment_can_be_committed_again() {
    let world = setup();
    let id = commit(world, player(1), fixtures::single_log(), 35, BOUNTY);
    let now = expire(world, id);
    start_cheat_caller_address(world.runs.contract_address, player(1));
    world.runs.reclaim(id);
    stop_cheat_caller_address(world.runs.contract_address);

    let again = commit(world, player(1), fixtures::single_log(), 35, BOUNTY * 2);
    assert_eq!(again, id);
    let c = world.runs.get_commitment(id);
    assert_eq!(c.status, commit_status::PENDING);
    assert_eq!(c.bounty, BOUNTY * 2);
    assert_eq!(c.created_block, now);
    assert_eq!(c.expires_at, now + EXPIRY);
    assert_eq!(world.runs.commitment_count(), 2);
    assert_eq!(world.runs.pending_commitments(0, 10), (array![id], 2));
    assert_eq!(balance(world, world.runs.contract_address), BOUNTY * 2);

    assert!(prove(world, prover(1), fixtures::single_leaf(), member(1, 0, 1), array![]));
    assert_eq!(balance(world, prover(1)), BOUNTY * 2);
}

// -- enumeration -------------------------------------------------------------

/// A prover node walks the append-only index from its last cursor and gets the ids still
/// pending; the logs are in the events.
#[test]
fn pending_commitments_walks_the_index() {
    let world = setup();
    let a = commit(world, player(1), fixtures::single_log(), 35, 0);
    let b = commit(world, player(1), fixtures::nine_tic_log(), 9, 0);
    let c = commit(world, player(2), fixtures::single_log(), 35, 0);
    assert_eq!(world.runs.commitment_count(), 3);
    assert_eq!(world.runs.pending_commitments(0, 10), (array![a, b, c], 3));
    assert_eq!(world.runs.pending_commitments(0, 2), (array![a, b], 2));
    assert_eq!(world.runs.pending_commitments(2, 2), (array![c], 3));
    assert_eq!(world.runs.pending_commitments(3, 2), (array![], 3));
    assert_eq!(world.runs.pending_commitments(7, 2), (array![], 3));

    assert!(prove(world, prover(1), fixtures::single_leaf(), member(1, 0, 1), array![]));
    assert_eq!(world.runs.pending_commitments(0, 10), (array![b, c], 3));
}

// -- cost --------------------------------------------------------------------

/// A three-minute game's log: 6 300 tics, 900 felts (synthetic words — `commit_run` does not
/// decode them).
const THREE_MINUTES: u32 = 6_300;
fn three_minute_log() -> Array<felt252> {
    let mut packed = array![];
    let mut i: felt252 = 0;
    while i != 900 {
        packed.append(0x1000 + i);
        i += 1;
    }
    packed
}

/// Cost probes (`snforge test cost_probe --detailed-resources`): the difference between the
/// two is one `commit_run` of a 900-felt log with a bounty — 900 Poseidon folds, the
/// storage writes, five events and the escrow's `transfer_from`.
#[test]
fn cost_probe_setup_only() {
    let world = setup();
    assert_eq!(world.runs.commitment_count(), 0);
}

#[test]
fn cost_probe_setup_and_commit_run_of_900_felts() {
    let world = setup();
    commit(world, player(1), three_minute_log(), THREE_MINUTES, BOUNTY);
    assert_eq!(world.runs.commitment_count(), 1);
}

/// A three-minute game is published in four `RunLog` chunks.
#[test]
fn a_three_minute_log_is_published_in_four_chunks() {
    let world = setup();
    let tics = THREE_MINUTES;
    let packed = three_minute_log();
    assert_eq!(packed.len(), packed_len(tics));
    let mut spy = spy_events();
    let id = commit(world, player(1), packed.clone(), tics, BOUNTY);

    let c = world.runs.get_commitment(id);
    assert_eq!(c.tics, tics);
    assert_eq!(c.inputs_commitment, commit_log(packed.span()));

    let mut chunks = array![];
    let mut offset = 0;
    let mut chunk = 0;
    while offset != 900 {
        let len = core::cmp::min(LOG_CHUNK, 900 - offset);
        chunks
            .append(
                (
                    world.runs.contract_address,
                    Event::RunLog(
                        RunLog {
                            commitment_id: id,
                            chunk,
                            offset,
                            packed: packed.span().slice(offset, len),
                        },
                    ),
                ),
            );
        offset += len;
        chunk += 1;
    }
    assert_eq!(chunks.len(), 4);
    spy.assert_emitted(@chunks);
    // RunCommitted + 4 RunLog + the token's own events, if any.
    assert!(spy.get_events().events.len() >= 5);
}

/// A single-segment run is the base case of the run-level commitment: the leaf's own
/// `inputs_commitment` *is* `commit_log` of the run's log.
#[test]
fn the_single_segment_commitment_is_the_leaf_commitment() {
    let leaf = *fixtures::single_leaf().at(0);
    assert_eq!(leaf.status, STATUS_EXIT);
    assert_eq!(commit_log(fixtures::single_log().span()), leaf.inputs_commitment);
}
