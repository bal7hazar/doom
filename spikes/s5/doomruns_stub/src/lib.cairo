//! S5 cost probe — a stand-in for the consumer-side `DoomRuns.submit_run`.
//!
//! Measures what the *consumer* transaction costs once the Stwo fact is
//! registered: the recomposition of the leaf-output chain (RISKS.md R3-A4),
//! the chain/terminal checks, and the storage of one `Run` record
//! (PLAN.md Phase 4, task 2).
//!
//! Per segment (leaf) it does, for N segments:
//!   * 1 `poseidon_hash_span` over the segment's 8 output words,
//!   * 1 `hades_permutation` folding that digest into the running
//!     `inputs_commitment` — ~2N Poseidon hashes in total,
//!   * 1 `blake2s_compress` of `running_digest ‖ segment_words`, which is
//!     the shape of the `packed_output` chain the recursive tree commits to,
//!   * the chain condition `h_in[i] == h_out[i-1]`, with `h_in[0] == genesis`,
//!
//! then checks `status == EXIT` on the last segment and writes the record.
//!
//! This is NOT the production contract: the real one also calls
//! `IStwoFactRegistry::is_valid` and pins `{program_hash, circuit_hash}`.
//! Those add one external call and two storage reads on top of what is
//! measured here.

/// Segment outputs, as 8 u32-valued felts:
/// `[h_in, h_out, tics, kills, items, secrets, score, status]`.
pub const WORDS_PER_SEGMENT: u32 = 8;

/// Terminal status a run must reach to be recorded.
pub const STATUS_EXIT: u32 = 2;

#[derive(Drop, Serde, starknet::Store)]
pub struct Run {
    pub player: starknet::ContractAddress,
    pub n_segments: u32,
    pub tics: u32,
    pub kills: u32,
    pub items: u32,
    pub secrets: u32,
    pub score: u32,
    pub block: u64,
}

#[starknet::interface]
pub trait IDoomRunsStub<TContractState> {
    /// Recomposes the leaf-output chain of `n` segments, checks it, and
    /// stores the run. `outputs` is `n * WORDS_PER_SEGMENT` felts, each
    /// fitting in a u32. Returns the recomposed commitment.
    fn submit_run(
        ref self: TContractState, run_id: felt252, genesis: u32, outputs: Span<felt252>,
    ) -> felt252;

    fn get_run(self: @TContractState, run_id: felt252) -> Run;
    fn commitment_of(self: @TContractState, run_id: felt252) -> felt252;
}

#[starknet::contract]
mod DoomRunsStub {
    use core::blake::blake2s_compress;
    use core::poseidon::{hades_permutation, poseidon_hash_span};
    use starknet::storage::{
        Map, StoragePathEntry, StoragePointerReadAccess, StoragePointerWriteAccess,
    };
    use starknet::{get_block_number, get_caller_address};
    use super::{IDoomRunsStub, Run, STATUS_EXIT, WORDS_PER_SEGMENT};

    /// blake2s IV — the initial chaining value of the leaf-output chain.
    const BLAKE_IV: [u32; 8] = [
        0x6B08E647, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A, 0x510E527F, 0x9B05688C, 0x1F83D9AB,
        0x5BE0CD19,
    ];

    #[storage]
    struct Storage {
        runs: Map<felt252, Run>,
        commitments: Map<felt252, felt252>,
        /// Unicity by recomposed commitment (RISKS.md R10-A1).
        seen: Map<felt252, bool>,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        RunSubmitted: RunSubmitted,
    }

    #[derive(Drop, starknet::Event)]
    struct RunSubmitted {
        #[key]
        run_id: felt252,
        #[key]
        player: starknet::ContractAddress,
        commitment: felt252,
        tics: u32,
    }

    #[abi(embed_v0)]
    impl DoomRunsStubImpl of IDoomRunsStub<ContractState> {
        fn submit_run(
            ref self: ContractState, run_id: felt252, genesis: u32, outputs: Span<felt252>,
        ) -> felt252 {
            let n_words = outputs.len();
            assert(n_words % WORDS_PER_SEGMENT == 0, 'ragged segment outputs');
            let n = n_words / WORDS_PER_SEGMENT;
            assert(n != 0, 'empty run');

            let mut digest: [u32; 8] = BLAKE_IV;
            let mut acc: felt252 = 0;
            let mut expected_h_in: u32 = genesis;
            let mut byte_count: u32 = 0;

            // Tallies of the last segment's cumulative counters.
            let mut tics: u32 = 0;
            let mut kills: u32 = 0;
            let mut items: u32 = 0;
            let mut secrets: u32 = 0;
            let mut score: u32 = 0;
            let mut status: u32 = 0;

            let mut i: u32 = 0;
            while i != n {
                let base = i * WORDS_PER_SEGMENT;
                let seg = outputs.slice(base, WORDS_PER_SEGMENT);

                // Chain continuity: this segment starts where the previous ended.
                let h_in: u32 = (*seg[0]).try_into().unwrap();
                let h_out: u32 = (*seg[1]).try_into().unwrap();
                assert(h_in == expected_h_in, 'broken segment chain');
                expected_h_in = h_out;

                tics = (*seg[2]).try_into().unwrap();
                kills = (*seg[3]).try_into().unwrap();
                items = (*seg[4]).try_into().unwrap();
                secrets = (*seg[5]).try_into().unwrap();
                score = (*seg[6]).try_into().unwrap();
                status = (*seg[7]).try_into().unwrap();

                // Poseidon #1: the segment's own digest.
                let leaf = poseidon_hash_span(seg);
                // Poseidon #2: fold it into the running commitment.
                let (next_acc, _, _) = hades_permutation(acc, leaf, 2);
                acc = next_acc;

                // blake2s: `digest' = compress(digest, digest ‖ segment_words)`,
                // the shape of the recursive tree's `packed_output` chain.
                let [d0, d1, d2, d3, d4, d5, d6, d7] = digest;
                let msg: [u32; 16] = [
                    d0, d1, d2, d3, d4, d5, d6, d7,
                    h_in, h_out, tics, kills, items, secrets, score, status,
                ];
                byte_count += 64;
                digest = blake2s_compress(BoxTrait::new(digest), byte_count, BoxTrait::new(msg))
                    .unbox();

                i += 1;
            }

            assert(status == STATUS_EXIT, 'run did not reach EXIT');

            // The commitment binds the Poseidon fold and the blake2s chain.
            let [c0, c1, c2, c3, c4, c5, c6, c7] = digest;
            let commitment = poseidon_hash_span(
                array![
                    acc, c0.into(), c1.into(), c2.into(), c3.into(), c4.into(), c5.into(),
                    c6.into(), c7.into(),
                ]
                    .span(),
            );
            assert(!self.seen.entry(commitment).read(), 'run already submitted');

            let player = get_caller_address();
            self.seen.entry(commitment).write(true);
            self.commitments.entry(run_id).write(commitment);
            self
                .runs
                .entry(run_id)
                .write(
                    Run {
                        player,
                        n_segments: n,
                        tics,
                        kills,
                        items,
                        secrets,
                        score,
                        block: get_block_number(),
                    },
                );
            self.emit(RunSubmitted { run_id, player, commitment, tics });
            commitment
        }

        fn get_run(self: @ContractState, run_id: felt252) -> Run {
            self.runs.entry(run_id).read()
        }

        fn commitment_of(self: @ContractState, run_id: felt252) -> felt252 {
            self.commitments.entry(run_id).read()
        }
    }
}
