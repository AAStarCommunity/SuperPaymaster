#!/usr/bin/env python3
"""Offline, single-statement behavioral deletion probes for Commit 6c."""
import ast
import copy
import io
from pathlib import Path
import unittest
from unittest.mock import patch

import test_manifest_exec as t
import test_manifest_phase_c as phase_tests
import test_swallow_exceptions as swallow_tests
import test_authority_checkpoints as authority_tests
from gate_assertions import assertion_mentions

CASES = [
    (t.m, 'layout_slot', "a.need('C_control_layout_'+label, [(len(entries), entries[0]['offset'] if entries else None)], [(1, 0)])",
     phase_tests.SnapshotControlTests, 'test_control_slot_readback', 'C_control_layout_cachedPrice'),
    (t.m, 'pre_send', 'discovery_old_authority(rpc, coverage, block)',
     authority_tests.AuthorityCheckpointTests, 'test_pre_old', 'discovery_old_authority'),
    (t.m, 'dvt_closing', 'discovery_old_authority(rpc, closing, block)',
     authority_tests.AuthorityCheckpointTests, 'test_closing_old', 'discovery_old_authority'),
    (t.m, 'pre_send', "old_timelock_holds_nothing(rpc, coverage, block, delta['approvalOwners'])",
     authority_tests.AuthorityCheckpointTests, 'test_pre_old_timelock', 'old_timelock_authority'),
    (t.m, 'dvt_closing', 'old_timelock_holds_nothing(rpc, closing, block)',
     authority_tests.AuthorityCheckpointTests, 'test_closing_old_timelock', 'old_timelock_authority'),
    (swallow_tests.s, 'assert_no_swallow', "u.a.need('swallow_exception', unreviewed, [])",
     swallow_tests.SwallowTests, 'test_unreviewed_handler', 'swallow_exception'),
    (t.m, 'main', 'except Exception', t.ExceptionStopTests, 'test_first_pre_send_exception', 'manifest_error'),
    (t.a, 'main', 'except Exception', t.ExceptionStopTests, 'test_a3a_exception', 'executor_error'),
    (t.m, 'pre_send', 'isolation.registry_callsite_targets(lambda target, sig: a.address(rpc, target, sig, block), {})',
     t.TargetReadTests, 'test_pre_send_target_change', 'old_owner_role_callsite_target'),
    (t.m, 'dvt_closing', 'isolation.registry_callsite_targets(lambda target, sig: a.address(rpc, target, sig, block), {})',
     t.TargetReadTests, 'test_closing_target_change', 'old_owner_role_callsite_target'),
    (t.m, 'build_plan', 'pin = stage_pin(pin, stage)',
     t.PrerequisiteCallTests, 'test_stage_pin_call', 'stage_pin_phase_c'),
    (t.m.isolation, 'decode_immutable', 'validate_immutable_inputs(identity, values, artifact)',
     t.PrerequisiteCallTests, 'test_decode_immutable_call', 'old_owner_immutable_values'),
]


def run(cls, name):
    stream = io.StringIO()
    result = unittest.TextTestRunner(stream=stream).run(unittest.TestSuite([cls(name)]))
    return result, stream.getvalue()


def main():
    passed = 0
    for module, function, expression, cls, name, gate in CASES:
        source = Path(module.__file__).read_text()
        fn = copy.deepcopy(next(n for n in ast.parse(source).body if isinstance(n, ast.FunctionDef) and n.name == function))
        sites = [n for n in ast.walk(fn) if
                 (isinstance(n, ast.ExceptHandler) and isinstance(n.type, ast.Name) and n.type.id == 'Exception'
                  if expression == 'except Exception' else
                  isinstance(n, ast.stmt) and ast.get_source_segment(source, n) == expression)]
        if not sites and expression != 'except Exception':
            sites = [n for n in ast.walk(fn) if isinstance(n, ast.Call) and ast.get_source_segment(source, n) == expression]
        if len(sites) != 1:
            print(f'{name}: gate={gate} sites={len(sites)} FAIL')
            continue
        class Delete(ast.NodeTransformer):
            def visit(self, node):
                if node is sites[0]:
                    if isinstance(node, ast.ExceptHandler):
                        return None
                    return ast.copy_location(ast.Constant(None) if isinstance(node, ast.Call) else ast.Pass(), node)
                return super().visit(node)
        mutated = ast.fix_missing_locations(ast.Module(body=[Delete().visit(fn)], type_ignores=[]))
        namespace = {}
        exec(compile(mutated, module.__file__, 'exec'), module.__dict__, namespace)
        baseline, baseline_log = run(cls, name)
        with patch.object(module, function, namespace[function]):
            result, log = run(cls, name)
        named = any(assertion_mentions(message, gate) for _, message in result.failures)
        good = baseline.wasSuccessful() and len(result.failures) >= 1 and not result.errors and named
        passed += good
        print(f'{name}: gate={gate} sites=1 baseline={"green" if baseline.wasSuccessful() else "RED"} '
              f'failures={len(result.failures)} errors={len(result.errors)} {"ASSERT named" if good else "FAIL"}')
        if not good:
            print(baseline_log + log)
    print(f'COMMIT6C_PROBES {"PASS" if passed == len(CASES) else "FAIL"} {passed}/{len(CASES)} strict red')
    return int(passed != len(CASES))


if __name__ == '__main__':
    raise SystemExit(main())
