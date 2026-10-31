#!/usr/bin/env bash
# Read-only post-send read-back of the live A3a packet 0bb821d1 (Sepolia test Safe).
# Reads every value at one fixed block from two RPCs and fails unless both agree
# and match the expectations. The RPC URL is read from a file and never printed.
# Usage: a3a-live-readback.sh <rpc-file> <second-rpc-url> <block> <out-dir>
set -euo pipefail
RPC_FILE=$1; RPC2=$2; BLOCK=$3; OUT=$4
[ -d "$OUT" ] && [ -n "$(ls -A "$OUT")" ] && { echo "out dir not empty: $OUT" >&2; exit 2; }
mkdir -p "$OUT"
RPC1=$(cat "$RPC_FILE")
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1
CAST=${CAST:-$HOME/Dev/aastar/tools/foundry-rams/nightly-4e8874b/cast}

SAFE=0x16dF788ed4ed1Fc384e52dC832A6a6C3A23bdEBf
DEPLOYER=0xb5600060e6de5E11D3636731964218E53caadf0E
APPROVER=0xE3D28Aa77c95d5C098170698e5ba68824BFC008d
EXECUTOR=0xF7Bf79AcB7F3702b9DbD397d8140ac9DE6Ce642C
TL=0xCCdF8e0D29Fb2c3061910D79484a2b653757C34B
AP=0x9Eb17FAc022557F64924aA2F9E018dB3A330e1E7
OP=0xa8c50665f85b1b63f98adc15dc5aab789f1ad91db7d2bc4425ecd46e0fcebc40
S5B_BLOCK=12032520

# Each line: label|kind|args...   kind call = cast call at BLOCK; nonce; ts (block timestamp)
QUERIES=(
  "tl.minDelay|call|$TL|getMinDelay()(uint256)"
  "tl.opState|call|$TL|getOperationState(bytes32)(uint8)|$OP"
  "tl.opTimestamp|call|$TL|getTimestamp(bytes32)(uint256)|$OP"
  "tl.proposer.safe|call|$TL|hasRole(bytes32,address)(bool)|$($CAST keccak PROPOSER_ROLE)|$SAFE"
  "tl.executor.safe|call|$TL|hasRole(bytes32,address)(bool)|$($CAST keccak EXECUTOR_ROLE)|$SAFE"
  "tl.canceller.safe|call|$TL|hasRole(bytes32,address)(bool)|$($CAST keccak CANCELLER_ROLE)|$SAFE"
  "tl.admin.self|call|$TL|hasRole(bytes32,address)(bool)|0x0000000000000000000000000000000000000000000000000000000000000000|$TL"
  "tl.admin.deployer|call|$TL|hasRole(bytes32,address)(bool)|0x0000000000000000000000000000000000000000000000000000000000000000|$DEPLOYER"
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

q() { # q <rpc> <kind> args...
  local rpc=$1 kind=$2; shift 2
  case $kind in
    call) "$CAST" call "$@" --block "$BLOCK" --rpc-url "$rpc" | awk '{print $1}' ;;
    nonce) "$CAST" nonce "$1" --block "$BLOCK" --rpc-url "$rpc" ;;
    ts) "$CAST" block "$1" -f timestamp --rpc-url "$rpc" ;;
  esac
}

{
  echo "block=$BLOCK"
  echo "blockHash.rpc1=$("$CAST" block "$BLOCK" -f hash --rpc-url "$RPC1")"
  echo "blockHash.rpc2=$("$CAST" block "$BLOCK" -f hash --rpc-url "$RPC2")"
} > "$OUT/readback.txt"
fail=0
for line in "${QUERIES[@]}"; do
  IFS='|' read -r label kind rest <<<"$line"
  IFS='|' read -r -a args <<<"$rest"
  a=$(q "$RPC1" "$kind" "${args[@]}"); b=$(q "$RPC2" "$kind" "${args[@]}")
  [ "$a" = "$b" ] || { echo "DISAGREE $label rpc1=$a rpc2=$b" >> "$OUT/readback.txt"; fail=1; continue; }
  echo "$label=$a" >> "$OUT/readback.txt"
done
grep -q '^blockHash.rpc1=' "$OUT/readback.txt"
h1=$(sed -n 's/^blockHash.rpc1=//p' "$OUT/readback.txt"); h2=$(sed -n 's/^blockHash.rpc2=//p' "$OUT/readback.txt")
[ "$h1" = "$h2" ] || { echo "block hash disagrees" >&2; fail=1; }

v() { sed -n "s/^$1=//p" "$OUT/readback.txt"; }
expect() { [ "$(v "$1")" = "$2" ] || { echo "MISMATCH $1 got=$(v "$1") want=$2" | tee -a "$OUT/readback.txt" >&2; fail=1; }; }
lc() { tr 'A-F' 'a-f' <<<"$1"; }
expect tl.minDelay 172800
expect tl.opState 1
expect tl.proposer.safe true
expect tl.executor.safe true
expect tl.canceller.safe true
expect tl.admin.self true
expect tl.admin.deployer false
expect ap.cap 10000000000000000000000000
expect ap.totalSupply 0
expect safe.nonce 2
expect nonce.deployer 12135
expect nonce.approver 98
expect nonce.executor 753
[ "$(lc "$(v ap.owner)")" = "$(lc $DEPLOYER)" ] || { echo "MISMATCH ap.owner" >&2; fail=1; }
[ "$(lc "$(v ap.pendingOwner)")" = "$(lc $TL)" ] || { echo "MISMATCH ap.pendingOwner" >&2; fail=1; }
eta=$(v tl.opTimestamp); ts=$(v s5b.blockTimestamp)
[ $((eta - ts)) -eq 172800 ] || { echo "MISMATCH eta-ts=$((eta - ts))" >&2; fail=1; }
echo "eta.minus.s5bTimestamp=$((eta - ts))" >> "$OUT/readback.txt"

if [ $fail -eq 0 ]; then echo "READBACK PASS" | tee "$OUT/verdict.txt"; else echo "READBACK FAIL" | tee "$OUT/verdict.txt"; exit 1; fi
