#!/usr/bin/env python3
"""Offline single-site deletion probes requiring named assertion failures."""
import test_manifest_exec as tests

CASES = {
    'test_gas_evidence_missing': 'gas_evidence_missing',
    'test_remote_estimate_context': 'remote_estimate_context',
    'test_measurement_executionTimestamp': 'measurement_executionTimestamp',
    'test_measurement_blockGasLimit': 'measurement_blockGasLimit',
    'test_B4_variant_measurements': 'B4_variant_measurements',
    'test_B4_placeholder_measurements_tx': 'B4_placeholder_measurements',
    'test_B4_placeholder_measurements_unexpected': 'B4_placeholder_measurements',
    'test_fresh_estimate_pin': 'fresh_estimate_pin',
    'test_remote_margin': 'measured_gas_limit',
    'test_missing_remote': 'remote_estimate_missing',
    'test_wrong_pin': 'remote_estimate_pin',
    'test_missing_override': 'remote_estimate_overrides',
    'test_fresh_estimate': 'fresh_estimate',
    'test_block_limit': 'block_gas_limit',
    'test_wrong_time_override': 'remote_estimate_time',
    'test_wrong_prior_steps': 'remote_estimate_prior_steps',
}


def strict_outcome(name, gate):
    from probe_phase_c_gates import run
    baseline, _, log = run(tests.GasGateControls, name)
    if not baseline:
        raise AssertionError(f'{gate}: baseline failed\n{log}')
    invalid, matched, log = run(tests.GasGateControls, name, gate)
    return matched and not invalid, log


def main():
    rows = []
    for name, gate in CASES.items():
        red, log = strict_outcome(name, gate)
        rows.append(red)
        print(f'{name}: gate={gate} baseline=OK strict_red={red}')
        if not red:
            print(log)
    print(f'GAS_GATE_PROBES {"PASS" if all(rows) else "FAIL"} {sum(rows)}/{len(rows)}')
    return 0 if all(rows) else 1


if __name__ == '__main__':
    raise SystemExit(main())
