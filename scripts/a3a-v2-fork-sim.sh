#!/usr/bin/env bash
# A3a precheck v2: simulate runbook 03-final-spec §6 step 1 ①–③ (+ the Safe-only GOV-1 timelock that
# becomes the single canonical timelock) on a LOCAL anvil fork of Sepolia at a pinned block.
#
# Differences from v1 (scripts/a3a-fork-sim.sh, now obsolete):
#   * S5/S6 go through the REAL Safe.execTransaction (2-of-3): one owner pre-approves the safeTxHash
#     with approveHash(), a second owner executes with both signatures in ascending-owner order.
#     The Safe address itself is NEVER impersonated for a state-changing call.
#   * Every transaction re-reads its sender nonce (and the Safe nonce) first and aborts on mismatch.
#   * The timelock's role member sets are proven EXACT (event history + hasRole), not point-checked.
#   * Negative controls for the Safe wrapper (bad signatures, early execute via the Safe) and the
#     timelock (non-Safe proposer / executor).
#
# NOTHING here is sent to a public network: the only writes go to http://127.0.0.1:$PORT.
# Usage: scripts/a3a-v2-fork-sim.sh <env file with RPC_URL> <fork block> <out dir> <deployer nonce> <safe nonce>
set -euo pipefail
ENVFILE="$1"; FORK_BLOCK="$2"; OUT="$3"; N0="$4"; S0="$5"
export PATH="$HOME/.foundry/bin:$PATH"
W="$(cd "$(dirname "$0")/.." && pwd)"; cd "$W"; mkdir -p "$OUT"
UP="$(grep -E '^RPC_URL=' "$ENVFILE" | head -1 | cut -d= -f2- | tr -d '"'"'"' ')"
PORT=28592; RPC="http://127.0.0.1:$PORT"
case "$RPC" in http://127.0.0.1:*) ;; *) echo "refusing: RPC is not local"; exit 3;; esac

EOA=0xb5600060e6de5E11D3636731964218E53caadf0E
SAFE=0x51eDf11fDb0A4F66220eFb8efA54Eca77232E114
SP=0x09DF0d2e3722EC0e401fE3819E64278a42ae4DE9
OLD_TL=0x86C86c789EDc099801cc6a5F48334F1D67dC9564
# Safe owners (ascending address order — Safe requires signatures sorted by owner address)
OA=0x871608cBA092105b91e91295A1d79fFC539BFb48   # executor of S5b/S6b (signs by being msg.sender)
OB=0x8c3499252232105A1615767C459DB9BBbf1273D6   # approver of S5a/S6a (approveHash)
OC=0xBB05d2E9890BceC6141e40A1066bf8927169b75E   # used only in negative controls
Z=0x0000000000000000000000000000000000000000
ZERO32=0x0000000000000000000000000000000000000000000000000000000000000000
LOG="$OUT/sim.log"; : > "$LOG"; : > "$OUT/steps.ndjson"; : > "$OUT/negatives.ndjson"
say() { echo "$*" | tee -a "$LOG"; }
fail() { say "!!! ABORT: $*"; exit 1; }
lc() { echo "$1" | tr 'A-F' 'a-f'; }

anvil --fork-url "$UP" --fork-block-number "$FORK_BLOCK" --port "$PORT" --silent > "$OUT/anvil.log" 2>&1 &
APID=$!; trap 'rc=$?; kill $APID 2>/dev/null; exit $rc' EXIT
for _ in $(seq 1 60); do cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 1; done
[ "$(cast block-number --rpc-url $RPC)" = "$FORK_BLOCK" ] || fail "fork head != pinned block $FORK_BLOCK"
say "fork: block $FORK_BLOCK chainId $(cast chain-id --rpc-url $RPC) (local anvil :$PORT); expected deployer nonce $N0, Safe nonce $S0"
for a in $EOA $OA $OB $OC; do cast rpc anvil_impersonateAccount $a --rpc-url $RPC >/dev/null; done

nonce_of() { cast nonce "$1" --rpc-url $RPC; }
safe_nonce() { cast call $SAFE 'nonce()(uint256)' --rpc-url $RPC | awk '{print $1}'; }
# per-tx abort rule: re-read the sender nonce (and the Safe nonce) before EVERY transaction
expect_nonce() { local got; got=$(nonce_of "$1"); [ "$got" = "$2" ] || fail "nonce of $1 is $got, packet expects $2 — addresses/hashes are invalid, regenerate the packet"; }
expect_safe_nonce() { local got; got=$(safe_nonce); [ "$got" = "$1" ] || fail "Safe nonce is $got, packet expects $1 — safeTxHash is invalid, regenerate"; }
txhash() { node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).transactionHash))'; }

# record <label> <txhash> <sender> <senderNonceBefore> <safeNonceBefore>
record() {
  local L="$1" H="$2" FROM="$3" NB="$4" SB="$5"
  cast receipt "$H" --rpc-url $RPC --json > "$OUT/$L.receipt.json"
  cast tx "$H" --rpc-url $RPC --json > "$OUT/$L.tx.json"
  local st; st=$(node -e 'console.log(require(process.argv[1]).status)' "$W/$OUT/$L.receipt.json")
  [ "$st" = "0x1" ] || [ "$st" = "1" ] || fail "$L reverted (status $st)"
  local NA SA G BN TS
  # the tx itself must carry exactly the nonce the packet planned; the post-nonce is the tx nonce + 1
  # (S3/S4 come from one forge script, so the live nonce is read before both and checked per tx here)
  local TXN; TXN=$(node -e 'console.log(BigInt(require(process.argv[1]).nonce).toString())' "$W/$OUT/$L.tx.json")
  [ "$TXN" = "$NB" ] || fail "$L: tx nonce $TXN != planned $NB"
  NA=$((TXN + 1)); SA=$(safe_nonce)
  [ "$(nonce_of "$FROM")" -ge "$NA" ] || fail "$L: live sender nonce below $NA after the tx"
  G=$(node -e 'console.log(BigInt(require(process.argv[1]).gasUsed).toString())' "$W/$OUT/$L.receipt.json")
  BN=$(node -e 'console.log(BigInt(require(process.argv[1]).blockNumber).toString())' "$W/$OUT/$L.receipt.json")
  TS=$(cast block "$BN" --field timestamp --rpc-url $RPC)
  echo "{\"label\":\"$L\",\"tx\":\"$H\",\"from\":\"$FROM\",\"senderNonceBefore\":$NB,\"senderNonceAfter\":$NA,\"safeNonceBefore\":$SB,\"safeNonceAfter\":$SA,\"gasUsed\":$G,\"block\":$BN,\"timestamp\":$TS}" >> "$OUT/steps.ndjson"
  say "  $L: tx $H from $FROM nonce ${NB}→$NA, Safe nonce ${SB}→$SA, gasUsed $G, block $BN ts $TS"
}
# send <label> <from> <to|--create> <calldata|initcode>
send() {
  local L="$1" FROM="$2" TO="$3" DATA="$4" NB SB H
  NB=$(nonce_of "$FROM"); SB=$(safe_nonce)
  if [ "$TO" = "--create" ]; then H=$(cast send --unlocked --from "$FROM" --rpc-url $RPC --json --create "$DATA" | txhash)
  else H=$(cast send "$TO" "$DATA" --unlocked --from "$FROM" --rpc-url $RPC --json | txhash); fi
  record "$L" "$H" "$FROM" "$NB" "$SB"
}
# negative <label> <expected revert substring> <from> <to> <calldata>  — must revert, nonces must not move
negative() {
  local L="$1" EXP="$2" FROM="$3" TO="$4" DATA="$5" NB SB
  NB=$(nonce_of "$FROM"); SB=$(safe_nonce)
  if cast send "$TO" "$DATA" --unlocked --from "$FROM" --rpc-url $RPC >/dev/null 2>"$OUT/neg-$L.err"; then fail "NEGATIVE CONTROL $L: transaction succeeded"; fi
  grep -q -- "$EXP" "$OUT/neg-$L.err" || fail "NEGATIVE CONTROL $L: reverted, but not with $EXP (see neg-$L.err)"
  [ "$(nonce_of "$FROM")" = "$NB" ] || fail "NEGATIVE CONTROL $L: sender nonce moved"
  [ "$(safe_nonce)" = "$SB" ] || fail "NEGATIVE CONTROL $L: Safe nonce moved"
  echo "{\"label\":\"$L\",\"from\":\"$FROM\",\"to\":\"$TO\",\"calldataKeccak256\":\"$(cast keccak "$DATA")\",\"expectedRevert\":\"$EXP\",\"safeNonceUnchanged\":$SB}" >> "$OUT/negatives.ndjson"
  say "  negative OK [$L]: reverted with $EXP; sender nonce $NB and Safe nonce $SB unchanged"
}
# Safe pre-validated signature (v = 1): r = owner, s = 0. Valid iff msg.sender == owner or approveHash'd.
sig1() { printf '%064s%064s01' "$(echo "${1#0x}" | tr 'A-F' 'a-f')" "" | tr ' ' '0'; }
safe_hash() { cast call $SAFE 'getTransactionHash(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,uint256)(bytes32)' "$1" 0 "$2" 0 0 0 0 $Z $Z "$3" --rpc-url $RPC; }
exec_data() { cast calldata 'execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)' "$1" 0 "$2" 0 0 0 0 $Z $Z "$3"; }

# ---- pre-flight ------------------------------------------------------------------------------
expect_nonce $EOA "$N0"; expect_safe_nonce "$S0"
[ "$(cast call $SAFE 'getThreshold()(uint256)' --rpc-url $RPC | awk '{print $1}')" = "2" ] || fail "Safe threshold != 2"
OWNERS=$(cast call $SAFE 'getOwners()(address[])' --rpc-url $RPC)
for o in $OA $OB $OC; do echo "$OWNERS" | grep -qi "$o" || fail "$o is not a Safe owner"; done
PEND0=$(cast call $SP 'pendingAPNTsToken()(address)' --rpc-url $RPC)
APNTS0=$(cast call $SP 'APNTS_TOKEN()(address)' --rpc-url $RPC)
[ "$(cast call $SP 'owner()(address)' --rpc-url $RPC)" = "$EOA" ] || fail "SP owner != deployer EOA"
say "== pre: SP $(cast call $SP 'version()(string)' --rpc-url $RPC) pendingAPNTsToken=$PEND0 eta=$(cast call $SP 'pendingAPNTsTokenEta()(uint256)' --rpc-url $RPC | awk '{print $1}') APNTS_TOKEN=$APNTS0"
# All CREATE addresses are fixed by the deployer nonce: S1 uses N0, S2 N0+1, S3 N0+2, S4 N0+3, S7 N0+4.
PRED_TL=$(cast compute-address $EOA --nonce $((N0 + 1)) | awk '{print $NF}')
PRED_CAP=$(cast compute-address $EOA --nonce $((N0 + 2)) | awk '{print $NF}')
say "   predicted: timelock (nonce $((N0 + 1))) $PRED_TL, APNTsCapped (nonce $((N0 + 2))) $PRED_CAP"

# ---- S1 (runbook 1①): cancel the pending 0xBb46… switch -------------------------------------
expect_nonce $EOA "$N0"
T0=$(cast block latest --field timestamp --rpc-url $RPC)
send S1-cancel $EOA $SP "$(cast calldata 'cancelAPNTsTokenChange()')"
[ "$(cast call $SP 'pendingAPNTsToken()(address)' --rpc-url $RPC)" = "$Z" ] || fail "S1 read-back pendingAPNTsToken != 0"
[ "$(cast call $SP 'pendingAPNTsTokenEta()(uint256)' --rpc-url $RPC)" = "0" ] || fail "S1 read-back eta != 0"
[ "$(cast call $SP 'APNTS_TOKEN()(address)' --rpc-url $RPC)" = "$APNTS0" ] || fail "S1 APNTS_TOKEN moved"
say "  S1 read-back OK: pending cleared, APNTS_TOKEN unchanged $APNTS0"

# ---- S2: deploy the Safe-only GOV-1 TimelockController (172800 s; proposer=canceller=executor=SAFE; admin=0)
TLBC="$(node -e 'const j=require(process.argv[1]);const m=j.metadata;if(m.settings.evmVersion!=="cancun"||m.settings.optimizer.runs!==500)throw new Error("not a default build");console.log(j.bytecode.object)' "$W/out/TimelockController.sol/TimelockController.default.json")"
TLARGS="$(cast abi-encode 'c(uint256,address[],address[],address)' 172800 "[$SAFE]" "[$SAFE]" $Z)"
echo "${TLBC}${TLARGS#0x}" > "$OUT/S2-timelock.initcode.hex"
expect_nonce $EOA "$((N0 + 1))"
send S2-deploy-timelock $EOA --create "${TLBC}${TLARGS#0x}"
NEW_TL=$(cast to-check-sum-address "$(node -e 'console.log(require(process.argv[1]).contractAddress)' "$W/$OUT/S2-deploy-timelock.receipt.json")")
[ "$(lc $NEW_TL)" = "$(lc $PRED_TL)" ] || fail "S2 address $NEW_TL != predicted $PRED_TL"
[ "$(cast call $NEW_TL 'getMinDelay()(uint256)' --rpc-url $RPC | awk '{print $1}')" = "172800" ] || fail "S2 minDelay"
TLBLK=$(node -e 'console.log(BigInt(require(process.argv[1]).blockNumber).toString())' "$W/$OUT/S2-deploy-timelock.receipt.json")
EXPECTED_ROLES="{\"ADMIN\":[\"$NEW_TL\"],\"PROPOSER\":[\"$SAFE\"],\"CANCELLER\":[\"$SAFE\"],\"EXECUTOR\":[\"$SAFE\"]}"
NOT_MEMBERS="$EOA,$OA,$OB,$OC,$SP,$OLD_TL" node scripts/a3a-v2-roles.mjs "$RPC" "$NEW_TL" "$TLBLK" "$EXPECTED_ROLES" > "$OUT/S2-roles.json" || fail "S2 exact role sets"
say "  S2 read-back OK: TimelockController $NEW_TL (== predicted) minDelay 172800; EXACT sets ADMIN=[timelock] PROPOSER=CANCELLER=EXECUTOR=[Safe] (S2-roles.json)"

# ---- S3+S4 (runbook 1②): DeployAPNTsCapped = CREATE APNTsCapped + transferOwnership(NEW_TL) ----
expect_nonce $EOA "$((N0 + 2))"
NB=$(nonce_of $EOA); SB=$(safe_nonce)
ENV=sepolia TIMELOCK=$NEW_TL forge script contracts/script/v3/DeployAPNTsCapped.s.sol:DeployAPNTsCapped \
  --rpc-url $RPC --unlocked --sender $EOA --broadcast --slow > "$OUT/S3S4-deploy-apnts-capped.log" 2>&1 || fail "S3/S4 DeployAPNTsCapped failed, see log"
cp broadcast/DeployAPNTsCapped.s.sol/11155111/run-latest.json "$OUT/S3S4-broadcast.json"
H3=$(node -e 'console.log(require(process.argv[1]).transactions[0].hash)' "$W/$OUT/S3S4-broadcast.json")
H4=$(node -e 'console.log(require(process.argv[1]).transactions[1].hash)' "$W/$OUT/S3S4-broadcast.json")
record S3-deploy-apnts-capped "$H3" $EOA "$NB" "$SB"
record S4-transfer-ownership "$H4" $EOA "$((NB + 1))" "$SB"
CAPPED=$(cast to-check-sum-address "$(node -e 'console.log(require(process.argv[1]).contractAddress)' "$W/$OUT/S3-deploy-apnts-capped.receipt.json")")
[ "$(lc $CAPPED)" = "$(lc $PRED_CAP)" ] || fail "S3 address $CAPPED != predicted $PRED_CAP"
grep -q "default artifact OK: APNTsCapped $CAPPED" "$OUT/S3S4-deploy-apnts-capped.log" || fail "S3 script did not confirm the artifact for $CAPPED"
[ "$(cast call $CAPPED 'owner()(address)' --rpc-url $RPC)" = "$EOA" ] || fail "S4 owner != deployer"
[ "$(cast call $CAPPED 'pendingOwner()(address)' --rpc-url $RPC)" = "$NEW_TL" ] || fail "S4 pendingOwner != NEW_TL"
say "  S3/S4 read-back OK: APNTsCapped $CAPPED (== predicted) owner=deployer pendingOwner=$NEW_TL minter=$(cast call $CAPPED 'minter()(address)' --rpc-url $RPC) capGuardian=$(cast call $CAPPED 'capGuardian()(address)' --rpc-url $RPC) cap=$(cast call $CAPPED 'cap()(uint256)' --rpc-url $RPC | awk '{print $1}') totalSupply=$(cast call $CAPPED 'totalSupply()(uint256)' --rpc-url $RPC | awk '{print $1}') version=$(cast call $CAPPED 'version()(string)' --rpc-url $RPC)"

# ---- Safe payloads --------------------------------------------------------------------------
ACC=$(cast calldata "acceptOwnership()")
SALT=$(cast keccak "APNTsCapped-1.0.0/acceptOwnership")
SCHED=$(cast calldata 'schedule(address,uint256,bytes,bytes32,bytes32,uint256)' $CAPPED 0 $ACC $ZERO32 $SALT 172800)
EXEC=$(cast calldata 'execute(address,uint256,bytes,bytes32,bytes32)' $CAPPED 0 $ACC $ZERO32 $SALT)
echo "$SCHED" > "$OUT/S5-schedule.calldata"; echo "$EXEC" > "$OUT/S6-execute.calldata"
OPID=$(cast call $NEW_TL 'hashOperation(address,uint256,bytes,bytes32,bytes32)(bytes32)' $CAPPED 0 $ACC $ZERO32 $SALT --rpc-url $RPC)
H5=$(safe_hash $NEW_TL "$SCHED" "$S0")
H6=$(safe_hash $NEW_TL "$EXEC" "$((S0 + 1))")
SIGS="0x$(sig1 $OA)$(sig1 $OB)"   # ascending owner order: OA < OB
say "   Safe payloads: S5 safeTxHash(nonce $S0)=$H5  S6 safeTxHash(nonce $((S0 + 1)))=$H6  timelock opId=$OPID"

# ---- negative controls on the Safe wrapper, BEFORE S5 (Safe nonce must stay $S0) --------------
negative safe-single-signature GS020 $OA $SAFE "$(exec_data $NEW_TL "$SCHED" "0x$(sig1 $OA)")"
negative safe-unapproved-owner GS025 $OA $SAFE "$(exec_data $NEW_TL "$SCHED" "0x$(sig1 $OA)$(sig1 $OC)")"
negative safe-non-owner-approveHash GS030 $EOA $SAFE "$(cast calldata 'approveHash(bytes32)' $H5)"

# ---- S5a: owner OB approves the S5 safeTxHash on-chain (stands in for an off-chain EIP-712 signature)
expect_safe_nonce "$S0"
send S5a-approveHash $OB $SAFE "$(cast calldata 'approveHash(bytes32)' $H5)"
[ "$(cast call $SAFE 'approvedHashes(address,bytes32)(uint256)' $OB $H5 --rpc-url $RPC)" = "1" ] || fail "S5a approvedHashes(OB,H5) != 1"
negative safe-unsorted-signatures GS026 $OA $SAFE "$(exec_data $NEW_TL "$SCHED" "0x$(sig1 $OB)$(sig1 $OA)")"
negative safe-wrong-executor GS025 $OC $SAFE "$(exec_data $NEW_TL "$SCHED" "$SIGS")"
# non-owner signer: OB (approved) ‖ EOA (msg.sender, so it passes GS025) → EOA is not an owner → GS026
negative safe-non-owner-signer GS026 $EOA $SAFE "$(exec_data $NEW_TL "$SCHED" "0x$(sig1 $OB)$(sig1 $EOA)")"

# ---- S5b: owner OA executes Safe.execTransaction(timelock.schedule(...)) with OA‖OB -----------
expect_safe_nonce "$S0"
INNER5=$(cast estimate $NEW_TL "$SCHED" --from $SAFE --rpc-url $RPC)
send S5b-safe-exec-schedule $OA $SAFE "$(exec_data $NEW_TL "$SCHED" "$SIGS")"
[ "$(safe_nonce)" = "$((S0 + 1))" ] || fail "S5b Safe nonce did not advance to $((S0 + 1))"
[ "$(cast call $NEW_TL 'isOperationPending(bytes32)(bool)' $OPID --rpc-url $RPC)" = "true" ] || fail "S5 operation not pending"
TS5=$(node -e 'const l=require("fs").readFileSync(process.argv[1],"utf8").trim().split("\n").map(JSON.parse);console.log(l.find(x=>x.label==="S5b-safe-exec-schedule").timestamp)' "$W/$OUT/steps.ndjson")
READY=$(cast call $NEW_TL 'getTimestamp(bytes32)(uint256)' $OPID --rpc-url $RPC | awk '{print $1}')
[ "$READY" = "$((TS5 + 172800))" ] || fail "S5 readyAt $READY != $TS5 + 172800"
say "  S5 read-back OK: Safe nonce ${S0}→$((S0 + 1)); op $OPID pending, readyAt=$READY (= exec block ts $TS5 + 172800); inner schedule() estimate $INNER5"

# ---- negative controls on the timelock after S5 ----------------------------------------------
negative tl-eoa-schedule 0xe2517d3f $EOA $NEW_TL "$SCHED"
negative tl-owner-direct-schedule 0xe2517d3f $OA $NEW_TL "$SCHED"
negative tl-eoa-execute-early 0xe2517d3f $EOA $NEW_TL "$EXEC"
# early execute through the real Safe path with a VALID 2-of-3 approval (OA + OC): the timelock
# reverts (TimelockUnexpectedOperationState) and the Safe turns it into GS013 (safeTxGas = gasPrice = 0)
send NEG-approveHash-early-S6-by-OC $OC $SAFE "$(cast calldata 'approveHash(bytes32)' $H6)"
negative safe-exec-execute-early GS013 $OA $SAFE "$(exec_data $NEW_TL "$EXEC" "0x$(sig1 $OA)$(sig1 $OC)")"
if cast call $NEW_TL "$EXEC" --from $SAFE --rpc-url $RPC > /dev/null 2> "$OUT/neg-inner-execute-early.err"; then fail "inner early execute succeeded"; fi
grep -q 0x5ead8eb5 "$OUT/neg-inner-execute-early.err" || fail "inner early execute did not revert with TimelockUnexpectedOperationState (0x5ead8eb5)"
say "  negative OK [inner-execute-early]: timelock.execute as the Safe (eth_call only) → TimelockUnexpectedOperationState 0x5ead8eb5"

cast rpc evm_increaseTime 172800 --rpc-url $RPC >/dev/null; cast rpc evm_mine --rpc-url $RPC >/dev/null
say "   (fork) time advanced by 172800 s"
negative tl-eoa-execute-after-delay 0xe2517d3f $EOA $NEW_TL "$EXEC"

# ---- S6a/S6b: OB approves, OA executes Safe.execTransaction(timelock.execute(...)) -----------
expect_safe_nonce "$((S0 + 1))"
send S6a-approveHash $OB $SAFE "$(cast calldata 'approveHash(bytes32)' $H6)"
expect_safe_nonce "$((S0 + 1))"
INNER6=$(cast estimate $NEW_TL "$EXEC" --from $SAFE --rpc-url $RPC)
send S6b-safe-exec-execute $OA $SAFE "$(exec_data $NEW_TL "$EXEC" "$SIGS")"
[ "$(safe_nonce)" = "$((S0 + 2))" ] || fail "S6b Safe nonce did not advance to $((S0 + 2))"
[ "$(cast call $CAPPED 'owner()(address)' --rpc-url $RPC)" = "$NEW_TL" ] || fail "S6 owner != NEW_TL"
[ "$(cast call $CAPPED 'pendingOwner()(address)' --rpc-url $RPC)" = "$Z" ] || fail "S6 pendingOwner != 0"
[ "$(cast call $NEW_TL 'isOperationDone(bytes32)(bool)' $OPID --rpc-url $RPC)" = "true" ] || fail "S6 op not done"
say "  S6 read-back OK: Safe nonce $((S0 + 1))→$((S0 + 2)); APNTsCapped owner=$NEW_TL pendingOwner=0; inner execute() estimate $INNER6"
ENV=sepolia TIMELOCK=$NEW_TL forge script contracts/script/v3/DeployAPNTsCapped.s.sol:DeployAPNTsCapped --sig 'verify(address,address)' $CAPPED $EOA --rpc-url $RPC > "$OUT/S6-verify.log" 2>&1 || fail "S6 DeployAPNTsCapped.verify failed"
grep -q '=== verify: ALL PASS ===' "$OUT/S6-verify.log" || fail "S6 verify did not print ALL PASS"
say "  S6 DeployAPNTsCapped.verify: ALL PASS"

# ---- S7 (runbook 1③): queue SP.setAPNTsToken(APNTsCapped), ETA = block ts + 7d ------------------
expect_nonce $EOA "$((N0 + 4))"
NB=$(nonce_of $EOA); SB=$(safe_nonce)
ENV=sepolia V55_APNTS_DECISION=queue forge script contracts/script/v3/UpgradeToV5_5_0.s.sol:UpgradeToV5_5_0 --sig 'queueAPNTs(address)' $CAPPED \
  --rpc-url $RPC --unlocked --sender $EOA --broadcast --slow > "$OUT/S7-queue.log" 2>&1 || fail "S7 queueAPNTs failed, see log"
cp broadcast/UpgradeToV5_5_0.s.sol/11155111/queueAPNTs-latest.json "$OUT/S7-broadcast.json"
record S7-queue "$(node -e 'console.log(require(process.argv[1]).transactions[0].hash)' "$W/$OUT/S7-broadcast.json")" $EOA "$NB" "$SB"
QTS=$(node -e 'const l=require("fs").readFileSync(process.argv[1],"utf8").trim().split("\n").map(JSON.parse);console.log(l.find(x=>x.label==="S7-queue").timestamp)' "$W/$OUT/steps.ndjson")
ETA=$(cast call $SP 'pendingAPNTsTokenEta()(uint256)' --rpc-url $RPC | awk '{print $1}')
[ "$(cast call $SP 'pendingAPNTsToken()(address)' --rpc-url $RPC)" = "$CAPPED" ] || fail "S7 pendingAPNTsToken != APNTsCapped"
[ "$ETA" = "$((QTS + 604800))" ] || fail "S7 eta $ETA != $QTS + 604800"
[ "$(cast call $SP 'APNTS_TOKEN()(address)' --rpc-url $RPC)" = "$APNTS0" ] || fail "S7 APNTS_TOKEN moved"
say "  S7 read-back OK: pendingAPNTsToken=$CAPPED eta=$ETA (= queue ts $QTS + 604800); APNTS_TOKEN unchanged; ETA - T0 = $((ETA - T0)) s ($(( (ETA - T0) / 86400 )) d $(( (ETA - T0) % 86400 / 3600 )) h)"
[ $((ETA - T0)) -ge $((9 * 86400)) ] || fail "default order must yield ETA >= T0 + 9d"
negative sp-execute-switch-before-eta 0xc52a9bd3 $EOA $SP "$(cast calldata 'executeAPNTsTokenChange()')"

# ---- final: role sets unchanged after the whole sequence; nonces ---------------------------------
NOT_MEMBERS="$EOA,$OA,$OB,$OC,$SP,$OLD_TL" node scripts/a3a-v2-roles.mjs "$RPC" "$NEW_TL" "$TLBLK" "$EXPECTED_ROLES" > "$OUT/final-roles.json" || fail "final exact role sets"
[ "$(safe_nonce)" = "$((S0 + 2))" ] || fail "final Safe nonce"
[ "$(nonce_of $EOA)" = "$((N0 + 5))" ] || fail "final deployer nonce"
node -e 'console.log(JSON.stringify({forkBlock:+process.argv[1],deployerNonceAtPin:+process.argv[2],safeNonceAtPin:+process.argv[3],newTimelock:process.argv[4],apntsCapped:process.argv[5],acceptOperationId:process.argv[6],acceptSalt:process.argv[7],safeTxHashS5:process.argv[8],safeTxHashS6:process.argv[9],signatures:process.argv[10],t0:+process.argv[11],scheduleTs:+process.argv[12],readyAt:+process.argv[13],queueTs:+process.argv[14],eta:+process.argv[15],timelockDeployBlock:+process.argv[16],innerScheduleGasEstimate:+process.argv[17],innerExecuteGasEstimate:+process.argv[18]},null,1))' \
  "$FORK_BLOCK" "$N0" "$S0" "$NEW_TL" "$CAPPED" "$OPID" "$SALT" "$H5" "$H6" "$SIGS" "$T0" "$TS5" "$READY" "$QTS" "$ETA" "$TLBLK" "$INNER5" "$INNER6" > "$OUT/addresses.json"
say "final: deployer nonce ${N0}→$((N0 + 5)), Safe nonce ${S0}→$((S0 + 2)); timelock roles still exact (final-roles.json)"
say "A3a v2 FORK SIMULATION OK (local only; nothing broadcast to a public network)"
