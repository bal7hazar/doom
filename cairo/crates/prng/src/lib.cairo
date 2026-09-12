// SPDX-License-Identifier: Apache-2.0

//! Table-driven, fully replayable pseudo-random generator.
//!
//! The generator owns **one felt of state** -- a cursor into a byte table
//! that the *caller* supplies on every draw. It therefore carries no data
//! of its own: the table is a parameter, never a constant of this crate
//! (PLAN.md A10; Doom's own `rndtable` lives in `cairo/doom/*`, never
//! here).
//!
//! Semantics match Doom's `M_Random`/`P_Random` shape: each draw reads
//! `table[index]` and advances `index` by one, wrapping at
//! [`TABLE_LEN`]. Doom keeps *two* cursors (`prndindex` for cosmetic
//! draws, `rndindex` for gameplay draws) so that cosmetic randomness
//! cannot desynchronise a demo; here that split is the caller's choice --
//! hold two [`Prng`] values and draw from whichever stream the effect
//! belongs to. Both are part of the hashed state, so an RNG divergence is
//! caught like any other state divergence.

pub mod compat;
pub use compat::{next, value};

/// Number of entries the table passed to every draw must have.
///
/// Fixed at 256 so that the cursor wrap is a single equality test rather
/// than a division (a `%` on `u32` costs ~15 steps, an equality ~3).
pub const TABLE_LEN: u32 = 256;

/// A single random stream: a cursor into the caller's table.
///
/// Invariant: `index < TABLE_LEN`. Every constructor in this crate
/// establishes it and every method preserves it, so `table.at(index)`
/// never traps as long as the table has `TABLE_LEN` entries.
#[derive(Copy, Drop, Serde, PartialEq, Debug, Default)]
pub struct Prng {
    pub index: u32,
}

/// Generator positioned at the start of the table.
pub fn new() -> Prng {
    Prng { index: 0 }
}

/// Generator positioned at `index`, folded into `[0, TABLE_LEN)`.
///
/// Total function: any `u32` is accepted, so a corrupted or attacker-chosen
/// seed can never make a draw trap (R4-A2).
pub fn from_index(index: u32) -> Prng {
    Prng { index: index % TABLE_LEN }
}

/// True when `table` can be used for a draw, i.e. it has exactly
/// [`TABLE_LEN`] entries. Callers validate their table once (at genesis or
/// in a test); the draw path does not re-check it.
pub fn is_valid_table(table: Span<u8>) -> bool {
    table.len() == TABLE_LEN
}

#[generate_trait]
pub impl PrngImpl of PrngTrait {
    /// The byte this generator would draw next, without advancing.
    fn peek(self: Prng, table: Span<u8>) -> u8 {
        *table.at(self.index)
    }

    /// Draw one byte and advance the cursor.
    ///
    /// The hot path: one span read at a variable index (10 steps) plus the
    /// wrap (7 steps: checked increment, equality, select) = **17 steps**
    /// net, measured (see README.md, "Measured costs"). Branching on the
    /// cursor rather than on `index + 1` saves one step, because the
    /// increment then only exists on one arm.
    fn next(self: Prng, table: Span<u8>) -> (Prng, u8) {
        let value = *table.at(self.index);
        let index = if self.index == TABLE_LEN - 1 {
            0
        } else {
            self.index + 1
        };
        (Prng { index }, value)
    }

    /// Doom's `P_Random() < threshold` idiom: a draw always happens, so
    /// RNG consumption is independent of the outcome (replay stability).
    fn chance(self: Prng, table: Span<u8>, threshold: u8) -> (Prng, bool) {
        let (rng, value) = self.next(table);
        (rng, value < threshold)
    }

    /// Doom's `P_Random() % n`. `n == 0` yields `0` instead of trapping,
    /// and still consumes exactly one draw (R4-A2).
    fn below(self: Prng, table: Span<u8>, n: u8) -> (Prng, u8) {
        let (rng, value) = self.next(table);
        if n == 0 {
            (rng, 0)
        } else {
            (rng, value % n)
        }
    }

    /// Doom's `P_SubRandom()`: two draws, `first - second`, in
    /// `[-255, 255]`. Consumes two entries of the table.
    fn sub_random(self: Prng, table: Span<u8>) -> (Prng, i32) {
        let (rng, a) = self.next(table);
        let (rng, b) = rng.next(table);
        let a32: i32 = a.into();
        let b32: i32 = b.into();
        (rng, a32 - b32)
    }

    /// Advance the cursor by `n` draws without reading the table.
    /// Total function for every `u32`.
    fn skip(self: Prng, n: u32) -> Prng {
        Prng { index: (self.index + n) % TABLE_LEN }
    }
}

#[cfg(test)]
mod tests {
    use super::{Prng, PrngTrait, TABLE_LEN, from_index, is_valid_table, new};

    /// Deterministic stand-in table. Mirrored by the Python reference in
    /// `bench/reference.py` so the vectors below are independent of Cairo.
    fn sample_table() -> Array<u8> {
        let mut t: Array<u8> = array![];
        let mut i: u32 = 0;
        while i != TABLE_LEN {
            let v: u32 = (i * 167 + 61) % 256;
            t.append(v.try_into().unwrap());
            i += 1;
        }
        t
    }

    #[test]
    fn test_new_starts_at_zero() {
        assert(new().index == 0, 'starts at zero');
    }

    #[test]
    fn test_from_index_folds_into_range() {
        assert(from_index(0).index == 0, 'zero stays zero');
        assert(from_index(255).index == 255, 'last stays last');
        assert(from_index(256).index == 0, 'wraps at table len');
        assert(from_index(4_294_967_295).index == 255, 'folds huge seeds');
    }

    #[test]
    fn test_is_valid_table() {
        assert(is_valid_table(sample_table().span()), 'full table is valid');
        let short: Array<u8> = array![1, 2, 3];
        assert(!is_valid_table(short.span()), 'short table is invalid');
    }

    /// Reference values: `table[i] = (i * 167 + 61) % 256`, drawn from
    /// index 0 -- computed independently by `bench/reference.py`.
    #[test]
    fn test_reference_vectors() {
        let table = sample_table();
        let rng = new();
        let (rng, v0) = rng.next(table.span());
        let (rng, v1) = rng.next(table.span());
        let (rng, v2) = rng.next(table.span());
        let (_, v3) = rng.next(table.span());
        assert(v0 == 61, 'draw 0 == 61');
        assert(v1 == 228, 'draw 1 == 228');
        assert(v2 == 139, 'draw 2 == 139');
        assert(v3 == 50, 'draw 3 == 50');
    }

    #[test]
    fn test_peek_does_not_advance() {
        let table = sample_table();
        let rng = from_index(17);
        let peeked = rng.peek(table.span());
        let (after, drawn) = rng.next(table.span());
        assert(peeked == drawn, 'peek equals next value');
        assert(rng.index == 17, 'peek left cursor alone');
        assert(after.index == 18, 'next advanced cursor');
    }

    #[test]
    fn test_next_is_deterministic() {
        let table = sample_table();
        let a = from_index(99).next(table.span());
        let b = from_index(99).next(table.span());
        assert(a == b, 'same state, same draw');
    }

    #[test]
    fn test_cursor_wraps_at_last_entry() {
        let table = sample_table();
        let (rng, _) = from_index(255).next(table.span());
        assert(rng.index == 0, 'wraps to zero');
    }

    #[test]
    fn test_full_period_returns_to_start() {
        let table = sample_table();
        let mut rng = from_index(7);
        let mut i: u32 = 0;
        while i != TABLE_LEN {
            let (n, _) = rng.next(table.span());
            rng = n;
            i += 1;
        }
        assert(rng.index == 7, 'period is exactly 256');
    }

    /// Property: over a full period every table entry is returned exactly
    /// once, whatever the starting cursor.
    #[test]
    fn test_period_is_a_permutation_of_the_table() {
        let table = sample_table();
        let mut rng = from_index(200);
        let mut sum: u32 = 0;
        let mut i: u32 = 0;
        while i != TABLE_LEN {
            let (n, v) = rng.next(table.span());
            rng = n;
            sum += v.into();
            i += 1;
        }
        let mut expected: u32 = 0;
        let mut j: u32 = 0;
        while j != TABLE_LEN {
            expected += (*table.at(j)).into();
            j += 1;
        }
        assert(sum == expected, 'reads every entry once');
    }

    #[test]
    fn test_chance_consumes_one_draw_either_way() {
        let table = sample_table();
        let (hit, is_hit) = new().chance(table.span(), 255);
        let (miss, is_miss) = new().chance(table.span(), 0);
        assert(is_hit, '61 < 255');
        assert(!is_miss, 'nothing is below 0');
        assert(hit.index == 1, 'hit consumed one draw');
        assert(miss.index == 1, 'miss consumed one draw');
    }

    #[test]
    fn test_below_bounds_and_zero_modulus() {
        let table = sample_table();
        let (rng, v) = new().below(table.span(), 8);
        assert(v < 8, 'below 8');
        assert(v == 5, '61 % 8 == 5');
        assert(rng.index == 1, 'one draw consumed');
        let (rng0, v0) = new().below(table.span(), 0);
        assert(v0 == 0, 'modulus zero yields zero');
        assert(rng0.index == 1, 'zero modulus still draws');
    }

    #[test]
    fn test_below_over_full_period_stays_in_range() {
        let table = sample_table();
        let mut rng = new();
        let mut i: u32 = 0;
        while i != TABLE_LEN {
            let (n, v) = rng.below(table.span(), 5);
            rng = n;
            assert(v < 5, 'always below modulus');
            i += 1;
        }
    }

    #[test]
    fn test_sub_random_range_and_consumption() {
        let table = sample_table();
        let (rng, d) = new().sub_random(table.span());
        assert(d == 61 - 228, 'first minus second');
        assert(rng.index == 2, 'two draws consumed');
        assert(d >= -255 && d <= 255, 'within doom range');
    }

    #[test]
    fn test_sub_random_is_zero_on_a_flat_table() {
        let mut flat: Array<u8> = array![];
        let mut i: u32 = 0;
        while i != TABLE_LEN {
            flat.append(42);
            i += 1;
        }
        let (_, d) = new().sub_random(flat.span());
        assert(d == 0, 'flat table cancels out');
    }

    #[test]
    fn test_skip_matches_repeated_draws() {
        let table = sample_table();
        let mut rng = new();
        let mut i: u32 = 0;
        while i != 5 {
            let (n, _) = rng.next(table.span());
            rng = n;
            i += 1;
        }
        assert(rng == new().skip(5), 'skip 5 == 5 draws');
        assert(new().skip(TABLE_LEN) == new(), 'skip a period is identity');
        assert(new().skip(4_294_967_295).index == 255, 'skip folds huge counts');
    }

    #[test]
    fn test_two_streams_are_independent() {
        // Doom's prndindex/rndindex split, held by the caller.
        let table = sample_table();
        let cosmetic = Prng { index: 10 };
        let gameplay = Prng { index: 200 };
        let (cosmetic, _) = cosmetic.next(table.span());
        let (gameplay2, v) = gameplay.next(table.span());
        assert(cosmetic.index == 11, 'cosmetic advanced alone');
        assert(gameplay2.index == 201, 'gameplay advanced alone');
        let (_, v_again) = gameplay.next(table.span());
        assert(v == v_again, 'cosmetic draw did not disturb');
    }

    #[test]
    fn test_serde_round_trip_is_one_felt() {
        let mut buf: Array<felt252> = array![];
        let rng = from_index(123);
        rng.serialize(ref buf);
        assert(buf.len() == 1, 'state is one felt');
        assert(*buf.at(0) == 123, 'state is the cursor');
    }
}
