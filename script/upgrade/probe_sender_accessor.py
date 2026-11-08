"""One strict accessor deletion in a temporary source tree; foreground only."""
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from gate_assertions import assertion_mentions
from probe_gate_dsr2 import ROOT, delete

GATE = 'a3a_sender_history_rows_present'


def run(tree):
    result = subprocess.run([sys.executable, '-B', '-m', 'unittest',
        'test_sender_accessor.SenderAccessorTests.test_sender_accessor_pair'],
        cwd=tree/'script/upgrade', capture_output=True, text=True, timeout=120)
    return result.returncode, result.stdout + result.stderr


def main():
    code, baseline = run(ROOT)
    print(baseline, end='')
    with tempfile.TemporaryDirectory(prefix='sender-accessor-probe-') as tmp:
        tree = Path(tmp)
        shutil.copytree(ROOT/'script', tree/'script', ignore=shutil.ignore_patterns('__pycache__'))
        sites = delete(tree, 'manifest_exec.py', 1823)
        mutant_code, log = run(tree)
        print(log, end='')
    failures, errors = log.count('FAIL:'), log.count('ERROR:')
    named = assertion_mentions(log, GATE)
    good = sites == 1 and code == 0 and mutant_code != 0 and failures >= 1 and errors == 0 and named
    print(f'SENDER_ACCESSOR_PROBE {GATE} {"PASS" if good else "BLOCKED"} source_sites={sites} '
          f'baseline={"green" if code == 0 else "RED"} failures={failures} errors={errors} named={named}')
    return int(not good)


if __name__ == '__main__':
    raise SystemExit(main())
