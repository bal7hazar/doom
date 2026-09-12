#!/usr/bin/env bash
# Regenerates `recursion_outputs/src/fixtures.cairo` from the monorepo golden and from every
# pipeline run under results/ that has a packed_output.json (S4: N1..N4 with the `doom` registry;
# S4b: the fold_step-4, poseidon and 1.59 M-step runs).
#
#   spikes/s4/scripts/gen_all_fixtures.sh
#
# A run contributes its `VerificationOutput.output_hash` assertion too when
# `verifier_output.json` is present (produce it with `verifier_output.sh`).
set -euo pipefail
source "$(dirname "$0")/env.sh"

R="$S4_DIR/results"
GOLDEN="$PROVING/crates/stwo_run_and_prove_recursive_tree/test_data/goldens/four_leaves"
SPECS=("golden_four_leaves:$GOLDEN/root_packed.json:$GOLDEN/root_outputs.json")

# Fixture name -> results directory. Order fixes the order of the generated tests.
for dir in N1_doom N2_doom N3_doom N4_doom N2_doom_fold4 N2_doom_poseidon N2_doom_big; do
  [ -f "$R/$dir/packed_output.json" ] || continue
  name="$(echo "$dir" | tr 'A-Z' 'a-z')"
  spec="$name:$R/$dir/packed_output.json:$R/$dir/program_output.json"
  [ -f "$R/$dir/verifier_output.json" ] && spec="$spec:$R/$dir/verifier_output.json"
  SPECS+=("$spec")
done

python3 "$S4_DIR/scripts/gen_fixtures.py" "$S4_DIR/recursion_outputs/src/fixtures.cairo" "${SPECS[@]}"
( cd "$S4_DIR/recursion_outputs" && scarb test )
