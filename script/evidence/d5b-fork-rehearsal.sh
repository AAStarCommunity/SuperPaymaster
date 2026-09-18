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
# Prerequisite: `pnpm install` at the repo root first (check-timelock-roles.mjs needs node_modules/viem
# on the require path; on a fresh/clean clone without it, the script crashes partway through Stage II --
# DSR hit exactly this in an isolated clone. The cleanup trap still fires and restores correctly even on
# that failure exit, which is a stronger test than a clean run, but the run itself won't complete).
#
# Usage: script/evidence/d5b-fork-rehearsal.sh <env file with RPC_URL> <fork block> <out dir> [stage]
#   stage (optional): I | II | all (default all). Re-run stage II alone once stage I evidence exists by
#   also passing SP_ADDR/REG_ADDR pointing at nothing -- in practice this script's fork is ephemeral
#   (one anvil process), so a mid-run failure is fixed by re-running from the top; each `step` echoes a
#   clear marker and every artefact is written incrementally, so failures are diagnosed from $OUT/*.log
#   without re-deriving anything by hand.
set -uo pipefail
ENVFILE="$1"; FORK_BLOCK="$2"; OUT="$3"; STAGE="${4:-all}"
# stage_on <name>: STAGE is "all", an exact stage name, or a comma-separated list (e.g. "0,I") --
# useful while iterating on one stage at a time without waiting through the whole thing.
stage_on() { [ "$STAGE" = "all" ] && return 0; case ",$STAGE," in *",$1,"*) return 0 ;; esac; return 1; }
export PATH="$HOME/.foundry/bin:$HOME/.local/bin:$PATH"
W="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$W"
mkdir -p "$OUT"
RPC_URL_FORK="$(grep -E '^RPC_URL=' "$ENVFILE" | head -1 | cut -d= -f2- | tr -d '"'"'"' ')"
[ -n "$RPC_URL_FORK" ] || { echo "no RPC_URL in env file"; exit 2; }

OWNER=0xb5600060e6de5E11D3636731964218E53caadf0E   # live SP+Registry+Timelock(proposer/canceller/executor/admin) EOA
ANNI=0xEcAACb915f7D92e9916f449F7ad42BD0408733c9    # live operator (community: Mycelium)
GOV_MULTISIG=0x51eDf11fDb0A4F66220eFb8efA54Eca77232E114   # Mycelium governance multisig (APNTsCapped minter/capGuardian/timelock proposer)
SP=0x09DF0d2e3722EC0e401fE3819E64278a42ae4DE9
REG=0xf5Bf37ca83AfdAab73691bA7eCcDfA69b8708E71
TL=0x86C86c789EDc099801cc6a5F48334F1D67dC9564
EP=0x0000000071727De22E5E9d8BAf0edAc6f37da032
OLD_APNTS=0x696A73701b104c6cCBbAadDD2216788ea08EaB89   # SP.APNTS_TOKEN() pre-switch (OWNER's balance is in this)
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
# FAILURES: read-back markers below are checked with `grep -q ... && ok || warn`, which by design
# never aborts the script mid-run (so every stage still gets attempted and logged). Without this
# counter that pattern degenerates into a false-positive gate: every warning was previously just an
# echoed "!!!" line, and the script printed "REHEARSAL OK" unconditionally at the bottom regardless
# of how many read-backs actually failed. Every soft-failure site below must increment this.
FAILURES=0
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
  # "sepolia-fork" is not a real network name used anywhere else in this repo (only "sepolia" is a
  # real deployment target), so this path can never collide with a real committed config -- safe to
  # unconditionally remove, unlike $MANIFEST above.
  rm -f "$W/deployments/config.sepolia-fork.json"
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
  # UpgradeViaTimelock.s.sol (via UpgradeRegistryD5b/D5bUpgradeChecks) imports Registry.sol, so it's
  # dual-compiled (foundry.toml's compilation_restrictions -> <Contract>.default.json +
  # <Contract>.registry-size.json, no bare <Contract>.json). Two DISTINCT, both confirmed-real forge
  # 1.7.1 quirks around this, that pull in opposite directions:
  #   (a) plain `forge script <file>:<Contract>` (no --force) fails "Could not find target contract"
  #       for THIS file even right after a from-scratch `rm -rf cache out && forge build` -- --force
  #       on the forge-script call itself reliably fixes this.
  #   (b) `forge script <file>:<Contract> --force` can (non-deterministically -- reproduced once,
  #       did NOT reproduce on two immediate identical retries) fail a LATER runtime check
  #       ("DefaultArtifacts: no profile.default build of ERC1967Proxy ...") because out/ez for a
  #       library this file only vm.readFile()s at runtime (never `import`s) went missing, even
  #       though a preceding project-wide `forge build --force` had just written it.
  # Since (b) did not reproduce on a same-conditions retry, treat it as flaky and retry the whole
  # (rebuild, force-script) sequence up to 3 times before giving up for real.
  local attempt out rc
  for attempt in 1 2 3; do
    forge build --force > /dev/null 2>&1
    out="$(env ENV="$ENVNAME" "$@" forge script "contracts/script/v3/UpgradeViaTimelock.s.sol:$c" \
      --rpc-url "$RPC" --unlocked --sender "$s" --broadcast --slow --force 2>&1)"
    rc=$?
    echo "$out"
    if [ $rc -eq 0 ]; then return 0; fi
    if ! echo "$out" | grep -q "DefaultArtifacts: no profile.default build"; then return $rc; fi
    echo "  (fscript_tl attempt $attempt/3: transient DefaultArtifacts artifact-pruning quirk, retrying with a fresh rebuild)" >&2
  done
  return $rc
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

step "forge build --force (once, up front)"
# REAL, REPRODUCIBLE FAILURE (found running this script): any file that imports Registry.sol --
# directly or transitively, e.g. UpgradeViaTimelock.s.sol via UpgradeRegistryD5b/D5bUpgradeChecks
# -- gets compiled TWICE by foundry.toml's [[profile.default.compilation_restrictions]] (once at
# the file's normal settings, once at Registry's forced runs<=200), and forge disambiguates by
# writing out/<File>.sol/<Contract>.default.json + <Contract>.registry-size.json instead of a bare
# <Contract>.json. After enough interleaved `forge build` / `forge build --skip test` / `forge test
# --evm-version prague` runs in one working tree (exactly what a long release-review session does),
# forge's incremental cache can end up in a state where `forge script <file>:<Contract>` for one of
# these dual-profile files reports "No files changed, compilation skipped" and then "Error: Could
# not find target contract" -- confirmed reproducible here even after a full `forge clean && forge
# build`; only `--force` (bypassing the cache, not just cleaning it) resolved it. One `--force`
# build up front, before anything else runs, avoids paying that cost on every later forge-script
# call in this script while still guaranteeing every artifact (both profiles) is freshly resolved.
export PATH="$HOME/.foundry/bin:$PATH"
forge build --force > "$OUT/00-forge-build-force.log" 2>&1
RC=$?
if [ "$RC" -ne 0 ]; then echo "  !!! forge build --force FAILED (exit $RC), see $OUT/00-forge-build-force.log" | tee -a "$OUT/rehearsal.log"; FAILURES=$((FAILURES+1)); exit 1; fi

step "fork Sepolia at block $FORK_BLOCK"
anvil --fork-url "$RPC_URL_FORK" --fork-block-number "$FORK_BLOCK" --port "$PORT" --silent >"$OUT/anvil.log" 2>&1 &
PIDS+=($!)
for _ in $(seq 1 60); do cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 1; done
for a in $OWNER $ANNI $GOV_MULTISIG; do cast rpc anvil_impersonateAccount $a --rpc-url "$RPC" >/dev/null; done
cast rpc anvil_setBalance $OWNER 0x56BC75E2D63100000 --rpc-url "$RPC" >/dev/null   # 100 ETH, real balance is fine but keep headroom
cast rpc anvil_setBalance $GOV_MULTISIG 0x56BC75E2D63100000 --rpc-url "$RPC" >/dev/null
echo "  chainId $(cast chain-id --rpc-url $RPC) head $(cast block-number --rpc-url $RPC)" | tee -a "$OUT/rehearsal.log"
echo "  pre-fork inventory: SP=$(cast call $SP 'version()(string)' --rpc-url $RPC) Registry=$(cast call $REG 'version()(string)' --rpc-url $RPC)" | tee -a "$OUT/rehearsal.log"

if stage_on 0; then

step "STAGE 0: fork-level check (real public RPCs, read-only, not fork-scoped) + on-chain inventory"
node script/evidence/fork-level-probes.mjs "$OUT/0-fork-level-probes.json" > "$OUT/0-fork-level-probes.log" 2>&1
RC=$?
if [ "$RC" -ne 0 ]; then echo "  !!! STAGE 0 fork-level probe FAILED (exit $RC), see $OUT/0-fork-level-probes.log" | tee -a "$OUT/rehearsal.log"; FAILURES=$((FAILURES+1)); fi
grep -o '"next":[^,}]*' "$OUT/0-fork-level-probes.json" | head -1 | tee -a "$OUT/rehearsal.log" || true

ENV=$ENVNAME $LOG "$OUT/0-inventory.log" forge script contracts/script/v3/UpgradeToV5_5_0.s.sol:UpgradeToV5_5_0 --sig 'inventory(address[])' "[$OWNER,$ANNI]" --rpc-url $RPC
RC=$?
if [ "$RC" -ne 0 ]; then echo "  !!! STAGE 0 inventory FAILED (exit $RC), see $OUT/0-inventory.log" | tee -a "$OUT/rehearsal.log"; FAILURES=$((FAILURES+1)); fi
grep -E "pendingAPNTsToken|operator " "$OUT/0-inventory.log" | tee -a "$OUT/rehearsal.log" || true

ANNI_TOKEN=$(cast call $SP 'operators(address)(uint128,bool,bool,address,uint32,uint48,address,uint256,uint256)' $ANNI --rpc-url $RPC | sed -n '4p')
ENV=$ENVNAME $LOG "$OUT/0-inventory-debts.log" forge script contracts/script/v3/UpgradeToV5_5_0.s.sol:UpgradeToV5_5_0 --sig 'inventoryDebts(address[],address[])' "[$OLD_APNTS,$ANNI_TOKEN]" "[$OWNER,$ANNI]" --rpc-url $RPC
RC=$?
if [ "$RC" -ne 0 ]; then echo "  !!! STAGE 0 inventoryDebts FAILED (exit $RC), see $OUT/0-inventory-debts.log" | tee -a "$OUT/rehearsal.log"; FAILURES=$((FAILURES+1)); fi
grep -E "pendingDebts|total" "$OUT/0-inventory-debts.log" | tee -a "$OUT/rehearsal.log" || true

fi # stage 0

if stage_on I; then

# check_stage1() name FAILED action, exit code -> on failure: log loudly, count it, and STOP.
# Unlike the Stage II read-back markers (which are independent checks that can all be attempted
# even if one is missing), A1-A4 are a strict dependency chain: A2 assumes A1 actually cancelled,
# A3's run() asserts pendingAPNTsToken==0 (A1's effect) and every V55_OPERATORS entry paused (A2's
# effect), A4 assumes A3 landed SP first. Continuing past a real forge-script failure here doesn't
# produce useful additional evidence, it produces a cascade of confusing downstream errors -- so
# stop immediately, exactly like must_fail() already does for an unexpected negative-control result.
check_stage1() {
  local name="$1" rc="$2"
  if [ "$rc" -ne 0 ]; then
    echo "  !!! STAGE I / $name FAILED (exit $rc) -- stopping, see the matching log in $OUT" | tee -a "$OUT/rehearsal.log"
    FAILURES=$((FAILURES+1))
    exit 1
  fi
}

step "STAGE I / A1: cancel the pending APNTsCapped switch (0xBb46...), orthogonal to D5b"
ENV=$ENVNAME V55_APNTS_DECISION=cancel $LOG "$OUT/I-A1-cancel.log" forge script contracts/script/v3/UpgradeToV5_5_0.s.sol:UpgradeToV5_5_0 --sig 'cancelPendingAPNTs()' --rpc-url $RPC --unlocked --sender $OWNER --broadcast
check_stage1 A1 $?
echo "  pendingAPNTsToken after cancel: $(cast call $SP 'pendingAPNTsToken()(address)' --rpc-url $RPC)" | tee -a "$OUT/rehearsal.log"

step "STAGE I / A1b: deploy a FRESH GOV-1-shaped TimelockController (172800; proposer=canceller=executor=GOV_MULTISIG; no admin) for the APNTsCapped handover"
# The REAL live TimelockController ($TL) does NOT have GOV_MULTISIG as PROPOSER (verified live on
# this fork: `hasRole(PROPOSER_ROLE, GOV_MULTISIG)` returns false) -- DeployAPNTsCapped.s.sol's own
# _checkTimelock() correctly refuses it ("timelock: governance multisig is not PROPOSER"), which is
# exactly the documented design intent (D5b-design.md, apnts-capped-deliverable.md L124: the real TL
# was never GOV-1-shaped for this multisig; SP "倾向新部署一把符合 GOV-1 的" for this handover). So
# deploy a fresh one here, matching script/evidence/fork-rehearsal.sh's precedent (row F-01).
TLART=out/TimelockController.sol/TimelockController.default.json
TLBC="$(node -e 'const j=require(process.argv[1]);const m=j.metadata;if(m.settings.evmVersion!=="cancun"||m.settings.optimizer.runs!==500)throw new Error("not a default build");console.log(j.bytecode.object)' "$W/$TLART")"
TLARGS="$(cast abi-encode 'c(uint256,address[],address[],address)' 172800 "[$GOV_MULTISIG]" "[$GOV_MULTISIG]" 0x0000000000000000000000000000000000000000)"
FRESH_TL_JSON="$(cast send --unlocked --from $OWNER --rpc-url $RPC --json --create "$TLBC${TLARGS#0x}")"
FRESH_TL="$(echo "$FRESH_TL_JSON" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).contractAddress))')"
if [ -z "$FRESH_TL" ] || [ "$FRESH_TL" = "null" ]; then echo "  !!! STAGE I / A1b: fresh TimelockController deploy failed" | tee -a "$OUT/rehearsal.log"; FAILURES=$((FAILURES+1)); exit 1; fi
echo "  fresh GOV-1-shaped TimelockController: $FRESH_TL" | tee -a "$OUT/rehearsal.log"

step "STAGE I / A1c (runbook 1②): deploy APNTsCapped, start the Ownable2Step handover to the fresh TimelockController"
ENV=$ENVNAME TIMELOCK=$FRESH_TL $LOG "$OUT/I-A1c-deploy-apnts-capped.log" forge script contracts/script/v3/DeployAPNTsCapped.s.sol:DeployAPNTsCapped --rpc-url $RPC --unlocked --sender $OWNER --broadcast
check_stage1 A1c $?
CAPPED=$(grep -oE "\[artifact\] default artifact OK: APNTsCapped 0x[0-9a-fA-F]{40}" "$OUT/I-A1c-deploy-apnts-capped.log" | awk '{print $NF}')
if [ -z "$CAPPED" ]; then echo "  !!! STAGE I / A1c could not extract the deployed APNTsCapped address, see $OUT/I-A1c-deploy-apnts-capped.log" | tee -a "$OUT/rehearsal.log"; FAILURES=$((FAILURES+1)); exit 1; fi
echo "  APNTsCapped deployed: $CAPPED (owner=$(cast call $CAPPED 'owner()(address)' --rpc-url $RPC) pendingOwner=$(cast call $CAPPED 'pendingOwner()(address)' --rpc-url $RPC))" | tee -a "$OUT/rehearsal.log"

step "STAGE I / A1d: governance multisig accepts ownership of APNTsCapped via the fresh TimelockController (real schedule -> +48h -> execute on the fork, committed to the fork's persisted state -- not the script's own internal vm.prank simulation, which never leaves the simulation and would NOT be visible to a later plain cast call)"
ACC_DATA=$(cast calldata "acceptOwnership()")
ACC_SALT=$(cast keccak "APNTsCapped-1.0.0/acceptOwnership")
ZERO32=0x0000000000000000000000000000000000000000000000000000000000000000
cast send $FRESH_TL 'schedule(address,uint256,bytes,bytes32,bytes32,uint256)' $CAPPED 0 $ACC_DATA $ZERO32 $ACC_SALT 172800 --unlocked --from $GOV_MULTISIG --rpc-url $RPC >/dev/null
check_stage1 A1d-schedule $?
must_fail "execute acceptOwnership before 48h" cast send $FRESH_TL 'execute(address,uint256,bytes,bytes32,bytes32)' $CAPPED 0 $ACC_DATA $ZERO32 $ACC_SALT --unlocked --from $GOV_MULTISIG --rpc-url $RPC
warp48h
cast send $FRESH_TL 'execute(address,uint256,bytes,bytes32,bytes32)' $CAPPED 0 $ACC_DATA $ZERO32 $ACC_SALT --unlocked --from $GOV_MULTISIG --rpc-url $RPC >/dev/null
check_stage1 A1d-execute $?
echo "  APNTsCapped after accept: owner=$(cast call $CAPPED 'owner()(address)' --rpc-url $RPC) pendingOwner=$(cast call $CAPPED 'pendingOwner()(address)' --rpc-url $RPC)" | tee -a "$OUT/rehearsal.log"

step "STAGE I / A1e (runbook 1③): queue the aPNTs switch to APNTsCapped"
ENV=$ENVNAME V55_APNTS_DECISION=queue $LOG "$OUT/I-A1e-queue.log" forge script contracts/script/v3/UpgradeToV5_5_0.s.sol:UpgradeToV5_5_0 --sig 'queueAPNTs(address)' $CAPPED --rpc-url $RPC --unlocked --sender $OWNER --broadcast
check_stage1 A1e $?
echo "  pendingAPNTsToken=$(cast call $SP 'pendingAPNTsToken()(address)' --rpc-url $RPC) eta=$(cast call $SP 'pendingAPNTsTokenEta()(uint256)' --rpc-url $RPC)" | tee -a "$OUT/rehearsal.log"

step "STAGE I: fast-forward 7 days (APNTS_TOKEN_TIMELOCK) so the queued switch is executable"
cast rpc evm_increaseTime 604800 --rpc-url "$RPC" >/dev/null
cast rpc evm_mine --rpc-url "$RPC" >/dev/null
echo "  block.timestamp now $(cast block --rpc-url $RPC latest timestamp) >= eta $(cast call $SP 'pendingAPNTsTokenEta()(uint256)' --rpc-url $RPC)" | tee -a "$OUT/rehearsal.log"

step "STAGE I / A1f: pre-fund OWNER *and ANNI* with APNTsCapped before the redeposit"
# REAL FINDING (verified on this fork, not assumed): SuperPaymaster.totalTrackedBalance() is a
# WHOLE-CONTRACT aggregate across every operator, regardless of which community token each one
# holds -- confirmed by exact arithmetic after A1g's first attempt (which only drained OWNER):
# 2934135941213700000000 (pre) - 1690008712737068326800 (OWNER's withdraw) -
# 399486525633215878600 (revenue drained to the buffer) = 844640702843415794600, which exactly
# equals ANNI's untouched aPNTsBalance (844540702843415794600, a DIFFERENT token, Mycelium PNTs)
# plus the 0.1 ether buffer. `executeAPNTsTokenChange`'s on-chain guard requires this GLOBAL total
# <= PROTOCOL_REVENUE_BUFFER (see commit d968b547, "fix(H-4b): fix APNTS migration
# totalTrackedBalance deadlock" -- pre-existing 5.4.2 production behaviour, not introduced by this
# branch), so EVERY operator must fully withdraw, not just ones holding the old aPNTs token -- the
# runbook's own step 1④ text already says this ("各 operator 取出全部余额", each operator, not
# "each aPNTs operator"). Consequence worth flagging for the real A3a execution: ANNI/Mycelium's
# balance gets swept into the NEW aPNTs token by the same 1:1 redeposit below, even though Mycelium
# was never on aPNTs -- whoever runs this for real needs to decide whether Mycelium should be
# reconfigured back to its own token immediately afterward (not something this script does).
# cast call's tuple output appends a human-readable "[1.69e21]" annotation after the raw decimal on
# the same line -- take only the first whitespace-delimited token, or `mint`'s uint256 arg is corrupt.
OWNER_OLD_BAL=$(cast call $SP 'operators(address)(uint128,bool,bool,address,uint32,uint48,address,uint256,uint256)' $OWNER --rpc-url $RPC | head -1 | awk '{print $1}')
ANNI_OLD_BAL=$(cast call $SP 'operators(address)(uint128,bool,bool,address,uint32,uint48,address,uint256,uint256)' $ANNI --rpc-url $RPC | head -1 | awk '{print $1}')
cast send $CAPPED 'mint(address,uint256)' $OWNER "$OWNER_OLD_BAL" --unlocked --from $GOV_MULTISIG --rpc-url $RPC >/dev/null
check_stage1 A1f-owner $?
cast send $CAPPED 'mint(address,uint256)' $ANNI "$ANNI_OLD_BAL" --unlocked --from $GOV_MULTISIG --rpc-url $RPC >/dev/null
check_stage1 A1f-anni $?
# `protocolRevenue` (the 0.1 ether buffer left after withdrawing down to it) survives the token-
# address swap as accounting denominated in the NEW token, but the old-token buffer physically left
# in SP does not collateralise that number afterwards -- executePendingAPNTs' own read-back (a
# Codex whole-branch-review fix) requires the new token to be pre-funded on the SP contract itself
# before the irreversible switch, or it reverts "SP lacks new-token collateral for retained
# protocolRevenue". Mint that buffer directly to the SP address.
cast send $CAPPED 'mint(address,uint256)' $SP 100000000000000000 --unlocked --from $GOV_MULTISIG --rpc-url $RPC >/dev/null
check_stage1 A1f-sp-buffer $?
echo "  minted for 1:1 redeposit: OWNER $OWNER_OLD_BAL, ANNI $ANNI_OLD_BAL, SP buffer 0.1e18; APNTsCapped balances now OWNER=$(cast call $CAPPED 'balanceOf(address)(uint256)' $OWNER --rpc-url $RPC) ANNI=$(cast call $CAPPED 'balanceOf(address)(uint256)' $ANNI --rpc-url $RPC) SP=$(cast call $CAPPED 'balanceOf(address)(uint256)' $SP --rpc-url $RPC)" | tee -a "$OUT/rehearsal.log"

step "STAGE I / A1g (runbook 1④): execute the full aPNTs migration -- drain EVERY operator's balance in its OLD token (not just aPNTs holders, see A1f's finding), executeAPNTsTokenChange, redeposit 1:1 in APNTsCapped"
ENV=$ENVNAME V55_APNTS_DECISION=execute V55_APNTS_RATIO_WAD=1000000000000000000 $LOG "$OUT/I-A1g-execute.log" forge script contracts/script/v3/UpgradeToV5_5_0.s.sol:UpgradeToV5_5_0 --sig 'executePendingAPNTs(address[])' "[$OWNER,$ANNI]" --rpc-url $RPC --unlocked --sender $OWNER --broadcast
check_stage1 A1g $?
echo "  APNTS_TOKEN=$(cast call $SP 'APNTS_TOKEN()(address)' --rpc-url $RPC) pendingAPNTsToken=$(cast call $SP 'pendingAPNTsToken()(address)' --rpc-url $RPC)" | tee -a "$OUT/rehearsal.log"

step "STAGE I / A1h (runbook step 2): clearPendingDebts (D-21 write-off; confirmed 0 for both known token/user pairs at Stage 0 -- this call is a no-op read-back, not a real write-off, since inventoryDebts already found nothing pending)"
ANNI_TOKEN=$(cast call $SP 'operators(address)(uint128,bool,bool,address,uint32,uint48,address,uint256,uint256)' $ANNI --rpc-url $RPC | sed -n '4p')
ENV=$ENVNAME $LOG "$OUT/I-A1h-clear-debts.log" forge script contracts/script/v3/UpgradeToV5_5_0.s.sol:UpgradeToV5_5_0 --sig 'clearPendingDebts(address[],address[])' "[$OLD_APNTS,$ANNI_TOKEN]" "[$OWNER,$ANNI]" --rpc-url $RPC --unlocked --sender $OWNER --broadcast
check_stage1 A1h $?

step "STAGE I / A2: pauseOperators([Owner,Anni]) (runbook step 3 precondition for run())"
ENV=$ENVNAME $LOG "$OUT/I-A2-pause.log" forge script contracts/script/v3/UpgradeToV5_5_0.s.sol:UpgradeToV5_5_0 --sig 'pauseOperators(address[])' "[$OWNER,$ANNI]" --rpc-url $RPC --unlocked --sender $OWNER --broadcast
check_stage1 A2 $?

step "STAGE I / A3: run() -- land CURRENT HEAD SuperPaymaster (5.5.0 AOA balance mode, D5b core+extension split already included) via a plain EOA upgradeToAndCall"
mkdir -p cache/evidence-d5b-fork
ENV=$ENVNAME V55_OUT_CONFIG=cache/evidence-d5b-fork/config.sepolia-fork.json V55_OPERATORS=$OWNER,$ANNI \
  $LOG "$OUT/I-A3-run.log" forge script contracts/script/v3/UpgradeToV5_5_0.s.sol:UpgradeToV5_5_0 --rpc-url $RPC --unlocked --sender $OWNER --broadcast
check_stage1 A3 $?
echo "  SP version after run(): $(cast call $SP 'version()(string)' --rpc-url $RPC)" | tee -a "$OUT/rehearsal.log"
echo "  SP EXTENSION (D5b core/ext split marker): $(cast call $SP 'EXTENSION()(address)' --rpc-url $RPC 2>&1)" | tee -a "$OUT/rehearsal.log"

step "STAGE I / A4: UpgradeRegistryD5b -- land CURRENT HEAD Registry (5.9.0, GOV-2 two-step ownership) via a plain EOA upgradeToAndCall"
# NOTE: the previous form of this line piped through `tee | grep ... || true`, which (with
# pipefail) forced the WHOLE pipeline's reported exit status to 0 regardless of whether forge
# script itself failed -- exactly the "reports success after a real failure" bug this fixes.
# Redirect to the log file first (fscript_tl already merges stderr internally) so $? is forge
# script's own exit code, unaffected by the display grep that follows.
fscript_tl UpgradeRegistryD5b $OWNER > "$OUT/I-A4-registry.log" 2>&1
RC=$?
grep -E "read-back|BLS|raw slots|5c|Error|revert" "$OUT/I-A4-registry.log" || true
check_stage1 A4 $RC
echo "  Registry version after UpgradeRegistryD5b: $(cast call $REG 'version()(string)' --rpc-url $RPC)" | tee -a "$OUT/rehearsal.log"

V55_CFG=cache/evidence-d5b-fork/config.sepolia-fork.json

step "STAGE I / A5 (runbook 7a): each community issues its own v2 token; operator stays paused (creditPolicy starts OFF)"
ENV=$ENVNAME V55_OUT_CONFIG=$V55_CFG $LOG "$OUT/I-A5-issue-owner.log" forge script contracts/script/v3/UpgradeToV5_5_0.s.sol:UpgradeToV5_5_0 --sig 'issueCommunityToken(string,string,string,string,uint256)' "AAStar PNTs v2" "aPNTsV2" "AAStar" "aastar.eth" 1000000000000000000 --rpc-url $RPC --unlocked --sender $OWNER --broadcast
check_stage1 A5-owner $?
OWNER_V2=$(grep -oE "step 7a: v2 token 0x[0-9a-fA-F]{40}" "$OUT/I-A5-issue-owner.log" | awk '{print $NF}')
[ -n "$OWNER_V2" ] || { echo "  !!! could not extract OWNER's v2 token address, see $OUT/I-A5-issue-owner.log" | tee -a "$OUT/rehearsal.log"; FAILURES=$((FAILURES+1)); exit 1; }

ENV=$ENVNAME V55_OUT_CONFIG=$V55_CFG $LOG "$OUT/I-A5-issue-anni.log" forge script contracts/script/v3/UpgradeToV5_5_0.s.sol:UpgradeToV5_5_0 --sig 'issueCommunityToken(string,string,string,string,uint256)' "Mycelium PNTs v2" "PNTSV2" "Mycelium" "mycelium.eth" 1000000000000000000 --rpc-url $RPC --unlocked --sender $ANNI --broadcast
check_stage1 A5-anni $?
ANNI_V2=$(grep -oE "step 7a: v2 token 0x[0-9a-fA-F]{40}" "$OUT/I-A5-issue-anni.log" | awk '{print $NF}')
[ -n "$ANNI_V2" ] || { echo "  !!! could not extract ANNI's v2 token address, see $OUT/I-A5-issue-anni.log" | tee -a "$OUT/rehearsal.log"; FAILURES=$((FAILURES+1)); exit 1; }
echo "  OWNER v2 token=$OWNER_V2 creditPolicy=$(cast call $OWNER_V2 'creditPolicy()(uint8)' --rpc-url $RPC)  ANNI v2 token=$ANNI_V2 creditPolicy=$(cast call $ANNI_V2 'creditPolicy()(uint8)' --rpc-url $RPC)" | tee -a "$OUT/rehearsal.log"

step "STAGE I / A6 (runbook 7c): updatePrice -> configureOperatorV2 -> unpauseOperator for both communities (balance mode only; creditPolicy stays OFF)"
ENV=$ENVNAME V55_OUT_CONFIG=$V55_CFG $LOG "$OUT/I-A6-configure-owner.log" forge script contracts/script/v3/UpgradeToV5_5_0.s.sol:UpgradeToV5_5_0 --sig 'configureOperatorV2(address,address)' $OWNER_V2 $OWNER --rpc-url $RPC --unlocked --sender $OWNER --broadcast
check_stage1 A6-configure-owner $?
ENV=$ENVNAME V55_OUT_CONFIG=$V55_CFG $LOG "$OUT/I-A6-configure-anni.log" forge script contracts/script/v3/UpgradeToV5_5_0.s.sol:UpgradeToV5_5_0 --sig 'configureOperatorV2(address,address)' $ANNI_V2 $ANNI --rpc-url $RPC --unlocked --sender $ANNI --broadcast
check_stage1 A6-configure-anni $?

ENV=$ENVNAME V55_OUT_CONFIG=$V55_CFG $LOG "$OUT/I-A6-unpause-owner.log" forge script contracts/script/v3/UpgradeToV5_5_0.s.sol:UpgradeToV5_5_0 --sig 'unpauseOperator(address)' $OWNER --rpc-url $RPC --unlocked --sender $OWNER --broadcast
check_stage1 A6-unpause-owner $?
ENV=$ENVNAME V55_OUT_CONFIG=$V55_CFG $LOG "$OUT/I-A6-unpause-anni.log" forge script contracts/script/v3/UpgradeToV5_5_0.s.sol:UpgradeToV5_5_0 --sig 'unpauseOperator(address)' $ANNI --rpc-url $RPC --unlocked --sender $OWNER --broadcast
check_stage1 A6-unpause-anni $?
# unpauseOperator itself doesn't re-assert creditPolicy==OFF (only issueCommunityToken/configureOperatorV2 do,
# per the whole-branch Codex review's runbook-entrypoints finding) -- the runbook's 7c row explicitly wants a
# read-back AFTER unpause, so do it here rather than trusting the earlier checks still hold.
for T in $OWNER_V2 $ANNI_V2; do
  CP=$(cast call $T 'creditPolicy()(uint8)' --rpc-url $RPC)
  if [ "$CP" != "0" ]; then echo "  !!! creditPolicy for $T is $CP, expected 0 (OFF) after unpause" | tee -a "$OUT/rehearsal.log"; FAILURES=$((FAILURES+1)); fi
done
echo "  post-unpause creditPolicy: OWNER_V2=$(cast call $OWNER_V2 'creditPolicy()(uint8)' --rpc-url $RPC) ANNI_V2=$(cast call $ANNI_V2 'creditPolicy()(uint8)' --rpc-url $RPC); OWNER paused=$(cast call $SP 'operators(address)(uint128,bool,bool,address,uint32,uint48,address,uint256,uint256)' $OWNER --rpc-url $RPC | sed -n '3p') ANNI paused=$(cast call $SP 'operators(address)(uint128,bool,bool,address,uint32,uint48,address,uint256,uint256)' $ANNI --rpc-url $RPC | sed -n '3p')" | tee -a "$OUT/rehearsal.log"

step "STAGE I / A7: real UserOp through EntryPoint (runbook 7c acceptance: one balance-mode op succeeds per community). Scoped to ANNI/Mycelium -- L4GaslessTest.s.sol is written specifically around the ANNI identity (PRIVATE_KEY_ANNI), not parameterized per-operator; extending it to cover OWNER/AAStar too is future work, not done here."
DEPLOY_CFG="deployments/config.sepolia-fork.json"
node -e '
  const fs = require("fs");
  const base = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  base.pnts = process.argv[2];
  fs.writeFileSync(process.argv[3], JSON.stringify(base, null, 2));
' "$V55_CFG" "$ANNI_V2" "$DEPLOY_CFG"
L4_USER_KEY=$(cast wallet new --json | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s)[0].private_key))')
ANNI_PK="$(grep -E '^PRIVATE_KEY_ANNI=' "$ENVFILE" | head -1 | cut -d= -f2- | tr -d '"'"'"' ')"
BUNDLER_PK="$(grep -E '^PRIVATE_KEY=' "$ENVFILE" | head -1 | cut -d= -f2- | tr -d '"'"'"' ')"
if [ -z "$ANNI_PK" ] || [ -z "$BUNDLER_PK" ]; then
  echo "  !!! STAGE I / A7 SKIPPED: PRIVATE_KEY_ANNI / PRIVATE_KEY missing from $ENVFILE (needed to sign the real UserOp's operator/bundler roles)" | tee -a "$OUT/rehearsal.log"
  FAILURES=$((FAILURES+1))
else
  ENV=sepolia-fork PRIVATE_KEY="$BUNDLER_PK" PRIVATE_KEY_ANNI="$ANNI_PK" L4_USER_KEY="$L4_USER_KEY" \
    $LOG "$OUT/I-A7-l4-gasless.log" forge script contracts/script/v3/L4GaslessTest.s.sol:L4GaslessTest --rpc-url $RPC --broadcast --slow --gas-estimate-multiplier 400
  RC=$?
  grep -E "AA account|settled|burned|Error|revert" "$OUT/I-A7-l4-gasless.log" || true
  check_stage1 A7 $RC
fi

fi # stage I

if stage_on II; then

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
grep -q "M1/M2 read-back OK" "$OUT/II-M1-execute.log" && echo "  M1 read-back OK" | tee -a "$OUT/rehearsal.log" || { echo "  !!! M1 read-back marker NOT found, see II-M1-execute.log" | tee -a "$OUT/rehearsal.log"; FAILURES=$((FAILURES+1)); }
must_fail "old EOA owner upgradeToAndCall after M1" cast send --rpc-url $RPC --unlocked --from $OWNER $SP 'upgradeToAndCall(address,bytes)' $SP 0x
echo "  SP.owner=$(cast call $SP 'owner()(address)' --rpc-url $RPC) guardian=$(cast call $SP 'guardian()(address)' --rpc-url $RPC)" | tee -a "$OUT/rehearsal.log"
echo "  Registry.owner=$(cast call $REG 'owner()(address)' --rpc-url $RPC)" | tee -a "$OUT/rehearsal.log"

step "STAGE II / C: timelock-aware upgrade drill (SP then Registry) -- demo cycle, redeploys the same implementation to exercise the mechanism"
for T in SP REGISTRY; do
  fscript_tl UpgradeViaTimelock $OWNER TL_MODE=deploy-impl TL_TARGET=$T | tee "$OUT/II-C-$T-deploy.log" | grep -E "ready|new implementation|Error|revert" || true
  NI=$(grep -oE "pass as TL_NEW_IMPL\): 0x[0-9a-fA-F]{40}" "$OUT/II-C-$T-deploy.log" | awk '{print $NF}')
  [ -n "$NI" ] || { echo "  !!! could not extract new impl address for $T, see II-C-$T-deploy.log" | tee -a "$OUT/rehearsal.log"; FAILURES=$((FAILURES+1)); continue; }
  must_fail "schedule-upgrade $T WITHOUT a roles attestation" fscript_tl UpgradeViaTimelock $OWNER TL_MODE=schedule-upgrade TL_TARGET=$T TL_NEW_IMPL="$NI" TL_SALT=$(cast keccak "d5b-fork-c-$T")
  roles_check "before-$T-upgrade"
  fscript_tl UpgradeViaTimelock $OWNER TL_MODE=schedule-upgrade TL_ROLES_ATTESTATION="$ATT" TL_TARGET=$T TL_NEW_IMPL="$NI" TL_SALT=$(cast keccak "d5b-fork-c-$T") | tee "$OUT/II-C-$T-schedule.log" | grep -E "scheduled|Error|revert" || true
  must_fail "execute-upgrade $T before 48h" fscript_tl UpgradeViaTimelock $OWNER TL_MODE=execute-upgrade TL_ROLES_ATTESTATION="$ATT" TL_TARGET=$T TL_NEW_IMPL="$NI" TL_SALT=$(cast keccak "d5b-fork-c-$T")
  warp48h
  roles_check "before-$T-execute"
  fscript_tl UpgradeViaTimelock $OWNER TL_MODE=execute-upgrade TL_ROLES_ATTESTATION="$ATT" TL_TARGET=$T TL_NEW_IMPL="$NI" TL_SALT=$(cast keccak "d5b-fork-c-$T") | tee "$OUT/II-C-$T-execute.log" | grep -E "read-back|BLS|raw slots|extension|Error|revert" || true
  grep -q "read-back OK" "$OUT/II-C-$T-execute.log" && echo "  $T timelock-aware upgrade: read-back OK" | tee -a "$OUT/rehearsal.log" || { echo "  !!! $T read-back marker NOT found, see II-C-$T-execute.log" | tee -a "$OUT/rehearsal.log"; FAILURES=$((FAILURES+1)); }
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
grep -q "governed call executed" "$OUT/II-M2-execute.log" && echo "  governed unpause executed" | tee -a "$OUT/rehearsal.log" || { echo "  !!! governed unpause marker NOT found, see II-M2-execute.log" | tee -a "$OUT/rehearsal.log"; FAILURES=$((FAILURES+1)); }
echo "  paused() after the timelock's unpause = $(cast call $SP 'paused()(bool)' --rpc-url $RPC)" | tee -a "$OUT/rehearsal.log"

fi # stage II

step "final state"
echo "  SP owner=$(cast call $SP 'owner()(address)' --rpc-url $RPC) guardian=$(cast call $SP 'guardian()(address)' --rpc-url $RPC) impl=$(impl_of $SP) version=$(cast call $SP 'version()(string)' --rpc-url $RPC)" | tee -a "$OUT/rehearsal.log"
echo "  Registry owner=$(cast call $REG 'owner()(address)' --rpc-url $RPC) impl=$(impl_of $REG) version=$(cast call $REG 'version()(string)' --rpc-url $RPC)" | tee -a "$OUT/rehearsal.log"
if [ "$FAILURES" -eq 0 ]; then
  echo "REHEARSAL OK ($STAGE)" | tee -a "$OUT/rehearsal.log"
else
  echo "REHEARSAL FAILED ($STAGE): $FAILURES read-back marker(s) missing, see the !!! lines above" | tee -a "$OUT/rehearsal.log"
  exit 1
fi
