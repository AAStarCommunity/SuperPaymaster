#!/usr/bin/env python3
"""Bounded offline per-call typed probes; all source mutations use temporary copies.

Discovery runs named offline suites, never a probe-driver batch. Each target test
runs through its original fixture. Malformed data enters through original inputs
or immediate provider returns; only the selected typed call is removed in the
mutant tree. Earlier stops and downstream errors block acceptance.
"""
import ast
import io
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from gate_assertions import assert_stop, assertion_mentions
from gate_typed_sites import ROOT

SUITES = ['test_old_owner_isolation', 'test_manifest_exec', 'test_manifest_phase_c',
          'test_a3a_exec', 'test_a3a_send', 'test_sp_upgrade_exec', 'test_authority_checkpoints',
          'test_swallow_exceptions', 'test_execution_head', 'test_execution_reads',
          'test_gate_names', 'test_gate_rename_controls', 'test_gate_template_controls',
          'test_gate_dsr2', 'test_gate_empty_schema', 'test_gate_extra_finite',
          'test_gate_review_controls', 'test_gate_r_controls', 'test_getter_accessor',
          'test_sender_accessor', 'test_gate_typed_controls', 'test_gate_declaration_controls',
          'test_gate_typed_boundaries', 'test_gate_typed_fields',
          'test_gate_typed_shadow_controls', 'test_gate_typed_log_fields']


def discover(out, suites=SUITES):
    import a3a_exec as a
    out.mkdir(parents=True, exist_ok=True)
    candidates = json.loads((out / 'candidates.json').read_text()) if (out / 'candidates.json').exists() else {}
    summaries = (out / 'suites.txt').read_text().splitlines() if (out / 'suites.txt').exists() else []
    faults = 0
    current = None
    seen = set()
    start = 0
    typed_code = a.typed.__code__

    def observe(frame, event, result):
        if event == 'return' and frame.f_code is typed_code and result is not None:
            gate = frame.f_locals['gate']
            if gate.startswith('rpc_result_'):
                seen.add(gate)

    class Result(unittest.TextTestResult):
        def startTest(self, test):
            nonlocal current, start
            current, start = test.id(), time.monotonic()
            seen.clear()
            super().startTest(test)

        def addSuccess(self, test):
            elapsed = time.monotonic() - start
            for gate in seen:
                candidates.setdefault(gate, []).append(dict(test=current, seconds=elapsed))
            super().addSuccess(test)

    for module in suites:
        stream = io.StringIO()
        suite = unittest.defaultTestLoader.loadTestsFromName(module)
        previous = sys.getprofile()
        try:
            sys.setprofile(observe)
            result = unittest.TextTestRunner(stream=stream, resultclass=Result).run(suite)
        finally:
            sys.setprofile(previous)
        log = stream.getvalue()
        (out / (module + '.log')).write_text(log)
        summary = f'SUITE {module} {"PASS" if result.wasSuccessful() else "FAIL"} tests={result.testsRun} failures={len(result.failures)} errors={len(result.errors)}'
        print(log + summary, flush=True)
        summaries = [line for line in summaries if not line.startswith('SUITE ' + module + ' ')]
        summaries.append(summary)
        faults += not result.wasSuccessful()
        (out / 'candidates.json').write_text(json.dumps(candidates, indent=2) + '\n')
        (out / 'suites.txt').write_text('\n'.join(summaries) + '\n')
    for gate, rows in candidates.items():
        unique = {row['test']: row for row in rows}
        candidates[gate] = sorted(unique.values(), key=lambda r: r['seconds'])
    (out / 'candidates.json').write_text(json.dumps(candidates, indent=2) + '\n')
    (out / 'suites.txt').write_text('\n'.join(summaries) + '\n')
    return int(bool(faults))


def discover_all(out):
    failures = 0
    for module in SUITES:
        child = subprocess.run([sys.executable, '-B', str(Path(__file__).resolve()),
                                '--discover-one', str(out), module], text=True, capture_output=True)
        print(child.stdout + child.stderr, end='', flush=True)
        print(f'FOREGROUND_SUITE_EXIT {module} {child.returncode}', flush=True)
        failures += child.returncode != 0
    return int(bool(failures))


def selected_test(test_id, gate):
    test = next(iter(unittest.defaultTestLoader.loadTestsFromName(test_id)))

    class Control(unittest.TestCase):
        def runTest(self):
            cls = type(test)
            cls.setUpClass()
            for name in ('a3a_exec', 'a3a_send', 'manifest_exec', 'old_owner_isolation', 'sp_upgrade_exec'):
                if name in sys.modules:
                    setattr(sys.modules[name], '__gate_probe_active', True)
            try:
                with assert_stop(self, gate):
                    test.setUp()
                    try:
                        getattr(test, test._testMethodName)()
                    finally:
                        test.tearDown()
            finally:
                test.doCleanups()
                cls.tearDownClass()
                cls.doClassCleanups()
    stream = io.StringIO()
    result = unittest.TextTestRunner(stream=stream).run(Control())
    print(stream.getvalue(), end='')
    return int(not result.wasSuccessful() or bool(result.skipped))


def source_site(source, row):
    tree = ast.parse(source)
    sites = [n for n in ast.walk(tree) if isinstance(n, ast.Call) and n.lineno == row['line'] and n.col_offset == row['column']
             and any(k.arg == 'gate' and isinstance(k.value, ast.Constant) and k.value.value == row['gate'] for k in n.keywords)]
    assert len(sites) == 1, f'{row["gate"]}: source_sites={len(sites)}'
    return tree, sites[0]


def return_ingress(tree, call):
    def io(node):
        return isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id in ('rpc', 'remote', 'cast')
    value = call.args[0]
    if io(value):
        return value
    # A raw response may be bound on the immediately preceding statement. Inject
    # at that assignment, so every subsequent read sees the malformed response.
    if isinstance(value, ast.Name):
        for parent in ast.walk(tree):
            for _, block in ast.iter_fields(parent):
                if not isinstance(block, list):
                    continue
                for index, statement in enumerate(block):
                    if index and isinstance(statement, ast.Expr) and statement.value is call:
                        previous = block[index-1]
                        if (isinstance(previous, ast.Assign) and len(previous.targets) == 1
                                and isinstance(previous.targets[0], ast.Name) and previous.targets[0].id == value.id
                                and io(previous.value)):
                            return previous.value
    return None


def rewrite(path, row, malformed, delete):
    assert not path.resolve().is_relative_to(ROOT.resolve()), 'refusing to mutate real worktree source'
    source = path.read_text()
    tree, call = source_site(source, row)
    lines = source.splitlines(keepends=True)
    def span(node):
        return (sum(map(len, lines[:node.lineno-1])) + node.col_offset,
                sum(map(len, lines[:node.end_lineno-1])) + node.end_col_offset)
    edits = []
    argument = ast.get_source_segment(source, call.args[0])
    if malformed is None:
        # Direct fixtures already supply malformed data before production entry.
        if delete:
            edits.append((*span(call), argument))
    else:
        ingress = return_ingress(tree, call)
        assert ingress is not None, 'no independent malformed-input fixture; refusing field-boundary injection'
        bad = "'0X' + __probe_value[2:]" if malformed == 'uppercase-prefix' else repr(malformed)
        replacement = ('(lambda __probe_value: ' + bad +
                       " if globals().get('__gate_probe_active', False) else __probe_value)(" +
                       ast.get_source_segment(source, ingress) + ')')
        if ingress is call.args[0]:
            edits.append((*span(call if delete else ingress), replacement))
        else:
            edits.append((*span(ingress), replacement))
            if delete:
                edits.append((*span(call), argument))
    for start, end, replacement in sorted(edits, reverse=True):
        source = source[:start] + replacement + source[end:]
    path.write_text(source)
    return 1


def probes(out, only=()):
    from test_gate_typed_boundaries import ACTIONS
    from test_gate_typed_fields import CASES
    direct_cases = {gate:'test_gate_typed_boundaries.TypedBoundaryTests.test_' + gate for gate in ACTIONS}
    direct_cases.update(CASES)
    from test_gate_typed_shadow_controls import CASES as shadow_cases
    from test_gate_typed_log_fields import CASES as log_cases
    direct_cases.update(shadow_cases)
    direct_cases.update(log_cases)
    candidates = json.loads((out / 'candidates.json').read_text())
    rows = json.loads((ROOT / 'script/upgrade/gate_typed_inventory.json').read_text())
    if only:
        unknown = set(only) - {row["gate"] for row in rows}
        if unknown: raise ValueError(f"Unknown probe sites: {unknown}")
        rows = [row for row in rows if row["gate"] in only]
    report = []
    with tempfile.TemporaryDirectory(prefix='6e-typed-probes-') as tmp:
        tree = Path(tmp)
        # Offline local object copy: provenance reads stay in the temporary repository.
        # No checkout, source redirection, RPC, environment file, or gate bypass.
        subprocess.run(['git', 'clone', '--local', '--no-hardlinks', '--no-checkout', '--quiet',
                        str(ROOT), str(tree)], check=True, timeout=60)
        shutil.copytree(ROOT / 'script', tree / 'script', ignore=shutil.ignore_patterns('__pycache__', '.env*', 'keystore', 'keystores'))
        for relative in ('docs/release/a3a-precheck-v4/a3a-precheck.json',
                         'docs/release/a3a-precheck-v4/snapshot.json',
                         'docs/release/sp-upgrade-a6e/evidence-11983550/boot/plan.json'):
            target = tree / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / relative, target)
        for row in rows:
            gate = row['gate']
            path = tree / row['file']
            original = path.read_text()
            attempts = []
            accepted = False
            site_fault = None
            source_tree, source_call = source_site(original, row)
            ingress = return_ingress(source_tree, source_call)
            choices = candidates.get(gate, []) if ingress is not None else []
            if gate in direct_cases:
                choices = [dict(test=direct_cases[gate], direct=True)]
            # A dedicated malformed-input fixture owns its site. Otherwise try discovered
            # provider fixtures until one satisfies the strict criterion.
            for candidate in choices:
                # First preserve the payload but violate the required lowercase prefix.
                # Then try wrong-width and non-hex returns. Errors never count as proof.
                for malformed in ((None,) if candidate.get('direct') else
                                  ('uppercase-prefix', '0X' + '00' * 32, '0x01', 'malformed')):
                    logs = {}
                    try:
                        path.write_text(original)
                        sites = rewrite(path, row, malformed, False)
                        command = [sys.executable, '-B', str(tree / 'script/upgrade/probe_typed_gates.py'),
                                   '--selected', candidate['test'], gate]
                        cwd = tree
                        if candidate.get('direct'):
                            command = [sys.executable, '-B', '-m', 'unittest', candidate['test']]
                            cwd = tree / 'script/upgrade'
                        baseline = subprocess.run(command, cwd=cwd, text=True, capture_output=True, timeout=120)
                        logs['baseline'] = baseline.stdout + baseline.stderr
                        if baseline.returncode != 0:
                            attempts.append(dict(test=candidate['test'], malformed=malformed, **logs))
                            continue
                        path.write_text(original)
                        sites = rewrite(path, row, malformed, True)
                        mutant = subprocess.run(command, cwd=cwd, text=True, capture_output=True, timeout=120)
                        logs['mutant'] = mutant.stdout + mutant.stderr
                        failures, errors = logs['mutant'].count('FAIL:'), logs['mutant'].count('ERROR:')
                        named = assertion_mentions(logs['mutant'], gate)
                        accepted = sites == 1 and mutant.returncode != 0 and failures >= 1 and errors == 0 and named
                        attempts.append(dict(test=candidate['test'], malformed=malformed, **logs))
                        if accepted:
                            final = f'RPC_RESULT_PROBE {gate} PASS sites=1 baseline=green failures={failures} errors={errors} named={named}'
                            break
                    except subprocess.TimeoutExpired:
                        attempts.append(dict(test=candidate['test'], malformed=malformed, blocked='120-second fixture timeout'))
                    except (AssertionError, SyntaxError, OSError, ValueError) as error:
                        site_fault = type(error).__name__ + ': ' + str(error)
                        attempts.append(dict(test=candidate['test'], malformed=malformed, blocked=site_fault))
                        break
                    finally:
                        path.write_text(original)
                if accepted or site_fault:
                    break
            if not accepted:
                reason = (f'no independent malformed original-input fixture for {row["value"]} in {row["function"]}; field-boundary injection prohibited'
                          if not choices else 'real fixture failed exact-target baseline or strict deletion criterion; see per-attempt logs')
                reason = site_fault or reason
                final = f'RPC_RESULT_PROBE {gate} BLOCKED sites={"unverified" if site_fault else 1} candidates={len(choices)} attempts={len(attempts)} reason={reason}'
            print(final, flush=True)
            item = dict(row, passed=accepted, final=final, ingress=('original_input' if gate in direct_cases else
                        'immediate_return' if ingress is not None else 'unestablished'), attempts=attempts)
            report.append(item)
            (out / (gate + '.json')).write_text(json.dumps(item, indent=2) + '\n')
    (out / 'probes.json').write_text(json.dumps(report, indent=2) + '\n')
    final = f'RPC_RESULT_PROBES passed={sum(r["passed"] for r in report)} total={len(rows)} blocked={sum(not r["passed"] for r in report)} errors_accepted=0'
    print(final, flush=True)
    (out / 'probes.txt').write_text('\n'.join(r['final'] for r in report) + '\n' + final + '\n')
    return int(any(not r['passed'] for r in report))


if __name__ == '__main__':
    sys.path.insert(0, str(ROOT / 'script/a3a'))
    if sys.argv[1] == '--selected':
        raise SystemExit(selected_test(*sys.argv[2:]))
    out = Path(sys.argv[2])
    if sys.argv[1] == '--discover-one':
        raise SystemExit(discover(out, sys.argv[3:]))
    if sys.argv[1] not in ('--discover', '--probes'):
        raise SystemExit('usage: probe_typed_gates.py --discover|--probes OUTPUT_DIRECTORY')
    raise SystemExit(discover_all(out) if sys.argv[1] == '--discover' else probes(out, sys.argv[3:]))
