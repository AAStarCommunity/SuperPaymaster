#!/bin/bash
# Runs the documented fork driver: deploylive_fork_deploy.py <fork-rpc> <deployer>. Fork-only.
cd /Users/jason/Dev/aastar/sp-wt/rc8-e2e || exit 1
[ -z "$(git status --porcelain)" ] || { echo 'STOP dirty worktree'; exit 1; }
source /Users/jason/Dev/aastar/manifest-live/tmp-evidence/e2e-sepolia-ddf-e6f5c7a8/inputs.env.sh
unset DEPLOYLIVE_POP_REQUEST_OUT
export GUARDIANS="$(cat /Users/jason/Dev/aastar/manifest-live/tmp-evidence/e2e-sepolia-ddf-e6f5c7a8/guardians.hex)"
# Fork rehearsal: both "real-chain" read endpoints point at the local fork (driver requires distinct strings).
export DEPLOYLIVE_SOURCE_RPC=http://127.0.0.1:8621 DEPLOYLIVE_SECOND_RPC=http://localhost:8621
# cast/forge on PATH for checker subprocesses: the pinned nightly engine dir.
export PATH=/Users/jason/Dev/aastar/tools/foundry-rams/nightly-4e8874b:$PATH
nice -n 10 python3 script/rehearsal/deploylive_fork_deploy.py http://127.0.0.1:8621 "$DEPLOYER_ADDRESS"
echo "exit=$?"
