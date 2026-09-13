#!/usr/bin/env bash
# D5c-1 — the runs still missing after the WIP checkpoint 08172c7d, in the coordinator's priority
# order. Same options as run-all-d5c1.sh, plus a hard 60-minute wall cap per partition
# (run-partitioned.py --part-wall-cap-s 3600: the partition is killed and recorded TIMEOUT-WALL).
# usage (repo root): script/halmos/run-remaining-d5c1.sh [jobs]
set -uo pipefail
export PATH="$HOME/.foundry/bin:$HOME/.local/bin:$PATH"
D=docs/design/aoa-balance-mode/data/halmos
J="${1:-6}"
X=(--default-bytes-lengths 0,65 --statistics)
P="python3 script/halmos/run-partitioned.py"
run() { local c="$1" f="$2" a="$3"; shift 3
  $P "$c" "$f" "$a" "$D/$c.$f" --jobs "$J" --retry-timeout-ms 300000 --part-wall-cap-s 3600 "$@" -- "${X[@]}"; }

script/halmos/run-d5c1.sh XPNTsV2RateHalmosTest "$D/rate-base.log" --match-test '^check_RATE_base' >/dev/null   # AST warm-up
# (1) I6 / I6-J
run XPNTsV2I6HalmosTest check_I6_coreAbi core
run XPNTsV2I6HalmosTest check_I6_extAbi ext
run XPNTsV2I6HalmosTest check_I6J_coreAbi core
run XPNTsV2I6HalmosTest check_I6J_extAbi ext
# (2)+(3) I2 core and ext, full (the partial pre-checkpoint logs are replaced)
run XPNTsV2I2HalmosTest check_I2_coreAbi core
run XPNTsV2I2HalmosTest check_I2_extAbi ext
# (4) mint partition with debts(v) == 0
run XPNTsV2A3MintNoDebtHalmosTest check_A3_extAbi ext --only mint
run XPNTsV2I2MintNoDebtHalmosTest check_I2_extAbi ext --only mint
run XPNTsV2I6MintNoDebtHalmosTest check_I6_extAbi ext --only mint
run XPNTsV2I6MintNoDebtHalmosTest check_I6J_extAbi ext --only mint
# (5) lemma M, A3x, I2 without R, witnesses
for f in check_LEMMA_M_repayNeverExceedsMint check_LEMMA_M1_floorDivTimesDivisor \
         check_LEMMA_M2_monotoneProduct check_LEMMA_M3_ceilDivByConstant; do
  $P MintRepayLemmaHalmosTest "$f" core "$D/MintRepayLemmaHalmosTest.$f" --jobs 1 --only OTHER \
    --retry-timeout-ms 0 --part-wall-cap-s 3600 -- --solver-timeout-assertion 600000 &
done
run XPNTsV2A3xHalmosTest check_A3x_exactCeilBound core --only settleLocked
run XPNTsV2I2NoRHalmosTest check_I2_coreAbi core --only tryLockForGas
run XPNTsV2WitnessHalmosTest check_witness_A3_spSettleBurnsVictim core --only settleLocked
run XPNTsV2WitnessHalmosTest check_witness_I2_spRenewIncrements core --only tryLockForGas
run XPNTsV2WitnessHalmosTest check_witness_I2_meteredPull core --only transferFrom
run XPNTsV2WitnessHalmosTest check_witness_I6_reservationAdmitted core --only tryReserveCredit
run XPNTsV2WitnessHalmosTest check_witness_I6_debtGrows core --only settleCredit
wait
echo ALL-REMAINING-DONE
