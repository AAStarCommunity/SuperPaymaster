#!/usr/bin/env python3
"""Offline gas-gate probes reporting acceptance or the next defensive gate."""
import io
import unittest
from unittest.mock import patch
import test_manifest_exec as tests

CASES = {
    'test_remote_margin': 'measured_gas_limit',
    'test_missing_remote': 'remote_estimate_missing',
    'test_wrong_pin': 'remote_estimate_pin',
    'test_missing_override': 'remote_estimate_overrides',
    'test_fresh_estimate': 'fresh_estimate',
    'test_block_limit': 'block_gas_limit',
    'test_wrong_time_override': 'remote_estimate_time',
    'test_wrong_prior_steps': 'remote_estimate_prior_steps',
}


def suppressed_outcome(name, gate):
    original = tests.a.need
    case = tests.GasGateControls(name)
    outcomes, suppressed = [], []

    def without_gate(actual_gate, *args, **kwargs):
        if actual_gate == gate:
            suppressed.append(actual_gate)
        else:
            return original(actual_gate, *args, **kwargs)

    def observe(expected_gate, action=None):
        case.assertEqual(expected_gate, gate)
        try:
            (action or (lambda: tests.u.validate_gas_evidence(case.plan, case.step)))()
        except tests.a.Gate as error:
            case.assertNotEqual(error.record['gate'], gate)
            case.assertEqual(error.record['step'], case.step['id'])
            outcomes.append('caught by '+error.record['gate']+' (defense in depth)')
        else:
            outcomes.append('accepted (load-bearing)')

    case.stop = observe
    stream = io.StringIO()
    with patch.object(tests.a, 'need', side_effect=without_gate):
        result = unittest.TextTestRunner(stream=stream).run(case)
    if not result.wasSuccessful():
        raise AssertionError(stream.getvalue())
    if not suppressed or len(outcomes) != 1:
        raise AssertionError(f'{gate}: probe did not exercise exactly one control and suppress its gate')
    return outcomes[0]


def main():
    rows = []
    for name, gate in CASES.items():
        stream = io.StringIO()
        baseline = unittest.TextTestRunner(stream=stream).run(tests.GasGateControls(name))
        if not baseline.wasSuccessful():
            raise AssertionError(f'{name}: baseline failed\n{stream.getvalue()}')
        rows.append((gate, suppressed_outcome(name, gate)))
    print('| Suppressed gate | Baseline | Suppressed outcome |')
    print('|---|---|---|')
    for gate, outcome in rows:
        print(f'| {gate} | PASS | {outcome} |')
    print(f'GAS_GATE_PROBES PASS {len(rows)}/{len(CASES)}')


if __name__ == '__main__':
    main()
