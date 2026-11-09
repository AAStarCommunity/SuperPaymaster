"""Only the two DSR #20 deletions, compiled from temporary source copies."""
import ast
import io
from pathlib import Path
import tempfile
import unittest
from gate_assertions import assertion_mentions
import test_getter_accessor as tests


def run():
    stream = io.StringIO()
    result = unittest.TextTestRunner(stream=stream).run(unittest.TestSuite([
        tests.GetterAccessorTests('test_getter_pair')]))
    return result, stream.getvalue()


def main():
    module = tests.fixture.o
    source = Path(module.__file__).read_text()
    total = 0
    for expression, gate, other in (
        ("'old_owner_getter_abi_' + name + '_' + label", tests.ABI, tests.ACCESSOR),
        (repr(tests.ACCESSOR), tests.ACCESSOR, tests.ABI),
    ):
        tree = ast.parse(source)
        sites = [n for n in ast.walk(tree) if isinstance(n, ast.Expr)
                 and isinstance(n.value, ast.Call) and ast.unparse(n.value.func) == 'a.need'
                 and ast.unparse(n.value.args[0]) == expression]
        baseline, baseline_log = run()
        print(baseline_log, end='')
        failures = errors = 0
        named = paired = False
        if len(sites) == 1 and baseline.wasSuccessful():
            class Delete(ast.NodeTransformer):
                def visit_Expr(self, node):
                    return ast.copy_location(ast.Pass(), node) if node is sites[0] else self.generic_visit(node)
            with tempfile.TemporaryDirectory(prefix='getter-accessor-probe-') as directory:
                path = Path(directory) / 'old_owner_isolation.py'
                path.write_text(ast.unparse(ast.fix_missing_locations(Delete().visit(tree))) + '\n')
                saved = module.__dict__.copy()
                try:
                    exec(compile(path.read_text(), str(path), 'exec'), module.__dict__)
                    result, log = run()
                finally:
                    module.__dict__.clear()
                    module.__dict__.update(saved)
                print(log, end='')
                failures, errors = len(result.failures), len(result.errors)
                named = any(assertion_mentions(message, gate) for _, message in result.failures)
                paired = any(assertion_mentions(message, other) for _, message in result.failures)
        good = len(sites) == 1 and baseline.wasSuccessful() and failures >= 1 and errors == 0 and named and paired
        total += good
        print(f'GETTER_ACCESSOR_PROBE {gate} {"PASS" if good else "BLOCKED"} source_sites={len(sites)} baseline={"green" if baseline.wasSuccessful() else "RED"} failures={failures} errors={errors} named={named} pair_named={paired}', flush=True)
    print(f'GETTER_ACCESSOR_PROBES {"PASS" if total == 2 else "FAIL"} passed={total}/2 errors_accepted=0')
    return int(total != 2)


if __name__ == '__main__':
    raise SystemExit(main())
