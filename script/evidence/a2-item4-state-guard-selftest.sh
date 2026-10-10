#!/usr/bin/env bash
# Self-test of the stage-D getter-snapshot guard (sp_state / sp_getter / state_ok) of a2-full-rehearsal.sh,
# added after Codex #462 round 2, WITHOUT a full `all` run. It loads the EXACT function bodies from
# a2-full-rehearsal.sh (line ranges located by their definitions, so the code under test is the committed
# script's, not a copy), then:
#   1. runs state_neg_controls (the same negative controls the full run executes in D0) against a short-lived
#      LOCAL anvil fork of Sepolia: injected EMPTY getter and injected FAILED getter -> sp_state returns failure;
#      healthy snapshot accepted; the Codex reproduction (operators(OWNER) blank in BOTH snapshots) rejected;
#   2. applies the NEW state_ok to the 4 archived getter snapshots of a given archive directory (post-hoc check).
# LOCAL ONLY: the public RPC is used only as anvil --fork-url; nothing is broadcast (one deploy tx on the local fork).
# Usage: script/evidence/a2-item4-state-guard-selftest.sh <env file with RPC_URL> <fork block> <archive dir> <out dir>
set -uo pipefail
ENVFILE="$1"; FORK_BLOCK="$2"; ARCH="$3"; OUT="$4"
export PATH="$HOME/.foundry/bin:$PATH"
W="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$W"
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"; : > "$OUT/rehearsal.log"
S=script/evidence/a2-full-rehearsal.sh
fn_range() { awk -v s="$1" -v e="$2" 'index($0,s)==1{f=1} f&&index($0,e)==1{exit} f' "$S"; }
# helpers (rlog..errdata) and the guard block (OPSIG..state_neg_controls), verbatim from the committed script
eval "$(fn_range 'rlog() {' 'rb() {')"
eval "$(fn_range 'check() {' 'sendtx() {' | sed '/^LAST_TX=""/d')"
eval "$(fn_range 'NEG_N=0' 'errdata() {')"
eval "$(fn_range "OPSIG='operators" 'fresh_price() {')"
for f in rlog fail check must_fail sp_state sp_getter state_ok sp_state_inject_blank sp_state_inject_fail state_neg_controls; do
  [ "$(type -t $f)" = function ] || { echo "missing function $f"; exit 2; }
done
echo "# script under test: $S @ $(git rev-parse HEAD)$(git diff --quiet HEAD -- "$S" || echo ' (+ uncommitted)')" | tee -a "$OUT/rehearsal.log"
FAILURES=0
RPC_URL_FORK="$(grep -E '^RPC_URL=' "$ENVFILE" | head -1 | cut -d= -f2- | tr -d "\"' ")"
PORT=28634; RPC="http://127.0.0.1:$PORT"
anvil --fork-url "$RPC_URL_FORK" --fork-block-number "$FORK_BLOCK" --port $PORT --silent > /dev/null 2>&1 & AP=$!
trap 'kill $AP 2>/dev/null; rm -f "$OUT/.neg.tmp" "$OUT/.sendtx.err"' EXIT
for _ in $(seq 1 60); do cast chain-id --rpc-url $RPC >/dev/null 2>&1 && break; sleep 1; done
SP=0x09DF0d2e3722EC0e401fE3819E64278a42ae4DE9; EP=0x0000000071727De22E5E9d8BAf0edAc6f37da032
OWNER=0xb5600060e6de5E11D3636731964218E53caadf0E; ANNI=0xEcAACb915f7D92e9916f449F7ad42BD0408733c9
CAPPED=0x696A73701b104c6cCBbAadDD2216788ea08EaB89   # live aPNTs stands in for APNTsCapped (balanceOf(SP) only)
rlog "  local anvil fork of Sepolia @$FORK_BLOCK (forkBlockHash $(cast block $FORK_BLOCK --field hash --rpc-url $RPC)); live SP $(cast call $SP 'version()(string)' --rpc-url $RPC)"
# The live SP at this block is 5.4.2, which has no pendingOwner()/guardian()/paused(): a first attempt of this
# self-test showed sp_state correctly FAILING on them. To give the positive control a 5.5.0 surface, deploy the
# profile.default (rc.2) SuperPaymaster impl on the fork and point the proxy's ERC-1967 slot at it with
# anvil_setStorageAt (fork-only cheat; no tx to any public network; storage untouched otherwise).
SPART=out/SuperPaymaster.sol/SuperPaymaster.json
cast rpc anvil_impersonateAccount $OWNER --rpc-url $RPC >/dev/null; cast rpc anvil_setBalance $OWNER 0x56BC75E2D63100000 --rpc-url $RPC >/dev/null
ARGS=$(cast abi-encode 'c(address,address,address)' "$(cast call $SP 'entryPoint()(address)' --rpc-url $RPC)" "$(cast call $SP 'REGISTRY()(address)' --rpc-url $RPC)" "$(cast call $SP 'ETH_USD_PRICE_FEED()(address)' --rpc-url $RPC)")
IMPL=$(cast send --unlocked --from $OWNER --rpc-url $RPC --json --create "$(jq -r .bytecode.object $SPART)${ARGS#0x}" | jq -r .contractAddress)
cast rpc anvil_setStorageAt $SP 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc "0x000000000000000000000000${IMPL#0x}" --rpc-url $RPC >/dev/null
cast rpc evm_mine --rpc-url $RPC >/dev/null
rlog "  fork-only: proxy impl slot -> rc.2 build $IMPL (runtime keccak $(cast keccak "$(jq -r .deployedBytecode.object $SPART)")); SP now reports $(cast call $SP 'version()(string)' --rpc-url $RPC)"
rlog "== 1. negative controls (state_neg_controls, verbatim from the script) =="
state_neg_controls
rlog "== 2. post-hoc: NEW state_ok applied to the archived getter snapshots of $ARCH =="
for f in D5-state-before D5-state-after D6-state-before D6-state-after; do
  p="$ARCH/$f.txt"
  r=$(state_ok "$p")
  rlog "  $f.txt: state_ok -> $r; ' = ' lines $(grep -c ' = ' "$p"); blank values $(grep -cE ' = *$' "$p"); error/revert lines $(grep -ciE 'error|revert' "$p"); header: $(head -1 "$p")"
  check "post-hoc $f.txt accepted by the NEW state_ok" "$r" valid
done
check "post-hoc D5 getters identical before/after" "$(diff <(tail -n +2 "$ARCH/D5-state-before.txt") <(tail -n +2 "$ARCH/D5-state-after.txt") >/dev/null && echo identical || echo DIFFERENT)" identical
check "post-hoc D6 getters identical before/after" "$(diff <(tail -n +2 "$ARCH/D6-state-before.txt") <(tail -n +2 "$ARCH/D6-state-after.txt") >/dev/null && echo identical || echo DIFFERENT)" identical
rlog "  CHECK lines: $(grep -c 'CHECK \[.*\] PASS' "$OUT/rehearsal.log") PASS, $(grep -c 'CHECK \[.*\] FAIL' "$OUT/rehearsal.log") FAIL; negative controls $NEG_N"
if [ "$FAILURES" -eq 0 ]; then rlog "SELFTEST COMPLETED WITH 0 FAILURES"; else rlog "SELFTEST FAILED: $FAILURES"; exit 1; fi
