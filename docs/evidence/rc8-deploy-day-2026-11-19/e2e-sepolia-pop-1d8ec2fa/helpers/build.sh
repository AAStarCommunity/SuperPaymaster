#!/bin/bash
# Builds in the rc8-e2e worktree with forge 1.7.1 (CI engine). Prague full tree into separate out/cache, then default Cancun into out/.
cd /Users/jason/Dev/aastar/sp-wt/rc8-e2e || exit 1
E=/Users/jason/Dev/aastar/manifest-live/tmp-evidence/e2e-sepolia-pop-1d8ec2fa
F=$HOME/.foundry/bin/forge
H=$(git rev-parse HEAD)
{ echo "cmd: FOUNDRY_OUT=cache/deploylive-rehearsal-out FOUNDRY_CACHE_PATH=cache/deploylive-rehearsal-cache nice -n 10 forge build --offline --evm-version prague (forge $($F --version|head -1), head $H)"
  FOUNDRY_OUT=cache/deploylive-rehearsal-out FOUNDRY_CACHE_PATH=cache/deploylive-rehearsal-cache nice -n 10 $F build --offline --evm-version prague; echo "exit=$?"; } > $E/build-prague-full.log 2>&1
{ echo "cmd: nice -n 10 forge build --offline (default profile, out/; forge $($F --version|head -1), head $H)"
  nice -n 10 $F build --offline; echo "exit=$?"; } > $E/build-cancun-out.log 2>&1
{ echo "cmd: python3 script/rehearsal/creation_pins.py --check deployments/creation-pins.11155111.json --artifacts out (PATH has forge 1.7.1 bin)"
  PATH=$HOME/.foundry/bin:$PATH python3 script/rehearsal/creation_pins.py --check deployments/creation-pins.11155111.json --artifacts out; echo "exit=$?"; } > $E/creation-pins-check.log 2>&1
echo "status after build:"; git status --porcelain | head
