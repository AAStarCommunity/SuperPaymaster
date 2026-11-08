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
    'execution_module_origin': ['test_execution_module_origin'],
    'execution_root': ['test_execution_root'],
    'execution_index_flags': ['test_execution_index_flags'],
    'execution_module_tracked': ['test_execution_module_tracked'],
    'execution_module_bytes': ['test_execution_module_bytes'],
    'execution_repo_read': ['test_os_open', 'test_popen'],
}


def main():
    passed = 0
    for gate, tests in CASES.items():
        with tempfile.TemporaryDirectory(prefix='commit6f-probe-') as directory:
            root = Path(directory)
            shutil.copytree(ROOT / 'script', root / 'script', ignore=shutil.ignore_patterns('__pycache__'))
            file = root / 'script/upgrade' / ('execution_reads.py' if gate == 'execution_repo_read'
                                              else 'execution_integrity.py')
            source = file.read_text()
            tree = ast.parse(source)
            sites = [node for node in ast.walk(tree) if isinstance(node, (ast.Expr, ast.Raise))
                     and isinstance(node.value if isinstance(node, ast.Expr) else node.exc, ast.Call)
                     and any(isinstance(arg, ast.Constant) and arg.value == gate
                             for arg in (node.value if isinstance(node, ast.Expr) else node.exc).args)]
            env = dict(os.environ, PYTHONPATH=os.pathsep.join(str(root / p) for p in
                       ('script/upgrade', 'script/a3a')), PYTHONDONTWRITEBYTECODE='1')
            command = [sys.executable, '-B', '-m', 'unittest', '-v',
                       *['test_execution_integrity.IntegrityTests.' + name for name in tests]]
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
          f'scope=5_integrity_gates+existing_read_gate passed={passed} total={len(CASES)}')
    return int(passed != len(CASES))


if __name__ == '__main__':
    raise SystemExit(main())
