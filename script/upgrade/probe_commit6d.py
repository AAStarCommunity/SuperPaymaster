#!/usr/bin/env python3
"""Offline whole-module, single-statement deletion controls for Commit 6d."""
import ast
import io
from pathlib import Path
import unittest
import test_swallow_exceptions as t
from gate_assertions import assertion_mentions

CASES = (
    ('raise box[\'error\']', 'test_worker_exception_identity', 'rpc_deadline_reraise'),
    ("raise TimeoutError('total RPC deadline exceeded')", 'test_expired_deadline', 'rpc_deadline_timeout'),
)


def run(name):
    output = io.StringIO()
    result = unittest.TextTestRunner(stream=output).run(unittest.TestSuite([
        t.DeadlinePropagationTests(name)]))
    return result, output.getvalue()


def main():
    module = t.s.u.a
    source = Path(module.__file__).read_text()
    passed = 0
    for expression, name, gate in CASES:
        tree = ast.parse(source)
        sites = [n for n in ast.walk(tree) if isinstance(n, ast.Raise)
                 and ast.get_source_segment(source, n) == expression]
        if len(sites) != 1:
            print(f'{gate}: sites={len(sites)} FAIL')
            continue
        baseline, baseline_log = run(name)

        class Delete(ast.NodeTransformer):
            def visit_Raise(self, node):
                return ast.copy_location(ast.Pass(), node) if node is sites[0] else node

        saved = module.__dict__.copy()
        try:
            exec(compile(ast.fix_missing_locations(Delete().visit(tree)), module.__file__, 'exec'), module.__dict__)
            result, log = run(name)
        finally:
            module.__dict__.clear()
            module.__dict__.update(saved)
        named = any(assertion_mentions(message, gate) for _, message in result.failures)
        good = baseline.wasSuccessful() and len(result.failures) >= 1 and not result.errors and named
        passed += good
        print(f'{name}: gate={gate} sites=1 baseline={"green" if baseline.wasSuccessful() else "RED"} '
              f'failures={len(result.failures)} errors={len(result.errors)} {"ASSERT named" if good else "FAIL"}')
        if not good:
            print(baseline_log + log)
    print(f'COMMIT6D_PROBES {"PASS" if passed == len(CASES) else "FAIL"} {passed}/{len(CASES)} strict red')
    return int(passed != len(CASES))


if __name__ == '__main__':
    raise SystemExit(main())
