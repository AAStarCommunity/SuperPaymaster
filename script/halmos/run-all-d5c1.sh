#!/usr/bin/env bash
# D5c-1 — the full set of Halmos runs behind docs/design/aoa-balance-mode/D5c-1-halmos.md.
#
# usage (repo root): script/halmos/run-all-d5c1.sh <group> [jobs]
#   groups: cap1 | rate | a3 | i2 | i4b | i6 | mint | lemma | settle | witness | all
# Output: docs/design/aoa-balance-mode/data/halmos/<Contract>.<check>/ (one log per partition +
#         summary.json/txt) and data/halmos/<name>.log for the unpartitioned runs.
# Halmos arguments: ONLY the named profiles of d5c1_binding.PROFILES (xp / lemma / cap1; `-fail` adds
# --early-exit and is used exactly for the expected-FAIL items: witnesses, the I2NoR negative
# control, the A-3 self-burn discrepancy). Every run: loop bound 2, --panic-error-codes '*', a 600 s
# hard wall cap (TIMEOUT-WALL), no retry (exactly one log per partition). verify-d5c1.py checks each
# log's recorded argument list against the profile its mandatory-suite item names.
#
# Exit code: every child's exit code is collected (run-partitioned: 0 = all PASS, 1 = not all PASS,
# anything else = error), and the run ends with script/halmos/verify-d5c1.py (logs + partitioned),
# the verdict authority. Exit 0 iff no child errored AND every expectation is met.
set -uo pipefail
export PATH="$HOME/.foundry/bin:$HOME/.local/bin:$PATH"
D=docs/design/aoa-balance-mode/data/halmos
G="${1:-all}"; J="${2:-6}"
P="python3 script/halmos/run-partitioned.py"
R=script/halmos/run-d5c1.sh
RC=0
chk() { if [ "$1" -gt 1 ]; then echo "CHILD-ERROR rc=$1 $2"; RC=1; fi; }
run() { # contract check abi profile [--only parts]
  local c="$1" f="$2" a="$3" p="$4"; shift 4
  $P "$c" "$f" "$a" "$D/$c.$f" --profile "$p" --jobs "$J" "$@"
  chk $? "$c.$f"
}
want() { [ "$G" = all ] || [ "$G" = "$1" ]; }

# warm-up: one unpartitioned run builds the harness with an AST (every later run is a cache no-op)
$R XPNTsV2RateHalmosTest "$D/rate-base.log" xp '^check_RATE_base' >/dev/null; chk $? rate-base

if want cap1; then
  $R APNTsCappedHalmosTest "$D/cap1.log" cap1 >/dev/null; chk $? cap1
  $R APNTsCappedWitnessHalmosTest "$D/cap1-witness.log" cap1-fail >/dev/null; chk $? cap1-witness
fi
if want rate; then
  run XPNTsV2RateHalmosTest check_RATE_step_coreAbi core xp
  run XPNTsV2RateHalmosTest check_RATE_step_extAbi ext xp
fi
if want a3; then
  run XPNTsV2A3HalmosTest check_A3_coreAbi core xp
  run XPNTsV2A3HalmosTest check_A3_extAbi ext xp
  run XPNTsV2A3NoSelfBurnHalmosTest check_A3_coreAbi core xp --only burn-9dc29fac
  run XPNTsV2A3Bit0HalmosTest check_A3_coreAbi core xp --only transferFrom
  run XPNTsV2A3Bit1HalmosTest check_A3_coreAbi core xp --only burn-9dc29fac
  run XPNTsV2A3HalmosTest check_A3_selfBurnDiscrepancy core xp-fail --only burn-9dc29fac
fi
if want i2; then
  run XPNTsV2I2HalmosTest check_I2_coreAbi core xp
  run XPNTsV2I2HalmosTest check_I2_extAbi ext xp
fi
if want i4b; then
  $R XPNTsV2I4BHalmosTest "$D/i4b-base.log" xp '^check_I4B_base' >/dev/null; chk $? i4b-base
  run XPNTsV2I4BHalmosTest check_I4B_coreAbi core xp
  run XPNTsV2I4BHalmosTest check_I4B_extAbi ext xp
fi
if want i6; then
  run XPNTsV2I6HalmosTest check_I6_coreAbi core xp
  run XPNTsV2I6HalmosTest check_I6_extAbi ext xp
  run XPNTsV2I6HalmosTest check_I6J_coreAbi core xp
  run XPNTsV2I6HalmosTest check_I6J_extAbi ext xp
fi
if want mint; then
  # the mint partition split on the victim's debt (debts(v) == 0 here; > 0 = lemma M)
  run XPNTsV2A3MintNoDebtHalmosTest check_A3_extAbi ext xp --only mint
  run XPNTsV2I2MintNoDebtHalmosTest check_I2_extAbi ext xp --only mint
  run XPNTsV2I4BMintNoDebtHalmosTest check_I4B_extAbi ext xp --only mint
  run XPNTsV2I6MintNoDebtHalmosTest check_I6_extAbi ext xp --only mint
  run XPNTsV2I6MintNoDebtHalmosTest check_I6J_extAbi ext xp --only mint
fi
if want lemma; then
  pids=()
  for f in check_LEMMA_M_repayNeverExceedsMint check_LEMMA_M1_floorDivTimesDivisor \
           check_LEMMA_M2_monotoneProduct check_LEMMA_M3_ceilDivByConstant; do
    $P MintRepayLemmaHalmosTest "$f" core "$D/MintRepayLemmaHalmosTest.$f" --profile lemma --jobs 1 --only OTHER &
    pids+=("$!")
  done
  for p in "${pids[@]}"; do wait "$p"; chk $? "lemma pid $p"; done
fi
if want settle; then
  run XPNTsV2A3xHalmosTest check_A3x_exactCeilBound core xp --only settleLocked
fi
if want witness; then
  run XPNTsV2I2NoRHalmosTest check_I2_coreAbi core xp-fail --only tryLockForGas
  run XPNTsV2WitnessPinnedHalmosTest check_witness_A3_spSettleBurnsVictim core xp-fail --only settleLocked
  run XPNTsV2WitnessHalmosTest check_witness_I2_spRenewIncrements core xp-fail --only tryLockForGas
  run XPNTsV2WitnessPinnedHalmosTest check_witness_I2_meteredPull core xp-fail --only transferFrom
  run XPNTsV2WitnessHalmosTest check_witness_I2_explicitPull core xp-fail --only transferFrom
  run XPNTsV2WitnessHalmosTest check_witness_I4B_outgoingWithLock core xp-fail --only transfer
  run XPNTsV2WitnessHalmosTest check_witness_I6_reservationAdmitted core xp-fail --only tryReserveCredit
  run XPNTsV2WitnessHalmosTest check_witness_I6_debtGrows core xp-fail --only settleCredit
fi
python3 script/halmos/verify-d5c1.py --only suite,logs,partitioned
V=$?
echo "RUN-ALL $G done (children rc=$RC, verify rc=$V)"
[ $RC -eq 0 ] && [ $V -eq 0 ] && exit 0
exit 1
