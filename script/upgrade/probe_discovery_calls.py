#!/usr/bin/env python3
"""Focused offline discovery call deletions; no production files are changed."""
import ast
import io
from pathlib import Path
import unittest
from unittest.mock import patch
import test_manifest_exec as t
from gate_assertions import assertion_mentions

# Only literal deletions are accepted. Value-producing inventory calls require
# separate controls before M7 can be declared complete.
CASES = (9, 12, 13, 14, 21, 22)


def run(index):
    stream = io.StringIO()
    result = unittest.TextTestRunner(stream=stream).run(unittest.TestSuite([
        t.DiscoveryCallTests('test_call_' + str(index))]))
    return result, stream.getvalue()


def main():
    source = Path(t.m.__file__).read_text()
    passed = 0
    for index in CASES:
        function, expression, gate = t.DISCOVERY_CALLS[index]
        tree = ast.parse(source)
        fn = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == function)
        sites = [n for n in ast.walk(fn) if isinstance(n, ast.Call)
                 and ast.get_source_segment(source, n) == expression]
        if len(sites) != 1:
            print(f'{index}: gate={gate} sites={len(sites)} FAIL')
            continue
        class Delete(ast.NodeTransformer):
            def visit_Call(self, node):
                if node is sites[0]: return ast.copy_location(ast.Constant(None), node)
                return self.generic_visit(node)
        namespace = {}
        exec(compile(ast.fix_missing_locations(ast.Module(body=[Delete().visit(fn)], type_ignores=[])),
                     t.m.__file__, 'exec'), t.m.__dict__, namespace)
        baseline, before = run(index)
        with patch.object(t.m, function, namespace[function]):
            result, after = run(index)
        named = any(assertion_mentions(message, gate) for _, message in result.failures)
        accepted = baseline.wasSuccessful() and len(result.failures) >= 1 and not result.errors and named
        passed += accepted
        print(f'{index}: gate={gate} sites=1 baseline={"green" if baseline.wasSuccessful() else "RED"} '
              f'failures={len(result.failures)} errors={len(result.errors)} {"ASSERT named" if accepted else "FAIL"}')
        if not accepted: print(before + after)
        else:
            for _, message in result.failures:
                print(message[message.index('AssertionError:'):].strip())
    print(f'COMMIT6D_D_PROBES {"PASS" if passed == len(CASES) else "FAIL"} {passed}/{len(CASES)} strict red')
    return int(passed != len(CASES))


if __name__ == '__main__':
    raise SystemExit(main())
