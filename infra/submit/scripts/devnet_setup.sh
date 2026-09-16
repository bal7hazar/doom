#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Deploys what `submit-batch` submits to, on a LOCAL devnet: the four P4.0 verifier classes plus
# the router, and `DoomRuns` (P4.2, D35). Nothing here is new — it is the declare/deploy half of
# `cairo/doom_contracts/tools/e2e_10felt_drive.py` split out, so the orchestrator can be driven
# against a router it did not deploy itself (which is the production shape: one router per
# verifier version, deployed once).
#
# `DoomRuns` (D35) takes `(owner, fee_token, expiry_blocks)`: the fee token defaults to a fresh
# `MockERC20` (the mintable stand-in of the contract tests, so `test/devnet.test.ts` can fund a
# bounty), `FEE_TOKEN=0x…` points it at an existing ERC20 (devnet's STRK is
# 0x04718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d) and `EXPIRY_BLOCKS`
# (default 20, the commit drive's value; production would be longer) is the reclaim delay.
#
# The version table (`add_version` / `set_genesis`) is *not* set here: those values come from the
# batch being submitted, so `submit-batch --setup-version` does it from the fixture.
#
#   starknet-devnet --seed 42 --port 5081 --accounts 3 --state-archive-capacity full \
#     --initial-balance 100000000000000000000000 \
#     --gas-price 1054411845 --gas-price-fri 92599658875965 \
#     --data-gas-price 426840 --data-gas-price-fri 37485578886 \
#     --l2-gas-price 347016 --l2-gas-price-fri 30475398907
#   sncast --accounts-file accounts.json account import --url http://127.0.0.1:5081/rpc \
#     --name devnet42 --type oz --address <addr> --private-key <key>
#   infra/submit/scripts/devnet_setup.sh accounts.json http://127.0.0.1:5081/rpc out.json
set -euo pipefail

ACCOUNTS_FILE=${1:?accounts file}
URL=${2:-http://127.0.0.1:5081/rpc}
OUT=${3:-deployment.json}
ACCOUNT=${ACCOUNT:-devnet42}
EXPIRY_BLOCKS=${EXPIRY_BLOCKS:-20}

case "$URL" in
  *127.0.0.1*|*localhost*) ;;
  *) echo "refusing to deploy anywhere but a local devnet: $URL" >&2; exit 1 ;;
esac

HERE=$(cd "$(dirname "$0")" && pwd)
PKG="$HERE/../../../cairo/doom_contracts"
ACCOUNTS_FILE=$(cd "$(dirname "$ACCOUNTS_FILE")" && pwd)/$(basename "$ACCOUNTS_FILE")
OUT=$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")
cd "$PKG"

declare_class() {
  local name=$1 package=$2 out
  out=$(sncast --json --accounts-file "$ACCOUNTS_FILE" --account "$ACCOUNT" \
        declare --contract-name "$name" --package "$package" --url "$URL" 2>&1 || true)
  local hash
  hash=$(echo "$out" | sed -n 's/.*"class_hash":"\(0x[0-9a-f]*\)".*/\1/p' | head -1)
  if [ -z "$hash" ]; then
    hash=$(echo "$out" | sed -n 's/.*class hash \(0x[0-9a-f]*\).*/\1/p' | head -1)
  fi
  [ -n "$hash" ] || { echo "declare $name failed:" >&2; echo "$out" >&2; exit 1; }
  echo "$hash"
}

deploy() {
  local class_hash=$1; shift
  local args=(--json --accounts-file "$ACCOUNTS_FILE" --account "$ACCOUNT"
              deploy --class-hash "$class_hash" --url "$URL")
  [ $# -gt 0 ] && args+=(--constructor-calldata "$@")
  sncast "${args[@]}" | sed -n 's/.*"contract_address":"\(0x[0-9a-f]*\)".*/\1/p' | head -1
}

echo "declaring the verifier classes…"
BEGIN=$(declare_class StwoPhasesBegin doom_contracts)
MERKLE=$(declare_class StwoPhasesMerkle doom_contracts)
FRI=$(declare_class StwoPhasesFri doom_contracts)
ROUTER_CLASS=$(declare_class StwoCircuitRouter doom_contracts)
RUNS_CLASS=$(declare_class DoomRuns doom_runs)
if [ -z "${FEE_TOKEN:-}" ]; then
  TOKEN_CLASS=$(declare_class MockERC20 doom_runs)
fi

echo "deploying the router…"
ROUTER=$(deploy "$ROUTER_CLASS" "$BEGIN" "$MERKLE" "$FRI")
OWNER=$(python3 -c "
import json,sys
doc=json.load(open('$ACCOUNTS_FILE'))
for net in doc.values():
    if '$ACCOUNT' in net:
        print(net['$ACCOUNT']['address']); break
")
if [ -z "${FEE_TOKEN:-}" ]; then
  echo "deploying MockERC20 (the fee token)…"
  FEE_TOKEN=$(deploy "$TOKEN_CLASS")
fi
echo "deploying DoomRuns (owner $OWNER, fee token $FEE_TOKEN, expiry $EXPIRY_BLOCKS blocks)…"
RUNS=$(deploy "$RUNS_CLASS" "$OWNER" "$FEE_TOKEN" "$(printf '0x%x' "$EXPIRY_BLOCKS")")

cat > "$OUT" <<JSON
{
 "url": "$URL",
 "owner": "$OWNER",
 "router": "$ROUTER",
 "doom_runs": "$RUNS",
 "fee_token": "$FEE_TOKEN",
 "expiry_blocks": $EXPIRY_BLOCKS,
 "classes": {
  "StwoPhasesBegin": "$BEGIN",
  "StwoPhasesMerkle": "$MERKLE",
  "StwoPhasesFri": "$FRI",
  "StwoCircuitRouter": "$ROUTER_CLASS",
  "DoomRuns": "$RUNS_CLASS"
 }
}
JSON
echo "router    $ROUTER"
echo "fee token $FEE_TOKEN"
echo "DoomRuns  $RUNS"
echo "-> $OUT"
