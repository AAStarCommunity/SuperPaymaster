#!/usr/bin/env bash
# Read-only post-send read-back of the live A3a packet 0bb821d1 (Sepolia test Safe).
# Every value is read at one numeric block from two different RPC endpoints. The run
# fails unless both endpoints return the same block hash before and after the reads,
# the same value for every query, and values equal to the expectations below.
# Timelock role sets are rebuilt from all role events since deployment and compared
# exactly with plan.json, so an extra member fails. The RPC URL is read from a file and
# only its hostname is recorded.
# Every cast call checks its own exit status: errexit is not inherited by command substitutions.
# Usage: a3a-live-readback.sh <rpc-file> <second-rpc-url> <decimal-block> <out-dir>
set -euo pipefail
RPC_FILE=$1; RPC2=$2; BLOCK=$3; OUT=$4
[[ $BLOCK =~ ^[0-9]+$ ]] || { echo "block must be a decimal number, not a tag: $BLOCK" >&2; exit 2; }
[ -d "$OUT" ] && [ -n "$(ls -A "$OUT")" ] && { echo "out dir not empty: $OUT" >&2; exit 2; }
RPC1=$(cat "$RPC_FILE")
host() { python3 -c 'import sys,urllib.parse as u;print((u.urlparse(sys.argv[1]).hostname or "").rstrip("."))' "$1"; }
H1=$(host "$RPC1"); H2=$(host "$RPC2")
[ -n "$H1" ] && [ -n "$H2" ] || { echo "cannot parse RPC hostnames" >&2; exit 2; }
[ "$RPC1" != "$RPC2" ] && [ "$H1" != "$H2" ] || { echo "the two RPCs must be different endpoints" >&2; exit 2; }
mkdir -p "$OUT"
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1
CAST=${CAST:-$HOME/Dev/aastar/tools/foundry-rams/nightly-4e8874b/cast}
HERE=$(cd "$(dirname "$0")/../.." && pwd)
PLAN=${A3A_PLAN:-$HERE/docs/release/a3a-testsafe-12025632/a3a-plan/plan.json}  # override only for negative controls

SAFE=0x16dF788ed4ed1Fc384e52dC832A6a6C3A23bdEBf
DEPLOYER=0xb5600060e6de5E11D3636731964218E53caadf0E
APPROVER=0xE3D28Aa77c95d5C098170698e5ba68824BFC008d
EXECUTOR=0xF7Bf79AcB7F3702b9DbD397d8140ac9DE6Ce642C
TL=0xCCdF8e0D29Fb2c3061910D79484a2b653757C34B
AP=0x9Eb17FAc022557F64924aA2F9E018dB3A330e1E7
OP=0xa8c50665f85b1b63f98adc15dc5aab789f1ad91db7d2bc4425ecd46e0fcebc40
S2_BLOCK=12032424
S5B_BLOCK=12032520

# Each line: label|kind|args...   kind call = cast call at BLOCK; nonce; ts (block timestamp); code
QUERIES=(
  "tl.code.beforeDeploy|code|$TL|$((S2_BLOCK - 1))"
  "tl.minDelay|call|$TL|getMinDelay()(uint256)"
  "tl.opState|call|$TL|getOperationState(bytes32)(uint8)|$OP"
  "tl.opTimestamp|call|$TL|getTimestamp(bytes32)(uint256)|$OP"
  "ap.owner|call|$AP|owner()(address)"
  "ap.pendingOwner|call|$AP|pendingOwner()(address)"
  "ap.cap|call|$AP|cap()(uint256)"
  "ap.totalSupply|call|$AP|totalSupply()(uint256)"
  "safe.nonce|call|$SAFE|nonce()(uint256)"
  "nonce.deployer|nonce|$DEPLOYER"
  "nonce.approver|nonce|$APPROVER"
  "nonce.executor|nonce|$EXECUTOR"
  "s5b.blockTimestamp|ts|$S5B_BLOCK"
)

q() { # q <rpc> <kind> args... ; prints the value, fails on an RPC error or empty output
  local rpc=$1 kind=$2 r; shift 2
  case $kind in
    call) r=$("$CAST" call "$@" --block "$BLOCK" --rpc-url "$rpc") || return 1; r=${r%% *} ;;
    nonce) r=$("$CAST" nonce "$1" --block "$BLOCK" --rpc-url "$rpc") || return 1 ;;
    ts) r=$("$CAST" block "$1" -f timestamp --rpc-url "$rpc") || return 1 ;;
    code) r=$("$CAST" code "$1" --block "$2" --rpc-url "$rpc") || return 1 ;;
  esac
  [ -n "$r" ] || return 1
  printf '%s\n' "$r"
}
bhash() { # bhash <rpc> ; the block hash at BLOCK, format-checked
  local h; h=$("$CAST" block "$BLOCK" -f hash --rpc-url "$1") || return 1
  [[ $h =~ ^0x[0-9a-f]{64}$ ]] || return 1
  printf '%s\n' "$h"
}

hA1=$(bhash "$RPC1"); hA2=$(bhash "$RPC2")
{
  echo "block=$BLOCK"
  echo "rpc1.host=$H1"
  echo "rpc2.host=$H2"
  echo "blockHash.rpc1=$hA1"
  echo "blockHash.rpc2=$hA2"
} > "$OUT/readback.txt"
fail=0
[ "$hA1" = "$hA2" ] || { echo "MISMATCH block hash rpc1=$hA1 rpc2=$hA2" | tee -a "$OUT/readback.txt" >&2; fail=1; }
for line in "${QUERIES[@]}"; do
  IFS='|' read -r label kind rest <<<"$line"
  IFS='|' read -r -a args <<<"$rest"
  a=$(q "$RPC1" "$kind" "${args[@]}"); b=$(q "$RPC2" "$kind" "${args[@]}")
  [ "$a" = "$b" ] || { echo "DISAGREE $label rpc1=$a rpc2=$b" | tee -a "$OUT/readback.txt" >&2; fail=1; continue; }
  echo "$label=$a" >> "$OUT/readback.txt"
done

# Role sets: every RoleGranted / RoleRevoked / RoleAdminChanged since deployment, from both RPCs.
for i in 1 2; do
  rpc=RPC$i
  "$CAST" logs --from-block "$S2_BLOCK" --to-block "$BLOCK" --address "$TL" --json --rpc-url "${!rpc}" > "$OUT/tl-logs.rpc$i.json"
done
python3 - "$OUT/tl-logs.rpc1.json" "$OUT/tl-logs.rpc2.json" "$PLAN" "$TL" >> "$OUT/readback.txt" <<'PY' || fail=1
import json, sys
GRANT = "0x2f8788117e7eff1d82e926ec794901d17c78024a50270940304540a733656f0d"
REVOKE = "0xf6391f5c32d9c69d2a47ea670b442974b53935d1edc7fd64eb21e047a839171b"
ADMIN = "0xbd79b86ffe0ab8e8776151514217cd7cacd52c909f66475c3af44e129f0b00ff"
ROLE = {"0x" + "00" * 32: "DEFAULT_ADMIN",
        "0xb09aa5aeb3702cfd50b6b62bc4532604938f21248a27a1d5ca736082b6819cc1": "PROPOSER",
        "0xd8aa0f3194971a2a116679f7c2090f6939c8d4e01a2a8d7e41d55e5351469e63": "EXECUTOR",
        "0xfd643c72710c63c0180259aba6b2d05451e3591a24e58b62239378085726f783": "CANCELLER"}
a, b, plan, tl = sys.argv[1:5]
def key(l): return (int(l["blockNumber"], 16), int(l["logIndex"], 16), l["transactionHash"], tuple(l["topics"]), l["data"])
la = sorted(map(key, json.load(open(a)))); lb = sorted(map(key, json.load(open(b))))
ok = True
if la != lb:
    print("DISAGREE tl.logs"); ok = False
sets = {r: set() for r in ROLE.values()}
n = 0
for blk, idx, tx, topics, data in la:
    t0 = topics[0]
    if t0 == ADMIN:
        print("MISMATCH RoleAdminChanged present"); ok = False
    if t0 in (GRANT, REVOKE):
        n += 1
        role = ROLE.get(topics[1])
        if role is None:
            print("MISMATCH unknown role " + topics[1]); ok = False; continue
        who = "0x" + topics[2][-40:]
        (sets[role].add if t0 == GRANT else sets[role].discard)(who)
want = {k: set(v) for k, v in json.load(open(plan))["roles"].items()}
for r in sorted(sets):
    print(f"tl.role.{r}={','.join(sorted(sets[r]))}")
print(f"tl.roleEvents={n}")
if n == 0:
    print("MISMATCH no role events: the log query found nothing"); ok = False
if sets != want:
    print("MISMATCH role sets differ from plan.json"); ok = False
sys.exit(0 if ok else 1)
PY

hB1=$(bhash "$RPC1"); hB2=$(bhash "$RPC2")
echo "blockHash.after.rpc1=$hB1" >> "$OUT/readback.txt"
echo "blockHash.after.rpc2=$hB2" >> "$OUT/readback.txt"
[ "$hB1" = "$hA1" ] && [ "$hB2" = "$hA1" ] || { echo "MISMATCH block hash changed during the reads" | tee -a "$OUT/readback.txt" >&2; fail=1; }

v() { sed -n "s/^$1=//p" "$OUT/readback.txt"; }
expect() { [ "$(v "$1")" = "$2" ] || { echo "MISMATCH $1 got=$(v "$1") want=$2" | tee -a "$OUT/readback.txt" >&2; fail=1; }; }
lc() { tr 'A-F' 'a-f' <<<"$1"; }
expect tl.code.beforeDeploy 0x
expect tl.minDelay 172800
expect tl.opState 1
expect ap.cap 10000000000000000000000000
expect ap.totalSupply 0
expect safe.nonce 2
expect nonce.deployer 12135
expect nonce.approver 98
expect nonce.executor 753
[ "$(lc "$(v ap.owner)")" = "$(lc $DEPLOYER)" ] || { echo "MISMATCH ap.owner" | tee -a "$OUT/readback.txt" >&2; fail=1; }
[ "$(lc "$(v ap.pendingOwner)")" = "$(lc $TL)" ] || { echo "MISMATCH ap.pendingOwner" | tee -a "$OUT/readback.txt" >&2; fail=1; }
eta=$(v tl.opTimestamp); ts=$(v s5b.blockTimestamp)
[ -n "$eta" ] && [ -n "$ts" ] && [ $((eta - ts)) -eq 172800 ] || { echo "MISMATCH eta-ts" | tee -a "$OUT/readback.txt" >&2; fail=1; }
echo "eta.minus.s5bTimestamp=$((${eta:-0} - ${ts:-0}))" >> "$OUT/readback.txt"

if [ $fail -eq 0 ]; then echo "READBACK PASS" | tee "$OUT/verdict.txt"; else echo "READBACK FAIL" | tee "$OUT/verdict.txt"; exit 1; fi
