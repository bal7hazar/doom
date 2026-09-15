// SPDX-License-Identifier: Apache-2.0
//! `DoomRuns` on the **proved** batches of P4.2b.
//!
//! `test_doom_runs.cairo` exercises every rule on synthetic leaves built by the Python model.
//! What it could not do until now is bind the contract to a root that was actually proved with
//! the ten-felt layout: the S4 spike's `segment_stub` returned four felts, so the only real
//! roots available carried leaves `DoomRuns` cannot read (`docs/design/doomruns.md`, the first
//! of the two limitations this file closes).
//!
//! The leaves below come from `spikes/s4/programs/segment_stub10` through `leaf-prover` and
//! `stwo_run_and_prove_recursive_tree`; `fixtures_real::*_output_hash()` is what
//! `stwo_circuit_verifier` returned for the root proof, and `*_FACT` is the fact
//! `StwoCircuitRouter` registered for it on devnet
//! (`results/e2e_10felt_receipts.json`). Nothing here is invented: the only thing these tests
//! add is the registry that answers `is_valid`, because registering the fact for real costs
//! 3.81e9 L2 gas and is measured by the devnet drive instead.
//!
//! What is therefore proved end to end by the pair (this file + the drive): the ten felts a
//! client sends recompose to the `output_hash` of a proof the on-chain verifier accepted, and
//! the fact that recomposition produces is the one the router holds.
use doom_runs::doom_runs::{
    IDoomRunsDispatcher, IDoomRunsDispatcherTrait, KIND_SCORE, KIND_TIME, Member, ReplayLog,
    Version, compute_fact, digest_of, score_of,
};
use doom_runs::mock_registry::MockFactRegistry::{
    IMockFactRegistryDispatcher, IMockFactRegistryDispatcherTrait,
};
use doom_runs::segment::{
    LeafOutput, STATUS_EXIT, STATUS_RUNNING, commit_log, packed_len, to_preimage,
};
use recursion_outputs::tree::root_output_hash;
use snforge_std::{
    ContractClassTrait, DeclareResultTrait, declare, start_cheat_caller_address,
    stop_cheat_caller_address,
};
use starknet::ContractAddress;
use crate::fixtures_real;

const VERSION_ID: u32 = 1;
const LEVEL_ID: u32 = 1;

fn owner() -> ContractAddress {
    0x0FF1CE.try_into().unwrap()
}

fn player(n: felt252) -> ContractAddress {
    (0x1000 + n).try_into().unwrap()
}

/// One proved batch, as the fixtures carry it.
#[derive(Drop, Clone)]
struct Proved {
    leaves: Array<LeafOutput>,
    members: Array<(u32, u32, u32, felt252)>,
    logs: Array<Array<felt252>>,
    leaf_circuit_hash: [u32; 8],
    multiverifier_hash: [u32; 8],
    output_hash: [u32; 8],
    program_hash: felt252,
    genesis: felt252,
    fact: felt252,
}

/// `B2_doom`: one game of two segments (160 + 137 tics), registry `doom`.
fn b2() -> Proved {
    Proved {
        leaves: fixtures_real::b2_doom_leaves(),
        members: fixtures_real::b2_doom_members(),
        logs: fixtures_real::b2_doom_logs(),
        leaf_circuit_hash: fixtures_real::b2_doom_leaf_circuit_hash(),
        multiverifier_hash: fixtures_real::b2_doom_multiverifier_hash(),
        output_hash: fixtures_real::b2_doom_output_hash(),
        program_hash: fixtures_real::B2_DOOM_PROGRAM_HASH,
        genesis: fixtures_real::B2_DOOM_GENESIS,
        fact: fixtures_real::B2_DOOM_FACT,
    }
}

/// `B2-1_doom`: two games in one batch (2 + 1 segments) — the shape a wrapper submits.
fn b2_1() -> Proved {
    Proved {
        leaves: fixtures_real::b2_1_doom_leaves(),
        members: fixtures_real::b2_1_doom_members(),
        logs: fixtures_real::b2_1_doom_logs(),
        leaf_circuit_hash: fixtures_real::b2_1_doom_leaf_circuit_hash(),
        multiverifier_hash: fixtures_real::b2_1_doom_multiverifier_hash(),
        output_hash: fixtures_real::b2_1_doom_output_hash(),
        program_hash: fixtures_real::B2_1_DOOM_PROGRAM_HASH,
        genesis: fixtures_real::B2_1_DOOM_GENESIS,
        fact: fixtures_real::B2_1_DOOM_FACT,
    }
}

#[derive(Drop, Copy)]
struct World {
    runs: IDoomRunsDispatcher,
    registry: IMockFactRegistryDispatcher,
}

/// Deploys the pair and pins the version of the proved batch: its program hash, the two circuit
/// hashes of the `doom` registry and the genesis its first segment started from.
fn setup(batch: @Proved) -> World {
    let registry_class = declare("MockFactRegistry").unwrap().contract_class();
    let (registry_address, _) = registry_class.deploy(@array![]).unwrap();
    let runs_class = declare("DoomRuns").unwrap().contract_class();
    // D35: a fee token (unused here — no bounty is ever escrowed) and an expiry.
    let fee_token: ContractAddress = 0xFEE.try_into().unwrap();
    let (runs_address, _) = runs_class
        .deploy(@array![owner().into(), fee_token.into(), 100])
        .unwrap();
    let world = World {
        runs: IDoomRunsDispatcher { contract_address: runs_address },
        registry: IMockFactRegistryDispatcher { contract_address: registry_address },
    };
    start_cheat_caller_address(runs_address, owner());
    world
        .runs
        .add_version(
            VERSION_ID,
            Version {
                program_hash: *batch.program_hash,
                program_hash_function: 'blake',
                leaf_circuit_hash: digest_of(*batch.leaf_circuit_hash),
                multiverifier_hash: digest_of(*batch.multiverifier_hash),
                registry_name: 'doom',
                verifier_router: registry_address,
            },
        );
    world.runs.set_genesis(VERSION_ID, LEVEL_ID, *batch.genesis);
    stop_cheat_caller_address(runs_address);
    world
}

fn members_of(batch: @Proved) -> Array<Member> {
    let mut out = array![];
    let mut i = 0;
    while i != batch.members.len() {
        let (leaf_start, leaf_len, level_id, _) = *batch.members.at(i);
        out.append(Member { player: player((i + 1).into()), level_id, leaf_start, leaf_len });
        i += 1;
    }
    out
}

fn replay_of(batch: @Proved) -> Array<ReplayLog> {
    let mut out = array![];
    let mut i = 0;
    while i != batch.logs.len() {
        out.append(ReplayLog { leaf_index: i, packed: batch.logs.at(i).clone() });
        i += 1;
    }
    out
}

/// The batch's recomposed `output_hash`, from the ten felts alone.
fn recompose(batch: @Proved) -> [u32; 8] {
    let mut preimages = array![];
    for leaf in batch.leaves.span() {
        preimages.append(to_preimage(*batch.program_hash, leaf));
    }
    let mut spans = array![];
    for p in preimages.span() {
        spans.append(p.span());
    }
    root_output_hash(spans.span(), *batch.leaf_circuit_hash, *batch.multiverifier_hash)
}

// -- the recomposition, against the on-chain verifier's own answer ------------

/// The ten public felts of each segment, folded the way the recursive tree folds them, give
/// back the `output_hash` `stwo_circuit_verifier` printed for the root proof — and therefore
/// the fact the router registered.
#[test]
fn real_root_recomposes_to_the_verifier_output_hash() {
    for batch in array![b2(), b2_1()] {
        assert_eq!(recompose(@batch), batch.output_hash);
        assert_eq!(compute_fact(batch.multiverifier_hash, batch.output_hash), batch.fact);
    }
}

/// ... and the contract's own view agrees, so a client can check the registry before paying.
#[test]
fn real_root_batch_fact_view_matches() {
    for batch in array![b2(), b2_1()] {
        let world = setup(@batch);
        assert_eq!(world.runs.batch_fact(VERSION_ID, batch.leaves.clone()), batch.fact);
    }
}

/// The two proved batches are different batches: the second one shares its first game with the
/// first, and still recomposes to another fact, because a batch's fact covers *all* its leaves.
#[test]
fn the_two_real_batches_have_different_facts() {
    assert!(b2().fact != b2_1().fact);
}

// -- the input-log commitments, as the proved program computed them ----------

/// `segment::commit_log` — the contract's port of `state_hash::commit_input` — folds the packed
/// log of each proved segment to the `inputs_commitment` that segment's **Cairo program**
/// computed and the proof committed to, and the log has exactly the length the tic span
/// implies. This is the replay publication path (D13/R10-A3) on data neither side invented.
#[test]
fn real_logs_fold_to_the_proved_commitments() {
    for batch in array![b2(), b2_1()] {
        let mut i = 0;
        while i != batch.leaves.len() {
            let leaf = *batch.leaves.at(i);
            let log = batch.logs.at(i);
            assert_eq!(log.len(), packed_len(leaf.tic_end - leaf.tic_start));
            assert_eq!(commit_log(log.span()), leaf.inputs_commitment);
            i += 1;
        }
    }
}

/// The chain rules of D14 hold on the proved leaves themselves: one genesis, contiguous tics,
/// `h_out[i] == h_in[i+1]`, `RUNNING` until the last segment of a game, `EXIT` on it.
#[test]
fn real_leaves_satisfy_the_continuity_rules() {
    for batch in array![b2(), b2_1()] {
        let mut m = 0;
        while m != batch.members.len() {
            let (start, len, _, _) = *batch.members.at(m);
            let first = *batch.leaves.at(start);
            assert_eq!(first.h_in, batch.genesis);
            assert_eq!(first.tic_start, 0);
            let mut i = 0;
            while i != len {
                let leaf = *batch.leaves.at(start + i);
                assert_eq!(leaf.version, 1);
                assert!(leaf.tic_end > leaf.tic_start);
                if i + 1 == len {
                    assert_eq!(leaf.status, STATUS_EXIT);
                } else {
                    assert_eq!(leaf.status, STATUS_RUNNING);
                    let next = *batch.leaves.at(start + i + 1);
                    assert_eq!(leaf.h_out, next.h_in);
                    assert_eq!(leaf.tic_end, next.tic_start);
                }
                i += 1;
            }
            m += 1;
        }
    }
}

// -- the whole gate, on the real fact ----------------------------------------

/// The two-game proved batch, submitted with its input logs: the fact gate passes on the real
/// fact, both members validate, and the records carry the proved counters.
#[test]
fn real_two_game_batch_is_recorded() {
    let batch = b2_1();
    let world = setup(@batch);
    world.registry.register(batch.fact);
    let accepted = world
        .runs
        .submit_batch(VERSION_ID, batch.leaves.clone(), members_of(@batch), replay_of(@batch));
    assert_eq!(accepted, 2);

    let mut i = 0;
    while i != batch.members.len() {
        let (start, len, level_id, run_id) = *batch.members.at(i);
        let last = *batch.leaves.at(start + len - 1);
        assert!(world.runs.is_run_registered(run_id), "member {} registered", i);
        // The id a client computes off chain is the one the contract stored.
        let mut own = array![];
        let mut k = 0;
        while k != len {
            own.append(*batch.leaves.at(start + k));
            k += 1;
        }
        assert_eq!(world.runs.run_id_of(VERSION_ID, level_id, own), run_id);

        let run = world.runs.get_run(run_id);
        assert_eq!(run.player, player((i + 1).into()));
        assert_eq!(run.version_id, VERSION_ID);
        assert_eq!(run.level_id, level_id);
        assert_eq!(run.n_segments, len);
        assert_eq!(run.status, STATUS_EXIT);
        assert_eq!(run.fact, batch.fact);
        assert_eq!(run.tics, last.tic_end);
        assert_eq!(run.kills, last.kills);
        assert_eq!(run.items, last.items);
        assert_eq!(run.secrets, last.secrets);
        assert_eq!(run.score, score_of(last.kills, last.items, last.secrets));
        assert_eq!(world.runs.player_runs(player((i + 1).into()), 0, 10), array![run_id]);
        i += 1;
    }

    // Two boards, the three-segment game first on score, the one-segment game first on time.
    let (_, _, _, game0) = *batch.members.at(0);
    let (_, _, _, game1) = *batch.members.at(1);
    assert_eq!(world.runs.leaderboard_len(VERSION_ID, KIND_SCORE), 2);
    let board = world.runs.leaderboard(VERSION_ID, KIND_SCORE, 0, 10);
    assert_eq!(*board.at(0).run_id, game0);
    assert_eq!(*board.at(1).run_id, game1);
    let by_time = world.runs.leaderboard(VERSION_ID, KIND_TIME, 0, 10);
    assert_eq!(*by_time.at(0).run_id, game1);
    assert_eq!(*by_time.at(1).run_id, game0);
}

/// The single-game proved batch, without replay publication.
#[test]
fn real_single_game_batch_is_recorded() {
    let batch = b2();
    let world = setup(@batch);
    world.registry.register(batch.fact);
    assert_eq!(
        world.runs.submit_batch(VERSION_ID, batch.leaves.clone(), members_of(@batch), array![]), 1,
    );
    let (start, len, _, run_id) = *batch.members.at(0);
    let last = *batch.leaves.at(start + len - 1);
    let run = world.runs.get_run(run_id);
    assert_eq!(run.n_segments, len);
    assert_eq!(run.tics, last.tic_end);
    assert_eq!(run.kills, last.kills);
}

/// One extra kill on the proved last segment: the leaf output changes, so the blake2s fold
/// changes, so the recomposed fact is not the one the router registered — and the whole call
/// reverts rather than recording an inflated score.
#[test]
#[should_panic(expected: 'doomruns: fact not registered')]
fn real_root_with_one_extra_kill_is_refused() {
    let batch = b2_1();
    let world = setup(@batch);
    world.registry.register(batch.fact);
    let mut tampered = array![];
    let mut i = 0;
    while i != batch.leaves.len() {
        let leaf = *batch.leaves.at(i);
        tampered
            .append(
                if i + 1 == batch.leaves.len() {
                    LeafOutput { kills: leaf.kills + 1, ..leaf }
                } else {
                    leaf
                },
            );
        i += 1;
    }
    world.runs.submit_batch(VERSION_ID, tampered, members_of(@batch), array![]);
}

/// The same two games in the other order recompose to another fact: the fold order *is* the
/// leaves array (`docs/design/doomruns.md` §2), so a reordered batch cannot borrow this one's
/// verification.
#[test]
#[should_panic(expected: 'doomruns: fact not registered')]
fn real_leaves_in_another_order_are_refused() {
    let batch = b2_1();
    let world = setup(@batch);
    world.registry.register(batch.fact);
    let leaves = batch.leaves.span();
    let reordered = array![*leaves.at(2), *leaves.at(0), *leaves.at(1)];
    let members = array![
        Member { player: player(1), level_id: LEVEL_ID, leaf_start: 1, leaf_len: 2 },
        Member { player: player(2), level_id: LEVEL_ID, leaf_start: 0, leaf_len: 1 },
    ];
    world.runs.submit_batch(VERSION_ID, reordered, members, array![]);
}

/// A published log that is not the one the proof consumed is caught by the commitment, even
/// though the leaves — and therefore the fact — are untouched.
#[test]
fn a_wrong_replay_log_is_rejected_on_the_real_batch() {
    let batch = b2();
    let world = setup(@batch);
    world.registry.register(batch.fact);
    let mut bad = array![];
    let mut i = 0;
    while i != batch.logs.len() {
        let mut log = batch.logs.at(i).clone();
        if i == 0 {
            let mut patched = array![*log.at(0) + 1];
            let mut k = 1;
            while k != log.len() {
                patched.append(*log.at(k));
                k += 1;
            }
            log = patched;
        }
        bad.append(ReplayLog { leaf_index: i, packed: log });
        i += 1;
    }
    assert_eq!(
        world.runs.submit_batch(VERSION_ID, batch.leaves.clone(), members_of(@batch), bad), 0,
    );
    let (_, _, _, run_id) = *batch.members.at(0);
    assert!(!world.runs.is_run_registered(run_id));
}
