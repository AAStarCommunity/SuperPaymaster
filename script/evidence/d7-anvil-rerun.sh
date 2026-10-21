#!/bin/bash
# D7 JS E2E rerun on a fresh local anvil (CC-125 DSR 9479dbd8 package ①).
# Usage: d7-anvil-rerun.sh <worktree at the commit under test> <out dir> <port>
# Contracts are deployed from, and the E2E harness is run from, the SAME worktree/commit.
# Local anvil only — not public-chain evidence, not A6 data.
set -uo pipefail
export PATH="$HOME/.foundry/bin:$PATH"
WT=$1; OUT=$2; P=$3; R=http://127.0.0.1:$P
K=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80   # anvil default #0 (public test key)
K1=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d  # anvil default #1
O=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
mkdir -p "$OUT"; : > "$OUT/steps.txt"
anvil --port $P --chain-id 31337 --hardfork prague > "$OUT/anvil.log" 2>&1 & AP=$!
trap 'kill $AP 2>/dev/null' EXIT
for i in $(seq 60); do cast chain-id --rpc-url $R >/dev/null 2>&1 && break; sleep 1; done
B0=$(cast block-number --rpc-url $R); N0=$(cast nonce --rpc-url $R $O)
{ echo "commit $(git -C "$WT" rev-parse HEAD)"
  echo "worktree clean (contracts script deploy-core prepare-test): $(git -C "$WT" diff --quiet HEAD -- contracts script deploy-core prepare-test && echo yes || echo NO)"
  echo "contracts/src vs v5.5.0-rc.2 1ac0e1c5: $(git -C "$WT" diff --quiet 1ac0e1c595dc84e684b540ca6a936168e922194f HEAD -- contracts/src && echo IDENTICAL || echo DIFFERS)"
  anvil --version | head -1; forge --version | head -1; echo "node $(node --version)"
  echo "argv: d7-anvil-rerun.sh <worktree> <out> $P"
  echo "E2E_BROADCAST_RPCS=http://127.0.0.1:9 (unreachable on purpose: same-anvil double-send self-induces nonce-too-low; empty falls back to Sepolia publicnode)"
  echo "fresh-chain control: block=$B0 deployerNonce=$N0 (must be 0/0)"; } > "$OUT/env.txt"
[ "$B0" = 0 ] && [ "$N0" = 0 ] || { echo "NOT FRESH" >> "$OUT/steps.txt"; exit 9; }
# The run rewrites abis/ and deployments/config.anvil.json (deploy-core) and restores them at the end;
# refuse to start if they already carry changes, so the restore can never discard someone's work.
git -C "$WT" diff --quiet HEAD -- abis deployments/config.anvil.json || { echo "REFUSE: abis/ or deployments/config.anvil.json not clean in $WT" | tee -a "$OUT/steps.txt"; exit 8; }
FAILED=0
step() { local name=$1; shift; "$@"; local rc=$?; echo "$name rc=$rc" >> "$OUT/steps.txt"; [ $rc -eq 0 ] || FAILED=1; return 0; }
cd "$WT"; export ANVIL_RPC_URL=$R
step deploy-core sh -c './deploy-core anvil --force > "$0/01-deploy-core.log" 2>&1' "$OUT"
step prepare-test sh -c './prepare-test anvil > "$0/02-prepare-test.log" 2>&1' "$OUT"
cp deployments/config.anvil.json "$OUT/config.anvil.json"
F=$(python3 -c "import json;print(json.load(open('$OUT/config.anvil.json'))['simpleAccountFactory'])")
SP=$(python3 -c "import json;print(json.load(open('$OUT/config.anvil.json'))['superPaymaster'])")
AA=(); for s in 0 1 2; do cast send --rpc-url $R --private-key $K $F 'createAccount(address,uint256)' $O $s >/dev/null; AA+=($(cast call --rpc-url $R $F 'getAddress(address,uint256)(address)' $O $s)); done
echo "AA accounts (factory.createAccount(anvil#0, salt 0/1/2)): ${AA[*]}" >> "$OUT/steps.txt"
cat > "$OUT/e2e.env" <<E2
SEPOLIA_RPC_URL=$R
RPC_URL=$R
E2E_BROADCAST_RPCS=http://127.0.0.1:9
CHAIN_ID=31337
CONFIG_PATH=$OUT/config.anvil.json
PRIVATE_KEY=$K
OWNER_PRIVATE_KEY=$K
ANNI_PRIVATE_KEY=$K1
PRIVATE_KEY_ANNI=$K1
DEPLOYER_ADDRESS=$O
OPERATOR_ADDRESS=$O
OPERATOR_ADDRESS_APNTS=$O
OPERATOR_ADDRESS_PNTS=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
OWNER2_ADDRESS=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC
TEST_EOA_ADDRESS=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC
TEST_AA_ACCOUNT_ADDRESS_A=${AA[0]}
TEST_AA_ACCOUNT_ADDRESS_B=${AA[1]}
TEST_AA_ACCOUNT_ADDRESS_C=${AA[2]}
TEST_AA_ACCOUNT_ADDRESS_1=${AA[0]}
TEST_AA_ACCOUNT_ADDRESS_2=${AA[1]}
SIMPLE_ACCOUNT_A=${AA[0]}
E2
step e2e sh -c 'ENV_FILE="$0/e2e.env" bash script/gasless-tests/run-all-e2e-tests.sh > "$0/03-e2e.log" 2>&1' "$OUT"
sed 's/\x1b\[[0-9;]*m//g' "$OUT/03-e2e.log" > "$OUT/03-e2e.clean.log"
# Post-suite: past the 48h creditPolicy timelock, refresh price (setup-gasless compares against the wall clock), rerun the gated cases.
cast rpc --rpc-url $R evm_increaseTime 172900 >/dev/null; cast rpc --rpc-url $R evm_mine >/dev/null
cast send --rpc-url $R --private-key $K $SP "updatePrice()" >/dev/null; echo "updatePrice after warp rc=$? priceValidUntil=$(cast call --rpc-url $R $SP 'priceValidUntil()(uint256)') block ts $(cast block latest --rpc-url $R -f timestamp)" >> "$OUT/steps.txt"
cd script/gasless-tests || { echo "cd script/gasless-tests rc=1" >> "$OUT/steps.txt"; exit 7; }
set -a; . "$OUT/e2e.env" || { echo "load e2e.env rc=1" >> "$OUT/steps.txt"; exit 7; }; set +a
step setup-after-warp sh -c 'node setup-gasless.js > "$0/04-setup-after-warp.log" 2>&1' "$OUT"
step tc4-after-warp sh -c 'node test-case-4-superpaymaster-credit-path.js > "$0/05-tc4-after-warp.log" 2>&1' "$OUT"
step tc2-after-warp sh -c 'TEST_AA_ACCOUNT_ADDRESS_B="$TEST_AA_ACCOUNT_ADDRESS_A" node test-case-2-superpaymaster-xpnts1-fixed.js > "$0/06-tc2-after-warp.log" 2>&1' "$OUT"
for f in "$OUT"/0[456]-*.log; do sed 's/\x1b\[[0-9;]*m//g' "$f" > "$f.tmp" && mv "$f.tmp" "$f"; done   # portable (no sed -i)
cd "$WT"; git checkout -q -- abis deployments/config.anvil.json || { echo "restore abis/config rc=1" >> "$OUT/steps.txt"; FAILED=1; }
cat "$OUT/steps.txt"; sed -n '/E2E Test Suite Summary/,$p' "$OUT/03-e2e.clean.log" | grep -E 'PASS|FAIL|SKIP|Total'
# Exit non-zero if any step failed (the suite itself fails on the known out-of-scope scripts;
# callers must read steps.txt for the per-step codes rather than treat 0 as "all green").
exit $FAILED
