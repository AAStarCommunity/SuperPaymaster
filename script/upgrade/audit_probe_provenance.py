#!/usr/bin/env python3
"""Read-only HEAD provenance audit; run a selected test family, never the probe driver.

HEAD Python sources are loaded from git objects at their original filenames. This
also supplies HEAD bytes for source-inspecting tests. Fixtures and Solidity inputs
must be unchanged tracked files. No working-tree production code is mutated.
"""
import argparse
import ast
import contextlib
import importlib.abc
import importlib.util
import inspect
import hashlib
import io
import json
import linecache
from pathlib import Path
import socket
import subprocess
import sys
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--origin', choices=('601', '604'), required=True)
    parser.add_argument('--family', required=True, help='Comma-separated class or class.method prefixes')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--gate-only-wrapper', action='store_true', help='Expose errors hidden by the historical timelock test helper')
    args = parser.parse_args()
    commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    paths = subprocess.check_output(['git', 'ls-tree', '-r', '--name-only', commit, 'script'], cwd=ROOT, text=True).splitlines()
    sources = {str(ROOT / path): subprocess.check_output(['git', 'show', commit + ':' + path], cwd=ROOT).decode()
               for path in paths if path.endswith('.py') and Path(path).parent.as_posix() in ('script/upgrade', 'script/a3a')}
    modules = {Path(path).stem: path for path in sources}

    class Loader(importlib.abc.Loader):
        def create_module(self, spec):
            return None
        def exec_module(self, module):
            module.__file__ = modules[module.__name__]
            source = sources[module.__file__]
            linecache.cache[module.__file__] = (len(source), None, source.splitlines(True), module.__file__)
            exec(compile(sources[module.__file__], module.__file__, 'exec'), module.__dict__)

    class Finder(importlib.abc.MetaPathFinder):
        def find_spec(self, fullname, path=None, target=None):
            if fullname in modules:
                return importlib.util.spec_from_loader(fullname, Loader(), origin=modules[fullname])

    original_read = Path.read_text
    def read(path, *a, **kw):
        return sources[str(path)] if str(path) in sources else original_read(path, *a, **kw)

    finder = Finder()
    sys.meta_path.insert(0, finder)
    rows = []
    source_hashes = {str(Path(path).relative_to(ROOT)): hashlib.sha256(source.encode()).hexdigest() for path, source in sources.items()}
    with patch.object(Path, 'read_text', read), patch.object(socket.socket, 'connect', side_effect=AssertionError('offline provenance: network forbidden')):
        import probe_phase_c_gates as p
        from gate_assertions import assert_stop, assertion_mentions
        t = p.base_tests.isolation_tests
        case_inventory = [(cls.__name__+'.'+name, gate) for cls, name, gate in p.CASES]
        a = p.a
        if args.gate_only_wrapper:
            # This is test-only normalization, never a production mutation.
            tree = ast.parse(sources[p.base_tests.__file__])
            cls = next(n for n in tree.body if isinstance(n, ast.ClassDef) and n.name == 'ManifestTests')
            fn = next(n for n in cls.body if isinstance(n, ast.FunctionDef) and n.name == 'assert_timelock_build_gate')
            handlers = [n for n in fn.body if isinstance(n, ast.Try)]
            assert len(handlers) == 1 and len(handlers[0].handlers) == 1
            assert ast.unparse(handlers[0].handlers[0].type) == '(KeyError, TypeError, IndexError)'
            assert not handlers[0].orelse and not handlers[0].finalbody
            fn.body = [child for node in fn.body for child in (node.body if node is handlers[0] else [node])]
            namespace = {}
            exec(compile(ast.fix_missing_locations(ast.Module(body=[fn], type_ignores=[])), p.base_tests.__file__, 'exec'), p.base_tests.__dict__, namespace)
            p.base_tests.ManifestTests.assert_timelock_build_gate = namespace[fn.name]

        def result_of(action):
            result = unittest.TestResult()
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                unittest.FunctionTestCase(action).run(result)
            return result

        def audit(label, gate, action):
            sites = set()
            need = a.need
            def recording(actual, *values, **kw):
                try:
                    return need(actual, *values, **kw)
                except a.Gate:
                    if actual == gate:
                        frame = inspect.currentframe().f_back
                        while frame and Path(frame.f_code.co_filename).name not in ('manifest_exec.py', 'old_owner_isolation.py', 'sp_upgrade_exec.py'):
                            frame = frame.f_back
                        if frame:
                            sites.add((frame.f_code.co_filename, frame.f_lineno))
                    raise
            with patch.object(a, 'need', side_effect=recording):
                baseline = result_of(action)
            row = dict(origin=args.origin, test=label, gate=gate, baseline=baseline.wasSuccessful(),
                       sites=[(str(Path(f).relative_to(ROOT)), n) for f, n in sorted(sites)],
                       failures=0, errors=0, classification='ASSERT-UNNAMED', detail='No unique source site', baseline_errors=baseline.errors, baseline_failures=baseline.failures)
            # Serialize test identifiers explicitly, not their repr memory addresses.
            for field in ('baseline_errors', 'baseline_failures'):
                row[field] = [message for _, message in row[field]]
            if len(sites) == 1:
                filename, line = next(iter(sites))
                tree = ast.parse(sources[filename], filename)
                targets = [n for n in ast.walk(tree) if isinstance(n, ast.Expr) and n.lineno <= line <= n.end_lineno and isinstance(n.value, ast.Call)]
                if len(targets) == 1:
                    target = targets[0]
                    owners = [n for n in tree.body if isinstance(n, ast.FunctionDef) and target in list(ast.walk(n))]
                    if len(owners) == 1:
                        owner = owners[0]
                        row['statement'] = ast.get_source_segment(sources[filename], target)
                        class Delete(ast.NodeTransformer):
                            def visit_Expr(self, node):
                                return ast.copy_location(ast.Pass(), node) if node is target else self.generic_visit(node)
                        mutant = ast.fix_missing_locations(ast.Module(body=[Delete().visit(owner)], type_ignores=[]))
                        module = next(m for m in (p.base_tests.m, t.o, p.base_tests.u) if m.__file__ == filename)
                        namespace = {}
                        exec(compile(mutant, filename, 'exec'), module.__dict__, namespace)
                        old = getattr(module, owner.name)
                        with contextlib.ExitStack() as stack:
                            stack.enter_context(patch.object(module, owner.name, namespace[owner.name]))
                            for consumer in (p.tests, p.base_tests, t):
                                for key, value in list(vars(consumer).items()):
                                    if value is old:
                                        stack.enter_context(patch.object(consumer, key, namespace[owner.name]))
                            result = result_of(action)
                        row.update(failures=len(result.failures), errors=len(result.errors),
                                   detail='\n'.join(log for _, log in result.failures + result.errors))
                        # Nested runner diagnostics contain traceback source. Only the
                        # innermost actual FAIL message may establish gate naming.
                        messages = []
                        for _, log in result.failures:
                            lines = log.splitlines()
                            starts = [i for i, line in enumerate(lines) if line.startswith('AssertionError:')]
                            if starts:
                                messages.append('\n'.join(lines[starts[-1]:]))
                        named = any(assertion_mentions(message, gate) for message in messages)
                        converted = any(f'Expected named gate {gate}, got {kind}' in log
                                        for _, log in result.failures for kind in ('KeyError', 'TypeError', 'IndexError'))
                        row['converted_error'] = converted
                        row['classification'] = ('HAS-ERROR' if result.errors or converted else 'ASSERT named' if baseline.wasSuccessful() and result.failures and named else 'ASSERT-UNNAMED')
            if baseline.errors:
                row['classification'] = 'HAS-ERROR'
            rows.append(row)
            print(f"{label} gate={gate} sites={len(sites)} baseline={'green' if row['baseline'] else 'RED'} failures={row['failures']} errors={row['errors']} {row['classification']}", flush=True)
            args.output.write_text(json.dumps(dict(commit=commit, origin=args.origin, family=args.family, gate_only_wrapper=args.gate_only_wrapper, source_sha256=source_hashes, phase_case_inventory=case_inventory, rows=rows), indent=2)+'\n')

        selected = 0
        if args.origin == '601':
            tree = ast.parse(sources[t.__file__])
            users = [(c.name, f.name) for c in tree.body if isinstance(c, ast.ClassDef) for f in c.body if isinstance(f, ast.FunctionDef)
                     and any(isinstance(n, ast.Call) and isinstance(n.func, ast.Name) and n.func.id == 'removed_probe' for n in ast.walk(f))]
            for cls, name in users:
                label = cls+'.'+name
                if not label.startswith(tuple(args.family.split(','))):
                    continue
                selected += 1
                count = 0
                def probe(test, action, gate):
                    nonlocal count
                    count += 1
                    def control():
                        with assert_stop(test, gate):
                            action()
                    audit(label+f'[{count}]', gate, control)
                with patch.object(t, 'removed_probe', probe):
                    outer = unittest.TestResult()
                    unittest.TestSuite([getattr(t, cls)(name)]).run(outer)
                if not outer.wasSuccessful():
                    raise AssertionError(f'Outer baseline failed: {label}: {outer.failures} {outer.errors}')
        else:
            for cls, name, gate in p.CASES:
                label = cls.__name__+'.'+name
                if not label.startswith(tuple(args.family.split(','))):
                    continue
                selected += 1
                def action(cls=cls, name=name):
                    result = unittest.TestResult()
                    unittest.TestSuite([cls(name)]).run(result)
                    # Preserve unittest FAIL versus ERROR, including subtests.
                    if result.errors:
                        raise RuntimeError('nested unittest ERROR: '+str(result.errors))
                    if result.failures:
                        raise AssertionError('\n'.join(log for _, log in result.failures))
                    if result.skipped:
                        raise RuntimeError('Skipped control is not baseline evidence')
                audit(label, gate, action)
        if not selected:
            raise AssertionError('Empty selection')
    counts = {key: sum(row['classification'] == key for row in rows) for key in ('ASSERT named', 'HAS-ERROR', 'ASSERT-UNNAMED')}
    print(f"COMMIT6D_G_AUDIT origin={args.origin} family={args.family} rows={len(rows)} named={counts['ASSERT named']} has_error={counts['HAS-ERROR']} unnamed={counts['ASSERT-UNNAMED']}")


if __name__ == '__main__':
    main()
