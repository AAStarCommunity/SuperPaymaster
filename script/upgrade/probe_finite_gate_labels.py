#!/usr/bin/env python3
"""Focused finite-label probes; only recorded real offline controls are deleted."""
import ast
import importlib
import inspect
import io
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import patch
import probe_phase_c_gates as driver
from gate_rename_ast_diff import ROOT
from gate_assertions import assertion_mentions
from gate_probe_trace import baseline_trace

MODULES = ('test_manifest_exec', 'test_manifest_phase_c', 'test_old_owner_isolation',
           'test_gate_template_controls')


def controls():
    rows = json.loads((ROOT / 'script/upgrade/gate_templates.json').read_text())
    return [(row, label, row['probes'][label]['gate']) for row in rows if not row.get('empty_schema_acceptance') for label in row['labels']]


def discover():
    """Run relevant existing controls once, recording actual failed gate statements."""
    cases = controls()
    wanted = {gate for _, _, gate in cases}
    prefixes = {gate.rsplit('_', 1)[0] for gate in wanted}
    bindings, logs = {}, []
    for name in MODULES:
        module = importlib.import_module(name)
        suite = unittest.defaultTestLoader.loadTestsFromModule(module)
        def flatten(suite):
            for test in suite:
                if isinstance(test, unittest.TestSuite):
                    yield from flatten(test)
                else:
                    yield test
        for test in flatten(suite):
            method = getattr(type(test), test._testMethodName)
            try:
                source = inspect.getsource(method)
            except (OSError, TypeError):
                source = ''
            # Generated controls carry the gate in their method name or closure.
            closure = [c.cell_contents for c in (getattr(method, '__closure__', None) or ())]
            strings = [source, test._testMethodName] + [x for x in closure if isinstance(x, str)]
            if not any(prefix in text for prefix in prefixes for text in strings):
                continue
            green, _, log = driver.run(type(test), test._testMethodName)
            if not green:
                logs.append(dict(test=test.id(), baseline='RED', log=log))
                continue
            for (cls, method_name, gate), sites in list(driver.SITES.items()):
                if cls is type(test) and method_name == test._testMethodName and gate in wanted and len(sites) == 1:
                    bindings.setdefault(gate, []).append(dict(module=name, cls=cls.__name__, method=method_name,
                                                            site=list(next(iter(sites)))))
    return bindings, logs


def probe_label(row, label, candidates):
    gate = row['probes'][label]['gate']
    attempts = []
    for binding in candidates:
        cls = getattr(importlib.import_module(binding['module']), binding['cls'])
        green, baseline, traces = baseline_trace(cls, binding['method'])
        if not green:
            attempts.append('baseline RED: ' + baseline)
            continue
        sites = driver.SITES.get((cls, binding['method'], gate), set())
        if len(sites) != 1:
            attempts.append('expected one recorded failing source site: ' + repr(sites))
            continue
        # Bind to this source site, not a same-name check elsewhere.
        filename, line = next(iter(sites))
        if Path(filename).resolve() != (ROOT / row['file']).resolve():
            continue
        if line != row['line'] and (str(ROOT / row['file']), row['line']) not in traces.get(gate, set()):
            # Wrapper calls may fail at the primitive guard. Such bindings require
            # a separate reviewed caller-to-primitive proof, never a name-only match.
            attempts.append(f'wrapper source {row["line"]} records primitive {line}; binding unresolved')
            continue
        accepted, reached, mutant = driver.run(cls, binding['method'], gate)
        attempts.append(baseline + mutant)
        if reached and not accepted:
            failures = mutant.count('FAIL:')
            named = assertion_mentions(mutant, gate)
            errors = mutant.count('ERROR:')
            if failures >= 1 and errors == 0 and named:
                return True, f'FINITE_LABEL {row["file"]}:{row["line"]} {label} {gate} PASS sites=1 baseline=green failures={failures} errors=0 named=True', attempts
    reason = 'no existing exact-gate negative fixture discovered' if not candidates else 'no candidate met strict criterion'
    return False, f'FINITE_LABEL {row["file"]}:{row["line"]} {label} {gate} BLOCKED {reason}', attempts


def main():
    bindings, failures = discover()
    report = dict(bindings=bindings, baseline_failures=failures, results=[])
    passed = 0
    for row, label, gate in controls():
        good, final, attempts = probe_label(row, label, bindings.get(gate, []))
        passed += good
        print(final, flush=True)
        report['results'].append(dict(file=row['file'], line=row['line'], label=label, gate=gate,
                                      passed=good, final=final, attempts=attempts))
    path = Path('/tmp/commit6e-rulings/finite-probes.json')
    path.parent.mkdir(exist_ok=True)
    path.write_text(json.dumps(report, indent=2)+'\n')
    total = len(report['results'])
    print(f'FINITE_LABEL_PROBES {"PASS" if passed == total else "FAIL"} {passed}/{total} strict red', flush=True)
    from probe_gate_empty_schema import run_probes as empty_schema_probes
    empty_schema = empty_schema_probes()
    print(f'FINITE_ACCEPTANCE {"PASS" if passed == total and empty_schema else "INCOMPLETE"} label_probes={passed}/{total} empty_schema_sites={2 if empty_schema else 0}/2 errors_accepted=0', flush=True)
    return int(passed != total or not empty_schema)


if __name__ == '__main__':
    raise SystemExit(main())
