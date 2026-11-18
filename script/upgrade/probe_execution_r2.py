#!/usr/bin/env python3
"""Round-two negative controls in copies; no Git writes, RPC or sockets."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import execution_set

ROOT = Path(__file__).resolve().parents[2]


def main():
    mutations = [
        ('unregistered read', 'script/a3a/a3a_send.py', None,
         "\ndef unregistered():\n    return (ROOT / 'new-policy.json').read_text()\n", 'test_read_inventory'),
        ('cast pin refresh', 'script/upgrade/execution_set.py',
         "        if 'cast' in execution and execution['cast'] != signer:",
         '        if False:', 'test_cli_preserves_existing_execution_fields'),
    ]
    for expression in ("open(args.password_file)", "__import__('io').open(args.password_file)",
                       "os.open(args.password_file, os.O_RDONLY)", "args.password_file.open()",
                       "args.password_file.read_text()", "args.password_file.read_bytes()"):
        mutations.append((expression, 'script/a3a/a3a_send.py',
                          "    raw_plan = args.plan.read_bytes()",
                          "    " + expression + "\n    raw_plan = args.plan.read_bytes()",
                          'test_password_zero_actual_opens'))
    passed = 0
    for label, relative, old, new, test in mutations:
        with tempfile.TemporaryDirectory(prefix='r2-negative-') as directory:
            root = Path(directory)
            for name in execution_set.execution_files() + ['script/upgrade/test_execution_r2.py']:
                target = root / name
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(ROOT / name, target)
            (root / 'new-policy.json').write_text('{}')
            path = root / relative
            source = path.read_text()
            env = dict(os.environ, PYTHONDONTWRITEBYTECODE='1', PYTHONPATH=os.pathsep.join(
                str(root / p) for p in ('script/upgrade', 'script/a3a')))
            command = [sys.executable, '-B', '-m', 'unittest', '-v',
                       'test_execution_r2.RoundTwoTests.' + test]
            baseline = subprocess.run(command, cwd=root, env=env, capture_output=True, text=True)
            if baseline.returncode or (old is not None and source.count(old) != 1):
                print('BASELINE/NOT APPLIED', label, baseline.stdout + baseline.stderr)
                continue
            path.write_text(source + new if old is None else source.replace(old, new, 1))
            result = subprocess.run(command, cwd=root, env=env, capture_output=True, text=True)
            log = result.stdout + result.stderr
            good = result.returncode == 1 and ('FAIL: ' + test) in log and 'ERROR: ' not in log
            passed += good
            print(log, end='')
            print(f'R2_MUTANT {label}: {"RED" if good else "NOT CAUGHT"} named={test} errors={log.count("ERROR: ")}')
    print(f'EXECUTION_R2_PROBES {passed}/{len(mutations)} red')
    return int(passed != len(mutations))


if __name__ == '__main__':
    raise SystemExit(main())
