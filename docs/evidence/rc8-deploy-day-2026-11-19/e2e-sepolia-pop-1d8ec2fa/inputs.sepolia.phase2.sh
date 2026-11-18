# PHASE 2 overrides on top of inputs.sepolia.sh (DSR ruling). Public, non-secret.
source /Users/jason/Dev/aastar/manifest-live/tmp-evidence/e2e-sepolia-pop-1d8ec2fa/inputs.sepolia.sh
# PLACEHOLDER (rehearsal only, not a production principal): fresh `cast wallet new` address, key discarded
export GUARDIAN_ADDRESS=0x624D8497A04b343ab491af82B2AD8FdBdc12C642
# PLACEHOLDER (rehearsal only, not a production principal): fresh `cast wallet new` address, key discarded
export SP_GUARDIAN=0xBa8AfE220C8ee8108878D4C358D104D408D893B3
# Genesis operator: Anni (DSR ruling)
export GENESIS_AASTAR_OPERATOR=0xEcAACb915f7D92e9916f449F7ad42BD0408733c9
# Execution hardfork actually used by the forge runtime in PHASE 2 (compile target stays prague)
export DEPLOYLIVE_EVM_VERSION=amsterdam
export GUARDIANS="$(cat /Users/jason/Dev/aastar/manifest-live/tmp-evidence/e2e-sepolia-pop-1d8ec2fa/guardians.hex)"
unset DEPLOYLIVE_POP_REQUEST_OUT
