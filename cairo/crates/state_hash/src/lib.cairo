// SPDX-License-Identifier: Apache-2.0

//! Canonical serialization and Poseidon hashing of game state.
//!
//! # Domain separation
//!
//! Every hash this crate produces is of the form
//!
//! ```text
//!   H(tag, version, data) = poseidon( tag ‖ version ‖ len(data) ‖ data )
//! ```
//!
//! * **`tag`** names the *kind* of record (a short string literal, e.g.
//!   `'HP.STATE'`). Two different record types can never collide, even if
//!   their felt encodings happen to coincide.
//! * **`version`** is the schema version of that record's encoding. A field
//!   added to `GameState` bumps it, and every hash changes — which is the
//!   point: an old replay must not silently validate against a new schema.
//! * **`len(data)`** pins the length, so a short record followed by other
//!   data can never be confused with a longer one (the classic
//!   concatenation attack: `H('a' ‖ 'bc')` vs `H('ab' ‖ 'c')`).
//!
//! Tags in [`tag`] are reserved by the state stack. Game crates pick their
//! own and must not reuse those.
//!
//! # Two ways to hash, and when to use which
//!
//! [`open`] gives an `Array` that already holds the header; the serializer
//! appends its fields to it and [`seal`] hashes the whole thing. Nothing is
//! ever copied, and that is the cheap path: **14.5 steps per felt**, of
//! which 10.5 are Poseidon (S1 §5.8's figure, reproduced here) and 4 the
//! append. A 4 000-felt state costs ~58 000 steps that way.
//!
//! [`hash_tagged`] is the convenience form, for data that already exists as
//! a span. It has to copy that span in behind the header, which costs
//! **35.5 steps per felt** — 2.4× the open/seal path. Use it for small
//! records and tests, not for a game state.
//!
//! A streaming `Digest` built on `core`'s Poseidon `HashState` was
//! implemented and measured too: **18.5 steps per felt**, worse than
//! open/seal despite never allocating, because `HashState::update` absorbs
//! one felt at a time with a parity branch while `poseidon_hash_span`
//! absorbs two per permutation. It was removed rather than kept as a trap.
//!
//! # Input-log commitment
//!
//! [`commit_input`] folds one packed transport felt (7 tics, see the
//! `ticcmd` crate) into a running commitment, starting from
//! [`inputs_seed`]. A segment publishes the final value; anyone holding the
//! packed log can recompute it and check it against the proof. It is
//! Starknet's 2-to-1 Poseidon (7 steps), not `poseidon_hash_span` of a
//! two-element array (48).

use core::poseidon::{hades_permutation, poseidon_hash_span};

/// Schema version of the encodings defined *by this crate* (the segment
/// output layout and the input-log commitment). Game records carry their
/// own version through [`hash_tagged`].
pub const SCHEMA_VERSION: felt252 = 1;

/// Domain tags reserved by the state stack. Game crates must not reuse
/// these values for their own records.
pub mod tag {
    /// A serialized `GameState`.
    pub const STATE: felt252 = 'HP.STATE';
    /// The public output record of a segment.
    pub const SEGMENT_OUTPUT: felt252 = 'HP.SEGOUT';
    /// The running commitment over a packed input log.
    pub const INPUT_LOG: felt252 = 'HP.INPUTS';
}

/// `poseidon(tag ‖ version ‖ len(data) ‖ data)`.
///
/// The canonical hash of one record. See the module docs for why all three
/// prefix felts are there.
pub fn hash_tagged(tag: felt252, version: felt252, data: Span<felt252>) -> felt252 {
    let mut buf: Array<felt252> = array![tag, version, data.len().into()];
    let mut i: u32 = 0;
    while i != data.len() {
        buf.append(*data.at(i));
        i += 1;
    }
    poseidon_hash_span(buf.span())
}

/// [`hash_tagged`] at this crate's [`SCHEMA_VERSION`].
pub fn hash_record(tag: felt252, data: Span<felt252>) -> felt252 {
    hash_tagged(tag, SCHEMA_VERSION, data)
}

/// Open a canonical buffer: an `Array` already holding the record header
/// `[tag, version, fields]`, ready for the fields to be appended.
///
/// `open` + append + [`seal`] is the cheapest way to hash a state — 14.5
/// steps per felt, of which 4 are the append and 10.5 Poseidon itself —
/// because nothing is ever copied. [`hash_tagged`] has to copy the data
/// behind the header and costs 35.5 steps per felt, so it is for small
/// records and tests, not for a 4 000-felt game state.
pub fn open(tag: felt252, version: felt252, fields: u32) -> Array<felt252> {
    array![tag, version, fields.into()]
}

/// Close a buffer opened by [`open`]: the Poseidon hash of the whole
/// buffer, header included.
pub fn seal(buf: Span<felt252>) -> felt252 {
    poseidon_hash_span(buf)
}

/// Canonical hash of a serialized game state: `H(tag::STATE,
/// SCHEMA_VERSION, values)`.
///
/// Convenience only — it goes through [`hash_tagged`] and therefore copies
/// `values`. A serializer that knows its own length should build its buffer
/// with `open(tag::STATE, SCHEMA_VERSION, n)` and close it with [`seal`]
/// instead: 14.5 steps per felt rather than 35.5, which on a 4 000-felt
/// state is 58 000 steps against 142 000.
pub fn hash_game_state(values: Span<felt252>) -> felt252 {
    hash_record(tag::STATE, values)
}

/// The starting value of an input-log commitment: the empty log.
pub fn inputs_seed() -> felt252 {
    hash_record(tag::INPUT_LOG, array![].span())
}

/// Fold one packed transport felt into a running input-log commitment.
///
/// `commitment_0 = inputs_seed()`, `commitment_{i+1} = commit_input(
/// commitment_i, packed_i)`. Order-sensitive, so a reordered log gives a
/// different commitment; the number of tics is pinned separately by the
/// segment output's `tic_start`/`tic_end`, which is what disambiguates a
/// short final group.
///
/// This is Starknet's **2-to-1** Poseidon — one Hades permutation over
/// `(prev, packed, 2)` — not `poseidon_hash_span([prev, packed])`, which
/// pads and costs 48 steps against 15. It is the same function as
/// `poseidon_hash(a, b)` in starknet.js and `poseidon_py`, so a verifier
/// recomputes the chain with a one-liner.
pub fn commit_input(prev: felt252, packed: felt252) -> felt252 {
    let (commitment, _, _) = hades_permutation(prev, packed, 2);
    commitment
}

// ---------------------------------------------------------------------------
// Canonical serialization helpers
//
// A record is: a header, then exactly `fields` felts, appended in a fixed
// order. Every value is stored non-negative and below 2^72 where the
// caller has a choice (A7 / S1 §5.2).
// ---------------------------------------------------------------------------

/// Append a record header — `tag`, `version`, `fields` — to `out`.
///
/// A record written this way is self-describing inside a larger state
/// array, so a reader can walk a state without a separate schema, and two
/// record kinds can never be confused for one another.
pub fn append_header(ref out: Array<felt252>, tag: felt252, version: felt252, fields: u32) {
    out.append(tag);
    out.append(version);
    out.append(fields.into());
}

/// Append a `u32` field.
pub fn append_u32(ref out: Array<felt252>, value: u32) {
    out.append(value.into());
}

/// Append a `u8` field.
pub fn append_u8(ref out: Array<felt252>, value: u8) {
    out.append(value.into());
}

/// Append a boolean field as 0 or 1.
pub fn append_bool(ref out: Array<felt252>, value: bool) {
    out.append(if value {
        1
    } else {
        0
    });
}

/// Append a signed field in offset form: `value + offset`.
///
/// The caller picks `offset` so the result is non-negative and stays below
/// 2^72 — S1 §5.2 measured that as free in steps and as avoiding both the
/// 33 % `range_check_9_9` penalty and the 10-step sign test a raw negative
/// felt costs.
pub fn append_biased(ref out: Array<felt252>, value: i64, offset: i64) {
    out.append((value + offset).into());
}

/// Append a length-prefixed span of felts.
pub fn append_span(ref out: Array<felt252>, values: Span<felt252>) {
    out.append(values.len().into());
    let mut i: u32 = 0;
    while i != values.len() {
        out.append(*values.at(i));
        i += 1;
    }
}

/// The `Hashable` pattern: a type that knows its domain tag, its schema
/// version, how many felts it writes, and how to write them.
///
/// Declaring `fields` up front is what lets [`hash_of`] and
/// [`append_record`] write the header *before* the fields and never copy
/// anything (see the module docs on cost). For a fixed-size record it is a
/// constant; for a variable-size one it is `count × felts_per_item`, plus
/// one for the count itself if [`append_span`] is used.
/// `test_hashable_declares_its_own_length` is the check that the two agree.
pub trait Hashable<T> {
    /// Domain tag of this record kind. Must be unique in the program.
    fn tag(self: @T) -> felt252;
    /// Schema version of this record's encoding.
    fn version(self: @T) -> felt252;
    /// Number of felts [`Hashable::append_to`] writes.
    fn fields(self: @T) -> u32;
    /// Append the record's fields — not its header — to `out`.
    fn append_to(self: @T, ref out: Array<felt252>);
}

/// The canonical hash of any [`Hashable`], with no intermediate copy.
pub fn hash_of<T, +Hashable<T>>(value: @T) -> felt252 {
    let mut buf = open(value.tag(), value.version(), value.fields());
    value.append_to(ref buf);
    seal(buf.span())
}

/// Append a [`Hashable`] with its header, as one record inside a larger
/// buffer.
pub fn append_record<T, +Hashable<T>>(ref out: Array<felt252>, value: @T) {
    append_header(ref out, value.tag(), value.version(), value.fields());
    value.append_to(ref out);
}

// ---------------------------------------------------------------------------
// TRANSITIONAL -- delete with P1.3.
//
// `doom_game` calls `hash_state`, and `segment::chain_commands` calls
// `chain`. Both predate the domain-separation scheme above and are kept so
// the workspace builds.
// ---------------------------------------------------------------------------

/// Untagged Poseidon hash of a span. Prefer [`hash_game_state`].
pub fn hash_state(values: Span<felt252>) -> felt252 {
    poseidon_hash_span(values)
}

/// Untagged fold of `prev` with a batch. Prefer [`commit_input`].
pub fn chain(prev: felt252, values: Span<felt252>) -> felt252 {
    let mut combined: Array<felt252> = array![prev];
    let mut i: u32 = 0;
    while i != values.len() {
        combined.append(*values.at(i));
        i += 1;
    }
    poseidon_hash_span(combined.span())
}

#[cfg(test)]
mod tests {
    use super::{
        Hashable, SCHEMA_VERSION, append_biased, append_bool, append_header, append_record,
        append_span, append_u32, append_u8, chain, commit_input, hash_game_state, hash_of,
        hash_record, hash_state, hash_tagged, inputs_seed, open, seal, tag,
    };

    #[derive(Copy, Drop)]
    struct Player {
        x: i64,
        y: i64,
        health: u32,
        alive: bool,
    }

    const PLAYER_TAG: felt252 = 'TEST.PLAYER';
    const COORD_BIAS: i64 = 0x10000;

    /// Values computed by `bench/reference.py` with `poseidon_py`, an
    /// implementation of Poseidon this repository did not write.
    const REFERENCE_TAGGED: felt252 =
        0x4678737b74be36630ceff80c6c70c61c2da5e0c373a99228d8d158e61350ca7;
    const REFERENCE_INPUTS_SEED: felt252 =
        0x2d5e13ed7c628cddeebe8a20c5aec4389f3c922e8276979479be592bd4f963e;
    const REFERENCE_COMMIT_111: felt252 =
        0x724d2f08e0425f78107ea6c830729ff38c59bf54d1a9ff641cbb1a497a89580;

    impl PlayerHashable of Hashable<Player> {
        fn tag(self: @Player) -> felt252 {
            PLAYER_TAG
        }
        fn version(self: @Player) -> felt252 {
            1
        }
        fn fields(self: @Player) -> u32 {
            4
        }
        fn append_to(self: @Player, ref out: Array<felt252>) {
            append_biased(ref out, *self.x, COORD_BIAS);
            append_biased(ref out, *self.y, COORD_BIAS);
            append_u32(ref out, *self.health);
            append_bool(ref out, *self.alive);
        }
    }

    fn sample_player() -> Player {
        Player { x: -100, y: 250, health: 100, alive: true }
    }

    // -- reference values --------------------------------------------------
    //
    // Cross-checked against `bench/reference.py`, which recomputes them
    // with starknet-py's independent Poseidon implementation when it is
    // installed.

    #[test]
    fn test_reference_vectors() {
        assert(
            hash_tagged(0, 0, array![].span()) == hash_tagged(0, 0, array![].span()),
            'deterministic',
        );
        // Pinned so a change to the scheme cannot pass unnoticed. Value
        // computed independently by `bench/reference.py` (poseidon_py).
        let h = hash_tagged('T', 1, array![1, 2, 3].span());
        assert(h == REFERENCE_TAGGED, 'tagged vector');
        assert(inputs_seed() == REFERENCE_INPUTS_SEED, 'inputs seed vector');
        assert(commit_input(REFERENCE_INPUTS_SEED, 111) == REFERENCE_COMMIT_111, 'commit vector');
    }

    // -- domain separation -------------------------------------------------

    #[test]
    fn test_different_tags_never_collide() {
        let data: Array<felt252> = array![1, 2, 3];
        let a = hash_tagged('A', 1, data.span());
        let b = hash_tagged('B', 1, data.span());
        assert(a != b, 'tag separates');
    }

    #[test]
    fn test_different_versions_never_collide() {
        let data: Array<felt252> = array![1, 2, 3];
        assert(hash_tagged('A', 1, data.span()) != hash_tagged('A', 2, data.span()), 'version');
    }

    /// The concatenation attack the length prefix exists to stop: two
    /// different splits of the same felts must hash differently.
    #[test]
    fn test_length_prefix_stops_concatenation() {
        let short: Array<felt252> = array![1];
        let long: Array<felt252> = array![1, 2];
        // Without the length prefix, H('A', 1, [1]) followed by 2 and
        // H('A', 1, [1, 2]) would absorb the same sequence.
        let a = hash_tagged('A', 1, short.span());
        let b = hash_tagged('A', 1, long.span());
        assert(a != b, 'length is bound');
        // And a record whose data starts with its own length is still
        // distinct from the shorter one.
        let tricky: Array<felt252> = array![1, 1];
        assert(hash_tagged('A', 1, tricky.span()) != b, 'no ambiguity');
    }

    #[test]
    fn test_hash_is_sensitive_to_every_felt() {
        let base: Array<felt252> = array![10, 20, 30, 40];
        let reference = hash_tagged('A', 1, base.span());
        let mut i: u32 = 0;
        while i != base.len() {
            let mut mutated: Array<felt252> = array![];
            let mut j: u32 = 0;
            while j != base.len() {
                mutated.append(if j == i {
                    *base.at(j) + 1
                } else {
                    *base.at(j)
                });
                j += 1;
            }
            assert(hash_tagged('A', 1, mutated.span()) != reference, 'felt flip changes hash');
            i += 1;
        }
    }

    #[test]
    fn test_hash_is_order_sensitive() {
        let a: Array<felt252> = array![1, 2];
        let b: Array<felt252> = array![2, 1];
        assert(hash_tagged('A', 1, a.span()) != hash_tagged('A', 1, b.span()), 'order matters');
    }

    #[test]
    fn test_reserved_tags_are_distinct() {
        assert(tag::STATE != tag::SEGMENT_OUTPUT, 'state vs segout');
        assert(tag::STATE != tag::INPUT_LOG, 'state vs inputs');
        assert(tag::SEGMENT_OUTPUT != tag::INPUT_LOG, 'segout vs inputs');
    }

    #[test]
    fn test_hash_record_and_game_state_use_the_scheme() {
        let data: Array<felt252> = array![7];
        assert(
            hash_record('A', data.span()) == hash_tagged('A', SCHEMA_VERSION, data.span()),
            'hash_record',
        );
        assert(
            hash_game_state(data.span()) == hash_record(tag::STATE, data.span()), 'hash_game_state',
        );
    }

    // -- the streaming digest ---------------------------------------------

    /// `open` + append + `seal` is the cheap path; it must give exactly the
    /// same value as the convenience `hash_tagged`, at every length (a
    /// sponge pads odd and even lengths differently).
    #[test]
    fn test_open_seal_matches_hash_tagged_at_every_length() {
        let mut n: u32 = 0;
        while n != 12 {
            let mut data: Array<felt252> = array![];
            let mut buf = open('A', SCHEMA_VERSION, n);
            let mut i: u32 = 0;
            while i != n {
                let value: felt252 = i.into() * 7 + 3;
                data.append(value);
                buf.append(value);
                i += 1;
            }
            assert(buf.len() == n + 3, 'header plus n fields');
            assert(seal(buf.span()) == hash_record('A', data.span()), 'agrees at this length');
            n += 1;
        }
    }

    #[test]
    fn test_open_writes_the_header() {
        let buf = open('A', 9, 4);
        assert(buf.len() == 3, 'header only');
        assert(*buf.at(0) == 'A', 'tag');
        assert(*buf.at(1) == 9, 'version');
        assert(*buf.at(2) == 4, 'field count');
    }

    #[test]
    fn test_declaring_the_wrong_length_changes_the_hash() {
        let data: Array<felt252> = array![1, 2, 3];
        let mut wrong = open('A', SCHEMA_VERSION, 2);
        let mut i: u32 = 0;
        while i != data.len() {
            wrong.append(*data.at(i));
            i += 1;
        }
        assert(seal(wrong.span()) != hash_record('A', data.span()), 'length is bound');
    }

    // -- the input-log commitment ------------------------------------------

    #[test]
    fn test_inputs_commitment_chain() {
        let seed = inputs_seed();
        let a = commit_input(seed, 111);
        let b = commit_input(a, 222);
        assert(a != seed, 'first felt moves it');
        assert(b != a, 'second felt moves it');
        assert(commit_input(seed, 111) == a, 'deterministic');
    }

    #[test]
    fn test_inputs_commitment_is_order_sensitive() {
        let seed = inputs_seed();
        let forward = commit_input(commit_input(seed, 1), 2);
        let backward = commit_input(commit_input(seed, 2), 1);
        assert(forward != backward, 'order matters');
    }

    #[test]
    fn test_inputs_seed_is_domain_separated() {
        assert(inputs_seed() != hash_record(tag::STATE, array![].span()), 'seed is tagged');
        assert(inputs_seed() != 0, 'seed is not zero');
    }

    // -- serialization helpers ---------------------------------------------

    #[test]
    fn test_append_helpers_write_the_expected_felts() {
        let mut out: Array<felt252> = array![];
        append_header(ref out, 'A', 3, 5);
        append_u32(ref out, 42);
        append_u8(ref out, 7);
        append_bool(ref out, true);
        append_bool(ref out, false);
        append_biased(ref out, -5, 100);
        assert(out.len() == 8, 'header plus five fields');
        assert(*out.at(0) == 'A', 'tag');
        assert(*out.at(1) == 3, 'version');
        assert(*out.at(2) == 5, 'field count');
        assert(*out.at(3) == 42, 'u32');
        assert(*out.at(4) == 7, 'u8');
        assert(*out.at(5) == 1, 'true');
        assert(*out.at(6) == 0, 'false');
        assert(*out.at(7) == 95, 'biased');
    }

    #[test]
    fn test_append_span_is_length_prefixed() {
        let mut out: Array<felt252> = array![];
        append_span(ref out, array![9, 8].span());
        append_span(ref out, array![].span());
        assert(out.len() == 4, 'two spans');
        assert(*out.at(0) == 2, 'length');
        assert(*out.at(1) == 9 && *out.at(2) == 8, 'values');
        assert(*out.at(3) == 0, 'empty span length');
    }

    #[test]
    fn test_biased_fields_stay_non_negative_and_small() {
        // A7: an encoded coordinate must be non-negative and below 2^72.
        let mut out: Array<felt252> = array![];
        append_biased(ref out, -0xFFFF, 0x10000);
        append_biased(ref out, 0xFFFF, 0x10000);
        let mut i: u32 = 0;
        while i != out.len() {
            let value: u128 = (*out.at(i)).try_into().unwrap();
            assert(value < 0x1000000000000000000, 'below 2^72');
            i += 1;
        }
    }

    // -- the Hashable pattern ----------------------------------------------

    #[test]
    fn test_hashable_round_trip() {
        let player = sample_player();
        let mut fields: Array<felt252> = array![];
        player.append_to(ref fields);
        assert(fields.len() == 4, 'four fields');
        assert(hash_of(@player) == hash_tagged(PLAYER_TAG, 1, fields.span()), 'hash_of');
    }

    /// The invariant that makes the copy-free path safe: what `append_to`
    /// writes must be exactly what `fields` promised.
    #[test]
    fn test_hashable_declares_its_own_length() {
        let player = sample_player();
        let mut fields: Array<felt252> = array![];
        player.append_to(ref fields);
        assert(fields.len() == player.fields(), 'declared length is honest');
    }

    #[test]
    fn test_hashable_is_sensitive_to_every_field() {
        let player = sample_player();
        let reference = hash_of(@player);
        let mut moved = player;
        moved.x += 1;
        assert(hash_of(@moved) != reference, 'x');
        let mut moved = player;
        moved.y += 1;
        assert(hash_of(@moved) != reference, 'y');
        let mut moved = player;
        moved.health += 1;
        assert(hash_of(@moved) != reference, 'health');
        let mut moved = player;
        moved.alive = false;
        assert(hash_of(@moved) != reference, 'alive');
    }

    #[test]
    fn test_append_record_writes_a_self_describing_record() {
        let player = sample_player();
        let mut out: Array<felt252> = array![];
        out.append(999);
        append_record(ref out, @player);
        assert(out.len() == 8, 'prefix, header, four fields');
        assert(*out.at(0) == 999, 'prefix untouched');
        assert(*out.at(1) == PLAYER_TAG, 'tag');
        assert(*out.at(2) == 1, 'version');
        assert(*out.at(3) == 4, 'field count');
    }

    #[test]
    fn test_two_records_in_one_buffer_stay_distinguishable() {
        let player = sample_player();
        let mut a: Array<felt252> = array![];
        append_record(ref a, @player);
        append_record(ref a, @player);
        let mut b: Array<felt252> = array![];
        append_record(ref b, @player);
        assert(a.len() == 2 * b.len(), 'two records');
        assert(hash_record(tag::STATE, a.span()) != hash_record(tag::STATE, b.span()), 'distinct');
    }

    // -- transitional ------------------------------------------------------

    #[test]
    fn test_legacy_helpers_still_work() {
        let values: Array<felt252> = array![1, 2, 3];
        assert(hash_state(values.span()) == hash_state(values.span()), 'deterministic');
        assert(chain(0, values.span()) != chain(1, values.span()), 'depends on prev');
        // The legacy helpers are untagged, so they must not accidentally
        // equal the tagged ones.
        assert(hash_state(values.span()) != hash_game_state(values.span()), 'untagged differs');
    }
}
