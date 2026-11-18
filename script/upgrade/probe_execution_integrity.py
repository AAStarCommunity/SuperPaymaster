#!/usr/bin/env python3
"""Strict single-site gate deletion probes, exclusively in temporary source trees."""
import ast
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from gate_assertions import assertion_mentions

ROOT = Path(__file__).resolve().parents[2]
CASES = {
    'execution_bootstrap_origin': ['test_execution_bootstrap_origin'],
    'execution_module_origin': ['test_execution_module_origin'],
    'execution_root': ['test_execution_root'],
    'execution_index_flags': ['test_execution_index_flags'],
    'execution_module_tracked': ['test_execution_module_tracked'],
    'execution_module_bytes': ['test_execution_module_bytes'],
    'execution_repo_read': ['test_os_open', 'test_popen'],
    'execution_integrity_source': ['test_execution_integrity_source'],
    'execution_integrity_source_manifest': ['test_execution_integrity_source_manifest'],
}
# Gates that live outside execution_integrity.py, and controls outside IntegrityTests.
FILES = {'execution_repo_read': 'script/upgrade/execution_reads.py',
         'execution_integrity_source': 'script/a3a/a3a_send.py',
         'execution_integrity_source_manifest': 'script/upgrade/manifest_exec.py'}
CLASSES = {'execution_bootstrap_origin': 'BootstrapTests',
           'execution_integrity_source': 'HelperSourceTests',
           'execution_integrity_source_manifest': 'HelperSourceTests'}


def main():
    passed = 0
    for gate, tests in CASES.items():
        with tempfile.TemporaryDirectory(prefix='commit6f-probe-') as directory:
            root = Path(directory)
            shutil.copytree(ROOT / 'script', root / 'script', ignore=shutil.ignore_patterns('__pycache__'))
            file = root / FILES.get(gate, 'script/upgrade/execution_integrity.py')
            source = file.read_text()
            tree = ast.parse(source)
            sites = [node for node in ast.walk(tree) if isinstance(node, (ast.Expr, ast.Raise))
                     and isinstance(node.value if isinstance(node, ast.Expr) else node.exc, ast.Call)
                     and any(isinstance(arg, ast.Constant) and arg.value == gate
                             for arg in (node.value if isinstance(node, ast.Expr) else node.exc).args)]
            env = dict(os.environ, PYTHONPATH=os.pathsep.join(str(root / p) for p in
                       ('script/upgrade', 'script/a3a')), PYTHONDONTWRITEBYTECODE='1')
            command = [sys.executable, '-B', '-m', 'unittest', '-v',
                       *[f'test_execution_integrity.{CLASSES.get(gate, "IntegrityTests")}.{name}'
                         for name in tests]]
            baseline = subprocess.run(command, cwd=root, env=env, capture_output=True, text=True)
            if len(sites) != 1 or baseline.returncode:
                print(baseline.stdout + baseline.stderr)
                print(f'{gate} FAIL sites={len(sites)} baseline_exit={baseline.returncode}')
                continue
            lines = source.splitlines(keepends=True)
            site = sites[0]
            lines[site.lineno - 1:site.end_lineno] = [' ' * site.col_offset + 'pass\n']
            file.write_text(''.join(lines))
            mutant = subprocess.run(command, cwd=root, env=env, capture_output=True, text=True)
            log = mutant.stdout + mutant.stderr
            failures = log.count('FAIL: ')
            errors = log.count('ERROR: ')
            named = assertion_mentions(log, gate)
            good = mutant.returncode == 1 and failures >= 1 and errors == 0 and named
            passed += good
            print(log, end='')
            print(f'{gate} {"PASS" if good else "FAIL"} sites=1 baseline=green '
                  f'failures={failures} errors={errors} named={named}')
    print(f'EXECUTION_INTEGRITY_PROBES {"PASS" if passed == len(CASES) else "FAIL"} '
          f'scope=6_integrity_gates+2_source_gates+existing_read_gate passed={passed} total={len(CASES)}')
    calls_failed = call_probes()
    return int(passed != len(CASES) or calls_failed)


def call_probes():
    """Only a named assertion FAIL counts; ERROR/import failures never count."""
    import re
    mutations = [
        ('first sender call', 'script/a3a/a3a_send.py',
         "    evidence = integrity_check(plan['rebuild']['commit'])", "    evidence = {}", 'test_first_call'),
        ('second sender call', 'script/a3a/a3a_send.py',
         "    integrity_check(plan['rebuild']['commit'])", "    pass", 'test_second_call'),
        ('sender module.check', 'script/a3a/a3a_send.py',
         '    return module.check(commit)', '    return {}', 'test_first_call'),
        ('manifest module.check', 'script/upgrade/manifest_exec.py',
         "    return module.check(plan['rebuild']['commit'])", '    return {}', 'test_manifest_call'),
        ('manifest call', 'script/upgrade/manifest_exec.py',
         '    evidence = execution_tree_gates(plan)', '    evidence = None', 'test_manifest_call'),
    ]
    source = (ROOT / 'script/upgrade/execution_integrity.py').read_text()
    for gate, test in (('execution_head', 'test_head'), ('execution_clean_tree', 'test_first_call')):
        line = next(line for line in source.splitlines() if "a.need('" + gate + "'" in line)
        mutations.append((gate, 'script/upgrade/execution_integrity.py', line, '    pass', test))
    def run(root, test=None):
        env = dict(os.environ, PYTHONPATH=os.pathsep.join(str(root / p) for p in
                   ('script/upgrade', 'script/a3a')), PYTHONDONTWRITEBYTECODE='1')
        suite = 'test_execution_calls' + ('.CallTests.' + test if test else '')
        result = subprocess.run([sys.executable, '-B', '-m', 'unittest', '-v', suite],
                                cwd=root, env=env, capture_output=True, text=True)
        log = result.stdout + result.stderr
        fails = set(re.findall(r'^FAIL: (\w+)', log, re.M))
        errors = re.findall(r'^ERROR: .*', log, re.M)
        return result.returncode, fails, errors, log
    with tempfile.TemporaryDirectory(prefix='execution-calls-') as directory:
        root = Path(directory)
        shutil.copytree(ROOT / 'script', root / 'script', ignore=shutil.ignore_patterns('__pycache__'))
        rc, fails, errors, log = run(root)
        print(log, end='')
        print('CALL_BASELINE', 'GREEN' if rc == 0 and not fails and not errors else 'FAIL')
        if rc or fails or errors:
            return 1
    caught = 0
    for label, file, old, new, test in mutations:
        with tempfile.TemporaryDirectory(prefix='execution-call-mutant-') as directory:
            root = Path(directory)
            shutil.copytree(ROOT / 'script', root / 'script', ignore=shutil.ignore_patterns('__pycache__'))
            path = root / file
            original = path.read_text()
            if old == new or original.count(old) != 1:
                print('NOT APPLIED', label)
                continue
            path.write_text(original.replace(old, new, 1))
            rc, fails, errors, log = run(root, test)
            good = rc != 0 and test in fails and not errors
            caught += good
            print(log, end='')
            print(f'CALL_MUTANT {label}: {"RED" if good else "NOT CAUGHT"} named={test} errors={len(errors)}')
    print(f'EXECUTION_CALL_PROBES {caught}/{len(mutations)} red')
    return int(caught != len(mutations))


if __name__ == '__main__':
    raise SystemExit(main())
