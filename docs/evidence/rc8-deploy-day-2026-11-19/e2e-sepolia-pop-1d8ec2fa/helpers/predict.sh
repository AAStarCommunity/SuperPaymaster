#!/bin/bash
# usage: predict.sh LOCAL_RPC REQUEST_PATH LOGFILE ; simulation only, NO --broadcast. Nightly forge (Amsterdam engine).
cd /Users/jason/Dev/aastar/sp-wt/rc8-e2e || exit 1
[ -z "$(git status --porcelain)" ] || { echo 'STOP dirty worktree'; exit 1; }
source /Users/jason/Dev/aastar/manifest-live/tmp-evidence/e2e-sepolia-pop-1d8ec2fa/inputs.sepolia.sh
[ "$SP_COMMIT" = "$(git rev-parse HEAD)" ] || { echo 'STOP SP_COMMIT != HEAD'; exit 1; }
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1
N=$HOME/Dev/aastar/tools/foundry-rams/nightly-4e8874b
export PATH=$N:$PATH
test "$(cast client --rpc-url "$1")" = "anvil/v1.8.7" || { echo "STOP not nightly anvil"; exit 9; }
export DEPLOYLIVE_POP_REQUEST_OUT="$2"
export FOUNDRY_OUT=cache/deploylive-rehearsal-out FOUNDRY_CACHE_PATH=cache/deploylive-rehearsal-cache
echo "cmd: forge script --offline contracts/script/v3/DeployLive.s.sol:DeployLive --rpc-url <local> --sender $DEPLOYER --unlocked --evm-version prague -vv (forge $(forge --version|head -1), head $(git rev-parse HEAD), POP_REQUEST_OUT=$2)" > "$3"
nice -n 10 forge script --offline contracts/script/v3/DeployLive.s.sol:DeployLive --rpc-url "$1" --sender "$DEPLOYER" --unlocked --evm-version prague -vv >> "$3" 2>&1
echo "exit=$?" >> "$3"
