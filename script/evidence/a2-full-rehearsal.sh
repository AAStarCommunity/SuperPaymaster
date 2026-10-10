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
#   stage: all (default) | comma list of 0,I,II,D   (D = rc1 gate item 4: real changed-runtime upgrade
#          to the TEST-ONLY dummy bump contracts/test/upgrade-drill/ + rollback; needs I and II in the same run)
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
  rm -f "$W/deployments/config.sepolia-fork-mycelium.json" "$W/deployments/config.sepolia-fork-aastar.json"
  rm -f "$OUT/.sendtx.err" "$OUT/.neg.tmp"
}
trap cleanup EXIT

PORT="${A2_PORT:-28613}"; RPC="http://127.0.0.1:$PORT"
rlog() { echo "$*" | tee -a "$OUT/rehearsal.log"; }
step() { echo; echo "=== $* ===" | tee -a "$OUT/rehearsal.log"; }
lc() { echo "$1" | tr 'A-F' 'a-f'; }
# fail(): also callable from inside $(...) (a subshell): the "!!!" line it writes to rehearsal.log is what the
# final verdict counts (FAILURES alone would lose increments made in subshells). Callers inside $(...) send it
# to stderr (fail ... >&2) so the message never becomes part of a captured value.
fail() { rlog "  !!! $*"; FAILURES=$((FAILURES+1)); }
# ---- fail-closed reads (DSR CC-125 466d42d1 ①) ------------------------------------------------------------
# rtype <type> <value>: 0 iff <value> is a well-formed rendering of <type>. Types: address, bytes32 / word /
# hash (32 bytes), uint* / blocknum, int*, bool, string (cast prints it quoted, must be non-empty), address[];
# anything else (tuples, multi-returns) must at least be non-empty and contain no "Error".
rtype() {
  case "$1" in
    address) [[ "$2" =~ ^0x[0-9a-fA-F]{40}$ ]] ;;
    bytes32|word|hash) [[ "$2" =~ ^0x[0-9a-fA-F]{64}$ ]] ;;
    uint*|blocknum) [[ "$2" =~ ^[0-9]+$ ]] ;;
    int*) [[ "$2" =~ ^-?[0-9]+$ ]] ;;
    bool) [ "$2" = true ] || [ "$2" = false ] ;;
    string) [[ "$2" =~ ^\".+\"$ ]] ;;
    code) [[ "$2" =~ ^0x([0-9a-fA-F]{2})+$ ]] ;;
    'address[]') [[ "$2" =~ ^\[(0x[0-9a-fA-F]{40}(,\ 0x[0-9a-fA-F]{40})*)?\]$ ]] ;;
    *) [ -n "$2" ] && ! [[ "$2" =~ [Ee]rror ]] ;;
  esac
}
# rtype_of_sig '<fn>(<args>)(<ret>)': the single return type, or "other" (tuple / multi-return)
rtype_of_sig() { local r="${1#*)(}"; r="${r%)}"; [[ "$r" =~ ^[a-z0-9]+(\[\])?$ ]] && echo "$r" || echo other; }
# rv <type> <label> <filter|-> <command...>: run a read command, apply an optional filter (one shell pipeline
# stage, e.g. 'sed -n 4p'), strip cast's "[1e18]" hints, and require exit 0 AND a well-formed <type> value.
# On failure: a "!!! READ FAILED" line (counted by the final verdict), the sentinel READ-FAILED, return 1.
rv() {
  local ty="$1" label="$2" flt="$3" v rc; shift 3
  v=$("$@" 2>"$OUT/.rv.err"); rc=$?
  if [ $rc -eq 0 ] && [ "$flt" != - ]; then v=$(printf '%s\n' "$v" | eval "$flt"); rc=$?; fi
  v=$(printf '%s' "$v" | sed -E 's/ \[-?[0-9.e+-]+\]//g')
  if [ $rc -ne 0 ] || ! rtype "$ty" "$v"; then
    fail "READ FAILED [$label] (expected $ty): exit $rc, value '${v:0:90}' $(head -c 200 "$OUT/.rv.err" | tr '\n' ' ')" >&2
    echo READ-FAILED; return 1
  fi
  printf '%s\n' "$v"
}
bn_raw() { cast block-number --rpc-url "$RPC"; }   # unchecked: ONLY for code that checks the result itself
bn() { rv blocknum "block-number" - cast block-number --rpc-url "$RPC"; }
# rb <label> <cast call args...>: read at an explicit block, log "readback [label] = v @block N", print v.
# Fail-closed: the exit status is checked and the value must match the signature's return type.
rb() {
  local label="$1"; shift
  local b v rc ty; b=$(bn) || { echo READ-FAILED; return 1; }
  ty=$(rtype_of_sig "$2")
  v=$(cast call "$@" --rpc-url "$RPC" --block "$b" 2>"$OUT/.rb.err" | tr '\n' ' ' | sed -E 's/ +$//; s/ \[-?[0-9.e+-]+\]//g'); rc=$?
  if [ $rc -ne 0 ] || ! rtype "$ty" "$v"; then
    fail "READ FAILED [readback $label] (expected $ty): exit $rc, value '${v:0:90}' $(head -c 200 "$OUT/.rb.err" | tr '\n' ' ') @block $b" >&2
    echo READ-FAILED; return 1
  fi
  echo "  readback [$label] = $v @block $b" | tee -a "$OUT/rehearsal.log" >&2
  echo "$v"
}
# rbs <label> <address> <slot>: raw storage read-back (must be a 32-byte word)
rbs() {
  local label="$1" b v; b=$(bn) || { echo READ-FAILED; return 1; }
  v=$(rv word "storage $label" - cast storage "$2" "$3" --rpc-url "$RPC" --block "$b") || { echo READ-FAILED; return 1; }
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
# must_fail <what> <expect> <cmd...>: negative control. PASSES only if the command fails AND the failure is
# the expected one:
#   * <expect> starting with 0x = the EXACT ABI-encoded revert data (selector + arguments, see errdata). The
#     first `data: "0x..."` field of the cast output must be byte-identical to it: a revert with another
#     selector, the same selector with other arguments, or no revert data at all is a FAILURE;
#   * otherwise <expect> is a regex over the output; used only for the OFF-CHAIN guard of the forge script
#     (UpgradeViaTimelock refusing to run without a roles attestation), which sends nothing.
# Any other failure (wrong revert, bash/tooling error, unbound variable, ...) is counted as a FAILURE, not a
# pass, and the run ends "RUN FAILED". The full output goes to neg.log with the head block before/after (a
# revert sends no tx); every control is also one row of neg-controls.jsonl (expected vs actual).
NEG_N=0
must_fail() {
  local what="$1" expect="$2"; shift 2
  local b0 b1 rc actual ok=0 mode; b0=$(bn)
  "$@" >"$OUT/.neg.tmp" 2>&1; rc=$?
  b1=$(bn)
  NEG_N=$((NEG_N+1))
  { echo "### NEG-$NEG_N [$what] expect=$expect head block before=$b0 after=$b1 exit=$rc"; sed -E 's#https?://[^ ]*(alchemy|infura)[^ ]*#<redacted-rpc>#g' "$OUT/.neg.tmp"; echo; } >> "$OUT/neg.log"
  if [ $rc -eq 0 ]; then
    rlog "NEGATIVE CONTROL FAILED: NEG-$NEG_N [$what] succeeded @block $b1"; FAILURES=$((FAILURES+1)); exit 1
  fi
  if [ "${expect:0:2}" = "0x" ]; then
    mode=exact-revert-data
    actual=$(grep -oE 'data: "0x[0-9a-fA-F]*"' "$OUT/.neg.tmp" | head -1 | sed -E 's/^data: "//; s/"$//' | tr 'A-F' 'a-f')
    [ -n "$actual" ] && [ "$actual" = "$(lc "$expect")" ] && ok=1
  else
    mode=regex
    actual=$(grep -oE "$expect" "$OUT/.neg.tmp" | head -1)
    [ -n "$actual" ] && ok=1
  fi
  jq -nc --arg id "NEG-$NEG_N" --arg what "$what" --arg b "$b0" --arg mode "$mode" --arg expect "$expect" --arg actual "${actual:-<none>}" --arg ok "$ok" \
    '{id:$id,what:$what,headBlock:($b|tonumber),mode:$mode,expected:$expect,actual:$actual,result:(if $ok=="1" then "PASS" else "FAIL" end)}' >> "$OUT/neg-controls.jsonl"
  if [ $ok -ne 1 ]; then
    fail "NEGATIVE CONTROL NEG-$NEG_N [$what] failed for an UNEXPECTED reason: expected ($mode) '$expect', actual '${actual:-<none>}' ($(grep -m1 -iE 'error|revert' "$OUT/.neg.tmp" | head -c 300))"
    return 1
  fi
  rlog "  negative ok NEG-$NEG_N [$what]: reverted @block $b0 (head after $b1); $mode expected == actual '$actual'"
}
# errdata <error signature> [args...]: the exact ABI-encoded revert data (lowercase) of a custom error or of
# Error(string), e.g. errdata 'OwnableUnauthorizedAccount(address)' 0x... -> 0x118cdaa7000...
errdata() { local sig="$1"; shift; lc "$(cast calldata "$sig" "$@")"; }
# Expected errors, each verified against the rc.2 source (and, for the pre-upgrade A1e call, the live 5.4.2
# source at tag v5.4.2): see the negative-control table in the archive README.
E_OWNABLE='OwnableUnauthorizedAccount(address)'               # 0x118cdaa7 OZ v5.0.2 Ownable.onlyOwner / Ownable2StepNamespaced.acceptOwnership
E_ACL='AccessControlUnauthorizedAccount(address,bytes32)'     # 0xe2517d3f OZ TimelockController onlyRole / onlyRoleOrOpenRole
E_TLSTATE='TimelockUnexpectedOperationState(bytes32,bytes32)' # 0x5ead8eb5 OZ TimelockController._beforeCall (not Ready)
READY_BITMAP=0x0000000000000000000000000000000000000000000000000000000000000004  # _encodeStateBitmap(Ready) = 1 << 2
E_INVALID_CFG=$(cast sig 'InvalidConfiguration()')            # 0xc52a9bd3 SuperPaymaster(Admin) InvalidConfiguration()
E_UNAUTH=$(cast sig 'Unauthorized()')                         # 0x82b42900 SuperPaymasterAdmin._requirePauseAuthority
warp() { cast rpc evm_increaseTime "$1" --rpc-url "$RPC" >/dev/null; cast rpc evm_mine --rpc-url "$RPC" >/dev/null; rlog "  warp +$1 s -> block $(bn) ts $(rv uint "latest block timestamp" - cast block latest --field timestamp --rpc-url "$RPC")"; }
impl_of() { # ERC-1967 implementation of a proxy: the slot must read as a 32-byte word whose top 12 bytes are 0
  rv address "ERC-1967 impl of $1" 'sed -n "s/^0x000000000000000000000000\([0-9a-fA-F]\{40\}\)$/0x\1/p"' \
    cast storage "$1" 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc --rpc-url "$RPC"
}

# ---------------------------------------------------------------- Safe (real execTransaction, 2-of-3)
safe_sig() { printf '000000000000000000000000%s%064d01' "$(lc "${1#0x}")" 0; }
SIGS2="0x$(safe_sig $SAFE_O1)$(safe_sig $SAFE_O2)"   # sorted ascending: O1 < O2
SIG1="0x$(safe_sig $SAFE_O2)"                        # single owner (threshold negative control)
safe_hash() { rv bytes32 "Safe.getTransactionHash" - cast call $SAFE 'getTransactionHash(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,uint256)(bytes32)' "$1" 0 "$2" 0 0 0 0 0x0000000000000000000000000000000000000000 0x0000000000000000000000000000000000000000 "$3" --rpc-url "$RPC"; }
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
# safe_exec_must_fail <label> <to> <data> <inner-revert-data>: approveHash (real tx), then the 2-of-3 exec
# must revert with Error("GS013") (Safe v1.4.1: inner call failed with safeTxGas == gasPrice == 0). The Safe
# hides the inner reason, so the inner call is ALSO replayed as a read-only eth_call with from = Safe (no tx,
# no impersonation) and its revert data must be EXACTLY <inner-revert-data> (required, no default).
safe_exec_must_fail() {
  local label="$1" to="$2" data="$3" inner="$4" n h ir
  [ -n "$inner" ] || { fail "safe_exec_must_fail [$label]: no expected inner revert data given"; return 1; }
  n=$(rb "$label: Safe.nonce" $SAFE 'nonce()(uint256)')
  h=$(safe_hash "$to" "$data" "$n")
  sendtx "$label: approveHash by owner $SAFE_O1 (for a negative control)" $SAFE_O1 $SAFE 'approveHash(bytes32)' "$h" || return 1
  must_fail "$label [inner call replayed as eth_call from the Safe]" "$inner" cast call "$to" "$data" --from $SAFE --rpc-url "$RPC"
  must_fail "$label" "$(errdata 'Error(string)' GS013)" cast send $SAFE "$EXEC_SIG" "$to" 0 "$data" 0 0 0 0 0x0000000000000000000000000000000000000000 0x0000000000000000000000000000000000000000 "$SIGS2" --unlocked --from $SAFE_O2 --rpc-url "$RPC"
  check "$label: Safe.nonce unchanged after the failed exec" "$(rb "$label: Safe.nonce after" $SAFE 'nonce()(uint256)')" "$n"
}
# timelock helpers (target, data, salt) -> calldata for the Safe
tl_schedule_data() { cast calldata 'schedule(address,uint256,bytes,bytes32,bytes32,uint256)' "$1" 0 "$2" $ZERO32 "$3" 172800; }
tl_execute_data() { cast calldata 'execute(address,uint256,bytes,bytes32,bytes32)' "$1" 0 "$2" $ZERO32 "$3"; }
tl_id() { rv bytes32 "TL.hashOperation" - cast call $TL 'hashOperation(address,uint256,bytes,bytes32,bytes32)(bytes32)' "$1" 0 "$2" $ZERO32 "$3" --rpc-url "$RPC"; }

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
      --rpc-url "$RPC" --sender "$s" ${extra[@]+"${extra[@]}"} 2>&1)"
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
xread() { # <url> <label> -> key=value lines; every read is exit-checked and type-checked (DSR CC-125 ①)
  local u="$1" B="$FORK_BLOCK"; XBAD=0
  xr() { # <key> <type> <filter|-> <cast args...>
    local key="$1" ty="$2" flt="$3" v rc; shift 3
    v=$(cast "$@" --rpc-url "$u" 2>"$OUT/.xr.err"); rc=$?
    if [ $rc -eq 0 ] && [ "$flt" != - ]; then v=$(printf '%s\n' "$v" | eval "$flt"); rc=$?; fi
    v=$(printf '%s' "$v" | sed -E 's/ \[-?[0-9.e+-]+\]//g')
    if [ $rc -ne 0 ] || ! rtype "$ty" "$v"; then
      echo "$key=READ-FAILED"; XBAD=$((XBAD+1))
      echo "xread: READ-FAILED $key (expected $ty): exit $rc, value '${v:0:90}' $(head -c 160 "$OUT/.xr.err" | tr '\n' ' ')" >> "$OUT/0-prestate-read-failures.log"
    else echo "$key=$v"; fi
  }
  xr blockHash hash - block $B --field hash
  xr SP.version string - call $SP 'version()(string)' --block $B
  xr SP.owner address - call $SP 'owner()(address)' --block $B
  xr SP.implSlot word - storage $SP 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc --block $B
  xr SP.APNTS_TOKEN address - call $SP 'APNTS_TOKEN()(address)' --block $B
  xr SP.pendingAPNTsToken address - call $SP 'pendingAPNTsToken()(address)' --block $B
  xr SP.pendingAPNTsTokenEta uint - call $SP 'pendingAPNTsTokenEta()(uint256)' --block $B
  xr SP.totalTrackedBalance uint "awk '{print \$1}'" call $SP 'totalTrackedBalance()(uint256)' --block $B
  xr 'SP.operators(OWNER)' other "awk '{print \$1}' | tr '\n' ','" call $SP 'operators(address)(uint128,bool,bool,address,uint32,uint48,address,uint256,uint256)' $OWNER --block $B
  xr 'SP.operators(ANNI)' other "awk '{print \$1}' | tr '\n' ','" call $SP 'operators(address)(uint128,bool,bool,address,uint32,uint48,address,uint256,uint256)' $ANNI --block $B
  xr 'EP.depositInfo(SP)' other - call $EP 'getDepositInfo(address)((uint256,bool,uint112,uint32,uint48))' $SP --block $B
  xr Registry.version string - call $REG 'version()(string)' --block $B
  xr Registry.owner address - call $REG 'owner()(address)' --block $B
  xr Registry.implSlot word - storage $REG 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc --block $B
  xr Safe.VERSION string - call $SAFE 'VERSION()(string)' --block $B
  xr Safe.owners 'address[]' - call $SAFE 'getOwners()(address[])' --block $B
  xr Safe.threshold uint - call $SAFE 'getThreshold()(uint256)' --block $B
  xr Safe.nonce uint - call $SAFE 'nonce()(uint256)' --block $B
  xr Safe.guardSlot word - storage $SAFE 0x4a204f620c8c5ccdca3fd54d003badd85ba500436a431f0cbda4f558c93c34c8 --block $B
  xr Safe.modules other "tr '\n' ' '" call $SAFE 'getModulesPaginated(address,uint256)(address[],address)' 0x0000000000000000000000000000000000000001 10 --block $B
  xr OLD_TL.minDelay uint "awk '{print \$1}'" call $OLD_TL 'getMinDelay()(uint256)' --block $B
  xr 'OLD_TL.proposer(Safe)' bool - call $OLD_TL 'hasRole(bytes32,address)(bool)' $PROPOSER_ROLE $SAFE --block $B
  xr 'OLD_TL.admin(OWNER)' bool - call $OLD_TL 'hasRole(bytes32,address)(bool)' $ADMIN_ROLE $OWNER --block $B
}
XREAD_N=23
: > "$OUT/0-prestate-read-failures.log"
xread "$RPC_URL_FORK" > "$OUT/0-prestate-endpointA.txt"; XBAD_A=$XBAD
xread "$RPC_URL_X" > "$OUT/0-prestate-endpointB.txt"; XBAD_B=$XBAD
{ echo "# endpoint A = the anvil --fork-url provider (key-bearing URL, not written); endpoint B = $RPC_URL_X"
  echo "# block $FORK_BLOCK; identical lines below are equal on both endpoints"
  diff "$OUT/0-prestate-endpointA.txt" "$OUT/0-prestate-endpointB.txt" && echo "IDENTICAL ($(wc -l < "$OUT/0-prestate-endpointA.txt" | tr -d ' ') values)"; } > "$OUT/0-prestate-crosscheck.log" 2>&1
# Fail-closed: EACH endpoint must deliver all XREAD_N values, every one exit-0 and well-typed (a failed or
# empty read is READ-FAILED, never an empty string that could compare equal on both sides); only then is
# "identical" meaningful.
check "pre-state endpoint A: $XREAD_N reads, 0 failed / empty / ill-typed" "$(grep -c '=' "$OUT/0-prestate-endpointA.txt"):$XBAD_A" "$XREAD_N:0"
check "pre-state endpoint B: $XREAD_N reads, 0 failed / empty / ill-typed" "$(grep -c '=' "$OUT/0-prestate-endpointB.txt"):$XBAD_B" "$XREAD_N:0"
if [ "$XBAD_A" = 0 ] && [ "$XBAD_B" = 0 ] && grep -q '^IDENTICAL' "$OUT/0-prestate-crosscheck.log" && ! grep -qiE 'READ-FAILED|error|revert' "$OUT/0-prestate-endpointA.txt"; then
  rlog "  CHECK [pre-state @$FORK_BLOCK identical on two endpoints] PASS ($(tail -1 "$OUT/0-prestate-crosscheck.log"))"
else fail "pre-state cross-check differs, errored or had failed reads (0-prestate-crosscheck.log, 0-prestate-read-failures.log)"; fi
sed 's/^/    /' "$OUT/0-prestate-read-failures.log" | tee -a "$OUT/rehearsal.log" >/dev/null
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
FORK_HASH=$(rv hash "fork block $FORK_BLOCK hash (local fork)" - cast block $FORK_BLOCK --field hash --rpc-url $RPC)
rlog "  chainId $(rv uint chain-id - cast chain-id --rpc-url $RPC) head $(bn) forkBlockHash $FORK_HASH"
# Fork-block hash (DSR CC-125 ①): endpoint A, endpoint B and the local fork must EACH be a non-empty 32-byte
# hash AND all equal (two empty / failed reads must never compare "equal").
HASH_A=$(grep '^blockHash=' "$OUT/0-prestate-endpointA.txt" | cut -d= -f2); HASH_B=$(grep '^blockHash=' "$OUT/0-prestate-endpointB.txt" | cut -d= -f2)
for h in A:$HASH_A B:$HASH_B fork:$FORK_HASH; do
  check "fork block hash well-formed: ${h%%:*} is a 32-byte hash" "$(rtype hash "${h#*:}" && echo hash32 || echo "ILL-TYPED('${h#*:}')")" hash32
done
check "fork block hash: endpoint A == endpoint B" "$(rtype hash "$HASH_A" && echo "$HASH_A" || echo A-INVALID)" "$(rtype hash "$HASH_B" && echo "$HASH_B" || echo B-INVALID)"
check "fork block hash: local fork == endpoint A" "$(rtype hash "$FORK_HASH" && echo "$FORK_HASH" || echo FORK-INVALID)" "$(rtype hash "$HASH_A" && echo "$HASH_A" || echo A-INVALID)"
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
ANNI_TOKEN=$(rv address "SP.operators(ANNI).xPNTsToken" 'sed -n 4p' cast call $SP 'operators(address)(uint128,bool,bool,address,uint32,uint48,address,uint256,uint256)' $ANNI --rpc-url $RPC)
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
TL=$(rv address "G0 TimelockController contractAddress" - cast receipt "$LAST_TX" contractAddress --rpc-url $RPC); TL_DEPLOY_BLOCK=$LAST_BLOCK
rlog "  CANONICAL GOV-1 TIMELOCK = $TL (deployed in block $TL_DEPLOY_BLOCK, tx $LAST_TX)"
rlog "  runtime codehash $(codehash_at $TL) ($(codesize_at $TL) B)"
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
must_fail "A1d: deployer EOA cannot schedule on the canonical TL (not PROPOSER)" "$(errdata "$E_ACL" $OWNER $PROPOSER_ROLE)" cast send $TL 'schedule(address,uint256,bytes,bytes32,bytes32,uint256)' $CAPPED 0 $ACC $ZERO32 $ACC_SALT 172800 --unlocked --from $OWNER --rpc-url $RPC
must_fail "A1d: a Safe OWNER EOA acting directly (not through the Safe) cannot schedule" "$(errdata "$E_ACL" $SAFE_O1 $PROPOSER_ROLE)" cast send $TL 'schedule(address,uint256,bytes,bytes32,bytes32,uint256)' $CAPPED 0 $ACC $ZERO32 $ACC_SALT 172800 --unlocked --from $SAFE_O1 --rpc-url $RPC
must_fail "A1d: Safe exec with ONE owner signature (threshold 2) -> GS020" "$(errdata 'Error(string)' GS020)" cast send $SAFE "$EXEC_SIG" $TL 0 "$(tl_schedule_data $CAPPED $ACC $ACC_SALT)" 0 0 0 0 0x0000000000000000000000000000000000000000 0x0000000000000000000000000000000000000000 "$SIG1" --unlocked --from $SAFE_O2 --rpc-url $RPC
safe_exec "A1d schedule acceptOwnership" $TL "$(tl_schedule_data $CAPPED $ACC $ACC_SALT)" || { fail "A1d schedule"; exit 1; }
check "A1d op pending" "$(rb 'TL.isOperationPending(acc)' $TL 'isOperationPending(bytes32)(bool)' $ACC_ID)" true
rlog "  op $ACC_ID ready at $(rb 'TL.getTimestamp(acc)' $TL 'getTimestamp(bytes32)(uint256)' $ACC_ID)"
safe_exec_must_fail "A1d: Safe execute BEFORE 48h (TimelockUnexpectedOperationState)" $TL "$(tl_execute_data $CAPPED $ACC $ACC_SALT)" "$(errdata "$E_TLSTATE" $ACC_ID $READY_BITMAP)"
warp 172800
must_fail "A1d: deployer EOA cannot execute (not EXECUTOR)" "$(errdata "$E_ACL" $OWNER $EXECUTOR_ROLE)" cast send $TL 'execute(address,uint256,bytes,bytes32,bytes32)' $CAPPED 0 $ACC $ZERO32 $ACC_SALT --unlocked --from $OWNER --rpc-url $RPC
safe_exec "A1d execute acceptOwnership" $TL "$(tl_execute_data $CAPPED $ACC $ACC_SALT)" || { fail "A1d execute"; exit 1; }
check "A1d op done" "$(rb 'TL.isOperationDone(acc)' $TL 'isOperationDone(bytes32)(bool)' $ACC_ID)" true
check "A1d APNTsCapped.owner == canonical TL" "$(rb 'APNTsCapped.owner' $CAPPED 'owner()(address)')" $TL
check "A1d APNTsCapped.pendingOwner == 0" "$(rb 'APNTsCapped.pendingOwner' $CAPPED 'pendingOwner()(address)')" 0x0000000000000000000000000000000000000000
ENV=$ENVNAME TIMELOCK=$TL $LOG "$OUT/I-A1d-verify-apnts-capped.log" forge script contracts/script/v3/DeployAPNTsCapped.s.sol:DeployAPNTsCapped --sig 'verify(address,address)' $CAPPED $OWNER --rpc-url $RPC
[ $? -eq 0 ] && grep -q "verify: ALL PASS" "$OUT/I-A1d-verify-apnts-capped.log" && rlog "  CHECK [A1d DeployAPNTsCapped.verify] PASS (I-A1d-verify-apnts-capped.log)" || fail "A1d DeployAPNTsCapped.verify"

step "STAGE I / A1e (runbook 1③): queue setAPNTsToken(APNTsCapped)"
ENV=$ENVNAME V55_APNTS_DECISION=queue $LOG "$OUT/I-A1e-queue.log" forge script contracts/script/v3/UpgradeToV5_5_0.s.sol:UpgradeToV5_5_0 --sig 'queueAPNTs(address)' $CAPPED --rpc-url $RPC --unlocked --sender $OWNER --broadcast --slow
stop1 A1e $?
QB=$(bn); QTS=$(rv uint "block $QB timestamp" - cast block $QB --field timestamp --rpc-url $RPC)
check "A1e pendingAPNTsToken == APNTsCapped" "$(rb 'SP.pendingAPNTsToken' $SP 'pendingAPNTsToken()(address)')" $CAPPED
check "A1e pendingAPNTsTokenEta == queue block ts + 7d" "$(rb 'SP.pendingAPNTsTokenEta' $SP 'pendingAPNTsTokenEta()(uint256)')" $((QTS+604800))
must_fail "A1e: executeAPNTsTokenChange before the 7-day ETA" "$E_INVALID_CFG" cast send $SP 'executeAPNTsTokenChange()' --unlocked --from $OWNER --rpc-url $RPC
# The LIVE SP here is still 5.4.2 (pre-upgrade). Its executeAPNTsTokenChange reverts InvalidConfiguration()
# on THREE branches (tag v5.4.2 SuperPaymaster.sol:380 pending == 0, :381 block.timestamp < ETA, :395 not
# drained) and the drain branch is ALSO true at this point, so the selector alone does not prove the ETA
# branch fired. Discriminator (read-only eth_calls with state overrides, no tx): the slots are first checked
# against the getters (storage-layout v5.4.2: 15 totalTrackedBalance, 16 protocolRevenue, 30
# pendingAPNTsTokenEta); then (a) drain branch neutralised (15 := 16 := 0), ETA real -> must STILL revert
# InvalidConfiguration() (pending != 0 was read back above, so only the ETA branch is left); (b) positive
# control: drain neutralised AND ETA := 0 -> must SUCCEED (proves the overrides take effect and that the
# ETA was the only remaining blocker).
check "A1e slot 15 == totalTrackedBalance()" "$(cast to-dec "$(rbs 'SP slot 15' $SP 15)")" "$(rb 'SP.totalTrackedBalance' $SP 'totalTrackedBalance()(uint256)' | awk '{print $1}')"
check "A1e slot 16 == protocolRevenue()" "$(cast to-dec "$(rbs 'SP slot 16' $SP 16)")" "$(rb 'SP.protocolRevenue' $SP 'protocolRevenue()(uint256)' | awk '{print $1}')"
check "A1e slot 30 == pendingAPNTsTokenEta()" "$(cast to-dec "$(rbs 'SP slot 30' $SP 30)")" "$(rb 'SP.pendingAPNTsTokenEta' $SP 'pendingAPNTsTokenEta()(uint256)' | awk '{print $1}')"
check "A1e drain branch is also live here (totalTrackedBalance != protocolRevenue)" "$(python3 -c "print($(rb 'SP.totalTrackedBalance' $SP 'totalTrackedBalance()(uint256)') != $(rb 'SP.protocolRevenue' $SP 'protocolRevenue()(uint256)'))")" True
must_fail "A1e discriminator (a): drain neutralised by state override, ETA real -> still InvalidConfiguration (ETA branch)" "$E_INVALID_CFG" \
  cast call $SP 'executeAPNTsTokenChange()' --from $OWNER --rpc-url $RPC --override-state-diff "$SP:0xf:0x0,$SP:0x10:0x0"
if A1E_PC=$(cast call $SP 'executeAPNTsTokenChange()' --from $OWNER --rpc-url $RPC --override-state-diff "$SP:0xf:0x0,$SP:0x10:0x0,$SP:0x1e:0x0" 2>&1); then
  rlog "  CHECK [A1e discriminator (b) positive control: drain AND ETA neutralised -> eth_call succeeds @block $(bn)] PASS"
else fail "A1e discriminator (b) positive control did not succeed: $(echo "$A1E_PC" | head -c 300)"; fi
warp 604800

step "STAGE I / A1f: Safe (minter) mints APNTsCapped for the 1:1 redeposit — real Safe.execTransaction"
OWNER_OLD_BAL=$(rv uint "SP.operators(OWNER).aPNTsBalance" "head -1 | awk '{print \$1}'" cast call $SP 'operators(address)(uint128,bool,bool,address,uint32,uint48,address,uint256,uint256)' $OWNER --rpc-url $RPC)
ANNI_OLD_BAL=$(rv uint "SP.operators(ANNI).aPNTsBalance" "head -1 | awk '{print \$1}'" cast call $SP 'operators(address)(uint128,bool,bool,address,uint32,uint48,address,uint256,uint256)' $ANNI --rpc-url $RPC)
rlog "  snapshot: OWNER aPNTsBalance=$OWNER_OLD_BAL ANNI aPNTsBalance=$ANNI_OLD_BAL @block $(bn)"
must_fail "A1f: deployer EOA cannot mint APNTsCapped (minter = Safe)" "$(errdata 'NotMinter(address)' $OWNER)" cast send $CAPPED 'mint(address,uint256)' $OWNER 1 --unlocked --from $OWNER --rpc-url $RPC
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
ANNI_TOKEN=$(rv address "SP.operators(ANNI).xPNTsToken" 'sed -n 4p' cast call $SP 'operators(address)(uint128,bool,bool,address,uint32,uint48,address,uint256,uint256)' $ANNI --rpc-url $RPC)
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
rlog "  5b stake read-back (deposit, staked, stake, unstakeDelaySec, withdrawTime): $EPI"
read -r _dep EP_STAKED EP_STAKE EP_DELAY EP_WT <<< "$(echo "$EPI" | tr -d '(),')"
check "A3/5b EntryPoint staked" "$EP_STAKED" true
check "A3/5b stake >= 1 ETH" "$(python3 -c "print($EP_STAKE >= 10**18)")" True
check "A3/5b unstakeDelaySec >= 86400" "$(python3 -c "print($EP_DELAY >= 86400)")" True
check "A3/5b withdrawTime == 0" "$EP_WT" 0
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
  agg=$(rv address "price feed aggregator" - cast call "$PRICE_FEED" 'aggregator()(address)' --rpc-url "$RPC")
  read -r roundid answer started updated answered_in <<< "$(rv other "aggregator latestRoundData" "tr '\n' ' ' | sed 's/\[[^]]*\]//g'" cast call "$agg" 'latestRoundData()(uint80,int256,uint256,uint256,uint80)' --rpc-url "$RPC")"
  nowts=$(rv uint "latest block timestamp" - cast block latest --rpc-url "$RPC" --field timestamp)
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
ORACLE_AGG=$(rv address "price feed aggregator" - cast call $PRICE_FEED 'aggregator()(address)' --rpc-url $RPC)
ORACLE_TS=$(rv uint "aggregator latestRoundData.updatedAt" "sed -n 4p | awk '{print \$1}'" cast call $ORACLE_AGG 'latestRoundData()(uint80,int256,uint256,uint256,uint80)' --rpc-url $RPC)
CP_TS=$(rb 'SP.cachedPrice' $SP 'cachedPrice()(int256,uint256,uint80,uint8)' | awk '{print $2}')
check "A6 cachedPrice.updatedAt == oracle latestRoundData.updatedAt (> 0)" "$CP_TS" "$ORACLE_TS"
check "A6 cachedPrice fresh: updatePrice block ts - updatedAt <= priceStalenessThreshold" "$(python3 -c "print(0 < $CP_TS and $(rv uint "block $LAST_BLOCK timestamp" - cast block $LAST_BLOCK --field timestamp --rpc-url $RPC) - $CP_TS <= $(cast call $SP 'priceStalenessThreshold()(uint256)' --rpc-url $RPC | awk '{print $1}'))")" True
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
must_fail "M1: deployer EOA AOAProtocolRegistry.revokeApproval after transfer" "$(errdata "$E_OWNABLE" $OWNER)" cast send $AOAREG 'revokeApproval(uint8,bytes32)' 0 $ZERO32 --unlocked --from $OWNER --rpc-url $RPC
must_fail "M1: deployer EOA xPNTsFactoryV2.setSuperPaymasterAddress after transfer" "$(errdata "$E_OWNABLE" $OWNER)" cast send $FACT 'setSuperPaymasterAddress(address)' $SP --unlocked --from $OWNER --rpc-url $RPC

step "STAGE II / M1 negative: a MISCONFIGURED timelock cannot accept (wrong timelock: minDelay 0, deployer as proposer/executor)"
BADARGS="$(cast abi-encode 'c(uint256,address[],address[],address)' 0 "[$OWNER]" "[$OWNER]" 0x0000000000000000000000000000000000000000)"
sendtx "M1-neg deploy misconfigured timelock" $OWNER --create "$TLBC${BADARGS#0x}" || true
BADTL=$(rv address "misconfigured TL contractAddress" - cast receipt "$LAST_TX" contractAddress --rpc-url $RPC)
rlog "  misconfigured timelock $BADTL (minDelay $(rb 'BADTL.getMinDelay' $BADTL 'getMinDelay()(uint256)'))"
sendtx "M1-neg BADTL.schedule(SP.acceptOwnership)" $OWNER $BADTL 'schedule(address,uint256,bytes,bytes32,bytes32,uint256)' $SP 0 $ACC $ZERO32 $ZERO32 0 || true
must_fail "M1: misconfigured timelock executes SP.acceptOwnership (pendingOwner is the canonical TL)" "$(errdata "$E_OWNABLE" $BADTL)" cast send $BADTL 'execute(address,uint256,bytes,bytes32,bytes32)' $SP 0 $ACC $ZERO32 $ZERO32 --unlocked --from $OWNER --rpc-url $RPC
check "M1-neg SP.owner unchanged" "$(rb 'SP.owner' $SP 'owner()(address)')" $OWNER

step "STAGE II / M1 ② : Safe -> TL.scheduleBatch[SP.acceptOwnership, Registry.acceptOwnership, SP.setGuardian(Safe)] (calldata printed by UpgradeViaTimelock after its operator preflight)"
must_fail "M1: UpgradeViaTimelock schedule-accept WITHOUT a roles attestation" "roles attestation: missing" fscript_tl UpgradeViaTimelock $SAFE_O1 no TL_MODE=schedule-accept TL_SALT=$(cast keccak a2/M1)
roles_check before-M1-schedule
fscript_tl UpgradeViaTimelock $SAFE_O1 no TL_MODE=schedule-accept TL_SALT=$(cast keccak a2/M1) TL_ROLES_ATTESTATION="$ATT" > "$OUT/II-M1-schedule-print.log" 2>&1 || fail "M1 schedule-accept print"
M1_SCHED=$(payload_after "$OUT/II-M1-schedule-print.log" "submit this scheduleBatch from the Safe")
[ -n "$M1_SCHED" ] || { fail "M1: no scheduleBatch calldata printed"; exit 1; }
grep -E "roles attestation|preflight" "$OUT/II-M1-schedule-print.log" | sed 's/^/    /' | tee -a "$OUT/rehearsal.log" >/dev/null
# independent re-derivation of the batch (it must equal what the script printed)
M1_T="[$SP,$REG,$SP]"; M1_V="[0,0,0]"; M1_P="[$ACC,$ACC,$(cast calldata 'setGuardian(address)' $SAFE)]"
M1_EXPECT=$(cast calldata 'scheduleBatch(address[],uint256[],bytes[],bytes32,bytes32,uint256)' "$M1_T" "$M1_V" "$M1_P" $ZERO32 $(cast keccak a2/M1) 172800)
check "M1 printed scheduleBatch calldata == independently encoded" "$M1_SCHED" "$M1_EXPECT"
M1_ID=$(rv bytes32 "TL.hashOperationBatch(M1)" - cast call $TL 'hashOperationBatch(address[],uint256[],bytes[],bytes32,bytes32)(bytes32)' "$M1_T" "$M1_V" "$M1_P" $ZERO32 $(cast keccak a2/M1) --rpc-url $RPC)
must_fail "M1: deployer EOA scheduleBatch directly (not PROPOSER)" "$(errdata "$E_ACL" $OWNER $PROPOSER_ROLE)" cast send $TL "$M1_SCHED" --unlocked --from $OWNER --rpc-url $RPC
safe_exec "M1② scheduleBatch" $TL "$M1_SCHED" || { fail "M1 schedule"; exit 1; }
check "M1② batch pending" "$(rb 'TL.isOperationPending(M1)' $TL 'isOperationPending(bytes32)(bool)' $M1_ID)" true
M1_EXEC=$(cast calldata 'executeBatch(address[],uint256[],bytes[],bytes32,bytes32)' "$M1_T" "$M1_V" "$M1_P" $ZERO32 $(cast keccak a2/M1))
safe_exec_must_fail "M1: Safe executeBatch BEFORE 48h" $TL "$M1_EXEC" "$(errdata "$E_TLSTATE" $M1_ID $READY_BITMAP)"
warp 172800
must_fail "M1: non-multisig (deployer EOA) executeBatch after 48h (not EXECUTOR)" "$(errdata "$E_ACL" $OWNER $EXECUTOR_ROLE)" cast send $TL "$M1_EXEC" --unlocked --from $OWNER --rpc-url $RPC
must_fail "M1: non-multisig (Safe owner EOA directly) executeBatch after 48h" "$(errdata "$E_ACL" $SAFE_O2 $EXECUTOR_ROLE)" cast send $TL "$M1_EXEC" --unlocked --from $SAFE_O2 --rpc-url $RPC
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
must_fail "M1: old EOA owner SP.upgradeToAndCall after M1" "$(errdata "$E_OWNABLE" $OWNER)" cast send $SP 'upgradeToAndCall(address,bytes)' $SPIMPL 0x --unlocked --from $OWNER --rpc-url $RPC
must_fail "M1: old EOA owner Registry.upgradeToAndCall after M1" "$(errdata "$E_OWNABLE" $OWNER)" cast send $REG 'upgradeToAndCall(address,bytes)' $REGIMPL 0x --unlocked --from $OWNER --rpc-url $RPC

step "STAGE II / C (§10.7b C): timelock-aware upgrade drill, SP then Registry (re-deploys the SAME rc.2 bytecode: no rc1' dummy-bump impl exists; see README)"
for T in SP REGISTRY; do
  PROXY=$([ $T = SP ] && echo $SP || echo $REG); NEND=$([ $T = SP ] && echo 65 || echo 74)
  fscript_tl UpgradeViaTimelock $OWNER yes TL_MODE=deploy-impl TL_TARGET=$T > "$OUT/II-C-$T-deploy.log" 2>&1 || fail "C $T deploy-impl"
  NI=$(grep -oE "pass as TL_NEW_IMPL\): 0x[0-9a-fA-F]{40}" "$OUT/II-C-$T-deploy.log" | awk '{print $NF}')
  [ -n "$NI" ] || { fail "C $T: no new impl"; continue; }
  rlog "  $T new impl $NI"
  attest_runtime "C-$T-impl" --target $([ $T = SP ] && echo SuperPaymaster || echo Registry)=$NI
  SALT=$(cast keccak "a2/C/$T")
  must_fail "C $T: schedule-upgrade WITHOUT a roles attestation" "roles attestation: missing" fscript_tl UpgradeViaTimelock $SAFE_O1 no TL_MODE=schedule-upgrade TL_TARGET=$T TL_NEW_IMPL=$NI TL_SALT=$SALT
  roles_check "before-C-$T-schedule"
  fscript_tl UpgradeViaTimelock $SAFE_O1 no TL_MODE=schedule-upgrade TL_TARGET=$T TL_NEW_IMPL=$NI TL_SALT=$SALT TL_ROLES_ATTESTATION="$ATT" > "$OUT/II-C-$T-schedule-print.log" 2>&1 || fail "C $T schedule print"
  UPD=$(cast calldata 'upgradeToAndCall(address,bytes)' $NI 0x)
  SCHED=$(payload_after "$OUT/II-C-$T-schedule-print.log" "submit this from the Safe")
  check "C $T printed schedule calldata == independently encoded" "$SCHED" "$(tl_schedule_data $PROXY $UPD $SALT)"
  safe_exec "C $T schedule(upgradeToAndCall)" $TL "$SCHED" || continue
  CID=$(tl_id $PROXY $UPD $SALT)
  check "C $T op pending" "$(rb "TL.isOperationPending(C-$T)" $TL 'isOperationPending(bytes32)(bool)' $CID)" true
  safe_exec_must_fail "C $T: Safe execute BEFORE 48h" $TL "$(tl_execute_data $PROXY $UPD $SALT)" "$(errdata "$E_TLSTATE" $CID $READY_BITMAP)"
  warp 172800
  roles_check "before-C-$T-execute"
  fscript_tl UpgradeViaTimelock $SAFE_O1 no TL_MODE=execute-upgrade TL_TARGET=$T TL_NEW_IMPL=$NI TL_SALT=$SALT TL_ROLES_ATTESTATION="$ATT" > "$OUT/II-C-$T-execute-print.log" 2>&1 || fail "C $T execute print"
  check "C $T printed execute calldata == independently encoded" "$(payload_after "$OUT/II-C-$T-execute-print.log" "submit this from the Safe")" "$(tl_execute_data $PROXY $UPD $SALT)"
  # pre-execute snapshot for the read-backs the forge script cannot do on the Safe path
  IMPL0=$(impl_of $PROXY); OWN0=$(rv address "$T.owner before execute" - cast call $PROXY 'owner()(address)' --rpc-url $RPC); B_SP=$(rv address "SP.BLS_AGGREGATOR before execute" - cast call $SP 'BLS_AGGREGATOR()(address)' --rpc-url $RPC); B_REG=$(rv address "Registry.blsAggregator before execute" - cast call $REG 'blsAggregator()(address)' --rpc-url $RPC)
  SB=$(bn); for i in $(seq 0 $((NEND-1))); do cast storage $PROXY $i --rpc-url $RPC --block $SB; done > "$OUT/II-C-$T-slots-before.txt"
  safe_exec "C $T execute(upgradeToAndCall)" $TL "$(tl_execute_data $PROXY $UPD $SALT)" || continue
  SA=$(bn); for i in $(seq 0 $((NEND-1))); do cast storage $PROXY $i --rpc-url $RPC --block $SA; done > "$OUT/II-C-$T-slots-after.txt"
  check "C $T op done" "$(rb "TL.isOperationDone(C-$T)" $TL 'isOperationDone(bytes32)(bool)' $CID)" true
  check "C $T ERC-1967 impl slot == new impl" "$(impl_of $PROXY)" "$NI"
  check "C $T impl actually changed (old impl $IMPL0 != new impl)" "$( [ "$(lc $IMPL0)" != "$(lc $NI)" ] && echo changed || echo SAME)" changed
  check "C $T version" "$(rb "$T.version" $PROXY 'version()(string)')" "$([ $T = SP ] && echo '"SuperPaymaster-5.5.0"' || echo '"Registry-5.9.0"')"
  check "C $T owner == TL (unchanged across execute)" "$(rb "$T.owner" $PROXY 'owner()(address)')" "$TL"
  check "C $T owner before execute was TL" "$OWN0" "$TL"
  check "C $T pendingOwner == 0" "$(rb "$T.pendingOwner" $PROXY 'pendingOwner()(address)')" 0x0000000000000000000000000000000000000000
  check "C $T BLS leg SP" "$(rb 'SP.BLS_AGGREGATOR' $SP 'BLS_AGGREGATOR()(address)')" "$B_SP"
  check "C $T BLS leg Registry" "$(rb 'Registry.blsAggregator' $REG 'blsAggregator()(address)')" "$B_REG"
  check "C $T slot dumps well-formed ($NEND words each, >= 1 non-zero)" "$(grep -c '^0x[0-9a-f]\{64\}$' "$OUT/II-C-$T-slots-before.txt"):$(grep -c '^0x[0-9a-f]\{64\}$' "$OUT/II-C-$T-slots-after.txt"):$(grep -vc '^0x0\{64\}$' "$OUT/II-C-$T-slots-before.txt" | awk '{print ($1>0)}')" "$NEND:$NEND:1"
  check "C $T raw slots 0..$((NEND-1)) byte-identical across execute (blocks $SB -> $SA)" "$(shasum -a 256 < "$OUT/II-C-$T-slots-after.txt" | awk '{print $1}')" "$(shasum -a 256 < "$OUT/II-C-$T-slots-before.txt" | awk '{print $1}')"
done

step "STAGE II / M2 (GOV-2): guardian (= Safe) pauses via Safe.execTransaction; validate -> sigFail; guardian cannot unpause / upgrade / move funds; timelock unpauses"
# validate probe with a REAL op: the AAStar AA account from A7 (SBT holder, holds AAStar v2 xPNTs), operator
# OWNER, token OWNER_V2, the 5.5.0 paymasterAndData layout. Replayed as eth_call from the EntryPoint (no tx).
# Its validationData sigFail bit (low 160 bits) must be 0 before the pause (positive control: the probe CAN
# say "ok"), 1 while paused, 0 again after the timelock unpause. (A first draft used a malformed dummy op:
# it returned sigFail=1 in every state, i.e. could not tell paused from unpaused -- not used.)
PROBE_ACCT=$(jq -r .account "$OUT/I-A7-l4-aastar.snapshot.json")
probe_validate() { # <label> -> prints the sigFail bit; logs the raw result with its block
  local b nonce rate pmd agl gf res vd
  b=$(bn)
  nonce=$(rv uint "EP.getNonce(probe account)" "awk '{print \$1}'" cast call $EP 'getNonce(address,uint192)(uint256)' $PROBE_ACCT 0 --rpc-url $RPC --block $b)
  rate=$(rv uint "AAStar v2 exchangeRate" "awk '{print \$1}'" cast call $OWNER_V2 'exchangeRate()(uint256)' --rpc-url $RPC --block $b)
  agl=0x$(printf '%032x%032x' 300000 100000); gf=0x$(printf '%032x%032x' 1000000000 3000000000)
  pmd=0x$(lc ${SP#0x})$(printf '%032x%032x' 300000 300000)$(lc ${OWNER#0x})$(python3 -c "print(format($rate,'064x'))")$(lc ${OWNER_V2#0x})00
  res=$(cast call $SP 'validatePaymasterUserOp((address,uint256,bytes,bytes,bytes32,uint256,bytes32,bytes,bytes),bytes32,uint256)(bytes,uint256)' \
    "($PROBE_ACCT,$nonce,0x,0x,$agl,60000,$gf,$pmd,0x)" "$(cast keccak "a2/M2/probe/$1")" 3180000000000000 --from $EP --rpc-url $RPC --block $b 2>&1 | tr '\n' ' ')
  vd=$(echo "$res" | awk '{print $2}')
  echo "  probe validatePaymasterUserOp(real AAStar op, sender $PROBE_ACCT) [$1] @block $b: validationData=$vd (raw: ${res:0:160})" | tee -a "$OUT/rehearsal.log" >&2
  python3 -c "print(int('$vd') & ((1<<160)-1))" 2>/dev/null || echo "ERR"
}
check "M2 probe BEFORE pause: sigFail bit == 0 (positive control)" "$(probe_validate before-pause)" 0
safe_exec "M2 guardian setGlobalPaused(true)" $SP "$(cast calldata 'setGlobalPaused(bool)' true)" || fail "M2 pause"
check "M2 paused() == true" "$(rb 'SP.paused' $SP 'paused()(bool)')" true
check "M2 probe WHILE paused: sigFail bit == 1 (SIG_VALIDATION_FAILED)" "$(probe_validate while-paused)" 1
safe_exec_must_fail "M2: guardian (Safe) unpause setGlobalPaused(false)" $SP "$(cast calldata 'setGlobalPaused(bool)' false)" "$E_UNAUTH"
safe_exec_must_fail "M2: guardian (Safe) SP.upgradeToAndCall" $SP "$(cast calldata 'upgradeToAndCall(address,bytes)' $SPIMPL 0x)" "$(errdata "$E_OWNABLE" $SAFE)"
safe_exec_must_fail "M2: guardian (Safe) SP.withdrawProtocolRevenue (move funds)" $SP "$(cast calldata 'withdrawProtocolRevenue(address,uint256)' $SAFE 1)" "$(errdata "$E_OWNABLE" $SAFE)"
safe_exec_must_fail "M2: guardian (Safe) unpause an operator setOperatorPaused(OWNER,false)" $SP "$(cast calldata 'setOperatorPaused(address,bool)' $OWNER false)" "$E_UNAUTH"
must_fail "M2: old EOA unpause (neither owner nor guardian)" "$E_UNAUTH" cast send $SP 'setGlobalPaused(bool)' false --unlocked --from $OWNER --rpc-url $RPC
UNP=$(cast calldata 'setGlobalPaused(bool)' false); USALT=$(cast keccak a2/M2/unpause)
roles_check before-M2-schedule
fscript_tl UpgradeViaTimelock $SAFE_O1 no TL_MODE=schedule-call TL_TARGET=SP TL_CALLDATA=$UNP TL_SALT=$USALT TL_ROLES_ATTESTATION="$ATT" > "$OUT/II-M2-schedule-print.log" 2>&1 || fail "M2 schedule print"
check "M2 printed schedule calldata == independently encoded" "$(payload_after "$OUT/II-M2-schedule-print.log" "submit this from the Safe")" "$(tl_schedule_data $SP $UNP $USALT)"
safe_exec "M2 schedule(unpause)" $TL "$(tl_schedule_data $SP $UNP $USALT)" || fail "M2 schedule"
safe_exec_must_fail "M2: Safe execute(unpause) BEFORE 48h" $TL "$(tl_execute_data $SP $UNP $USALT)" "$(errdata "$E_TLSTATE" "$(tl_id $SP $UNP $USALT)" $READY_BITMAP)"
warp 172800
safe_exec "M2 execute(unpause)" $TL "$(tl_execute_data $SP $UNP $USALT)" || fail "M2 execute"
check "M2 paused() == false after the timelock's unpause" "$(rb 'SP.paused' $SP 'paused()(bool)')" false
check "M2 probe AFTER timelock unpause: sigFail bit == 0" "$(probe_validate after-unpause)" 0

step "STAGE II / M3 (GOV-3): setAPNTSPrice only via the timelock"
P0=$(rb 'SP.aPNTsPriceUSD' $SP 'aPNTsPriceUSD()(uint256)' | awk '{print $1}')
P1=$(python3 -c "print($P0 * 105 // 100)")
rlog "  aPNTsPriceUSD $P0 -> $P1 (+5%, inside the ±10% per-update band)"
must_fail "M3: old EOA setAPNTSPrice" "$(errdata "$E_OWNABLE" $OWNER)" cast send $SP 'setAPNTSPrice(uint256)' $P1 --unlocked --from $OWNER --rpc-url $RPC
safe_exec_must_fail "M3: Safe (guardian, not owner) setAPNTSPrice directly" $SP "$(cast calldata 'setAPNTSPrice(uint256)' $P1)" "$(errdata "$E_OWNABLE" $SAFE)"
SETP=$(cast calldata 'setAPNTSPrice(uint256)' $P1); PSALT=$(cast keccak a2/M3/setAPNTSPrice)
roles_check before-M3-schedule
fscript_tl UpgradeViaTimelock $SAFE_O1 no TL_MODE=schedule-call TL_TARGET=SP TL_CALLDATA=$SETP TL_SALT=$PSALT TL_ROLES_ATTESTATION="$ATT" > "$OUT/II-M3-schedule-print.log" 2>&1 || fail "M3 schedule print"
check "M3 printed schedule calldata == independently encoded" "$(payload_after "$OUT/II-M3-schedule-print.log" "submit this from the Safe")" "$(tl_schedule_data $SP $SETP $PSALT)"
safe_exec "M3 schedule(setAPNTSPrice)" $TL "$(tl_schedule_data $SP $SETP $PSALT)" || fail "M3 schedule"
PID=$(tl_id $SP $SETP $PSALT)
check "M3 op pending" "$(rb 'TL.isOperationPending(M3)' $TL 'isOperationPending(bytes32)(bool)' $PID)" true
safe_exec_must_fail "M3: Safe execute(setAPNTSPrice) BEFORE 48h (early execute)" $TL "$(tl_execute_data $SP $SETP $PSALT)" "$(errdata "$E_TLSTATE" $PID $READY_BITMAP)"
check "M3 price unchanged after the early execute" "$(rb 'SP.aPNTsPriceUSD' $SP 'aPNTsPriceUSD()(uint256)' | awk '{print $1}')" $P0
warp 172800
must_fail "M3: deployer EOA execute after 48h (not EXECUTOR)" "$(errdata "$E_ACL" $OWNER $EXECUTOR_ROLE)" cast send $TL 'execute(address,uint256,bytes,bytes32,bytes32)' $SP 0 $SETP $ZERO32 $PSALT --unlocked --from $OWNER --rpc-url $RPC
roles_check before-M3-execute
fscript_tl UpgradeViaTimelock $SAFE_O1 no TL_MODE=execute-call TL_TARGET=SP TL_CALLDATA=$SETP TL_SALT=$PSALT TL_ROLES_ATTESTATION="$ATT" > "$OUT/II-M3-execute-print.log" 2>&1 || fail "M3 execute print"
check "M3 printed execute calldata == independently encoded" "$(payload_after "$OUT/II-M3-execute-print.log" "submit this from the Safe")" "$(tl_execute_data $SP $SETP $PSALT)"
safe_exec "M3 execute(setAPNTSPrice)" $TL "$(tl_execute_data $SP $SETP $PSALT)" || fail "M3 execute"
check "M3 op done" "$(rb 'TL.isOperationDone(M3)' $TL 'isOperationDone(bytes32)(bool)' $PID)" true
check "M3 aPNTsPriceUSD == new price" "$(rb 'SP.aPNTsPriceUSD' $SP 'aPNTsPriceUSD()(uint256)' | awk '{print $1}')" $P1
fi # stage II

if stage_on D; then
# Stage D needs the post-M1 governance state (TL, SAFE path, PROBE_ACCT, OWNER_V2, ...) built by stages I and II
# in the SAME run: run it as part of `all` or as `I,II,D`.
[ -n "${TL:-}" ] && [ -n "${PROBE_ACCT:-}" ] || { fail "stage D requires stages I and II in the same run"; exit 1; }
step "STAGE D (rc1 gate item 4, 03-final-spec.md L394 / §10.7b C): REAL changed-runtime upgrade rc.2 -> rc1' (TEST-ONLY dummy bump) through the Safe-only GOV-1 timelock, then roll back"
rlog "  The C drill above re-deployed the SAME rc.2 bytecode (routing only). Here the new implementation is"
rlog "  contracts/test/upgrade-drill/SuperPaymasterA2DrillDummyBump.sol: a TEST ARTIFACT (never a release artifact)"
rlog "  whose only change vs rc.2 SuperPaymaster is the version() string constant."
DSRC=contracts/test/upgrade-drill/SuperPaymasterA2DrillDummyBump.sol
DART=out/SuperPaymasterA2DrillDummyBump.sol/SuperPaymasterA2DrillDummyBump.default.json
[ -f "$DART" ] || DART=out/SuperPaymasterA2DrillDummyBump.sol/SuperPaymasterA2DrillDummyBump.json
SPART=out/SuperPaymaster.sol/SuperPaymaster.default.json
[ -f "$SPART" ] || SPART=out/SuperPaymaster.sol/SuperPaymaster.json
DRILL_VERSION='SuperPaymaster-5.5.0-A2DRILL-DUMMY-NOT-A-RELEASE'
cp "$DSRC" "$OUT/D-dummy-source.SuperPaymasterA2DrillDummyBump.sol"
git diff --quiet HEAD -- "$DSRC" && DSRC_STATE=committed || DSRC_STATE="UNCOMMITTED"
# D0: the test artifact itself — provenance, compiler settings, size, runtime != rc.2, storage layout == rc.2
node -e '
const fs=require("fs"), {keccak256}=require("viem");
const [dart, spart, att, src, out]=process.argv.slice(1);
const d=JSON.parse(fs.readFileSync(dart)), s=JSON.parse(fs.readFileSync(spart)), a=JSON.parse(fs.readFileSync(att));
const rc2=a.contracts.find(c=>c.contract==="SuperPaymaster");
const m=d.metadata.settings;
const r={ testArtifact:true, label:"TEST ARTIFACT - NOT A RELEASE ARTIFACT (A2 rc1 gate item 4 dummy bump)", source:src,
  sourceSha256:require("crypto").createHash("sha256").update(fs.readFileSync(src)).digest("hex"), artifact:dart,
  artifactFileSha256:require("crypto").createHash("sha256").update(fs.readFileSync(dart)).digest("hex"),
  compiler:d.metadata.compiler.version, evmVersion:m.evmVersion, optimizerRuns:m.optimizer.runs, viaIR:m.viaIR===true,
  runtimeBytes:(d.deployedBytecode.object.length-2)/2, runtimeKeccak:keccak256(d.deployedBytecode.object), creationKeccak:keccak256(d.bytecode.object),
  immutableRefs:Object.keys(d.deployedBytecode.immutableReferences||{}).length,
  rc2SuperPaymaster:{artifact:spart, runtimeBytes:(s.deployedBytecode.object.length-2)/2, runtimeKeccak:keccak256(s.deployedBytecode.object), attestedRuntimeKeccak:rc2.runtimeKeccak} };
fs.writeFileSync(out, JSON.stringify(r,null,2)+"\n");
console.log(JSON.stringify(r));' "$DART" "$SPART" "$W/$ATTEST_JSON" "$DSRC" "$OUT/D-dummy-artifact.json" > /dev/null || { fail "D0 artifact report"; exit 1; }
rlog "  D0 test artifact: $(jq -c '{source,sourceSha256,artifactFileSha256,runtimeBytes,runtimeKeccak,creationKeccak,compiler,evmVersion,optimizerRuns,viaIR}' "$OUT/D-dummy-artifact.json") source state: $DSRC_STATE"
check "D0 dummy source is committed (archive reproducible from the commit)" "$DSRC_STATE" committed
check "D0 dummy compiled with the release settings (cancun / 500 runs / via_ir)" "$(jq -r '"\(.evmVersion)/\(.optimizerRuns)/\(.viaIR)"' "$OUT/D-dummy-artifact.json")" "cancun/500/true"
check "D0 local SuperPaymaster artifact == rc.2 attested runtime (the dummy's base is rc.2)" "$(jq -r .rc2SuperPaymaster.runtimeKeccak "$OUT/D-dummy-artifact.json")" "$(jq -r .rc2SuperPaymaster.attestedRuntimeKeccak "$OUT/D-dummy-artifact.json")"
check "D0 dummy runtime keccak != rc.2 attested runtime keccak" "$( [ "$(jq -r .runtimeKeccak "$OUT/D-dummy-artifact.json")" != "$(jq -r .rc2SuperPaymaster.attestedRuntimeKeccak "$OUT/D-dummy-artifact.json")" ] && echo different || echo SAME)" different
check "D0 dummy runtime <= EIP-170 24576 B" "$(python3 -c "print($(jq -r .runtimeBytes "$OUT/D-dummy-artifact.json") <= 24576)")" True
# D0 provenance (Codex #462 M1): the artifact that is deployed must be the one compiled from THIS checkout.
#   (a) every source recorded in the artifact's compiler metadata (the dummy, SuperPaymaster.sol and all 33
#       transitive imports) has keccak256 == keccak256 of the file in the checkout;
#   (b) compilationTarget is the dummy, and the settings are the release ones;
#   (c) a FRESH compile of the dummy in this run (isolated out/cache dirs under cache/, never out/) yields a
#       runtime AND creation bytecode byte-identical to the artifact that D1 deploys.
# Negative controls: a stale artifact whose recorded dummy source differs (metadata keccak of a source with
# extra logic) and a stale artifact whose runtime differs by one byte must both be REFUSED.
dummy_provenance() { # <artifact> <fresh artifact> -> "PROVENANCE OK ..." (exit 0) | "PROVENANCE MISMATCH: ..." (exit 1)
  node -e '
const fs=require("fs"), {keccak256}=require("viem");
const [art, fresh, target]=process.argv.slice(1);
const a=JSON.parse(fs.readFileSync(art)), f=JSON.parse(fs.readFileSync(fresh));
const bad=[]; const srcs=Object.entries(a.metadata.sources||{});
if(!srcs.length) bad.push("no metadata sources");
for(const [p,v] of srcs){ let k; try{ k=keccak256(fs.readFileSync(p)); }catch(e){ bad.push("source keccak: "+p+" unreadable"); continue; }
  if(k!==v.keccak256) bad.push("source keccak: "+p+" artifact "+v.keccak256+" != checkout "+k); }
const ct=a.metadata.settings.compilationTarget||{};
if(ct[target]!=="SuperPaymasterA2DrillDummyBump") bad.push("compilationTarget "+JSON.stringify(ct));
if(!srcs.find(([p])=>p==="contracts/src/paymasters/superpaymaster/v3/SuperPaymaster.sol")) bad.push("SuperPaymaster.sol not among metadata sources");
const s=a.metadata.settings; if(!(s.evmVersion==="cancun"&&s.optimizer.runs===500&&s.viaIR===true&&s.metadata.bytecodeHash==="none")) bad.push("settings "+JSON.stringify({e:s.evmVersion,r:s.optimizer.runs,v:s.viaIR}));
if(a.deployedBytecode.object!==f.deployedBytecode.object) bad.push("runtime != fresh rebuild ("+keccak256(a.deployedBytecode.object)+" vs "+keccak256(f.deployedBytecode.object)+")");
if(a.bytecode.object!==f.bytecode.object) bad.push("creation != fresh rebuild");
if(bad.length){ console.log("PROVENANCE MISMATCH: "+bad.join("; ")); process.exit(1); }
console.log("PROVENANCE OK: "+srcs.length+"/"+srcs.length+" metadata sources == checkout; runtime "+keccak256(a.deployedBytecode.object)+" and creation "+keccak256(a.bytecode.object)+" == fresh rebuild");' "$1" "$2" "$DSRC"; }
FRESH_DIR=cache/evidence-a2/dummy-fresh; rm -rf "$FRESH_DIR"
forge build "$DSRC" --out "$FRESH_DIR/out" --cache-path "$FRESH_DIR/cache" > "$OUT/D0-dummy-fresh-build.log" 2>&1 || { fail "D0 fresh rebuild of the dummy failed (D0-dummy-fresh-build.log)"; exit 1; }
FRESH_ART="$FRESH_DIR/out/SuperPaymasterA2DrillDummyBump.sol/SuperPaymasterA2DrillDummyBump.json"
rlog "  D0 fresh rebuild: $(grep -m1 -E '^Compiling [0-9]+ files' "$OUT/D0-dummy-fresh-build.log") -> $FRESH_ART"
DPROV=$(dummy_provenance "$DART" "$FRESH_ART"); DPROV_RC=$?
echo "$DPROV" > "$OUT/D0-dummy-provenance.log"
rlog "  $DPROV"
check "D0 dummy artifact provenance (metadata source keccaks == checkout; == fresh rebuild)" "$DPROV_RC:${DPROV%%:*}" "0:PROVENANCE OK"
[ $DPROV_RC -eq 0 ] || { fail "D0: refusing to deploy an artifact not built from this checkout"; exit 1; }
node -e 'const fs=require("fs"),{keccak256}=require("viem");const a=JSON.parse(fs.readFileSync(process.argv[1]));
a.metadata.sources[process.argv[3]].keccak256=keccak256(Buffer.concat([fs.readFileSync(process.argv[3]),Buffer.from("\n// stale build: extra logic\n")]));
fs.writeFileSync(process.argv[2],JSON.stringify(a));' "$DART" "$OUT/.stale-source-artifact.json" "$DSRC"
node -e 'const fs=require("fs");const a=JSON.parse(fs.readFileSync(process.argv[1]));const o=a.deployedBytecode.object;const i=o.length-2;
a.deployedBytecode.object=o.slice(0,i)+(o.slice(i)==="00"?"01":"00");fs.writeFileSync(process.argv[2],JSON.stringify(a));' "$DART" "$OUT/.stale-runtime-artifact.json"
must_fail "D0: stale artifact compiled from a DIFFERENT dummy source (metadata keccak != checkout) is refused" "PROVENANCE MISMATCH: source keccak: $DSRC" dummy_provenance "$OUT/.stale-source-artifact.json" "$FRESH_ART"
must_fail "D0: stale artifact whose runtime differs by one byte from the fresh rebuild is refused" "PROVENANCE MISMATCH: runtime != fresh rebuild" dummy_provenance "$OUT/.stale-runtime-artifact.json" "$FRESH_ART"
rm -f "$OUT/.stale-source-artifact.json" "$OUT/.stale-runtime-artifact.json"
# storage layout: the compiler's storageLayout of the dummy must equal rc.2 SuperPaymaster's EXACTLY (every
# storage entry's label/slot/offset and its type, expanded recursively incl. struct members / mapping key and
# value / array base). Not compared: solc's `contract` attribution (names the contract being compiled, i.e.
# the derived test contract) and astId / raw type ids (they embed per-compilation AST ids: the first trial run
# compared raw JSON and failed only because forge script had recompiled SuperPaymaster with other AST ids).
# Comparator controls (must say DIFFERENT): SuperPaymaster vs Registry, and rc.2's own layout with ONE
# struct-member offset mutated.
REGART=out/Registry.sol/Registry.default.json; [ -f "$REGART" ] || REGART=out/Registry.sol/Registry.json
cmp_layout() { node -e '
const fs=require("fs"); const L=p=>{const j=JSON.parse(fs.readFileSync(p)); return j.storageLayout||j;};
const a=L(process.argv[1]), b=L(process.argv[2]);
if(!a||!b||!a.storage||!b.storage||!a.storage.length){console.log("NO-LAYOUT");process.exit(0);}
// canonical form: every type identifier is expanded recursively into {encoding,label,numberOfBytes,base,key,
// value,members[{label,slot,offset,type}]}; astId / contract / raw type ids (which embed per-compilation AST
// ids) are dropped, everything that determines where and how a value is stored is kept.
const canon=(lay)=>{ const T=(t)=>{ const d=lay.types[t]; if(!d) return {missing:t};
  const o={encoding:d.encoding,label:d.label,numberOfBytes:d.numberOfBytes};
  if(d.base) o.base=T(d.base); if(d.key) o.key=T(d.key); if(d.value) o.value=T(d.value);
  if(d.members) o.members=d.members.map(m=>({label:m.label,slot:m.slot,offset:m.offset,type:T(m.type)})); return o; };
  return lay.storage.map(e=>({label:e.label,slot:e.slot,offset:e.offset,type:T(e.type)})); };
console.log(JSON.stringify(canon(a))===JSON.stringify(canon(b))?"IDENTICAL":"DIFFERENT");' "$1" "$2"; }
node -e 'const fs=require("fs");const l=JSON.parse(fs.readFileSync(process.argv[1])).storageLayout;
const k=Object.keys(l.types).find(t=>l.types[t].members&&l.types[t].members.length>1); const m=l.types[k].members[1]; m.offset=m.offset+1;
fs.writeFileSync(process.argv[2], JSON.stringify(l)); console.log(k+"."+m.label);' "$SPART" "$OUT/.mutated-layout.json" > "$OUT/.mutated-layout.what"
node -e 'const l=JSON.parse(require("fs").readFileSync(process.argv[1])).storageLayout; console.log(JSON.stringify({entries:l.storage.length, maxSlot:Math.max(...l.storage.map(e=>+e.slot+Math.ceil(+l.types[e.type].numberOfBytes/32)-1)),storage:l.storage.map(e=>({slot:e.slot,offset:e.offset,label:e.label,type:e.type,contract:e.contract}))},null,1))' "$DART" > "$OUT/D-dummy-storage-layout.json"
node -e 'const l=JSON.parse(require("fs").readFileSync(process.argv[1])).storageLayout; console.log(JSON.stringify({entries:l.storage.length, maxSlot:Math.max(...l.storage.map(e=>+e.slot+Math.ceil(+l.types[e.type].numberOfBytes/32)-1)),storage:l.storage.map(e=>({slot:e.slot,offset:e.offset,label:e.label,type:e.type,contract:e.contract}))},null,1))' "$SPART" > "$OUT/D-rc2-storage-layout.json"
check "D0 storage layout: dummy == rc.2 SuperPaymaster (compiler storageLayout, entries + types)" "$(cmp_layout "$DART" "$SPART")" IDENTICAL
check "D0 storage layout comparator control 1: SuperPaymaster vs Registry == DIFFERENT" "$(cmp_layout "$SPART" "$REGART")" DIFFERENT
check "D0 storage layout comparator control 2: rc.2 layout with ONE member offset mutated ($(cat "$OUT/.mutated-layout.what")) == DIFFERENT" "$(cmp_layout "$OUT/.mutated-layout.json" "$SPART")" DIFFERENT
check "D0 storage layout comparator control 3: rc.2 layout vs itself == IDENTICAL" "$(cmp_layout "$SPART" "$SPART")" IDENTICAL
rm -f "$OUT/.mutated-layout.json" "$OUT/.mutated-layout.what"
SP_MAXSLOT=$(jq -r .maxSlot "$OUT/D-rc2-storage-layout.json"); DN=$((SP_MAXSLOT+1))
rlog "  D0 layout: $(jq -r .entries "$OUT/D-rc2-storage-layout.json") entries, last occupied slot incl. __gap = $SP_MAXSLOT (raw dumps below cover 0..$SP_MAXSLOT + the ERC-7201 slots)"
INIT_SLOT=0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00   # OZ v5 Initializable (ERC-7201)
OWN2_SLOT=0xdb5a3168abaa6147a9f3a4cb66016161119d4d50b6393344d27120286f742a00   # Ownable2StepNamespaced pending owner
IMPL_SLOT=0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc
# dump_slots <file>: raw SP proxy storage at ONE block (sequential 0..maxSlot + ERC-7201 namespaced slots).
# Codex #462 M2: every read is checked — a failed `cast storage` (or block-number read) writes a
# "READ-FAILED" line, prints "dump_slots: READ-FAILED ..." and returns 1; the caller fails the run. Each
# snapshot is then validated by slots_valid (exactly DN + 2 lines "slot <id> 0x<64 hex>"), so a read that
# failed identically in two snapshots can never compare "identical".
dump_slots() {
  local b v i rc=0 id
  if ! b=$(bn_raw) || ! [[ "$b" =~ ^[0-9]+$ ]]; then echo "dump_slots: READ-FAILED block number" >&2; echo "# READ-FAILED block number" > "$1"; return 1; fi
  echo "# SP proxy $SP raw storage @block $b" > "$1"
  for id in $(seq 0 $SP_MAXSLOT) "Initializable(ERC-7201)=$INIT_SLOT" "Ownable2Step.pending(ERC-7201)=$OWN2_SLOT"; do
    i=${id#*=}
    if v=$(cast storage $SP "$i" --rpc-url $RPC --block "$b" 2>&1) && [[ "$v" =~ ^0x[0-9a-f]{64}$ ]]; then echo "slot ${id%%=*} $v" >> "$1"
    else echo "slot ${id%%=*} READ-FAILED" >> "$1"; echo "dump_slots: READ-FAILED slot ${id%%=*} @block $b: $(echo "$v" | head -c 160)" >&2; rc=1; fi
  done
  return $rc
}
slots_valid() { # <file>: "valid" iff exactly DN + 2 lines "slot <id> 0x<64 hex>", no READ-FAILED, header with a block
  local n bad; n=$(grep -cE '^slot [^ ]+ 0x[0-9a-f]{64}$' "$1"); bad=$(grep -v '^#' "$1" | grep -cvE '^slot [^ ]+ 0x[0-9a-f]{64}$')
  if [ "$n" = "$((DN+2))" ] && [ "$bad" = 0 ] && head -1 "$1" | grep -qE '@block [0-9]+$'; then echo valid; else echo "INVALID($n valid words, $bad bad lines)"; fi
}
dump_slots_checked() { # <file> <label>: dump + fail the run on any read error or malformed snapshot
  dump_slots "$1" || fail "$2: raw slot dump had read failures ($1)"
  check "$2: slot snapshot well-formed (exactly $((DN+2)) 32-byte words, no READ-FAILED)" "$(slots_valid "$1")" valid
}
# Negative controls for the dump itself (injected read failure; a corrupted snapshot), run once here.
dump_slots_deadrpc() { local RPC=http://127.0.0.1:9; dump_slots "$1"; }
dump_slots_inject_slot5() { # shadow `cast` for ONE call: `cast storage <SP> 5 ...` fails like an RPC error
  cast() { if [ "$1" = storage ] && [ "$3" = 5 ]; then echo "Error: injected read failure (connection reset)" >&2; return 1; fi; command cast "$@"; }
  dump_slots "$1"; local rc=$?; unset -f cast; return $rc
}
must_fail "D0: dump_slots with an injected read failure on slot 5 (one cast storage call fails) returns failure" "READ-FAILED slot 5" dump_slots_inject_slot5 "$OUT/.slots-injected-failure.txt"
check "D0: the injected slot-5-failure snapshot is rejected by slots_valid" "$(slots_valid "$OUT/.slots-injected-failure.txt")" "INVALID($((DN+1)) valid words, 1 bad lines)"
check "D0: injection was scoped (cast is no longer shadowed)" "$(type -t cast)" file
must_fail "D0: dump_slots with every read failing (RPC on a dead port) returns failure" "READ-FAILED block number" dump_slots_deadrpc "$OUT/.slots-injected-failure2.txt"
check "D0: the dead-RPC snapshot is rejected by slots_valid" "$(slots_valid "$OUT/.slots-injected-failure2.txt" | cut -c1-7)" INVALID
rm -f "$OUT/.slots-injected-failure2.txt"
dump_slots "$OUT/.slots-control.txt" || fail "D0 control dump failed"
check "D0: a healthy snapshot is accepted by slots_valid (positive control)" "$(slots_valid "$OUT/.slots-control.txt")" valid
sed -E '6s/ 0x[0-9a-f]{64}$/ /' "$OUT/.slots-control.txt" > "$OUT/.slots-corrupt.txt"
check "D0: a snapshot with ONE empty word (the old swallowed-error shape 'slot 4 ') is rejected" "$(slots_valid "$OUT/.slots-corrupt.txt" | cut -c1-7)" INVALID
rm -f "$OUT/.slots-injected-failure.txt" "$OUT/.slots-control.txt" "$OUT/.slots-corrupt.txt"
OPSIG='operators(address)(uint128,bool,bool,address,uint32,uint48,address,uint256,uint256)'
# sp_state <file>: key getters THROUGH the proxy (i.e. decoded by the CURRENT implementation) at ONE block.
# Codex #462 round 2: every `cast call` is checked — a non-zero exit or an empty value writes "<getter> = FAILED",
# prints "sp_state: FAILED ..." and returns 1 (the caller fails the run); state_ok then requires EXACTLY
# SP_STATE_N lines "<getter> = <non-empty value>" and no FAILED / error / revert, so a getter that came back
# blank (or failed) in BOTH snapshots can no longer make the before/after diff say "identical".
SP_STATE_N=24
sp_state() {
  local b v rc=0 q
  if ! b=$(bn_raw) || ! [[ "$b" =~ ^[0-9]+$ ]]; then echo "sp_state: FAILED block number" >&2; echo "# FAILED block number" > "$1"; return 1; fi
  echo "# SP getters via proxy @block $b" > "$1"
  for q in 'owner()(address)' 'pendingOwner()(address)' 'guardian()(address)' 'paused()(bool)' 'APNTS_TOKEN()(address)' \
    'pendingAPNTsToken()(address)' 'pendingAPNTsTokenEta()(uint256)' 'xpntsFactory()(address)' 'treasury()(address)' \
    'aPNTsPriceUSD()(uint256)' 'cachedPrice()(int256,uint256,uint80,uint8)' 'protocolFeeBPS()(uint256)' 'BLS_AGGREGATOR()(address)' \
    'totalTrackedBalance()(uint256)' 'protocolRevenue()(uint256)' 'priceStalenessThreshold()(uint256)' 'priceMode()(uint8)' \
    'entryPoint()(address)' 'REGISTRY()(address)' 'ETH_USD_PRICE_FEED()(address)'; do
    sp_getter "$1" "$q" "$b" $SP "$q" || rc=1
  done
  sp_getter "$1" "operators(OWNER)" "$b" $SP "$OPSIG" $OWNER || rc=1
  sp_getter "$1" "operators(ANNI)" "$b" $SP "$OPSIG" $ANNI || rc=1
  sp_getter "$1" "EP.getDepositInfo(SP)" "$b" $EP 'getDepositInfo(address)((uint256,bool,uint112,uint32,uint48))' $SP || rc=1
  sp_getter "$1" "APNTsCapped.balanceOf(SP)" "$b" $CAPPED 'balanceOf(address)(uint256)' $SP || rc=1
  return $rc
}
sp_getter() { # <file> <label> <block> <cast call args...>: one checked getter line
  local f="$1" label="$2" b="$3" v; shift 3
  if v=$(cast call "$@" --rpc-url $RPC --block "$b" 2>&1); then v=$(echo "$v" | tr '\n' ' ' | sed -E 's/ +$//'); else
    echo "$label = FAILED" >> "$f"; echo "sp_state: FAILED $label @block $b: $(echo "$v" | head -c 160)" >&2; return 1; fi
  if [ -z "$v" ]; then echo "$label = FAILED" >> "$f"; echo "sp_state: FAILED $label @block $b: empty value" >&2; return 1; fi
  echo "$label = $v" >> "$f"
}
state_ok() { # <file>: "valid" iff exactly SP_STATE_N lines "<label> = <non-empty>", none FAILED / error / revert
  local n bad; n=$(grep -cE '^[^#].* = [^ ]' "$1"); bad=$(grep -v '^#' "$1" | grep -cvE '^.+ = [^ ]')
  if [ "$n" = "$SP_STATE_N" ] && [ "$bad" = 0 ] && ! grep -qiE ' = FAILED$|error|revert' "$1" && head -1 "$1" | grep -qE '@block [0-9]+$'; then echo valid
  else echo "INVALID($n non-empty values, $bad bad lines$(grep -qiE ' = FAILED$|error|revert' "$1" && echo ', FAILED/error/revert present'))"; fi
}
sp_state_checked() { # <file> <label>
  sp_state "$1" || fail "$2: getter snapshot had failed or empty reads ($1)"
  check "$2: getter snapshot well-formed (exactly $SP_STATE_N non-empty values, no FAILED/error/revert)" "$(state_ok "$1")" valid
}
# Negative controls for the getter snapshot (Codex #462 round 2), run once here against the live fork.
sp_state_inject_blank() { # shadow `cast` for ONE getter: operators(OWNER) returns exit 0 with an EMPTY value
  cast() { if [ "$1" = call ] && [ "$3" = "$OPSIG" ] && [ "$(lc "$4")" = "$(lc $OWNER)" ]; then return 0; fi; command cast "$@"; }
  sp_state "$1"; local rc=$?; unset -f cast; return $rc
}
sp_state_inject_fail() { # shadow `cast` for ONE getter: operators(OWNER) exits non-zero like an RPC error
  cast() { if [ "$1" = call ] && [ "$3" = "$OPSIG" ] && [ "$(lc "$4")" = "$(lc $OWNER)" ]; then echo "Error: injected read failure" >&2; return 1; fi; command cast "$@"; }
  sp_state "$1"; local rc=$?; unset -f cast; return $rc
}
state_neg_controls() { # <tag>: logs to $OUT/D0-state-guard-controls.log
  local L="$OUT/D0-state-guard-controls.log" T="$OUT/.st"
  must_fail "D0: sp_state with an injected EMPTY getter (operators(OWNER) exit 0, blank) returns failure" "FAILED operators\(OWNER\) @block [0-9]+: empty value" sp_state_inject_blank "$T-blank.txt"
  must_fail "D0: sp_state with an injected FAILED getter (operators(OWNER) exit 1) returns failure" "FAILED operators\(OWNER\) @block [0-9]+: Error: injected read failure" sp_state_inject_fail "$T-fail.txt"
  check "D0: injection was scoped (cast is no longer shadowed)" "$(type -t cast)" file
  sp_state "$T-ok.txt" || fail "D0 healthy getter snapshot failed"
  check "D0: healthy getter snapshot accepted by state_ok (positive control)" "$(state_ok "$T-ok.txt")" valid
  check "D0: snapshot with the injected failed getter rejected" "$(state_ok "$T-fail.txt" | cut -c1-7)" INVALID
  check "D0: snapshot with the injected empty getter rejected" "$(state_ok "$T-blank.txt" | cut -c1-7)" INVALID
  # the Codex reproduction: the SAME getter blank in BOTH snapshots (old state_ok accepted it, diff said identical)
  sed -E 's/^(operators\(OWNER\)) = .*/\1 = /' "$T-ok.txt" > "$T-blankA.txt"; cp "$T-blankA.txt" "$T-blankB.txt"
  check "D0: Codex repro — operators(OWNER) blank in BOTH snapshots: snapshot A rejected" "$(state_ok "$T-blankA.txt")" "INVALID($((SP_STATE_N-1)) non-empty values, 1 bad lines)"
  check "D0: Codex repro — operators(OWNER) blank in BOTH snapshots: snapshot B rejected" "$(state_ok "$T-blankB.txt")" "INVALID($((SP_STATE_N-1)) non-empty values, 1 bad lines)"
  check "D0: Codex repro — the OLD rule would have accepted it (documents the gap)" "$( ! grep -qiE 'error|revert' "$T-blankA.txt" && [ "$(grep -c ' = ' "$T-blankA.txt")" -ge 24 ] && echo old-accepts || echo old-rejects)" old-accepts
  { echo "# getter-snapshot guard controls @block $(bn) (sp_state / state_ok, Codex #462 round 2)"
    for f in ok blank fail blankA; do echo "## $f: state_ok -> $(state_ok "$T-$f.txt")"; sed 's/^/  /' "$T-$f.txt"; done; } > "$L"
  rm -f "$T"-*.txt
}
fresh_price() { refresh_oracle; sendtx "D updatePrice before probe ($1)" $OWNER $SP 'updatePrice()' || fail "D updatePrice ($1)"; }
code_at() { rv code "runtime code of $1" - cast code "$1" --rpc-url $RPC; }
codehash_at() { local c; c=$(code_at "$1") || { echo READ-FAILED; return 1; }; cast keccak "$c"; }
codesize_at() { local c; c=$(code_at "$1") || { echo READ-FAILED; return 1; }; echo $(( (${#c} - 2) / 2 )); }

state_neg_controls

step "STAGE D / D1: deploy the TEST dummy implementation (deployer EOA; constructor = the live SP proxy's three immutables)"
D_EP=$(rb 'SP.entryPoint' $SP 'entryPoint()(address)'); D_REGI=$(rb 'SP.REGISTRY' $SP 'REGISTRY()(address)'); D_FEED=$(rb 'SP.ETH_USD_PRICE_FEED' $SP 'ETH_USD_PRICE_FEED()(address)')
DBC="$(jq -r .bytecode.object "$DART")"; DARGS="$(cast abi-encode 'c(address,address,address)' $D_EP $D_REGI $D_FEED)"
sendtx "D1 deploy TEST dummy impl SuperPaymasterA2DrillDummyBump" $OWNER --create "$DBC${DARGS#0x}" || { fail "D1 deploy"; exit 1; }
DUMMY=$(rv address "D1 dummy contractAddress" - cast receipt "$LAST_TX" contractAddress --rpc-url $RPC); DUMMY_TX=$LAST_TX
rlog "  TEST DUMMY IMPL = $DUMMY (tx $DUMMY_TX block $LAST_BLOCK; $(codesize_at $DUMMY) B runtime; codehash $(codehash_at $DUMMY))"
check "D1 dummy.version() (impl, direct)" "$(rb 'DUMMY.version' $DUMMY 'version()(string)')" "\"$DRILL_VERSION\""
check "D1 dummy.entryPoint == proxy's" "$(rb 'DUMMY.entryPoint' $DUMMY 'entryPoint()(address)')" "$D_EP"
check "D1 dummy.REGISTRY == proxy's" "$(rb 'DUMMY.REGISTRY' $DUMMY 'REGISTRY()(address)')" "$D_REGI"
check "D1 dummy.ETH_USD_PRICE_FEED == proxy's" "$(rb 'DUMMY.ETH_USD_PRICE_FEED' $DUMMY 'ETH_USD_PRICE_FEED()(address)')" "$D_FEED"
check "D1 dummy.proxiableUUID == ERC-1967 implementation slot" "$(rb 'DUMMY.proxiableUUID' $DUMMY 'proxiableUUID()(bytes32)')" $IMPL_SLOT
DEXT=$(rb 'DUMMY.EXTENSION' $DUMMY 'EXTENSION()(address)')
# the deployed dummy runtime == the dummy artifact built from the committed source (TEST-ONLY attestation file,
# generated here, never under docs/release/), and its extension == the rc.2 attested SuperPaymasterAdmin
jq -n --arg art "SuperPaymasterA2DrillDummyBump.sol/$(basename "$DART")" --arg k "$(jq -r .runtimeKeccak "$OUT/D-dummy-artifact.json")" \
  '{testOnly:"TEST ARTIFACT - NOT A RELEASE ATTESTATION (A2 item-4 dummy bump)", attestedCommit:"see D-dummy-artifact.json", contracts:[{contract:"SuperPaymasterA2DrillDummyBump", artifact:$art, runtimeKeccak:$k}]}' > "$OUT/D-dummy-TEST-ONLY-attestation.json"
node script/evidence/verify-attested-runtime.mjs --rpc "$RPC" --attestation "$OUT/D-dummy-TEST-ONLY-attestation.json" --out-dir out \
  --report "$OUT/codehash-D1-dummy-vs-dummy-artifact.json" --target SuperPaymasterA2DrillDummyBump=$DUMMY > "$OUT/codehash-D1-dummy-vs-dummy-artifact.log" 2>&1 \
  && rlog "  CHECK [D1 deployed dummy runtime == dummy artifact (masked immutables)] PASS ($(tail -1 "$OUT/codehash-D1-dummy-vs-dummy-artifact.log"))" \
  || fail "D1 deployed dummy runtime != dummy artifact (codehash-D1-dummy-vs-dummy-artifact.log)"
attest_runtime D1-dummy-ext-and-negative --target SuperPaymasterAdmin=$DEXT --expect-mismatch SuperPaymaster=$DUMMY
check "D1 dummy's EXTENSION runtime == rc.2 attested SuperPaymasterAdmin (only the core changed)" "$(grep -c "^MATCH    SuperPaymasterAdmin @ $DEXT" "$OUT/codehash-D1-dummy-ext-and-negative.log")" 1
check "D1 dummy core runtime != rc.2 attested SuperPaymaster (comparator says no)" "$(grep -c "^negative ok (mismatch as expected) SuperPaymaster vs $DUMMY" "$OUT/codehash-D1-dummy-ext-and-negative.log")" 1
roles_check before-D1-printer
must_fail "D1: the RELEASE tool (UpgradeViaTimelock schedule-upgrade) refuses the TEST dummy impl (DefaultArtifacts gate)" \
  "DefaultArtifacts: SuperPaymaster runtime != profile.default artifact" \
  fscript_tl UpgradeViaTimelock $SAFE_O1 no TL_MODE=schedule-upgrade TL_TARGET=SP TL_NEW_IMPL=$DUMMY TL_SALT=$(cast keccak a2/D/forward) TL_ROLES_ATTESTATION="$ATT"

step "STAGE D / D2: pre-upgrade snapshot + positive control of the validate probe on rc.2"
IMPL0=$(impl_of $SP); V0=$(rb 'SP.version' $SP 'version()(string)'); EXT0=$(rb 'SP.EXTENSION' $SP 'EXTENSION()(address)')
CH0=$(codehash_at $IMPL0); DCH=$(codehash_at $DUMMY)
rlog "  before: impl=$IMPL0 version=$V0 implCodehash=$CH0 EXTENSION=$EXT0 @block $(bn)"
check "D2 current impl is the rc.2 attested SuperPaymaster" "$(node script/evidence/verify-attested-runtime.mjs --rpc "$RPC" --attestation "$ATTEST_JSON" --out-dir out --target SuperPaymaster=$IMPL0 >/dev/null 2>&1 && echo rc2 || echo NOT-rc2)" rc2
check "D2 SP.owner == canonical TL" "$(rb 'SP.owner' $SP 'owner()(address)')" $TL
check "D2 dummy codehash != current impl codehash" "$( [ "$DCH" != "$CH0" ] && echo different || echo SAME)" different
fresh_price before-dummy
check "D2 probe validate on rc.2 BEFORE the dummy upgrade: sigFail bit == 0 (positive control)" "$(probe_validate D-before-dummy)" 0

step "STAGE D / D3: negative controls before scheduling (nobody but the timelock can upgrade; EOAs cannot schedule)"
DUPD=$(cast calldata 'upgradeToAndCall(address,bytes)' $DUMMY 0x); DSALT=$(cast keccak a2/D/forward)
must_fail "D3: old EOA owner SP.upgradeToAndCall(dummy) directly" "$(errdata "$E_OWNABLE" $OWNER)" cast send $SP 'upgradeToAndCall(address,bytes)' $DUMMY 0x --unlocked --from $OWNER --rpc-url $RPC
safe_exec_must_fail "D3: Safe (guardian, not owner) SP.upgradeToAndCall(dummy) directly" $SP "$DUPD" "$(errdata "$E_OWNABLE" $SAFE)"
must_fail "D3: deployer EOA schedule(upgradeToAndCall(dummy)) on the TL (not PROPOSER)" "$(errdata "$E_ACL" $OWNER $PROPOSER_ROLE)" cast send $TL 'schedule(address,uint256,bytes,bytes32,bytes32,uint256)' $SP 0 $DUPD $ZERO32 $DSALT 172800 --unlocked --from $OWNER --rpc-url $RPC
must_fail "D3: Safe owner EOA directly schedule (not through the Safe)" "$(errdata "$E_ACL" $SAFE_O1 $PROPOSER_ROLE)" cast send $TL 'schedule(address,uint256,bytes,bytes32,bytes32,uint256)' $SP 0 $DUPD $ZERO32 $DSALT 172800 --unlocked --from $SAFE_O1 --rpc-url $RPC
must_fail "D3: schedule with delay < minDelay (172799), replayed as eth_call from the Safe address (no tx)" "$(errdata 'TimelockInsufficientDelay(uint256,uint256)' 172799 172800)" cast call $TL 'schedule(address,uint256,bytes,bytes32,bytes32,uint256)' $SP 0 $DUPD $ZERO32 $DSALT 172799 --from $SAFE --rpc-url $RPC

step "STAGE D / D4: Safe -> TL.schedule(SP.upgradeToAndCall(dummy)) (calldata encoded independently: the release printer refuses test artifacts, D1)"
DID=$(tl_id $SP $DUPD $DSALT)
roles_check before-D-forward-schedule
safe_exec "D4 schedule(upgradeToAndCall(dummy))" $TL "$(tl_schedule_data $SP $DUPD $DSALT)" || { fail "D4 schedule"; exit 1; }
DSCHED_TS=$(rv uint "block $LAST_BLOCK timestamp" - cast block $LAST_BLOCK --field timestamp --rpc-url $RPC)
check "D4 op pending" "$(rb 'TL.isOperationPending(D-fwd)' $TL 'isOperationPending(bytes32)(bool)' $DID)" true
check "D4 op NOT ready" "$(rb 'TL.isOperationReady(D-fwd)' $TL 'isOperationReady(bytes32)(bool)' $DID)" false
check "D4 getTimestamp == schedule block ts + 172800" "$(rb 'TL.getTimestamp(D-fwd)' $TL 'getTimestamp(bytes32)(uint256)' $DID | awk '{print $1}')" "$((DSCHED_TS+172800))"
safe_exec_must_fail "D4: Safe execute IMMEDIATELY (TimelockUnexpectedOperationState)" $TL "$(tl_execute_data $SP $DUPD $DSALT)" "$(errdata "$E_TLSTATE" $DID $READY_BITMAP)"
warp 172000
rlog "  head ts $(rv uint "latest block timestamp" - cast block latest --field timestamp --rpc-url $RPC) < ready ts $((DSCHED_TS+172800)) (boundary probe ~800 s before readiness)"
safe_exec_must_fail "D4: Safe execute ~800 s BEFORE readiness (TimelockUnexpectedOperationState)" $TL "$(tl_execute_data $SP $DUPD $DSALT)" "$(errdata "$E_TLSTATE" $DID $READY_BITMAP)"
check "D4 impl still rc.2 after the early executes" "$(impl_of $SP)" "$IMPL0"
warp 800
check "D4 op ready after 48h" "$(rb 'TL.isOperationReady(D-fwd)' $TL 'isOperationReady(bytes32)(bool)' $DID)" true
must_fail "D4: deployer EOA execute after 48h (not EXECUTOR)" "$(errdata "$E_ACL" $OWNER $EXECUTOR_ROLE)" cast send $TL 'execute(address,uint256,bytes,bytes32,bytes32)' $SP 0 $DUPD $ZERO32 $DSALT --unlocked --from $OWNER --rpc-url $RPC

step "STAGE D / D5: Safe -> TL.execute(SP.upgradeToAndCall(dummy)) + read-backs"
dump_slots_checked "$OUT/D5-slots-before.txt" "D5-slots-before"; sp_state_checked "$OUT/D5-state-before.txt" "D5-state-before"
safe_exec "D5 execute(upgradeToAndCall(dummy))" $TL "$(tl_execute_data $SP $DUPD $DSALT)" || { fail "D5 execute"; exit 1; }
D5_TX=$SAFE_LAST_TX; D5_BLOCK=$LAST_BLOCK
dump_slots_checked "$OUT/D5-slots-after.txt" "D5-slots-after"; sp_state_checked "$OUT/D5-state-after.txt" "D5-state-after"
check "D5 Upgraded(dummy) event in the execute tx" "$(cast receipt $D5_TX --rpc-url $RPC --json | jq -r --arg s "$(lc $SP)" --arg t "$(cast keccak 'Upgraded(address)')" --arg i "0x000000000000000000000000$(lc ${DUMMY#0x})" '[.logs[] | select((.address|ascii_downcase)==$s and .topics[0]==$t and .topics[1]==$i)] | length')" 1
check "D5 op done" "$(rb 'TL.isOperationDone(D-fwd)' $TL 'isOperationDone(bytes32)(bool)' $DID)" true
check "D5 ERC-1967 implementation slot == dummy" "$(rbs 'SP ERC-1967 impl slot' $SP $IMPL_SLOT | sed 's/0x000000000000000000000000/0x/')" "$DUMMY"
check "D5 implementation changed (rc.2 $IMPL0 -> dummy)" "$( [ "$(lc "$(impl_of $SP)")" != "$(lc $IMPL0)" ] && echo changed || echo SAME)" changed
check "D5 SP.version() via proxy == dummy string" "$(rb 'SP.version' $SP 'version()(string)')" "\"$DRILL_VERSION\""
D5_CH=$(codehash_at "$(impl_of $SP)")
rlog "  readback [codehash of the proxy's implementation] = $D5_CH @block $(bn) (before: $CH0)"
check "D5 runtime codehash of the proxy's impl == dummy codehash" "$D5_CH" "$DCH"
check "D5 runtime codehash of the proxy's impl CHANGED vs rc.2 impl" "$( [ "$D5_CH" != "$CH0" ] && echo changed || echo SAME)" changed
attest_runtime D5-proxy-impl-is-NOT-rc2 --expect-mismatch SuperPaymaster=$(impl_of $SP)
check "D5 the proxy's implementation runtime != rc.2 attested SuperPaymaster (expected mismatch)" "$(grep -c "^negative ok (mismatch as expected) SuperPaymaster vs $(impl_of $SP)" "$OUT/codehash-D5-proxy-impl-is-NOT-rc2.log")" 1
check "D5 SP.EXTENSION via proxy == dummy's extension (new extension instance, rc.2 code)" "$(rb 'SP.EXTENSION' $SP 'EXTENSION()(address)')" "$DEXT"
check "D5 SP.owner == TL (unchanged)" "$(rb 'SP.owner' $SP 'owner()(address)')" $TL
check "D5 SP.pendingOwner == 0" "$(rb 'SP.pendingOwner' $SP 'pendingOwner()(address)')" 0x0000000000000000000000000000000000000000
check "D5 SP.guardian == Safe (unchanged)" "$(rb 'SP.guardian' $SP 'guardian()(address)')" $SAFE
check "D5 getter snapshots well-formed (exactly $SP_STATE_N non-empty values each)" "$(state_ok "$OUT/D5-state-before.txt"):$(state_ok "$OUT/D5-state-after.txt")" valid:valid
check "D5 getters via proxy identical before/after (rc.2 decode vs dummy decode)" "$(diff <(tail -n +2 "$OUT/D5-state-before.txt") <(tail -n +2 "$OUT/D5-state-after.txt") >/dev/null && echo identical || echo DIFFERENT)" identical
check "D5 slot snapshot not all-zero (>= 1 non-zero word)" "$(grep '^slot ' "$OUT/D5-slots-before.txt" | grep -vc ' 0x0\{64\}$' | awk '{print ($1>0)}')" 1
check "D5 raw storage (slots 0..$SP_MAXSLOT + ERC-7201) byte-identical across the dummy upgrade" "$(diff <(tail -n +2 "$OUT/D5-slots-before.txt") <(tail -n +2 "$OUT/D5-slots-after.txt") >/dev/null && echo identical || echo DIFFERENT)" identical
fresh_price after-dummy
check "D5 probe validate on the DUMMY: sigFail bit == 0 (the changed runtime still sponsors a real op)" "$(probe_validate D-on-dummy)" 0
must_fail "D5: old EOA owner cannot upgrade the dummy back directly" "$(errdata "$E_OWNABLE" $OWNER)" cast send $SP 'upgradeToAndCall(address,bytes)' $IMPL0 0x --unlocked --from $OWNER --rpc-url $RPC

step "STAGE D / D6: ROLL BACK dummy -> rc.2 impl $IMPL0 through the same timelock flow (release printer accepts the rc.2 impl)"
RUPD=$(cast calldata 'upgradeToAndCall(address,bytes)' $IMPL0 0x); RSALT=$(cast keccak a2/D/rollback)
RID=$(tl_id $SP $RUPD $RSALT)
roles_check before-D-rollback-schedule
fscript_tl UpgradeViaTimelock $SAFE_O1 no TL_MODE=schedule-upgrade TL_TARGET=SP TL_NEW_IMPL=$IMPL0 TL_SALT=$RSALT TL_ROLES_ATTESTATION="$ATT" > "$OUT/D6-rollback-schedule-print.log" 2>&1 || fail "D6 schedule print (release tool on the rc.2 impl)"
check "D6 release printer accepted the rc.2 impl and its schedule calldata == independently encoded" "$(payload_after "$OUT/D6-rollback-schedule-print.log" "submit this from the Safe")" "$(tl_schedule_data $SP $RUPD $RSALT)"
safe_exec "D6 schedule(upgradeToAndCall(rc.2 impl))" $TL "$(tl_schedule_data $SP $RUPD $RSALT)" || { fail "D6 schedule"; exit 1; }
RSCHED_TS=$(rv uint "block $LAST_BLOCK timestamp" - cast block $LAST_BLOCK --field timestamp --rpc-url $RPC)
check "D6 op pending" "$(rb 'TL.isOperationPending(D-rb)' $TL 'isOperationPending(bytes32)(bool)' $RID)" true
check "D6 getTimestamp == schedule block ts + 172800" "$(rb 'TL.getTimestamp(D-rb)' $TL 'getTimestamp(bytes32)(uint256)' $RID | awk '{print $1}')" "$((RSCHED_TS+172800))"
safe_exec_must_fail "D6: Safe execute rollback BEFORE 48h (TimelockUnexpectedOperationState)" $TL "$(tl_execute_data $SP $RUPD $RSALT)" "$(errdata "$E_TLSTATE" $RID $READY_BITMAP)"
check "D6 impl still the dummy after the early execute" "$(impl_of $SP)" "$DUMMY"
warp 172800
must_fail "D6: deployer EOA execute rollback after 48h (not EXECUTOR)" "$(errdata "$E_ACL" $OWNER $EXECUTOR_ROLE)" cast send $TL 'execute(address,uint256,bytes,bytes32,bytes32)' $SP 0 $RUPD $ZERO32 $RSALT --unlocked --from $OWNER --rpc-url $RPC
roles_check before-D-rollback-execute
fscript_tl UpgradeViaTimelock $SAFE_O1 no TL_MODE=execute-upgrade TL_TARGET=SP TL_NEW_IMPL=$IMPL0 TL_SALT=$RSALT TL_ROLES_ATTESTATION="$ATT" > "$OUT/D6-rollback-execute-print.log" 2>&1 || fail "D6 execute print"
check "D6 release printer execute calldata == independently encoded" "$(payload_after "$OUT/D6-rollback-execute-print.log" "submit this from the Safe")" "$(tl_execute_data $SP $RUPD $RSALT)"
dump_slots_checked "$OUT/D6-slots-before.txt" "D6-slots-before"; sp_state_checked "$OUT/D6-state-before.txt" "D6-state-before"
safe_exec "D6 execute(upgradeToAndCall(rc.2 impl))" $TL "$(tl_execute_data $SP $RUPD $RSALT)" || { fail "D6 execute"; exit 1; }
D6_TX=$SAFE_LAST_TX
dump_slots_checked "$OUT/D6-slots-after.txt" "D6-slots-after"; sp_state_checked "$OUT/D6-state-after.txt" "D6-state-after"
check "D6 Upgraded(rc.2 impl) event in the execute tx" "$(cast receipt $D6_TX --rpc-url $RPC --json | jq -r --arg s "$(lc $SP)" --arg t "$(cast keccak 'Upgraded(address)')" --arg i "0x000000000000000000000000$(lc ${IMPL0#0x})" '[.logs[] | select((.address|ascii_downcase)==$s and .topics[0]==$t and .topics[1]==$i)] | length')" 1
check "D6 op done" "$(rb 'TL.isOperationDone(D-rb)' $TL 'isOperationDone(bytes32)(bool)' $RID)" true
check "D6 ERC-1967 implementation slot == rc.2 impl" "$(rbs 'SP ERC-1967 impl slot' $SP $IMPL_SLOT | sed 's/0x000000000000000000000000/0x/')" "$IMPL0"
check "D6 SP.version() == SuperPaymaster-5.5.0" "$(rb 'SP.version' $SP 'version()(string)')" '"SuperPaymaster-5.5.0"'
D6_CH=$(codehash_at "$(impl_of $SP)")
rlog "  readback [codehash of the proxy's implementation] = $D6_CH @block $(bn) (dummy: $DCH; original rc.2: $CH0)"
check "D6 runtime codehash of the proxy's impl == original rc.2 impl codehash" "$D6_CH" "$CH0"
attest_runtime D6-proxy-impl-is-rc2-again --target SuperPaymaster=$(impl_of $SP)
check "D6 the proxy's implementation runtime == rc.2 attested SuperPaymaster again" "$(grep -c "^MATCH    SuperPaymaster @ $(impl_of $SP)" "$OUT/codehash-D6-proxy-impl-is-rc2-again.log")" 1
check "D6 SP.EXTENSION == original rc.2 extension" "$(rb 'SP.EXTENSION' $SP 'EXTENSION()(address)')" "$EXT0"
check "D6 SP.owner == TL; pendingOwner == 0; guardian == Safe" "$(rb 'SP.owner' $SP 'owner()(address)'):$(rb 'SP.pendingOwner' $SP 'pendingOwner()(address)'):$(rb 'SP.guardian' $SP 'guardian()(address)')" "$TL:0x0000000000000000000000000000000000000000:$SAFE"
check "D6 getter snapshots well-formed (exactly $SP_STATE_N non-empty values each)" "$(state_ok "$OUT/D6-state-before.txt"):$(state_ok "$OUT/D6-state-after.txt")" valid:valid
check "D6 getters via proxy identical before/after the rollback" "$(diff <(tail -n +2 "$OUT/D6-state-before.txt") <(tail -n +2 "$OUT/D6-state-after.txt") >/dev/null && echo identical || echo DIFFERENT)" identical
check "D6 raw storage byte-identical across the rollback" "$(diff <(tail -n +2 "$OUT/D6-slots-before.txt") <(tail -n +2 "$OUT/D6-slots-after.txt") >/dev/null && echo identical || echo DIFFERENT)" identical
fresh_price after-rollback
check "D6 probe validate on rc.2 after the rollback: sigFail bit == 0" "$(probe_validate D-after-rollback)" 0
fi # stage D

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
  attest_runtime final --target SuperPaymaster=$(impl_of $SP) --target SuperPaymasterAdmin=$(rv address "SP.EXTENSION" - cast call $SP 'EXTENSION()(address)' --rpc-url $RPC) --target Registry=$(impl_of $REG) \
    --target SuperPaymasterLens=$LENS --target GlobalTierSource=$TIER --target AOAProtocolRegistry=$AOAREG --target xPNTsTokenV2Ext=$V2EXT \
    --target xPNTsTokenV2=$V2IMPL --target xPNTsFactoryV2=$FACT --target APNTsCapped=$CAPPED \
    --clone AAStarV2=$OWNER_V2:$V2IMPL --clone MyceliumV2=$ANNI_V2:$V2IMPL --expect-mismatch Registry=$(impl_of $SP)
fi
step "fork tx ledger: EVERY transaction mined on the fork after block $FORK_BLOCK (from, to, selector, status)"
HEADB=$(bn)
# NOTE: an integer loop, not `seq`: BSD seq prints 8-digit block numbers as 1.18779e+07 (the first full
# run, fork block 11877866, produced an EMPTY ledger that way; its positive control caught it).
LEDGER_BLOCKS=0
for ((b = FORK_BLOCK + 1; b <= HEADB; b++)); do
  LEDGER_BLOCKS=$((LEDGER_BLOCKS+1))
  BJ=$(cast block $b --json --rpc-url $RPC) || { fail "ledger: cast block $b failed"; continue; }
  for h in $(echo "$BJ" | jq -r '.transactions[] | if type=="object" then .hash else . end'); do
    RJ=$(cast receipt $h --json --rpc-url $RPC) || { fail "ledger: receipt $h failed"; continue; }
    cast tx $h --json --rpc-url $RPC | jq -c --arg st "$(echo "$RJ" | jq -r .status)" --arg ca "$(echo "$RJ" | jq -r '.contractAddress // ""')" \
      '{block:(.blockNumber), hash, from, to, contractAddress:$ca, selector:(.input[0:10]), status:$st}'
  done
done > "$OUT/fork-tx-ledger.jsonl"
check "ledger walked every block after the fork block" "$LEDGER_BLOCKS" "$((HEADB - FORK_BLOCK))"
check "ledger contains EVERY tx hash recorded in receipts.jsonl" "$(jq -r '.transactionHash|ascii_downcase' "$OUT/receipts.jsonl" | sort -u | while read -r x; do grep -qi "$x" "$OUT/fork-tx-ledger.jsonl" || echo "$x"; done | wc -l | tr -d ' ')" 0
NTX=$(wc -l < "$OUT/fork-tx-ledger.jsonl" | tr -d ' ')
rlog "  ledger: $NTX txs in blocks $((FORK_BLOCK+1))..$HEADB (fork-tx-ledger.jsonl)"
check "ledger non-empty and every block accounted for (positive control: G0 deploy tx present)" "$(grep -c "$(lc $(jq -r 'select(.label=="G0 deploy canonical TimelockController")|.transactionHash' "$OUT/receipts.jsonl"))" "$OUT/fork-tx-ledger.jsonl")" 1
check "ledger: NO tx sent FROM the Safe address (the Safe was never impersonated)" "$(jq -r 'select((.from|ascii_downcase)=="'"$(lc $SAFE)"'")|.hash' "$OUT/fork-tx-ledger.jsonl" | wc -l | tr -d ' ')" 0
check "ledger: every Safe-targeted tx was sent by a Safe OWNER EOA (approveHash / execTransaction)" "$(jq -r 'select((.to//""|ascii_downcase)=="'"$(lc $SAFE)"'") | .from|ascii_downcase' "$OUT/fork-tx-ledger.jsonl" | sort -u | paste -sd, -)" "$(printf '%s\n' "$(lc $SAFE_O1)" "$(lc $SAFE_O2)" | sort -u | paste -sd, -)"
check "ledger: no mined tx reverted (negative controls never reach the chain)" "$(jq -r 'select(.status!="true" and .status!="1" and .status!="0x1")|.hash' "$OUT/fork-tx-ledger.jsonl" | wc -l | tr -d ' ')" 0
check "ledger: no mined tx was sent directly to the canonical timelock (every schedule/execute is an internal call from the Safe)" "$(jq -r 'select((.to//""|ascii_downcase)=="'"$(lc $TL)"'")|.from|ascii_downcase' "$OUT/fork-tx-ledger.jsonl" | sort -u | paste -sd, -)" ""
rlog "  SP owner=$(rb 'final SP.owner' $SP 'owner()(address)') guardian=$(rb 'final SP.guardian' $SP 'guardian()(address)') impl=$(impl_of $SP) version=$(rb 'final SP.version' $SP 'version()(string)') @block $(bn)"
rlog "  Registry owner=$(rb 'final Registry.owner' $REG 'owner()(address)') impl=$(impl_of $REG) version=$(rb 'final Registry.version' $REG 'version()(string)') @block $(bn)"
rlog "  negative controls executed: $NEG_N (all reverted; neg-controls.jsonl)"
NBANG=$(grep -c '!!!' "$OUT/rehearsal.log")
rlog "  CHECK lines: $(grep -c 'CHECK \[.*\] PASS' "$OUT/rehearsal.log") PASS, $(grep -c 'CHECK \[.*\] FAIL' "$OUT/rehearsal.log") FAIL; !!! lines: $NBANG"
# The verdict counts BOTH the in-shell FAILURES counter and the "!!!" lines: a fail() inside $(...) (e.g. a
# READ FAILED from rv / rb) only survives as its "!!!" line.
[ "$NBANG" -gt "$FAILURES" ] && FAILURES=$NBANG
if [ "$FAILURES" -eq 0 ]; then rlog "RUN COMPLETED WITH 0 FAILURES ($STAGE) — this line is a tally, not evidence; see the per-step CHECK / TX / readback lines above"
else rlog "RUN FAILED ($STAGE): $FAILURES failure(s), see the !!! lines"; exit 1; fi
