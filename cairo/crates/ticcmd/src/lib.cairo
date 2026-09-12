// SPDX-License-Identifier: Apache-2.0

//! One tic of player input: encoding, decoding, and the packed transport
//! form used for on-chain replay events and compact input logs.
//!
//! # Wire formats
//!
//! There are exactly two, and they are not interchangeable:
//!
//! **The word** (`encode`/`decode`) — one 32-bit value per tic, held in a
//! `felt252`. This is what the proving path consumes, one felt per tic,
//! because decoding it is cheap: 64 steps for a full `TicCmd`, 31 for the
//! raw offsets, against the 106 S1 §5.1 measured for a 5-field 16-bit
//! packed record (see README.md).
//!
//! ```text
//!   bits  0..7   forward + 128        (forward in [-128, 127])
//!   bits  8..15  side    + 128        (side    in [-128, 127])
//!   bits 16..23  turn / 256 + 128     (turn in [-32768, 32512], step 256)
//!   bits 24..31  buttons              (0..255)
//! ```
//!
//! Every field is stored as a non-negative offset, per S1 §5.2 (offset
//! encoding beats raw negative felts by 10 steps per sign test) and A7 (a
//! word is < 2^32, far below the 2^72 range-check cliff).
//!
//! `turn` is quantised to 256 BAM, which is exactly what Doom's own `.lmp`
//! demo format does (`G_WriteDemoTiccmd` writes `angleturn >> 8`), and is
//! what makes a tic fit in 4 bytes as CONTEXT.md §9 budgets. Build commands
//! with [`quantize`] so they are canonical by construction.
//!
//! **The transport felt** (`pack7`/`unpack7`) — seven words packed into one
//! felt, `w0 + w1·2^32 + … + w6·2^192` (at most 2^224, so it always fits).
//! 7 tics/felt is the density CONTEXT.md §9 assumes (~900 felts for a
//! 3-minute run). The proving path never *unpacks* — unpacking costs 101
//! steps per group against 12 per tic for the streaming [`Packer`] — it
//! consumes words and re-packs them to recompute the input-log commitment.
//! `pack7`/`unpack7` are for the client, the replay tool and the on-chain
//! event.

/// Inclusive bounds of `forward` and `side` (Doom's `char` movement).
pub const MOVE_MIN: i64 = -128;
pub const MOVE_MAX: i64 = 127;

/// Granularity of `angle_turn`, in BAM. Doom's demo format stores
/// `angleturn >> 8`, so a turn is always a multiple of 256 BAM.
pub const TURN_UNIT: i64 = 256;
/// Inclusive bounds of `angle_turn`, in BAM (`-128 * 256` … `127 * 256`).
pub const TURN_MIN: i64 = -32768;
pub const TURN_MAX: i64 = 32512;

/// Tics packed into one transport felt.
pub const TICS_PER_FELT: u32 = 7;
/// Width of one encoded tic, in bits.
pub const WORD_BITS: u32 = 32;

const OFFSET: i64 = 128;
const OFFSET_FELT: felt252 = 128;
const TURN_UNIT_FELT: felt252 = 256;
const BYTE: u32 = 256;
const B1: felt252 = 0x100;
const B2: felt252 = 0x10000;
const B3: felt252 = 0x1000000;
/// 2^32, the shift between two tics inside a transport felt.
const WORD_SHIFT: felt252 = 0x100000000;
const WORD_SHIFT_U128: u128 = 0x100000000;
/// 2^224 = `WORD_SHIFT ^ TICS_PER_FELT`: a full group.
const GROUP_SHIFT: felt252 = 0x100000000000000000000000000000000000000000000000000000000;

/// One tic of player input.
///
/// Field *types* are `i64` (and `u8`) so that the value can be fed straight
/// to `fixed::from_int`; the *ranges* are Doom's: `forward`/`side` are
/// i8-like, `angle_turn` is i16-like with a 256-BAM step, `buttons` is a
/// bitfield this crate never interprets.
///
/// A command whose fields respect those ranges is called **canonical**;
/// only canonical commands can be encoded ([`is_canonical`],
/// [`quantize`]).
#[derive(Copy, Drop, Serde, PartialEq, Debug, Default)]
pub struct TicCmd {
    pub forward: i64,
    pub side: i64,
    pub angle_turn: i64,
    pub buttons: u8,
}

/// The all-zero command (no movement, no buttons).
pub fn idle() -> TicCmd {
    TicCmd { forward: 0, side: 0, angle_turn: 0, buttons: 0 }
}

/// True when every field is in range and `angle_turn` is a multiple of
/// [`TURN_UNIT`], i.e. when the command can be encoded losslessly.
pub fn is_canonical(cmd: TicCmd) -> bool {
    if cmd.forward < MOVE_MIN || cmd.forward > MOVE_MAX {
        return false;
    }
    if cmd.side < MOVE_MIN || cmd.side > MOVE_MAX {
        return false;
    }
    if cmd.angle_turn < TURN_MIN || cmd.angle_turn > TURN_MAX {
        return false;
    }
    turn_units(cmd.angle_turn) * TURN_UNIT == cmd.angle_turn
}

/// Clamp every field into range and snap `angle_turn` to [`TURN_UNIT`]
/// (towards minus infinity, like an arithmetic shift right). The result is
/// always canonical, for any input: this is the function the input-capture
/// path should build commands with.
pub fn quantize(cmd: TicCmd) -> TicCmd {
    let forward = clamp(cmd.forward, MOVE_MIN, MOVE_MAX);
    let side = clamp(cmd.side, MOVE_MIN, MOVE_MAX);
    let turn = clamp(cmd.angle_turn, TURN_MIN, TURN_MAX);
    TicCmd { forward, side, angle_turn: turn_units(turn) * TURN_UNIT, buttons: cmd.buttons }
}

/// `angle_turn` in units of [`TURN_UNIT`], rounded towards minus infinity
/// so that the mapping is monotone and `quantize` is idempotent.
fn turn_units(turn: i64) -> i64 {
    // Cairo's `/` on signed integers truncates towards zero; shift into the
    // non-negative domain first so the rounding is uniform (and no felt
    // division is ever used -- S1, transverse rule 3).
    let offset: i64 = (turn - TURN_MIN) / TURN_UNIT;
    offset + TURN_MIN / TURN_UNIT
}

fn clamp(value: i64, low: i64, high: i64) -> i64 {
    if value < low {
        low
    } else if value > high {
        high
    } else {
        value
    }
}

/// Encode one tic into its 32-bit word, or `None` when the command is not
/// canonical. Total function.
pub fn try_encode(cmd: TicCmd) -> Option<felt252> {
    if !is_canonical(cmd) {
        return Option::None;
    }
    let forward: felt252 = (cmd.forward + OFFSET).into();
    let side: felt252 = (cmd.side + OFFSET).into();
    let turn: felt252 = (turn_units(cmd.angle_turn) + OFFSET).into();
    let buttons: felt252 = cmd.buttons.into();
    Option::Some(forward + side * B1 + turn * B2 + buttons * B3)
}

/// Encode one tic into its 32-bit word.
///
/// Panics on a non-canonical command: that is a caller bug, and this
/// function runs on the input-capture path (off the proving path), where a
/// loud failure is wanted rather than a silently truncated input. Use
/// [`try_encode`] where a panic is not acceptable, and [`quantize`] to make
/// any command canonical first.
pub fn encode(cmd: TicCmd) -> felt252 {
    match try_encode(cmd) {
        Option::Some(word) => word,
        Option::None => core::panic_with_felt252('ticcmd: not canonical'),
    }
}

/// The four raw byte fields of a word, still in their non-negative offset
/// form: `(forward + 128, side + 128, turn / 256 + 128, buttons)`.
///
/// This is the cheap half of decoding (three `DivRem`s); a caller that can
/// work in offset space should use it and skip [`decode`]'s sign
/// conversions.
///
/// Panics if `word` is not a 32-bit value; see [`try_decode`].
pub fn decode_offsets(word: felt252) -> (u32, u32, u32, u32) {
    let packed: u32 = word.try_into().unwrap();
    let divisor: NonZero<u32> = BYTE.try_into().unwrap();
    let (rest, forward) = DivRem::div_rem(packed, divisor);
    let (rest, side) = DivRem::div_rem(rest, divisor);
    let (buttons, turn) = DivRem::div_rem(rest, divisor);
    (forward, side, turn, buttons)
}

/// Decode one tic from its 32-bit word. Inverse of [`encode`] on every
/// canonical command.
///
/// Panics if `word` is not a 32-bit value; see [`try_decode`].
pub fn decode(word: felt252) -> TicCmd {
    let (forward, side, turn, buttons) = decode_offsets(word);
    // De-bias in `felt252` and convert once per field: a felt subtraction
    // costs 1 step and a felt -> i64 conversion 7, against ~17 for
    // converting first and subtracting in `i64` (which range-checks the
    // subtraction). Measured: 86 steps the naive way, 64 this way.
    let forward: felt252 = forward.into() - OFFSET_FELT;
    let side: felt252 = side.into() - OFFSET_FELT;
    let turn: felt252 = (turn.into() - OFFSET_FELT) * TURN_UNIT_FELT;
    TicCmd {
        forward: forward.try_into().unwrap(),
        side: side.try_into().unwrap(),
        angle_turn: turn.try_into().unwrap(),
        buttons: buttons.try_into().unwrap(),
    }
}

/// Decode one tic, or `None` when `word` is not a 32-bit value. Total
/// function: this is what a segment runner uses so that a corrupted input
/// log becomes `ABORT` rather than a panic (R4-A2).
pub fn try_decode(word: felt252) -> Option<TicCmd> {
    let packed: Option<u32> = word.try_into();
    match packed {
        Option::Some(_) => Option::Some(decode(word)),
        Option::None => Option::None,
    }
}

/// Pack up to [`TICS_PER_FELT`] words into one transport felt, little-end
/// first: `w0 + w1·2^32 + … + w6·2^192`.
///
/// A short group (the tail of a log) is packed as-is; the missing words
/// read back as zero, so the *number of tics* must be carried separately —
/// `SegmentOutput`'s `tic_start`/`tic_end` do that on the proving path, and
/// [`unpack7_n`] takes it explicitly off it.
///
/// Words beyond the seventh are ignored. 18 steps per group.
pub fn pack7(words: Span<felt252>) -> felt252 {
    let mut packed: felt252 = 0;
    let mut shift: felt252 = 1;
    let mut i: u32 = 0;
    let count = if words.len() < TICS_PER_FELT {
        words.len()
    } else {
        TICS_PER_FELT
    };
    while i != count {
        packed = packed + *words.at(i) * shift;
        shift = shift * WORD_SHIFT;
        i += 1;
    }
    packed
}

/// Unpack a full group of [`TICS_PER_FELT`] words from a transport felt.
///
/// Total function: any felt is accepted, and bits at or above 2^224 (which
/// `pack7` never sets) are discarded.
///
/// A group is exactly 224 bits = 128 + 96, so the two `u256` limbs split
/// cleanly: four words come out of the low limb and three out of the high
/// one, with six `u128` divisions in all. Doing the same work with `u256`
/// divisions costs 1 205 steps against 220 (see bench/README.md).
pub fn unpack7(packed: felt252) -> Array<felt252> {
    let value: u256 = packed.into();
    let divisor: NonZero<u128> = WORD_SHIFT_U128.try_into().unwrap();
    let (low, word0) = DivRem::div_rem(value.low, divisor);
    let (low, word1) = DivRem::div_rem(low, divisor);
    let (word3, word2) = DivRem::div_rem(low, divisor);
    let (high, word4) = DivRem::div_rem(value.high, divisor);
    let (high, word5) = DivRem::div_rem(high, divisor);
    let (_, word6) = DivRem::div_rem(high, divisor);
    array![
        word0.into(), word1.into(), word2.into(), word3.into(), word4.into(), word5.into(),
        word6.into(),
    ]
}

/// Unpack the first `count` words (`count` above [`TICS_PER_FELT`] is
/// clamped) of a transport felt. Total function.
pub fn unpack7_n(packed: felt252, count: u32) -> Array<felt252> {
    if count >= TICS_PER_FELT {
        return unpack7(packed);
    }
    let all = unpack7(packed);
    let mut out: Array<felt252> = array![];
    let mut i: u32 = 0;
    while i != count {
        out.append(*all.at(i));
        i += 1;
    }
    out
}

/// Streaming packer for the transport form.
///
/// The proving path already holds one word per tic, so it must never call
/// [`pack7`] (which re-reads a span, 164 steps per group): it pushes words
/// as it produces them, at ~8 steps per tic, and gets a finished transport
/// felt every [`TICS_PER_FELT`] pushes.
///
/// The group counter *is* `shift`: it reaches `WORD_SHIFT^7` exactly when
/// seven words have been pushed, which saves the separate counter and its
/// bounds check.
#[derive(Copy, Drop, PartialEq, Debug)]
pub struct Packer {
    pub packed: felt252,
    pub shift: felt252,
}

/// An empty packer.
pub fn packer() -> Packer {
    Packer { packed: 0, shift: 1 }
}

#[generate_trait]
pub impl PackerImpl of PackerTrait {
    /// Push one word. Returns the packer to use next and, when this push
    /// completed a group, the finished transport felt (the packer returned
    /// alongside it is empty again).
    fn push(self: Packer, word: felt252) -> (Packer, Option<felt252>) {
        let packed = self.packed + word * self.shift;
        let shift = self.shift * WORD_SHIFT;
        if shift == GROUP_SHIFT {
            (packer(), Option::Some(packed))
        } else {
            (Packer { packed, shift }, Option::None)
        }
    }

    /// Close a partial group: the transport felt for the words pushed since
    /// the last completed group, or `None` when none are pending.
    fn seal(self: Packer) -> Option<felt252> {
        if self.shift == 1 {
            Option::None
        } else {
            Option::Some(self.packed)
        }
    }

    /// Words pending in the current group, in `0..TICS_PER_FELT`.
    fn pending(self: Packer) -> u32 {
        let mut shift: felt252 = 1;
        let mut count: u32 = 0;
        while shift != self.shift && count != TICS_PER_FELT {
            shift = shift * WORD_SHIFT;
            count += 1;
        }
        count
    }
}

/// Pack a whole log of per-tic words into transport felts, seven per felt.
/// The last group may be short.
pub fn pack_log(words: Span<felt252>) -> Array<felt252> {
    let mut out: Array<felt252> = array![];
    let mut i: u32 = 0;
    while i < words.len() {
        let end = if i + TICS_PER_FELT < words.len() {
            i + TICS_PER_FELT
        } else {
            words.len()
        };
        out.append(pack7(words.slice(i, end - i)));
        i += TICS_PER_FELT;
    }
    out
}

/// Inverse of [`pack_log`]: expand `tics` words out of a packed log.
/// Words past the end of `packed` read back as zero (the idle command).
pub fn unpack_log(packed: Span<felt252>, tics: u32) -> Array<felt252> {
    let mut out: Array<felt252> = array![];
    let mut group: u32 = 0;
    while out.len() < tics {
        let remaining = tics - out.len();
        let felt = if group < packed.len() {
            *packed.at(group)
        } else {
            0
        };
        let words = unpack7_n(felt, remaining);
        let mut i: u32 = 0;
        while i != words.len() {
            out.append(*words.at(i));
            i += 1;
        }
        group += 1;
    }
    out
}

/// A cursor over a log of per-tic words, yielding decoded commands.
///
/// Build the words with [`unpack_log`] when starting from the packed
/// transport form; keeping the two steps separate means the proving path,
/// which already holds words, never pays for `u256` unpacking.
#[derive(Copy, Drop, PartialEq, Debug)]
pub struct TicCmdLog {
    pub words: Span<felt252>,
    pub pos: u32,
}

/// A log cursor positioned on the first tic.
pub fn log(words: Span<felt252>) -> TicCmdLog {
    TicCmdLog { words, pos: 0 }
}

#[generate_trait]
pub impl TicCmdLogImpl of TicCmdLogTrait {
    /// Total number of tics in the log.
    fn len(self: @TicCmdLog) -> u32 {
        (*self.words).len()
    }

    /// Tics not yet yielded.
    fn remaining(self: @TicCmdLog) -> u32 {
        (*self.words).len() - *self.pos
    }

    /// The command of tic `index`, or `None` past the end. Does not move
    /// the cursor.
    fn at(self: @TicCmdLog, index: u32) -> Option<TicCmd> {
        if index >= (*self.words).len() {
            return Option::None;
        }
        try_decode(*(*self.words).at(index))
    }

    /// Advance one tic. Yields `None` at the end of the log **and** on a
    /// word that is not a valid 32-bit value, so a corrupted log
    /// terminates the iteration instead of trapping.
    fn next(ref self: TicCmdLog) -> Option<TicCmd> {
        if self.pos >= self.words.len() {
            return Option::None;
        }
        let word = *self.words.at(self.pos);
        self.pos += 1;
        try_decode(word)
    }
}

// ---------------------------------------------------------------------------
// TRANSITIONAL aliases -- delete with P1.3/P1.5.
//
// `doom_player`, `doom_game`, `doom_run` and `segment::chain_commands` were
// written against the Phase-0 skeleton's `pack`/`unpack` names.
// ---------------------------------------------------------------------------

/// Deprecated alias of [`encode`].
pub fn pack(cmd: TicCmd) -> felt252 {
    encode(cmd)
}

/// Deprecated alias of [`decode`].
pub fn unpack(word: felt252) -> TicCmd {
    decode(word)
}

#[cfg(test)]
mod tests {
    use super::{
        MOVE_MAX, MOVE_MIN, PackerTrait, TICS_PER_FELT, TURN_MAX, TURN_MIN, TURN_UNIT, TicCmd,
        TicCmdLogTrait, decode, decode_offsets, encode, idle, is_canonical, log, pack7, pack_log,
        packer, quantize, try_decode, try_encode, unpack7, unpack7_n, unpack_log,
    };

    fn cmd(forward: i64, side: i64, turn: i64, buttons: u8) -> TicCmd {
        TicCmd { forward, side, angle_turn: turn, buttons }
    }

    // -- reference values (mirrored by bench/reference.py) -----------------

    #[test]
    fn test_reference_words() {
        // forward=0, side=0, turn=0, buttons=0 -> 128 + 128<<8 + 128<<16
        assert(encode(idle()) == 0x808080, 'idle word');
        // forward=1 -> 129; side=-1 -> 127; turn=256 -> 129; buttons=3
        assert(encode(cmd(1, -1, 256, 3)) == 0x03817F81, 'sample word');
        // all minima
        assert(encode(cmd(-128, -128, -32768, 0)) == 0x00000000, 'min word');
        // all maxima
        assert(encode(cmd(127, 127, 32512, 255)) == 0xFFFFFFFF, 'max word');
    }

    #[test]
    fn test_reference_pack7() {
        let words: Array<felt252> = array![1, 2, 3, 4, 5, 6, 7];
        // 1 + 2*2^32 + 3*2^64 + ... + 7*2^192
        assert(
            pack7(words.span()) == 0x7000000060000000500000004000000030000000200000001,
            'seven word group',
        );
    }

    // -- canonical form ----------------------------------------------------

    #[test]
    fn test_is_canonical_bounds() {
        assert(is_canonical(idle()), 'idle is canonical');
        assert(is_canonical(cmd(MOVE_MIN, MOVE_MAX, TURN_MIN, 255)), 'extremes are canonical');
        assert(is_canonical(cmd(0, 0, TURN_MAX, 0)), 'turn max is canonical');
        assert(!is_canonical(cmd(MOVE_MIN - 1, 0, 0, 0)), 'forward too small');
        assert(!is_canonical(cmd(MOVE_MAX + 1, 0, 0, 0)), 'forward too large');
        assert(!is_canonical(cmd(0, MOVE_MIN - 1, 0, 0)), 'side too small');
        assert(!is_canonical(cmd(0, MOVE_MAX + 1, 0, 0)), 'side too large');
        assert(!is_canonical(cmd(0, 0, TURN_MIN - 1, 0)), 'turn too small');
        assert(!is_canonical(cmd(0, 0, TURN_MAX + 1, 0)), 'turn too large');
        assert(!is_canonical(cmd(0, 0, 1, 0)), 'turn off the 256 grid');
        assert(!is_canonical(cmd(0, 0, -1, 0)), 'negative turn off grid');
    }

    #[test]
    fn test_quantize_is_total_and_idempotent() {
        let wild = cmd(9999, -9999, 12345, 200);
        let once = quantize(wild);
        assert(is_canonical(once), 'quantize is canonical');
        assert(quantize(once) == once, 'quantize is idempotent');
        assert(once.forward == MOVE_MAX, 'forward clamped');
        assert(once.side == MOVE_MIN, 'side clamped');
        assert(once.angle_turn == 12288, '12345 snaps down to 12288');
        assert(once.buttons == 200, 'buttons preserved');
    }

    #[test]
    fn test_quantize_rounds_towards_minus_infinity() {
        assert(quantize(cmd(0, 0, 255, 0)).angle_turn == 0, '255 -> 0');
        assert(quantize(cmd(0, 0, -1, 0)).angle_turn == -256, '-1 -> -256');
        assert(quantize(cmd(0, 0, -256, 0)).angle_turn == -256, '-256 stays');
        assert(quantize(cmd(0, 0, 99999, 0)).angle_turn == TURN_MAX, 'clamped then snapped');
        assert(quantize(cmd(0, 0, -99999, 0)).angle_turn == TURN_MIN, 'clamped low');
    }

    // -- round trips -------------------------------------------------------

    #[test]
    fn test_round_trip_over_the_whole_movement_range() {
        let mut forward: i64 = MOVE_MIN;
        while forward != MOVE_MAX + 1 {
            let c = cmd(forward, -forward - 1, 0, 0);
            assert(decode(encode(c)) == c, 'forward round trip');
            forward += 1;
        }
    }

    #[test]
    fn test_round_trip_over_the_whole_turn_range() {
        let mut units: i64 = -128;
        while units != 128 {
            let c = cmd(0, 0, units * TURN_UNIT, 0);
            assert(decode(encode(c)) == c, 'turn round trip');
            units += 1;
        }
    }

    #[test]
    fn test_round_trip_over_the_whole_buttons_range() {
        let mut buttons: u8 = 0;
        loop {
            let c = cmd(-128, 127, TURN_MIN, buttons);
            assert(decode(encode(c)) == c, 'buttons round trip');
            if buttons == 255 {
                break;
            }
            buttons += 1;
        }
    }

    #[test]
    fn test_words_are_distinct_for_distinct_commands() {
        assert(encode(cmd(1, 0, 0, 0)) != encode(cmd(0, 1, 0, 0)), 'forward vs side');
        assert(encode(cmd(0, 1, 0, 0)) != encode(cmd(0, 0, 256, 0)), 'side vs turn');
        assert(encode(cmd(0, 0, 256, 0)) != encode(cmd(0, 0, 0, 1)), 'turn vs buttons');
    }

    #[test]
    fn test_decode_offsets_matches_decode() {
        let c = cmd(-40, 90, -2560, 17);
        let (forward, side, turn, buttons) = decode_offsets(encode(c));
        assert(forward == 88, 'forward offset');
        assert(side == 218, 'side offset');
        assert(turn == 118, 'turn offset');
        assert(buttons == 17, 'buttons offset');
        let back = decode(encode(c));
        assert(back == c, 'decode agrees');
    }

    #[test]
    fn test_try_encode_rejects_non_canonical() {
        assert(try_encode(cmd(0, 0, 1, 0)).is_none(), 'off grid rejected');
        assert(try_encode(cmd(1000, 0, 0, 0)).is_none(), 'out of range rejected');
        assert(try_encode(idle()).is_some(), 'canonical accepted');
    }

    #[test]
    #[should_panic(expected: 'ticcmd: not canonical')]
    fn test_encode_panics_on_non_canonical() {
        encode(cmd(200, 0, 0, 0));
    }

    #[test]
    fn test_try_decode_rejects_oversized_words() {
        assert(try_decode(0xFFFFFFFF).is_some(), '32-bit word accepted');
        assert(try_decode(0x100000000).is_none(), '33-bit word rejected');
        assert(try_decode(-1).is_none(), 'negative felt rejected');
    }

    // -- transport packing -------------------------------------------------

    #[test]
    fn test_pack7_unpack7_round_trip() {
        let mut words: Array<felt252> = array![];
        let mut i: u32 = 0;
        while i != TICS_PER_FELT {
            words.append(encode(cmd(i.into() - 3, 5 - i.into(), (i.into() - 3) * TURN_UNIT, 7)));
            i += 1;
        }
        let packed = pack7(words.span());
        let back = unpack7(packed);
        assert(back.len() == TICS_PER_FELT, 'seven words back');
        let mut j: u32 = 0;
        while j != TICS_PER_FELT {
            assert(*back.at(j) == *words.at(j), 'word round trip');
            j += 1;
        }
    }

    #[test]
    fn test_pack7_of_extreme_words_round_trips() {
        let words: Array<felt252> = array![0xFFFFFFFF, 0, 0xFFFFFFFF, 0, 0xFFFFFFFF, 0, 0xFFFFFFFF];
        let back = unpack7(pack7(words.span()));
        let mut j: u32 = 0;
        while j != TICS_PER_FELT {
            assert(*back.at(j) == *words.at(j), 'extreme word round trip');
            j += 1;
        }
    }

    #[test]
    fn test_pack7_short_group_pads_with_zeros() {
        let words: Array<felt252> = array![11, 22];
        let back = unpack7(pack7(words.span()));
        assert(*back.at(0) == 11, 'first kept');
        assert(*back.at(1) == 22, 'second kept');
        assert(*back.at(2) == 0, 'padded with zero');
        assert(*back.at(6) == 0, 'padded to seven');
    }

    #[test]
    fn test_pack7_ignores_words_past_the_seventh() {
        let seven: Array<felt252> = array![1, 2, 3, 4, 5, 6, 7];
        let eight: Array<felt252> = array![1, 2, 3, 4, 5, 6, 7, 8];
        assert(pack7(seven.span()) == pack7(eight.span()), 'eighth word ignored');
    }

    #[test]
    fn test_pack7_of_nothing_is_zero() {
        let empty: Array<felt252> = array![];
        assert(pack7(empty.span()) == 0, 'empty group is zero');
        assert(unpack7_n(0, 0).len() == 0, 'zero words back');
    }

    #[test]
    fn test_unpack7_n_is_a_prefix_of_unpack7() {
        let words: Array<felt252> = array![1, 2, 3, 4, 5, 6, 7];
        let packed = pack7(words.span());
        let three = unpack7_n(packed, 3);
        assert(three.len() == 3, 'three words');
        assert(*three.at(2) == 3, 'third word');
        assert(unpack7_n(packed, 99).len() == TICS_PER_FELT, 'clamped to seven');
    }

    #[test]
    fn test_pack_log_round_trip_over_awkward_lengths() {
        let mut n: u32 = 0;
        while n != 16 {
            let mut words: Array<felt252> = array![];
            let mut i: u32 = 0;
            while i != n {
                words.append(encode(cmd(1, 2, TURN_UNIT, i.try_into().unwrap())));
                i += 1;
            }
            let packed = pack_log(words.span());
            let expected_felts = (n + TICS_PER_FELT - 1) / TICS_PER_FELT;
            assert(packed.len() == expected_felts, 'felt count');
            let back = unpack_log(packed.span(), n);
            assert(back.len() == n, 'word count');
            let mut j: u32 = 0;
            while j != n {
                assert(*back.at(j) == *words.at(j), 'log round trip');
                j += 1;
            }
            n += 1;
        }
    }

    #[test]
    fn test_unpack_log_past_the_end_yields_idle_words() {
        let empty: Array<felt252> = array![];
        let back = unpack_log(empty.span(), 3);
        assert(back.len() == 3, 'three words');
        assert(*back.at(0) == 0, 'zero word');
        assert(decode(0).forward == -128, 'zero word decodes to min');
    }

    // -- the streaming packer ---------------------------------------------

    #[test]
    fn test_packer_emits_the_same_felt_as_pack7() {
        let words: Array<felt252> = array![10, 20, 30, 40, 50, 60, 70];
        let mut p = packer();
        let mut emitted: Option<felt252> = Option::None;
        let mut i: u32 = 0;
        while i != TICS_PER_FELT {
            let (next, group) = p.push(*words.at(i));
            p = next;
            if group.is_some() {
                emitted = group;
            }
            i += 1;
        }
        assert(emitted == Option::Some(pack7(words.span())), 'packer matches pack7');
        assert(p == packer(), 'packer reset after a group');
        assert(p.seal() == Option::None, 'nothing left to seal');
    }

    #[test]
    fn test_packer_emits_only_on_the_seventh_push() {
        let mut p = packer();
        let mut i: u32 = 0;
        while i != TICS_PER_FELT - 1 {
            let (next, group) = p.push(1);
            assert(group == Option::None, 'no group before the seventh');
            assert(p.pending() == i, 'pending count');
            p = next;
            i += 1;
        }
        let (_, group) = p.push(1);
        assert(group.is_some(), 'group on the seventh push');
    }

    #[test]
    fn test_packer_seals_a_partial_group() {
        let words: Array<felt252> = array![10, 20, 30];
        let mut p = packer();
        let mut i: u32 = 0;
        while i != words.len() {
            let (next, group) = p.push(*words.at(i));
            assert(group == Option::None, 'partial group emits nothing');
            p = next;
            i += 1;
        }
        assert(p.pending() == 3, 'three pending');
        assert(p.seal() == Option::Some(pack7(words.span())), 'seal matches pack7');
    }

    #[test]
    fn test_packer_over_a_whole_log_matches_pack_log() {
        let mut words: Array<felt252> = array![];
        let mut i: u32 = 0;
        while i != 17 {
            words.append(encode(cmd(1, 2, TURN_UNIT, i.try_into().unwrap())));
            i += 1;
        }
        let mut streamed: Array<felt252> = array![];
        let mut p = packer();
        let mut j: u32 = 0;
        while j != words.len() {
            let (next, group) = p.push(*words.at(j));
            p = next;
            match group {
                Option::Some(felt) => streamed.append(felt),
                Option::None => {},
            }
            j += 1;
        }
        match p.seal() {
            Option::Some(felt) => streamed.append(felt),
            Option::None => {},
        }
        let batched = pack_log(words.span());
        assert(streamed.len() == batched.len(), 'same felt count');
        let mut k: u32 = 0;
        while k != batched.len() {
            assert(*streamed.at(k) == *batched.at(k), 'same felts');
            k += 1;
        }
    }

    // -- the log cursor ----------------------------------------------------

    #[test]
    fn test_log_iterates_every_tic_in_order() {
        let a = cmd(1, 2, TURN_UNIT, 3);
        let b = cmd(-1, -2, -TURN_UNIT, 4);
        let words: Array<felt252> = array![encode(a), encode(b)];
        let mut cursor = log(words.span());
        assert(cursor.len() == 2, 'two tics');
        assert(cursor.remaining() == 2, 'two remaining');
        assert(cursor.next() == Option::Some(a), 'first command');
        assert(cursor.remaining() == 1, 'one remaining');
        assert(cursor.next() == Option::Some(b), 'second command');
        assert(cursor.next() == Option::None, 'end of log');
        assert(cursor.next() == Option::None, 'stays at the end');
    }

    #[test]
    fn test_log_of_nothing_is_empty() {
        let empty: Array<felt252> = array![];
        let mut cursor = log(empty.span());
        assert(cursor.len() == 0, 'no tics');
        assert(cursor.next() == Option::None, 'nothing to yield');
    }

    #[test]
    fn test_log_random_access_and_corruption() {
        let a = cmd(7, 8, 2 * TURN_UNIT, 9);
        let words: Array<felt252> = array![encode(a), 0x1_0000_0000];
        let cursor = log(words.span());
        assert(cursor.at(0) == Option::Some(a), 'first tic');
        assert(cursor.at(1) == Option::None, 'corrupt word yields none');
        assert(cursor.at(2) == Option::None, 'past the end yields none');
        let mut walking = cursor;
        assert(walking.next().is_some(), 'first tic walks');
        assert(walking.next() == Option::None, 'corrupt word stops the walk');
    }

    // -- provability -------------------------------------------------------

    #[test]
    fn test_words_stay_below_the_range_check_cliff() {
        // A7 / S1 §5.2: a value written to memory should stay under 2^72.
        // Every per-tic word does -- it is 32 bits wide, whatever the
        // command.
        let mut turn_units: i64 = -128;
        while turn_units != 128 {
            let word = encode(cmd(127, -128, turn_units * TURN_UNIT, 255));
            let as_u128: u128 = word.try_into().unwrap();
            assert(as_u128 < 0x100000000, 'a word is 32 bits');
            turn_units += 1;
        }
        // A transport felt is the one exception: seven words make 224 bits.
        // See README.md, "Invariants".
        let words: Array<felt252> = array![
            0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF,
        ];
        let packed: u256 = pack7(words.span()).into();
        assert(
            packed < 0x100000000000000000000000000000000000000000000000000000000_u256,
            'a group is 224 bits',
        );
    }
}
