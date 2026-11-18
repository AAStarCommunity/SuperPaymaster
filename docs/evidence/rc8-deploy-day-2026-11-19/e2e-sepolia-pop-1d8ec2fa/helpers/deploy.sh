#!/bin/bash
# usage: deploy.sh LOCAL_RPC LOGFILE ENVNAME [extra forge args...]  ; fork-only. Nightly forge 4e8874b.
RPC=$1; LOG=$2; NAME=$3; shift 3
cd /Users/jason/Dev/aastar/sp-wt/rc8-e2e || exit 1
[ -z "$(git status --porcelain)" ] || { echo 'STOP dirty worktree'; exit 1; }
source /Users/jason/Dev/aastar/manifest-live/tmp-evidence/e2e-sepolia-pop-1d8ec2fa/inputs.sepolia.phase2.sh
export ENV=$NAME
[ "$SP_COMMIT" = "$(git rev-parse HEAD)" ] || { echo 'STOP SP_COMMIT != HEAD'; exit 1; }
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1
N=${FORGE_DIR:-$HOME/Dev/aastar/tools/foundry-rams/nightly-4e8874b}; export PATH=$N:$PATH; CASTN=$HOME/Dev/aastar/tools/foundry-rams/nightly-4e8874b/cast
test "$($CASTN client --rpc-url "$RPC")" = "anvil/v1.8.7" || { echo "STOP not nightly anvil"; exit 9; }
case "$RPC" in http://127.0.0.1:*) ;; *) echo "STOP non-local rpc"; exit 9;; esac
export FOUNDRY_OUT=${XOUT:-cache/dlr-out-nightly} FOUNDRY_CACHE_PATH=${XCACHE:-cache/dlr-cache-nightly}
echo "cmd: forge script --offline contracts/script/v3/DeployLive.s.sol:DeployLive --rpc-url <local> --sender $DEPLOYER --unlocked --evm-version prague -vv $* (FOUNDRY_OUT=$FOUNDRY_OUT, forge $(forge --version|head -1), head $(git rev-parse HEAD), ENV=$NAME)" > "$LOG"
nice -n 10 forge script --offline contracts/script/v3/DeployLive.s.sol:DeployLive --rpc-url "$RPC" --sender "$DEPLOYER" --unlocked --evm-version prague -vv "$@" >> "$LOG" 2>&1
echo "exit=$?" >> "$LOG"
