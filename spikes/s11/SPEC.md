# S11 candidate specification — experiment only

State hash D16 remains Poseidon in production. This experiment defines a distinct
candidate, `BLAKE9-v1`, only for schema-2 records whose felts all satisfy
`0 <= value < 2^72`. The current `doom_game` serializer explicitly guarantees
this range: fixed values use their biased encodings, health is biased, remaining
fields and grid members are unsigned bounded counters or domain tags. The
candidate checks each bound. No cast silently truncates a felt.

The byte message is the following unambiguous concatenation:

| Field | Encoding |
|---|---|
| Domain | 16 literal bytes `HP.STATE.B2S9\x00\x00\x00` |
| Game schema | 4 bytes little-endian, value 2 |
| Candidate encoding version | 4 bytes little-endian, value 1 |
| Number of serialized felts | 8 bytes little-endian |
| Every serialized felt, in order | Exactly 9 little-endian bytes each |

The complete existing `[HP.STATE, 2, field_count, ...fields...]` record is encoded,
including all player, actor, RNG, specials and canonical grid membership order.
The new domain does not replace or discard its old header. Fixed-width elements
and an explicit count make this byte encoding injective over the specified
input domain. No field is omitted because it looks derived or historical.
The core compression API has a u32 byte counter, so this prototype explicitly
rejects more than 477,218,584 input felts before arithmetic; real game states are
many orders of magnitude smaller.

Hash the exact bytes with unkeyed BLAKE2s-256, standard sequential parameters.
The initial state is the standard IV with its first word XOR `0x01010020`.
Use 64-byte compression blocks, 32-bit little-endian words, zero unused bytes,
and the exact cumulative unpadded byte count. Mark the last actual block final,
including when its length is exactly 64 bytes. Do not append an extra block in
that case. These semantics follow [RFC 7693 §2–3](https://www.rfc-editor.org/rfc/rfc7693.html#section-3)
and the installed Scarb 2.16.0 `core/src/blake.cairo` interface. Python `hashlib`
produces independent complete-digest vectors, including the RFC's `abc` check,
partial words and full final blocks.

Interpret all 32 digest bytes as a little-endian nonnegative integer `D`, then
return `D mod p`, where `p = 2^251 + 17*2^192 + 1`. Cairo evaluates all eight
32-bit words in the field, which gives precisely that reduction. Every digest
bit participates. This is not masking high bits or using a shorter digest to
make compression cheaper; both choices would leave the number of blocks unchanged.

Reduction to a single Stark felt gives an idealized collision scale near
`sqrt(p) = 2^125.5`, versus `2^128` for a full 256-bit digest. Residues have 31 or
32 preimages in the 256-bit digest space; the slight bias must not be described
as exact uniformity. This reasoning assumes the hash behaves ideally and is not
a security proof of this new domain construction. A two-felt full digest would
retain all 256 bits but change D14 and its consumers, outside this spike. Existing
Poseidon state outputs are already single Stark felts; compatibility of that
output type does not authorize a production migration.

A generic 32-byte/felt format would cover every Stark felt, at 3.56 times the
state bytes before framing. It is not implemented in this phase: schema 2 already
supplies and checks the 72-bit domain. The nine-byte prototype will be measured
first; no security claim depends on using the shorter representation.

The segment wrappers share the same `from_felts` admission and actual generic
`segment::run_segment`. Their engines call the actual `doom_game::step_tic`,
`serialize`, `snapshot` and scoreboard accessors. Only the candidate engine's
state hash differs. D13 command packing and input commitment remain the existing
Poseidon implementation. Invalid states/tic_start retain production's Poseidon
ABORT commitment of the supplied felts, even outside the nine-byte domain.

`doom_run` currently has executable targets only, so its public helper functions
cannot be imported as a Scarb library. The spike duplicates its small admission
and genesis plumbing in one common helper, without changing that manifest. The
measured wrappers are explicitly **not** production `doom_run` executables.
Separate inspection targets return full state/snapshot for equivalence checks;
the resource targets return only the ten D14 felts. Neither path removes validation.
