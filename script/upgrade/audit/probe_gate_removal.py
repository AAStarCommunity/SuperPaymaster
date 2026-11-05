#!/usr/bin/env python3
"""Gate-removal probes for manifest_exec.py (audit 2026-11-04; offline only).

For every ``a.need(...)`` *statement* inside the Phase A/B/D functions listed in
PHASE_FUNCTIONS, a child process loads manifest_exec.py from its unchanged source
file, replaces exactly that statement with ``pass`` in the AST (in memory; the file
on disk is never written), installs the result as ``sys.modules['manifest_exec']``
and runs the unchanged script/upgrade/test_manifest_exec.py suite.

* ``killed``   - the suite fails with the gate removed (at least one test depends on it).
* ``survived`` - the suite stays green with the gate removed (the gate is untested).

Killed probes run with unittest ``--failfast`` (the first failing test is enough to
prove the kill and is recorded); surviving probes necessarily ran the whole suite.
A separate ``--coverage`` run replaces every probed statement with a recording
wrapper that still calls ``a.need`` and reports which sites the suite reaches at all,
so a survivor can be classified as "never reached" or "reached but not asserted".

Usage (repository root):
  A3A_ENGINE_DIR=$HOME/.foundry/bin python3 -B script/upgrade/audit/probe_gate_removal.py \
      --list
  ... --coverage --out DIR
  ... --all --jobs 4 --out DIR
  ... --site LINE            (child mode, used by --all)
  ... --site LINE --select Class.test_name[,..]   (run only the named tests against the mutation)
  ... --baseline [--select ...]                    (same tests, no mutation)
"""
import sys
sys.dont_write_bytecode = True
import argparse
import ast
import concurrent.futures
import json
import os
import subprocess
import time
import types
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
UPGRADE = HERE.parent
ROOT = UPGRADE.parents[1]
TARGET = UPGRADE/'manifest_exec.py'
TESTS = 'test_manifest_exec'

# Phase A/B/D construction, execution, read-back, gate and control code. Excluded on
# purpose: release-evidence parsing, fraud-fixture parsing, Safe governance gaps and
# A3a nonce history (section-2 release/history preconditions, audited separately).
PHASE_FUNCTIONS = (
    'validate_external', 'collect_pair', 'old_pointers', 'dvt_closing', 'old_activity', 'dvt_activity', 'balances', 'drain_gate', 'collect',
    'runtime_bytes', 'verify_prefix', 'stage_readback', 'build_plan',
    'handover_gate', 'handover_trace', 'handover_controls', 'activation_eta_gate',
    'b2_gate', 'b4_post_state', 'execute_b4', 'b4_controls', 'check_predicate',
    'batch_readback', 'budget', 'validate_plan', 'pre_send', 'mint_trace',
    'unbacked_swap_control', 'early_swap_control', 'controls_at', 'run_manifest',
    'solvency_probe', 'save_artifact', 'load_artifact', 'main',
)


def is_need(node):
    return (isinstance(node, ast.Expr) and isinstance(node.value, ast.Call)
            and isinstance(node.value.func, ast.Attribute) and node.value.func.attr == 'need'
            and isinstance(node.value.func.value, ast.Name) and node.value.func.value.id == 'a')


def sites(tree=None):
    tree = tree or ast.parse(TARGET.read_text(), str(TARGET))
    found = []
    for fn in tree.body:
        if isinstance(fn, ast.FunctionDef) and fn.name in PHASE_FUNCTIONS:
            for node in ast.walk(fn):
                if is_need(node):
                    gate = node.value.args[0]
                    found.append(dict(line=node.lineno, function=fn.name,
                                      gate=gate.value if isinstance(gate, ast.Constant) else ast.unparse(gate)))
    return sorted(found, key=lambda s: s['line'])


class Remove(ast.NodeTransformer):
    def __init__(self, line):
        self.line, self.hits = line, 0

    def visit_Expr(self, node):
        if is_need(node) and node.lineno == self.line:
            self.hits += 1
            return ast.copy_location(ast.Pass(), node)
        return node


class Record(ast.NodeTransformer):
    """Coverage mode: keep the gate, but record that the statement was reached."""
    def __init__(self, lines):
        self.lines = set(lines)

    def visit_Expr(self, node):
        if is_need(node) and node.lineno in self.lines:
            hit = ast.parse(f'__probe_hits__.add({node.lineno})').body[0]
            return [ast.copy_location(hit, node), node]
        return node


def install(tree, extra=None):
    ast.fix_missing_locations(tree)
    sys.path[:0] = [str(UPGRADE), str(ROOT/'script/a3a')]
    module = types.ModuleType('manifest_exec')
    module.__file__ = str(TARGET)
    module.__dict__.update(extra or {})
    sys.modules['manifest_exec'] = module
    exec(compile(tree, str(TARGET), 'exec'), module.__dict__)
    # Performance only. validate_evidence_details (manifest_exec.py, the module's only
    # ast.walk/ast.parse call site, asserted below) re-parses the same unchanged test
    # sources on every evidence check and keeps only FunctionDef/AsyncFunctionDef names.
    # The memo returns exactly those nodes for the same source text, so every gate
    # decision is unchanged; it cuts suite time several-fold.
    source = TARGET.read_text()
    assert source.count('ast.walk(') == 1 and source.count('ast.parse(') == 1
    module.__dict__['ast'] = MemoAst()
    return module


class MemoAst:
    def __init__(self):
        self.__dict__.update({k: v for k, v in vars(ast).items() if not k.startswith('__') and k not in ('parse', 'walk')})
        self._trees, self._walks = {}, {}

    def parse(self, source, *args, **kwargs):
        if args or kwargs or not isinstance(source, str):
            return ast.parse(source, *args, **kwargs)
        if source not in self._trees:
            self._trees[source] = ast.parse(source)
        return self._trees[source]

    def walk(self, node):
        key = id(node)
        if key not in self._walks or self._walks[key][0] is not node:
            self._walks[key] = (node, [n for n in ast.walk(node)
                                       if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef))])
        return iter(self._walks[key][1])


def flatten(suite):
    for t in suite:
        yield from (flatten(t) if isinstance(t, unittest.TestSuite) else (t,))


def run_suite(failfast, select=None):
    os.chdir(ROOT)
    tests = __import__(TESTS)
    suite = unittest.defaultTestLoader.loadTestsFromModule(tests)
    if select:
        # Exact test-id suffixes ("Class.test_name"); an unmatched selector is a harness error, not a pass.
        chosen = [t for t in flatten(suite) if any(t.id().endswith('.'+name) for name in select)]
        unmatched = [name for name in select if not any(t.id().endswith('.'+name) for t in chosen)]
        if unmatched:
            raise SystemExit(f'PROBE_ERROR unmatched --select {unmatched}')
        suite = unittest.TestSuite(chosen)
    result = unittest.TextTestRunner(stream=sys.stdout, verbosity=1, failfast=failfast).run(suite)
    return result


def child(line, failfast, select=None):
    tree = ast.parse(TARGET.read_text(), str(TARGET))
    if line:
        remover = Remove(line)
        tree = remover.visit(tree)
        if remover.hits != 1:
            print(f'PROBE_ERROR line {line}: {remover.hits} statements matched')
            return 2
    install(tree)
    mutation = 'replace a.need statement with pass' if line else 'none (baseline)'
    print(f'PROBE line={line} mutation={mutation} failfast={failfast} select={select}', flush=True)
    result = run_suite(failfast, select)
    first = (result.failures + result.errors)[:1]
    if first:
        print('FIRST_FAILING_TEST', first[0][0].id())
    for test, _ in result.failures:
        print('FAILED_TEST', test.id())
    print('PROBE_RESULT', 'killed' if not result.wasSuccessful() else 'survived', 'ran', result.testsRun,
          'failures', len(result.failures), 'errors', len(result.errors), 'expectedFailures', len(result.expectedFailures))
    return 0


def coverage(out):
    tree = ast.parse(TARGET.read_text(), str(TARGET))
    probe = sites(tree)
    hits = set()
    tree = Record([s['line'] for s in probe]).visit(tree)
    install(tree, {'__probe_hits__': hits})
    result = run_suite(False)
    record = dict(baselineGreen=result.wasSuccessful(), testsRun=result.testsRun,
                  reached=sorted(hits), unreached=[s['line'] for s in probe if s['line'] not in hits])
    (out/'coverage.json').write_text(json.dumps(record, indent=1)+'\n')
    print('COVERAGE reached', len(hits), 'of', len(probe), 'green', result.wasSuccessful())
    return 0 if result.wasSuccessful() else 1


def run_one(site, out, env):
    log = out/f'probe-L{site["line"]:04d}.log'
    if log.exists() and 'PROBE_RESULT' in log.read_text():
        text = log.read_text()   # resume: keep the earlier actual run output
        status = next(r.split()[1] for r in text.splitlines() if r.startswith('PROBE_RESULT'))
        first = next((r.split(' ', 1)[1] for r in text.splitlines() if r.startswith('FIRST_FAILING_TEST')), None)
        return dict(site, status=status, firstFailingTest=first, log=str(log.relative_to(ROOT)))
    started = time.time()
    # Try failfast first; a green failfast run already executed the full suite.
    proc = subprocess.run([sys.executable, '-B', str(Path(__file__)), '--site', str(site['line']), '--failfast'],
                          cwd=ROOT, env=env, capture_output=True, text=True)
    text = proc.stdout + proc.stderr
    log.write_text(f'# gate={site["gate"]} function={site["function"]} line={site["line"]}\n'
                   f'# command: python3 -B script/upgrade/audit/probe_gate_removal.py --site {site["line"]} --failfast\n'
                   f'# exit={proc.returncode} seconds={time.time()-started:.1f}\n' + text)
    status = 'error'
    for row in text.splitlines():
        if row.startswith('PROBE_RESULT'):
            status = row.split()[1]
    first = next((r.split(' ', 1)[1] for r in text.splitlines() if r.startswith('FIRST_FAILING_TEST')), None)
    return dict(site, status=status, firstFailingTest=first, log=str(log.relative_to(ROOT)))


def run_all(out, jobs):
    env = dict(os.environ)
    probe = sites()
    results = []
    with concurrent.futures.ThreadPoolExecutor(jobs) as pool:
        for r in pool.map(lambda s: run_one(s, out, env), probe):
            results.append(r)
            print(f'L{r["line"]:04d} {r["status"]:8s} {r["function"]}:{r["gate"]}', flush=True)
    summary = dict(target='script/upgrade/manifest_exec.py', suite='script/upgrade/test_manifest_exec.py',
                   functions=list(PHASE_FUNCTIONS), total=len(results),
                   killed=sum(r['status'] == 'killed' for r in results),
                   survived=[r for r in results if r['status'] == 'survived'],
                   errors=[r for r in results if r['status'] not in ('killed', 'survived')],
                   results=results)
    (out/'summary.json').write_text(json.dumps(summary, indent=1)+'\n')
    print('PROBES total', summary['total'], 'killed', summary['killed'],
          'survived', len(summary['survived']), 'errors', len(summary['errors']))
    return 0


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--list', action='store_true')
    p.add_argument('--coverage', action='store_true')
    p.add_argument('--all', action='store_true')
    p.add_argument('--site', type=int)
    p.add_argument('--failfast', action='store_true')
    p.add_argument('--select', type=lambda v: v.split(','), help='comma-separated exact test-id suffixes')
    p.add_argument('--baseline', action='store_true', help='run (selected) tests on the unmodified module')
    p.add_argument('--jobs', type=int, default=4)
    p.add_argument('--out', type=Path)
    args = p.parse_args()
    if args.list:
        for s in sites():
            print(f'{s["line"]:5d} {s["function"]:22s} {s["gate"]}')
        print(len(sites()), 'sites')
        return 0
    if args.site:
        return child(args.site, args.failfast, args.select)
    if args.baseline:
        return child(0, args.failfast, args.select)
    args.out = args.out.resolve()
    args.out.mkdir(parents=True, exist_ok=True)
    if args.coverage:
        return coverage(args.out)
    if args.all:
        return run_all(args.out, args.jobs)
    p.error('nothing to do')


if __name__ == '__main__':
    sys.exit(main())
