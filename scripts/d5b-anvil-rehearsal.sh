#!/usr/bin/env bash
# =============================================================================
# D5b upgrade-flow rehearsal on a LOCAL anvil (no public RPC, anvil's public dev accounts,
# `--unlocked` — no private key is passed or printed). Spec 03 §6 A2 items 1/3/4 and §10.7b C:
#
#   setup  : previous release on chain — SP proxy on the c30854f9 SP impl (5.5.0 rc) and Registry
#            proxy on the c30854f9 Registry impl (5.8.0), both from contracts/test/fixtures/; a 48h
#            TimelockController (proposer = executor = "multisig" = anvil #1, admin none).
#   A (5c) : UpgradeRegistryD5b (EOA) — Registry 5.8.0 → D5b with read-backs.
#   A (5)  : UpgradeViaTimelock deploy-impl + direct-upgrade (EOA) — SP rc → D5b with read-backs.
#   B (M1) : EOA transferOwnership(timelock) on both; schedule-accept (ONE scheduleBatch
#            [SP.acceptOwnership, Registry.acceptOwnership, SP.setGuardian(Safe)]); negative: execute
#            before 48h fails; +48h; execute-accept; negative: the old EOA can no longer upgrade.
#   C      : timelock-aware upgrade for SP and Registry: deploy-impl → schedule-upgrade → negative early
#            execute → +48h → execute-upgrade (read-backs: impl slot, version, owner, pendingOwner 0,
#            default artifacts incl. the SP extension binding, BLS legs, raw slots).
#   M2     : guardian (the Safe) pauses; guardian unpause reverts; the unpause is scheduled / executed
#            through UpgradeViaTimelock schedule-call / execute-call (checker -> attestation -> gate).
#   EVERY timelock schedule / execute above runs check-timelock-roles.mjs first and passes its
#   attestation (TL_ROLES_ATTESTATION); each gate also has a negative 'WITHOUT a roles attestation'.
# Usage: scripts/d5b-anvil-rehearsal.sh <workDir>   (plain `forge build` first: default artifacts)
# =============================================================================
set -euo pipefail
W="$1"; mkdir -p "$W"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
ANVIL="${ANVIL:-$HOME/.foundry/bin/anvil}"; CAST="${CAST:-$HOME/.foundry/bin/cast}"; FORGE="${FORGE:-$HOME/.foundry/bin/forge}"
PORT="${PORT:-18791}"; RPC="http://127.0.0.1:$PORT"
ENVNAME="d5b-rehearsal"; CFG="deployments/config.$ENVNAME.json"
OWNER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266     # anvil dev account #0 (public)
MULTISIG=0x70997970C51812dc3A010C7d01b50e0d17dc79C8  # anvil dev account #1 (public) = proposer/executor/Safe
EP=0x0000000071727De22E5E9d8BAf0edAc6f37da032

"$ANVIL" --port "$PORT" --chain-id 31337 --hardfork osaka >"$W/anvil.log" 2>&1 &
APID=$!; echo "$APID" >"$W/anvil.pid"
MANIFEST="deployments/timelock-roles.$ENVNAME.json"
cleanup() { kill "$APID" 2>/dev/null || true; rm -f "$ROOT/$CFG" "$ROOT/$MANIFEST" "$ROOT"/deployments/attestations/timelock-roles."$ENVNAME".*.json; }
trap cleanup EXIT
for _ in $(seq 1 100); do "$CAST" chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 0.2; done

step() { echo; echo "=== $* ==="; }
art() { python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['bytecode']['object'])" "$1"; }
create() { # <creation hex> -> address
  "$CAST" send --rpc-url "$RPC" --unlocked --from "$OWNER" --create "$1" --json | python3 -c "import json,sys;print(json.load(sys.stdin)['contractAddress'])"
}
send() { local from="$1"; shift; "$CAST" send --rpc-url "$RPC" --unlocked --from "$from" "$@" >/dev/null; }
must_fail() { local what="$1"; shift; if "$@" >"$W/neg.log" 2>&1; then echo "NEGATIVE CONTROL FAILED: $what succeeded"; exit 1; else echo "  negative ok: $what reverted ($(grep -oE 'Error: [^,]{0,120}|revert[^,]{0,120}' "$W/neg.log" | head -1))"; fi; }
fscript() { # <contract> <sender> [env...]
  local c="$1" s="$2"; shift 2
  env ENV="$ENVNAME" "$@" "$FORGE" script "contracts/script/v3/UpgradeViaTimelock.s.sol:$c" \
    --rpc-url "$RPC" --unlocked --sender "$s" --broadcast --slow 2>&1
}
warp48h() { "$CAST" rpc evm_increaseTime 172800 --rpc-url "$RPC" >/dev/null; "$CAST" rpc evm_mine --rpc-url "$RPC" >/dev/null; }
impl_of() { "$CAST" storage "$1" 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc --rpc-url "$RPC" | sed 's/0x000000000000000000000000/0x/'; }

step "setup: previous release (c30854f9) on chain"
"$CAST" rpc anvil_setCode "$EP" "$(cat contracts/test/fixtures/entrypoint-v0.7.runtime.hex)" --rpc-url "$RPC" >/dev/null
FEED=$(create "$(art out/AnvilMockPriceFeed.sol/AnvilMockPriceFeed.json)")
PROXY_CODE=$(art "$(ls out/ERC1967Proxy.sol/ERC1967Proxy*.json | head -1)")
REG_IMPL=$(create "$(cat contracts/test/fixtures/registry-5.8.0-c30854f9-impl.creation.hex)")
REG_INIT=$("$CAST" calldata "initialize(address,address,address)" "$OWNER" 0x0000000000000000000000000000000000005701 0x00000000000000000000000000000000000005B7)
REG=$(create "$PROXY_CODE$("$CAST" abi-encode "c(address,bytes)" "$REG_IMPL" "$REG_INIT" | sed 's/^0x//')")
SP_IMPL=$(create "$(cat contracts/test/fixtures/superpaymaster-5.5.0-c30854f9-impl.creation.hex)$("$CAST" abi-encode "c(address,address,address)" "$EP" "$REG" "$FEED" | sed 's/^0x//')")
SP_INIT=$("$CAST" calldata "initialize(address,address,address,uint256)" "$OWNER" 0x0000000000000000000000000000000000000000 "$OWNER" 3600)
SP=$(create "$PROXY_CODE$("$CAST" abi-encode "c(address,bytes)" "$SP_IMPL" "$SP_INIT" | sed 's/^0x//')")
TL_CODE=$(art "$(ls out/TimelockController.sol/TimelockController*.json | head -1)")
TL=$(create "$TL_CODE$("$CAST" abi-encode "c(uint256,address[],address[],address)" 172800 "[$MULTISIG]" "[$MULTISIG]" 0x0000000000000000000000000000000000000000 | sed 's/^0x//')")
TL_BLOCK=$("$CAST" block-number --rpc-url "$RPC") # automine: the timelock CREATE is the latest block
send "$OWNER" "$REG" "setSuperPaymaster(address)" "$SP"
send "$OWNER" "$REG" "setBLSAggregator(address)" 0x0000000000000000000000000000000000000B15
send "$OWNER" "$SP" "initBLSAggregator(address)" 0x0000000000000000000000000000000000000B15
send "$OWNER" "$SP" "updatePrice()"
printf '{\n  "superPaymaster": "%s",\n  "registry": "%s",\n  "entryPoint": "%s",\n  "priceFeed": "%s",\n  "timelockController": "%s"\n}\n' \
  "$SP" "$REG" "$EP" "$FEED" "$TL" >"$CFG"
cp "$CFG" "$W/config.$ENVNAME.json"
# committed-manifest shape (deployments/timelock-roles.example.json): M1 policy + historical accounts
printf '{\n  "network": "%s",\n  "chainId": 31337,\n  "timelock": "%s",\n  "deploymentBlock": %s,\n  "roles": {\n    "DEFAULT_ADMIN_ROLE": ["%s"],\n    "PROPOSER_ROLE": ["%s"],\n    "CANCELLER_ROLE": ["%s"],\n    "EXECUTOR_ROLE": ["%s"]\n  },\n  "mustHoldNothing": ["%s"],\n  "mustHoldNothingLabels": ["deployer / old SP and Registry owner"]\n}\n' \
  "$ENVNAME" "$TL" "$TL_BLOCK" "$TL" "$MULTISIG" "$MULTISIG" "$MULTISIG" "$OWNER" >"$MANIFEST"
cp "$MANIFEST" "$W/timelock-roles.$ENVNAME.json"
roles_check() { # event-history role check -> attestation; UpgradeViaTimelock REQUIRES it (TL_ROLES_ATTESTATION)
  node script/governance/check-timelock-roles.mjs --rpc "$RPC" --manifest "$MANIFEST" --out "$W/roles-$1.json" \
    --attest "deployments/attestations/timelock-roles.$ENVNAME.$1.json" | tee "$W/roles-$1.log" | tail -2
  ATT="deployments/attestations/timelock-roles.$ENVNAME.$1.json"   # forge may only read inside the project
  cp "$ATT" "$W/attestation-$1.json"
}
echo "  SP proxy $SP (impl $SP_IMPL, $("$CAST" call "$SP" 'version()(string)' --rpc-url "$RPC"))"
echo "  Registry proxy $REG (impl $REG_IMPL, $("$CAST" call "$REG" 'version()(string)' --rpc-url "$RPC"))"
echo "  TimelockController $TL (minDelay $("$CAST" call "$TL" 'getMinDelay()(uint256)' --rpc-url "$RPC"))"

step "A / runbook 5c: UpgradeRegistryD5b (EOA)"
fscript UpgradeRegistryD5b "$OWNER" | tee "$W/A-5c.log" | grep -E "read-back|BLS|raw slots|5c|Error|revert" || true
grep -q "5c done" "$W/A-5c.log"

step "A / runbook 5: SP rc -> D5b (EOA): deploy-impl + direct-upgrade"
fscript UpgradeViaTimelock "$OWNER" TL_MODE=deploy-impl TL_TARGET=SP | tee "$W/A-5-deploy.log" | grep -E "ready|new implementation|Error|revert" || true
NEW_SP=$(grep -oE "pass as TL_NEW_IMPL\): 0x[0-9a-fA-F]{40}" "$W/A-5-deploy.log" | awk '{print $NF}')
fscript UpgradeViaTimelock "$OWNER" TL_MODE=direct-upgrade TL_TARGET=SP TL_NEW_IMPL="$NEW_SP" | tee "$W/A-5-upgrade.log" | grep -E "read-back|BLS|raw slots|extension|Error|revert" || true
[ "$(impl_of "$SP" | tr A-F a-f)" = "$(echo "$NEW_SP" | tr A-F a-f)" ]

step "B / M1: two-step transfer to the timelock + ONE scheduleBatch"
send "$OWNER" "$SP" "transferOwnership(address)" "$TL"
send "$OWNER" "$REG" "transferOwnership(address)" "$TL"
echo "  after step 1: SP.owner=$("$CAST" call "$SP" 'owner()(address)' --rpc-url "$RPC") pendingOwner=$("$CAST" call "$SP" 'pendingOwner()(address)' --rpc-url "$RPC")"
must_fail "schedule-accept WITHOUT a roles attestation" fscript UpgradeViaTimelock "$MULTISIG" TL_MODE=schedule-accept
roles_check before-M1
fscript UpgradeViaTimelock "$MULTISIG" TL_MODE=schedule-accept TL_ROLES_ATTESTATION="$ATT" | tee "$W/B-schedule.log" | grep -E "scheduled|Error|revert" || true
must_fail "execute-accept before 48h" fscript UpgradeViaTimelock "$MULTISIG" TL_MODE=execute-accept TL_ROLES_ATTESTATION="$ATT"
warp48h
roles_check before-M1-execute
fscript UpgradeViaTimelock "$MULTISIG" TL_MODE=execute-accept TL_ROLES_ATTESTATION="$ATT" | tee "$W/B-execute.log" | grep -E "read-back|Error|revert" || true
grep -q "M1/M2 read-back OK" "$W/B-execute.log"
must_fail "old EOA owner upgradeToAndCall after M1" "$CAST" send --rpc-url "$RPC" --unlocked --from "$OWNER" "$SP" "upgradeToAndCall(address,bytes)" "$NEW_SP" 0x

step "C / §10.7b C: timelock-aware upgrade (SP then Registry)"
for T in SP REGISTRY; do
  fscript UpgradeViaTimelock "$OWNER" TL_MODE=deploy-impl TL_TARGET=$T | tee "$W/C-$T-deploy.log" | grep -E "ready|new implementation|Error|revert" || true
  NI=$(grep -oE "pass as TL_NEW_IMPL\): 0x[0-9a-fA-F]{40}" "$W/C-$T-deploy.log" | awk '{print $NF}')
  must_fail "schedule-upgrade $T WITHOUT a roles attestation" fscript UpgradeViaTimelock "$MULTISIG" TL_MODE=schedule-upgrade TL_TARGET=$T TL_NEW_IMPL="$NI" TL_SALT=$("$CAST" keccak "c-$T")
  roles_check "before-$T-upgrade"
  fscript UpgradeViaTimelock "$MULTISIG" TL_MODE=schedule-upgrade TL_ROLES_ATTESTATION="$ATT" TL_TARGET=$T TL_NEW_IMPL="$NI" TL_SALT=$("$CAST" keccak "c-$T") | tee "$W/C-$T-schedule.log" | grep -E "scheduled|Error|revert" || true
  must_fail "execute-upgrade $T before 48h" fscript UpgradeViaTimelock "$MULTISIG" TL_MODE=execute-upgrade TL_ROLES_ATTESTATION="$ATT" TL_TARGET=$T TL_NEW_IMPL="$NI" TL_SALT=$("$CAST" keccak "c-$T")
  warp48h
  roles_check "before-$T-execute"
  fscript UpgradeViaTimelock "$MULTISIG" TL_MODE=execute-upgrade TL_ROLES_ATTESTATION="$ATT" TL_TARGET=$T TL_NEW_IMPL="$NI" TL_SALT=$("$CAST" keccak "c-$T") | tee "$W/C-$T-execute.log" | grep -E "read-back|BLS|raw slots|extension|Error|revert" || true
  grep -q "read-back OK" "$W/C-$T-execute.log"
done
if [ "$(impl_of "$SP" | tr A-F a-f)" = "$(echo "$NEW_SP" | tr A-F a-f)" ]; then echo "C: SP impl did not move"; exit 1; fi

step "M2 drill: guardian (Safe) pauses; guardian cannot unpause; timelock unpauses after 48h"
send "$MULTISIG" "$SP" "setGlobalPaused(bool)" true
echo "  paused() = $("$CAST" call "$SP" 'paused()(bool)' --rpc-url "$RPC")"
must_fail "guardian unpause" "$CAST" send --rpc-url "$RPC" --unlocked --from "$MULTISIG" "$SP" "setGlobalPaused(bool)" false
UNP=$("$CAST" calldata "setGlobalPaused(bool)" false)
# Codex re-check L1: the unpause is a timelock schedule like any other -> checker -> attestation -> gate
must_fail "schedule-call (unpause) WITHOUT a roles attestation" fscript UpgradeViaTimelock "$MULTISIG" TL_MODE=schedule-call TL_TARGET=SP TL_CALLDATA="$UNP" TL_SALT=$("$CAST" keccak m2-unpause)
roles_check before-M2-unpause
fscript UpgradeViaTimelock "$MULTISIG" TL_MODE=schedule-call TL_ROLES_ATTESTATION="$ATT" TL_TARGET=SP TL_CALLDATA="$UNP" TL_SALT=$("$CAST" keccak m2-unpause) | tee "$W/M2-schedule.log" | grep -E "roles attestation|scheduled|Error|revert" || true
grep -q "call scheduled" "$W/M2-schedule.log"
must_fail "execute-call (unpause) before 48h" fscript UpgradeViaTimelock "$MULTISIG" TL_MODE=execute-call TL_ROLES_ATTESTATION="$ATT" TL_TARGET=SP TL_CALLDATA="$UNP" TL_SALT=$("$CAST" keccak m2-unpause)
warp48h
roles_check before-M2-unpause-execute
fscript UpgradeViaTimelock "$MULTISIG" TL_MODE=execute-call TL_ROLES_ATTESTATION="$ATT" TL_TARGET=SP TL_CALLDATA="$UNP" TL_SALT=$("$CAST" keccak m2-unpause) | tee "$W/M2-execute.log" | grep -E "roles attestation|executed|Error|revert" || true
grep -q "governed call executed" "$W/M2-execute.log"
[ "$("$CAST" call "$SP" 'paused()(bool)' --rpc-url "$RPC")" = "false" ]
echo "  paused() after the timelock's unpause = false"

step "final state"
echo "  SP owner=$("$CAST" call "$SP" 'owner()(address)' --rpc-url "$RPC") guardian=$("$CAST" call "$SP" 'guardian()(address)' --rpc-url "$RPC") impl=$(impl_of "$SP") version=$("$CAST" call "$SP" 'version()(string)' --rpc-url "$RPC")"
echo "  Registry owner=$("$CAST" call "$REG" 'owner()(address)' --rpc-url "$RPC") impl=$(impl_of "$REG") version=$("$CAST" call "$REG" 'version()(string)' --rpc-url "$RPC")"
echo "REHEARSAL OK"
