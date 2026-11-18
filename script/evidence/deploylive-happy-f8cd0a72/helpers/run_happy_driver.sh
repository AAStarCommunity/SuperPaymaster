#!/bin/bash
# usage: run_happy_driver.sh RPC_URL ENVNAME GUARDIANS_FILE ; REHEARSAL ONLY. Secrets/URL only enter env, never printed.
cd /Users/jason/Dev/aastar/sp-wt/rc8-dlr
export PATH=$HOME/.foundry/bin:$PATH
source /Users/jason/Dev/aastar/manifest-live/tmp-evidence/deploylive-happy-f8cd0a72/inputs.happy.sh
export ENV="$2" GUARDIANS="$(cat "$3")"
export REHEARSAL_SOURCE_RPC="$(cat /Users/jason/Dev/aastar/manifest-live/.rpc/opa)"
export REHEARSAL_BLS_SCALARS="$(cat /Users/jason/Dev/aastar/manifest-live/tmp-evidence/keys/deploylive-happy-f8cd0a72/bls-scalars.json)"
test "$(cast client --rpc-url "$1")" = "anvil/v1.7.1" || exit 9
nice -n 10 python3 script/rehearsal/deploylive_rehearse.py happy "$1" "deployments/config.$2.json" "$DEPLOYER" "$GOVERNANCE_OWNER"
