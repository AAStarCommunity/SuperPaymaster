#!/usr/bin/env bash
# =============================================================================
# Self-test of script/governance/check-timelock-roles.mjs on a LOCAL anvil (no public RPC; anvil's
# public dev accounts via --unlocked / impersonation; no private key is passed or printed).
#   1. correct M1 timelock + manifest                      -> checker PASSES
#   2. an extra, UNLISTED DEFAULT_ADMIN granted            -> FAILS   (the case the forge preflight
#                                                              cannot see: test_preflight_is_bounded_*)
#   3. that admin revoked again                            -> PASSES
#   4. PROPOSER granted to an address not in the manifest  -> FAILS; revoked -> PASSES
#   5. EXECUTOR granted to a mustHoldNothing account       -> FAILS; revoked -> PASSES
#   6. manifest deploymentBlock wrong (depth probe)        -> FAILS
# Every step also checks the attestation the checker wrote (--attest): result PASS iff the check passed.
# Usage: scripts/d5b-timelock-roles-selftest.sh <workDir>   (plain `forge build` first)
# =============================================================================
set -euo pipefail
W="$1"; mkdir -p "$W"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
ANVIL="${ANVIL:-$HOME/.foundry/bin/anvil}"; CAST="${CAST:-$HOME/.foundry/bin/cast}"
PORT="${PORT:-18792}"; RPC="http://127.0.0.1:$PORT"
OWNER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266     # anvil #0: deployer / old owner (mustHoldNothing)
SAFE=0x70997970C51812dc3A010C7d01b50e0d17dc79C8      # anvil #1: the governance Safe
X=0x00000000000000000000000000000000000AD111         # an address the manifest does not name
CHECK="node script/governance/check-timelock-roles.mjs"

"$ANVIL" --port "$PORT" --chain-id 31337 >"$W/anvil.log" 2>&1 &
APID=$!; echo "$APID" >"$W/anvil.pid"
trap 'kill "$APID" 2>/dev/null || true' EXIT
for _ in $(seq 1 100); do "$CAST" chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 0.2; done

art() { python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['bytecode']['object'])" "$1"; }
TL_CODE=$(art "$(ls out/TimelockController.sol/TimelockController*.json | head -1)")
R=$("$CAST" send --rpc-url "$RPC" --unlocked --from "$OWNER" --create \
  "$TL_CODE$("$CAST" abi-encode "c(uint256,address[],address[],address)" 172800 "[$SAFE]" "[$SAFE]" 0x0000000000000000000000000000000000000000 | sed 's/^0x//')" --json)
TL=$(echo "$R" | python3 -c "import json,sys;print(json.load(sys.stdin)['contractAddress'])")
BLK=$(echo "$R" | python3 -c "import json,sys;print(int(json.load(sys.stdin)['blockNumber'],16))")
manifest() { # <deploymentBlock> <out>
  printf '{\n  "network": "anvil-selftest",\n  "chainId": 31337,\n  "timelock": "%s",\n  "deploymentBlock": %s,\n  "roles": {\n    "DEFAULT_ADMIN_ROLE": ["%s"],\n    "PROPOSER_ROLE": ["%s"],\n    "CANCELLER_ROLE": ["%s"],\n    "EXECUTOR_ROLE": ["%s"]\n  },\n  "mustHoldNothing": ["%s"],\n  "mustHoldNothingLabels": ["deployer/old owner"]\n}\n' \
    "$TL" "$1" "$TL" "$SAFE" "$SAFE" "$SAFE" "$OWNER" >"$2"
}
manifest "$BLK" "$W/manifest.json"
"$CAST" rpc anvil_impersonateAccount "$TL" --rpc-url "$RPC" >/dev/null
"$CAST" rpc anvil_setBalance "$TL" 0xDE0B6B3A7640000 --rpc-url "$RPC" >/dev/null
asTL() { "$CAST" send --rpc-url "$RPC" --unlocked --from "$TL" "$TL" "$@" >/dev/null; }
ADMIN=0x0000000000000000000000000000000000000000000000000000000000000000
PROP=$("$CAST" keccak PROPOSER_ROLE); EXEC=$("$CAST" keccak EXECUTOR_ROLE)

n=0
expect() { # <0|1> <label>
  n=$((n+1)); set +e; $CHECK --rpc "$RPC" --manifest "$W/manifest.json" --out "$W/step$n.json" --attest "$W/att$n.json" >"$W/step$n.log" 2>&1; rc=$?; set -e
  res=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['result'])" "$W/att$n.json" 2>/dev/null || echo none)
  want=$([ "$1" = 0 ] && echo PASS || echo FAIL)
  if [ "$res" != "$want" ]; then echo "SELF-TEST FAILED at step $n: attestation result $res, expected $want"; exit 1; fi
  if [ "$rc" = "$1" ]; then echo "  step $n ok: $2 (exit $rc)"; else echo "SELF-TEST FAILED at step $n: $2 (exit $rc, expected $1)"; cat "$W/step$n.log"; exit 1; fi
}
echo "timelock $TL deployed in block $BLK"
expect 0 "correct M1 timelock == manifest"
asTL "grantRole(bytes32,address)" "$ADMIN" "$X";   expect 1 "unlisted DEFAULT_ADMIN granted"
asTL "revokeRole(bytes32,address)" "$ADMIN" "$X";  expect 0 "unlisted admin revoked"
asTL "grantRole(bytes32,address)" "$PROP" "$X";    expect 1 "PROPOSER granted to an address not in the manifest"
asTL "revokeRole(bytes32,address)" "$PROP" "$X";   expect 0 "that proposer revoked"
asTL "grantRole(bytes32,address)" "$EXEC" "$OWNER"; expect 1 "EXECUTOR granted to a mustHoldNothing account (old owner)"
asTL "revokeRole(bytes32,address)" "$EXEC" "$OWNER"; expect 0 "that executor revoked"
manifest "$((BLK + 3))" "$W/manifest.json";         expect 1 "manifest deploymentBlock wrong (depth probe / positive control)"
echo "TIMELOCK ROLE CHECKER SELF-TEST OK"
