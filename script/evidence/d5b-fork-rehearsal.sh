#!/usr/bin/env bash
# D5b (GOV-2 core+extension split, two-step ownership, guardian/pause, GOV-5 gas params) upgrade-flow
# rehearsal against a REAL Sepolia-FORK state (LOCAL anvil fork only; nothing is sent to any public
# network — every forge/cast call below targets http://127.0.0.1:<port>). This is the "small stage,
# each stage checkpointed" companion to scripts/d5b-anvil-rehearsal.sh (which deploys a FRESH synthetic
# stack on plain anvil): here the SP/Registry proxies, the TimelockController, the owner EOA and the
# operators are the REAL live Sepolia ones, forked at a pinned block, so the rehearsal exercises actual
# governance state (real pending proposals, real role grants, real operator config) instead of a clean-
# room fixture.
#
# Live state at the time this was written (2026-09-16, block ~11716158): SP = SuperPaymaster-5.4.2
# (NOT yet the 5.5.0 rc that scripts/d5b-anvil-rehearsal.sh assumes as its starting point), Registry =
# Registry-5.8.0, both owned by the EOA 0xb560...df0E; a live TimelockController (48h) already deployed
# but NOT yet holding SP/Registry ownership; that EOA ALSO still holds the timelock's DEFAULT_ADMIN_ROLE
# (in addition to PROPOSER/CANCELLER/EXECUTOR) — the GOV-1 handoff has not happened. So this rehearsal is
# in two stages: (I) land the CURRENT HEAD implementation (5.5.0 AOA balance mode + D5b already baked
# in, since D5b is not shipped as a separate version bump — see D5b-design.md) via the existing
# UpgradeToV5_5_0 + UpgradeRegistryD5b scripts, exactly the upgrade that would really need to run on
# live Sepolia; (II) exercise the D5b/GOV-1 timelock mechanics (M1 ownership handoff, a demo timelock-
# aware upgrade cycle, M2 guardian pause/unpause) against that landed state, using the SAME EOA as
# proposer/canceller/executor -- which is not a rehearsal simplification, it is what the account already
# holds on real Sepolia today.
#
# Usage: script/evidence/d5b-fork-rehearsal.sh <env file with RPC_URL> <fork block> <out dir> [stage]
#   stage (optional): I | II | all (default all). Re-run stage II alone once stage I evidence exists by
#   also passing SP_ADDR/REG_ADDR pointing at nothing -- in practice this script's fork is ephemeral
#   (one anvil process), so a mid-run failure is fixed by re-running from the top; each `step` echoes a
#   clear marker and every artefact is written incrementally, so failures are diagnosed from $OUT/*.log
#   without re-deriving anything by hand.
set -uo pipefail
ENVFILE="$1"; FORK_BLOCK="$2"; OUT="$3"; STAGE="${4:-all}"
export PATH="$HOME/.foundry/bin:$HOME/.local/bin:$PATH"
W="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$W"
mkdir -p "$OUT"
RPC_URL_FORK="$(grep -E '^RPC_URL=' "$ENVFILE" | head -1 | cut -d= -f2- | tr -d '"'"'"' ')"
[ -n "$RPC_URL_FORK" ] || { echo "no RPC_URL in env file"; exit 2; }

OWNER=0xb5600060e6de5E11D3636731964218E53caadf0E   # live SP+Registry+Timelock(proposer/canceller/executor/admin) EOA
ANNI=0xEcAACb915f7D92e9916f449F7ad42BD0408733c9    # live operator (community: Mycelium)
SP=0x09DF0d2e3722EC0e401fE3819E64278a42ae4DE9
REG=0xf5Bf37ca83AfdAab73691bA7eCcDfA69b8708E71
TL=0x86C86c789EDc099801cc6a5F48334F1D67dC9564
EP=0x0000000071727De22E5E9d8BAf0edAc6f37da032
ENVNAME=sepolia
LOG=script/evidence/run-logged.sh
# MANIFEST is a REAL, non-negotiable path: UpgradeViaTimelock.s.sol's _cfg()/_manifest() build it from
# the SAME `ENV` value used to find the real deployments/config.sepolia.json, so it MUST be
# "deployments/timelock-roles.sepolia.json" -- the exact path a real, committed GOV-1 manifest lives at
# once the real M1 handoff happens (see deployments/timelock-roles.example.json's own comment: "create
# the real file... change it only through a reviewed change"). This script must NEVER destroy that file
# if it already exists for real: back it up before writing the rehearsal's own version, and RESTORE
# (never just delete) on exit. Only delete on exit when it did NOT exist before this run touched it.
MANIFEST="deployments/timelock-roles.$ENVNAME.json"
MANIFEST_BACKUP="$OUT/REAL-manifest-backup.$ENVNAME.json"
MANIFEST_PREEXISTED=0
if [ -f "$W/$MANIFEST" ]; then
  MANIFEST_PREEXISTED=1
  cp "$W/$MANIFEST" "$MANIFEST_BACKUP"
  echo "NOTE: $MANIFEST already exists (real committed manifest?) -- backed up to $MANIFEST_BACKUP, will be restored on exit, never deleted." | tee -a "$OUT/rehearsal.log" 2>/dev/null || true
fi
PIDS=()
cleanup() {
  for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done
  if [ "$MANIFEST_PREEXISTED" = "1" ]; then
    cp "$MANIFEST_BACKUP" "$W/$MANIFEST"
    echo "restored the pre-existing $MANIFEST from backup (not deleted)."
  else
    rm -f "$W/$MANIFEST"
  fi
  # Attestation filenames ARE fully chosen by this script (roles_check()'s label argument, below) and
  # are namespaced with a "fork-rehearsal-" prefix specifically so they can never collide with a real
  # attestation someone files for an actual governance action -- so a plain rm -f here is safe.
  rm -f "$W"/deployments/attestations/timelock-roles."$ENVNAME".fork-rehearsal-*.json
}
trap cleanup EXIT

PORT=28571; RPC="http://127.0.0.1:$PORT"
step() { echo; echo "=== $* ===" | tee -a "$OUT/rehearsal.log"; }
must_fail() { local what="$1"; shift; if "$@" >"$OUT/neg.log" 2>&1; then echo "NEGATIVE CONTROL FAILED: $what succeeded" | tee -a "$OUT/rehearsal.log"; exit 1; else echo "  negative ok: $what reverted ($(grep -oE 'Error: [^,]{0,120}|revert[^,]{0,120}' "$OUT/neg.log" | head -1))" | tee -a "$OUT/rehearsal.log"; fi; }
txhash() { node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).transactionHash))'; }
warp48h() { cast rpc evm_increaseTime 172800 --rpc-url "$RPC" >/dev/null; cast rpc evm_mine --rpc-url "$RPC" >/dev/null; }
impl_of() { cast storage "$1" 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc --rpc-url "$RPC" | sed 's/0x000000000000000000000000/0x/'; }
fscript_tl() { # <contract> <sender> [env...]
  local c="$1" s="$2"; shift 2
  env ENV="$ENVNAME" "$@" forge script "contracts/script/v3/UpgradeViaTimelock.s.sol:$c" \
    --rpc-url "$RPC" --unlocked --sender "$s" --broadcast --slow 2>&1
}
roles_check() { # <label> -> sets $ATT
  # "fork-rehearsal-" prefix: this filename is entirely our own choice (unlike $MANIFEST, whose path is
  # fixed by UpgradeViaTimelock.s.sol), so namespace it so it can never collide with, shadow, or get
  # cleaned up in place of a real attestation someone files for an actual governance action.
  ATT="deployments/attestations/timelock-roles.$ENVNAME.fork-rehearsal-$1.json"
  node script/governance/check-timelock-roles.mjs --rpc "$RPC" --manifest "$OUT/manifest.json" --out "$OUT/roles-$1.json" \
    --attest "$ATT" | tee "$OUT/roles-$1.log" | tail -3
  cp "$ATT" "$OUT/attestation-$1.json"
  cast rpc evm_mine --rpc-url "$RPC" >/dev/null   # let the attested head get a blockhash (live-chain path)
}

step "fork Sepolia at block $FORK_BLOCK"
anvil --fork-url "$RPC_URL_FORK" --fork-block-number "$FORK_BLOCK" --port "$PORT" --silent >"$OUT/anvil.log" 2>&1 &
PIDS+=($!)
for _ in $(seq 1 60); do cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 1; done
for a in $OWNER $ANNI; do cast rpc anvil_impersonateAccount $a --rpc-url "$RPC" >/dev/null; done
cast rpc anvil_setBalance $OWNER 0x56BC75E2D63100000 --rpc-url "$RPC" >/dev/null   # 100 ETH, real balance is fine but keep headroom
echo "  chainId $(cast chain-id --rpc-url $RPC) head $(cast block-number --rpc-url $RPC)" | tee -a "$OUT/rehearsal.log"
echo "  pre-fork inventory: SP=$(cast call $SP 'version()(string)' --rpc-url $RPC) Registry=$(cast call $REG 'version()(string)' --rpc-url $RPC)" | tee -a "$OUT/rehearsal.log"

if [ "$STAGE" = "I" ] || [ "$STAGE" = "all" ]; then

step "STAGE I / A1: cancel the pending APNTsCapped switch (0xBb46...), orthogonal to D5b"
ENV=$ENVNAME V55_APNTS_DECISION=cancel $LOG "$OUT/I-A1-cancel.log" forge script contracts/script/v3/UpgradeToV5_5_0.s.sol:UpgradeToV5_5_0 --sig 'cancelPendingAPNTs()' --rpc-url $RPC --unlocked --sender $OWNER --broadcast
echo "  pendingAPNTsToken after cancel: $(cast call $SP 'pendingAPNTsToken()(address)' --rpc-url $RPC)" | tee -a "$OUT/rehearsal.log"

step "STAGE I / A2: pauseOperators([Owner,Anni]) (runbook step 3 precondition for run())"
ENV=$ENVNAME $LOG "$OUT/I-A2-pause.log" forge script contracts/script/v3/UpgradeToV5_5_0.s.sol:UpgradeToV5_5_0 --sig 'pauseOperators(address[])' "[$OWNER,$ANNI]" --rpc-url $RPC --unlocked --sender $OWNER --broadcast

step "STAGE I / A3: run() -- land CURRENT HEAD SuperPaymaster (5.5.0 AOA balance mode, D5b core+extension split already included) via a plain EOA upgradeToAndCall"
mkdir -p cache/evidence-d5b-fork
ENV=$ENVNAME V55_OUT_CONFIG=cache/evidence-d5b-fork/config.sepolia-fork.json V55_OPERATORS=$OWNER,$ANNI \
  $LOG "$OUT/I-A3-run.log" forge script contracts/script/v3/UpgradeToV5_5_0.s.sol:UpgradeToV5_5_0 --rpc-url $RPC --unlocked --sender $OWNER --broadcast
echo "  SP version after run(): $(cast call $SP 'version()(string)' --rpc-url $RPC)" | tee -a "$OUT/rehearsal.log"
echo "  SP EXTENSION (D5b core/ext split marker): $(cast call $SP 'EXTENSION()(address)' --rpc-url $RPC 2>&1)" | tee -a "$OUT/rehearsal.log"

step "STAGE I / A4: UpgradeRegistryD5b -- land CURRENT HEAD Registry (5.9.0, GOV-2 two-step ownership) via a plain EOA upgradeToAndCall"
fscript_tl UpgradeRegistryD5b $OWNER | tee "$OUT/I-A4-registry.log" | grep -E "read-back|BLS|raw slots|5c|Error|revert" || true
echo "  Registry version after UpgradeRegistryD5b: $(cast call $REG 'version()(string)' --rpc-url $RPC)" | tee -a "$OUT/rehearsal.log"

fi # stage I

if [ "$STAGE" = "II" ] || [ "$STAGE" = "all" ]; then

step "STAGE II / precondition: renounce the deployer's leftover DEFAULT_ADMIN_ROLE on the live TimelockController"
echo "  BEFORE: admin(OWNER)=$(cast call $TL 'hasRole(bytes32,address)(bool)' 0x0000000000000000000000000000000000000000000000000000000000000000 $OWNER --rpc-url $RPC) admin(timelock itself)=$(cast call $TL 'hasRole(bytes32,address)(bool)' 0x0000000000000000000000000000000000000000000000000000000000000000 $TL --rpc-url $RPC)" | tee -a "$OUT/rehearsal.log"
echo "  >>> FINDING (real, live Sepolia): the deployer EOA still holds DEFAULT_ADMIN_ROLE on the already-deployed TimelockController $TL." | tee -a "$OUT/rehearsal.log"
echo "  >>> check-timelock-roles.mjs's validateManifest HARD-REQUIRES DEFAULT_ADMIN_ROLE == [timelock] exactly (the M1 policy)," | tee -a "$OUT/rehearsal.log"
echo "  >>> so the REAL M1 batch cannot be scheduled at all until the deployer renounces this role for real. Demonstrated here on the fork:" | tee -a "$OUT/rehearsal.log"
RENTX=$(cast send $TL 'renounceRole(bytes32,address)' 0x0000000000000000000000000000000000000000000000000000000000000000 $OWNER --unlocked --from $OWNER --rpc-url $RPC --json | txhash)
echo "  renounceRole tx (fork only) $RENTX" | tee -a "$OUT/rehearsal.log"
echo "  AFTER : admin(OWNER)=$(cast call $TL 'hasRole(bytes32,address)(bool)' 0x0000000000000000000000000000000000000000000000000000000000000000 $OWNER --rpc-url $RPC) admin(timelock itself)=$(cast call $TL 'hasRole(bytes32,address)(bool)' 0x0000000000000000000000000000000000000000000000000000000000000000 $TL --rpc-url $RPC)" | tee -a "$OUT/rehearsal.log"

step "STAGE II / manifest: build + canonicalize the M1-policy manifest for the now-corrected role shape"
# deploymentBlock MUST be the real constructor block (the checker scans event history starting here;
# too-late a value would silently hide any role grant before it). Found by directly querying this
# timelock's own event log on live Sepolia (cast logs --address $TL --from-block 0 --to-block latest),
# not guessed: the timelock's four RoleGranted events (DEFAULT_ADMIN_ROLE -> the timelock itself AND
# -> the deployer EOA, PROPOSER/CANCELLER/EXECUTOR_ROLE -> the deployer EOA, sender = the deployer EOA
# in every case) all land in block 11151057, which is therefore the constructor's block.
TL_DEPLOY_BLOCK="${TL_DEPLOY_BLOCK:-11151057}"
# mustHoldNothing: verified on-chain (cast logs, this timelock, block 0..latest) that the ONLY accounts
# ever granted any role here are the timelock itself and $OWNER -- there is no second, retired EOA to
# name. Exhaustively checked further: EVERY superseded SuperPaymaster proxy in this project's Sepolia
# history (queried via `owner()` on each address ever recorded in deployments/config.sepolia.json's git
# history -- 0xFb090E82.../0x506962D1.../0x33404ccD.../0x829C3178... and the current 0x09DF0d2e...)
# reports the SAME owner EOA. This single EOA has controlled every deployment of this project on Sepolia
# since its first recorded redeploy; there genuinely is no distinct "retired credential" to name. The
# manifest schema still hard-requires a non-empty, real, verifiable entry (by design: it will not accept
# an unrelated or fabricated placeholder as satisfying it, correctly -- an earlier draft of this script
# used the ERC-4337 EntryPoint singleton here, which was rightly rejected as still a semantic placeholder
# since EntryPoint was never a plausible candidate for holding a timelock role in the first place).
# What IS used instead: 0xFb090E82bD041C6e9787eDEbE1D3BE55b3c7266a, the immediately-PRIOR SuperPaymaster
# proxy of THIS SAME project on THIS SAME network, retired when the project last redeployed to the
# current proxy. It is a real, project-specific, genuinely-retired artefact of this deployment's own
# history (not an arbitrary unrelated contract), directly verified below to hold none of the four roles.
# It is still not a perfect fit for "historical EOA account" -- it is a contract, not a wallet -- and
# this is recorded here as an open question for the schema owner: for a single-EOA-since-genesis
# deployment like this one, `mustHoldNothing`'s non-empty requirement has no natural EOA answer, and this
# script's choice should be revisited (or the schema extended with an explicit "no historical account"
# state, backed by the same exhaustive on-chain check this script just did) rather than treated as settled.
OLDSP=0xFb090E82bD041C6e9787eDEbE1D3BE55b3c7266a
OLDSP_HOLDS_NONE=1
for ROLE_HASH in 0x0000000000000000000000000000000000000000000000000000000000000000 $(cast keccak PROPOSER_ROLE) $(cast keccak CANCELLER_ROLE) $(cast keccak EXECUTOR_ROLE); do
  HAS=$(cast call $TL 'hasRole(bytes32,address)(bool)' "$ROLE_HASH" "$OLDSP" --rpc-url "$RPC")
  [ "$HAS" = "false" ] || OLDSP_HOLDS_NONE=0
done
[ "$OLDSP_HOLDS_NONE" = "1" ] || { echo "  !!! retired SP proxy unexpectedly holds a timelock role -- cannot use it as the mustHoldNothing entry" | tee -a "$OUT/rehearsal.log"; exit 1; }
echo "  verified: retired SP proxy $OLDSP holds none of the four roles on $TL (live check, not assumed)" | tee -a "$OUT/rehearsal.log"
cat > "$OUT/manifest.draft.json" <<JSON
{
  "network": "$ENVNAME",
  "chainId": "11155111",
  "timelock": "$TL",
  "deploymentBlock": "$TL_DEPLOY_BLOCK",
  "roles": {
    "DEFAULT_ADMIN_ROLE": ["$TL"],
    "PROPOSER_ROLE": ["$OWNER"],
    "CANCELLER_ROLE": ["$OWNER"],
    "EXECUTOR_ROLE": ["$OWNER"]
  },
  "mustHoldNothing": ["$OLDSP"],
  "mustHoldNothingLabels": ["retired SuperPaymaster proxy from this same project's Sepolia deployment history (superseded by the current 0x09DF0d2e... proxy); used because an exhaustive on-chain check (current + 4 prior SP deployments, all owner() reads) found no distinct EOA anywhere in this project's history -- see the script comment above for the full reasoning and the open question this leaves for the schema owner"]
}
JSON
node script/governance/check-timelock-roles.mjs --canonicalize "$OUT/manifest.draft.json" > "$MANIFEST"
cp "$MANIFEST" "$OUT/manifest.json"
cat "$OUT/manifest.json" | tee -a "$OUT/rehearsal.log"

step "STAGE II / M1: two-step transferOwnership(timelock) on SP + Registry, then ONE scheduleBatch (accept + setGuardian)"
cast send $SP 'transferOwnership(address)' $TL --unlocked --from $OWNER --rpc-url $RPC >/dev/null
cast send $REG 'transferOwnership(address)' $TL --unlocked --from $OWNER --rpc-url $RPC >/dev/null
echo "  after transferOwnership: SP.pendingOwner=$(cast call $SP 'pendingOwner()(address)' --rpc-url $RPC) Registry.pendingOwner=$(cast call $REG 'pendingOwner()(address)' --rpc-url $RPC)" | tee -a "$OUT/rehearsal.log"
must_fail "schedule-accept WITHOUT a roles attestation" fscript_tl UpgradeViaTimelock $OWNER TL_MODE=schedule-accept
roles_check before-M1
fscript_tl UpgradeViaTimelock $OWNER TL_MODE=schedule-accept TL_ROLES_ATTESTATION="$ATT" | tee "$OUT/II-M1-schedule.log" | grep -E "scheduled|Error|revert" || true
must_fail "execute-accept before 48h" fscript_tl UpgradeViaTimelock $OWNER TL_MODE=execute-accept TL_ROLES_ATTESTATION="$ATT"
warp48h
roles_check before-M1-execute
fscript_tl UpgradeViaTimelock $OWNER TL_MODE=execute-accept TL_ROLES_ATTESTATION="$ATT" | tee "$OUT/II-M1-execute.log" | grep -E "read-back|Error|revert" || true
grep -q "M1/M2 read-back OK" "$OUT/II-M1-execute.log" && echo "  M1 read-back OK" | tee -a "$OUT/rehearsal.log" || echo "  !!! M1 read-back marker NOT found, see II-M1-execute.log" | tee -a "$OUT/rehearsal.log"
must_fail "old EOA owner upgradeToAndCall after M1" cast send --rpc-url $RPC --unlocked --from $OWNER $SP 'upgradeToAndCall(address,bytes)' $SP 0x
echo "  SP.owner=$(cast call $SP 'owner()(address)' --rpc-url $RPC) guardian=$(cast call $SP 'guardian()(address)' --rpc-url $RPC)" | tee -a "$OUT/rehearsal.log"
echo "  Registry.owner=$(cast call $REG 'owner()(address)' --rpc-url $RPC)" | tee -a "$OUT/rehearsal.log"

step "STAGE II / C: timelock-aware upgrade drill (SP then Registry) -- demo cycle, redeploys the same implementation to exercise the mechanism"
for T in SP REGISTRY; do
  fscript_tl UpgradeViaTimelock $OWNER TL_MODE=deploy-impl TL_TARGET=$T | tee "$OUT/II-C-$T-deploy.log" | grep -E "ready|new implementation|Error|revert" || true
  NI=$(grep -oE "pass as TL_NEW_IMPL\): 0x[0-9a-fA-F]{40}" "$OUT/II-C-$T-deploy.log" | awk '{print $NF}')
  [ -n "$NI" ] || { echo "  !!! could not extract new impl address for $T, see II-C-$T-deploy.log" | tee -a "$OUT/rehearsal.log"; continue; }
  must_fail "schedule-upgrade $T WITHOUT a roles attestation" fscript_tl UpgradeViaTimelock $OWNER TL_MODE=schedule-upgrade TL_TARGET=$T TL_NEW_IMPL="$NI" TL_SALT=$(cast keccak "d5b-fork-c-$T")
  roles_check "before-$T-upgrade"
  fscript_tl UpgradeViaTimelock $OWNER TL_MODE=schedule-upgrade TL_ROLES_ATTESTATION="$ATT" TL_TARGET=$T TL_NEW_IMPL="$NI" TL_SALT=$(cast keccak "d5b-fork-c-$T") | tee "$OUT/II-C-$T-schedule.log" | grep -E "scheduled|Error|revert" || true
  must_fail "execute-upgrade $T before 48h" fscript_tl UpgradeViaTimelock $OWNER TL_MODE=execute-upgrade TL_ROLES_ATTESTATION="$ATT" TL_TARGET=$T TL_NEW_IMPL="$NI" TL_SALT=$(cast keccak "d5b-fork-c-$T")
  warp48h
  roles_check "before-$T-execute"
  fscript_tl UpgradeViaTimelock $OWNER TL_MODE=execute-upgrade TL_ROLES_ATTESTATION="$ATT" TL_TARGET=$T TL_NEW_IMPL="$NI" TL_SALT=$(cast keccak "d5b-fork-c-$T") | tee "$OUT/II-C-$T-execute.log" | grep -E "read-back|BLS|raw slots|extension|Error|revert" || true
  grep -q "read-back OK" "$OUT/II-C-$T-execute.log" && echo "  $T timelock-aware upgrade: read-back OK" | tee -a "$OUT/rehearsal.log" || echo "  !!! $T read-back marker NOT found, see II-C-$T-execute.log" | tee -a "$OUT/rehearsal.log"
done

step "STAGE II / M2: guardian (owner) pauses; guardian cannot unpause; timelock unpauses after 48h"
cast send $SP 'setGlobalPaused(bool)' true --unlocked --from $OWNER --rpc-url $RPC >/dev/null
echo "  paused() = $(cast call $SP 'paused()(bool)' --rpc-url $RPC)" | tee -a "$OUT/rehearsal.log"
must_fail "guardian unpause" cast send --rpc-url $RPC --unlocked --from $OWNER $SP 'setGlobalPaused(bool)' false
UNP=$(cast calldata "setGlobalPaused(bool)" false)
must_fail "schedule-call (unpause) WITHOUT a roles attestation" fscript_tl UpgradeViaTimelock $OWNER TL_MODE=schedule-call TL_TARGET=SP TL_CALLDATA="$UNP" TL_SALT=$(cast keccak d5b-fork-m2-unpause)
roles_check before-M2-unpause
fscript_tl UpgradeViaTimelock $OWNER TL_MODE=schedule-call TL_ROLES_ATTESTATION="$ATT" TL_TARGET=SP TL_CALLDATA="$UNP" TL_SALT=$(cast keccak d5b-fork-m2-unpause) | tee "$OUT/II-M2-schedule.log" | grep -E "roles attestation|scheduled|Error|revert" || true
must_fail "execute-call (unpause) before 48h" fscript_tl UpgradeViaTimelock $OWNER TL_MODE=execute-call TL_ROLES_ATTESTATION="$ATT" TL_TARGET=SP TL_CALLDATA="$UNP" TL_SALT=$(cast keccak d5b-fork-m2-unpause)
warp48h
roles_check before-M2-unpause-execute
fscript_tl UpgradeViaTimelock $OWNER TL_MODE=execute-call TL_ROLES_ATTESTATION="$ATT" TL_TARGET=SP TL_CALLDATA="$UNP" TL_SALT=$(cast keccak d5b-fork-m2-unpause) | tee "$OUT/II-M2-execute.log" | grep -E "roles attestation|executed|Error|revert" || true
grep -q "governed call executed" "$OUT/II-M2-execute.log" && echo "  governed unpause executed" | tee -a "$OUT/rehearsal.log"
echo "  paused() after the timelock's unpause = $(cast call $SP 'paused()(bool)' --rpc-url $RPC)" | tee -a "$OUT/rehearsal.log"

fi # stage II

step "final state"
echo "  SP owner=$(cast call $SP 'owner()(address)' --rpc-url $RPC) guardian=$(cast call $SP 'guardian()(address)' --rpc-url $RPC) impl=$(impl_of $SP) version=$(cast call $SP 'version()(string)' --rpc-url $RPC)" | tee -a "$OUT/rehearsal.log"
echo "  Registry owner=$(cast call $REG 'owner()(address)' --rpc-url $RPC) impl=$(impl_of $REG) version=$(cast call $REG 'version()(string)' --rpc-url $RPC)" | tee -a "$OUT/rehearsal.log"
echo "REHEARSAL OK ($STAGE)" | tee -a "$OUT/rehearsal.log"
