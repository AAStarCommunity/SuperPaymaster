#!/usr/bin/env python3
"""Focused whole-module single-site deletion proofs for item 6d C."""
import ast
import io
from pathlib import Path
import unittest
import test_execution_head as t
from gate_assertions import assertion_mentions

CASES = (('execution_head', 'test_wrong_head'),
         ('execution_clean_tree', 'test_dirty_file'))


def run(name):
    output = io.StringIO()
    result = unittest.TextTestRunner(stream=output).run(
        unittest.TestSuite([t.ExecutionHeadTests(name)]))
    return result, output.getvalue()


def main():
    module = t.m
    source = Path(module.__file__).read_text()
    passed = 0
    for gate, name in CASES:
        tree = ast.parse(source)
        sites = [n for n in ast.walk(tree) if isinstance(n, ast.Expr)
                 and isinstance(n.value, ast.Call)
                 and ast.unparse(n.value.func) == 'a.need' and n.value.args
                 and isinstance(n.value.args[0], ast.Constant) and n.value.args[0].value == gate]
        if len(sites) != 1:
            print(f'{gate}: sites={len(sites)} FAIL')
            continue
        baseline, before = run(name)
        class Delete(ast.NodeTransformer):
            def visit_Expr(self, node):
                return ast.copy_location(ast.Pass(), node) if node is sites[0] else node
        saved = module.__dict__.copy()
        try:
            exec(compile(ast.fix_missing_locations(Delete().visit(tree)), module.__file__, 'exec'), module.__dict__)
            result, after = run(name)
        finally:
            module.__dict__.clear()
            module.__dict__.update(saved)
        named = any(assertion_mentions(message, gate) for _, message in result.failures)
        good = baseline.wasSuccessful() and len(result.failures) >= 1 and not result.errors and named
        passed += good
        print(f'{gate}: sites=1 baseline={"green" if baseline.wasSuccessful() else "RED"} '
              f'failures={len(result.failures)} errors={len(result.errors)} {"ASSERT named" if good else "FAIL"}')
        if good:
            message = next(message for _, message in result.failures if assertion_mentions(message, gate))
            print(next(line for line in message.splitlines() if line.startswith('AssertionError:') and gate in line))
        else:
            print(before + after)
    print(f'COMMIT6D_C_PROBES {"PASS" if passed == len(CASES) else "FAIL"} {passed}/{len(CASES)} strict red')
    return int(passed != len(CASES))


if __name__ == '__main__':
    raise SystemExit(main())
