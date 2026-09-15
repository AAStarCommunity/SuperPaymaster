#!/usr/bin/env bash
# D5c-1 — one group at a time, 10-minute hard cap per partition (anything over the cap is recorded
# TIMEOUT-WALL / TIMEOUT and the batch moves on). Every child exit code is collected; the final
# exit code is that of script/halmos/verify-d5c1.py restricted to this group's items (0 only if
# every check matches its expectation: PASS / FAIL-with-counterexample / allow-listed BOUNDED).
# usage (repo root): script/halmos/run-step-d5c1.sh <i2ext|mint|lemma|a3x|nor|witness|verify> [jobs]
#   verify: no Halmos run, only the verdict over the existing evidence (D5C1_ROOT / D5C1_EXPECT
#   environment overrides are honoured; used by script/halmos/verify-selftest.sh)
set -uo pipefail
export PATH="$HOME/.foundry/bin:$HOME/.local/bin:$PATH"
D=docs/design/aoa-balance-mode/data/halmos
G="$1"; J="${2:-6}"
CAP=600
X=(--default-bytes-lengths 0,65 --statistics --solver-timeout-assertion 300000)
P="python3 script/halmos/run-partitioned.py"
RC=0
chk() { # rc label : run-partitioned exits 0 (all PASS) or 1 (not all PASS: judged by verify); anything else is an error
  if [ "$1" -gt 1 ]; then echo "CHILD-ERROR rc=$1 $2"; RC=1; fi; }
run() { local c="$1" f="$2" a="$3"; shift 3
  $P "$c" "$f" "$a" "$D/$c.$f" --jobs "$J" --retry-timeout-ms 0 --part-wall-cap-s $CAP "$@" -- "${X[@]}"
  chk $? "$c.$f"; }
runx() { local c="$1" f="$2" a="$3"; shift 3   # expected-FAIL checks: stop at the first counterexample
  $P "$c" "$f" "$a" "$D/$c.$f" --jobs "$J" --retry-timeout-ms 0 --part-wall-cap-s $CAP "$@" -- "${X[@]}" --early-exit
  chk $? "$c.$f"; }
if [ "$G" != verify ]; then
  # harness artifacts left by a plain forge build lack an AST -> halmos would skip them; rebuild once
  for d in out/APNTsCappedHalmos.t.sol out/XPNTsV2Halmos.t.sol out/XPNTsV2HalmosProbe.sol out/MintRepayLemma.t.sol; do
    [ -d "$d" ] || continue
    python3 -c 'import json,sys,glob; sys.exit(0 if all("ast" in json.load(open(f)) for f in glob.glob(sys.argv[1]+"/*.json")) else 1)' "$d" || rm -rf "$d"
  done
  forge build --ast --extra-output storageLayout metadata > /dev/null 2>&1 || { echo "BUILD-ERROR"; exit 3; }
fi
FILTER=""
case "$G" in
  i2ext)   run XPNTsV2I2HalmosTest check_I2_extAbi ext; FILTER="XPNTsV2I2HalmosTest.check_I2_extAbi" ;;
  mint)    run XPNTsV2A3MintNoDebtHalmosTest check_A3_extAbi ext --only mint
           run XPNTsV2I2MintNoDebtHalmosTest check_I2_extAbi ext --only mint
           run XPNTsV2I6MintNoDebtHalmosTest check_I6_extAbi ext --only mint
           run XPNTsV2I6MintNoDebtHalmosTest check_I6J_extAbi ext --only mint; FILTER="MintNoDebt" ;;
  lemma)   pids=()
           for f in check_LEMMA_M_repayNeverExceedsMint check_LEMMA_M1_floorDivTimesDivisor \
                    check_LEMMA_M2_monotoneProduct check_LEMMA_M3_ceilDivByConstant; do
             $P MintRepayLemmaHalmosTest "$f" core "$D/MintRepayLemmaHalmosTest.$f" --jobs 1 --only OTHER \
               --retry-timeout-ms 0 --part-wall-cap-s $CAP -- --solver-timeout-assertion 540000 &
             pids+=("$!")
           done
           for p in "${pids[@]}"; do wait "$p"; chk $? "lemma pid $p"; done; FILTER="MintRepayLemma" ;;
  a3x)     run XPNTsV2A3xHalmosTest check_A3x_exactCeilBound core --only settleLocked; FILTER="A3x" ;;
  nor)     runx XPNTsV2I2NoRHalmosTest check_I2_coreAbi core --only tryLockForGas; FILTER="I2NoR" ;;
  witness) runx XPNTsV2WitnessHalmosTest check_witness_A3_spSettleBurnsVictim core --only settleLocked
           runx XPNTsV2WitnessHalmosTest check_witness_I2_spRenewIncrements core --only tryLockForGas
           runx XPNTsV2WitnessHalmosTest check_witness_I2_meteredPull core --only transferFrom
           runx XPNTsV2WitnessHalmosTest check_witness_I6_reservationAdmitted core --only tryReserveCredit
           runx XPNTsV2WitnessHalmosTest check_witness_I6_debtGrows core --only settleCredit; FILTER="witness" ;;
  verify)  FILTER="${D5C1_FILTER:-}" ;;
  *)       echo "unknown group $G"; exit 2 ;;
esac
if [ -n "$FILTER" ]; then python3 script/halmos/verify-d5c1.py --filter "$FILTER"; else python3 script/halmos/verify-d5c1.py; fi
V=$?
echo "STEP-DONE $G (children rc=$RC, verify rc=$V)"
[ $RC -eq 0 ] && [ $V -eq 0 ] && exit 0
exit 1
