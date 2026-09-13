#!/usr/bin/env bash
# D5c-1 — every mutation of D5c-1-halmos.md §5, one after another, in the CURRENT checkout.
# Run it in a scratch copy of the tree (rsync contracts/ singleton-paymaster/ foundry.toml out/
# cache/ script/), so that evidence runs in the main tree never compile mutated source.
# usage: script/halmos/run-mutations-all.sh <out_root>
set -uo pipefail
o="$1"
M=script/halmos/run-mutation.sh
$M M-CAP1 "$o/M-CAP1" CAP1_scenario APNTsCappedHalmosTest:unpartitioned
$M M-A3   "$o/M-A3"   A3_scenario \
  XPNTsV2A3HalmosTest:check_A3_extAbi:ext:spPull \
  XPNTsV2A3HalmosTest:check_A3_coreAbi:core:OTHER
$M M-I2   "$o/M-I2"   I2_scenario XPNTsV2I2HalmosTest:check_I2_coreAbi:core:tryLockForGas
$M M-I6   "$o/M-I6"   I6_scenario \
  XPNTsV2I6HalmosTest:check_I6_coreAbi:core:tryReserveCredit \
  XPNTsV2I6HalmosTest:check_I6J_coreAbi:core:tryReserveCredit
$M M-F1   "$o/M-F1"   REGRESSION_F1 \
  XPNTsV2RateHalmosTest:check_RATE_base_initialize:core:OTHER \
  XPNTsV2RateHalmosTest:check_RATE_base_realFactory:core:OTHER
