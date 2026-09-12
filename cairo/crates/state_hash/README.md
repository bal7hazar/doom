# state_hash

**Does**: computes a canonical Poseidon hash (`hash_state`) over a
`Span<felt252>` — the serialized representation of a `GameState` — and a
chaining helper (`chain`) that folds a previous hash together with a new
batch of felts (`h_out = chain(h_in, public_outputs)`), the primitive
`segment::run_segment` uses to link consecutive segments (PLAN.md A2).

**Does not**: define *how* a `GameState` is serialized into felts (that is
`doom_game`'s responsibility — this crate only hashes whatever span it is
given); it does not implement Merkle trees or any multi-leaf aggregation
(that is the recursive proving route, `recursive_tree`, outside this
Cairo workspace).

**Invariants**: `hash_state` is a pure function of its input span (same
input always yields the same output, in the same call and across calls);
changing any single felt in the span changes the hash (tested on a sample,
not proven — Poseidon's collision resistance is out of scope for this
crate's tests); `chain(h, a ++ b) == chain(chain(h, a), ...)` is **not**
assumed by this crate (chaining is a single flat hash of `h` prepended to
the batch, not an incremental/streaming hash) — segment-level associativity
of chaining, if required, is `segment`'s concern, built on top of this
primitive.
