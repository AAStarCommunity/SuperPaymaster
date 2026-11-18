#!/usr/bin/env python3
"""Offline deletion probes for the three DSR inventory/replay regressions."""
import pathlib
import re
import subprocess
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'script/upgrade'))
from gate_assertions import assertion_mentions
SOURCE = ROOT/'script/upgrade/manifest_exec.py'
PROBES = {
    'inventory_drift': (
        "    a.need('old_timelock_inventory', (found, {k: section[k] for k in fields}),\n"
        "           (expected, {k: pin['oldOwnerIsolation'][k] for k in fields}))\n",
        'test_old_timelock_inventory_new_token'),
    'replay_owners': (
        "    a.need('old_timelock_replay_owners', actual['approvalOwners'], section['approvalOwners'])\n",
        'test_old_timelock_log_replay'),
    'replay_unused': (
        "    a.need('old_timelock_unused', next(reads, None), None)\n",
        'test_old_timelock_log_replay'),
}


def main():
    source = SOURCE.read_text()
    if len(sys.argv) > 1:
        name, mode = sys.argv[1:]
        site, test = PROBES[name]
        sys.path.insert(0, str(SOURCE.parent))
        import test_manifest_exec as tests
        if mode == 'mutated':
            assert source.count(site) == 1
            exec(compile(source.replace(site, ''), str(SOURCE), 'exec'), tests.m.__dict__)
        suite = unittest.defaultTestLoader.loadTestsFromName('ManifestTests.'+test, tests)
        return 0 if unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful() else 1
    ok = True
    for name, (site, _) in PROBES.items():
        count = source.count(site)
        results = []
        for mode in ('baseline', 'mutated'):
            proc = subprocess.run([sys.executable, '-B', __file__, name, mode], cwd=ROOT,
                                  capture_output=True, text=True, stdin=subprocess.DEVNULL)
            lines = proc.stderr.splitlines()
            tail = next((line for line in reversed(lines) if line.startswith(('OK', 'FAILED'))), '')
            results.append((proc.returncode, tail, proc.stderr))
        baseline, mutated = results
        gate = re.search(r"a.need\('([^']+)'", site)[1]
        passed = (count == 1 and baseline[0] == 0 and baseline[1] == 'OK'
                  and mutated[0] == 1 and re.search(r'failures=[1-9][0-9]*', mutated[1])
                  and 'errors=' not in mutated[1]
                  and assertion_mentions(mutated[2], gate))
        ok &= passed
        print(f'{name}: matches={count}, baseline {baseline[1]}, mutated {mutated[1]}', flush=True)
        if not passed:
            print(mutated[2], flush=True)
    print('INVENTORY_REPLAY_PROBES '+('PASS' if ok else 'FAIL'))
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
