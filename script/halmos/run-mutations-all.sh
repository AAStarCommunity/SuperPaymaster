#!/usr/bin/env bash
# D5c-1 — every mutation of D5c-1-halmos.md §5, one after another, in the CURRENT checkout.
# Run it in a scratch copy of the tree (rsync contracts/ singleton-paymaster/ lib/ foundry.toml out/
# cache/ script/), so that evidence runs in the main tree never compile mutated source.
# usage: script/halmos/run-mutations-all.sh <out_root> [ID ...]   (default: all)
# Exit code: non-zero if ANY mutation was not killed as expected or its source was not restored.
set -uo pipefail
o="$1"; shift
M=script/halmos/run-mutation.sh
RC=0
sel() { [ $# -eq 0 ] && return 0; for x in "${IDS[@]}"; do [ "$x" = "$1" ] && return 0; done; return 1; }
IDS=("$@")
k() { local id="$2"; if [ ${#IDS[@]} -gt 0 ] && ! sel "$id"; then return; fi
  "$@"; local r=$?; [ $r -eq 0 ] || { echo "MUTATION-NOT-KILLED-OR-ERROR rc=$r: $id"; RC=1; }; }
k $M M-CAP1 "$o/M-CAP1" CAP1_scenario APNTsCappedHalmosTest:unpartitioned
k $M M-A3   "$o/M-A3"   A3_scenario_spCannotMove \
  XPNTsV2A3HalmosTest:check_A3_extAbi:ext:spPull:red \
  XPNTsV2A3HalmosTest:check_A3_coreAbi:core:OTHER:red
k $M M-A3TF "$o/M-A3TF" A3_scenario_spFirewallBits \
  XPNTsV2A3Bit0HalmosTest:check_A3_coreAbi:core:transferFrom:red \
  XPNTsV2A3Bit1HalmosTest:check_A3_coreAbi:core:burn-9dc29fac:green
k $M M-A3BF "$o/M-A3BF" A3_scenario_spFirewallBits \
  XPNTsV2A3Bit1HalmosTest:check_A3_coreAbi:core:burn-9dc29fac:red \
  XPNTsV2A3Bit0HalmosTest:check_A3_coreAbi:core:transferFrom:green
k $M M-I2   "$o/M-I2"   I2_scenario XPNTsV2I2HalmosTest:check_I2_coreAbi:core:tryLockForGas:red
k $M M-I4B  "$o/M-I4B"  I4B_scenario XPNTsV2I4BHalmosTest:check_I4B_coreAbi:core:transfer:red
k $M M-I6   "$o/M-I6"   I6_scenario \
  XPNTsV2I6HalmosTest:check_I6_coreAbi:core:tryReserveCredit:red \
  XPNTsV2I6HalmosTest:check_I6J_coreAbi:core:tryReserveCredit:red
k $M M-F1   "$o/M-F1"   REGRESSION_F1_rateOutOfRange XPNTsV2RateHalmosTest:unpartitioned:^check_RATE_base
python3 script/halmos/verify-d5c1.py --only mutations --mutations-dir "$o" || RC=1
exit $RC
