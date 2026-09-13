#!/usr/bin/env bash
# D5c-1 — negative / positive controls for the verification runners themselves.
# Builds small fake evidence trees and checks that the verdict authority (verify-d5c1.py) and the
# orchestrator entry point (run-step-d5c1.sh verify) exit non-zero exactly when they must:
#   P1  all expectations met                                   -> exit 0
#   N1  a PASS-expected partition FAILs                        -> exit != 0
#   N2  a witness (expect FAIL) PASSes (vacuous harness)       -> exit != 0
#   N3  a witness FAILs but WITHOUT a counterexample           -> exit != 0
#   N4  a TIMEOUT partition not on the allow-list              -> exit != 0
#   P2  the same TIMEOUT partition on the allow-list           -> exit 0
#   N5  a partition log with no result line (aborted run)      -> exit != 0
#   N6  a mutation that stays green (Halmos PASS, scenario PASS) -> exit != 0
#   N7  a mutation whose source was not restored (sha differs) -> exit != 0
#   N8  a fuzz liveness mutation that stays green              -> exit != 0
#   N9  the unmutated fuzz run is not green                    -> exit != 0
#   O1  run-step-d5c1.sh verify propagates a mismatch          -> exit != 0
#   O2  run-step-d5c1.sh verify on a clean fake tree           -> exit 0
# usage (repo root): script/halmos/verify-selftest.sh   (exit 0 iff every control behaves)
set -uo pipefail
V="python3 script/halmos/verify-d5c1.py"
T="$(mktemp -d "${TMPDIR:-/tmp}/d5c1-selftest.XXXXXX")"
trap 'rm -rf "$T"' EXIT
FAILS=0
expect() { # name expected(0|nonzero) cmd...
  local name="$1" want="$2"; shift 2
  "$@" > "$T/$name.out" 2>&1; local rc=$?
  if { [ "$want" = 0 ] && [ $rc -eq 0 ]; } || { [ "$want" = nonzero ] && [ $rc -ne 0 ]; }; then
    echo "ok    $name (rc=$rc, wanted $want)"
  else
    echo "FAIL  $name (rc=$rc, wanted $want)"; tail -5 "$T/$name.out"; FAILS=$((FAILS + 1))
  fi
}
pass_line() { printf '[PASS] %s() (paths: 3, time: 0.1s, bounds: [])\n# exit_code: 0  wall_seconds: 1\n' "$1"; }
fail_line() { printf 'Counterexample: \n    p_x = 0x01\n[FAIL] %s() (paths: 3, time: 0.1s, bounds: [])\n# exit_code: 1  wall_seconds: 1\n' "$1"; }
fail_nocex() { printf '[FAIL] %s() (paths: 3, time: 0.1s, bounds: [])\n# exit_code: 1  wall_seconds: 1\n' "$1"; }
tout_line() { printf '[TIMEOUT] %s() (paths: 3, time: 60.0s, bounds: [])\n# exit_code: 1  wall_seconds: 61\n' "$1"; }

mk() { # root: a PASS check (2 parts), a witness check, a mutation, a fuzz liveness set
  local R="$1"; mkdir -p "$R/C.check_P" "$R/W.check_W" "$R/mutations/M-X/C.check_P" "$R/fuzz-liveness"
  pass_line check_P > "$R/C.check_P/check_P.OTHER.log"
  pass_line check_P > "$R/C.check_P/check_P.foo-00000001.log"
  fail_line check_W > "$R/W.check_W/check_W.OTHER.log"
  fail_line check_P > "$R/mutations/M-X/C.check_P/check_P.foo-00000001.log"
  echo "applied M-X to f.sol (pristine sha256 $(printf 'a%.0s' {1..64}); diff in x)" > "$R/mutations/M-X/apply.txt"
  echo "reverted M-X: f.sol sha256 $(printf 'a%.0s' {1..64})" > "$R/mutations/M-X/summary.txt"
  echo "[FAIL: bitmask: 1 != 0] test_scen() (gas: 1)" > "$R/mutations/M-X/scenario.log"
  echo "[PASS] testFuzz_t(uint256) (runs: 10000, μ: 1, ~: 1)" > "$R/fuzz-liveness/unmutated.log"
  echo "applied M-Y to f.sol (pristine sha256 $(printf 'b%.0s' {1..64}); diff in x)" > "$R/fuzz-liveness/M-Y.apply.txt"
  printf '[FAIL: red; counterexample: calldata=0x args=[1]] testFuzz_t(uint256) (runs: 3)\nreverted M-Y: f.sol sha256 %s\n' "$(printf 'b%.0s' {1..64})" > "$R/fuzz-liveness/M-Y.fuzz.log"
}
cat > "$T/expect.json" <<'EOF'
{"logs": [],
 "partitioned": [
   {"dir": "C.check_P", "expect": "PASS", "min_parts": 2, "allow_bounded": {"bar-00000002": {"reason": "r", "substitute": "s"}}},
   {"dir": "W.check_W", "expect": "FAIL", "min_parts": 1}],
 "mutations": [{"id": "M-X", "halmos_logs": [], "halmos_parts": [{"dir": "C.check_P", "part_prefix": "foo"}],
                "scenario_test": "test_scen", "scenario_msg": "1 != 0"}],
 "fuzz_liveness": {"unmutated_log": "unmutated.log", "unmutated_tests": ["testFuzz_t"],
                   "mutations": [{"id": "M-Y", "must_fail": ["testFuzz_t"]}]}}
EOF
E="$T/expect.json"
fresh() { rm -rf "$T/r"; mk "$T/r"; }

fresh; expect P1_all_met 0 $V --root "$T/r" --expect "$E"
fresh; fail_line check_P > "$T/r/C.check_P/check_P.foo-00000001.log"; expect N1_pass_check_fails nonzero $V --root "$T/r" --expect "$E"
fresh; pass_line check_W > "$T/r/W.check_W/check_W.OTHER.log"; expect N2_witness_passes nonzero $V --root "$T/r" --expect "$E"
fresh; fail_nocex check_W > "$T/r/W.check_W/check_W.OTHER.log"; expect N3_witness_no_cex nonzero $V --root "$T/r" --expect "$E"
fresh; tout_line check_P > "$T/r/C.check_P/check_P.foo-00000001.log"; expect N4_timeout_not_allowed nonzero $V --root "$T/r" --expect "$E"
fresh; tout_line check_P > "$T/r/C.check_P/check_P.bar-00000002.log"; expect P2_timeout_allowed 0 $V --root "$T/r" --expect "$E"
fresh; printf '# halmos started\n' > "$T/r/C.check_P/check_P.foo-00000001.log"; expect N5_aborted_part nonzero $V --root "$T/r" --expect "$E"
fresh; pass_line check_P > "$T/r/mutations/M-X/C.check_P/check_P.foo-00000001.log"
       echo "[PASS] test_scen() (gas: 1)" > "$T/r/mutations/M-X/scenario.log"; expect N6_mutation_survives nonzero $V --root "$T/r" --expect "$E"
fresh; echo "reverted M-X: f.sol sha256 $(printf 'c%.0s' {1..64})" > "$T/r/mutations/M-X/summary.txt"; expect N7_not_restored nonzero $V --root "$T/r" --expect "$E"
fresh; printf '[PASS] testFuzz_t(uint256) (runs: 10000)\nreverted M-Y: f.sol sha256 %s\n' "$(printf 'b%.0s' {1..64})" > "$T/r/fuzz-liveness/M-Y.fuzz.log"
       expect N8_fuzz_mutation_survives nonzero $V --root "$T/r" --expect "$E"
fresh; echo "[FAIL: x] testFuzz_t(uint256) (runs: 3)" > "$T/r/fuzz-liveness/unmutated.log"; expect N9_unmutated_fuzz_red nonzero $V --root "$T/r" --expect "$E"
fresh; fail_line check_P > "$T/r/C.check_P/check_P.OTHER.log"
       expect O1_orchestrator_propagates nonzero env D5C1_ROOT="$T/r" D5C1_EXPECT="$E" script/halmos/run-step-d5c1.sh verify
fresh; expect O2_orchestrator_clean 0 env D5C1_ROOT="$T/r" D5C1_EXPECT="$E" script/halmos/run-step-d5c1.sh verify
echo
if [ $FAILS -eq 0 ]; then echo "SELFTEST: all 13 controls behave"; exit 0; fi
echo "SELFTEST: $FAILS control(s) misbehave"; exit 1
