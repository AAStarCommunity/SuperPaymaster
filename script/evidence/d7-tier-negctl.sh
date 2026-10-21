#!/bin/bash
# D7 setup-gasless credit-tier raise: old (68dfdccb) vs new negative control on a [100,250,300] schedule
# (DSR CC-125 b219c6ac item B). For each version: fresh anvil -> deploy-core -> prepare-test -> 3 AA
# accounts -> Registry.setCreditTier(2, 250e18) so tiers are [100, 250, 300, ...] -> run that version's
# setup-gasless.js -> read creditTierConfig(1..3).
# Expected: old scan stops at tier 2 (250 >= 200), writes tier 1 = 300 > 250 -> CreditTiersNotMonotonic
#   (swallowed as non-fatal) -> tier 1 stays 100.  New scan collects levels below 300 -> tiers 1,2 = 300.
# Usage: d7-tier-negctl.sh <worktree> <out dir> <port>     Local anvil only — not public-chain evidence.
set -uo pipefail
export PATH="$HOME/.foundry/bin:$PATH"
WT=$1; OUT=$2; P=$3; R=http://127.0.0.1:$P
K=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80   # anvil default #0 (public test key)
K1=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d  # anvil default #1
O=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
OLD_REF=68dfdccb
mkdir -p "$OUT"; : > "$OUT/results.tsv"
git -C "$WT" diff --quiet HEAD -- abis deployments/config.anvil.json script/gasless-tests || { echo "REFUSE: $WT not clean"; exit 8; }
{ echo "commit $(git -C "$WT" rev-parse HEAD)"; echo "new setup-gasless blob $(git -C "$WT" rev-parse HEAD:script/gasless-tests/setup-gasless.js)"
  echo "old setup-gasless blob $(git -C "$WT" rev-parse $OLD_REF:script/gasless-tests/setup-gasless.js) ($OLD_REF)"
  anvil --version | head -1; forge --version | head -1; echo "node $(node --version)"; echo "argv: d7-tier-negctl.sh <worktree> <out> $P"; echo "runner sha256 $(shasum -a 256 "$0" | cut -d" " -f1)"; } > "$OUT/env.txt"
FAILED=0
run_one() {  # $1 = label (old|new); $2 = path of the setup-gasless.js to run (inside script/gasless-tests)
  local L=$1 S=$2 D="$OUT/$1"; mkdir -p "$D"
  anvil --port $P --chain-id 31337 --hardfork prague > "$D/anvil.log" 2>&1 & local AP=$!
  for i in $(seq 60); do cast chain-id --rpc-url $R >/dev/null 2>&1 && break; sleep 1; done
  local B0 N0; B0=$(cast block-number --rpc-url $R); N0=$(cast nonce --rpc-url $R $O)
  echo "fresh-chain control: block=$B0 nonce=$N0" > "$D/steps.txt"
  [ "$B0" = 0 ] && [ "$N0" = 0 ] || { echo "NOT FRESH" >> "$D/steps.txt"; kill $AP; FAILED=1; return; }
  ( cd "$WT" && ANVIL_RPC_URL=$R ./deploy-core anvil --force > "$D/01-deploy-core.log" 2>&1 ); echo "deploy-core rc=$?" >> "$D/steps.txt"
  ( cd "$WT" && ANVIL_RPC_URL=$R ./prepare-test anvil > "$D/02-prepare-test.log" 2>&1 ); echo "prepare-test rc=$?" >> "$D/steps.txt"
  cp "$WT/deployments/config.anvil.json" "$D/config.anvil.json"
  local REG F; REG=$(python3 -c "import json;print(json.load(open('$D/config.anvil.json'))['registry'])")
  F=$(python3 -c "import json;print(json.load(open('$D/config.anvil.json'))['simpleAccountFactory'])")
  local AA=(); for s in 0 1 2; do cast send --rpc-url $R --private-key $K $F 'createAccount(address,uint256)' $O $s >/dev/null; AA+=($(cast call --rpc-url $R $F 'getAddress(address,uint256)(address)' $O $s)); done
  cast send --rpc-url $R --private-key $K $REG 'setCreditTier(uint256,uint256)' 2 250000000000000000000 >/dev/null; echo "setCreditTier(2,250e18) rc=$?" >> "$D/steps.txt"
  for l in 1 2 3; do echo "before tier$l $(cast call --rpc-url $R $REG 'creditTierConfig(uint256)(uint256)' $l | awk '{print $1}')"; done >> "$D/steps.txt"
  cat > "$D/e2e.env" <<E2
SEPOLIA_RPC_URL=$R
RPC_URL=$R
E2E_BROADCAST_RPCS=http://127.0.0.1:9
CHAIN_ID=31337
CONFIG_PATH=$D/config.anvil.json
PRIVATE_KEY=$K
OWNER_PRIVATE_KEY=$K
ANNI_PRIVATE_KEY=$K1
PRIVATE_KEY_ANNI=$K1
TEST_AA_ACCOUNT_ADDRESS_A=${AA[0]}
TEST_AA_ACCOUNT_ADDRESS_B=${AA[1]}
TEST_AA_ACCOUNT_ADDRESS_C=${AA[2]}
E2
  ( cd "$WT/script/gasless-tests" && set -a && . "$D/e2e.env" && set +a && node "$S" > "$D/03-setup-gasless.log" 2>&1 ); echo "setup-gasless($L) rc=$?" >> "$D/steps.txt"
  local t1 t2 t3; t1=$(cast call --rpc-url $R $REG 'creditTierConfig(uint256)(uint256)' 1 | awk '{print $1}')
  t2=$(cast call --rpc-url $R $REG 'creditTierConfig(uint256)(uint256)' 2 | awk '{print $1}'); t3=$(cast call --rpc-url $R $REG 'creditTierConfig(uint256)(uint256)' 3 | awk '{print $1}')
  echo "after tier1 $t1"$'\n'"after tier2 $t2"$'\n'"after tier3 $t3" >> "$D/steps.txt"
  local nm; nm=$(grep -c 'non-fatal' "$D/03-setup-gasless.log")
  printf '%s\t%s\t%s\t%s\tnon-fatal-swallowed=%s\n' "$L" "$t1" "$t2" "$t3" "$nm" >> "$OUT/results.tsv"
  kill $AP 2>/dev/null; wait $AP 2>/dev/null
  ( cd "$WT" && git checkout -q -- abis deployments/config.anvil.json ) || { echo "restore rc=1" >> "$D/steps.txt"; FAILED=1; }
}
OLDJS="$WT/script/gasless-tests/setup-gasless.old-negctl.js"
# Extraction must succeed and yield the real file: an empty/missing old script would "succeed" in node,
# leave tier 1 at 100 and make the verdict pass vacuously (Codex challenge on 6645c13f).
git -C "$WT" show $OLD_REF:script/gasless-tests/setup-gasless.js > "$OLDJS" || { echo "REFUSE: cannot extract $OLD_REF setup-gasless.js"; exit 8; }
[ "$(git -C "$WT" rev-parse $OLD_REF:script/gasless-tests/setup-gasless.js)" = "$(git hash-object "$OLDJS")" ] || { echo "REFUSE: extracted old setup-gasless.js does not match its blob"; exit 8; }
grep -q 'Ensure Base Credit Tier' "$OLDJS" || { echo "REFUSE: old setup-gasless.js lacks the tier step"; exit 8; }
run_one old setup-gasless.old-negctl.js
rm -f "$WT/script/gasless-tests/setup-gasless.old-negctl.js"
run_one new setup-gasless.js
# Verdict: old must leave tier1 = 100e18 (the defect), new must raise tiers 1 and 2 to 300e18 (the fix).
OLD=$(awk -F'\t' '$1=="old"{print $2}' "$OUT/results.tsv"); NEW1=$(awk -F'\t' '$1=="new"{print $2}' "$OUT/results.tsv"); NEW2=$(awk -F'\t' '$1=="new"{print $3}' "$OUT/results.tsv")
# The defect must be OBSERVED, not just inferred from an unchanged tier: the old run must have swallowed
# CreditTiersNotMonotonic (selector 0x89f9d354; the script truncates the message, so match its prefix)
# and the new run must have swallowed nothing.
OLD_SEL=$(grep -c 'non-fatal.*0x89f9d35' "$OUT/old/03-setup-gasless.log"); NEW_NF=$(grep -c 'non-fatal' "$OUT/new/03-setup-gasless.log")
echo "old swallowed CreditTiersNotMonotonic lines: $OLD_SEL; new non-fatal lines: $NEW_NF" >> "$OUT/results.tsv"
if [ "$OLD" = 100000000000000000000 ] && [ "$OLD_SEL" -ge 1 ] && [ "$NEW_NF" = 0 ] && [ "$NEW1" = 300000000000000000000 ] && [ "$NEW2" = 300000000000000000000 ]; then echo "VERDICT PASS: old leaves tier1=100 (defect reproduced), new raises tiers 1,2 to 300" | tee "$OUT/verdict.txt"; else echo "VERDICT FAIL: old tier1=$OLD new tier1=$NEW1 tier2=$NEW2" | tee "$OUT/verdict.txt"; FAILED=1; fi
cat "$OUT/results.tsv"
exit $FAILED
