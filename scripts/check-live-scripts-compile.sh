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
  contracts/script/v3/InitializeAAStar.s.sol
  contracts/script/v3/InitializeMycelium.s.sol
  contracts/script/deployment/14_RedeployAPNTs.s.sol
  contracts/script/deployment/15_VerifyAPNTs.s.sol
)
# checks/ compiles clean as a directory, so take it wholesale — audit-core runs
# every Check*.s.sol in there by name, and listing them individually would rot.
LIVE_DIRS=( contracts/script/checks )

missing=0
for f in "${LIVE[@]}"; do
  [ -f "$f" ] || { echo "FAIL  listed but missing: $f"; missing=1; }
done
[ "$missing" -eq 0 ] || { echo "SCRIPT COMPILE GATE: FAIL (see above)"; exit 2; }

echo "compiling $((${#LIVE[@]})) live scripts + ${#LIVE_DIRS[@]} dir(s)…"
out=$(forge build --contracts "${LIVE[@]}" "${LIVE_DIRS[@]}" 2>&1); rc=$?
if [ $rc -ne 0 ]; then
  echo "$out" | grep -E "^Error|error\[|-->" | head -20
  echo "SCRIPT COMPILE GATE: FAIL — a live deployment script does not parse."
  exit 1
fi
echo "SCRIPT COMPILE GATE: OK — every script the tooling invokes compiles."
