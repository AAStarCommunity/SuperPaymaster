#!/usr/bin/env python3
"""Offline mutation probes: suppress one gas gate, require its negative test to fail."""
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
}


def main():
    original = tests.a.need
    for name, gate in CASES.items():
        baseline = unittest.TextTestRunner(stream=io.StringIO()).run(tests.GasGateControls(name))
        if not baseline.wasSuccessful():
            raise AssertionError(f'{name}: baseline failed')
        def without_gate(actual_gate, *args, **kwargs):
            if actual_gate != gate:
                return original(actual_gate, *args, **kwargs)
        with patch.object(tests.a, 'need', side_effect=without_gate):
            result = unittest.TextTestRunner(stream=io.StringIO()).run(tests.GasGateControls(name))
        if result.wasSuccessful():
            raise AssertionError(f'{gate}: mutation survived')
        print(f'{gate}: baseline PASS; gate removed RED')
    print('GAS_GATE_PROBES PASS 6/6')


if __name__ == '__main__':
    main()
