#!/usr/bin/env bash
# D5c-1 — the full set of Halmos runs behind docs/design/aoa-balance-mode/D5c-1-halmos.md.
#
# usage (repo root): script/halmos/run-all-d5c1.sh <group> [jobs]
#   groups: cap1 | rate | ext | core | mint | lemma | settle | witness | all
# Output: docs/design/aoa-balance-mode/data/halmos/<check>/ (one log per partition + summary.json/txt)
#         and docs/design/aoa-balance-mode/data/halmos/<name>.log for unpartitioned runs.
# Every xPNTs run uses: --default-bytes-lengths 0,65  --panic-error-codes '*'  (loop bound = default 2;
# each result line reports the loop bounds actually hit, "bounds: []" = none).
set -uo pipefail
export PATH="$HOME/.foundry/bin:$HOME/.local/bin:$PATH"
D=docs/design/aoa-balance-mode/data/halmos
G="${1:-all}"; J="${2:-6}"
X=(--default-bytes-lengths 0,65 --statistics)
P="python3 script/halmos/run-partitioned.py"

# warm-up: one unpartitioned run builds the harness with an AST (every later run is a cache no-op)
script/halmos/run-d5c1.sh XPNTsV2RateHalmosTest "$D/rate-base.log" --match-test '^check_RATE_base' >/dev/null

run() { # contract check abi [--only parts]
  local c="$1" f="$2" a="$3"; shift 3
  $P "$c" "$f" "$a" "$D/$c.$f" --jobs "$J" --retry-timeout-ms 300000 "$@" -- "${X[@]}"
}

want() { [ "$G" = all ] || [ "$G" = "$1" ]; }

if want cap1; then
  script/halmos/run-d5c1.sh APNTsCappedHalmosTest "$D/cap1.log" >/dev/null
  script/halmos/run-d5c1.sh APNTsCappedWitnessHalmosTest "$D/cap1-witness.log" >/dev/null
fi
if want rate; then
  run XPNTsV2RateHalmosTest check_RATE_step_coreAbi core
  run XPNTsV2RateHalmosTest check_RATE_step_extAbi ext
fi
if want ext; then
  run XPNTsV2A3HalmosTest check_A3_extAbi ext
  run XPNTsV2I2HalmosTest check_I2_extAbi ext
  run XPNTsV2I6HalmosTest check_I6_extAbi ext
  run XPNTsV2I6HalmosTest check_I6J_extAbi ext
fi
if want core; then
  run XPNTsV2A3HalmosTest check_A3_coreAbi core
  run XPNTsV2I2HalmosTest check_I2_coreAbi core
  run XPNTsV2I6HalmosTest check_I6_coreAbi core
  run XPNTsV2I6HalmosTest check_I6J_coreAbi core
fi
if want mint; then
  # the mint partition split on the victim's debt (debts(v) == 0 here; > 0 = lemma M)
  run XPNTsV2A3MintNoDebtHalmosTest check_A3_extAbi ext --only mint
  run XPNTsV2I2MintNoDebtHalmosTest check_I2_extAbi ext --only mint
  run XPNTsV2I6MintNoDebtHalmosTest check_I6_extAbi ext --only mint
  run XPNTsV2I6MintNoDebtHalmosTest check_I6J_extAbi ext --only mint
fi
if want lemma; then
  for f in check_LEMMA_M_repayNeverExceedsMint check_LEMMA_M1_floorDivTimesDivisor \
           check_LEMMA_M2_monotoneProduct check_LEMMA_M3_ceilDivByConstant; do
    $P MintRepayLemmaHalmosTest "$f" core "$D/MintRepayLemmaHalmosTest.$f" --jobs 1 --only OTHER \
      --retry-timeout-ms 0 -- --solver-timeout-assertion 600000 &
  done
  wait
fi
if want settle; then
  run XPNTsV2A3xHalmosTest check_A3x_exactCeilBound core --only settleLocked
fi
if want witness; then
  run XPNTsV2I2NoRHalmosTest check_I2_coreAbi core --only tryLockForGas
  run XPNTsV2WitnessHalmosTest check_witness_A3_spSettleBurnsVictim core --only settleLocked
  run XPNTsV2WitnessHalmosTest check_witness_I2_spRenewIncrements core --only tryLockForGas
  run XPNTsV2WitnessHalmosTest check_witness_I2_meteredPull core --only transferFrom
  run XPNTsV2WitnessHalmosTest check_witness_I6_reservationAdmitted core --only tryReserveCredit
  run XPNTsV2WitnessHalmosTest check_witness_I6_debtGrows core --only settleCredit
fi
