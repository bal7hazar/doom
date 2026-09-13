#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Conformance check of a circuit registry against the phased verifier (R3-A5):
# regenerates the vendored multiverifier constants for <registry> (in the optimized vendor tree
# AND in the pristine `_ref` copy, whose package names differ), selects its fixture and runs the
# monolithic reference, the equivalence suite, the phase-machine and router suites; then
# restores the committed constants and fixture selection.
# Usage: tools/check_registry.sh doom | doom_fold4_min
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
REF_CONSTS=vendor/stwo_cairo_verifier_ref/crates/circuit_air/src/multiverifier_consts.cairo
REF_COLS=vendor/stwo_cairo_verifier_ref/crates/circuit_air/src/preprocessed_columns.cairo
for f in "$CONSTS" "$COLS" "$REF_CONSTS" "$REF_COLS" fixtures/selected.txt; do cp "$f" "$f.bak"; done
restore() { for f in "$CONSTS" "$COLS" "$REF_CONSTS" "$REF_COLS" fixtures/selected.txt; do mv "$f.bak" "$f"; done; }
trap restore EXIT
python3 tools/gen_multiverifier_consts.py --registry "$REG"
# The same constants in the pristine copy (its crates are renamed `*_ref`, tools/vendor_ref.sh).
rename_ref() {
  perl -pe 's/\bstwo_verifier_core\b/stwo_verifier_core_ref/g; s/\bstwo_verifier_utils\b/stwo_verifier_utils_ref/g;
            s/\bstwo_constraint_framework\b/stwo_constraint_framework_ref/g; s/\bstwo_circuit_air\b/stwo_circuit_air_ref/g;
            s/(?<![:\w])bounded_int(?=::)/bounded_int_ref/g' "$1" > "$2"
}
rename_ref "$CONSTS" "$REF_CONSTS"
rename_ref "$COLS" "$REF_COLS"
echo "$SEL" > fixtures/selected.txt
sh fixtures/unpack.sh > /dev/null
set +o pipefail
for t in monolithic_verify phases_end_to_end test_equivalence; do
  ( cd crates/stwo_circuit_phases && snforge test "$t" 2>&1 | grep -E "^\[PASS\]|^\[FAIL\]|Tests:" )
done
( cd crates/doom_contracts && snforge test router_five_transactions 2>&1 | grep -E "^\[PASS\]|^\[FAIL\]|Tests:|calldata felts" )
