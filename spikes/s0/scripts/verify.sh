#!/usr/bin/env bash
# Verify a Stwo Cairo proof with the standalone Rust verifier.
#
#   ./verify.sh <proof.json> [channel_hash]
#
# `channel_hash` is blake2s (default), blake2s_m31 or poseidon252 and MUST match the
# `channel_hash` of the params the proof was produced with.
#
# NOTE: the `verify` binary reads the **json** proof format only
# (`CairoProofForRustVerifier`). For a cairo-serde proof, re-prove with
# PROOF_FORMAT=json, or rely on prove.sh's in-process `--verify`, which checks the proof
# whatever the serialisation format.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
source "$HERE/env.sh"

[ $# -ge 1 ] || { sed -n '2,13p' "$0"; exit 2; }
PROOF="$1"
CHANNEL="${2:-blake2s}"

"$PROVING_BIN/verify" --proof_path "$PROOF" --channel_hash "$CHANNEL"
