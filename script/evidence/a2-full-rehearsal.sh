#!/usr/bin/env bash
# A2 (rc1 gate) COMPLETE fork rehearsal — CC-122 / DSR directive v4, audit finding #3.
#
# Supersedes the coverage of script/evidence/d5b-fork-rehearsal.sh (archive
# fork-rehearsal-full-11729160-b3e2d3eb), which printed "REHEARSAL OK (all)" although it did not cover
# what 03-final-spec.md §6 requires for A2:
#   * it used the deployer EOA as PROPOSER/CANCELLER/EXECUTOR of the OLD live TimelockController
#     0x86C8…9564 for SP/Registry (and a SECOND, fresh timelock for APNTsCapped) — the spec's M1 timelock
#     is Safe-only (proposer/canceller/executor = governance multisig, admin renounced);
#   * no AOAProtocolRegistry / xPNTsFactoryV2 owner transfer (M1, M-6);
#   * no M3 (setAPNTSPrice via the timelock);
#   * the 7c acceptance UserOp ran for ANNI/Mycelium only, not for AAStar (OWNER).
#
# What this script does differently:
#   * ONE canonical GOV-1 TimelockController (minDelay 172800; admin = the timelock itself ONLY;
#     PROPOSER = CANCELLER = EXECUTOR = the Mycelium Safe ONLY), deployed on the fork from the
#     profile.default OZ artifact. It is the owner target for APNTsCapped, SP, Registry,
#     AOAProtocolRegistry and xPNTsFactoryV2. Its exact role member sets are rebuilt from the
#     RoleGranted/RoleRevoked history (check-timelock-roles.mjs) at several points, and the raw role
#     events are dumped.
#   * Every Safe action is a REAL Safe.execTransaction (Safe v1.4.1, 2-of-3) on the fork: two of the
#     three real owner EOAs are impersonated (anvil) and sign with the Safe's "approved hash" scheme
#     (owner A approveHash(h); owner B execTransaction with [A v=1, B v=1] sorted ascending). The Safe
#     address itself is NEVER impersonated (no anvil_impersonateAccount on it, no --from SAFE).
#   * Every step has its own read-back line with the block number it was read at ("readback [...] = v
#     @block N") and an explicit CHECK line; every tx is logged with hash + block + status and its full
#     receipt is appended to receipts.jsonl; every negative control is logged with the head block it
#     was attempted at and its full output is appended to neg.log.
#   * Runtime code of every deployed 5.5.0 contract is compared with docs/release/v5.5.0-rc.2-attestation.json
#     (immutables masked, see verify-attested-runtime.mjs), plus a negative control.
#
# LOCAL ANVIL FORK ONLY. Nothing is broadcast to any public network: every forge/cast write below
# targets http://127.0.0.1:$PORT. The public RPC is used only as anvil --fork-url and for READ-ONLY
# pre-state cross-checks. RPC URLs and private keys are never written to $OUT.
#
# Usage: script/evidence/a2-full-rehearsal.sh <env file with RPC_URL> <fork block> <out dir> [stage]
#   stage: all (default) | comma list of 0,I,II
# Prerequisites: forge build (profile.default) done; pnpm install (viem).
set -uo pipefail
ENVFILE="$1"; FORK_BLOCK="$2"; OUT="$3"; STAGE="${4:-all}"
stage_on() { [ "$STAGE" = "all" ] && return 0; case ",$STAGE," in *",$1,"*) return 0 ;; esac; return 1; }
export PATH="$HOME/.foundry/bin:$HOME/.local/bin:$PATH"
W="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$W"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"   # absolute: node require() / forge cwd-independent
envval() { grep -E "^$1=" "$ENVFILE" | head -1 | cut -d= -f2- | tr -d '"'"'"' '; }
RPC_URL_FORK="$(envval RPC_URL)"
[ -n "$RPC_URL_FORK" ] || { echo "no RPC_URL in env file"; exit 2; }
# Second, independent endpoint for the read-only pre-state cross-check (keyless public node).
RPC_URL_X="${RPC_URL_X:-https://ethereum-sepolia-rpc.publicnode.com}"

OWNER=0xb5600060e6de5E11D3636731964218E53caadf0E   # live SP + Registry owner EOA (deployer), AAStar community/operator
ANNI=0xEcAACb915f7D92e9916f449F7ad42BD0408733c9    # live operator, Mycelium community
SAFE=0x51eDf11fDb0A4F66220eFb8efA54Eca77232E114    # Mycelium governance Safe (v1.4.1, 2-of-3)
SAFE_O1=0x871608cBA092105b91e91295A1d79fFC539BFb48 # Safe owners (live getOwners()); O1 < O2 numerically
SAFE_O2=0x8c3499252232105A1615767C459DB9BBbf1273D6
SAFE_O3=0xBB05d2E9890BceC6141e40A1066bf8927169b75E # not used to sign (2-of-3)
SP=0x09DF0d2e3722EC0e401fE3819E64278a42ae4DE9
REG=0xf5Bf37ca83AfdAab73691bA7eCcDfA69b8708E71
OLD_TL=0x86C86c789EDc099801cc6a5F48334F1D67dC9564  # live Sepolia timelock: NOT used (deployer holds every role)
EP=0x0000000071727De22E5E9d8BAf0edAc6f37da032
OLD_APNTS=0x696A73701b104c6cCBbAadDD2216788ea08EaB89
PRICE_FEED=0x694AA1769357215DE4FAC081bf1f309aDC325306
ENVNAME=sepolia
ATTEST_JSON=docs/release/v5.5.0-rc.2-attestation.json
LOG=script/evidence/run-logged.sh
ZERO32=0x0000000000000000000000000000000000000000000000000000000000000000
ADMIN_ROLE=$ZERO32
PROPOSER_ROLE=$(cast keccak PROPOSER_ROLE); CANCELLER_ROLE=$(cast keccak CANCELLER_ROLE); EXECUTOR_ROLE=$(cast keccak EXECUTOR_ROLE)

# The M1 manifest path is FIXED by UpgradeViaTimelock.s.sol (deployments/timelock-roles.<ENV>.json): back up
# a pre-existing real one and restore it on exit (same contract as d5b-fork-rehearsal.sh).
MANIFEST="deployments/timelock-roles.$ENVNAME.json"
MANIFEST_PREEXISTED=0
if [ -f "$W/$MANIFEST" ]; then MANIFEST_PREEXISTED=1; cp "$W/$MANIFEST" "$OUT/.REAL-manifest-backup.json"; fi
FAILURES=0
PIDS=()
cleanup() {
  for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done
  if [ "$MANIFEST_PREEXISTED" = "1" ]; then cp "$OUT/.REAL-manifest-backup.json" "$W/$MANIFEST"; rm -f "$OUT/.REAL-manifest-backup.json"; else rm -f "$W/$MANIFEST"; fi
  rm -f "$W"/deployments/attestations/timelock-roles."$ENVNAME".a2-rehearsal-*.json
  rm -f "$W/deployments/config.sepolia-fork-anni.json" "$W/deployments/config.sepolia-fork-aastar.json"
  rm -f "$OUT/.sendtx.err" "$OUT/.neg.tmp"
}
trap cleanup EXIT

PORT="${A2_PORT:-28613}"; RPC="http://127.0.0.1:$PORT"
rlog() { echo "$*" | tee -a "$OUT/rehearsal.log"; }
step() { echo; echo "=== $* ===" | tee -a "$OUT/rehearsal.log"; }
bn() { cast block-number --rpc-url "$RPC"; }
lc() { echo "$1" | tr 'A-F' 'a-f'; }
fail() { rlog "  !!! $*"; FAILURES=$((FAILURES+1)); }
# rb <label> <cast call args...>: read at an explicit block, log "readback [label] = v @block N", print v.
rb() {
  local label="$1"; shift
  local b v; b=$(bn)
  v=$(cast call "$@" --rpc-url "$RPC" --block "$b" 2>&1 | tr '\n' ' ' | sed -E 's/ +$//; s/ \[[0-9.e+]+\]//g')
  echo "  readback [$label] = $v @block $b" | tee -a "$OUT/rehearsal.log" >&2
  echo "$v"
}
# rbs <label> <address> <slot>: raw storage read-back
rbs() {
  local label="$1" b v; b=$(bn)
  v=$(cast storage "$2" "$3" --rpc-url "$RPC" --block "$b")
  echo "  readback [$label] = $v @block $b" | tee -a "$OUT/rehearsal.log" >&2
  echo "$v"
}
check() { # check <label> <actual> <expected>   (case-insensitive)
  if [ "$(lc "$2")" = "$(lc "$3")" ]; then rlog "  CHECK [$1] PASS: $2"; else fail "CHECK [$1] FAIL: got '$2' expected '$3'"; fi
}
# sendtx <label> <from> <cast send args...>: one impersonated tx; logs hash/block/status + full receipt.
LAST_TX=""; LAST_BLOCK=""
sendtx() {
  local label="$1" from="$2"; shift 2
  local j rc
  j=$(cast send --unlocked --from "$from" --rpc-url "$RPC" --json "$@" 2>"$OUT/.sendtx.err"); rc=$?
  if [ $rc -ne 0 ] || [ -z "$j" ]; then fail "TX [$label] could not be sent: $(tr '\n' ' ' < "$OUT/.sendtx.err" | head -c 400)"; LAST_TX=""; return 1; fi
  echo "$j" | jq -c --arg label "$label" '{label:$label} + .' >> "$OUT/receipts.jsonl"
  LAST_TX=$(echo "$j" | jq -r .transactionHash); LAST_BLOCK=$(( $(echo "$j" | jq -r .blockNumber) ))
  local st; st=$(echo "$j" | jq -r .status)
  if [ "$st" = "0x1" ]; then rlog "  TX [$label] hash=$LAST_TX block=$LAST_BLOCK status=0x1 from=$from"
  else fail "TX [$label] hash=$LAST_TX block=$LAST_BLOCK status=$st (REVERTED on chain)"; return 1; fi
}
# must_fail <what> <cmd...>: negative control; the full output goes to neg.log with the head block.
NEG_N=0
must_fail() {
  local what="$1"; shift
  local b0 b1 rc reason; b0=$(bn)
  "$@" >"$OUT/.neg.tmp" 2>&1; rc=$?
  b1=$(bn)
  NEG_N=$((NEG_N+1))
  { echo "### NEG-$NEG_N [$what] head block before=$b0 after=$b1 exit=$rc"; sed -E 's#https?://[^ ]*@?[^ ]*(alchemy|infura|publicnode)[^ ]*#<redacted-rpc>#g' "$OUT/.neg.tmp"; echo; } >> "$OUT/neg.log"
  if [ $rc -eq 0 ]; then
    rlog "NEGATIVE CONTROL FAILED: NEG-$NEG_N [$what] succeeded @block $b1"; FAILURES=$((FAILURES+1)); exit 1
  fi
  reason=$(grep -oE 'GS[0-9]{3}|AccessControl[A-Za-z]+|Ownable[A-Za-z]+|TimelockUnexpectedOperationState|TimelockInsufficientDelay|Unauthorized|execution reverted[^,]{0,120}|Error: [^,]{0,160}|revert[^,]{0,120}' "$OUT/.neg.tmp" | head -1)
  rlog "  negative ok NEG-$NEG_N [$what]: reverted @block $b0 (head after $b1) ($reason)"
  jq -nc --arg id "NEG-$NEG_N" --arg what "$what" --arg b "$b0" --arg reason "$reason" '{id:$id,what:$what,headBlock:($b|tonumber),reason:$reason}' >> "$OUT/neg-controls.jsonl"
}
warp() { cast rpc evm_increaseTime "$1" --rpc-url "$RPC" >/dev/null; cast rpc evm_mine --rpc-url "$RPC" >/dev/null; rlog "  warp +$1 s -> block $(bn) ts $(cast block latest --field timestamp --rpc-url "$RPC")"; }
impl_of() { cast storage "$1" 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc --rpc-url "$RPC" | sed 's/0x000000000000000000000000/0x/'; }

# ---------------------------------------------------------------- Safe (real execTransaction, 2-of-3)
safe_sig() { printf '000000000000000000000000%s%064d01' "$(lc "${1#0x}")" 0; }
SIGS2="0x$(safe_sig $SAFE_O1)$(safe_sig $SAFE_O2)"   # sorted ascending: O1 < O2
SIG1="0x$(safe_sig $SAFE_O2)"                        # single owner (threshold negative control)
safe_hash() { cast call $SAFE 'getTransactionHash(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,uint256)(bytes32)' "$1" 0 "$2" 0 0 0 0 0x0000000000000000000000000000000000000000 0x0000000000000000000000000000000000000000 "$3" --rpc-url "$RPC"; }
EXEC_SIG='execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)'
# safe_exec <label> <to> <data>: owner O1 approveHash(h) -> owner O2 execTransaction([O1,O2] approved-hash sigs)
safe_exec() {
  local label="$1" to="$2" data="$3" n h n2 ev
  n=$(rb "$label: Safe.nonce before" $SAFE 'nonce()(uint256)')
  h=$(safe_hash "$to" "$data" "$n")
  rlog "  Safe tx [$label]: to=$to nonce=$n safeTxHash=$h data=${data:0:74}$([ ${#data} -gt 74 ] && echo …)"
  sendtx "$label: approveHash by owner $SAFE_O1" $SAFE_O1 $SAFE 'approveHash(bytes32)' "$h" || return 1
  check "$label: approvedHashes(O1,h)" "$(rb "$label: approvedHashes" $SAFE 'approvedHashes(address,bytes32)(uint256)' $SAFE_O1 "$h")" 1
  sendtx "$label: execTransaction by owner $SAFE_O2 (2-of-3)" $SAFE_O2 $SAFE "$EXEC_SIG" "$to" 0 "$data" 0 0 0 0 0x0000000000000000000000000000000000000000 0x0000000000000000000000000000000000000000 "$SIGS2" || return 1
  ev=$(cast receipt "$LAST_TX" --rpc-url "$RPC" --json | jq -r --arg s "$(lc $SAFE)" --arg t "$(cast keccak 'ExecutionSuccess(bytes32,uint256)')" '[.logs[] | select((.address|ascii_downcase)==$s and .topics[0]==$t)] | length')
  check "$label: Safe ExecutionSuccess event in $LAST_TX" "$ev" 1
  n2=$(rb "$label: Safe.nonce after" $SAFE 'nonce()(uint256)')
  check "$label: Safe.nonce incremented" "$n2" "$((n+1))"
  SAFE_LAST_TX=$LAST_TX
}
# safe_exec_must_fail <label> <to> <data>: approveHash (real tx) then the exec must revert (inner call fails -> GS013)
safe_exec_must_fail() {
  local label="$1" to="$2" data="$3" n h
  n=$(rb "$label: Safe.nonce" $SAFE 'nonce()(uint256)')
  h=$(safe_hash "$to" "$data" "$n")
  sendtx "$label: approveHash by owner $SAFE_O1 (for a negative control)" $SAFE_O1 $SAFE 'approveHash(bytes32)' "$h" || return 1
  must_fail "$label" cast send $SAFE "$EXEC_SIG" "$to" 0 "$data" 0 0 0 0 0x0000000000000000000000000000000000000000 0x0000000000000000000000000000000000000000 "$SIGS2" --unlocked --from $SAFE_O2 --rpc-url "$RPC"
  check "$label: Safe.nonce unchanged after the failed exec" "$(rb "$label: Safe.nonce after" $SAFE 'nonce()(uint256)')" "$n"
}
# timelock helpers (target, data, salt) -> calldata for the Safe
tl_schedule_data() { cast calldata 'schedule(address,uint256,bytes,bytes32,bytes32,uint256)' "$1" 0 "$2" $ZERO32 "$3" 172800; }
tl_execute_data() { cast calldata 'execute(address,uint256,bytes,bytes32,bytes32)' "$1" 0 "$2" $ZERO32 "$3"; }
tl_id() { cast call $TL 'hashOperation(address,uint256,bytes,bytes32,bytes32)(bytes32)' "$1" 0 "$2" $ZERO32 "$3" --rpc-url "$RPC"; }

# forge helpers ------------------------------------------------------------------------------
# fscript_tl: see d5b-fork-rehearsal.sh (forge 1.7.1 dual-profile target-resolution bug, root-caused in
# 4f07a370): delete only cache/solidity-files-cache.json before each UpgradeViaTimelock call.
fscript_tl() { # <contract> <sender> <broadcast:yes|no> [env...]
  local c="$1" s="$2" bc="$3"; shift 3
  local attempt out rc extra=()
  [ "$bc" = "yes" ] && extra=(--unlocked --broadcast --slow)
  for attempt in 1 2 3; do
    rm -f cache/solidity-files-cache.json
    out="$(env ENV="$ENVNAME" TIMELOCK="$TL" "$@" forge script "contracts/script/v3/UpgradeViaTimelock.s.sol:$c" \
      --rpc-url "$RPC" --sender "$s" "${extra[@]}" 2>&1)"
    rc=$?
    echo "$out"
    if [ $rc -eq 0 ]; then return 0; fi
    if ! echo "$out" | grep -qE "Could not find target contract|DefaultArtifacts: no profile.default build"; then return $rc; fi
    echo "  (fscript_tl attempt $attempt/3: retrying with a fresh cache wipe)" >&2
  done
  return $rc
}
# payload_after <log> <marker regex>: the first hex line (>= 4 bytes + data) printed after the marker
payload_after() { awk -v m="$2" 'f && $1 ~ /^0x[0-9a-fA-F]+$/ && length($1) > 74 {print $1; exit} $0 ~ m {f=1}' "$1"; }
roles_check() { # <label>: rebuild the exact role sets from event history (check-timelock-roles.mjs) + attest
  ATT="deployments/attestations/timelock-roles.$ENVNAME.a2-rehearsal-$1.json"
  node script/governance/check-timelock-roles.mjs --rpc "$RPC" --manifest "$OUT/manifest.json" --out "$OUT/roles-$1.json" \
    --attest "$ATT" > "$OUT/roles-$1.log" 2>&1
  local rc=$?
  sed 's/^/    /' "$OUT/roles-$1.log" | tee -a "$OUT/rehearsal.log" >/dev/null
  cp "$ATT" "$OUT/attestation-$1.json" 2>/dev/null
  if [ $rc -eq 0 ]; then rlog "  CHECK [roles $1: event-history holder sets == manifest] PASS (roles-$1.log)"; else fail "CHECK [roles $1] FAIL (exit $rc, roles-$1.log)"; fi
  cast rpc evm_mine --rpc-url "$RPC" >/dev/null   # the attested head needs a successor for blockhash()
}
role_events_dump() { # <label>: raw RoleGranted / RoleRevoked logs of $TL since deployment
  local g r; g=$(cast keccak 'RoleGranted(bytes32,address,address)'); r=$(cast keccak 'RoleRevoked(bytes32,address,address)')
  { cast logs --address $TL --from-block "$TL_DEPLOY_BLOCK" --to-block latest "$g" --rpc-url "$RPC" --json;
    cast logs --address $TL --from-block "$TL_DEPLOY_BLOCK" --to-block latest "$r" --rpc-url "$RPC" --json; } \
    | jq -s --arg g "$g" --arg label "$1" --arg head "$(bn)" '
        def hex: ltrimstr("0x") | ascii_downcase | explode | reduce .[] as $c (0; . * 16 + (if $c >= 97 then $c - 87 else $c - 48 end));
        {label:$label, headBlock:($head|tonumber),
        events:([ .[][] | {event:(if .topics[0]==$g then "RoleGranted" else "RoleRevoked" end), role:.topics[1],
        account:("0x"+(.topics[2][26:])), sender:("0x"+(.topics[3][26:])), blockNumber:(.blockNumber|hex), logIndex:(.logIndex|hex), tx:.transactionHash}] | sort_by(.blockNumber, .logIndex))}' \
    > "$OUT/role-events-$1.json"
  rlog "  role events [$1]: $(jq '.events|length' "$OUT/role-events-$1.json") RoleGranted/RoleRevoked logs since block $TL_DEPLOY_BLOCK (role-events-$1.json)"
}
attest_runtime() { # <label> <args for verify-attested-runtime.mjs>
  local label="$1"; shift
  node script/evidence/verify-attested-runtime.mjs --rpc "$RPC" --attestation "$ATTEST_JSON" --out-dir out \
    --report "$OUT/codehash-$label.json" "$@" > "$OUT/codehash-$label.log" 2>&1
  local rc=$?
  sed 's/^/    /' "$OUT/codehash-$label.log" | tee -a "$OUT/rehearsal.log" >/dev/null
  if [ $rc -eq 0 ]; then rlog "  CHECK [codehash $label == rc.2 attestation] PASS (codehash-$label.log)"; else fail "CHECK [codehash $label] FAIL (codehash-$label.log)"; fi
}

# ================================================================================================
step "provenance"
rlog "  script commit: $(git rev-parse HEAD)$(git diff --quiet HEAD -- contracts script || echo ' (+ uncommitted changes)')"
rlog "  contracts/src vs v5.5.0-rc.2 peeled commit 1ac0e1c5: $(git diff --quiet 1ac0e1c595dc84e684b540ca6a936168e922194f HEAD -- contracts/src && echo IDENTICAL || echo DIFFERENT)"
git diff --quiet 1ac0e1c595dc84e684b540ca6a936168e922194f HEAD -- contracts/src || { fail "contracts/src differs from rc.2"; exit 1; }
rlog "  forge: $(forge --version | head -1); anvil: $(anvil --version | head -1)"
step "build reproduces the rc.2 attestation (artifact keccaks)"
node docs/release/attest-hashes.mjs out > "$OUT/00-attest-hashes-local.json" 2>&1 || fail "attest-hashes.mjs failed"
node -e '
const a=require(process.argv[1]), l=require(process.argv[2]); let bad=0;
for (const c of a.contracts){ const x=l.find(r=>r.contract===c.contract);
  const ok = x && x.runtimeKeccak===c.runtimeKeccak && x.creationKeccak===c.creationKeccak;
  if(!ok) bad++; console.log(`${ok?"MATCH   ":"MISMATCH"} ${c.contract} runtime ${x&&x.runtimeKeccak} creation ${x&&x.creationKeccak}`);}
console.log(bad?`BUILD != ATTESTATION (${bad})`:`BUILD == ATTESTATION (${a.contracts.length}/${a.contracts.length} runtime+creation)`); process.exit(bad?1:0);' \
  "$W/$ATTEST_JSON" "$OUT/00-attest-hashes-local.json" > "$OUT/00-build-vs-attestation.log" 2>&1
RC=$?; sed 's/^/    /' "$OUT/00-build-vs-attestation.log" | tee -a "$OUT/rehearsal.log" >/dev/null
[ $RC -eq 0 ] && rlog "  CHECK [local build == rc.2 attestation] PASS" || { fail "local build != rc.2 attestation"; exit 1; }

step "pre-state cross-check at Sepolia block $FORK_BLOCK on two independent endpoints (read-only)"
xread() { # <url> -> key=value lines
  local u="$1" B="$FORK_BLOCK"
  echo "blockHash=$(cast block $B --field hash --rpc-url "$u")"
  echo "SP.version=$(cast call $SP 'version()(string)' --rpc-url "$u" --block $B)"
  echo "SP.owner=$(cast call $SP 'owner()(address)' --rpc-url "$u" --block $B)"
  echo "SP.implSlot=$(cast storage $SP 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc --rpc-url "$u" --block $B)"
  echo "SP.APNTS_TOKEN=$(cast call $SP 'APNTS_TOKEN()(address)' --rpc-url "$u" --block $B)"
  echo "SP.pendingAPNTsToken=$(cast call $SP 'pendingAPNTsToken()(address)' --rpc-url "$u" --block $B)"
  echo "SP.pendingAPNTsTokenEta=$(cast call $SP 'pendingAPNTsTokenEta()(uint256)' --rpc-url "$u" --block $B)"
  echo "SP.totalTrackedBalance=$(cast call $SP 'totalTrackedBalance()(uint256)' --rpc-url "$u" --block $B | awk '{print $1}')"
  echo "SP.operators(OWNER)=$(cast call $SP 'operators(address)(uint128,bool,bool,address,uint32,uint48,address,uint256,uint256)' $OWNER --rpc-url "$u" --block $B | awk '{print $1}' | tr '\n' ',')"
  echo "SP.operators(ANNI)=$(cast call $SP 'operators(address)(uint128,bool,bool,address,uint32,uint48,address,uint256,uint256)' $ANNI --rpc-url "$u" --block $B | awk '{print $1}' | tr '\n' ',')"
  echo "EP.depositInfo(SP)=$(cast call $EP 'getDepositInfo(address)((uint256,bool,uint112,uint32,uint48))' $SP --rpc-url "$u" --block $B)"
  echo "Registry.version=$(cast call $REG 'version()(string)' --rpc-url "$u" --block $B)"
  echo "Registry.owner=$(cast call $REG 'owner()(address)' --rpc-url "$u" --block $B)"
  echo "Registry.implSlot=$(cast storage $REG 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc --rpc-url "$u" --block $B)"
  echo "Safe.VERSION=$(cast call $SAFE 'VERSION()(string)' --rpc-url "$u" --block $B)"
  echo "Safe.owners=$(cast call $SAFE 'getOwners()(address[])' --rpc-url "$u" --block $B)"
  echo "Safe.threshold=$(cast call $SAFE 'getThreshold()(uint256)' --rpc-url "$u" --block $B)"
  echo "Safe.nonce=$(cast call $SAFE 'nonce()(uint256)' --rpc-url "$u" --block $B)"
  echo "Safe.guardSlot=$(cast storage $SAFE 0x4a204f620c8c5ccdca3fd54d003badd85ba500436a431f0cbda4f558c93c34c8 --rpc-url "$u" --block $B)"
  echo "Safe.modules=$(cast call $SAFE 'getModulesPaginated(address,uint256)(address[],address)' 0x0000000000000000000000000000000000000001 10 --rpc-url "$u" --block $B | tr '\n' ' ')"
  echo "OLD_TL.minDelay=$(cast call $OLD_TL 'getMinDelay()(uint256)' --rpc-url "$u" --block $B | awk '{print $1}')"
  echo "OLD_TL.proposer(Safe)=$(cast call $OLD_TL 'hasRole(bytes32,address)(bool)' $PROPOSER_ROLE $SAFE --rpc-url "$u" --block $B)"
  echo "OLD_TL.admin(OWNER)=$(cast call $OLD_TL 'hasRole(bytes32,address)(bool)' $ADMIN_ROLE $OWNER --rpc-url "$u" --block $B)"
}
xread "$RPC_URL_FORK" > "$OUT/0-prestate-endpointA.txt" 2>&1
xread "$RPC_URL_X" > "$OUT/0-prestate-endpointB.txt" 2>&1
{ echo "# endpoint A = the anvil --fork-url provider (key-bearing URL, not written); endpoint B = $RPC_URL_X"
  echo "# block $FORK_BLOCK; identical lines below are equal on both endpoints"
  diff "$OUT/0-prestate-endpointA.txt" "$OUT/0-prestate-endpointB.txt" && echo "IDENTICAL ($(wc -l < "$OUT/0-prestate-endpointA.txt" | tr -d ' ') values)"; } > "$OUT/0-prestate-crosscheck.log" 2>&1
if grep -q '^IDENTICAL' "$OUT/0-prestate-crosscheck.log" && ! grep -qiE 'error|revert' "$OUT/0-prestate-endpointA.txt"; then
  rlog "  CHECK [pre-state @$FORK_BLOCK identical on two endpoints] PASS ($(tail -1 "$OUT/0-prestate-crosscheck.log"))"
else fail "pre-state cross-check differs or errored (0-prestate-crosscheck.log)"; fi
sed 's/^/    /' "$OUT/0-prestate-endpointA.txt" | tee -a "$OUT/rehearsal.log" >/dev/null

step "fork Sepolia at block $FORK_BLOCK (local anvil :$PORT)"
anvil --fork-url "$RPC_URL_FORK" --fork-block-number "$FORK_BLOCK" --port "$PORT" --silent >"$OUT/anvil-stdout.log" 2>&1 &
PIDS+=($!)
for _ in $(seq 1 60); do cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 1; done
# impersonate EOAs only (never the Safe)
for a in $OWNER $ANNI $SAFE_O1 $SAFE_O2; do
  cast rpc anvil_impersonateAccount $a --rpc-url "$RPC" >/dev/null
  cast rpc anvil_setBalance $a 0x56BC75E2D63100000 --rpc-url "$RPC" >/dev/null
done
rlog "  chainId $(cast chain-id --rpc-url $RPC) head $(bn) forkBlockHash $(cast block $FORK_BLOCK --field hash --rpc-url $RPC)"
check "fork block hash == endpoint A" "$(cast block $FORK_BLOCK --field hash --rpc-url $RPC)" "$(grep '^blockHash=' "$OUT/0-prestate-endpointA.txt" | cut -d= -f2)"
rlog "  impersonated on the fork: OWNER, ANNI, Safe owners O1/O2 (EOAs). The Safe $SAFE is NOT impersonated."
check "Safe threshold (fork)" "$(rb 'Safe.getThreshold' $SAFE 'getThreshold()(uint256)')" 2
check "Safe owners (fork)" "$(rb 'Safe.getOwners' $SAFE 'getOwners()(address[])')" "[$SAFE_O1, $SAFE_O3, $SAFE_O2]"
check "Safe guard slot empty" "$(rbs 'Safe guard slot' $SAFE 0x4a204f620c8c5ccdca3fd54d003badd85ba500436a431f0cbda4f558c93c34c8)" $ZERO32

if stage_on 0; then
step "STAGE 0 (runbook 0): fork-level probes (public RPCs, read-only) + on-chain inventory"
node script/evidence/fork-level-probes.mjs "$OUT/0-fork-level-probes.json" > "$OUT/0-fork-level-probes.log" 2>&1 || fail "fork-level probes failed"
rlog "  eth_config: $(grep -o '"next":[^,}]*' "$OUT/0-fork-level-probes.json" | head -1)"
ENV=$ENVNAME $LOG "$OUT/0-inventory.log" forge script contracts/script/v3/UpgradeToV5_5_0.s.sol:UpgradeToV5_5_0 --sig 'inventory(address[])' "[$OWNER,$ANNI]" --rpc-url $RPC || fail "inventory"
grep -E "pendingAPNTsToken|operator " "$OUT/0-inventory.log" | sed 's/^/    /' | tee -a "$OUT/rehearsal.log" >/dev/null
ANNI_TOKEN=$(cast call $SP 'operators(address)(uint128,bool,bool,address,uint32,uint48,address,uint256,uint256)' $ANNI --rpc-url $RPC | sed -n '4p')
ENV=$ENVNAME $LOG "$OUT/0-inventory-debts.log" forge script contracts/script/v3/UpgradeToV5_5_0.s.sol:UpgradeToV5_5_0 --sig 'inventoryDebts(address[],address[])' "[$OLD_APNTS,$ANNI_TOKEN]" "[$OWNER,$ANNI]" --rpc-url $RPC || fail "inventoryDebts"
grep -E "pendingDebts|total" "$OUT/0-inventory-debts.log" | sed 's/^/    /' | tee -a "$OUT/rehearsal.log" >/dev/null
fi

if stage_on I; then
stop1() { [ "$2" -eq 0 ] || { fail "STAGE I / $1 FAILED (exit $2) -- stopping"; exit 1; }; }

step "STAGE I / G0 (GOV-1): deploy the ONE canonical Safe-only TimelockController (minDelay 172800; proposers=[Safe]; executors=[Safe]; admin=address(0) -> only the timelock administers itself)"
TLART=out/TimelockController.sol/TimelockController.default.json
[ -f "$TLART" ] || TLART=out/TimelockController.sol/TimelockController.json
TLBC="$(node -e 'const j=require(process.argv[1]);const m=j.metadata;if(m.settings.evmVersion!=="cancun"||m.settings.optimizer.runs!==500)throw new Error("not a default build");console.log(j.bytecode.object)' "$W/$TLART")"
TLARGS="$(cast abi-encode 'c(uint256,address[],address[],address)' 172800 "[$SAFE]" "[$SAFE]" 0x0000000000000000000000000000000000000000)"
rlog "  constructor args: minDelay=172800 proposers=[$SAFE] executors=[$SAFE] admin=0x0 (artifact $TLART)"
sendtx "G0 deploy canonical TimelockController" $OWNER --create "$TLBC${TLARGS#0x}"; stop1 G0 $?
TL=$(cast receipt "$LAST_TX" contractAddress --rpc-url $RPC); TL_DEPLOY_BLOCK=$LAST_BLOCK
rlog "  CANONICAL GOV-1 TIMELOCK = $TL (deployed in block $TL_DEPLOY_BLOCK, tx $LAST_TX)"
rlog "  runtime codehash $(cast keccak "$(cast code $TL --rpc-url $RPC)") ($( (cast code $TL --rpc-url $RPC | wc -c) | awk '{print ($1-3)/2}') B)"
check "G0 getMinDelay" "$(rb 'TL.getMinDelay' $TL 'getMinDelay()(uint256)')" 172800
for who in TL:$TL SAFE:$SAFE OWNER:$OWNER SAFE_O1:$SAFE_O1 SAFE_O2:$SAFE_O2 SAFE_O3:$SAFE_O3 ZERO:0x0000000000000000000000000000000000000000; do
  n=${who%%:*}; a=${who#*:}
  for r in ADMIN:$ADMIN_ROLE PROPOSER:$PROPOSER_ROLE CANCELLER:$CANCELLER_ROLE EXECUTOR:$EXECUTOR_ROLE; do
    rn=${r%%:*}; rh=${r#*:}
    exp=false
    { [ "$n" = TL ] && [ "$rn" = ADMIN ]; } && exp=true
    { [ "$n" = SAFE ] && [ "$rn" != ADMIN ]; } && exp=true
    check "G0 hasRole($rn, $n)" "$(rb "TL.hasRole($rn,$n)" $TL 'hasRole(bytes32,address)(bool)' $rh $a)" $exp
  done
done
role_events_dump G0-deploy
check "G0 deploy-block role events == exactly 4 grants (ADMIN->TL, PROPOSER/CANCELLER/EXECUTOR->Safe)" \
  "$(jq -r '[.events[] | "\(.event):\(.role):\(.account)"] | sort | join(",")' "$OUT/role-events-G0-deploy.json")" \
  "$(printf '%s\n' "RoleGranted:$ADMIN_ROLE:$(lc $TL)" "RoleGranted:$PROPOSER_ROLE:$(lc $SAFE)" "RoleGranted:$CANCELLER_ROLE:$(lc $SAFE)" "RoleGranted:$EXECUTOR_ROLE:$(lc $SAFE)" | LC_ALL=C sort | paste -sd, -)"
# M1 manifest for THIS timelock: admin=[TL]; P=C=E=[Safe]; mustHoldNothing = the deployer EOA (it sent the
# deploy tx and the old live timelock's every role; here it must hold nothing) + the old live timelock.
cat > "$OUT/manifest.draft.json" <<JSON
{
  "network": "$ENVNAME",
  "chainId": "11155111",
  "timelock": "$TL",
  "deploymentBlock": "$TL_DEPLOY_BLOCK",
  "roles": {
    "DEFAULT_ADMIN_ROLE": ["$TL"],
    "PROPOSER_ROLE": ["$SAFE"],
    "CANCELLER_ROLE": ["$SAFE"],
    "EXECUTOR_ROLE": ["$SAFE"]
  },
  "mustHoldNothing": ["$OWNER", "$OLD_TL"],
  "mustHoldNothingLabels": ["deployer EOA: deployed this timelock, current SP/Registry owner, holds every role on the old live timelock", "old live Sepolia TimelockController 0x86C8 (not GOV-1 shaped), superseded by this one"]
}
JSON
node script/governance/check-timelock-roles.mjs --canonicalize "$OUT/manifest.draft.json" > "$W/$MANIFEST" || { fail "manifest canonicalize"; exit 1; }
cp "$W/$MANIFEST" "$OUT/manifest.json"
roles_check G0-after-deploy

step "STAGE I / A1 (runbook 1①): cancel the pending 0xBb46 aPNTs switch"
check "A1 pre: pendingAPNTsToken" "$(rb 'SP.pendingAPNTsToken' $SP 'pendingAPNTsToken()(address)')" 0xBb46321545a91DB2F3B5c3e694F2f23aBe259883
ENV=$ENVNAME V55_APNTS_DECISION=cancel $LOG "$OUT/I-A1-cancel.log" forge script contracts/script/v3/UpgradeToV5_5_0.s.sol:UpgradeToV5_5_0 --sig 'cancelPendingAPNTs()' --rpc-url $RPC --unlocked --sender $OWNER --broadcast --slow
stop1 A1 $?
check "A1 pendingAPNTsToken after cancel" "$(rb 'SP.pendingAPNTsToken' $SP 'pendingAPNTsToken()(address)')" 0x0000000000000000000000000000000000000000

step "STAGE I / A1c (runbook 1②): deploy APNTsCapped (minter = capGuardian = Safe) and start the Ownable2Step handover to the CANONICAL timelock"
ENV=$ENVNAME TIMELOCK=$TL $LOG "$OUT/I-A1c-deploy-apnts-capped.log" forge script contracts/script/v3/DeployAPNTsCapped.s.sol:DeployAPNTsCapped --rpc-url $RPC --unlocked --sender $OWNER --broadcast --slow
stop1 A1c $?
CAPPED=$(grep -oE "\[artifact\] default artifact OK: APNTsCapped 0x[0-9a-fA-F]{40}" "$OUT/I-A1c-deploy-apnts-capped.log" | awk '{print $NF}')
[ -n "$CAPPED" ] || { fail "A1c: no APNTsCapped address"; exit 1; }
rlog "  APNTsCapped = $CAPPED"
check "A1c APNTsCapped.owner" "$(rb 'APNTsCapped.owner' $CAPPED 'owner()(address)')" $OWNER
check "A1c APNTsCapped.pendingOwner == canonical TL" "$(rb 'APNTsCapped.pendingOwner' $CAPPED 'pendingOwner()(address)')" $TL
check "A1c APNTsCapped.minter == Safe" "$(rb 'APNTsCapped.minter' $CAPPED 'minter()(address)')" $SAFE
check "A1c APNTsCapped.capGuardian == Safe" "$(rb 'APNTsCapped.capGuardian' $CAPPED 'capGuardian()(address)')" $SAFE
attest_runtime A1c-APNTsCapped --target APNTsCapped=$CAPPED

step "STAGE I / A1d (GOV-1 accept): Safe -> TL.schedule(APNTsCapped.acceptOwnership) -> 48h -> Safe -> TL.execute"
ACC=$(cast calldata "acceptOwnership()"); ACC_SALT=$(cast keccak "a2/APNTsCapped/acceptOwnership")
ACC_ID=$(tl_id $CAPPED $ACC $ACC_SALT)
must_fail "A1d: deployer EOA cannot schedule on the canonical TL (not PROPOSER)" cast send $TL 'schedule(address,uint256,bytes,bytes32,bytes32,uint256)' $CAPPED 0 $ACC $ZERO32 $ACC_SALT 172800 --unlocked --from $OWNER --rpc-url $RPC
must_fail "A1d: a Safe OWNER EOA acting directly (not through the Safe) cannot schedule" cast send $TL 'schedule(address,uint256,bytes,bytes32,bytes32,uint256)' $CAPPED 0 $ACC $ZERO32 $ACC_SALT 172800 --unlocked --from $SAFE_O1 --rpc-url $RPC
must_fail "A1d: Safe exec with ONE owner signature (threshold 2) -> GS020" cast send $SAFE "$EXEC_SIG" $TL 0 "$(tl_schedule_data $CAPPED $ACC $ACC_SALT)" 0 0 0 0 0x0000000000000000000000000000000000000000 0x0000000000000000000000000000000000000000 "$SIG1" --unlocked --from $SAFE_O2 --rpc-url $RPC
safe_exec "A1d schedule acceptOwnership" $TL "$(tl_schedule_data $CAPPED $ACC $ACC_SALT)" || { fail "A1d schedule"; exit 1; }
check "A1d op pending" "$(rb 'TL.isOperationPending(acc)' $TL 'isOperationPending(bytes32)(bool)' $ACC_ID)" true
rlog "  op $ACC_ID ready at $(rb 'TL.getTimestamp(acc)' $TL 'getTimestamp(bytes32)(uint256)' $ACC_ID)"
safe_exec_must_fail "A1d: Safe execute BEFORE 48h (TimelockUnexpectedOperationState)" $TL "$(tl_execute_data $CAPPED $ACC $ACC_SALT)"
warp 172800
must_fail "A1d: deployer EOA cannot execute (not EXECUTOR)" cast send $TL 'execute(address,uint256,bytes,bytes32,bytes32)' $CAPPED 0 $ACC $ZERO32 $ACC_SALT --unlocked --from $OWNER --rpc-url $RPC
safe_exec "A1d execute acceptOwnership" $TL "$(tl_execute_data $CAPPED $ACC $ACC_SALT)" || { fail "A1d execute"; exit 1; }
check "A1d op done" "$(rb 'TL.isOperationDone(acc)' $TL 'isOperationDone(bytes32)(bool)' $ACC_ID)" true
check "A1d APNTsCapped.owner == canonical TL" "$(rb 'APNTsCapped.owner' $CAPPED 'owner()(address)')" $TL
check "A1d APNTsCapped.pendingOwner == 0" "$(rb 'APNTsCapped.pendingOwner' $CAPPED 'pendingOwner()(address)')" 0x0000000000000000000000000000000000000000
ENV=$ENVNAME TIMELOCK=$TL $LOG "$OUT/I-A1d-verify-apnts-capped.log" forge script contracts/script/v3/DeployAPNTsCapped.s.sol:DeployAPNTsCapped --sig 'verify(address,address)' $CAPPED $OWNER --rpc-url $RPC
[ $? -eq 0 ] && grep -q "verify: ALL PASS" "$OUT/I-A1d-verify-apnts-capped.log" && rlog "  CHECK [A1d DeployAPNTsCapped.verify] PASS (I-A1d-verify-apnts-capped.log)" || fail "A1d DeployAPNTsCapped.verify"

step "STAGE I / A1e (runbook 1③): queue setAPNTsToken(APNTsCapped)"
ENV=$ENVNAME V55_APNTS_DECISION=queue $LOG "$OUT/I-A1e-queue.log" forge script contracts/script/v3/UpgradeToV5_5_0.s.sol:UpgradeToV5_5_0 --sig 'queueAPNTs(address)' $CAPPED --rpc-url $RPC --unlocked --sender $OWNER --broadcast --slow
stop1 A1e $?
QB=$(bn); QTS=$(cast block $QB --field timestamp --rpc-url $RPC)
check "A1e pendingAPNTsToken == APNTsCapped" "$(rb 'SP.pendingAPNTsToken' $SP 'pendingAPNTsToken()(address)')" $CAPPED
check "A1e pendingAPNTsTokenEta == queue block ts + 7d" "$(rb 'SP.pendingAPNTsTokenEta' $SP 'pendingAPNTsTokenEta()(uint256)')" $((QTS+604800))
must_fail "A1e: executeAPNTsTokenChange before the 7-day ETA" cast send $SP 'executeAPNTsTokenChange()' --unlocked --from $OWNER --rpc-url $RPC
warp 604800

step "STAGE I / A1f: Safe (minter) mints APNTsCapped for the 1:1 redeposit — real Safe.execTransaction"
OWNER_OLD_BAL=$(cast call $SP 'operators(address)(uint128,bool,bool,address,uint32,uint48,address,uint256,uint256)' $OWNER --rpc-url $RPC | head -1 | awk '{print $1}')
ANNI_OLD_BAL=$(cast call $SP 'operators(address)(uint128,bool,bool,address,uint32,uint48,address,uint256,uint256)' $ANNI --rpc-url $RPC | head -1 | awk '{print $1}')
rlog "  snapshot: OWNER aPNTsBalance=$OWNER_OLD_BAL ANNI aPNTsBalance=$ANNI_OLD_BAL @block $(bn)"
must_fail "A1f: deployer EOA cannot mint APNTsCapped (minter = Safe)" cast send $CAPPED 'mint(address,uint256)' $OWNER 1 --unlocked --from $OWNER --rpc-url $RPC
safe_exec "A1f mint OWNER" $CAPPED "$(cast calldata 'mint(address,uint256)' $OWNER $OWNER_OLD_BAL)" || { fail A1f; exit 1; }
safe_exec "A1f mint ANNI" $CAPPED "$(cast calldata 'mint(address,uint256)' $ANNI $ANNI_OLD_BAL)" || { fail A1f; exit 1; }
safe_exec "A1f mint SP buffer 0.1" $CAPPED "$(cast calldata 'mint(address,uint256)' $SP 100000000000000000)" || { fail A1f; exit 1; }
check "A1f balanceOf(OWNER)" "$(rb 'APNTsCapped.balanceOf(OWNER)' $CAPPED 'balanceOf(address)(uint256)' $OWNER)" $OWNER_OLD_BAL
check "A1f balanceOf(ANNI)" "$(rb 'APNTsCapped.balanceOf(ANNI)' $CAPPED 'balanceOf(address)(uint256)' $ANNI)" $ANNI_OLD_BAL
check "A1f balanceOf(SP)" "$(rb 'APNTsCapped.balanceOf(SP)' $CAPPED 'balanceOf(address)(uint256)' $SP)" 100000000000000000

step "STAGE I / A1g (runbook 1④, checkpoint P1): drain every operator, executeAPNTsTokenChange, redeposit 1:1"
ENV=$ENVNAME V55_APNTS_DECISION=execute V55_APNTS_RATIO_WAD=1000000000000000000 $LOG "$OUT/I-A1g-execute.log" forge script contracts/script/v3/UpgradeToV5_5_0.s.sol:UpgradeToV5_5_0 --sig 'executePendingAPNTs(address[])' "[$OWNER,$ANNI]" --rpc-url $RPC --unlocked --sender $OWNER --broadcast --slow
stop1 A1g $?
check "A1g APNTS_TOKEN == APNTsCapped" "$(rb 'SP.APNTS_TOKEN' $SP 'APNTS_TOKEN()(address)')" $CAPPED
check "A1g pendingAPNTsToken == 0" "$(rb 'SP.pendingAPNTsToken' $SP 'pendingAPNTsToken()(address)')" 0x0000000000000000000000000000000000000000
check "A1g OWNER balance == snapshot x1" "$(rb 'SP.operators(OWNER).aPNTsBalance' $SP 'operators(address)(uint128,bool,bool,address,uint32,uint48,address,uint256,uint256)' $OWNER | awk '{print $1}')" $OWNER_OLD_BAL
check "A1g ANNI balance == snapshot x1" "$(rb 'SP.operators(ANNI).aPNTsBalance' $SP 'operators(address)(uint128,bool,bool,address,uint32,uint48,address,uint256,uint256)' $ANNI | awk '{print $1}')" $ANNI_OLD_BAL
TT=$(rb 'SP.totalTrackedBalance' $SP 'totalTrackedBalance()(uint256)' | awk '{print $1}'); REV=$(rb 'SP.protocolRevenue' $SP 'protocolRevenue()(uint256)' | awk '{print $1}')
check "A1g totalTrackedBalance == sum + revenue" "$TT" "$(python3 -c "print($OWNER_OLD_BAL+$ANNI_OLD_BAL+$REV)")"
CAPSUP=$(rb 'APNTsCapped.totalSupply' $CAPPED 'totalSupply()(uint256)' | awk '{print $1}'); CAP=$(rb 'APNTsCapped.cap' $CAPPED 'cap()(uint256)' | awk '{print $1}')
check "A1g totalSupply <= cap" "$(python3 -c "print($CAPSUP <= $CAP)")" True

step "STAGE I / A1h (runbook 2): pendingDebts — inventory found none; clearPendingDebts is a read-back no-op"
ANNI_TOKEN=$(cast call $SP 'operators(address)(uint128,bool,bool,address,uint32,uint48,address,uint256,uint256)' $ANNI --rpc-url $RPC | sed -n '4p')
ENV=$ENVNAME $LOG "$OUT/I-A1h-clear-debts.log" forge script contracts/script/v3/UpgradeToV5_5_0.s.sol:UpgradeToV5_5_0 --sig 'clearPendingDebts(address[],address[])' "[$OLD_APNTS,$ANNI_TOKEN]" "[$OWNER,$ANNI]" --rpc-url $RPC --unlocked --sender $OWNER --broadcast --slow
stop1 A1h $?
check "A1h pendingDebts(OLD_APNTS,OWNER)" "$(rb 'SP.pendingDebts(OLD_APNTS,OWNER)' $SP 'pendingDebts(address,address)(uint256)' $OLD_APNTS $OWNER)" 0
check "A1h pendingDebts(ANNI_TOKEN,ANNI)" "$(rb 'SP.pendingDebts(ANNI_TOKEN,ANNI)' $SP 'pendingDebts(address,address)(uint256)' $ANNI_TOKEN $ANNI)" 0

step "STAGE I / A2 (runbook 3): pause both legacy operators"
ENV=$ENVNAME $LOG "$OUT/I-A2-pause.log" forge script contracts/script/v3/UpgradeToV5_5_0.s.sol:UpgradeToV5_5_0 --sig 'pauseOperators(address[])' "[$OWNER,$ANNI]" --rpc-url $RPC --unlocked --sender $OWNER --broadcast --slow
stop1 A2 $?
for o in OWNER:$OWNER ANNI:$ANNI; do check "A2 isPaused(${o%%:*})" "$(rb "SP.operators(${o%%:*}).isPaused" $SP 'operators(address)(uint128,bool,bool,address,uint32,uint48,address,uint256,uint256)' ${o#*:} | awk '{print $3}')" true; done

step "STAGE I / A3 (runbook 4, 5, 5b, 6): v2 stack + SP upgradeToAndCall -> 5.5.0 (rc.2 bytecode) + stake + setXPNTsFactory"
mkdir -p cache/evidence-a2
V55_CFG=cache/evidence-a2/config.sepolia-fork.json; rm -f "$V55_CFG"
ENV=$ENVNAME V55_OUT_CONFIG=$V55_CFG V55_OPERATORS=$OWNER,$ANNI \
  $LOG "$OUT/I-A3-run.log" forge script contracts/script/v3/UpgradeToV5_5_0.s.sol:UpgradeToV5_5_0 --rpc-url $RPC --unlocked --sender $OWNER --broadcast --slow
stop1 A3 $?
cp "$V55_CFG" "$OUT/I-A3-config.sepolia-fork.json"
grep -E "read-back OK|step-5|step-5b|setXPNTsFactory|new impl" "$OUT/I-A3-run.log" | sed 's/^/    /' | tee -a "$OUT/rehearsal.log" >/dev/null
SPIMPL=$(jq -r .spImpl "$V55_CFG"); AOAREG=$(jq -r .aoaProtocolRegistry "$V55_CFG"); FACT=$(jq -r .xPNTsFactoryV2 "$V55_CFG")
TIER=$(jq -r .globalTierSource "$V55_CFG"); V2EXT=$(jq -r .xPNTsTokenV2Ext "$V55_CFG"); V2IMPL=$(jq -r .xPNTsTokenV2Impl "$V55_CFG"); LENS=$(jq -r .superPaymasterLens "$V55_CFG")
check "A3 SP.version" "$(rb 'SP.version' $SP 'version()(string)')" '"SuperPaymaster-5.5.0"'
check "A3 SP impl slot == new impl" "$(impl_of $SP)" "$SPIMPL"
SPEXT=$(rb 'SP.EXTENSION' $SP 'EXTENSION()(address)')
check "A3 SP.xpntsFactory == factoryV2" "$(rb 'SP.xpntsFactory' $SP 'xpntsFactory()(address)')" $FACT
check "A3 factoryV2.SUPERPAYMASTER == SP" "$(rb 'factoryV2.SUPERPAYMASTER' $FACT 'SUPERPAYMASTER()(address)')" $SP
check "A3 AOAProtocolRegistry.owner == deployer (pre-M1)" "$(rb 'AOAProtocolRegistry.owner' $AOAREG 'owner()(address)')" $OWNER
check "A3 xPNTsFactoryV2.owner == deployer (pre-M1)" "$(rb 'xPNTsFactoryV2.owner' $FACT 'owner()(address)')" $OWNER
EPI=$(rb 'EP.getDepositInfo(SP)' $EP 'getDepositInfo(address)((uint256,bool,uint112,uint32,uint48))' $SP)
rlog "  5b stake read-back: $EPI"
STALE=$(rb 'SP.priceStalenessThreshold' $SP 'priceStalenessThreshold()(uint256)' | awk '{print $1}')
check "A3 priceStalenessThreshold in [60,86400]" "$(python3 -c "print(60 <= $STALE <= 86400)")" True
attest_runtime A3-v55-stack --target SuperPaymaster=$SPIMPL --target SuperPaymasterAdmin=$SPEXT --target SuperPaymasterLens=$LENS \
  --target GlobalTierSource=$TIER --target AOAProtocolRegistry=$AOAREG --target xPNTsTokenV2Ext=$V2EXT --target xPNTsTokenV2=$V2IMPL \
  --target xPNTsFactoryV2=$FACT --expect-mismatch SuperPaymaster=$OLD_APNTS

step "STAGE I / A4 (runbook 5c): Registry upgradeToAndCall -> Registry-5.9.0 (rc.2 bytecode), EOA path"
fscript_tl UpgradeRegistryD5b $OWNER yes > "$OUT/I-A4-registry.log" 2>&1
RC=$?; grep -E "read-back|BLS|raw slots|5c|Error|revert" "$OUT/I-A4-registry.log" | sed 's/^/    /' | tee -a "$OUT/rehearsal.log" >/dev/null
stop1 A4 $RC
REGIMPL=$(impl_of $REG)
check "A4 Registry.version" "$(rb 'Registry.version' $REG 'version()(string)')" '"Registry-5.9.0"'
check "A4 Registry.owner unchanged" "$(rb 'Registry.owner' $REG 'owner()(address)')" $OWNER
check "A4 Registry.pendingOwner == 0" "$(rb 'Registry.pendingOwner' $REG 'pendingOwner()(address)')" 0x0000000000000000000000000000000000000000
attest_runtime A4-registry --target Registry=$REGIMPL

step "STAGE I / A5 (runbook 7a): each community issues its v2 token (creditPolicy OFF), operators stay paused"
ENV=$ENVNAME V55_OUT_CONFIG=$V55_CFG $LOG "$OUT/I-A5-issue-owner.log" forge script contracts/script/v3/UpgradeToV5_5_0.s.sol:UpgradeToV5_5_0 --sig 'issueCommunityToken(string,string,string,string,uint256)' "AAStar PNTs v2" "aPNTsV2" "AAStar" "aastar.eth" 1000000000000000000 --rpc-url $RPC --unlocked --sender $OWNER --broadcast --slow
stop1 A5-owner $?
OWNER_V2=$(grep -oE "step 7a: v2 token 0x[0-9a-fA-F]{40}" "$OUT/I-A5-issue-owner.log" | awk '{print $NF}')
ENV=$ENVNAME V55_OUT_CONFIG=$V55_CFG $LOG "$OUT/I-A5-issue-anni.log" forge script contracts/script/v3/UpgradeToV5_5_0.s.sol:UpgradeToV5_5_0 --sig 'issueCommunityToken(string,string,string,string,uint256)' "Mycelium PNTs v2" "PNTSV2" "Mycelium" "mycelium.eth" 1000000000000000000 --rpc-url $RPC --unlocked --sender $ANNI --broadcast --slow
stop1 A5-anni $?
ANNI_V2=$(grep -oE "step 7a: v2 token 0x[0-9a-fA-F]{40}" "$OUT/I-A5-issue-anni.log" | awk '{print $NF}')
[ -n "$OWNER_V2" ] && [ -n "$ANNI_V2" ] || { fail "A5 token addresses"; exit 1; }
rlog "  AAStar v2 token = $OWNER_V2 ; Mycelium v2 token = $ANNI_V2"
for t in AAStar:$OWNER_V2 Mycelium:$ANNI_V2; do
  check "A5 ${t%%:*} creditPolicy == OFF(0)" "$(rb "${t%%:*}V2.creditPolicy" ${t#*:} 'creditPolicy()(uint8)')" 0
done
check "A5 factory.getTokenAddress(OWNER)" "$(rb 'factory.getTokenAddress(OWNER)' $FACT 'getTokenAddress(address)(address)' $OWNER)" $OWNER_V2
check "A5 factory.getTokenAddress(ANNI)" "$(rb 'factory.getTokenAddress(ANNI)' $FACT 'getTokenAddress(address)(address)' $ANNI)" $ANNI_V2
attest_runtime A5-tokens --clone AAStarV2=$OWNER_V2:$V2IMPL --clone MyceliumV2=$ANNI_V2:$V2IMPL

step "STAGE I / A6 (runbook 7c): updatePrice (oracle refreshed on the frozen fork) -> configureOperatorV2 -> unpause, both communities"
# refresh_oracle: the fork's clock moved >= 9 days; overwrite ONLY the latest round's timestamp on the
# forked Chainlink aggregator (fork-only cheat; the answer is untouched). See d5b-fork-rehearsal.sh.
refresh_oracle() {
  local agg roundid answer started updated answered_in nowts base found_base found_slot slot val intval expect
  agg=$(cast call "$PRICE_FEED" 'aggregator()(address)' --rpc-url "$RPC")
  read -r roundid answer started updated answered_in <<< "$(cast call "$agg" 'latestRoundData()(uint80,int256,uint256,uint256,uint80)' --rpc-url "$RPC" | tr '\n' ' ' | sed 's/\[[^]]*\]//g')"
  nowts=$(cast block latest --rpc-url "$RPC" --field timestamp)
  expect=$(python3 -c "print(int('$answer') + (int('$updated') << 192))")
  found_base=""
  for base in $(seq 0 80); do
    slot=$(cast keccak "0x$(printf '%064x' "$roundid")$(printf '%064x' "$base")")
    val=$(cast storage "$agg" "$slot" --rpc-url "$RPC" 2>/dev/null)
    intval=$(python3 -c "print(int('$val',16))" 2>/dev/null)
    if [ "$intval" = "$expect" ]; then found_base=$base; found_slot=$slot; break; fi
  done
  [ -n "$found_base" ] || { fail "refresh_oracle: s_transmissions[$roundid] not found"; return 1; }
  cast rpc anvil_setStorageAt "$agg" "$found_slot" "0x$(python3 -c "print(format(int('$answer') + ($nowts << 192), '064x'))")" --rpc-url "$RPC" >/dev/null
  cast rpc evm_mine --rpc-url "$RPC" >/dev/null
  rlog "  refresh_oracle (FORK-ONLY storage write): aggregator=$agg round=$roundid answer=$answer updatedAt $updated -> $nowts (base slot $found_base)"
}
refresh_oracle
sendtx "A6 SP.updatePrice" $OWNER $SP 'updatePrice()' || fail "updatePrice"
check "A6 cachedPrice.updatedAt == updatePrice block ts" "$(rb 'SP.cachedPrice' $SP 'cachedPrice()(int256,uint256,uint80,uint8)' | awk '{print $2}')" "$(cast block $LAST_BLOCK --field timestamp --rpc-url $RPC)"
ENV=$ENVNAME V55_OUT_CONFIG=$V55_CFG $LOG "$OUT/I-A6-configure-owner.log" forge script contracts/script/v3/UpgradeToV5_5_0.s.sol:UpgradeToV5_5_0 --sig 'configureOperatorV2(address,address)' $OWNER_V2 $OWNER --rpc-url $RPC --unlocked --sender $OWNER --broadcast --slow
stop1 A6-configure-owner $?
ENV=$ENVNAME V55_OUT_CONFIG=$V55_CFG $LOG "$OUT/I-A6-configure-anni.log" forge script contracts/script/v3/UpgradeToV5_5_0.s.sol:UpgradeToV5_5_0 --sig 'configureOperatorV2(address,address)' $ANNI_V2 $ANNI --rpc-url $RPC --unlocked --sender $ANNI --broadcast --slow
stop1 A6-configure-anni $?
ENV=$ENVNAME V55_OUT_CONFIG=$V55_CFG $LOG "$OUT/I-A6-unpause-owner.log" forge script contracts/script/v3/UpgradeToV5_5_0.s.sol:UpgradeToV5_5_0 --sig 'unpauseOperator(address)' $OWNER --rpc-url $RPC --unlocked --sender $OWNER --broadcast --slow
stop1 A6-unpause-owner $?
ENV=$ENVNAME V55_OUT_CONFIG=$V55_CFG $LOG "$OUT/I-A6-unpause-anni.log" forge script contracts/script/v3/UpgradeToV5_5_0.s.sol:UpgradeToV5_5_0 --sig 'unpauseOperator(address)' $ANNI --rpc-url $RPC --unlocked --sender $OWNER --broadcast --slow
stop1 A6-unpause-anni $?
for o in AAStar:$OWNER:$OWNER_V2 Mycelium:$ANNI:$ANNI_V2; do
  IFS=: read -r nm op tok <<< "$o"
  OPR=$(rb "SP.operators($nm)" $SP 'operators(address)(uint128,bool,bool,address,uint32,uint48,address,uint256,uint256)' $op)
  check "A6 $nm isConfigured" "$(echo $OPR | awk '{print $2}')" true
  check "A6 $nm isPaused == false" "$(echo $OPR | awk '{print $3}')" false
  check "A6 $nm xPNTsToken == v2" "$(echo $OPR | awk '{print $4}')" $tok
  check "A6 $nm creditPolicy == OFF after unpause" "$(rb "$nm V2.creditPolicy" $tok 'creditPolicy()(uint8)')" 0
done

step "STAGE I / A7 (runbook 7c acceptance): ONE real balance-mode UserOperation through EntryPoint.handleOps PER COMMUNITY (AAStar + Mycelium)"
OWNER_PK="$(envval PRIVATE_KEY)"; ANNI_PK="$(envval PRIVATE_KEY_ANNI)"
[ "$(lc "$(cast wallet address --private-key "$OWNER_PK")")" = "$(lc $OWNER)" ] || { fail "PRIVATE_KEY does not derive OWNER"; exit 1; }
[ "$(lc "$(cast wallet address --private-key "$ANNI_PK")")" = "$(lc $ANNI)" ] || { fail "PRIVATE_KEY_ANNI does not derive ANNI"; exit 1; }
UOE=$(cast keccak 'UserOperationEvent(bytes32,address,address,uint256,bool,uint256,uint256)')
for c in mycelium:$ANNI:$ANNI_V2:ANNI_PK aastar:$OWNER:$OWNER_V2:OWNER_PK; do
  IFS=: read -r nm op tok pkvar <<< "$c"
  jq --arg t "$tok" '.pnts = $t' "$V55_CFG" > "deployments/config.sepolia-fork-$nm.json"
  USER_KEY=$(cast wallet new --json | jq -r '.[0].private_key')
  B0=$(bn)
  # L4GaslessTest's "operator" key is PRIVATE_KEY_ANNI; for AAStar it is the OWNER key (operator = OWNER).
  ENV=sepolia-fork-$nm PRIVATE_KEY="$OWNER_PK" PRIVATE_KEY_ANNI="${!pkvar}" L4_USER_KEY="$USER_KEY" L4_OUT="$W/cache/evidence-a2/l4-$nm.json" \
    $LOG "$OUT/I-A7-l4-$nm.log" forge script contracts/script/v3/L4GaslessTest.s.sol:L4GaslessTest --rpc-url $RPC --broadcast --slow --gas-estimate-multiplier 400
  RC=$?
  grep -E "AA account|burned|lockedOf|decrease|delta|dryRun|Error|revert" "$OUT/I-A7-l4-$nm.log" | sed "s/^/    [$nm] /" | tee -a "$OUT/rehearsal.log" >/dev/null
  [ $RC -eq 0 ] || { fail "A7 $nm L4 run (exit $RC)"; continue; }
  cp "$W/cache/evidence-a2/l4-$nm.json" "$OUT/I-A7-l4-$nm.snapshot.json"
  OPHASH=$(jq -r .opHash "$OUT/I-A7-l4-$nm.snapshot.json"); ACCT=$(jq -r .account "$OUT/I-A7-l4-$nm.snapshot.json")
  cast logs --address $EP --from-block $B0 --to-block latest "$UOE" "$OPHASH" --rpc-url $RPC --json > "$OUT/I-A7-userop-event-$nm.json"
  N=$(jq length "$OUT/I-A7-userop-event-$nm.json")
  check "A7 $nm exactly one UserOperationEvent for userOpHash $OPHASH" "$N" 1
  if [ "$N" = 1 ]; then
    UTX=$(jq -r '.[0].transactionHash' "$OUT/I-A7-userop-event-$nm.json"); UBLK=$(( $(jq -r '.[0].blockNumber' "$OUT/I-A7-userop-event-$nm.json") ))
    DATA=$(jq -r '.[0].data' "$OUT/I-A7-userop-event-$nm.json")
    PM="0x$(jq -r '.[0].topics[3]' "$OUT/I-A7-userop-event-$nm.json" | cut -c27-)"; SENDER="0x$(jq -r '.[0].topics[2]' "$OUT/I-A7-userop-event-$nm.json" | cut -c27-)"
    SUCC=$(( 0x${DATA:66:64} ))
    rlog "  A7 $nm: TxHash=$UTX UserOpHash=$OPHASH block=$UBLK sender=$SENDER paymaster=$PM success=$SUCC operator=$op token=$tok"
    check "A7 $nm UserOperationEvent.success" "$SUCC" 1
    check "A7 $nm paymaster == SP" "$PM" $SP
    check "A7 $nm sender == AA account" "$SENDER" "$ACCT"
    cast receipt "$UTX" --rpc-url $RPC --json | jq -c --arg label "A7 $nm handleOps" '{label:$label} + .' >> "$OUT/receipts.jsonl"
  fi
  ENV=sepolia-fork-$nm L4_OUT="$W/cache/evidence-a2/l4-$nm.json" $LOG "$OUT/I-A7-l4-$nm-verify.log" forge script contracts/script/v3/L4GaslessTest.s.sol:L4GaslessTest --sig 'verify()' --rpc-url $RPC
  [ $? -eq 0 ] && grep -q "L4 verify: settlement read back from chain state OK" "$OUT/I-A7-l4-$nm-verify.log" && rlog "  CHECK [A7 $nm L4 verify() from chain state @block $(bn)] PASS" || fail "A7 $nm L4 verify()"
  check "A7 $nm creditPolicy still OFF" "$(rb "$nm V2.creditPolicy" $tok 'creditPolicy()(uint8)')" 0
done
unset OWNER_PK ANNI_PK USER_KEY
fi # stage I

if stage_on II; then
step "STAGE II / M1 ① (EOA): SP + Registry transferOwnership(canonical TL) [two-step]; AOAProtocolRegistry + xPNTsFactoryV2 transferOwnership(canonical TL) [single-step OZ Ownable]"
roles_check before-M1
sendtx "M1① SP.transferOwnership(TL)" $OWNER $SP 'transferOwnership(address)' $TL || exit 1
sendtx "M1① Registry.transferOwnership(TL)" $OWNER $REG 'transferOwnership(address)' $TL || exit 1
SP_PEND=$(rb 'SP.pendingOwner' $SP 'pendingOwner()(address)'); REG_PEND=$(rb 'Registry.pendingOwner' $REG 'pendingOwner()(address)')
check "M1① SP.pendingOwner == TL" "$SP_PEND" $TL
check "M1① Registry.pendingOwner == TL" "$REG_PEND" $TL
check "M1① SP.owner still deployer" "$(rb 'SP.owner' $SP 'owner()(address)')" $OWNER
# single-step transfers: no accept, no natural abort point -> "address checked twice": the target must be
# byte-identical to what SP and Registry recorded as pendingOwner, and must be the timelock with the M1 roles.
check "M1 address double-check 1: TL == SP.pendingOwner" "$TL" "$SP_PEND"
check "M1 address double-check 2: TL == Registry.pendingOwner" "$TL" "$REG_PEND"
check "M1 address double-check 3: TL minDelay" "$(rb 'TL.getMinDelay' $TL 'getMinDelay()(uint256)')" 172800
sendtx "M1 AOAProtocolRegistry.transferOwnership(TL)" $OWNER $AOAREG 'transferOwnership(address)' $TL || exit 1
check "M1 AOAProtocolRegistry.owner == TL" "$(rb 'AOAProtocolRegistry.owner' $AOAREG 'owner()(address)')" $TL
sendtx "M1 xPNTsFactoryV2.transferOwnership(TL)" $OWNER $FACT 'transferOwnership(address)' $TL || exit 1
check "M1 xPNTsFactoryV2.owner == TL" "$(rb 'xPNTsFactoryV2.owner' $FACT 'owner()(address)')" $TL
must_fail "M1: deployer EOA AOAProtocolRegistry.revokeApproval after transfer" cast send $AOAREG 'revokeApproval(uint8,bytes32)' 0 $ZERO32 --unlocked --from $OWNER --rpc-url $RPC
must_fail "M1: deployer EOA xPNTsFactoryV2.setSuperPaymasterAddress after transfer" cast send $FACT 'setSuperPaymasterAddress(address)' $SP --unlocked --from $OWNER --rpc-url $RPC

step "STAGE II / M1 negative: a MISCONFIGURED timelock cannot accept (wrong timelock: minDelay 0, deployer as proposer/executor)"
BADARGS="$(cast abi-encode 'c(uint256,address[],address[],address)' 0 "[$OWNER]" "[$OWNER]" 0x0000000000000000000000000000000000000000)"
sendtx "M1-neg deploy misconfigured timelock" $OWNER --create "$TLBC${BADARGS#0x}" || true
BADTL=$(cast receipt "$LAST_TX" contractAddress --rpc-url $RPC)
rlog "  misconfigured timelock $BADTL (minDelay $(rb 'BADTL.getMinDelay' $BADTL 'getMinDelay()(uint256)'))"
sendtx "M1-neg BADTL.schedule(SP.acceptOwnership)" $OWNER $BADTL 'schedule(address,uint256,bytes,bytes32,bytes32,uint256)' $SP 0 $ACC $ZERO32 $ZERO32 0 || true
must_fail "M1: misconfigured timelock executes SP.acceptOwnership (pendingOwner is the canonical TL)" cast send $BADTL 'execute(address,uint256,bytes,bytes32,bytes32)' $SP 0 $ACC $ZERO32 $ZERO32 --unlocked --from $OWNER --rpc-url $RPC
check "M1-neg SP.owner unchanged" "$(rb 'SP.owner' $SP 'owner()(address)')" $OWNER

step "STAGE II / M1 ② : Safe -> TL.scheduleBatch[SP.acceptOwnership, Registry.acceptOwnership, SP.setGuardian(Safe)] (calldata printed by UpgradeViaTimelock after its operator preflight)"
must_fail "M1: UpgradeViaTimelock schedule-accept WITHOUT a roles attestation" fscript_tl UpgradeViaTimelock $SAFE_O1 no TL_MODE=schedule-accept TL_SALT=$(cast keccak a2/M1)
roles_check before-M1-schedule
fscript_tl UpgradeViaTimelock $SAFE_O1 no TL_MODE=schedule-accept TL_SALT=$(cast keccak a2/M1) TL_ROLES_ATTESTATION="$ATT" > "$OUT/II-M1-schedule-print.log" 2>&1 || fail "M1 schedule-accept print"
M1_SCHED=$(payload_after "$OUT/II-M1-schedule-print.log" "submit this scheduleBatch from the Safe")
[ -n "$M1_SCHED" ] || { fail "M1: no scheduleBatch calldata printed"; exit 1; }
grep -E "roles attestation|preflight" "$OUT/II-M1-schedule-print.log" | sed 's/^/    /' | tee -a "$OUT/rehearsal.log" >/dev/null
# independent re-derivation of the batch (it must equal what the script printed)
M1_T="[$SP,$REG,$SP]"; M1_V="[0,0,0]"; M1_P="[$ACC,$ACC,$(cast calldata 'setGuardian(address)' $SAFE)]"
M1_EXPECT=$(cast calldata 'scheduleBatch(address[],uint256[],bytes[],bytes32,bytes32,uint256)' "$M1_T" "$M1_V" "$M1_P" $ZERO32 $(cast keccak a2/M1) 172800)
check "M1 printed scheduleBatch calldata == independently encoded" "$M1_SCHED" "$M1_EXPECT"
M1_ID=$(cast call $TL 'hashOperationBatch(address[],uint256[],bytes[],bytes32,bytes32)(bytes32)' "$M1_T" "$M1_V" "$M1_P" $ZERO32 $(cast keccak a2/M1) --rpc-url $RPC)
must_fail "M1: deployer EOA scheduleBatch directly (not PROPOSER)" cast send $TL "$M1_SCHED" --unlocked --from $OWNER --rpc-url $RPC
safe_exec "M1② scheduleBatch" $TL "$M1_SCHED" || { fail "M1 schedule"; exit 1; }
check "M1② batch pending" "$(rb 'TL.isOperationPending(M1)' $TL 'isOperationPending(bytes32)(bool)' $M1_ID)" true
M1_EXEC=$(cast calldata 'executeBatch(address[],uint256[],bytes[],bytes32,bytes32)' "$M1_T" "$M1_V" "$M1_P" $ZERO32 $(cast keccak a2/M1))
safe_exec_must_fail "M1: Safe executeBatch BEFORE 48h" $TL "$M1_EXEC"
warp 172800
must_fail "M1: non-multisig (deployer EOA) executeBatch after 48h (not EXECUTOR)" cast send $TL "$M1_EXEC" --unlocked --from $OWNER --rpc-url $RPC
must_fail "M1: non-multisig (Safe owner EOA directly) executeBatch after 48h" cast send $TL "$M1_EXEC" --unlocked --from $SAFE_O2 --rpc-url $RPC
roles_check before-M1-execute
fscript_tl UpgradeViaTimelock $SAFE_O1 no TL_MODE=execute-accept TL_SALT=$(cast keccak a2/M1) TL_ROLES_ATTESTATION="$ATT" > "$OUT/II-M1-execute-print.log" 2>&1 || fail "M1 execute-accept print"
check "M1 printed executeBatch calldata == independently encoded" "$(payload_after "$OUT/II-M1-execute-print.log" "submit this executeBatch from the Safe")" "$M1_EXEC"
safe_exec "M1② executeBatch" $TL "$M1_EXEC" || { fail "M1 execute"; exit 1; }
check "M1 batch done" "$(rb 'TL.isOperationDone(M1)' $TL 'isOperationDone(bytes32)(bool)' $M1_ID)" true
check "M1 SP.owner == TL" "$(rb 'SP.owner' $SP 'owner()(address)')" $TL
check "M1 SP.pendingOwner == 0" "$(rb 'SP.pendingOwner' $SP 'pendingOwner()(address)')" 0x0000000000000000000000000000000000000000
check "M1 Registry.owner == TL" "$(rb 'Registry.owner' $REG 'owner()(address)')" $TL
check "M1 Registry.pendingOwner == 0" "$(rb 'Registry.pendingOwner' $REG 'pendingOwner()(address)')" 0x0000000000000000000000000000000000000000
check "M1/M2 SP.guardian == Safe" "$(rb 'SP.guardian' $SP 'guardian()(address)')" $SAFE
check "M1 AOAProtocolRegistry.owner == TL" "$(rb 'AOAProtocolRegistry.owner' $AOAREG 'owner()(address)')" $TL
check "M1 xPNTsFactoryV2.owner == TL" "$(rb 'xPNTsFactoryV2.owner' $FACT 'owner()(address)')" $TL
check "M1 APNTsCapped.owner == TL" "$(rb 'APNTsCapped.owner' $CAPPED 'owner()(address)')" $TL
check "M1 TL.getMinDelay" "$(rb 'TL.getMinDelay' $TL 'getMinDelay()(uint256)')" 172800
check "M1 executor not open (hasRole(EXECUTOR, 0))" "$(rb 'TL.hasRole(EXECUTOR,0)' $TL 'hasRole(bytes32,address)(bool)' $EXECUTOR_ROLE 0x0000000000000000000000000000000000000000)" false
roles_check after-M1
role_events_dump after-M1
must_fail "M1: old EOA owner SP.upgradeToAndCall after M1" cast send $SP 'upgradeToAndCall(address,bytes)' $SPIMPL 0x --unlocked --from $OWNER --rpc-url $RPC
must_fail "M1: old EOA owner Registry.upgradeToAndCall after M1" cast send $REG 'upgradeToAndCall(address,bytes)' $REGIMPL 0x --unlocked --from $OWNER --rpc-url $RPC

step "STAGE II / C (§10.7b C): timelock-aware upgrade drill, SP then Registry (re-deploys the SAME rc.2 bytecode: no rc1' dummy-bump impl exists; see README)"
for T in SP REGISTRY; do
  PROXY=$([ $T = SP ] && echo $SP || echo $REG); NEND=$([ $T = SP ] && echo 65 || echo 74)
  fscript_tl UpgradeViaTimelock $OWNER yes TL_MODE=deploy-impl TL_TARGET=$T > "$OUT/II-C-$T-deploy.log" 2>&1 || fail "C $T deploy-impl"
  NI=$(grep -oE "pass as TL_NEW_IMPL\): 0x[0-9a-fA-F]{40}" "$OUT/II-C-$T-deploy.log" | awk '{print $NF}')
  [ -n "$NI" ] || { fail "C $T: no new impl"; continue; }
  rlog "  $T new impl $NI"
  attest_runtime "C-$T-impl" --target $([ $T = SP ] && echo SuperPaymaster || echo Registry)=$NI
  SALT=$(cast keccak "a2/C/$T")
  must_fail "C $T: schedule-upgrade WITHOUT a roles attestation" fscript_tl UpgradeViaTimelock $SAFE_O1 no TL_MODE=schedule-upgrade TL_TARGET=$T TL_NEW_IMPL=$NI TL_SALT=$SALT
  roles_check "before-C-$T-schedule"
  fscript_tl UpgradeViaTimelock $SAFE_O1 no TL_MODE=schedule-upgrade TL_TARGET=$T TL_NEW_IMPL=$NI TL_SALT=$SALT TL_ROLES_ATTESTATION="$ATT" > "$OUT/II-C-$T-schedule-print.log" 2>&1 || fail "C $T schedule print"
  UPD=$(cast calldata 'upgradeToAndCall(address,bytes)' $NI 0x)
  SCHED=$(payload_after "$OUT/II-C-$T-schedule-print.log" "submit this from the Safe")
  check "C $T printed schedule calldata == independently encoded" "$SCHED" "$(tl_schedule_data $PROXY $UPD $SALT)"
  safe_exec "C $T schedule(upgradeToAndCall)" $TL "$SCHED" || continue
  CID=$(tl_id $PROXY $UPD $SALT)
  check "C $T op pending" "$(rb "TL.isOperationPending(C-$T)" $TL 'isOperationPending(bytes32)(bool)' $CID)" true
  safe_exec_must_fail "C $T: Safe execute BEFORE 48h" $TL "$(tl_execute_data $PROXY $UPD $SALT)"
  warp 172800
  roles_check "before-C-$T-execute"
  fscript_tl UpgradeViaTimelock $SAFE_O1 no TL_MODE=execute-upgrade TL_TARGET=$T TL_NEW_IMPL=$NI TL_SALT=$SALT TL_ROLES_ATTESTATION="$ATT" > "$OUT/II-C-$T-execute-print.log" 2>&1 || fail "C $T execute print"
  check "C $T printed execute calldata == independently encoded" "$(payload_after "$OUT/II-C-$T-execute-print.log" "submit this from the Safe")" "$(tl_execute_data $PROXY $UPD $SALT)"
  # pre-execute snapshot for the read-backs the forge script cannot do on the Safe path
  OWN0=$(cast call $PROXY 'owner()(address)' --rpc-url $RPC); B_SP=$(cast call $SP 'BLS_AGGREGATOR()(address)' --rpc-url $RPC); B_REG=$(cast call $REG 'blsAggregator()(address)' --rpc-url $RPC)
  SB=$(bn); for i in $(seq 0 $((NEND-1))); do cast storage $PROXY $i --rpc-url $RPC --block $SB; done > "$OUT/II-C-$T-slots-before.txt"
  safe_exec "C $T execute(upgradeToAndCall)" $TL "$(tl_execute_data $PROXY $UPD $SALT)" || continue
  SA=$(bn); for i in $(seq 0 $((NEND-1))); do cast storage $PROXY $i --rpc-url $RPC --block $SA; done > "$OUT/II-C-$T-slots-after.txt"
  check "C $T op done" "$(rb "TL.isOperationDone(C-$T)" $TL 'isOperationDone(bytes32)(bool)' $CID)" true
  check "C $T ERC-1967 impl slot == new impl" "$(impl_of $PROXY)" "$NI"
  check "C $T version" "$(rb "$T.version" $PROXY 'version()(string)')" "$([ $T = SP ] && echo '"SuperPaymaster-5.5.0"' || echo '"Registry-5.9.0"')"
  check "C $T owner == TL (unchanged)" "$(rb "$T.owner" $PROXY 'owner()(address)')" "$OWN0"
  check "C $T pendingOwner == 0" "$(rb "$T.pendingOwner" $PROXY 'pendingOwner()(address)')" 0x0000000000000000000000000000000000000000
  check "C $T BLS leg SP" "$(rb 'SP.BLS_AGGREGATOR' $SP 'BLS_AGGREGATOR()(address)')" "$B_SP"
  check "C $T BLS leg Registry" "$(rb 'Registry.blsAggregator' $REG 'blsAggregator()(address)')" "$B_REG"
  check "C $T raw slots 0..$((NEND-1)) byte-identical across execute (blocks $SB -> $SA)" "$(shasum -a 256 < "$OUT/II-C-$T-slots-after.txt" | awk '{print $1}')" "$(shasum -a 256 < "$OUT/II-C-$T-slots-before.txt" | awk '{print $1}')"
done

step "STAGE II / M2 (GOV-2): guardian (= Safe) pauses via Safe.execTransaction; validate -> sigFail; guardian cannot unpause / upgrade / move funds; timelock unpauses"
DUMMY_OP="($SP,0,0x,0x,$ZERO32,0,$ZERO32,0x,0x)"
probe_validate() { cast call $SP 'validatePaymasterUserOp((address,uint256,bytes,bytes,bytes32,uint256,bytes32,bytes,bytes),bytes32,uint256)(bytes,uint256)' "$DUMMY_OP" $ZERO32 1 --from $EP --rpc-url $RPC --block "$(bn)" 2>&1 | tr '\n' ' ' | head -c 300; }
rlog "  probe validatePaymasterUserOp(dummy op) BEFORE pause @block $(bn): $(probe_validate)"
safe_exec "M2 guardian setGlobalPaused(true)" $SP "$(cast calldata 'setGlobalPaused(bool)' true)" || fail "M2 pause"
check "M2 paused() == true" "$(rb 'SP.paused' $SP 'paused()(bool)')" true
VP=$(probe_validate); rlog "  probe validatePaymasterUserOp(dummy op) WHILE paused @block $(bn): $VP"
check "M2 validate returns SIG_VALIDATION_FAILED (validationData == 1) while paused" "$(echo "$VP" | awk '{print $NF}')" 1
safe_exec_must_fail "M2: guardian (Safe) unpause setGlobalPaused(false)" $SP "$(cast calldata 'setGlobalPaused(bool)' false)"
safe_exec_must_fail "M2: guardian (Safe) SP.upgradeToAndCall" $SP "$(cast calldata 'upgradeToAndCall(address,bytes)' $SPIMPL 0x)"
safe_exec_must_fail "M2: guardian (Safe) SP.withdrawProtocolRevenue (move funds)" $SP "$(cast calldata 'withdrawProtocolRevenue(address,uint256)' $SAFE 1)"
safe_exec_must_fail "M2: guardian (Safe) unpause an operator setOperatorPaused(OWNER,false)" $SP "$(cast calldata 'setOperatorPaused(address,bool)' $OWNER false)"
must_fail "M2: old EOA unpause" cast send $SP 'setGlobalPaused(bool)' false --unlocked --from $OWNER --rpc-url $RPC
UNP=$(cast calldata 'setGlobalPaused(bool)' false); USALT=$(cast keccak a2/M2/unpause)
roles_check before-M2-schedule
fscript_tl UpgradeViaTimelock $SAFE_O1 no TL_MODE=schedule-call TL_TARGET=SP TL_CALLDATA=$UNP TL_SALT=$USALT TL_ROLES_ATTESTATION="$ATT" > "$OUT/II-M2-schedule-print.log" 2>&1 || fail "M2 schedule print"
check "M2 printed schedule calldata == independently encoded" "$(payload_after "$OUT/II-M2-schedule-print.log" "submit this from the Safe")" "$(tl_schedule_data $SP $UNP $USALT)"
safe_exec "M2 schedule(unpause)" $TL "$(tl_schedule_data $SP $UNP $USALT)" || fail "M2 schedule"
safe_exec_must_fail "M2: Safe execute(unpause) BEFORE 48h" $TL "$(tl_execute_data $SP $UNP $USALT)"
warp 172800
safe_exec "M2 execute(unpause)" $TL "$(tl_execute_data $SP $UNP $USALT)" || fail "M2 execute"
check "M2 paused() == false after the timelock's unpause" "$(rb 'SP.paused' $SP 'paused()(bool)')" false
rlog "  probe validatePaymasterUserOp(dummy op) AFTER unpause @block $(bn): $(probe_validate)"

step "STAGE II / M3 (GOV-3): setAPNTSPrice only via the timelock"
P0=$(rb 'SP.aPNTsPriceUSD' $SP 'aPNTsPriceUSD()(uint256)' | awk '{print $1}')
P1=$(python3 -c "print($P0 * 105 // 100)")
rlog "  aPNTsPriceUSD $P0 -> $P1 (+5%, inside the ±10% per-update band)"
must_fail "M3: old EOA setAPNTSPrice" cast send $SP 'setAPNTSPrice(uint256)' $P1 --unlocked --from $OWNER --rpc-url $RPC
safe_exec_must_fail "M3: Safe (guardian, not owner) setAPNTSPrice directly" $SP "$(cast calldata 'setAPNTSPrice(uint256)' $P1)"
SETP=$(cast calldata 'setAPNTSPrice(uint256)' $P1); PSALT=$(cast keccak a2/M3/setAPNTSPrice)
roles_check before-M3-schedule
fscript_tl UpgradeViaTimelock $SAFE_O1 no TL_MODE=schedule-call TL_TARGET=SP TL_CALLDATA=$SETP TL_SALT=$PSALT TL_ROLES_ATTESTATION="$ATT" > "$OUT/II-M3-schedule-print.log" 2>&1 || fail "M3 schedule print"
check "M3 printed schedule calldata == independently encoded" "$(payload_after "$OUT/II-M3-schedule-print.log" "submit this from the Safe")" "$(tl_schedule_data $SP $SETP $PSALT)"
safe_exec "M3 schedule(setAPNTSPrice)" $TL "$(tl_schedule_data $SP $SETP $PSALT)" || fail "M3 schedule"
PID=$(tl_id $SP $SETP $PSALT)
check "M3 op pending" "$(rb 'TL.isOperationPending(M3)' $TL 'isOperationPending(bytes32)(bool)' $PID)" true
safe_exec_must_fail "M3: Safe execute(setAPNTSPrice) BEFORE 48h (early execute)" $TL "$(tl_execute_data $SP $SETP $PSALT)"
check "M3 price unchanged after the early execute" "$(rb 'SP.aPNTsPriceUSD' $SP 'aPNTsPriceUSD()(uint256)' | awk '{print $1}')" $P0
warp 172800
must_fail "M3: deployer EOA execute after 48h (not EXECUTOR)" cast send $TL 'execute(address,uint256,bytes,bytes32,bytes32)' $SP 0 $SETP $ZERO32 $PSALT --unlocked --from $OWNER --rpc-url $RPC
roles_check before-M3-execute
fscript_tl UpgradeViaTimelock $SAFE_O1 no TL_MODE=execute-call TL_TARGET=SP TL_CALLDATA=$SETP TL_SALT=$PSALT TL_ROLES_ATTESTATION="$ATT" > "$OUT/II-M3-execute-print.log" 2>&1 || fail "M3 execute print"
check "M3 printed execute calldata == independently encoded" "$(payload_after "$OUT/II-M3-execute-print.log" "submit this from the Safe")" "$(tl_execute_data $SP $SETP $PSALT)"
safe_exec "M3 execute(setAPNTSPrice)" $TL "$(tl_execute_data $SP $SETP $PSALT)" || fail "M3 execute"
check "M3 op done" "$(rb 'TL.isOperationDone(M3)' $TL 'isOperationDone(bytes32)(bool)' $PID)" true
check "M3 aPNTsPriceUSD == new price" "$(rb 'SP.aPNTsPriceUSD' $SP 'aPNTsPriceUSD()(uint256)' | awk '{print $1}')" $P1
fi # stage II

step "final state"
if stage_on II; then
  roles_check final
  role_events_dump final
  jq -n --arg tl "$TL" --arg dep "$TL_DEPLOY_BLOCK" --slurpfile ev "$OUT/role-events-final.json" --arg safe "$SAFE" '
    def holders(r): [$ev[0].events | sort_by(.blockNumber, .logIndex)[] | select(.role==r)]
      | reduce .[] as $e ({}; if $e.event=="RoleGranted" then .[$e.account]=true else del(.[$e.account]) end) | keys;
    {timelock:$tl, deploymentBlock:($dep|tonumber), headBlock:$ev[0].headBlock, source:"RoleGranted/RoleRevoked replay (role-events-final.json); cross-checked by check-timelock-roles.mjs (roles-final.json)",
     DEFAULT_ADMIN_ROLE:holders("0x0000000000000000000000000000000000000000000000000000000000000000"),
     PROPOSER_ROLE:holders("'"$PROPOSER_ROLE"'"), CANCELLER_ROLE:holders("'"$CANCELLER_ROLE"'"), EXECUTOR_ROLE:holders("'"$EXECUTOR_ROLE"'")}' > "$OUT/role-manifest-final.json"
  rlog "  role manifest (final, replayed): $(jq -c '{DEFAULT_ADMIN_ROLE,PROPOSER_ROLE,CANCELLER_ROLE,EXECUTOR_ROLE}' "$OUT/role-manifest-final.json")"
  check "final exact ADMIN set == [TL]" "$(jq -c .DEFAULT_ADMIN_ROLE "$OUT/role-manifest-final.json")" "[\"$(lc $TL)\"]"
  for r in PROPOSER CANCELLER EXECUTOR; do check "final exact $r set == [Safe]" "$(jq -c .${r}_ROLE "$OUT/role-manifest-final.json")" "[\"$(lc $SAFE)\"]"; done
  attest_runtime final --target SuperPaymaster=$(impl_of $SP) --target SuperPaymasterAdmin=$(cast call $SP 'EXTENSION()(address)' --rpc-url $RPC) --target Registry=$(impl_of $REG) \
    --target SuperPaymasterLens=$LENS --target GlobalTierSource=$TIER --target AOAProtocolRegistry=$AOAREG --target xPNTsTokenV2Ext=$V2EXT \
    --target xPNTsTokenV2=$V2IMPL --target xPNTsFactoryV2=$FACT --target APNTsCapped=$CAPPED \
    --clone AAStarV2=$OWNER_V2:$V2IMPL --clone MyceliumV2=$ANNI_V2:$V2IMPL --expect-mismatch Registry=$(impl_of $SP)
fi
rlog "  SP owner=$(cast call $SP 'owner()(address)' --rpc-url $RPC) guardian=$(cast call $SP 'guardian()(address)' --rpc-url $RPC) impl=$(impl_of $SP) version=$(cast call $SP 'version()(string)' --rpc-url $RPC) @block $(bn)"
rlog "  Registry owner=$(cast call $REG 'owner()(address)' --rpc-url $RPC) impl=$(impl_of $REG) version=$(cast call $REG 'version()(string)' --rpc-url $RPC) @block $(bn)"
rlog "  negative controls executed: $NEG_N (all reverted; neg-controls.jsonl)"
rlog "  CHECK lines: $(grep -c 'CHECK \[.*\] PASS' "$OUT/rehearsal.log") PASS, $(grep -c 'CHECK \[.*\] FAIL' "$OUT/rehearsal.log") FAIL; !!! lines: $(grep -c '!!!' "$OUT/rehearsal.log")"
if [ "$FAILURES" -eq 0 ]; then rlog "RUN COMPLETED WITH 0 FAILURES ($STAGE) — this line is a tally, not evidence; see the per-step CHECK / TX / readback lines above"
else rlog "RUN FAILED ($STAGE): $FAILURES failure(s), see the !!! lines"; exit 1; fi
