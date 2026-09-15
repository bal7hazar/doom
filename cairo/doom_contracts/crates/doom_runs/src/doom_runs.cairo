// SPDX-License-Identifier: Apache-2.0
//! `DoomRuns` — the consumer contract of the Stwo fact registry.
//!
//! One fact covers a **batch** of games (D6/D18): the wrapper folds every segment of every game
//! in the batch into one recursive tree, P4.0's router verifies the root proof in 5–6
//! transactions and registers `fact = poseidon(circuit_hash ‖ output_hash)`. This contract is
//! the other half: it recomputes that `output_hash` from the leaves' public outputs, asks the
//! router whether the fact exists, and then validates **each game independently** before
//! recording it.
//!
//! Full specification, rules and gas table: `docs/design/doomruns.md`. Design of the fact and
//! of the consumer interface: `docs/design/onchain-verifier.md` §6.
//!
//! **Open prover (D35).** Proving is not the player's job: the player *commits* a played game
//! (`commit_run`: the whole packed input log, published by events, plus an escrowed bounty in
//! the fee token), and any address may execute that log, prove it, fold it and submit the
//! resulting batch. A member whose run matches a pending commitment — same version, level,
//! player and run-level input commitment — settles it: the commitment is marked proved, bound
//! to the run id, and the bounty goes to the **caller** of `submit_batch`/`register_member`.
//! An unproved commitment is reclaimable by its player once `expiry_blocks` have passed.

use starknet::ContractAddress;
use crate::segment::LeafOutput;

/// Leaderboard kinds.
pub const KIND_SCORE: u8 = 0;
pub const KIND_TIME: u8 = 1;
/// Entries kept on chain per `(version_id, kind)`.
pub const BOARD_SIZE: u32 = 10;

/// Season-1 scoring, computed on chain from the last segment's cumulative counters.
pub const SCORE_PER_KILL: u64 = 100;
pub const SCORE_PER_ITEM: u64 = 25;
pub const SCORE_PER_SECRET: u64 = 500;

/// Domain tag of a run id.
pub const TAG_RUN: felt252 = 'HP.RUN';
/// Domain tag of a commitment id (D35).
pub const TAG_COMMIT: felt252 = 'HP.COMMIT';

/// Felts per `RunLog` / `Replay` event: Starknet caps an event's data at 300 felts, so a
/// published log is split into chunks of this size (a 3-minute game, ~900 felts, is 4 events).
pub const LOG_CHUNK: u32 = 256;

/// Lifecycle of a commitment (`Commitment.status`).
pub mod commit_status {
    /// No such commitment.
    pub const NONE: u8 = 0;
    /// Committed, bounty in escrow, waiting for a prover.
    pub const PENDING: u8 = 1;
    /// A member matched it: bound to `run_id`, bounty paid to `prover`.
    pub const PROVED: u8 = 2;
    /// Expired and reclaimed by the player: bounty refunded.
    pub const RECLAIMED: u8 = 3;
}

/// Rejection reasons of `MemberRejected` (short strings).
pub mod reason {
    /// `leaf_range` empty or outside the batch.
    pub const RANGE: felt252 = 'bad range';
    /// No genesis pinned for this `(version_id, level_id)`.
    pub const LEVEL: felt252 = 'unknown level';
    /// A segment's `version` field is not the supported layout.
    pub const LAYOUT: felt252 = 'bad layout';
    /// The first segment does not start from the level's genesis state.
    pub const GENESIS: felt252 = 'bad genesis';
    /// The first segment does not start at tic 0.
    pub const TIC_START: felt252 = 'bad tic start';
    /// A segment reports `ABORT` (provably invalid execution, D14/R4-A2).
    pub const ABORT: felt252 = 'abort segment';
    /// `h_out[i] != h_in[i+1]`.
    pub const CHAIN: felt252 = 'chain break';
    /// `tic_end[i] != tic_start[i+1]`, or a segment with `tic_end < tic_start`.
    pub const TICS: felt252 = 'tic gap';
    /// A non-final segment is terminal (`DEAD`/`EXIT`).
    pub const EARLY_END: felt252 = 'early terminal';
    /// The last segment is still `RUNNING`.
    pub const UNFINISHED: felt252 = 'unfinished';
    /// This run id is already recorded (R10-A1).
    pub const REPLAYED: felt252 = 'already registered';
    /// Replay data supplied for part of the run only.
    pub const LOG_MISSING: felt252 = 'replay incomplete';
    /// A published log does not have the length the segment's tic span implies.
    pub const LOG_LENGTH: felt252 = 'replay length';
    /// A published log does not fold to the segment's `inputs_commitment`.
    pub const LOG_COMMITMENT: felt252 = 'replay commitment';
}

/// One pinned verifier/program version (governed, then frozen — R3-A6).
#[derive(Copy, Drop, Serde, starknet::Store, PartialEq, Debug)]
pub struct Version {
    /// `preimage[0]` of every leaf of this version.
    pub program_hash: felt252,
    /// `'blake'` or `'poseidon'`: the hash function the leaf bootloader used for
    /// `program_hash` (D-S4b — the same executable hashed both ways gives two values, so the
    /// pair is pinned, not just the hash).
    pub program_hash_function: felt252,
    /// The leaf circuit's hash, `circuit_hash` of the leaf verifier of the registry.
    pub leaf_circuit_hash: Digest,
    /// The multiverifier's circuit hash — the root node's `circuit_hash`, and the first half
    /// of the fact.
    pub multiverifier_hash: Digest,
    /// The circuit registry this pair comes from, e.g. `'doom_fold4_min'`.
    pub registry_name: felt252,
    /// The P4.0 router that registers facts for that registry.
    pub verifier_router: ContractAddress,
}

/// Eight u32 words packed little-endian into two u128s (`lo` = words 0..3).
#[derive(Copy, Drop, Serde, starknet::Store, PartialEq, Debug)]
pub struct Digest {
    pub lo: u128,
    pub hi: u128,
}

/// A recorded game. `status` is `EXIT` for a finished run and `DEAD` for an attempt.
#[derive(Copy, Drop, Serde, PartialEq, Debug)]
pub struct Run {
    pub player: ContractAddress,
    pub version_id: u32,
    pub level_id: u32,
    pub tics: u32,
    pub kills: u32,
    pub items: u32,
    pub secrets: u32,
    pub score: u64,
    pub status: u8,
    pub n_segments: u32,
    pub block: u64,
    /// The batch fact this run was proved under.
    pub fact: felt252,
}

/// One game inside a batch: its player, its level, and the half-open range of leaves it owns
/// **in fold order** (`GET /v1/batches/{id}` → `leaves[]`, positions of that run's segments,
/// which the wrapper emits contiguously and in segment order).
#[derive(Copy, Drop, Serde, PartialEq, Debug)]
pub struct Member {
    pub player: ContractAddress,
    pub level_id: u32,
    pub leaf_start: u32,
    pub leaf_len: u32,
}

/// The packed input log of one leaf (7 tics per felt, `ticcmd::Packer`), published by the
/// optional `Replay` event and checked against that leaf's `inputs_commitment` (D13/R10-A3).
#[derive(Drop, Serde)]
pub struct ReplayLog {
    pub leaf_index: u32,
    pub packed: Array<felt252>,
}

/// One leaderboard row.
#[derive(Copy, Drop, Serde, PartialEq, Debug)]
pub struct BoardRow {
    pub run_id: felt252,
    pub player: ContractAddress,
    /// `score` for `KIND_SCORE`, `tics` for `KIND_TIME`.
    pub value: u64,
}

/// A committed game (D35): what the player published and escrowed, and how it was settled.
#[derive(Copy, Drop, Serde, PartialEq, Debug)]
pub struct Commitment {
    pub player: ContractAddress,
    pub version_id: u32,
    pub level_id: u32,
    /// The level's genesis at commit time (the table is add-only, so it never changes).
    pub genesis: felt252,
    /// `commit_log(packed)` over the **whole** run's packed input log (see `IDoomRuns`).
    pub inputs_commitment: felt252,
    /// The number of tics the log encodes: `packed.len() == packed_len(tics)`.
    pub tics: u32,
    /// Escrowed in the fee token; paid to the prover, or refunded on `reclaim`.
    pub bounty: u256,
    pub created_block: u64,
    /// `created_block + expiry_blocks`: `reclaim` is accepted from this block on.
    pub expires_at: u64,
    /// One of `commit_status`.
    pub status: u8,
    /// The run it was proved as (`PROVED` only).
    pub run_id: felt252,
    /// The caller that submitted that run and received the bounty (`PROVED` only).
    pub prover: ContractAddress,
}

/// The read-only slice of P4.0's `StwoCircuitRouter` this contract uses (§6 of the verifier
/// design: `is_valid(fact)` *is* the consumer interface).
#[starknet::interface]
pub trait IFactRegistry<TContractState> {
    fn is_valid(self: @TContractState, fact: felt252) -> bool;
}

/// The slice of the fee token (STRK) used for bounties: snake-case entrypoints, which the
/// Starknet STRK contract exposes alongside the camel-case ones.
#[starknet::interface]
pub trait IERC20<TContractState> {
    fn balance_of(self: @TContractState, account: ContractAddress) -> u256;
    fn transfer(ref self: TContractState, recipient: ContractAddress, amount: u256) -> bool;
    fn transfer_from(
        ref self: TContractState, sender: ContractAddress, recipient: ContractAddress, amount: u256,
    ) -> bool;
}

#[starknet::interface]
pub trait IDoomRuns<TContractState> {
    /// Recomposes the batch's root `output_hash` from `leaves` (given in fold order),
    /// requires the fact to be registered by the version's router, then validates and records
    /// every member independently. Returns the number of members accepted.
    ///
    /// A member that fails validation is skipped with a `MemberRejected` event and does not
    /// block the others (D18). `replay` is optional, sorted by `leaf_index`, and either
    /// covers a member's whole range or none of it.
    fn submit_batch(
        ref self: TContractState,
        version_id: u32,
        leaves: Array<LeafOutput>,
        members: Array<Member>,
        replay: Array<ReplayLog>,
    ) -> u32;

    /// `submit_batch` for a single member — the split used when a batch's members do not fit
    /// one invoke (`docs/design/doomruns.md` §7).
    fn register_member(
        ref self: TContractState,
        version_id: u32,
        leaves: Array<LeafOutput>,
        member: Member,
        replay: Array<ReplayLog>,
    ) -> bool;

    fn get_run(self: @TContractState, run_id: felt252) -> Run;
    fn get_attempt(self: @TContractState, run_id: felt252) -> Run;
    fn is_run_registered(self: @TContractState, run_id: felt252) -> bool;
    fn leaderboard(
        self: @TContractState, version_id: u32, kind: u8, offset: u32, limit: u32,
    ) -> Array<BoardRow>;
    fn leaderboard_len(self: @TContractState, version_id: u32, kind: u8) -> u32;
    fn player_run_count(self: @TContractState, player: ContractAddress) -> u32;
    fn player_runs(
        self: @TContractState, player: ContractAddress, offset: u32, limit: u32,
    ) -> Array<felt252>;

    /// The fact `submit_batch` would require for this batch — so a client can check the
    /// registry before paying for the consumer transaction.
    fn batch_fact(self: @TContractState, version_id: u32, leaves: Array<LeafOutput>) -> felt252;
    /// The run id of one member's segments, so a client can check `is_run_registered` first.
    fn run_id_of(
        self: @TContractState, version_id: u32, level_id: u32, leaves: Array<LeafOutput>,
    ) -> felt252;

    fn get_version(self: @TContractState, version_id: u32) -> Version;
    fn genesis_of(self: @TContractState, version_id: u32, level_id: u32) -> felt252;
    fn owner(self: @TContractState) -> ContractAddress;
    fn is_frozen(self: @TContractState) -> bool;

    /// Owner, before the freeze: add a version (never mutate one — a new verifier version is a
    /// new entry) and pin a level's genesis state hash.
    fn add_version(ref self: TContractState, version_id: u32, version: Version);
    fn set_genesis(ref self: TContractState, version_id: u32, level_id: u32, genesis: felt252);
    /// One-way: no version and no genesis can be added afterwards.
    fn freeze(ref self: TContractState);

    // -- open prover (D35) ---------------------------------------------------------------

    /// The player (the caller) commits a played game: `packed` is the **whole** run's input
    /// log (7 tics per felt, `packed.len() == packed_len(tics)`), published by one
    /// `RunCommitted` and `ceil(len / LOG_CHUNK)` `RunLog` events so that any prover can
    /// rebuild it; `bounty` (possibly zero) of the fee token is pulled from the caller
    /// (`transfer_from`, so an allowance is needed) and held until the run is proved or the
    /// commitment expires. Returns the commitment id,
    /// `poseidon(TAG_COMMIT ‖ version_id ‖ level_id ‖ player ‖ commit_log(packed))`.
    ///
    /// Refused while a commitment with that id is `PENDING` or `PROVED`; a `RECLAIMED` one
    /// may be committed again (a fresh escrow and expiry, appended to the index again).
    ///
    /// A submitted member settles the commitment when its run is the committed log: same
    /// version, level and player, `tics` tics, and a run-level input commitment equal to
    /// `commit_log(packed)`. That run-level commitment is the leaf's own `inputs_commitment`
    /// for a one-segment run; for several segments it is recomputed from the `replay` logs
    /// the submitter supplies (D13 commits per segment, so the segment logs are concatenated
    /// and folded again — which requires every non-final segment to span a multiple of 7
    /// tics, so that the segment packing is a slice of the run packing). A multi-segment
    /// submission without replay data is accepted as a run but settles nothing.
    fn commit_run(
        ref self: TContractState,
        version_id: u32,
        level_id: u32,
        packed: Span<felt252>,
        tics: u32,
        bounty: u256,
    ) -> felt252;

    /// The player takes an unproved commitment back once `expires_at` is reached: the bounty
    /// is refunded and the commitment becomes `RECLAIMED`. There is no cancellation before
    /// expiry (a prover's work in flight cannot be pulled from under it). Not affected by
    /// `freeze`.
    fn reclaim(ref self: TContractState, commitment_id: felt252);

    fn get_commitment(self: @TContractState, commitment_id: felt252) -> Commitment;
    /// `get_commitment(commitment_id_of(...))`.
    fn commitment_of(
        self: @TContractState,
        version_id: u32,
        level_id: u32,
        player: ContractAddress,
        inputs_commitment: felt252,
    ) -> Commitment;
    /// Number of `commit_run` calls so far — the size of the append-only index that
    /// `pending_commitments` walks.
    fn commitment_count(self: @TContractState) -> u32;
    /// The ids of the commitments still `PENDING` among index positions
    /// `[cursor, min(cursor + limit, commitment_count))`, and the next cursor. A prover node
    /// walks the index from its last cursor; the logs themselves are in the `RunLog` events.
    fn pending_commitments(self: @TContractState, cursor: u32, limit: u32) -> (Array<felt252>, u32);
    fn fee_token(self: @TContractState) -> ContractAddress;
    fn expiry_blocks(self: @TContractState) -> u64;
}

/// `commitment_id = poseidon(TAG_COMMIT ‖ version_id ‖ level_id ‖ player ‖
/// inputs_commitment)`:
/// the same log committed by the same player for the same level is one commitment.
pub fn commitment_id_of(
    version_id: u32, level_id: u32, player: ContractAddress, inputs_commitment: felt252,
) -> felt252 {
    core::poseidon::poseidon_hash_span(
        array![TAG_COMMIT, version_id.into(), level_id.into(), player.into(), inputs_commitment]
            .span(),
    )
}

/// `score = 100·kills + 25·items + 500·secrets` (season 1).
pub fn score_of(kills: u32, items: u32, secrets: u32) -> u64 {
    let kills: u64 = kills.into();
    let items: u64 = items.into();
    let secrets: u64 = secrets.into();
    kills * SCORE_PER_KILL + items * SCORE_PER_ITEM + secrets * SCORE_PER_SECRET
}

/// `fact = poseidon(circuit_hash[0..8] ‖ output_hash[0..8])` over the 16 u32 words — the same
/// felts `StwoCircuitRouter::compute_fact` hashes.
pub fn compute_fact(circuit_hash: [u32; 8], output_hash: [u32; 8]) -> felt252 {
    let mut words: Array<felt252> = array![];
    for w in circuit_hash.span() {
        words.append((*w).into());
    }
    for w in output_hash.span() {
        words.append((*w).into());
    }
    core::poseidon::poseidon_hash_span(words.span())
}

/// Eight u32 words -> the stored `Digest`.
pub fn digest_of(words: [u32; 8]) -> Digest {
    let w = words.span();
    let p: u128 = 0x1_0000_0000;
    let lo = (*w[0]).into()
        + (*w[1]).into() * p
        + (*w[2]).into() * p * p
        + (*w[3]).into() * p * p * p;
    let hi = (*w[4]).into()
        + (*w[5]).into() * p
        + (*w[6]).into() * p * p
        + (*w[7]).into() * p * p * p;
    Digest { lo, hi }
}

/// ... and back.
pub fn words_of(digest: Digest) -> [u32; 8] {
    let nz: NonZero<u128> = 0x1_0000_0000_u128.try_into().unwrap();
    let (q, w0) = DivRem::div_rem(digest.lo, nz);
    let (q, w1) = DivRem::div_rem(q, nz);
    let (w3, w2) = DivRem::div_rem(q, nz);
    let (q, w4) = DivRem::div_rem(digest.hi, nz);
    let (q, w5) = DivRem::div_rem(q, nz);
    let (w7, w6) = DivRem::div_rem(q, nz);
    [
        w0.try_into().unwrap(), w1.try_into().unwrap(), w2.try_into().unwrap(),
        w3.try_into().unwrap(), w4.try_into().unwrap(), w5.try_into().unwrap(),
        w6.try_into().unwrap(), w7.try_into().unwrap(),
    ]
}

#[starknet::contract]
pub mod DoomRuns {
    use core::poseidon::poseidon_hash_span;
    use recursion_outputs::tree::root_output_hash;
    use starknet::storage::{
        Map, StoragePathEntry, StoragePointerReadAccess, StoragePointerWriteAccess,
    };
    use starknet::{ContractAddress, get_block_number, get_caller_address, get_contract_address};
    use crate::segment::{
        LeafOutput, OUTPUT_LEN, STATUS_ABORT, STATUS_DEAD, STATUS_EXIT, STATUS_RUNNING,
        TICS_PER_FELT, VERSION, commit_input, commit_log, inputs_seed, packed_len, to_preimage,
    };
    use super::{
        BOARD_SIZE, BoardRow, Commitment, Digest, IERC20Dispatcher, IERC20DispatcherTrait,
        IFactRegistryDispatcher, IFactRegistryDispatcherTrait, KIND_SCORE, KIND_TIME, LOG_CHUNK,
        Member, ReplayLog, Run, TAG_RUN, Version, commit_status, commitment_id_of, compute_fact,
        digest_of, reason, score_of, words_of,
    };

    /// `tics` ranked ascending is stored as `TIME_KEY_MAX - tics`, so both boards are ordered
    /// by a descending u64 key.
    const TIME_KEY_MAX: u64 = 0xFFFF_FFFF;

    /// `expiry_blocks` is bounded so that `created_block + expiry_blocks` can never overflow
    /// a u64 (which would lock every escrow): 2^40 blocks is ~ 10^5 years at one a second.
    const MAX_EXPIRY_BLOCKS: u64 = 0x100_0000_0000;

    const P16: u128 = 0x1_0000;
    const P32: u128 = 0x1_0000_0000;
    const P64: u128 = 0x1_0000_0000_0000_0000;

    /// A run record, five storage slots: the player (existence flag), three packed u128s and
    /// the fact. A storage node so that membership costs one read instead of five.
    #[starknet::storage_node]
    struct RunNode {
        player: ContractAddress,
        /// `version_id(32) | level_id(32) | tics(32) | n_segments(16) | status(8)`
        ids: u128,
        /// `kills(32) | items(32) | secrets(32)`
        stats: u128,
        /// `score(64) | block(64)`
        tally: u128,
        fact: felt252,
    }

    #[starknet::storage_node]
    struct BoardEntry {
        run_id: felt252,
        key: u64,
    }

    /// A commitment (D35). `commit_run` writes six slots of the node (the bounty is two)
    /// plus the index entry and its length; settling writes `ids` (status), `run_id` and
    /// `prover`; reclaiming writes `ids` only.
    #[starknet::storage_node]
    struct CommitmentNode {
        player: ContractAddress,
        /// `version_id(32) | level_id(32) | tics(32) | status(8)`
        ids: u128,
        genesis: felt252,
        inputs_commitment: felt252,
        bounty: u256,
        /// `created_block(64) | index(32)`: the block of the (latest) `commit_run` and its
        /// position in `commitment_index`.
        meta: u128,
        run_id: felt252,
        prover: ContractAddress,
    }

    #[storage]
    struct Storage {
        owner: ContractAddress,
        frozen: bool,
        /// The ERC20 bounties are paid in (STRK), fixed at deployment.
        fee_token: ContractAddress,
        /// Blocks a commitment stays reclaim-proof after `commit_run`.
        expiry_blocks: u64,
        commitments: Map<felt252, CommitmentNode>,
        /// Append-only index of commitment ids, one entry per `commit_run` call. A
        /// re-committed id is appended again so that a cursor-based walk sees it again; its
        /// node records its latest position, and `pending_commitments` skips the older one.
        commitment_index: Map<u32, felt252>,
        commitment_count: u32,
        versions: Map<u32, Version>,
        /// `(version_id, level_id) -> genesis state hash`. Zero means "level not pinned".
        genesis: Map<(u32, u32), felt252>,
        /// Finished runs (`EXIT`) and, separately, dead attempts (`DEAD`). A run id lives in
        /// exactly one of them; both are checked for replay.
        runs: Map<felt252, RunNode>,
        attempts: Map<felt252, RunNode>,
        board: Map<(u32, u8, u32), BoardEntry>,
        board_len: Map<(u32, u8), u32>,
        player_count: Map<ContractAddress, u32>,
        player_index: Map<(ContractAddress, u32), felt252>,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        RunSubmitted: RunSubmitted,
        AttemptRecorded: AttemptRecorded,
        MemberRejected: MemberRejected,
        Replay: Replay,
        VersionAdded: VersionAdded,
        GenesisSet: GenesisSet,
        Frozen: Frozen,
        RunCommitted: RunCommitted,
        RunLog: RunLog,
        CommitmentProved: CommitmentProved,
        CommitmentReclaimed: CommitmentReclaimed,
    }

    /// A game was committed (D35). The packed log follows in `n_chunks` `RunLog` events of
    /// the same transaction, in `chunk` order.
    #[derive(Drop, starknet::Event)]
    pub struct RunCommitted {
        #[key]
        pub commitment_id: felt252,
        #[key]
        pub player: ContractAddress,
        #[key]
        pub version_id: u32,
        pub level_id: u32,
        pub genesis: felt252,
        pub inputs_commitment: felt252,
        pub tics: u32,
        pub bounty: u256,
        pub expires_at: u64,
        pub n_chunks: u32,
    }

    /// One `LOG_CHUNK`-felt slice of a committed log: `packed[offset .. offset + len]`.
    #[derive(Drop, starknet::Event)]
    pub struct RunLog {
        #[key]
        pub commitment_id: felt252,
        pub chunk: u32,
        pub offset: u32,
        pub packed: Span<felt252>,
    }

    /// A submitted member settled a commitment: the bounty went to `prover`, the caller of
    /// that `submit_batch` / `register_member`.
    #[derive(Drop, starknet::Event)]
    pub struct CommitmentProved {
        #[key]
        pub commitment_id: felt252,
        #[key]
        pub run_id: felt252,
        #[key]
        pub prover: ContractAddress,
        pub player: ContractAddress,
        pub bounty: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub struct CommitmentReclaimed {
        #[key]
        pub commitment_id: felt252,
        #[key]
        pub player: ContractAddress,
        pub bounty: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub struct RunSubmitted {
        #[key]
        pub run_id: felt252,
        #[key]
        pub player: ContractAddress,
        #[key]
        pub version_id: u32,
        pub level_id: u32,
        pub tics: u32,
        pub kills: u32,
        pub items: u32,
        pub secrets: u32,
        pub score: u64,
        pub n_segments: u32,
        pub fact: felt252,
    }

    #[derive(Drop, starknet::Event)]
    pub struct AttemptRecorded {
        #[key]
        pub run_id: felt252,
        #[key]
        pub player: ContractAddress,
        #[key]
        pub version_id: u32,
        pub level_id: u32,
        pub tics: u32,
        pub score: u64,
        pub fact: felt252,
    }

    #[derive(Drop, starknet::Event)]
    pub struct MemberRejected {
        #[key]
        pub member_index: u32,
        #[key]
        pub player: ContractAddress,
        pub reason: felt252,
        pub leaf_start: u32,
        pub leaf_len: u32,
    }

    /// The published input log of one segment (R10-A3), emitted only when the submitter pays
    /// for it.
    #[derive(Drop, starknet::Event)]
    pub struct Replay {
        #[key]
        pub run_id: felt252,
        pub leaf_index: u32,
        pub tic_start: u32,
        pub tic_end: u32,
        pub packed: Span<felt252>,
    }

    #[derive(Drop, starknet::Event)]
    pub struct VersionAdded {
        #[key]
        pub version_id: u32,
        pub program_hash: felt252,
        pub registry_name: felt252,
        pub verifier_router: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    pub struct GenesisSet {
        #[key]
        pub version_id: u32,
        #[key]
        pub level_id: u32,
        pub genesis: felt252,
    }

    #[derive(Drop, starknet::Event)]
    pub struct Frozen {
        pub by: ContractAddress,
    }

    /// `fee_token`: the ERC20 bounties are escrowed in (STRK). `expiry_blocks`: how long a
    /// commitment stays reclaim-proof; non-zero, so a player can never pull a bounty from
    /// under a prover in the same block.
    #[constructor]
    fn constructor(
        ref self: ContractState,
        owner: ContractAddress,
        fee_token: ContractAddress,
        expiry_blocks: u64,
    ) {
        assert(expiry_blocks != 0, 'doomruns: zero expiry');
        assert(expiry_blocks <= MAX_EXPIRY_BLOCKS, 'doomruns: expiry too long');
        self.owner.write(owner);
        self.fee_token.write(fee_token);
        self.expiry_blocks.write(expiry_blocks);
    }

    #[abi(embed_v0)]
    impl Impl of super::IDoomRuns<ContractState> {
        fn submit_batch(
            ref self: ContractState,
            version_id: u32,
            leaves: Array<LeafOutput>,
            members: Array<Member>,
            replay: Array<ReplayLog>,
        ) -> u32 {
            let (version, fact) = self.checked_fact(version_id, leaves.span());
            let leaves = leaves.span();
            let replay = replay.span();
            let mut accepted = 0;
            let mut index = 0;
            while index != members.len() {
                let member = *members.at(index);
                match self.process(version_id, @version, fact, leaves, @member, replay) {
                    Ok(_) => { accepted += 1; },
                    Err(why) => {
                        self
                            .emit(
                                MemberRejected {
                                    member_index: index,
                                    player: member.player,
                                    reason: why,
                                    leaf_start: member.leaf_start,
                                    leaf_len: member.leaf_len,
                                },
                            );
                    },
                }
                index += 1;
            }
            accepted
        }

        fn register_member(
            ref self: ContractState,
            version_id: u32,
            leaves: Array<LeafOutput>,
            member: Member,
            replay: Array<ReplayLog>,
        ) -> bool {
            self.submit_batch(version_id, leaves, array![member], replay) == 1
        }

        fn get_run(self: @ContractState, run_id: felt252) -> Run {
            let node = self.runs.entry(run_id);
            decode_run(
                node.player.read(),
                node.ids.read(),
                node.stats.read(),
                node.tally.read(),
                node.fact.read(),
            )
        }

        fn get_attempt(self: @ContractState, run_id: felt252) -> Run {
            let node = self.attempts.entry(run_id);
            decode_run(
                node.player.read(),
                node.ids.read(),
                node.stats.read(),
                node.tally.read(),
                node.fact.read(),
            )
        }

        fn is_run_registered(self: @ContractState, run_id: felt252) -> bool {
            self.registered(run_id)
        }

        fn leaderboard(
            self: @ContractState, version_id: u32, kind: u8, offset: u32, limit: u32,
        ) -> Array<BoardRow> {
            let len = self.board_len.entry((version_id, kind)).read();
            let mut rows = array![];
            let mut i = offset;
            while i != len && rows.len() != limit {
                let entry = self.board.entry((version_id, kind, i));
                let run_id = entry.run_id.read();
                rows
                    .append(
                        BoardRow {
                            run_id,
                            player: self.runs.entry(run_id).player.read(),
                            value: decode_key(kind, entry.key.read()),
                        },
                    );
                i += 1;
            }
            rows
        }

        fn leaderboard_len(self: @ContractState, version_id: u32, kind: u8) -> u32 {
            self.board_len.entry((version_id, kind)).read()
        }

        fn player_run_count(self: @ContractState, player: ContractAddress) -> u32 {
            self.player_count.entry(player).read()
        }

        fn player_runs(
            self: @ContractState, player: ContractAddress, offset: u32, limit: u32,
        ) -> Array<felt252> {
            let count = self.player_count.entry(player).read();
            let mut ids = array![];
            let mut i = offset;
            while i != count && ids.len() != limit {
                ids.append(self.player_index.entry((player, i)).read());
                i += 1;
            }
            ids
        }

        fn batch_fact(self: @ContractState, version_id: u32, leaves: Array<LeafOutput>) -> felt252 {
            let version = self.version(version_id);
            batch_fact(@version, leaves.span())
        }

        fn run_id_of(
            self: @ContractState, version_id: u32, level_id: u32, leaves: Array<LeafOutput>,
        ) -> felt252 {
            run_id_of(
                version_id,
                level_id,
                self.genesis.entry((version_id, level_id)).read(),
                leaves.span(),
            )
        }

        fn get_version(self: @ContractState, version_id: u32) -> Version {
            self.versions.entry(version_id).read()
        }

        fn genesis_of(self: @ContractState, version_id: u32, level_id: u32) -> felt252 {
            self.genesis.entry((version_id, level_id)).read()
        }

        fn owner(self: @ContractState) -> ContractAddress {
            self.owner.read()
        }

        fn is_frozen(self: @ContractState) -> bool {
            self.frozen.read()
        }

        fn add_version(ref self: ContractState, version_id: u32, version: Version) {
            self.only_owner_unfrozen();
            assert(version.program_hash != 0, 'doomruns: empty program hash');
            assert(
                self.versions.entry(version_id).read().program_hash == 0,
                'doomruns: version exists',
            );
            self.versions.entry(version_id).write(version);
            self
                .emit(
                    VersionAdded {
                        version_id,
                        program_hash: version.program_hash,
                        registry_name: version.registry_name,
                        verifier_router: version.verifier_router,
                    },
                );
        }

        fn set_genesis(ref self: ContractState, version_id: u32, level_id: u32, genesis: felt252) {
            self.only_owner_unfrozen();
            assert(
                self.versions.entry(version_id).read().program_hash != 0,
                'doomruns: unknown version',
            );
            assert(genesis != 0, 'doomruns: empty genesis');
            assert(self.genesis.entry((version_id, level_id)).read() == 0, 'doomruns: genesis set');
            self.genesis.entry((version_id, level_id)).write(genesis);
            self.emit(GenesisSet { version_id, level_id, genesis });
        }

        fn freeze(ref self: ContractState) {
            self.only_owner_unfrozen();
            self.frozen.write(true);
            self.emit(Frozen { by: get_caller_address() });
        }

        // -- open prover (D35) ---------------------------------------------------------

        fn commit_run(
            ref self: ContractState,
            version_id: u32,
            level_id: u32,
            packed: Span<felt252>,
            tics: u32,
            bounty: u256,
        ) -> felt252 {
            // Checks.
            let genesis = self.genesis.entry((version_id, level_id)).read();
            assert(genesis != 0, 'doomruns: unknown level');
            assert(tics != 0, 'doomruns: empty run');
            assert(packed.len() == packed_len(tics), 'doomruns: packed length');
            let inputs_commitment = commit_log(packed);
            let player = get_caller_address();
            let commitment_id = commitment_id_of(version_id, level_id, player, inputs_commitment);
            let node = self.commitments.entry(commitment_id);
            let (_, _, _, status) = split_commit_ids(node.ids.read());
            assert(
                status != commit_status::PENDING && status != commit_status::PROVED,
                'doomruns: commitment exists',
            );

            // Effects.
            let created_block = get_block_number();
            let expires_at = created_block + self.expiry_blocks.read();
            node.player.write(player);
            node.ids.write(pack_commit_ids(version_id, level_id, tics, commit_status::PENDING));
            node.genesis.write(genesis);
            node.inputs_commitment.write(inputs_commitment);
            node.bounty.write(bounty);
            let count = self.commitment_count.read();
            node.meta.write(pack_commit_meta(created_block, count));
            self.commitment_index.entry(count).write(commitment_id);
            self.commitment_count.write(count + 1);

            let n_chunks = (packed.len() + LOG_CHUNK - 1) / LOG_CHUNK;
            self
                .emit(
                    RunCommitted {
                        commitment_id,
                        player,
                        version_id,
                        level_id,
                        genesis,
                        inputs_commitment,
                        tics,
                        bounty,
                        expires_at,
                        n_chunks,
                    },
                );
            let mut offset = 0;
            let mut chunk = 0;
            while offset != packed.len() {
                let len = core::cmp::min(LOG_CHUNK, packed.len() - offset);
                self
                    .emit(
                        RunLog { commitment_id, chunk, offset, packed: packed.slice(offset, len) },
                    );
                offset += len;
                chunk += 1;
            }

            // Interaction: the escrow, last (checks-effects-interactions).
            if bounty != 0 {
                let token = IERC20Dispatcher { contract_address: self.fee_token.read() };
                assert(
                    token.transfer_from(player, get_contract_address(), bounty),
                    'doomruns: escrow failed',
                );
            }
            commitment_id
        }

        fn reclaim(ref self: ContractState, commitment_id: felt252) {
            // Checks.
            let node = self.commitments.entry(commitment_id);
            let ids = node.ids.read();
            let (_, _, _, status) = split_commit_ids(ids);
            assert(status == commit_status::PENDING, 'doomruns: not pending');
            let player = node.player.read();
            assert(get_caller_address() == player, 'doomruns: not player');
            let (created_block, _) = split_commit_meta(node.meta.read());
            assert(
                get_block_number() >= created_block + self.expiry_blocks.read(),
                'doomruns: not expired',
            );

            // Effects.
            node.ids.write(with_commit_status(ids, commit_status::RECLAIMED));
            let bounty = node.bounty.read();
            self.emit(CommitmentReclaimed { commitment_id, player, bounty });

            // Interaction.
            if bounty != 0 {
                let token = IERC20Dispatcher { contract_address: self.fee_token.read() };
                assert(token.transfer(player, bounty), 'doomruns: refund failed');
            }
        }

        fn get_commitment(self: @ContractState, commitment_id: felt252) -> Commitment {
            let node = self.commitments.entry(commitment_id);
            let (version_id, level_id, tics, status) = split_commit_ids(node.ids.read());
            let (created_block, _) = split_commit_meta(node.meta.read());
            let expires_at = if status == commit_status::NONE {
                0
            } else {
                created_block + self.expiry_blocks.read()
            };
            Commitment {
                player: node.player.read(),
                version_id,
                level_id,
                genesis: node.genesis.read(),
                inputs_commitment: node.inputs_commitment.read(),
                tics,
                bounty: node.bounty.read(),
                created_block,
                expires_at,
                status,
                run_id: node.run_id.read(),
                prover: node.prover.read(),
            }
        }

        fn commitment_of(
            self: @ContractState,
            version_id: u32,
            level_id: u32,
            player: ContractAddress,
            inputs_commitment: felt252,
        ) -> Commitment {
            self.get_commitment(commitment_id_of(version_id, level_id, player, inputs_commitment))
        }

        fn commitment_count(self: @ContractState) -> u32 {
            self.commitment_count.read()
        }

        fn pending_commitments(
            self: @ContractState, cursor: u32, limit: u32,
        ) -> (Array<felt252>, u32) {
            let count = self.commitment_count.read();
            let end = if cursor >= count || limit > count - cursor {
                count
            } else {
                cursor + limit
            };
            let mut ids = array![];
            let mut i = cursor;
            while i < end {
                let id = self.commitment_index.entry(i).read();
                let node = self.commitments.entry(id);
                let (_, _, _, status) = split_commit_ids(node.ids.read());
                let (_, index) = split_commit_meta(node.meta.read());
                if status == commit_status::PENDING && index == i {
                    ids.append(id);
                }
                i += 1;
            }
            (ids, end)
        }

        fn fee_token(self: @ContractState) -> ContractAddress {
            self.fee_token.read()
        }

        fn expiry_blocks(self: @ContractState) -> u64 {
            self.expiry_blocks.read()
        }
    }

    #[generate_trait]
    impl Private of PrivateTrait {
        fn only_owner_unfrozen(ref self: ContractState) {
            assert(get_caller_address() == self.owner.read(), 'doomruns: not owner');
            assert(!self.frozen.read(), 'doomruns: frozen');
        }

        fn version(self: @ContractState, version_id: u32) -> Version {
            let version = self.versions.entry(version_id).read();
            assert(version.program_hash != 0, 'doomruns: unknown version');
            version
        }

        /// Recomposes the root `output_hash` of the batch and requires the version's router to
        /// hold the matching fact. Batch-level failures revert: they invalidate every member.
        fn checked_fact(
            self: @ContractState, version_id: u32, leaves: Span<LeafOutput>,
        ) -> (Version, felt252) {
            let version = self.version(version_id);
            assert(leaves.len() != 0, 'doomruns: empty batch');
            let fact = batch_fact(@version, leaves);
            let registry = IFactRegistryDispatcher { contract_address: version.verifier_router };
            assert(registry.is_valid(fact), 'doomruns: fact not registered');
            (version, fact)
        }

        fn registered(self: @ContractState, run_id: felt252) -> bool {
            self.runs.entry(run_id).player.read().into() != 0_felt252
                || self.attempts.entry(run_id).player.read().into() != 0_felt252
        }

        /// Validates one member against the (already proven) leaf outputs and records it.
        /// Every `Err` is a member-level rejection: it never touches storage.
        fn process(
            ref self: ContractState,
            version_id: u32,
            version: @Version,
            fact: felt252,
            leaves: Span<LeafOutput>,
            member: @Member,
            replay: Span<ReplayLog>,
        ) -> Result<felt252, felt252> {
            let start = *member.leaf_start;
            let len = *member.leaf_len;
            // Written without `start + len` so that a member claiming an absurd range is
            // rejected (D18) instead of overflowing and reverting the whole batch.
            if len == 0 || start >= leaves.len() || len > leaves.len() - start {
                return Err(reason::RANGE);
            }
            let own = leaves.slice(start, len);
            let level_id = *member.level_id;
            let genesis = self.genesis.entry((version_id, level_id)).read();
            if genesis == 0 {
                return Err(reason::LEVEL);
            }

            if let Err(why) = check_chain(own, genesis) {
                return Err(why);
            }

            let run_id = run_id_of(version_id, level_id, genesis, own);
            if self.registered(run_id) {
                return Err(reason::REPLAYED);
            }

            // Replay data: none, or the whole range, verified segment by segment.
            let logs = match select_logs(replay, start, len) {
                Ok(logs) => logs,
                Err(why) => { return Err(why); },
            };
            if let Err(why) = check_logs(own, logs) {
                return Err(why);
            }

            let first = *own.at(0);
            let last = *own.at(len - 1);
            let run = Run {
                player: *member.player,
                version_id,
                level_id,
                tics: last.tic_end - first.tic_start,
                kills: last.kills,
                items: last.items,
                secrets: last.secrets,
                score: score_of(last.kills, last.items, last.secrets),
                status: last.status,
                n_segments: len,
                block: get_block_number(),
                fact,
            };
            // D35: does this run settle a pending commitment of its player? Decided before
            // any write, settled after them all (the payout is the last thing that happens).
            let commitment_id = self
                .matching_commitment(
                    version_id, level_id, genesis, *member.player, own, logs, run.tics,
                );
            self.record(run_id, @run);
            self.publish(run_id, own, logs);
            if let Some(commitment_id) = commitment_id {
                self.settle(commitment_id, run_id);
            }
            Ok(run_id)
        }

        /// The pending commitment this member proves, if any: same version, level and player
        /// (all three are in the id), same tic count, same genesis, and a run-level input
        /// commitment equal to the committed `commit_log(packed)` — see
        /// `run_inputs_commitment`. `None` never rejects the member: an uncommitted run is
        /// recorded exactly as before D35.
        fn matching_commitment(
            self: @ContractState,
            version_id: u32,
            level_id: u32,
            genesis: felt252,
            player: ContractAddress,
            own: Span<LeafOutput>,
            logs: Span<ReplayLog>,
            tics: u32,
        ) -> Option<felt252> {
            let inputs_commitment = run_inputs_commitment(own, logs)?;
            let commitment_id = commitment_id_of(version_id, level_id, player, inputs_commitment);
            let node = self.commitments.entry(commitment_id);
            let (_, _, committed_tics, status) = split_commit_ids(node.ids.read());
            if status != commit_status::PENDING
                || committed_tics != tics
                || node.genesis.read() != genesis {
                return None;
            }
            Some(commitment_id)
        }

        /// Marks a commitment proved as `run_id`, then pays its bounty to the caller.
        fn settle(ref self: ContractState, commitment_id: felt252, run_id: felt252) {
            let prover = get_caller_address();
            let node = self.commitments.entry(commitment_id);
            // Effects.
            node.ids.write(with_commit_status(node.ids.read(), commit_status::PROVED));
            node.run_id.write(run_id);
            node.prover.write(prover);
            let bounty = node.bounty.read();
            let player = node.player.read();
            self.emit(CommitmentProved { commitment_id, run_id, prover, player, bounty });
            // Interaction.
            if bounty != 0 {
                let token = IERC20Dispatcher { contract_address: self.fee_token.read() };
                assert(token.transfer(prover, bounty), 'doomruns: bounty failed');
            }
        }

        /// Writes the record and its indexes. `EXIT` runs land in `runs`, enter the player
        /// index and compete on the boards; `DEAD` runs are kept as attempts only.
        fn record(ref self: ContractState, run_id: felt252, run: @Run) {
            let node = if *run.status == STATUS_EXIT {
                self.runs.entry(run_id)
            } else {
                self.attempts.entry(run_id)
            };
            node.player.write(*run.player);
            // `n_segments` is packed in 16 bits: it is bounded by the number of leaves of one
            // transaction, itself bounded by the ~4 991-felt calldata limit (10 felts a leaf).
            node
                .ids
                .write(
                    (*run.version_id).into()
                        + (*run.level_id).into() * P32
                        + (*run.tics).into() * P64
                        + (*run.n_segments).into() * P64 * P32
                        + (*run.status).into() * P64 * P32 * P16,
                );
            node
                .stats
                .write(
                    (*run.kills).into() + (*run.items).into() * P32 + (*run.secrets).into() * P64,
                );
            node.tally.write((*run.score).into() + (*run.block).into() * P64);
            node.fact.write(*run.fact);

            if *run.status != STATUS_EXIT {
                self
                    .emit(
                        AttemptRecorded {
                            run_id,
                            player: *run.player,
                            version_id: *run.version_id,
                            level_id: *run.level_id,
                            tics: *run.tics,
                            score: *run.score,
                            fact: *run.fact,
                        },
                    );
                return;
            }

            let count = self.player_count.entry(*run.player).read();
            self.player_index.entry((*run.player, count)).write(run_id);
            self.player_count.entry(*run.player).write(count + 1);

            self.insert(*run.version_id, KIND_SCORE, run_id, *run.score);
            self
                .insert(
                    *run.version_id, KIND_TIME, run_id, encode_key(KIND_TIME, (*run.tics).into()),
                );

            self
                .emit(
                    RunSubmitted {
                        run_id,
                        player: *run.player,
                        version_id: *run.version_id,
                        level_id: *run.level_id,
                        tics: *run.tics,
                        kills: *run.kills,
                        items: *run.items,
                        secrets: *run.secrets,
                        score: *run.score,
                        n_segments: *run.n_segments,
                        fact: *run.fact,
                    },
                );
        }

        /// Top-`BOARD_SIZE` insertion, descending by `key`. The common case is one read: a run
        /// that does not beat the last entry of a full board stops there.
        fn insert(ref self: ContractState, version_id: u32, kind: u8, run_id: felt252, key: u64) {
            let len = self.board_len.entry((version_id, kind)).read();
            if len == BOARD_SIZE
                && key <= self.board.entry((version_id, kind, len - 1)).key.read() {
                return;
            }
            let mut pos = if len == BOARD_SIZE {
                BOARD_SIZE - 1
            } else {
                len
            };
            while pos != 0 {
                let above = self.board.entry((version_id, kind, pos - 1));
                if above.key.read() >= key {
                    break;
                }
                let slot = self.board.entry((version_id, kind, pos));
                slot.run_id.write(above.run_id.read());
                slot.key.write(above.key.read());
                pos -= 1;
            }
            let slot = self.board.entry((version_id, kind, pos));
            slot.run_id.write(run_id);
            slot.key.write(key);
            if len != BOARD_SIZE {
                self.board_len.entry((version_id, kind)).write(len + 1);
            }
        }

        /// Publishes the verified input logs (R10-A3). Optional: a submitter who does not send
        /// replay data pays nothing for it. A log longer than `LOG_CHUNK` felts is published
        /// as several `Replay` events, each covering the tic sub-range its felts encode (a
        /// log that fits is one event, exactly as before).
        fn publish(
            ref self: ContractState, run_id: felt252, own: Span<LeafOutput>, logs: Span<ReplayLog>,
        ) {
            let mut i = 0;
            while i != logs.len() {
                let log = logs.at(i);
                let leaf = own.at(i);
                let packed = log.packed.span();
                let mut offset = 0;
                while offset != packed.len() {
                    let len = core::cmp::min(LOG_CHUNK, packed.len() - offset);
                    let tic_start = *leaf.tic_start + offset * TICS_PER_FELT;
                    let tic_end = core::cmp::min(*leaf.tic_end, tic_start + len * TICS_PER_FELT);
                    self
                        .emit(
                            Replay {
                                run_id,
                                leaf_index: *log.leaf_index,
                                tic_start,
                                tic_end,
                                packed: packed.slice(offset, len),
                            },
                        );
                    offset += len;
                }
                i += 1;
            }
        }
    }

    /// The run-level input commitment of a member — `commit_log` over the run's **whole**
    /// packed log, which is what `commit_run` committed to — when it can be derived from
    /// what the submitter sent:
    /// - one segment: the leaf's own `inputs_commitment` (the segment log *is* the run log);
    /// - several segments: the fold of the concatenated replay logs (already checked against
    ///   each leaf's `inputs_commitment` by `check_logs`), provided every non-final segment
    ///   spans a multiple of `TICS_PER_FELT` tics — otherwise the segment packing is not a
    ///   slice of the run packing and nothing can be concluded.
    /// `None` when it cannot be derived (no replay data for a multi-segment run, or an
    /// unaligned cut).
    fn run_inputs_commitment(own: Span<LeafOutput>, logs: Span<ReplayLog>) -> Option<felt252> {
        if own.len() == 1 {
            return Some(*own.at(0).inputs_commitment);
        }
        if logs.len() != own.len() {
            return None;
        }
        let mut i = 0;
        let mut aligned = true;
        while i != own.len() - 1 {
            let leaf = own.at(i);
            if (*leaf.tic_end - *leaf.tic_start) % TICS_PER_FELT != 0 {
                aligned = false;
                break;
            }
            i += 1;
        }
        if !aligned {
            return None;
        }
        let mut commitment = inputs_seed();
        for log in logs {
            for word in log.packed.span() {
                commitment = commit_input(commitment, *word);
            }
        }
        Some(commitment)
    }

    fn pack_commit_ids(version_id: u32, level_id: u32, tics: u32, status: u8) -> u128 {
        version_id.into() + level_id.into() * P32 + tics.into() * P64 + status.into() * P64 * P32
    }

    /// `(version_id, level_id, tics, status)`.
    fn split_commit_ids(ids: u128) -> (u32, u32, u32, u8) {
        let nz32: NonZero<u128> = P32.try_into().unwrap();
        let (rest, version_id) = DivRem::div_rem(ids, nz32);
        let (rest, level_id) = DivRem::div_rem(rest, nz32);
        let (status, tics) = DivRem::div_rem(rest, nz32);
        (
            version_id.try_into().unwrap(),
            level_id.try_into().unwrap(),
            tics.try_into().unwrap(),
            status.try_into().unwrap(),
        )
    }

    fn with_commit_status(ids: u128, status: u8) -> u128 {
        let (version_id, level_id, tics, _) = split_commit_ids(ids);
        pack_commit_ids(version_id, level_id, tics, status)
    }

    fn pack_commit_meta(created_block: u64, index: u32) -> u128 {
        created_block.into() + index.into() * P64
    }

    /// `(created_block, index)`.
    fn split_commit_meta(meta: u128) -> (u64, u32) {
        let nz64: NonZero<u128> = P64.try_into().unwrap();
        let (index, created_block) = DivRem::div_rem(meta, nz64);
        (created_block.try_into().unwrap(), index.try_into().unwrap())
    }

    /// `poseidon(mv_hash ‖ output_hash)` where `output_hash` is recomposed from the leaf
    /// preimages `[program_hash, out_0 … out_9]` in fold order (S4 §4: two-to-one folds, odd
    /// carry, single leaf folded with itself).
    fn batch_fact(version: @Version, leaves: Span<LeafOutput>) -> felt252 {
        let program_hash = *version.program_hash;
        let mut preimages: Array<Array<felt252>> = array![];
        for leaf in leaves {
            preimages.append(to_preimage(program_hash, leaf));
        }
        let mut spans: Array<Span<felt252>> = array![];
        for preimage in preimages.span() {
            spans.append(preimage.span());
        }
        let mv = words_of(*version.multiverifier_hash);
        let output_hash = root_output_hash(spans.span(), words_of(*version.leaf_circuit_hash), mv);
        compute_fact(mv, output_hash)
    }

    /// The run id: the whole per-segment `inputs_commitment` chain (D13), bound to the level's
    /// genesis and to the run's final state. Two submissions of the same inputs produce the
    /// same id, and an id is accepted once (R10-A1).
    fn run_id_of(
        version_id: u32, level_id: u32, genesis: felt252, own: Span<LeafOutput>,
    ) -> felt252 {
        let mut words: Array<felt252> = array![
            TAG_RUN, version_id.into(), level_id.into(), genesis, own.len().into(),
        ];
        for leaf in own {
            words.append(*leaf.inputs_commitment);
        }
        if own.len() != 0 {
            let last = *own.at(own.len() - 1);
            words.append(last.h_out);
            words.append(last.tic_end.into());
        }
        poseidon_hash_span(words.span())
    }

    /// The chain rules of `cairo/crates/segment/bench/reference.py::check_run`, extended with
    /// D14's `ABORT` and D18's `DEAD` handling.
    fn check_chain(own: Span<LeafOutput>, genesis: felt252) -> Result<(), felt252> {
        let len = own.len();
        let first = *own.at(0);
        if first.h_in != genesis {
            return Err(reason::GENESIS);
        }
        if first.tic_start != 0 {
            return Err(reason::TIC_START);
        }
        let mut err = 0;
        let mut i = 0;
        while i != len {
            let leaf = *own.at(i);
            if leaf.version != VERSION {
                err = reason::LAYOUT;
                break;
            }
            if leaf.status == STATUS_ABORT {
                err = reason::ABORT;
                break;
            }
            if leaf.tic_end < leaf.tic_start {
                err = reason::TICS;
                break;
            }
            let last = i == len - 1;
            if !last {
                if leaf.status != STATUS_RUNNING {
                    err = reason::EARLY_END;
                    break;
                }
                let next = *own.at(i + 1);
                if leaf.h_out != next.h_in {
                    err = reason::CHAIN;
                    break;
                }
                if leaf.tic_end != next.tic_start {
                    err = reason::TICS;
                    break;
                }
            } else if leaf.status != STATUS_EXIT && leaf.status != STATUS_DEAD {
                err = reason::UNFINISHED;
                break;
            }
            i += 1;
        }
        if err != 0 {
            return Err(err);
        }
        Ok(())
    }

    /// The replay entries covering `[start, start + len)`: all of them, in order, or none.
    fn select_logs(
        replay: Span<ReplayLog>, start: u32, len: u32,
    ) -> Result<Span<ReplayLog>, felt252> {
        let mut at = 0;
        while at != replay.len() && *replay.at(at).leaf_index < start {
            at += 1;
        }
        if at == replay.len() || *replay.at(at).leaf_index >= start + len {
            return Ok(array![].span());
        }
        if at + len > replay.len() {
            return Err(reason::LOG_MISSING);
        }
        let logs = replay.slice(at, len);
        let mut err = 0;
        let mut i = 0;
        while i != len {
            if *logs.at(i).leaf_index != start + i {
                err = reason::LOG_MISSING;
                break;
            }
            i += 1;
        }
        if err != 0 {
            return Err(err);
        }
        Ok(logs)
    }

    /// Each published log must have the length its segment's tic span implies and must fold to
    /// that segment's `inputs_commitment` (D13).
    fn check_logs(own: Span<LeafOutput>, logs: Span<ReplayLog>) -> Result<(), felt252> {
        let mut err = 0;
        let mut i = 0;
        while i != logs.len() {
            let leaf = *own.at(i);
            let packed = logs.at(i).packed.span();
            if packed.len() != packed_len(leaf.tic_end - leaf.tic_start) {
                err = reason::LOG_LENGTH;
                break;
            }
            if commit_log(packed) != leaf.inputs_commitment {
                err = reason::LOG_COMMITMENT;
                break;
            }
            i += 1;
        }
        if err != 0 {
            return Err(err);
        }
        Ok(())
    }

    fn encode_key(kind: u8, value: u64) -> u64 {
        if kind == KIND_TIME {
            TIME_KEY_MAX - value
        } else {
            value
        }
    }

    fn decode_key(kind: u8, key: u64) -> u64 {
        encode_key(kind, key)
    }

    /// The five stored slots of a run, unpacked.
    fn decode_run(
        player: ContractAddress, ids: u128, stats: u128, tally: u128, fact: felt252,
    ) -> Run {
        let nz32: NonZero<u128> = P32.try_into().unwrap();
        let nz16: NonZero<u128> = P16.try_into().unwrap();
        let nz64: NonZero<u128> = P64.try_into().unwrap();
        let (rest, version_id) = DivRem::div_rem(ids, nz32);
        let (rest, level_id) = DivRem::div_rem(rest, nz32);
        let (rest, tics) = DivRem::div_rem(rest, nz32);
        let (status, n_segments) = DivRem::div_rem(rest, nz16);
        let (rest, kills) = DivRem::div_rem(stats, nz32);
        let (secrets, items) = DivRem::div_rem(rest, nz32);
        let (block, score) = DivRem::div_rem(tally, nz64);
        Run {
            player,
            version_id: version_id.try_into().unwrap(),
            level_id: level_id.try_into().unwrap(),
            tics: tics.try_into().unwrap(),
            kills: kills.try_into().unwrap(),
            items: items.try_into().unwrap(),
            secrets: secrets.try_into().unwrap(),
            score: score.try_into().unwrap(),
            status: status.try_into().unwrap(),
            n_segments: n_segments.try_into().unwrap(),
            block: block.try_into().unwrap(),
            fact,
        }
    }

    /// Re-exported for tests: the ten-felt layout the calldata follows.
    pub fn output_len() -> u32 {
        OUTPUT_LEN
    }

    pub fn digest(words: [u32; 8]) -> Digest {
        digest_of(words)
    }
}
