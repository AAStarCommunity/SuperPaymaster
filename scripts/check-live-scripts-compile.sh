#!/usr/bin/env bash
# =============================================================================
# Compiles the forge scripts the deployment tooling ACTUALLY INVOKES.
#
# Nothing in CI compiles contracts/script: `forge build`, `forge build --skip
# test` and `forge test` all report clean with a syntax error in there
# (measured). A PR touching only deploy scripts — which is what a deployment fix
# looks like — can therefore be approved and merged while being unparseable, and
# fail at deploy time on whichever chain the operator is pointed at. That is how
# a stray `}` in DeployAnvil.s.sol reached #404's approved head. Issue #406.
#
# BY FILE, NOT BY DIRECTORY, and the reason is worth keeping: this tree holds 113
# scripts and only these are reachable from deploy-core / deploy-sepolia.sh /
# audit-core. Fifteen of the rest import source files that no longer exist
# (contracts/src/paymasters/v2/..., v4/PaymasterV4.sol), and two more inside
# script/v3 itself are broken — L4GaslessTest.s.sol declares an identifier twice,
# DeployStandardV3.s.sol imports a deleted contract. A directory-scoped gate is
# red on arrival, and a gate that is always red is not a gate. Cleaning those up
# is separate work; this refuses to wait for it.
#
# Adding a script to the tooling? Add it here. A file listed but absent fails
# loudly rather than being skipped.
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/.."

LIVE=(
  contracts/script/v3/DeployLive.s.sol
  contracts/script/v3/DeployAnvil.s.sol
  contracts/script/v3/UpgradeLive.s.sol
  contracts/script/v3/InitializeAAStar.s.sol
  contracts/script/v3/InitializeMycelium.s.sol
  contracts/script/deployment/14_RedeployAPNTs.s.sol
  contracts/script/deployment/15_VerifyAPNTs.s.sol
)
# checks/ compiles clean as a directory, so take it wholesale — audit-core runs
# every Check*.s.sol in there by name, and listing them individually would rot.
LIVE_DIRS=( contracts/script/checks )

# The list above is hand-kept, so it is CHECKED against the router rather than
# trusted. deploy-core builds its path from a variable
# (forge script "contracts/script/v3/${SCRIPT_NAME}.s.sol"), so a grep for literal
# paths cannot see what it runs — which is exactly how UpgradeLive was missed in
# the first version of this gate: the live UPGRADE path, absent from a gate whose
# whole purpose is the live paths. Found by Codex.
# All three entry points, not just deploy-core: the header claims LIVE[] covers
# deploy-core, deploy-sepolia.sh and audit-core, and only the first was checked —
# a claimed scope one notch wider than the implemented one, which is the defect
# this repo keeps finding. deploy-sepolia.sh and audit-core use literal paths and
# a checks/ loop, so both forms are parsed. Raised by pr-daemon.
routed=""
# PER ENTRY POINT, not pooled. Pooling them meant deploy-core alone kept the
# combined list non-empty, so deploy-sepolia.sh or audit-core could stop
# contributing entirely — renamed, restructured, pattern gone stale — and the
# emptiness check would still pass while that entry point silently lost coverage.
# The previous commit fixed exactly this failure globally and left it per-file.
# Found by Codex.
for ep in deploy-core deploy-sepolia.sh audit-core; do
  if [ ! -f "$ep" ]; then
    echo "FAIL  entry point '$ep' not found; LIVE[] cannot be checked against it"
    missing=1
    continue
  fi
  # audit-core invokes only contracts/script/checks/Check*.s.sol, by NAME, in a
  # loop — it names no v3 script at all. Applying the v3 pattern to it read
  # "this entry point runs no v3 scripts" as "parsing failed", which is the same
  # confusion in the other direction: a legitimately empty result treated as a
  # broken instrument. Each entry point gets the pattern that matches how it
  # actually invokes scripts.
  ep_routes=$( { grep -oE 'SCRIPT_NAME="[A-Za-z0-9_]+"' "$ep" 2>/dev/null | sed 's/.*"\(.*\)"/\1/'
                 grep -ohE 'contracts/script/v3/[A-Za-z0-9_]+\.s\.sol' "$ep" 2>/dev/null \
                   | sed 's|.*/||; s|\.s\.sol$||'
                 # checks/ is covered wholesale by LIVE_DIRS, so these names are
                 # proof the entry point still invokes scripts, not entries to match.
                 grep -oE 'Check[0-9]+_[A-Za-z0-9_]+|VerifyV3_[0-9_]+' "$ep" 2>/dev/null \
                   | sed 's/^/__checksdir__/'
               } | sort -u )
  if [ -z "$ep_routes" ]; then
    echo "FAIL  parsed no scripts out of '$ep'."
    echo "      It either stopped invoking forge scripts or changed shape. Cannot"
    echo "      confirm LIVE[] still covers it, so not claiming that it does."
    missing=1
  else
    routed=$(printf '%s\n%s' "$routed" "$ep_routes")
  fi
done
routed=$(printf '%s\n' "$routed" | grep -v '^$' | sort -u)
for n in $routed; do
  case "$n" in __checksdir__*) continue ;; esac   # covered by LIVE_DIRS
  printf '%s\n' "${LIVE[@]}" | grep -q "/${n}\.s\.sol$" \
    || { echo "FAIL  an entry point routes to '$n' but it is not in LIVE[]"; missing=1; }
done

missing=${missing:-0}
for f in "${LIVE[@]}"; do
  [ -f "$f" ] || { echo "FAIL  listed but missing: $f"; missing=1; }
done
[ "$missing" -eq 0 ] || { echo "SCRIPT COMPILE GATE: FAIL (see above)"; exit 2; }

echo "compiling $((${#LIVE[@]})) live scripts + ${#LIVE_DIRS[@]} dir(s)…"
# NOT `--contracts`. It is a SINGLE-VALUE option, so bash expansion feeds it the
# array's FIRST element and the rest become positional arguments — silently
# excluding contracts/script/v3/DeployLive.s.sol, the script that deploys to a
# real chain and the entire reason this gate exists. The gate still printed
# "every script the tooling invokes compiles". Found by pr-daemon.
#
# My own four-way verification could not have caught it: I mutated DeployAnvil,
# the SECOND element, so a passing run was consistent with both "the gate works"
# and "the gate drops element one". The per-file matrix below exists because of
# that.
out=$(forge build "${LIVE[@]}" "${LIVE_DIRS[@]}" 2>&1); rc=$?
if [ $rc -ne 0 ]; then
  echo "$out" | grep -E "^Error|error\[|-->" | head -20
  echo "SCRIPT COMPILE GATE: FAIL — a live deployment script does not parse."
  exit 1
fi
echo "SCRIPT COMPILE GATE: OK — every script the tooling invokes compiles."
