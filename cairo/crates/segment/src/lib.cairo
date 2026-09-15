// SPDX-License-Identifier: Apache-2.0

//! The generic segment runner: K tics of *someone's* game, executed as one
//! provable Cairo run, with a fixed public output the chain can read.
//!
//! # Public output layout
//!
//! `run_segment` returns a [`SegmentOutput`]; [`to_felts`] flattens it to
//! **ten felts, in this order**, which is what an executable returns and
//! therefore what lands in the leaf bootloader's output preimage
//! (`[program_hash, out_0, …]`, S4 §1):
//!
//! ```text
//!   0  version             layout version -- 1
//!   1  h_in                Poseidon hash of the state before the segment
//!   2  h_out               ... and after it
//!   3  tic_start           absolute tic index of the first tic
//!   4  tic_end             one past the last tic actually run
//!   5  status              0 RUNNING, 1 DEAD, 2 EXIT, 3 ABORT
//!   6  inputs_commitment   commitment to this segment's slice of the log
//!   7  kills
//!   8  items
//!   9  secrets
//! ```
//!
//! This is CONTEXT.md §9's `[h_in, h_out, tic_start, tic_end, status,
//! kills, items, secrets]` with two additions. **`version` comes first** so
//! that a consumer can dispatch on the layout before reading anything else
//! — a field added later must not silently shift the meaning of the ones
//! already deployed on chain. **`inputs_commitment`** binds the segment to
//! the exact inputs it consumed, so the input log published as an event can
//! be checked against the proof rather than merely accompanying it.
//!
//! The chain-side rules are unchanged: `h_in[0] = genesis`, `h_out[i] =
//! h_in[i+1]`, `tic_end[i] = tic_start[i+1]`, `status = EXIT` on the last
//! segment and `RUNNING` on every other one.
//!
//! # Why a trait and not a function argument
//!
//! Cairo has no function pointers, so the game is supplied as an impl of
//! [`SegmentEngine`] — one trait with four methods (`step`, `hash`,
//! `stats`, `word`) rather than four generic parameters, because every
//! extra monomorphised generic costs 60–77 bytecode words (S1 §5.9) and the
//! program-size budget is 16 k words (G0 D4).
//!
//! # Zero panics
//!
//! A panic on the proving path means no proof at all, so nothing here can
//! trap: the loop indexes only inside the span, the tic counter is bounded
//! by [`MAX_TIC`], and the engine reports trouble by returning
//! [`Status::Abort`] instead of panicking (R4-A2). An `ABORT` segment still
//! produces a complete, hashable output — it simply will not be accepted as
//! part of a finished run.

use state_hash::{commit_input, inputs_seed};
use ticcmd::{PackerTrait, packer};

/// Version of the public output layout documented above.
pub const VERSION: felt252 = 1;

/// Number of felts in the flattened public output.
pub const OUTPUT_LEN: u32 = 10;

/// Largest tic index the runner will produce. Well above a full run
/// (3 minutes is 6 300 tics) and far enough from `u32`'s ceiling that
/// `tic_start + tics` cannot overflow.
pub const MAX_TIC: u32 = 0x4000_0000;

/// How a segment ended.
#[derive(Copy, Drop, Serde, PartialEq, Debug, Default)]
pub enum Status {
    /// The segment ran to its end and the game continues.
    #[default]
    Running,
    /// The player died during this segment.
    Dead,
    /// The level was completed during this segment.
    Exit,
    /// The engine detected an impossible state and stopped. Never a panic.
    Abort,
}

/// Felt encoding of a [`Status`], as it appears in the public output.
pub fn status_felt(status: Status) -> felt252 {
    match status {
        Status::Running => 0,
        Status::Dead => 1,
        Status::Exit => 2,
        Status::Abort => 3,
    }
}

/// Inverse of [`status_felt`]; `None` on any other value.
pub fn status_from_felt(value: felt252) -> Option<Status> {
    if value == 0 {
        Option::Some(Status::Running)
    } else if value == 1 {
        Option::Some(Status::Dead)
    } else if value == 2 {
        Option::Some(Status::Exit)
    } else if value == 3 {
        Option::Some(Status::Abort)
    } else {
        Option::None
    }
}

/// True for a status that ends the segment early.
pub fn is_terminal(status: Status) -> bool {
    status != Status::Running
}

/// The three scoreboard counters the chain reads out of a run.
#[derive(Copy, Drop, Serde, PartialEq, Debug, Default)]
pub struct Stats {
    pub kills: u32,
    pub items: u32,
    pub secrets: u32,
}

/// The public output of one segment. Field order is the felt order; see
/// the module docs.
#[derive(Copy, Drop, Serde, PartialEq, Debug)]
pub struct SegmentOutput {
    pub version: felt252,
    pub h_in: felt252,
    pub h_out: felt252,
    pub tic_start: u32,
    pub tic_end: u32,
    pub status: Status,
    pub inputs_commitment: felt252,
    pub stats: Stats,
}

/// Flatten a [`SegmentOutput`] into the ten public felts.
pub fn to_felts(output: SegmentOutput) -> Array<felt252> {
    array![
        output.version, output.h_in, output.h_out, output.tic_start.into(), output.tic_end.into(),
        status_felt(output.status), output.inputs_commitment, output.stats.kills.into(),
        output.stats.items.into(), output.stats.secrets.into(),
    ]
}

/// Read a [`SegmentOutput`] back from the ten public felts. `None` when the
/// length, the version, the status code or a counter is not valid — the
/// consumer-side check, and a total function.
pub fn from_felts(felts: Span<felt252>) -> Option<SegmentOutput> {
    if felts.len() != OUTPUT_LEN {
        return Option::None;
    }
    if *felts.at(0) != VERSION {
        return Option::None;
    }
    let tic_start: Option<u32> = (*felts.at(3)).try_into();
    let tic_end: Option<u32> = (*felts.at(4)).try_into();
    let kills: Option<u32> = (*felts.at(7)).try_into();
    let items: Option<u32> = (*felts.at(8)).try_into();
    let secrets: Option<u32> = (*felts.at(9)).try_into();
    let status = status_from_felt(*felts.at(5));
    match (tic_start, tic_end, kills, items, secrets, status) {
        (
            Option::Some(tic_start),
            Option::Some(tic_end),
            Option::Some(kills),
            Option::Some(items),
            Option::Some(secrets),
            Option::Some(status),
        ) => {
            if tic_end < tic_start {
                return Option::None;
            }
            Option::Some(
                SegmentOutput {
                    version: VERSION,
                    h_in: *felts.at(1),
                    h_out: *felts.at(2),
                    tic_start,
                    tic_end,
                    status,
                    inputs_commitment: *felts.at(6),
                    stats: Stats { kills, items, secrets },
                },
            )
        },
        _ => Option::None,
    }
}

/// True when `later` continues `earlier`: same hash, same tic, and the
/// earlier segment did not already end the run. The continuity rule
/// `DoomRuns` enforces, written once here so the contract and the tests
/// share it.
pub fn continues(earlier: SegmentOutput, later: SegmentOutput) -> bool {
    earlier.h_out == later.h_in
        && earlier.tic_end == later.tic_start
        && earlier.status == Status::Running
}

/// Everything the runner needs to know about a game.
///
/// One trait, four methods, because each extra generic parameter costs
/// 60–77 bytecode words when monomorphised (S1 §5.9):
///
/// * `step` advances one tic and says whether the game is still running;
///   it must **never panic** — return [`Status::Abort`] instead;
/// * `hash` is the canonical state hash (see `state_hash`), called exactly
///   twice per segment, never per tic;
/// * `stats` reads the scoreboard counters out of the final state;
/// * `word` is the 32-bit encoding of one command (see `ticcmd::encode`),
///   used to rebuild the packed input log for the commitment.
pub trait SegmentEngine<S, C> {
    fn step(state: S, cmd: C) -> (S, Status);
    fn hash(state: @S) -> felt252;
    fn stats(state: @S) -> Stats;
    fn word(cmd: @C) -> felt252;
}

/// Run up to `max_tics` tics of `cmds`, starting from `state` at absolute
/// tic `tic_start`.
///
/// Stops at `min(cmds.len(), max_tics)` tics, or earlier if the engine
/// returns a terminal status — the tic that ends the game is *included*, so
/// `tic_end` counts it.
///
/// Returns the final state (the caller needs it to start the next segment)
/// and the public output.
///
/// The `inputs_commitment` is **per segment**: it starts from
/// `state_hash::inputs_seed()` and folds this segment's own commands, seven
/// to a felt. It therefore does not chain from one segment to the next the
/// way `h_out`/`h_in` do; a verifier recomputes each segment's commitment
/// from the slice of the published log that `tic_start`/`tic_end` names.
pub fn run_segment<S, C, impl Engine: SegmentEngine<S, C>, +Destruct<S>, +Drop<C>, +Copy<C>>(
    state: S, cmds: Span<C>, tic_start: u32, max_tics: u32,
) -> (S, SegmentOutput) {
    let h_in = Engine::hash(@state);
    let mut current = state;
    let mut status = Status::Running;
    let mut ran: u32 = 0;
    let mut commitment = inputs_seed();
    let mut group = packer();

    // Bounded by both the command span and the caller's budget, and by
    // MAX_TIC so that `tic_start + ran` cannot overflow. An out-of-range
    // `tic_start` yields a zero-tic ABORT rather than a trap.
    let mut limit: u32 = 0;
    if tic_start > MAX_TIC {
        status = Status::Abort;
    } else {
        let headroom = MAX_TIC - tic_start;
        let wanted = if cmds.len() < max_tics {
            cmds.len()
        } else {
            max_tics
        };
        limit = if wanted > headroom {
            headroom
        } else {
            wanted
        };
    }

    while ran != limit {
        let cmd = *cmds.at(ran);
        let (next, reported) = Engine::step(current, cmd);
        current = next;
        let (advanced, complete) = group.push(Engine::word(@cmd));
        group = advanced;
        match complete {
            Option::Some(felt) => { commitment = commit_input(commitment, felt); },
            Option::None => {},
        }
        ran += 1;
        if reported != Status::Running {
            status = reported;
            break;
        }
    }

    match group.seal() {
        Option::Some(felt) => { commitment = commit_input(commitment, felt); },
        Option::None => {},
    }

    let output = SegmentOutput {
        version: VERSION,
        h_in,
        h_out: Engine::hash(@current),
        tic_start,
        tic_end: tic_start + ran,
        status,
        inputs_commitment: commitment,
        stats: Engine::stats(@current),
    };
    (current, output)
}

// ---------------------------------------------------------------------------
// TRANSITIONAL -- delete with P1.3.
//
// `doom_game::run_segment_header` calls `chain_commands`, which predates
// `run_segment` and has no game semantics at all.
// ---------------------------------------------------------------------------

use state_hash::chain;
use ticcmd::{TicCmd, pack};

/// Fold a batch of commands onto `h_in`. Prefer [`run_segment`].
pub fn chain_commands(h_in: felt252, tic_start: u32, cmds: Span<TicCmd>) -> SegmentOutput {
    let mut packed: Array<felt252> = array![];
    let mut i: u32 = 0;
    while i != cmds.len() {
        packed.append(pack(*cmds.at(i)));
        i += 1;
    }
    let h_out = if cmds.len() == 0 {
        h_in
    } else {
        chain(h_in, packed.span())
    };
    SegmentOutput {
        version: VERSION,
        h_in,
        h_out,
        tic_start,
        tic_end: tic_start + cmds.len(),
        status: Status::Running,
        inputs_commitment: 0,
        stats: Default::default(),
    }
}

#[cfg(test)]
mod tests {
    use state_hash::{commit_input, inputs_seed};
    use ticcmd::{TicCmd, encode, pack_log};
    use super::{
        MAX_TIC, OUTPUT_LEN, SegmentEngine, SegmentOutput, Stats, Status, VERSION, chain_commands,
        continues, from_felts, is_terminal, run_segment, status_felt, status_from_felt, to_felts,
    };

    /// A toy game: the state is a counter and a "health" value. Each tic
    /// adds `forward` to the counter and subtracts `side` from health;
    /// health reaching zero is DEAD, a `buttons` bit is EXIT, and a
    /// deliberately impossible command is ABORT. Enough shape to exercise
    /// every branch of the runner without dragging in any Doom.
    #[derive(Copy, Drop, PartialEq, Debug)]
    struct Toy {
        position: i64,
        health: i64,
        kills: u32,
    }

    const BT_EXIT: u8 = 1;
    const BT_KILL: u8 = 2;
    const BT_ABORT: u8 = 4;

    impl ToyEngine of SegmentEngine<Toy, TicCmd> {
        fn step(state: Toy, cmd: TicCmd) -> (Toy, Status) {
            if cmd.buttons == BT_ABORT {
                return (state, Status::Abort);
            }
            let kills = if cmd.buttons == BT_KILL {
                state.kills + 1
            } else {
                state.kills
            };
            let next = Toy {
                position: state.position + cmd.forward, health: state.health - cmd.side, kills,
            };
            if next.health <= 0 {
                return (Toy { position: next.position, health: 0, kills }, Status::Dead);
            }
            if cmd.buttons == BT_EXIT {
                return (next, Status::Exit);
            }
            (next, Status::Running)
        }

        fn hash(state: @Toy) -> felt252 {
            state_hash::hash_game_state(
                array![
                    (*state.position + 0x10000).into(), (*state.health + 0x10000).into(),
                    (*state.kills).into(),
                ]
                    .span(),
            )
        }

        fn stats(state: @Toy) -> Stats {
            Stats { kills: *state.kills, items: 0, secrets: 0 }
        }

        fn word(cmd: @TicCmd) -> felt252 {
            encode(*cmd)
        }
    }

    fn start() -> Toy {
        Toy { position: 0, health: 100, kills: 0 }
    }

    fn cmd(forward: i64, side: i64, buttons: u8) -> TicCmd {
        TicCmd { forward, side, angle_turn: 0, buttons }
    }

    fn walk(n: u32) -> Array<TicCmd> {
        let mut out: Array<TicCmd> = array![];
        let mut i: u32 = 0;
        while i != n {
            out.append(cmd(1, 0, 0));
            i += 1;
        }
        out
    }

    // -- the output layout -------------------------------------------------

    #[test]
    fn test_output_layout_is_ten_felts_in_the_documented_order() {
        let output = SegmentOutput {
            version: VERSION,
            h_in: 111,
            h_out: 222,
            tic_start: 10,
            tic_end: 20,
            status: Status::Exit,
            inputs_commitment: 333,
            stats: Stats { kills: 4, items: 5, secrets: 6 },
        };
        let felts = to_felts(output);
        assert(felts.len() == OUTPUT_LEN, 'ten felts');
        assert(*felts.at(0) == VERSION, '0 version');
        assert(*felts.at(1) == 111, '1 h_in');
        assert(*felts.at(2) == 222, '2 h_out');
        assert(*felts.at(3) == 10, '3 tic_start');
        assert(*felts.at(4) == 20, '4 tic_end');
        assert(*felts.at(5) == 2, '5 status EXIT');
        assert(*felts.at(6) == 333, '6 inputs_commitment');
        assert(*felts.at(7) == 4, '7 kills');
        assert(*felts.at(8) == 5, '8 items');
        assert(*felts.at(9) == 6, '9 secrets');
    }

    #[test]
    fn test_to_felts_matches_serde() {
        // The executable's return value is serialized by `Serde`; the
        // documented layout and that serialization must be the same felts,
        // or the on-chain consumer reads the wrong ones.
        let output = SegmentOutput {
            version: VERSION,
            h_in: 7,
            h_out: 8,
            tic_start: 1,
            tic_end: 2,
            status: Status::Dead,
            inputs_commitment: 9,
            stats: Stats { kills: 1, items: 2, secrets: 3 },
        };
        let mut serialized: Array<felt252> = array![];
        output.serialize(ref serialized);
        let flat = to_felts(output);
        assert(serialized.len() == flat.len(), 'same length');
        let mut i: u32 = 0;
        while i != flat.len() {
            assert(*serialized.at(i) == *flat.at(i), 'same felt');
            i += 1;
        }
    }

    #[test]
    fn test_from_felts_round_trip() {
        let output = SegmentOutput {
            version: VERSION,
            h_in: 111,
            h_out: 222,
            tic_start: 10,
            tic_end: 20,
            status: Status::Running,
            inputs_commitment: 333,
            stats: Stats { kills: 4, items: 5, secrets: 6 },
        };
        assert(from_felts(to_felts(output).span()) == Option::Some(output), 'round trip');
    }

    #[test]
    fn test_from_felts_rejects_malformed_output() {
        let good = to_felts(
            SegmentOutput {
                version: VERSION,
                h_in: 1,
                h_out: 2,
                tic_start: 3,
                tic_end: 4,
                status: Status::Running,
                inputs_commitment: 5,
                stats: Default::default(),
            },
        );
        assert(from_felts(array![].span()).is_none(), 'empty is rejected');
        assert(from_felts(good.span().slice(0, 9)).is_none(), 'short is rejected');
        let mut wrong_version = good.clone();
        let mut patched: Array<felt252> = array![VERSION + 1];
        let mut i: u32 = 1;
        while i != good.len() {
            patched.append(*good.at(i));
            i += 1;
        }
        assert(from_felts(patched.span()).is_none(), 'other version is rejected');
        wrong_version = array![VERSION, 1, 2, 3, 4, 99, 5, 0, 0, 0];
        assert(from_felts(wrong_version.span()).is_none(), 'bad status is rejected');
        let backwards: Array<felt252> = array![VERSION, 1, 2, 9, 3, 0, 5, 0, 0, 0];
        assert(from_felts(backwards.span()).is_none(), 'tic_end before start');
        let huge: Array<felt252> = array![VERSION, 1, 2, 0x100000000, 4, 0, 5, 0, 0, 0];
        assert(from_felts(huge.span()).is_none(), 'oversized tic is rejected');
    }

    #[test]
    fn test_status_codes_round_trip() {
        assert(status_felt(Status::Running) == 0, 'running is 0');
        assert(status_felt(Status::Dead) == 1, 'dead is 1');
        assert(status_felt(Status::Exit) == 2, 'exit is 2');
        assert(status_felt(Status::Abort) == 3, 'abort is 3');
        assert(status_from_felt(0) == Option::Some(Status::Running), 'from 0');
        assert(status_from_felt(1) == Option::Some(Status::Dead), 'from 1');
        assert(status_from_felt(2) == Option::Some(Status::Exit), 'from 2');
        assert(status_from_felt(3) == Option::Some(Status::Abort), 'from 3');
        assert(status_from_felt(4).is_none(), 'from 4 is none');
        assert(!is_terminal(Status::Running), 'running continues');
        assert(is_terminal(Status::Dead), 'dead is terminal');
        assert(is_terminal(Status::Exit), 'exit is terminal');
        assert(is_terminal(Status::Abort), 'abort is terminal');
    }

    // -- running -----------------------------------------------------------

    #[test]
    fn test_runs_every_command() {
        let cmds = walk(5);
        let (state, output) = run_segment::<Toy, TicCmd, ToyEngine>(start(), cmds.span(), 0, 100);
        assert(state.position == 5, 'five tics of movement');
        assert(output.tic_start == 0 && output.tic_end == 5, 'tic bounds');
        assert(output.status == Status::Running, 'still running');
        assert(output.version == VERSION, 'version is stamped');
    }

    #[test]
    fn test_empty_command_span_is_a_no_op() {
        let cmds: Array<TicCmd> = array![];
        let (state, output) = run_segment::<Toy, TicCmd, ToyEngine>(start(), cmds.span(), 42, 100);
        assert(state == start(), 'state untouched');
        assert(output.h_in == output.h_out, 'hash unchanged');
        assert(output.tic_start == 42 && output.tic_end == 42, 'no tics elapsed');
        assert(output.status == Status::Running, 'still running');
        assert(output.inputs_commitment == inputs_seed(), 'empty log commitment');
    }

    #[test]
    fn test_max_tics_truncates() {
        let cmds = walk(10);
        let (state, output) = run_segment::<Toy, TicCmd, ToyEngine>(start(), cmds.span(), 0, 4);
        assert(state.position == 4, 'stopped at max_tics');
        assert(output.tic_end == 4, 'tic_end is max_tics');
        assert(output.status == Status::Running, 'truncation is not terminal');
    }

    #[test]
    fn test_max_tics_zero_runs_nothing() {
        let cmds = walk(10);
        let (state, output) = run_segment::<Toy, TicCmd, ToyEngine>(start(), cmds.span(), 7, 0);
        assert(state == start(), 'no tic ran');
        assert(output.tic_end == 7, 'tic_end equals tic_start');
        assert(output.h_in == output.h_out, 'hash unchanged');
    }

    #[test]
    fn test_terminal_status_stops_early_and_counts_its_tic() {
        let cmds: Array<TicCmd> = array![
            cmd(1, 0, 0), cmd(1, 0, BT_EXIT), cmd(1, 0, 0), cmd(1, 0, 0),
        ];
        let (state, output) = run_segment::<Toy, TicCmd, ToyEngine>(start(), cmds.span(), 0, 100);
        assert(output.status == Status::Exit, 'exited');
        assert(output.tic_end == 2, 'the exiting tic counts');
        assert(state.position == 2, 'two tics ran');
    }

    #[test]
    fn test_terminal_on_the_first_tic() {
        let cmds: Array<TicCmd> = array![cmd(0, 0, BT_EXIT), cmd(1, 0, 0)];
        let (state, output) = run_segment::<Toy, TicCmd, ToyEngine>(start(), cmds.span(), 5, 100);
        assert(output.status == Status::Exit, 'exited immediately');
        assert(output.tic_end == 6, 'exactly one tic');
        assert(state.position == 0, 'the second command never ran');
    }

    #[test]
    fn test_death_is_terminal() {
        let cmds: Array<TicCmd> = array![cmd(0, 60, 0), cmd(0, 60, 0), cmd(1, 0, 0)];
        let (state, output) = run_segment::<Toy, TicCmd, ToyEngine>(start(), cmds.span(), 0, 100);
        assert(output.status == Status::Dead, 'died');
        assert(output.tic_end == 2, 'stopped on death');
        assert(state.health == 0, 'health floored');
    }

    #[test]
    fn test_abort_instead_of_panic() {
        let cmds: Array<TicCmd> = array![cmd(1, 0, 0), cmd(0, 0, BT_ABORT), cmd(1, 0, 0)];
        let (state, output) = run_segment::<Toy, TicCmd, ToyEngine>(start(), cmds.span(), 0, 100);
        assert(output.status == Status::Abort, 'aborted');
        assert(output.tic_end == 2, 'the aborting tic counts');
        assert(state.position == 1, 'abort tic changed nothing');
        // An ABORT still produces a complete, readable output.
        assert(from_felts(to_felts(output).span()).is_some(), 'output is well formed');
    }

    #[test]
    fn test_stats_are_read_from_the_final_state() {
        let cmds: Array<TicCmd> = array![cmd(1, 0, BT_KILL), cmd(1, 0, BT_KILL), cmd(1, 0, 0)];
        let (_, output) = run_segment::<Toy, TicCmd, ToyEngine>(start(), cmds.span(), 0, 100);
        assert(output.stats == Stats { kills: 2, items: 0, secrets: 0 }, 'two kills');
    }

    #[test]
    fn test_tic_start_beyond_the_ceiling_aborts_without_trapping() {
        let cmds = walk(3);
        let (state, output) = run_segment::<
            Toy, TicCmd, ToyEngine,
        >(start(), cmds.span(), MAX_TIC + 1, 100);
        assert(output.status == Status::Abort, 'aborted');
        assert(output.tic_end == output.tic_start, 'no tics ran');
        assert(state == start(), 'state untouched');
    }

    #[test]
    fn test_tics_are_clamped_at_the_ceiling() {
        let cmds = walk(10);
        let (_, output) = run_segment::<
            Toy, TicCmd, ToyEngine,
        >(start(), cmds.span(), MAX_TIC - 3, 100);
        assert(output.tic_end == MAX_TIC, 'clamped at the ceiling');
    }

    // -- associativity -----------------------------------------------------

    /// `run(s, a ++ b) == run(run(s, a), b)` for the state, the hash chain
    /// and the stats. The `inputs_commitment` is deliberately *not* part of
    /// this: it is per segment, so splitting a run changes it (see the next
    /// test).
    #[test]
    fn test_associativity_of_splitting_a_segment() {
        let mut n: u32 = 0;
        while n != 10 {
            let mut all: Array<TicCmd> = array![];
            let mut i: u32 = 0;
            while i != 9 {
                all.append(cmd(1, 1, if i == 4 {
                    BT_KILL
                } else {
                    0
                }));
                i += 1;
            }
            let (whole_state, whole) = run_segment::<
                Toy, TicCmd, ToyEngine,
            >(start(), all.span(), 0, 100);
            let (mid_state, first) = run_segment::<
                Toy, TicCmd, ToyEngine,
            >(start(), all.span().slice(0, n), 0, 100);
            let (end_state, second) = run_segment::<
                Toy, TicCmd, ToyEngine,
            >(mid_state, all.span().slice(n, 9 - n), first.tic_end, 100);
            assert(end_state == whole_state, 'same final state');
            assert(second.h_out == whole.h_out, 'same final hash');
            assert(first.h_in == whole.h_in, 'same initial hash');
            assert(second.tic_end == whole.tic_end, 'same tic bounds');
            assert(second.stats == whole.stats, 'same stats');
            assert(continues(first, second), 'the halves chain');
            n += 1;
        }
    }

    #[test]
    fn test_continuity_predicate() {
        let cmds = walk(6);
        let (mid, first) = run_segment::<Toy, TicCmd, ToyEngine>(start(), cmds.span(), 0, 3);
        let (_, second) = run_segment::<
            Toy, TicCmd, ToyEngine,
        >(mid, cmds.span().slice(3, 3), first.tic_end, 3);
        assert(continues(first, second), 'consecutive segments chain');
        assert(!continues(second, first), 'not the other way round');
        let mut tampered = second;
        tampered.h_in = tampered.h_in + 1;
        assert(!continues(first, tampered), 'a changed h_in breaks it');
        let mut gap = second;
        gap.tic_start = gap.tic_start + 1;
        assert(!continues(first, gap), 'a tic gap breaks it');
        let mut ended = first;
        ended.status = Status::Exit;
        assert(!continues(ended, second), 'nothing follows an EXIT');
    }

    // -- the input-log commitment ------------------------------------------

    #[test]
    fn test_inputs_commitment_matches_the_packed_log() {
        let cmds: Array<TicCmd> = array![
            cmd(1, 0, 0), cmd(2, 0, 0), cmd(3, 0, 0), cmd(4, 0, 0), cmd(5, 0, 0), cmd(6, 0, 0),
            cmd(7, 0, 0), cmd(8, 0, 0), cmd(9, 0, 0),
        ];
        let (_, output) = run_segment::<Toy, TicCmd, ToyEngine>(start(), cmds.span(), 0, 100);
        // Independently: encode every command, pack seven to a felt, fold.
        let mut words: Array<felt252> = array![];
        let mut i: u32 = 0;
        while i != cmds.len() {
            words.append(encode(*cmds.at(i)));
            i += 1;
        }
        let packed = pack_log(words.span());
        let mut expected = inputs_seed();
        let mut j: u32 = 0;
        while j != packed.len() {
            expected = commit_input(expected, *packed.at(j));
            j += 1;
        }
        assert(output.inputs_commitment == expected, 'commitment matches the log');
    }

    /// Pinned against `bench/reference.py`, which recomputes the same
    /// value with `poseidon_py`. `encode(cmd(i, 0, 0))` is `0x808080 + i`,
    /// so the two sides describe the same nine tics.
    #[test]
    fn test_inputs_commitment_reference_vector() {
        let mut cmds: Array<TicCmd> = array![];
        let mut i: i64 = 0;
        while i != 9 {
            cmds.append(cmd(i, 0, 0));
            i += 1;
        }
        assert(encode(*cmds.at(0)) == 0x808080, 'first word');
        assert(encode(*cmds.at(8)) == 0x808088, 'ninth word');
        let (_, output) = run_segment::<Toy, TicCmd, ToyEngine>(start(), cmds.span(), 0, 100);
        assert(
            output
                .inputs_commitment == 0x5a1a00832b34d6773e3ac371ddb6dfa8fef9813b137df243faf9539da38cad2,
            'nine-tic commitment vector',
        );
    }

    #[test]
    fn test_inputs_commitment_is_sensitive_to_every_command() {
        let base = walk(8);
        let (_, reference) = run_segment::<Toy, TicCmd, ToyEngine>(start(), base.span(), 0, 100);
        let mut i: u32 = 0;
        while i != base.len() {
            let mut mutated: Array<TicCmd> = array![];
            let mut j: u32 = 0;
            while j != base.len() {
                mutated.append(if j == i {
                    cmd(2, 0, 0)
                } else {
                    *base.at(j)
                });
                j += 1;
            }
            let (_, changed) = run_segment::<
                Toy, TicCmd, ToyEngine,
            >(start(), mutated.span(), 0, 100);
            assert(
                changed.inputs_commitment != reference.inputs_commitment, 'every tic is committed',
            );
            i += 1;
        }
    }

    #[test]
    fn test_inputs_commitment_is_per_segment_not_chained() {
        let cmds = walk(8);
        let (mid, first) = run_segment::<Toy, TicCmd, ToyEngine>(start(), cmds.span(), 0, 4);
        let (_, second) = run_segment::<
            Toy, TicCmd, ToyEngine,
        >(mid, cmds.span().slice(4, 4), first.tic_end, 4);
        let (_, whole) = run_segment::<Toy, TicCmd, ToyEngine>(start(), cmds.span(), 0, 8);
        // Documented behaviour, asserted so it cannot change silently.
        assert(second.inputs_commitment != whole.inputs_commitment, 'per segment, not chained');
        assert(first.inputs_commitment != inputs_seed(), 'but it does commit');
    }

    #[test]
    fn test_hash_is_only_taken_at_the_boundaries() {
        // S3: the state must be (de)serialized only at segment boundaries.
        // The observable consequence is that a longer segment does not
        // change `h_in`, whatever happens in between.
        let short = walk(1);
        let long = walk(50);
        let (_, a) = run_segment::<Toy, TicCmd, ToyEngine>(start(), short.span(), 0, 100);
        let (_, b) = run_segment::<Toy, TicCmd, ToyEngine>(start(), long.span(), 0, 100);
        assert(a.h_in == b.h_in, 'h_in depends only on the state');
        assert(a.h_out != b.h_out, 'h_out follows the final state');
    }

    // -- transitional ------------------------------------------------------

    #[test]
    fn test_chain_commands_still_works() {
        let cmds: Array<TicCmd> = array![cmd(1, 0, 0), cmd(2, 0, 0)];
        let out = chain_commands(42, 10, cmds.span());
        assert(out.tic_start == 10 && out.tic_end == 12, 'tic bounds');
        assert(out.version == VERSION, 'version stamped');
        let empty: Array<TicCmd> = array![];
        let none = chain_commands(42, 0, empty.span());
        assert(none.h_in == none.h_out, 'empty batch is identity');
    }
}
