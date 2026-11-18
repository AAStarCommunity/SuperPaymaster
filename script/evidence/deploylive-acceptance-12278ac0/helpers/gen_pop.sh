#!/bin/bash
# usage: gen_pop.sh RPC_URL OUT_REL_PATH LOGFILE ; scalars read from keys file into env of forge only, never printed
set -e
cd /Users/jason/Dev/aastar/sp-wt/rc8-dlr
source /Users/jason/Dev/aastar/manifest-live/tmp-evidence/deploylive-acceptance-12278ac0/inputs.acceptance.sh
K=/Users/jason/Dev/aastar/manifest-live/tmp-evidence/keys/deploylive-acceptance-12278ac0/bls-scalars.json
eval "$(python3 -I -c "import json;ks=json.load(open('$K'));print('\n'.join(f'export ACC_BLS_SK_{i}={k}' for i,k in enumerate(ks)))")"
export ACC_GUARDIANS_OUT="$2"
test "$(~/.foundry/bin/cast client --rpc-url "$1")" = "anvil/v1.7.1"
nice -n 10 ~/.foundry/bin/forge script --offline contracts/test/scripts/acceptance/AcceptancePoP.s.sol:AcceptancePoP --rpc-url "$1" --evm-version prague -vv > "$3" 2>&1
