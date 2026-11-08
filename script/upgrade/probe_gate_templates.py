#!/usr/bin/env python3
"""Focused deletion probes for the finite dynamic templates added in 6e."""
import ast
import json
from gate_assertions import assertion_mentions
from pathlib import Path
import probe_phase_c_gates as driver
import test_gate_template_controls as tests
from gate_rename_ast_diff import ROOT, gate_sites
from gate_probe_trace import baseline_trace


def finite_label_probes(cases=None):
    cases = tests.CASES if cases is None else cases
    registry = json.loads((ROOT / 'script/upgrade/gate_templates.json').read_text())
    trees = {file: list(gate_sites(ast.parse((ROOT / file).read_text()))) for file in {row['file'] for row in registry}}
    passed = 0
    for cls, name, gate, line in cases:
        rows = [row for row in registry if row['line'] == line and any(p['gate'] == gate for p in row['probes'].values())]
        if len(rows) != 1:
            print(f'GATE_TEMPLATE_CONTROL {gate} FAIL ambiguous registry sites={len(rows)}')
            continue
        path = (ROOT / rows[0]['file']).resolve()
        sites = trees[rows[0]['file']]
        matches = {id(call) for _, call, value in sites if call.lineno == line}
        green, baseline, traces = baseline_trace(cls, name)
        # Require one definition and a recorded caller-to-primitive path, then
        # delete only the failing primitive statement (including suffix guards).
        recorded = driver.SITES.get((cls, name, gate), set())
        trace = traces.get(gate, set())
        if len(matches) == 1 and len(recorded) == 1 and (str(path), line) in trace:
            accepted, reached, mutant = driver.run(cls, name, gate) if green else (True, False, '')
        else:
            accepted, reached, mutant = True, False, ''
        good = green and reached and not accepted
        passed += good
        print(baseline + mutant, end='')
        print(f'GATE_TEMPLATE_CONTROL {gate} {"PASS" if good else "FAIL"} '
              f'baseline={"green" if green else "RED"} source_sites={len(matches)} '
              f'failures={mutant.count("FAIL:")} errors={mutant.count("ERROR:")} named={assertion_mentions(mutant, gate)}')
    print(f'GATE_TEMPLATE_PROBES {"PASS" if passed == len(cases) else "FAIL"} {passed}/{len(cases)} strict red')
    return passed == len(cases)


if __name__ == '__main__':
    raise SystemExit(not finite_label_probes())
