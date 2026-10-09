#!/usr/bin/env bash
# Instrument control for must_fail (the negative-control comparator of a2-full-rehearsal.sh): the
# functions are extracted VERBATIM from the committed script and run against a plain local anvil with a
# deployed OZ TimelockController (no fork, no public RPC). It must say PASS only for the exact revert data.
set -u
export PATH="$HOME/.foundry/bin:$PATH"
# repo root: this file lives in docs/design/aoa-balance-mode/data/d5b/<archive>/ (override with A2_REPO)
W="${A2_REPO:-$(cd "$(dirname "$0")/../../../../../.." && pwd)}"
S=$W/script/evidence/a2-full-rehearsal.sh
echo "# must_fail self-test; script $(git -C "$W" rev-parse HEAD) sha256 $(shasum -a 256 "$S" | awk '{print $1}')"
OUT=$(mktemp -d "${TMPDIR:-/tmp}/mfst.XXXX")
PORT=28702; RPC=http://127.0.0.1:$PORT
anvil --port $PORT --silent >/dev/null 2>&1 &
APID=$!
trap 'kill $APID 2>/dev/null; rm -rf "$OUT"' EXIT
for i in $(seq 1 30); do cast chain-id --rpc-url $RPC >/dev/null 2>&1 && break; sleep 0.5; done
FAILURES=0
# extract helper definitions verbatim (rlog, bn, lc, fail, must_fail, errdata) from the script
eval "$(sed -n '/^rlog() {/p; /^bn() {/p; /^lc() {/p; /^fail() {/p' "$S")"
eval "$(awk '/^must_fail\(\) \{/{f=1} f{print} f && /^}$/{exit}' "$S")"
eval "$(sed -n '/^errdata() {/p' "$S")"
NEG_N=0
A=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
B=0x70997970C51812dc3Ae63dc8C504c9E07B5c8E8b
TLART=$W/out/TimelockController.sol/TimelockController.default.json
BC=$(jq -r .bytecode.object "$TLART")
ARGS=$(cast abi-encode 'c(uint256,address[],address[],address)' 100 "[$A]" "[$A]" 0x0000000000000000000000000000000000000000)
cast rpc anvil_impersonateAccount $B --rpc-url $RPC >/dev/null; cast rpc anvil_setBalance $B 0x56BC75E2D63100000 --rpc-url $RPC >/dev/null; cast rpc anvil_impersonateAccount $A --rpc-url $RPC >/dev/null
TL=$(cast send --unlocked --from $A --rpc-url $RPC --json --create "$BC${ARGS#0x}" | jq -r .contractAddress)
PROP=$(cast keccak PROPOSER_ROLE)
CALL=(cast send $TL 'schedule(address,uint256,bytes,bytes32,bytes32,uint256)' $A 0 0x 0x0000000000000000000000000000000000000000000000000000000000000000 0x0000000000000000000000000000000000000000000000000000000000000001 100 --unlocked --from $B --rpc-url $RPC)
probe() { # <label> <expected verdict PASS|FAIL> <expect> <cmd...>
  local label="$1" want="$2" before="$FAILURES"; shift 2
  ( must_fail "$label" "$@" ) >/dev/null 2>&1; local rc=$?
  local got; got=$(tail -1 "$OUT/neg-controls.jsonl" 2>/dev/null | jq -r .result)
  [ $rc -ne 0 ] && got="FAIL(exit $rc)"
  echo "probe [$label]: must_fail verdict=$got wanted=$want -> $([ "${got%%(*}" = "$want" ] && echo OK || echo WRONG)"
}
probe "exact AccessControlUnauthorizedAccount(B, PROPOSER)" PASS "$(errdata 'AccessControlUnauthorizedAccount(address,bytes32)' $B $PROP)" "${CALL[@]}"
probe "same selector, wrong account (A instead of B)" FAIL "$(errdata 'AccessControlUnauthorizedAccount(address,bytes32)' $A $PROP)" "${CALL[@]}"
probe "same selector, wrong role (EXECUTOR)" FAIL "$(errdata 'AccessControlUnauthorizedAccount(address,bytes32)' $B "$(cast keccak EXECUTOR_ROLE)")" "${CALL[@]}"
probe "different selector (OwnableUnauthorizedAccount(B))" FAIL "$(errdata 'OwnableUnauthorizedAccount(address)' $B)" "${CALL[@]}"
probe "bare selector prefix only (0xe2517d3f)" FAIL 0xe2517d3f "${CALL[@]}"
probe "command that SUCCEEDS (A is proposer)" FAIL "$(errdata 'AccessControlUnauthorizedAccount(address,bytes32)' $A $PROP)" cast send $TL 'schedule(address,uint256,bytes,bytes32,bytes32,uint256)' $A 0 0x 0x0000000000000000000000000000000000000000000000000000000000000000 0x0000000000000000000000000000000000000000000000000000000000000002 100 --unlocked --from $A --rpc-url $RPC
probe "tooling error, no revert data (bad signature)" FAIL "$(errdata 'AccessControlUnauthorizedAccount(address,bytes32)' $B $PROP)" cast send $TL 'nosuchfn(' --unlocked --from $B --rpc-url $RPC
echo "--- neg-controls.jsonl rows written by the extracted must_fail:"
cat "$OUT/neg-controls.jsonl"
