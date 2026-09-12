#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Conformance check of a circuit registry against the phased verifier (R3-A5):
# regenerates the vendored multiverifier constants for <registry>, selects its fixture and
# runs the monolithic, phase-machine and router suites; then restores the committed constants
# and fixture selection. Usage: tools/check_registry.sh doom | doom_fold4_min
set -euo pipefail
cd "$(dirname "$0")/.."
REG=${1:?registry name}
case "$REG" in
  doom) SEL=1 ;;
  doom_fold4_min) SEL=2 ;;
  *) echo "no fixture for registry $REG (see crates/stwo_circuit_phases/tests/fixture.cairo)"; exit 2 ;;
esac
CONSTS=vendor/stwo_cairo_verifier/crates/circuit_air/src/multiverifier_consts.cairo
COLS=vendor/stwo_cairo_verifier/crates/circuit_air/src/preprocessed_columns.cairo
cp "$CONSTS" "$CONSTS.bak"; cp "$COLS" "$COLS.bak"; cp fixtures/selected.txt fixtures/selected.txt.bak
restore() { mv "$CONSTS.bak" "$CONSTS"; mv "$COLS.bak" "$COLS"; mv fixtures/selected.txt.bak fixtures/selected.txt; }
trap restore EXIT
python3 tools/gen_multiverifier_consts.py --registry "$REG"
echo "$SEL" > fixtures/selected.txt
sh fixtures/unpack.sh > /dev/null
set +o pipefail
for t in monolithic_verify phases_end_to_end; do
  ( cd crates/stwo_circuit_phases && snforge test "$t" 2>&1 | grep -E "^\[PASS\]|^\[FAIL\]|Tests:" )
done
( cd crates/doom_contracts && snforge test router_five_transactions 2>&1 | grep -E "^\[PASS\]|^\[FAIL\]|Tests:|calldata felts" )
