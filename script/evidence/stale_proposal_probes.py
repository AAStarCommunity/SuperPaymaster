#!/usr/bin/env python3
"""Gate-removal probes for the DVT stale-proposal exemption, closing read-back and pointer gates (#606).

Each probe replaces one gate statement with `pass` (or drops the sibling level comparison) in an IN-MEMORY copy
of manifest_exec.py, installs it as `manifest_exec` in a fresh child interpreter (probe_gate_removal.install),
runs the named controls there, and requires them to turn red by assertion failures only (failures > 0,
errors == 0): an exception elsewhere is not evidence that the forbidden state was accepted.

The source file on disk is never written, so there is nothing to restore: an interrupted, killed or concurrent
run cannot leave a mutated source or test another run's mutation. Gates are removed as AST statements
(probe_gate_removal.sites/Remove), never by text. Each child writes its result to a file the parent names (not
stdout), with the probe name and the ids of the tests it ran; a missing, malformed or mismatched result is a
failure, never a pass.

A mutation counts only if the controls actually executed the changed site: the removed gate is replaced by a
statement that records it was reached (the sibling edit records its statement too), so a control that fails
before reaching the site (e.g. in setUp) cannot stand in for the gate.

Trust boundary: the controls themselves are reviewed code in the same commit. The harness defends against
accidental mismatches (wrong statement, stale or mixed results, concurrent runs, an unreached site), not
against test code that deliberately forges its own result; that is for review.

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
import tempfile
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
# Gates live in these functions; each listed gate must be exactly one a.need statement there.
FUNCTIONS = {'dvt_activity', 'dvt_closing', 'old_pointers'}
SIBLING = ("(peer[0], peer[1], peer[3], peer[5]), (w[0], w[1], 1, evidence)",
           "(peer[0], peer[3], peer[5]), (w[0], 1, evidence)")


def functions(tree):
    return {fn.name: ast.dump(fn) for fn in tree.body if isinstance(fn, ast.FunctionDef)}


def mutate(source, name):
    """An AST for the probe; asserts it differs from the source exactly where intended."""
    tree = ast.parse(source, str(probe.TARGET))
    if name == 'baseline':
        return tree
    if name == 'sibling_level':
        assert source.count(SIBLING[0]) == 1, name
        mutated = ast.parse(source.replace(*SIBLING), str(probe.TARGET))
        before, after = functions(tree), functions(mutated)
        # A textual edit must change code, and only dvt_activity's (never a comment, never elsewhere).
        assert [f for f in before if before[f] != after.get(f)] == ['dvt_activity'], name
        site = [x for x in probe.sites(mutated) if x['gate'] == 'dvt_stale_sibling_executed']
        assert len(site) == 1, (name, site)
        # Keep the edited statement; record that it ran.
        return probe.Record([site[0]['line']]).visit(mutated)
    # Gate removal by AST statement (probe_gate_removal.Remove), never by text: a comment or another
    # statement mentioning the gate cannot be removed in its place.
    site = [s for s in probe.sites(tree) if s['gate'] == name and s['function'] in FUNCTIONS]
    assert len(site) == 1, (name, site)
    remover = Reached(site[0]['line'])
    tree = remover.visit(tree)
    assert remover.hits == 1, (name, remover.hits)
    return tree


class Reached(probe.Remove):
    """Like probe_gate_removal.Remove, but the gate becomes a record that its site was reached."""
    def visit_Expr(self, node):
        if probe.is_need(node) and node.lineno == self.line:
            self.hits += 1
            return ast.copy_location(ast.parse(f'__probe_hits__.add({node.lineno})').body[0], node)
        return node


def child(name, result_path):
    hits = set()
    probe.install(mutate(probe.TARGET.read_text(), name), {'__probe_hits__': hits})
    tests = __import__('test_manifest_exec')
    loader = unittest.TestLoader()
    loader.testNamePatterns = PATTERNS
    suite = loader.loadTestsFromModule(tests)
    ids = sorted(t.id() for t in probe.flatten(suite))
    result = unittest.TextTestRunner(stream=io.StringIO(), verbosity=0).run(suite)
    # The result goes to a file the parent named, never through stdout, which tests can write to.
    Path(result_path).write_text(json.dumps(dict(name=name, ids=ids, ran=result.testsRun, reached=bool(hits),
                                                 failures=len(result.failures), errors=len(result.errors))))


def run(name):
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp)/'result.json'
        p = subprocess.run([sys.executable, '-B', __file__, '--child', name, str(path)], cwd=ROOT,
                           capture_output=True, text=True)
        try:
            r = json.loads(path.read_text())
            assert p.returncode == 0 and r['name'] == name
            assert set(r) == {'name', 'ids', 'ran', 'reached', 'failures', 'errors'}
        except Exception:
            return dict(name=name, ids=[], ran=0, reached=False, failures=0, errors=-1,
                        note='child did not report (rc=%d)' % p.returncode)
    return r


def main():
    if sys.argv[1:2] == ['--child']:
        return child(sys.argv[2], sys.argv[3])
    before = probe.TARGET.read_bytes()
    base = run('baseline')
    print('baseline:', {k: v for k, v in base.items() if k != 'ids'}, base['ids'], flush=True)
    if not (base['ran'] > 0 and base['ran'] == len(base['ids']) and base['failures'] == 0 and base['errors'] == 0):
        print('baseline not green')
        return 1
    ok = True
    for name in GATES + ['sibling_level']:
        r = run(name)
        # Same tests as the baseline (by id), all run, red by assertion failures only.
        red = (r['ids'] == base['ids'] and r['ran'] == base['ran'] and r['reached']
               and r['failures'] > 0 and r['errors'] == 0)
        ok &= red
        print('remove %s -> ran=%d reached=%d failures=%d errors=%d %s' % (name, r['ran'], r['reached'], r['failures'],
              r['errors'], 'red' if red else 'NOT RED ' + r.get('note', '')), flush=True)
    # The parent never writes the source; assert it anyway.
    unchanged = probe.TARGET.read_bytes() == before
    print('SOURCE_UNCHANGED', int(unchanged))
    print('PROBES_ALL_RED=%d' % int(ok and unchanged))
    return 0 if ok and unchanged else 1


if __name__ == '__main__':
    sys.exit(main())
