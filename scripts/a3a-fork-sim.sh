#!/usr/bin/env bash
# A3a precheck: simulate runbook 03-final-spec §6 step 1 ①–③ (+ GOV-1 timelock for APNTsCapped)
# on a LOCAL anvil fork of Sepolia at a pinned block, and record every transaction's exact payload.
# NOTHING here is sent to a public network: the only writes go to http://127.0.0.1:$PORT.
# Usage: scripts/a3a-fork-sim.sh <env file with RPC_URL> <fork block> <out dir>
set -euo pipefail
ENVFILE="$1"; FORK_BLOCK="$2"; OUT="$3"
export PATH="$HOME/.foundry/bin:$PATH"
W="$(cd "$(dirname "$0")/.." && pwd)"; cd "$W"; mkdir -p "$OUT"
UP="$(grep -E '^RPC_URL=' "$ENVFILE" | head -1 | cut -d= -f2- | tr -d '"'"'"' ')"
PORT=28591; RPC="http://127.0.0.1:$PORT"
case "$RPC" in http://127.0.0.1:*) ;; *) echo "refusing: RPC is not local"; exit 3;; esac

OWNER=0xb5600060e6de5E11D3636731964218E53caadf0E
SAFE=0x51eDf11fDb0A4F66220eFb8efA54Eca77232E114
SP=0x09DF0d2e3722EC0e401fE3819E64278a42ae4DE9
ZERO32=0x0000000000000000000000000000000000000000000000000000000000000000
LOG="$OUT/sim.log"; : > "$LOG"
say() { echo "$*" | tee -a "$LOG"; }
fail() { say "!!! $*"; exit 1; }

anvil --fork-url "$UP" --fork-block-number "$FORK_BLOCK" --port "$PORT" --silent > "$OUT/anvil.log" 2>&1 &
APID=$!; trap 'kill $APID 2>/dev/null || true' EXIT
for _ in $(seq 1 60); do cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 1; done
say "fork: block $(cast block-number --rpc-url $RPC) chainId $(cast chain-id --rpc-url $RPC) (local anvil, pinned $FORK_BLOCK)"
cast rpc anvil_impersonateAccount $OWNER --rpc-url $RPC >/dev/null
cast rpc anvil_impersonateAccount $SAFE --rpc-url $RPC >/dev/null

rcpt() { # <label> <txhash> -> saves receipt + tx, prints gasUsed
  cast receipt "$2" --rpc-url $RPC --json > "$OUT/$1.receipt.json"
  cast tx "$2" --rpc-url $RPC --json > "$OUT/$1.tx.json"
  local st; st=$(node -e 'console.log(require(process.argv[1]).status)' "$W/$OUT/$1.receipt.json")
  [ "$st" = "0x1" ] || [ "$st" = "1" ] || fail "$1 reverted (status $st)"
  say "  $1: tx $2 gasUsed $(node -e 'console.log(BigInt(require(process.argv[1]).gasUsed).toString())' "$W/$OUT/$1.receipt.json")"
}

say "== pre: SP pendingAPNTsToken=$(cast call $SP 'pendingAPNTsToken()(address)' --rpc-url $RPC) eta=$(cast call $SP 'pendingAPNTsTokenEta()(uint256)' --rpc-url $RPC) APNTS_TOKEN=$(cast call $SP 'APNTS_TOKEN()(address)' --rpc-url $RPC)"
say "   deployer nonce $(cast nonce $OWNER --rpc-url $RPC)"

# ---- S1 (runbook 1①): cancel the pending 0xBb46… switch -------------------------------------
H=$(cast send $SP 'cancelAPNTsTokenChange()' --unlocked --from $OWNER --rpc-url $RPC --json | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).transactionHash))')
rcpt S1-cancel "$H"
[ "$(cast call $SP 'pendingAPNTsToken()(address)' --rpc-url $RPC)" = "0x0000000000000000000000000000000000000000" ] || fail "S1 read-back pendingAPNTsToken != 0"
[ "$(cast call $SP 'pendingAPNTsTokenEta()(uint256)' --rpc-url $RPC)" = "0" ] || fail "S1 read-back eta != 0"
say "  S1 read-back OK: pending cleared, APNTS_TOKEN=$(cast call $SP 'APNTS_TOKEN()(address)' --rpc-url $RPC)"

# ---- S2: deploy a GOV-1-shaped TimelockController (172800 s; proposer=canceller=executor=SAFE; admin=0)
TLBC="$(node -e 'const j=require(process.argv[1]);const m=j.metadata;if(m.settings.evmVersion!=="cancun"||m.settings.optimizer.runs!==500)throw new Error("not a default build");console.log(j.bytecode.object)' "$W/out/TimelockController.sol/TimelockController.default.json")"
TLARGS="$(cast abi-encode 'c(uint256,address[],address[],address)' 172800 "[$SAFE]" "[$SAFE]" 0x0000000000000000000000000000000000000000)"
echo "${TLBC}${TLARGS#0x}" > "$OUT/S2-timelock.initcode.hex"
PRED_TL=$(cast compute-address $OWNER --nonce "$(cast nonce $OWNER --rpc-url $RPC)" --rpc-url $RPC | awk '{print $NF}')
H=$(cast send --unlocked --from $OWNER --rpc-url $RPC --json --create "${TLBC}${TLARGS#0x}" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).transactionHash))')
rcpt S2-deploy-timelock "$H"
NEW_TL=$(node -e 'console.log(require(process.argv[1]).contractAddress)' "$W/$OUT/S2-deploy-timelock.receipt.json")
NEW_TL=$(cast to-check-sum-address "$NEW_TL")
[ "$(echo $NEW_TL | tr A-F a-f)" = "$(echo $PRED_TL | tr A-F a-f)" ] || fail "S2 predicted address $PRED_TL != actual $NEW_TL"
for R in PROPOSER_ROLE CANCELLER_ROLE EXECUTOR_ROLE; do
  [ "$(cast call $NEW_TL 'hasRole(bytes32,address)(bool)' $(cast keccak $R) $SAFE --rpc-url $RPC)" = "true" ] || fail "S2 SAFE lacks $R"
  [ "$(cast call $NEW_TL 'hasRole(bytes32,address)(bool)' $(cast keccak $R) $OWNER --rpc-url $RPC)" = "false" ] || fail "S2 EOA holds $R"
done
[ "$(cast call $NEW_TL 'hasRole(bytes32,address)(bool)' $ZERO32 $OWNER --rpc-url $RPC)" = "false" ] || fail "S2 EOA holds DEFAULT_ADMIN"
[ "$(cast call $NEW_TL 'getMinDelay()(uint256)' --rpc-url $RPC | awk '{print $1}')" = "172800" ] || fail "S2 minDelay"
say "  S2 read-back OK: TimelockController $NEW_TL (predicted $PRED_TL) minDelay 172800, SAFE=proposer/canceller/executor, EOA no role, no admin"

# ---- S3+S4 (runbook 1②): DeployAPNTsCapped = CREATE APNTsCapped + transferOwnership(NEW_TL) ----
ENV=sepolia TIMELOCK=$NEW_TL forge script contracts/script/v3/DeployAPNTsCapped.s.sol:DeployAPNTsCapped \
  --rpc-url $RPC --unlocked --sender $OWNER --broadcast --slow > "$OUT/S3S4-deploy-apnts-capped.log" 2>&1 || fail "S3/S4 DeployAPNTsCapped failed, see log"
BJ=$(ls -t broadcast/DeployAPNTsCapped.s.sol/11155111/run-latest.json)
cp "$BJ" "$OUT/S3S4-broadcast.json"
CAPPED=$(grep -oE "\[artifact\] default artifact OK: APNTsCapped 0x[0-9a-fA-F]{40}" "$OUT/S3S4-deploy-apnts-capped.log" | awk '{print $NF}')
CAPPED=$(cast to-check-sum-address "$CAPPED")
[ -n "$CAPPED" ] || fail "S3 could not extract APNTsCapped address"
for i in 0 1; do
  H=$(node -e 'console.log(require(process.argv[1]).transactions[+process.argv[2]].hash)' "$W/$OUT/S3S4-broadcast.json" $i)
  rcpt "S$((3+i))-$( [ $i = 0 ] && echo deploy-apnts-capped || echo transfer-ownership)" "$H"
done
say "  S3/S4 read-back: APNTsCapped $CAPPED owner=$(cast call $CAPPED 'owner()(address)' --rpc-url $RPC) pendingOwner=$(cast call $CAPPED 'pendingOwner()(address)' --rpc-url $RPC) minter=$(cast call $CAPPED 'minter()(address)' --rpc-url $RPC) capGuardian=$(cast call $CAPPED 'capGuardian()(address)' --rpc-url $RPC) cap=$(cast call $CAPPED 'cap()(uint256)' --rpc-url $RPC | awk '{print $1}') totalSupply=$(cast call $CAPPED 'totalSupply()(uint256)' --rpc-url $RPC | awk '{print $1}') version=$(cast call $CAPPED 'version()(string)' --rpc-url $RPC)"
[ "$(cast call $CAPPED 'pendingOwner()(address)' --rpc-url $RPC)" = "$NEW_TL" ] || fail "S4 pendingOwner != NEW_TL"

# ---- S5 (Safe tx): NEW_TL.schedule(APNTsCapped, 0, acceptOwnership(), 0, salt, 172800) ----------
ACC=$(cast calldata "acceptOwnership()")
SALT=$(cast keccak "APNTsCapped-1.0.0/acceptOwnership")
SCHED=$(cast calldata 'schedule(address,uint256,bytes,bytes32,bytes32,uint256)' $CAPPED 0 $ACC $ZERO32 $SALT 172800)
EXEC=$(cast calldata 'execute(address,uint256,bytes,bytes32,bytes32)' $CAPPED 0 $ACC $ZERO32 $SALT)
echo "$SCHED" > "$OUT/S5-schedule.calldata"; echo "$EXEC" > "$OUT/S6-execute.calldata"
OPID=$(cast call $NEW_TL 'hashOperation(address,uint256,bytes,bytes32,bytes32)(bytes32)' $CAPPED 0 $ACC $ZERO32 $SALT --rpc-url $RPC)
H=$(cast send $NEW_TL "$SCHED" --unlocked --from $SAFE --rpc-url $RPC --json | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).transactionHash))')
rcpt S5-safe-schedule "$H"
[ "$(cast call $NEW_TL 'isOperationPending(bytes32)(bool)' $OPID --rpc-url $RPC)" = "true" ] || fail "S5 operation not pending"
TS5=$(cast block latest --field timestamp --rpc-url $RPC)
say "  S5 read-back OK: operation $OPID pending, readyAt=$(cast call $NEW_TL 'getTimestamp(bytes32)(uint256)' $OPID --rpc-url $RPC | awk '{print $1}') (= schedule block ts $TS5 + 172800)"

# negative control: execute before 48h must revert
if cast send $NEW_TL "$EXEC" --unlocked --from $SAFE --rpc-url $RPC >/dev/null 2>"$OUT/neg-early-execute.err"; then fail "NEGATIVE CONTROL: execute before 48h succeeded"; fi
say "  negative OK: execute before 48h reverted ($(grep -oE 'TimelockUnexpectedOperationState|revert[^,]{0,80}' "$OUT/neg-early-execute.err" | head -1))"
# negative control: a non-proposer (the EOA) cannot schedule on the new timelock
if cast send $NEW_TL "$SCHED" --unlocked --from $OWNER --rpc-url $RPC >/dev/null 2>"$OUT/neg-eoa-schedule.err"; then fail "NEGATIVE CONTROL: EOA scheduled"; fi
say "  negative OK: EOA schedule reverted ($(grep -oE 'AccessControlUnauthorizedAccount|revert[^,]{0,80}' "$OUT/neg-eoa-schedule.err" | head -1))"

cast rpc evm_increaseTime 172800 --rpc-url $RPC >/dev/null; cast rpc evm_mine --rpc-url $RPC >/dev/null

# ---- S6 (Safe tx): NEW_TL.execute(...) -> APNTsCapped.acceptOwnership() -----------------------
H=$(cast send $NEW_TL "$EXEC" --unlocked --from $SAFE --rpc-url $RPC --json | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).transactionHash))')
rcpt S6-safe-execute "$H"
[ "$(cast call $CAPPED 'owner()(address)' --rpc-url $RPC)" = "$NEW_TL" ] || fail "S6 owner != NEW_TL"
[ "$(cast call $CAPPED 'pendingOwner()(address)' --rpc-url $RPC)" = "0x0000000000000000000000000000000000000000" ] || fail "S6 pendingOwner != 0"
say "  S6 read-back OK: APNTsCapped owner=$NEW_TL pendingOwner=0"
ENV=sepolia TIMELOCK=$NEW_TL forge script contracts/script/v3/DeployAPNTsCapped.s.sol:DeployAPNTsCapped --sig 'verify(address,address)' $CAPPED $OWNER --rpc-url $RPC > "$OUT/S6-verify.log" 2>&1 || fail "S6 DeployAPNTsCapped.verify failed, see $OUT/S6-verify.log"
grep -q '=== verify: ALL PASS ===' "$OUT/S6-verify.log" || fail "S6 DeployAPNTsCapped.verify did not print ALL PASS"
say "  S6 DeployAPNTsCapped.verify: ALL PASS"

# ---- S7 (runbook 1③): queue SP.setAPNTsToken(APNTsCapped), ETA = block ts + 7d ------------------
ENV=sepolia V55_APNTS_DECISION=queue forge script contracts/script/v3/UpgradeToV5_5_0.s.sol:UpgradeToV5_5_0 --sig 'queueAPNTs(address)' $CAPPED \
  --rpc-url $RPC --unlocked --sender $OWNER --broadcast --slow > "$OUT/S7-queue.log" 2>&1 || fail "S7 queueAPNTs failed, see log"
cp "$(ls -t broadcast/UpgradeToV5_5_0.s.sol/11155111/queueAPNTs-latest.json 2>/dev/null || ls -t broadcast/UpgradeToV5_5_0.s.sol/11155111/run-latest.json)" "$OUT/S7-broadcast.json"
H=$(node -e 'console.log(require(process.argv[1]).transactions[0].hash)' "$W/$OUT/S7-broadcast.json")
rcpt S7-queue "$H"
BLK=$(node -e 'console.log(BigInt(require(process.argv[1]).blockNumber).toString())' "$W/$OUT/S7-queue.receipt.json")
QTS=$(cast block $BLK --field timestamp --rpc-url $RPC)
ETA=$(cast call $SP 'pendingAPNTsTokenEta()(uint256)' --rpc-url $RPC | awk '{print $1}')
[ "$(cast call $SP 'pendingAPNTsToken()(address)' --rpc-url $RPC)" = "$CAPPED" ] || fail "S7 pendingAPNTsToken != APNTsCapped"
[ "$ETA" = "$((QTS + 604800))" ] || fail "S7 eta $ETA != queue ts $QTS + 604800"
say "  S7 read-back OK: pendingAPNTsToken=$CAPPED eta=$ETA (= queue block ts $QTS + 604800); APNTS_TOKEN unchanged=$(cast call $SP 'APNTS_TOKEN()(address)' --rpc-url $RPC)"
# negative control: executeAPNTsTokenChange before ETA must revert (and it is NOT part of A3a anyway)
if cast send $SP 'executeAPNTsTokenChange()' --unlocked --from $OWNER --rpc-url $RPC >/dev/null 2>"$OUT/neg-early-switch.err"; then fail "NEGATIVE CONTROL: switch executed before ETA"; fi
say "  negative OK: executeAPNTsTokenChange before ETA reverted (A3b is out of scope)"

node -e '
const fs=require("fs"),o=process.argv[1];
console.log(JSON.stringify({newTimelock:process.argv[2],apntsCapped:process.argv[3],acceptOperationId:process.argv[4],acceptSalt:process.argv[5],queueBlockTs:+process.argv[6],eta:+process.argv[7]},null,1));
' "$OUT" "$NEW_TL" "$CAPPED" "$OPID" "$SALT" "$QTS" "$ETA" > "$OUT/addresses.json"
say "A3a FORK SIMULATION OK (local only; nothing broadcast to a public network)"
