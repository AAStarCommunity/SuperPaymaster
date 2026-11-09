#!/usr/bin/env python3
"""Focused whole-module single-source-site deletion proof for item 6d B."""
import ast
import io
from pathlib import Path
import unittest
import execution_reads as e
import test_execution_reads as t
from test_execution_head import ExecutionHeadTests
from gate_assertions import assertion_mentions


def run():
    stream = io.StringIO()
    result = unittest.TextTestRunner(stream=stream).run(unittest.TestSuite([
        ExecutionHeadTests('test_tree_gates_inside_guard_stop'),
        t.ExecutionReadTests('test_deleted_gate'),
        t.ExecutionReadTests('test_guard_remains_active_through_real_runner_closing'),
        t.ExecutionReadTests('test_run_manifest_installs_guard_after_validation')]))
    return result, stream.getvalue()


def main():
    source = Path(e.__file__).read_text()
    tree = ast.parse(source)
    sites = [n for n in ast.walk(tree) if isinstance(n, ast.Raise)
             and isinstance(n.exc, ast.Call) and n.exc.args
             and isinstance(n.exc.args[0], ast.Constant)
             and n.exc.args[0].value == 'execution_repo_read']
    if len(sites) != 1:
        print(f'execution_repo_read: sites={len(sites)} FAIL')
        return 1
    baseline, before = run()
    class Delete(ast.NodeTransformer):
        def visit_Raise(self, node):
            return ast.copy_location(ast.Pass(), node) if node is sites[0] else node
    saved = e.__dict__.copy()
    try:
        exec(compile(ast.fix_missing_locations(Delete().visit(tree)), e.__file__, 'exec'), e.__dict__)
        result, after = run()
    finally:
        e.__dict__.clear()
        e.__dict__.update(saved)
    named = any(assertion_mentions(message, 'execution_repo_read') for _, message in result.failures)
    good = baseline.wasSuccessful() and len(result.failures) >= 1 and not result.errors and named
    print(f'execution_repo_read: sites=1 baseline={"green" if baseline.wasSuccessful() else "RED"} '
          f'failures={len(result.failures)} errors={len(result.errors)} {"ASSERT named" if good else "FAIL"}')
    if good:
        message = next(message for _, message in result.failures
                       if assertion_mentions(message, 'execution_repo_read'))
        print(next(line for line in message.splitlines()
                   if line.startswith('AssertionError:') and 'execution_repo_read' in line))
    else:
        print(before + after)
    print(f'COMMIT6D_B_PROBE {"PASS" if good else "FAIL"} 1/1 strict red')
    return int(not good)


if __name__ == '__main__':
    raise SystemExit(main())
