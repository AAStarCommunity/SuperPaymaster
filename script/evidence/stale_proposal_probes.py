#!/usr/bin/env python3
"""Gate-removal probes for the DVT stale-proposal exemption, closing read-back and pointer gates (#606).

Each probe replaces one gate statement with `pass` (or drops the sibling level comparison) in an IN-MEMORY copy
of manifest_exec.py, installs it as `manifest_exec` in a fresh child interpreter (probe_gate_removal.install),
runs the named controls there, and requires them to turn red by assertion failures only (failures > 0,
errors == 0): an exception elsewhere is not evidence that the forbidden state was accepted.

The source file on disk is never written, so there is nothing to restore: an interrupted, killed or concurrent
run cannot leave a mutated source or test another run's mutation. Each child reports one JSON result line;
a child that does not report (crash, no tests run) is a failure, never a pass.

Limitation: controls assert the gate *name*, so a removal can turn red because a later gate rejects the same
state under another name. A red probe proves the control is bound to that gate; it does not by itself prove
the state would otherwise be accepted end to end.

Usage (repository root; set A3A_ENGINE_DIR as in CI): python3 -B script/evidence/stale_proposal_probes.py
"""
import sys
sys.dont_write_bytecode = True
import ast
import io
import json
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'script/upgrade/audit'))
import probe_gate_removal as probe  # noqa: E402

PATTERNS = ['*stale_dvt*', '*unsigned_dvt*', '*dvt_closing*', '*old_pointers*']
GATES = ['dvt_stale_next_id', 'dvt_proposal_inventory', 'dvt_stale_proposal_listed', 'dvt_stale_proposal_shape',
         'dvt_stale_sibling_executed', 'dvt_stale_open_set', 'closing_registry_pointer', 'closing_dvt_pointer',
         'closing_committee_pointer', 'closing_dvt_activity', 'closing_stale_unexecuted', 'old_pointer',
         'pointer_owner']
SIBLING = ("(peer[0], peer[1], peer[3], peer[5]), (w[0], w[1], 1, evidence)",
           "(peer[0], peer[3], peer[5]), (w[0], 1, evidence)")
RESULT = 'PROBE_JSON '


def mutate(source, name):
    if name == 'baseline':
        return source
    if name == 'sibling_level':
        assert source.count(SIBLING[0]) == 1, name
        return source.replace(*SIBLING)
    lines = source.split('\n')
    hits = [i for i, l in enumerate(lines) if f"a.need('{name}'" in l]
    assert len(hits) == 1, (name, hits)
    line = lines[hits[0]]
    lines[hits[0]] = line[:len(line)-len(line.lstrip())] + 'pass'
    return '\n'.join(lines)


def child(name):
    probe.install(ast.parse(mutate(probe.TARGET.read_text(), name), str(probe.TARGET)))
    tests = __import__('test_manifest_exec')
    loader = unittest.TestLoader()
    loader.testNamePatterns = PATTERNS
    stream = io.StringIO()
    result = unittest.TextTestRunner(stream=stream, verbosity=0).run(loader.loadTestsFromModule(tests))
    print(RESULT + json.dumps(dict(name=name, ran=result.testsRun, failures=len(result.failures),
                                   errors=len(result.errors))), flush=True)


def run(name):
    p = subprocess.run([sys.executable, '-B', __file__, '--child', name], cwd=ROOT, capture_output=True, text=True)
    rows = [l[len(RESULT):] for l in p.stdout.splitlines() if l.startswith(RESULT)]
    if p.returncode != 0 or len(rows) != 1:
        return dict(name=name, ran=0, failures=0, errors=-1, note='child did not report (rc=%d)' % p.returncode)
    return json.loads(rows[0])


def main():
    if sys.argv[1:2] == ['--child']:
        return child(sys.argv[2])
    before = probe.TARGET.read_bytes()
    base = run('baseline')
    print('baseline:', base, flush=True)
    if not (base['ran'] > 0 and base['failures'] == 0 and base['errors'] == 0):
        print('baseline not green')
        return 1
    ok = True
    for name in GATES + ['sibling_level']:
        r = run(name)
        red = r['ran'] == base['ran'] and r['failures'] > 0 and r['errors'] == 0
        ok &= red
        print('remove %s -> ran=%d failures=%d errors=%d %s' % (name, r['ran'], r['failures'], r['errors'],
              'red' if red else 'NOT RED ' + r.get('note', '')), flush=True)
    # The parent never writes the source; assert it anyway.
    unchanged = probe.TARGET.read_bytes() == before
    print('SOURCE_UNCHANGED', int(unchanged))
    print('PROBES_ALL_RED=%d' % int(ok and unchanged))
    return 0 if ok and unchanged else 1


if __name__ == '__main__':
    sys.exit(main())
