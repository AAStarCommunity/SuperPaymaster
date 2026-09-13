#!/usr/bin/env bash
# D5c-1 — one remaining group at a time, 10-minute hard cap per partition (coordinator's rule after
# the WIP checkpoint: anything over the cap is recorded TIMEOUT-WALL / TIMEOUT and the batch moves on).
# usage (repo root): script/halmos/run-step-d5c1.sh <i2ext|mint|lemma|a3x|nor|witness> [jobs]
set -uo pipefail
export PATH="$HOME/.foundry/bin:$HOME/.local/bin:$PATH"
D=docs/design/aoa-balance-mode/data/halmos
G="$1"; J="${2:-6}"
CAP=600
X=(--default-bytes-lengths 0,65 --statistics)
P="python3 script/halmos/run-partitioned.py"
run() { local c="$1" f="$2" a="$3"; shift 3
  $P "$c" "$f" "$a" "$D/$c.$f" --jobs "$J" --retry-timeout-ms 300000 --part-wall-cap-s $CAP "$@" -- "${X[@]}"; }
# harness artifacts left by a plain forge build lack an AST -> halmos would skip them; rebuild once
for d in out/APNTsCappedHalmos.t.sol out/XPNTsV2Halmos.t.sol out/XPNTsV2HalmosProbe.sol out/MintRepayLemma.t.sol; do
  [ -d "$d" ] || continue
  python3 -c 'import json,sys,glob; sys.exit(0 if all("ast" in json.load(open(f)) for f in glob.glob(sys.argv[1]+"/*.json")) else 1)' "$d" || rm -rf "$d"
done
forge build --ast --extra-output storageLayout metadata > /dev/null 2>&1
case "$G" in
  i2ext)   run XPNTsV2I2HalmosTest check_I2_extAbi ext ;;
  mint)    run XPNTsV2A3MintNoDebtHalmosTest check_A3_extAbi ext --only mint
           run XPNTsV2I2MintNoDebtHalmosTest check_I2_extAbi ext --only mint
           run XPNTsV2I6MintNoDebtHalmosTest check_I6_extAbi ext --only mint
           run XPNTsV2I6MintNoDebtHalmosTest check_I6J_extAbi ext --only mint ;;
  lemma)   for f in check_LEMMA_M_repayNeverExceedsMint check_LEMMA_M1_floorDivTimesDivisor \
                    check_LEMMA_M2_monotoneProduct check_LEMMA_M3_ceilDivByConstant; do
             $P MintRepayLemmaHalmosTest "$f" core "$D/MintRepayLemmaHalmosTest.$f" --jobs 1 --only OTHER \
               --retry-timeout-ms 0 --part-wall-cap-s $CAP -- --solver-timeout-assertion 540000 &
           done; wait ;;
  a3x)     run XPNTsV2A3xHalmosTest check_A3x_exactCeilBound core --only settleLocked ;;
  nor)     run XPNTsV2I2NoRHalmosTest check_I2_coreAbi core --only tryLockForGas ;;
  witness) run XPNTsV2WitnessHalmosTest check_witness_A3_spSettleBurnsVictim core --only settleLocked
           run XPNTsV2WitnessHalmosTest check_witness_I2_spRenewIncrements core --only tryLockForGas
           run XPNTsV2WitnessHalmosTest check_witness_I2_meteredPull core --only transferFrom
           run XPNTsV2WitnessHalmosTest check_witness_I6_reservationAdmitted core --only tryReserveCredit
           run XPNTsV2WitnessHalmosTest check_witness_I6_debtGrows core --only settleCredit ;;
esac
echo "STEP-DONE $G"
