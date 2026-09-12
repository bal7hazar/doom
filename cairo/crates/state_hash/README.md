# state_hash

**Does**: defines how the state stack turns records into felts and felts
into one Poseidon hash, with **domain separation** so that two different
kinds of record can never collide:

```text
H(tag, version, data) = poseidon( tag ‖ version ‖ len(data) ‖ data )
```

It ships the scheme (`hash_tagged`, `hash_record`), the copy-free way to
apply it (`open` → append → `seal`), the canonical field writers
(`append_header`, `append_u32`, `append_u8`, `append_bool`,
`append_biased`, `append_span`), the `Hashable` trait pattern
(`hash_of`, `append_record`), and the running commitment over a packed
input log (`inputs_seed`, `commit_input`).

**Does not**: know what a `GameState` contains. Field order and schema
version are `doom_game`'s business; this crate only says how a record is
framed and hashed. It builds no Merkle trees (that is the recursive
prover's job, outside this workspace) and holds no state of its own.

## Domain separation

Every prefix felt earns its place:

| Felt | Stops |
|---|---|
| `tag` | a player record and a mobj record with the same field layout hashing alike |
| `version` | an old replay validating against a new schema — bump it and every hash moves |
| `len(data)` | the concatenation attack: `H(t, v, [1])` vs `H(t, v, [1, 2])` |

`tag::STATE`, `tag::SEGMENT_OUTPUT` and `tag::INPUT_LOG` are reserved by
the state stack; game crates pick their own short-string tags and must not
reuse those three.

The **input-log commitment** is a separate, order-sensitive fold:
`inputs_seed()` is the empty log (itself tagged), and `commit_input(prev,
packed)` absorbs one packed transport felt — seven tics, see `ticcmd`. A
segment publishes the final value; anyone holding the packed log can
recompute it. The tic count is *not* folded in, because the segment output
pins it separately with `tic_start`/`tic_end`; that is what disambiguates a
short final group.

`commit_input` is Starknet's **2-to-1** Poseidon — one Hades permutation
over `(prev, packed, 2)` — and not `poseidon_hash_span([prev, packed])`,
which pads: 7 steps against 48, and it is exactly `poseidonHash(a, b)` in
`starknet.js` and `poseidon_hash(a, b)` in `poseidon_py`, so the verifier
side is a one-liner. That change took `segment`'s per-tic overhead from
45.7 steps to 35.7.

## Invariants

- `hash_tagged` is a pure function of `(tag, version, data)`, sensitive to
  every felt of `data` and to its order (both tested elementwise).
- Changing the tag, the version, or the length always changes the hash.
- `open(tag, version, n)` + `n` appends + `seal` == `hash_tagged(tag,
  version, data)`, checked for every length 0..11 (a sponge pads odd and
  even lengths differently, so one length proves nothing).
- A `Hashable` must write exactly as many felts as its `fields()` promises;
  that is what makes the copy-free path correct, and it is tested.
- `append_biased` is the only way a signed value enters a buffer: the
  caller supplies an offset that keeps the felt non-negative and under
  2^72 (A7 / S1 §5.2). The felts this crate writes are otherwise `u32`,
  `u8`, booleans and lengths.
- The reference vectors are computed by an independent implementation
  (`poseidon_py`), not by this crate.

## Measured costs

Method: differential step measurement, `scarb execute
--print-resource-usage`; `n` is the number of felts hashed, so these are
per-felt figures. See [`bench/README.md`](bench/README.md). Bare loop
9 steps. Scarb 2.16.0, `enable-gas = false`.

| Operation | net steps/felt | budget (CI) |
|---|---:|---:|
| `open` + append + `seal` | **14.5** | 16 |
| `hash_tagged` over an existing span | 35.5 | 39 |
| `commit_input` (per call, not per felt) | 7 | 10 |
| *(build the array only)* | 4 | — |
| *(build + bare `poseidon_hash_span`)* | 14.5 | — |

Reading the table: Poseidon itself is **10.5 steps/felt** (14.5 − 4),
reproducing S1 §5.8's figure on a different program. Domain separation is
therefore **free** — the three header felts amortise away — provided the
serializer uses `open`/`seal` and never lets its buffer be copied.
`hash_tagged`'s extra 21 steps/felt *are* that copy, which on a 4 000-felt
state is 142 000 steps against 58 000.

S1 §5.8 suggested streaming with `hades_permutation` to halve the bill. It
was implemented (a `Digest` over `core`'s Poseidon `HashState`) and
measured at **18.5 steps/felt** — worse than `open`/`seal` despite never
allocating, because `HashState::update` absorbs one felt at a time behind a
parity branch while `poseidon_hash_span` absorbs two per permutation. The
code was removed; the suggestion is answered and should not be retried in
this form.

For the segment budget: a 4 000-felt state costs ~58 000 steps to hash, and
a segment hashes twice (in and out), so ~116 000 steps — about 1 % of a
2^20-step segment, and ~720 steps/tic amortised at K = 160. **Never hash
per tic.**

## Tests

`scarb test -p state_hash`: 23 tests — reference vectors from
`bench/reference.py` (`poseidon_py`), domain separation (tag, version and
length each shown to separate; the concatenation attack shown to fail),
sensitivity to every felt and to order, `open`/`seal` ≡ `hash_tagged` at
every length 0..11, the field writers' exact output, the `Hashable`
pattern including its declared-length invariant, two records in one buffer
staying distinguishable, and a provability check that biased fields stay
under 2^72. The step-budget test is `bench/measure.py`.

**Coverage**: `python3 bench/coverage.py` reports **34/34 production
lines = 100 %** (23 tests). It copies the crate to a temporary directory
and patches the manifest there, because `cairo-coverage` only reads
`snforge` traces and `snforge` cannot compile this workspace with
`enable-gas = false`; lines at or below a file's `#[cfg(test)]` marker are
excluded, so the figure is the coverage of the code that ships.
`cairo-coverage` 0.5.0 emits no `BRF`/`BRH` records, so **branch** coverage
cannot be reported by the tool — line coverage is the proxy, and since
`scarb fmt` puts every branch arm on its own line, a missed arm shows up as
a missed line. The script exits non-zero below 90 % (C7).

## Transitional

`hash_state` (untagged) and `chain` are kept because `doom_game` and
`segment::chain_commands` still call them. They have no domain separation;
replace them with `hash_game_state`/`open`+`seal` and `commit_input`, and
delete them, with P1.3.
