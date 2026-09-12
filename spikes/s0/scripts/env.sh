#!/usr/bin/env bash
# Shared configuration for the S0 scripts. Override any of these from the
# environment; the defaults match the machine the spike was run on.

# --- pinned versions -------------------------------------------------------
# Scarb: matched to the cairo-lang-* 2.19.4 crates the monorepo links against,
# so the `.executable.json` format is exactly what the prover expects.
: "${SCARB_VERSION:=2.19.4}"
# starkware-libs/proving commit used for every measurement in docs/spikes/S0.md.
: "${PROVING_COMMIT:=cd7bc5f4697fb188a27e09f9242f1dd76df8afdc}"

# --- paths -----------------------------------------------------------------
# Working copy of the monorepo (a clone, never the shared read-only one).
: "${PROVING_DIR:=$HOME/git/proving}"
: "${PROVING_BIN:=$PROVING_DIR/target/release}"
# The Cairo-0 "privacy simple bootloader" that wraps a Scarb executable as a
# bootloader task. Shipped with the monorepo.
: "${BOOTLOADER:=$PROVING_DIR/crates/cairo-program-runner-lib/resources/compiled_programs/bootloaders/privacy_simple_bootloader_compiled.json}"

# Serialised lock used to keep two >2^19-step proofs from running at once.
: "${PROOF_LOCK:=${SCRATCH:-/tmp}/.proof-lock}"
# Proofs larger than 2^19 steps take the lock; smaller ones do not.
: "${PROOF_LOCK_THRESHOLD_STEPS:=524288}"

PROGRAMS=(felt_loop u32_loop bitwise_loop poseidon_hash steps_k bigcode felt_width)
