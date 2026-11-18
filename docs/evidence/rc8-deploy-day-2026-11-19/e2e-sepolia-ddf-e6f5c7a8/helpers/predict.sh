#!/bin/bash
# usage: predict.sh LOCAL_RPC LOGFILE ; PoP prediction per DEPLOYLIVE_HANDOFF (no --broadcast). Request written in worktree.
cd /Users/jason/Dev/aastar/sp-wt/rc8-e2e || exit 1
case "$1" in http://127.0.0.1:*) ;; *) echo "STOP non-local rpc"; exit 9;; esac
[ -z "$(git status --porcelain)" ] || { echo 'STOP dirty worktree'; exit 1; }
source /Users/jason/Dev/aastar/manifest-live/tmp-evidence/e2e-sepolia-ddf-e6f5c7a8/inputs.env.sh
export SP_COMMIT="$(git rev-parse HEAD)"
[ "$SP_COMMIT" = e6f5c7a8973096a1c547da765390fa9ddef9e71a ] || { echo 'STOP head'; exit 1; }
mkdir -p deployments/live cache/ddf
export DEPLOYLIVE_POP_REQUEST_OUT=cache/ddf/pop-request.json
rm -f "$DEPLOYLIVE_POP_REQUEST_OUT"
python3 -c "import os,sys;sys.path.insert(0,'script/rehearsal');from deploylive_deploy_day import verify_build;verify_build(dict(os.environ),True)" > "$2" 2>&1 || { echo "STOP verify_build"; cat "$2"; exit 1; }
echo "cmd: \$FORGE script --offline contracts/script/v3/DeployLive.s.sol:DeployLive --rpc-url <local fork> --sender $DEPLOYER_ADDRESS --slow --evm-version prague --hardfork $DEPLOYLIVE_HARDFORK --gas-estimate-multiplier 130 -vv --unlocked (no --broadcast); POP_REQUEST_OUT=$DEPLOYLIVE_POP_REQUEST_OUT head $SP_COMMIT" >> "$2"
nice -n 10 "$FORGE" script --offline contracts/script/v3/DeployLive.s.sol:DeployLive --rpc-url "$1" --sender "$DEPLOYER_ADDRESS" --slow --evm-version prague --hardfork "$DEPLOYLIVE_HARDFORK" --gas-estimate-multiplier 130 -vv --unlocked >> "$2" 2>&1
echo "exit=$?" >> "$2"
