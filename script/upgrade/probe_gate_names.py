#!/usr/bin/env python3
"""Focused uniqueness assertion deletion and enumerated funding-label controls."""
import ast
import io
from pathlib import Path
import unittest
from gate_assertions import assertion_mentions
import test_gate_names as tests


def run_seed():
    stream = io.StringIO()
    result = unittest.TextTestRunner(stream=stream).run(unittest.TestSuite([
        tests.GateNameTests('test_seeded_duplicate_rejected'),
        tests.GateNameTests('test_transitive_wrapper_duplicate_rejected'),
        tests.GateNameTests('test_suffix_definition_duplicates_rejected')]))
    return result, stream.getvalue()


def uniqueness_probe():
    source = Path(tests.__file__).read_text()
    tree = ast.parse(source)
    sites = [node for node in ast.walk(tree) if isinstance(node, ast.Raise)
             and 'gate_name_uniqueness:' in ast.get_source_segment(source, node)]
    baseline, baseline_log = run_seed()
    if len(sites) != 1:
        print(f'GATE_UNIQUENESS_PROBE FAIL sites={len(sites)}')
        return False
    class Delete(ast.NodeTransformer):
        def visit_Raise(self, node):
            return ast.copy_location(ast.Pass(), node) if node is sites[0] else node
    saved = tests.__dict__.copy()
    try:
        exec(compile(ast.fix_missing_locations(Delete().visit(tree)), tests.__file__, 'exec'), tests.__dict__)
        result, log = run_seed()
    finally:
        tests.__dict__.clear()
        tests.__dict__.update(saved)
    named = any(assertion_mentions(message, 'gate_name_uniqueness') for _, message in result.failures)
    good = baseline.wasSuccessful() and len(result.failures) >= 1 and not result.errors and named
    print(baseline_log + log, end='')
    print(f'GATE_UNIQUENESS_PROBE {"PASS" if good else "FAIL"} sites=1 '
          f'baseline={"green" if baseline.wasSuccessful() else "RED"} '
          f'failures={len(result.failures)} errors={len(result.errors)} named={named}')
    return good


def funding_labels():
    import probe_phase_c_gates as driver
    labels = ('entrypoint_SP', 'entrypoint_VPM', 'entrypoint_TPM', 'bundler', 'owner',
              'user', 'feeToken', 'taskSender', 'taskRecipient')
    passed = 0
    for label in labels:
        gate = 'C_funding_' + label
        cls, name = driver.L, 'test_funding_' + gate
        green, _, baseline = driver.run(cls, name)
        accepted, reached, mutant = driver.run(cls, name, gate) if green else (True, False, '')
        good = green and reached and not accepted
        passed += good
        print(f'{gate}: {"PASS" if good else "FAIL"} baseline={"green" if green else "RED"} sites={len(driver.SITES.get((cls, name, gate), set()))}')
        print(baseline + mutant, end='')
    print(f'GATE_FUNDING_LABEL_PROBES {"PASS" if passed == len(labels) else "FAIL"} {passed}/{len(labels)} strict red')
    return passed == len(labels)


def main():
    unique = uniqueness_probe()
    funding = funding_labels()
    print(f'GATE_NAME_PROBES {"PASS" if unique and funding else "FAIL"}')
    return int(not (unique and funding))


if __name__ == '__main__':
    raise SystemExit(main())
