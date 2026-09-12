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

/// The read-only slice of P4.0's `StwoCircuitRouter` this contract uses (§6 of the verifier
/// design: `is_valid(fact)` *is* the consumer interface).
#[starknet::interface]
pub trait IFactRegistry<TContractState> {
    fn is_valid(self: @TContractState, fact: felt252) -> bool;
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
    use starknet::{ContractAddress, get_block_number, get_caller_address};
    use crate::segment::{
        LeafOutput, OUTPUT_LEN, STATUS_ABORT, STATUS_DEAD, STATUS_EXIT, STATUS_RUNNING, VERSION,
        commit_log, packed_len, to_preimage,
    };
    use super::{
        BOARD_SIZE, BoardRow, Digest, IFactRegistryDispatcher, IFactRegistryDispatcherTrait,
        KIND_SCORE, KIND_TIME, Member, ReplayLog, Run, TAG_RUN, Version, compute_fact, digest_of,
        reason, score_of, words_of,
    };

    /// `tics` ranked ascending is stored as `TIME_KEY_MAX - tics`, so both boards are ordered
    /// by a descending u64 key.
    const TIME_KEY_MAX: u64 = 0xFFFF_FFFF;

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

    #[storage]
    struct Storage {
        owner: ContractAddress,
        frozen: bool,
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

    #[constructor]
    fn constructor(ref self: ContractState, owner: ContractAddress) {
        self.owner.write(owner);
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
            if len == 0 || start + len > leaves.len() {
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
            self.record(run_id, @run);
            self.publish(run_id, own, logs);
            Ok(run_id)
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
        /// replay data pays nothing for it.
        fn publish(
            ref self: ContractState, run_id: felt252, own: Span<LeafOutput>, logs: Span<ReplayLog>,
        ) {
            let mut i = 0;
            while i != logs.len() {
                let log = logs.at(i);
                let leaf = own.at(i);
                self
                    .emit(
                        Replay {
                            run_id,
                            leaf_index: *log.leaf_index,
                            tic_start: *leaf.tic_start,
                            tic_end: *leaf.tic_end,
                            packed: log.packed.span(),
                        },
                    );
                i += 1;
            }
        }
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
