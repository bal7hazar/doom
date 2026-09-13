#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Builds `vendor/stwo_cairo_verifier_ref/`: the UNMODIFIED vendored verifier (upstream
# `proving@cd7bc5f` + the visibility-only patch, i.e. the tree before the P4.1 patch series)
# under renamed package names (`bounded_int_ref`, `stwo_verifier_utils_ref`,
# `stwo_verifier_core_ref`, `stwo_constraint_framework_ref`, `stwo_circuit_air_ref`), so that the
# reference `verify_circuit` and the optimized phases can be compiled into the same test binary
# and compared (`crates/stwo_circuit_phases/tests/test_equivalence.cairo`), and the
# measurement-only `StwoCircuitMonolithic` class stays the pristine verifier.
#
# Usage: tools/vendor_ref.sh <pristine crates dir>
#   e.g. git archive <commit-before-p4.1> cairo/doom_contracts/vendor/stwo_cairo_verifier/crates \
#          | tar -x -C /tmp/pristine && tools/vendor_ref.sh /tmp/pristine/cairo/doom_contracts/vendor/stwo_cairo_verifier/crates
# Re-run after a registry switch (`tools/gen_multiverifier_consts.py` regenerates the constants of
# BOTH copies, see `check_registry.sh`).
set -euo pipefail
cd "$(dirname "$0")/.."
SRC=${1:?pristine crates dir}
DST=vendor/stwo_cairo_verifier_ref
rm -rf "$DST/crates"
mkdir -p "$DST/crates"
for c in bounded_int verifier_utils verifier_core constraint_framework circuit_air; do
  cp -R "$SRC/$c" "$DST/crates/$c"
done
# Package names and their cross references. `core::internal::bounded_int` (a corelib path) and
# the `bounded_int_*` identifiers are left alone.
find "$DST/crates" \( -name Scarb.toml -o -name '*.cairo' \) -print0 | xargs -0 perl -pi -e '
  s/\bstwo_verifier_core\b/stwo_verifier_core_ref/g;
  s/\bstwo_verifier_utils\b/stwo_verifier_utils_ref/g;
  s/\bstwo_constraint_framework\b/stwo_constraint_framework_ref/g;
  s/\bstwo_circuit_air\b/stwo_circuit_air_ref/g;
  s/(?<![:\w])bounded_int(?=::)/bounded_int_ref/g;
  s/^bounded_int = \{/bounded_int_ref = {/;
  s/^name = "bounded_int"$/name = "bounded_int_ref"/;
'
cat > "$DST/Scarb.toml" <<'TOML'
# Pristine copy of the vendored verifier (see REF.md); own workspace like the original.
[workspace]
members = [
    "crates/bounded_int",
    "crates/circuit_air",
    "crates/constraint_framework",
    "crates/verifier_core",
    "crates/verifier_utils",
]

[workspace.dependencies]
cairo_execute = "2.18.0"
cairo_test = "2.18.0"

[workspace.tool.cairo-lint]
collapsible_if_else = false
double_parens = false
ifs_same_cond = false
manual_assert = false

[cairo]
enable-gas = false
allow-warnings = false
TOML
echo "pristine copy written to $DST (packages *_ref)"
