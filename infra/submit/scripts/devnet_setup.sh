#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Deploys what `submit-batch` submits to, on a LOCAL devnet: the four P4.0 verifier classes plus
# the router, and `DoomRuns` (P4.2). Nothing here is new — it is the declare/deploy half of
# `cairo/doom_contracts/tools/e2e_10felt_drive.py` split out, so the orchestrator can be driven
# against a router it did not deploy itself (which is the production shape: one router per
# verifier version, deployed once).
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
  local out
  out=$(sncast --json --accounts-file "$ACCOUNTS_FILE" --account "$ACCOUNT" \
        deploy --class-hash "$class_hash" --url "$URL" \
        ${1:+--constructor-calldata "$@"})
  echo "$out" | sed -n 's/.*"contract_address":"\(0x[0-9a-f]*\)".*/\1/p' | head -1
}

echo "declaring the verifier classes…"
BEGIN=$(declare_class StwoPhasesBegin doom_contracts)
MERKLE=$(declare_class StwoPhasesMerkle doom_contracts)
FRI=$(declare_class StwoPhasesFri doom_contracts)
ROUTER_CLASS=$(declare_class StwoCircuitRouter doom_contracts)
RUNS_CLASS=$(declare_class DoomRuns doom_runs)

echo "deploying the router…"
ROUTER=$(deploy "$ROUTER_CLASS" "$BEGIN" "$MERKLE" "$FRI")
OWNER=$(python3 -c "
import json,sys
doc=json.load(open('$ACCOUNTS_FILE'))
for net in doc.values():
    if '$ACCOUNT' in net:
        print(net['$ACCOUNT']['address']); break
")
echo "deploying DoomRuns (owner $OWNER)…"
RUNS=$(deploy "$RUNS_CLASS" "$OWNER")

cat > "$OUT" <<JSON
{
 "url": "$URL",
 "owner": "$OWNER",
 "router": "$ROUTER",
 "doom_runs": "$RUNS",
 "classes": {
  "StwoPhasesBegin": "$BEGIN",
  "StwoPhasesMerkle": "$MERKLE",
  "StwoPhasesFri": "$FRI",
  "StwoCircuitRouter": "$ROUTER_CLASS",
  "DoomRuns": "$RUNS_CLASS"
 }
}
JSON
echo "router   $ROUTER"
echo "DoomRuns $RUNS"
echo "-> $OUT"
