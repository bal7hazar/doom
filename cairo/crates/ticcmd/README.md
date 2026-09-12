# ticcmd

**Does**: turns one tic of player input — `TicCmd { forward, side,
angle_turn, buttons }`, the fields of Doom's `ticcmd_t` — into felts, and
back. Two formats, for two different consumers:

- **the word** (`encode`/`decode`, `try_encode`/`try_decode`,
  `decode_offsets`): one 32-bit value per tic in a `felt252`, which is what
  the proving path consumes (one felt per tic, cheap to decode);
- **the transport felt** (`pack7`/`unpack7`, `pack_log`/`unpack_log`, and
  the streaming `Packer`): seven words in one felt, the density CONTEXT.md
  §9 budgets for the on-chain replay event and the stored input log (~900
  felts for a 3-minute run).

`quantize` makes any raw input canonical (clamping, and snapping the turn to
the 256-BAM grid), `is_canonical` checks it, and `TicCmdLog` is a cursor
over a span of words that yields decoded commands (`next`, `at`, `len`,
`remaining`).

**Does not**: interpret `buttons` (the bits are Doom's business, in
`cairo/doom/doom_player`), decide how many tics a segment holds, or hash
anything (`state_hash` and `segment` do that). It never stores a log: every
function takes and returns spans and arrays the caller owns.

## Wire format

```text
word (32 bits, one tic)
  bits  0..7   forward + 128        forward in [-128, 127]
  bits  8..15  side    + 128        side    in [-128, 127]
  bits 16..23  turn / 256 + 128     turn in [-32768, 32512], multiples of 256
  bits 24..31  buttons              0..255

transport felt (224 bits, seven tics)
  w0 + w1·2^32 + w2·2^64 + w3·2^96 + w4·2^128 + w5·2^160 + w6·2^192
```

Every field is a **non-negative offset**: S1 §5.2 measured a predicate on
offset-encoded values at 18 steps against 28 on raw negative felts, and a
negative felt is ≈ 2^251, which also trips the 2^72 `range_check_9_9`
penalty. A word is 32 bits, far below that cliff.

`angle_turn` is **quantised to 256 BAM**. That is exactly what Doom's own
demo format does (`G_WriteDemoTiccmd` stores `angleturn >> 8`), and it is
what makes a tic fit in the 4 bytes CONTEXT.md §9 budgets — 5 bytes per tic
would only fit 6 tics per felt (40 × 7 = 280 bits > 252). The input-capture
path must therefore build commands through `quantize`; `encode` refuses
anything else rather than truncating silently.

## Invariants

- `decode(encode(cmd)) == cmd` for **every** canonical command — checked
  exhaustively over all 65 536 `(forward, turn)` pairs by
  `bench/reference.py`, and over each field's full range in Cairo.
- `encode` is injective on canonical commands, and `quantize` is total
  (any `i64` input) and idempotent.
- `unpack7(pack7(words)) == words` padded to seven; `pack_log`/`unpack_log`
  round-trip for every log length, the last group being short.
- The `Packer` produces byte-identical felts to `pack_log` (tested on a
  17-tic log, i.e. two full groups and a partial one).
- Total functions on the proving path: `try_encode`, `try_decode`,
  `unpack7`, `unpack7_n`, `quantize`, and `TicCmdLog::next`/`at` — none of
  them can trap on any input (R4-A2). `encode`, `decode` and
  `decode_offsets` do panic on an out-of-domain argument: they run on the
  input-capture side, where silence would be worse.
- A word is always < 2^32 (A7). The **one** value in this crate above the
  2^72 mark is the transport felt, at 224 bits — unavoidable at 7 tics/felt,
  and no worse than a Poseidon hash, which the state stack already holds.

## Measured costs

Method: differential step measurement, `scarb execute
--print-resource-usage`; see [`bench/README.md`](bench/README.md). Net =
gross minus the 25.87-step bare loop (which includes the pool read that
defeats loop-invariant hoisting). Scarb 2.16.0, `enable-gas = false`.

| Operation | net steps | per tic | budget (CI) |
|---|---:|---:|---:|
| `decode(word) -> TicCmd` | **64** | 64 | 70 |
| `decode_offsets(word)` (raw offsets) | **31** | 31 | 34 |
| `try_decode(word)` | 70 | 70 | 77 |
| `decode` + `encode` round trip | 225 | — | 248 |
| `Packer::push` | 12.3 | **12.3** | 14 |
| `pack7(7 words)` | 172 | 24.6 | 190 |
| `unpack7(felt)` | 101 | 14.4 | 112 |

Against the baseline the task set — S1 §5.1's **106 steps** to unpack five
16-bit fields from a packed felt — the layout here costs **31 steps** for
the four raw fields and **64** for a fully typed `TicCmd`. What bought it:

- **four 8-bit fields instead of five 16-bit ones**, so three `DivRem`s
  instead of four divisions and five modulos (S1's 37 range checks drop to
  8);
- **`DivRem` rather than division-then-modulo**: one libfunc returns both
  halves;
- **de-biasing in `felt252`, converting once per field**: a felt
  subtraction costs 1 step and a `felt252 -> i64` conversion 7, against
  ~17 for converting first and then subtracting in range-checked `i64`.
  This alone took `decode` from 86 steps to 64;
- for `unpack7`, **splitting the two `u256` limbs** (224 bits = 128 + 96,
  so four words come out of the low limb and three out of the high one,
  six `u128` divisions in all) instead of seven `u256` divisions: **101
  steps instead of 1 205**, a 12× cut;
- for the proving path, the streaming `Packer` (12.3 steps/tic) instead of
  `pack7` (24.6 steps/tic), because it never re-reads a span — and its
  group counter is the shift itself, which reaches 2^224 exactly on the
  seventh push.

## Tests

`scarb test -p ticcmd`: 29 tests — reference vectors (mirrored by
`bench/reference.py`, which also re-checks the round trip exhaustively over
65 536 commands), properties (round trips over the full range of each
field, injectivity, `quantize` idempotence and monotone rounding,
`pack_log` round trip for every length 0..15, `Packer` ≡ `pack_log`), edge
cases (empty group, short group, eighth word ignored, cursor at the end,
corrupted word, oversized and negative felts), and a provability test
asserting word widths. The step-budget test is `bench/measure.py`.

## Transitional

`pack`/`unpack` are kept as deprecated aliases of `encode`/`decode` because
`doom_player`, `doom_game`, `doom_run` and `segment::chain_commands` were
written against the Phase-0 names. The struct field is still called
`angle_turn` (Doom's `angleturn`) rather than `turn` for the same reason.
Both can go with P1.3.
