#!/usr/bin/env python3
"""Offline #17 only: required-gate and read-inventory assertion deletions."""
import ast
import io
from pathlib import Path
import unittest
from unittest.mock import patch
import probe_phase_c_gates as probes
from gate_assertions import assertion_mentions

t = probes.base_tests


def main():
    cls = t.ManifestTests
    name = 'test_old_timelock_required'
    baseline, _, log = probes.run(cls, name)
    print(log, end='')
    rejected, single, log = probes.run(cls, name, 'old_timelock_required')
    print(log, end='')
    gate_ok = baseline and single and not rejected
    print(f'OLD_TIMELOCK_REQUIRED {"PASS" if gate_ok else "FAIL"} sites=1 baseline={"green" if baseline else "RED"}')

    def run():
        stream = io.StringIO()
        result = unittest.TextTestRunner(stream=stream).run(cls('test_old_timelock_read_sites'))
        print(stream.getvalue(), end='')
        return result

    baseline = run()
    tree = ast.parse(Path(t.__file__).read_text())
    klass = next(n for n in tree.body if isinstance(n, ast.ClassDef) and n.name == 'ManifestTests')
    method = next(n for n in klass.body if isinstance(n, ast.FunctionDef) and n.name == name)
    sites = [n for n in ast.walk(method) if isinstance(n, ast.Expr) and isinstance(n.value, ast.Call)
             and any(isinstance(arg, ast.Constant) and arg.value == 'old_timelock_read_sites: patch needs updating'
                     for arg in n.value.args)]
    if len(sites) != 1:
        print(f'OLD_TIMELOCK_READ_SITES FAIL sites={len(sites)}')
        return 1

    class Delete(ast.NodeTransformer):
        def visit_Expr(self, node):
            return ast.copy_location(ast.Pass(), node) if node is sites[0] else self.generic_visit(node)

    module = ast.Module(body=[Delete().visit(method)], type_ignores=[])
    namespace = {}
    exec(compile(ast.fix_missing_locations(module), t.__file__, 'exec'), t.__dict__, namespace)
    with patch.object(cls, name, namespace[name]):
        mutant = run()
    count_ok = (baseline.wasSuccessful() and len(mutant.failures) >= 1 and not mutant.errors
                and any(assertion_mentions(log, 'old_timelock_read_sites') for _, log in mutant.failures))
    print(f'OLD_TIMELOCK_READ_SITES {"PASS" if count_ok else "FAIL"} sites=1 '
          f'baseline={"green" if baseline.wasSuccessful() else "RED"} '
          f'failures={len(mutant.failures)} errors={len(mutant.errors)}')
    print(f'COMMIT6D_17_REDO {"PASS" if gate_ok and count_ok else "FAIL"} 2/2 strict deletion probes')
    return int(not (gate_ok and count_ok))


if __name__ == '__main__':
    raise SystemExit(main())
