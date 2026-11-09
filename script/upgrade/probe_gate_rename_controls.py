#!/usr/bin/env python3
"""Focused proxy, calldata and receipt-index rename controls; never the full batch."""
import sys
from pathlib import Path
import probe_phase_c_gates as driver
from test_gate_rename_controls import RenameControls

CASES = (
    ('test_receipt_transaction_index_typed', 'safe_gap_log_transactionIndex_typed'),
    ('test_unexpected_proxy_other', 'unexpected_proxy_other'),
    ('test_unexpected_proxy_beacon', 'unexpected_proxy_beacon'),
    ('test_old_owner_calldata_bytes_outer_tx', 'old_owner_calldata_bytes_outer_tx'),
    ('test_old_owner_calldata_bytes_payload', 'old_owner_calldata_bytes_payload'),
)


def main():
    passed = 0
    for name, gate in CASES:
        locations = set()
        typed_code = driver.a.typed.__code__
        def trace(frame, event, arg):
            if frame.f_code is not typed_code:
                return None
            if event == 'exception' and isinstance(arg[1], driver.a.Gate):
                if arg[1].record['gate'] == gate:
                    caller = frame.f_back
                    while caller and Path(caller.f_code.co_filename).name not in ('manifest_exec.py', 'old_owner_isolation.py'):
                        caller = caller.f_back
                    if caller:
                        locations.add((caller.f_code.co_filename, caller.f_lineno))
            return trace
        # Observe the helper without introducing a forwarding call or changing it.
        previous = sys.gettrace()
        try:
            sys.settrace(trace)
            green, _, baseline = driver.run(RenameControls, name)
        finally:
            sys.settrace(previous)
        if locations:
            driver.SITES[(RenameControls, name, gate)] = locations
        accepted, reached, mutant = driver.run(RenameControls, name, gate) if green else (True, False, '')
        good = green and reached and not accepted
        passed += good
        print(baseline + mutant, end='')
        print(f'GATE_RENAME_CONTROL {gate} {"PASS" if good else "FAIL"} '
              f'baseline={"green" if green else "RED"} sites={len(driver.SITES.get((RenameControls,name,gate), set()))}')
    print(f'GATE_RENAME_CONTROLS {"PASS" if passed == len(CASES) else "FAIL"} {passed}/{len(CASES)} strict red')
    return int(passed != len(CASES))


if __name__ == '__main__':
    raise SystemExit(main())
