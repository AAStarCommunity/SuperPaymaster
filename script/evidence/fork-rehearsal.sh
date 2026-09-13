#!/usr/bin/env bash
# Sepolia-FORK rehearsal of the scripted runbook steps (LOCAL anvil fork only; nothing is sent to
# any public network — every forge/cast call below targets http://127.0.0.1:<port>).
#
#   fork A (step 1 ①–③, GOV-4 b):  inventory -> cancel 0xBb46 -> GOV-1-shaped timelock ->
#                                   DeployAPNTsCapped (+ simulated accept) -> real accept on the fork
#                                   (impersonated Safe, +48h) -> verify() -> re-queue
#                                   setAPNTsToken(APNTsCapped) [manual cast: NOT scripted] + read-back
#   fork B (steps 1① cancel, 3, 4–6, 5b, 7a, 7c): inventory -> cancel -> pauseOperators -> run()
#                                   (strict) -> issueCommunityToken -> configureOperatorV2 ->
#                                   unpauseOperator
#   Step 1 ④ (execute the switch to APNTsCapped + 1:1 re-deposit) is NOT scripted for APNTsCapped
#   (UpgradeToV5_5_0.executePendingAPNTs funds via the xPNTs communityOwner, which APNTsCapped does
#   not have) and is therefore not rehearsed here.
#
# Usage: script/evidence/fork-rehearsal.sh <env file holding RPC_URL (archive, never printed)> <fork block> <out dir>
set -uo pipefail
ENVFILE="$1"; FORK_BLOCK="$2"; OUT="$3"
export PATH="$HOME/.foundry/bin:$PATH"
W="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$W"
mkdir -p "$OUT"
RPC_URL_FORK="$(grep -E '^RPC_URL=' "$ENVFILE" | head -1 | cut -d= -f2- | tr -d '"'"'"' ')"
[ -n "$RPC_URL_FORK" ] || { echo "no RPC_URL in env file"; exit 2; }

OWNER=0xb5600060e6de5E11D3636731964218E53caadf0E   # SP owner (EOA) on Sepolia
ANNI=0xEcAACb915f7D92e9916f449F7ad42BD0408733c9    # operator
SAFE=0x51eDf11fDb0A4F66220eFb8efA54Eca77232E114    # governance multisig (Mycelium Safe)
SAMPLE=0x92EA8b02D34A4D5d10f0Db9Ea894e8bC72e292e8
SP=0x09DF0d2e3722EC0e401fE3819E64278a42ae4DE9
US=contracts/script/v3/UpgradeToV5_5_0.s.sol:UpgradeToV5_5_0
LOG=script/evidence/run-logged.sh
PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done; }
trap cleanup EXIT

start_fork() { # <port>
  anvil --fork-url "$RPC_URL_FORK" --fork-block-number "$FORK_BLOCK" --port "$1" --silent >/dev/null 2>&1 &
  PIDS+=($!)
  for _ in $(seq 1 60); do cast chain-id --rpc-url "http://127.0.0.1:$1" >/dev/null 2>&1 && break; sleep 1; done
  for a in $OWNER $ANNI $SAFE; do cast rpc anvil_impersonateAccount $a --rpc-url "http://127.0.0.1:$1" >/dev/null; done
  echo "fork on :$1 chainId $(cast chain-id --rpc-url http://127.0.0.1:$1) head $(cast block-number --rpc-url http://127.0.0.1:$1)"
}
bcast() { # <script file basename> [<function name>] -> latest broadcast json (forge names it <fn>-latest.json, run() -> run-latest.json)
  echo "broadcast/$1/11155111/${2:-run}-latest.json"
}
txhash() { node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).transactionHash))'; }
collect() { # <port> <out> <broadcast json>
  node script/evidence/collect-receipts.mjs "http://127.0.0.1:$1" "$2" fork-simulation --broadcast "$3"
}

# ---------------------------------------------------------------- fork A
PA=28562; RA=http://127.0.0.1:$PA
start_fork $PA
echo "== A0 inventory"
ENV=sepolia $LOG "$OUT/A0-inventory.log" forge script $US --sig 'inventory(address[])' "[$OWNER,$ANNI]" --rpc-url $RA
echo "== A1 cancel 0xBb46 (step 1 ①)"
ENV=sepolia V55_APNTS_DECISION=cancel $LOG "$OUT/A1-cancel.log" forge script $US --sig 'cancelPendingAPNTs()' --rpc-url $RA --unlocked --sender $OWNER --broadcast
collect $PA "$OUT/A1-cancel.receipts.json" "$(bcast UpgradeToV5_5_0.s.sol cancelPendingAPNTs)"
echo "== A2 GOV-1-shaped timelock (48h; proposer=canceller=executor=Safe; no admin), from the profile.default artifact"
TLART=out/TimelockController.sol/TimelockController.default.json
TLBC="$(node -e 'const j=require(process.argv[1]);const m=j.metadata;if(m.settings.evmVersion!=="cancun"||m.settings.optimizer.runs!==500)throw new Error("not a default build");console.log(j.bytecode.object)' "$W/$TLART")"
TLARGS="$(cast abi-encode 'c(uint256,address[],address[],address)' 172800 "[$SAFE]" "[$SAFE]" 0x0000000000000000000000000000000000000000)"
TLJSON="$(cast send --unlocked --from $OWNER --rpc-url $RA --json --create "$TLBC${TLARGS#0x}")"
TL="$(echo "$TLJSON" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).contractAddress))')"
TLTX="$(echo "$TLJSON" | txhash)"
printf '# command: cast send --create <%s bytecode> abi.encode(172800,[%s],[%s],0x0) --unlocked --from %s\n# timelock %s tx %s\n' "$TLART" $SAFE $SAFE $OWNER "$TL" "$TLTX" > "$OUT/A2-timelock.log"
node script/evidence/collect-receipts.mjs $RA "$OUT/A2-timelock.receipts.json" fork-simulation "timelockDeploy=$TLTX"
echo "   timelock $TL"
echo "== A3 DeployAPNTsCapped (step 1 ②), APNTS_SIMULATE_ACCEPT=true"
TIMELOCK=$TL APNTS_SIMULATE_ACCEPT=true $LOG "$OUT/A3-deploy-apnts-capped.log" forge script contracts/script/v3/DeployAPNTsCapped.s.sol:DeployAPNTsCapped --rpc-url $RA --unlocked --sender $OWNER --broadcast
collect $PA "$OUT/A3-deploy-apnts-capped.receipts.json" "$(bcast DeployAPNTsCapped.s.sol)"
TOKEN="$(node -e 'const b=require(process.argv[1]);const t=b.transactions.find(x=>x.transactionType==="CREATE");console.log(t.contractAddress)' "$W/$(bcast DeployAPNTsCapped.s.sol)")"
echo "   APNTsCapped $TOKEN"
echo "== A4 real acceptOwnership on the fork: Safe schedules, +48h, Safe executes"
cast rpc anvil_setBalance $SAFE 0x8AC7230489E80000 --rpc-url $RA >/dev/null
SALT="$(cast keccak 'APNTsCapped-1.0.0/acceptOwnership')"
ACC="$(cast calldata 'acceptOwnership()')"
TX1="$(cast send $TL 'schedule(address,uint256,bytes,bytes32,bytes32,uint256)' $TOKEN 0 $ACC 0x0000000000000000000000000000000000000000000000000000000000000000 $SALT 172800 --unlocked --from $SAFE --rpc-url $RA --json | txhash)"
cast rpc evm_increaseTime 172800 --rpc-url $RA >/dev/null; cast rpc evm_mine --rpc-url $RA >/dev/null
TX2="$(cast send $TL 'execute(address,uint256,bytes,bytes32,bytes32)' $TOKEN 0 $ACC 0x0000000000000000000000000000000000000000000000000000000000000000 $SALT --unlocked --from $SAFE --rpc-url $RA --json | txhash)"
node script/evidence/collect-receipts.mjs $RA "$OUT/A4-accept.receipts.json" fork-simulation "safeSchedule=$TX1" "safeExecuteAccept=$TX2"
$LOG "$OUT/A4-verify.log" forge script contracts/script/v3/DeployAPNTsCapped.s.sol:DeployAPNTsCapped --sig 'verify(address,address)' $TOKEN $OWNER --rpc-url $RA
echo "== A5 re-queue setAPNTsToken(APNTsCapped) (step 1 ③) — manual cast, NOT scripted"
TX3="$(cast send $SP 'setAPNTsToken(address)' $TOKEN --unlocked --from $OWNER --rpc-url $RA --json | txhash)"
node script/evidence/collect-receipts.mjs $RA "$OUT/A5-requeue.receipts.json" fork-simulation "setAPNTsToken=$TX3"
{
  echo "# read-back after A5 (cast call, block $(cast block-number --rpc-url $RA))"
  echo "pendingAPNTsToken    $(cast call $SP 'pendingAPNTsToken()(address)' --rpc-url $RA)"
  echo "pendingAPNTsTokenEta $(cast call $SP 'pendingAPNTsTokenEta()(uint256)' --rpc-url $RA)"
  echo "block.timestamp(tx)  $(cast block "$(cast receipt $TX3 blockNumber --rpc-url $RA)" --field timestamp --rpc-url $RA)   (eta must be this + 604800)"
  echo "APNTS_TOKEN          $(cast call $SP 'APNTS_TOKEN()(address)' --rpc-url $RA)"
  echo "APNTsCapped.owner    $(cast call $TOKEN 'owner()(address)' --rpc-url $RA)"
  echo "APNTsCapped.cap      $(cast call $TOKEN 'cap()(uint256)' --rpc-url $RA)"
  echo "APNTsCapped.codehash $(cast keccak "$(cast code $TOKEN --rpc-url $RA)")"
} > "$OUT/A5-readback.txt"
cat "$OUT/A5-readback.txt"

# ---------------------------------------------------------------- fork B
PB=28563; RB=http://127.0.0.1:$PB
start_fork $PB
echo "== B0 inventory"
ENV=sepolia $LOG "$OUT/B0-inventory.log" forge script $US --sig 'inventory(address[])' "[$OWNER,$ANNI]" --rpc-url $RB
echo "== B1 cancel (step 1 ①)"
ENV=sepolia V55_APNTS_DECISION=cancel $LOG "$OUT/B1-cancel.log" forge script $US --sig 'cancelPendingAPNTs()' --rpc-url $RB --unlocked --sender $OWNER --broadcast
collect $PB "$OUT/B1-cancel.receipts.json" "$(bcast UpgradeToV5_5_0.s.sol cancelPendingAPNTs)"
echo "== B3 pauseOperators (step 3)"
ENV=sepolia $LOG "$OUT/B3-pause.log" forge script $US --sig 'pauseOperators(address[])' "[$OWNER,$ANNI]" --rpc-url $RB --unlocked --sender $OWNER --broadcast
collect $PB "$OUT/B3-pause.receipts.json" "$(bcast UpgradeToV5_5_0.s.sol pauseOperators)"
echo "== B4 run() strict (steps 4 -> 5 -> 5b -> 6)"
mkdir -p cache/evidence-fork
ENV=sepolia V55_OUT_CONFIG=cache/evidence-fork/config.sepolia-fork.json V55_OPERATORS=$OWNER,$ANNI V55_SAMPLE_USERS=$ANNI,$OWNER,$SAMPLE V55_SAMPLE_OPERATOR=$ANNI \
  $LOG "$OUT/B4-run.log" forge script $US --rpc-url $RB --unlocked --sender $OWNER --broadcast
collect $PB "$OUT/B4-run.receipts.json" "$(bcast UpgradeToV5_5_0.s.sol)"
cp cache/evidence-fork/config.sepolia-fork.json "$OUT/B4-config.sepolia-fork.json"
echo "== B7a issueCommunityToken (Anni)"
ENV=sepolia V55_OUT_CONFIG=cache/evidence-fork/config.sepolia-fork.json \
  $LOG "$OUT/B7a-issue.log" forge script $US --sig 'issueCommunityToken(string,string,string,string,uint256)' 'Mycelium PNTs' PNTs Mycelium mycelium.eth 1000000000000000000 --rpc-url $RB --unlocked --sender $ANNI --broadcast
collect $PB "$OUT/B7a-issue.receipts.json" "$(bcast UpgradeToV5_5_0.s.sol issueCommunityToken)"
V2TOK="$(grep -E 'step 7a: v2 token' "$OUT/B7a-issue.log" | awk '{print $NF}')"
echo "   v2 token $V2TOK"
echo "== B7c-1 configureOperatorV2 (Anni)"
ENV=sepolia V55_OUT_CONFIG=cache/evidence-fork/config.sepolia-fork.json \
  $LOG "$OUT/B7c1-configure.log" forge script $US --sig 'configureOperatorV2(address,address)' $V2TOK $ANNI --rpc-url $RB --unlocked --sender $ANNI --broadcast
collect $PB "$OUT/B7c1-configure.receipts.json" "$(bcast UpgradeToV5_5_0.s.sol configureOperatorV2)"
echo "== B7c-2 unpauseOperator (owner)"
ENV=sepolia V55_OUT_CONFIG=cache/evidence-fork/config.sepolia-fork.json \
  $LOG "$OUT/B7c2-unpause.log" forge script $US --sig 'unpauseOperator(address)' $ANNI --rpc-url $RB --unlocked --sender $OWNER --broadcast
collect $PB "$OUT/B7c2-unpause.receipts.json" "$(bcast UpgradeToV5_5_0.s.sol unpauseOperator)"
{
  echo "# read-back after B7c-2 (cast call, block $(cast block-number --rpc-url $RB))"
  echo "SP.version            $(cast call $SP 'version()(string)' --rpc-url $RB)"
  echo "v2 token creditPolicy $(cast call $V2TOK 'creditPolicy()(uint8)' --rpc-url $RB)   (0 = OFF)"
  echo "EP depositInfo(SP)    $(cast call 0x0000000071727De22E5E9d8BAf0edAc6f37da032 'getDepositInfo(address)((uint256,bool,uint112,uint32,uint48))' $SP --rpc-url $RB)"
  echo "operators(Anni) raw   $(cast call $SP 'operators(address)' $ANNI --rpc-url $RB)"
} > "$OUT/B7-readback.txt"
cat "$OUT/B7-readback.txt"
echo "done"
