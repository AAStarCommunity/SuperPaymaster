#!/usr/bin/env python3
"""Foreground, per-site strict deletion controls; never runs the batch driver."""
import ast
import io
import json
from pathlib import Path
import unittest
from gate_assertions import assertion_mentions
from gate_rename_ast_diff import ROOT, gate_sites
import test_gate_r_controls as tests


def run_case(cls, name):
    stream = io.StringIO()
    result = unittest.TextTestRunner(stream=stream).run(unittest.TestSuite([cls(name)]))
    return result, stream.getvalue()


def run_probes(cases=None):
    if cases is None:
        import test_gate_extra_finite
        cases = tests.CASES + test_gate_extra_finite.CASES
    from gate_probe_bindings import reconcile
    registry = json.loads((ROOT / 'script/upgrade/gate_templates.json').read_text()) + json.loads((ROOT / 'script/upgrade/gate_open_templates.json').read_text())
    executed = []
    passed = 0
    for cls, name, gate, line in cases:
        filename = 'old_owner_isolation.py' if gate.startswith('old_owner_') else 'manifest_exec.py'
        module = tests.fixture.isolation_tests.o if filename.startswith('old_') else tests.m
        path = Path(module.__file__)
        executed.append((str(path.relative_to(ROOT)), line, gate, cls, name))
        tree = ast.parse(path.read_text())
        definitions = [c for _,c,v in gate_sites(tree, expand=True) if c.lineno == line
                       and not (isinstance(v, ast.Constant) and v.value != gate)]
        expressions = [n for n in ast.walk(tree) if isinstance(n,ast.Expr)
                       and any(n.value is call for call in definitions)]
        baseline, baseline_log = run_case(cls, name)
        result, log = None, ''
        if baseline.wasSuccessful() and len(definitions) == 1 and len(expressions) == 1:
            class Delete(ast.NodeTransformer):
                def visit_Expr(self, node):
                    return ast.copy_location(ast.Pass(),node) if node is expressions[0] else self.generic_visit(node)
            saved = module.__dict__.copy()
            try:
                exec(compile(ast.fix_missing_locations(Delete().visit(tree)),str(path),'exec'),module.__dict__)
                result,log = run_case(cls,name)
            finally:
                module.__dict__.clear(); module.__dict__.update(saved)
        failures = len(result.failures) if result else 0
        errors = len(result.errors) if result else len(baseline.errors)
        named = bool(result and any(assertion_mentions(message,gate) for _,message in result.failures))
        good = baseline.wasSuccessful() and len(definitions)==1 and failures>=1 and errors==0 and named
        passed += good
        print(baseline_log + log, end='')
        print(f'R_SITE_PROBE {gate} {"PASS" if good else "BLOCKED"} source_sites={len(definitions)} baseline={"green" if baseline.wasSuccessful() else "RED"} failures={failures} errors={errors} named={named}',flush=True)
    binding_ok = True
    try:
        reconcile(registry, executed)
    except AssertionError as error:
        binding_ok = False
        print('R_SITE_BINDINGS FAIL ' + str(error), flush=True)
    print(f'R_SITE_PROBES {"PASS" if binding_ok and passed==len(cases) else "FAIL"} passed={passed} total={len(cases)} blocked={len(cases)-passed} errors_accepted=0',flush=True)
    return binding_ok and passed==len(cases)


def prefix_probe():
    import test_gate_names as names
    source=Path(names.__file__).read_text();tree=ast.parse(source)
    sites=[n for n in ast.walk(tree) if isinstance(n,ast.Raise) and 'gate_prefix_disjointness:' in ast.get_source_segment(source,n)]
    baseline,_=run_case(names.GateNameTests,'test_prefix_counterexamples_rejected')
    class Delete(ast.NodeTransformer):
        def visit_Raise(self,node):
            return ast.copy_location(ast.Pass(),node) if node in sites else self.generic_visit(node)
    saved=names.__dict__.copy()
    try:
        exec(compile(ast.fix_missing_locations(Delete().visit(tree)),names.__file__,'exec'),names.__dict__)
        result,log=run_case(names.GateNameTests,'test_prefix_counterexamples_rejected')
    finally:
        names.__dict__.clear();names.__dict__.update(saved)
    named=any(assertion_mentions(message,'gate_prefix_disjointness') for _,message in result.failures)
    good=len(sites)==1 and baseline.wasSuccessful() and len(result.failures)>=1 and not result.errors and named
    print(log,end='')
    print(f'GATE_PREFIX_PROBE {"PASS" if good else "FAIL"} source_sites={len(sites)} baseline={"green" if baseline.wasSuccessful() else "RED"} failures={len(result.failures)} errors={len(result.errors)} named={named}',flush=True)
    return good


if __name__=='__main__':
    prefix = prefix_probe()
    controls = run_probes()
    from probe_gate_empty_schema import run_probes as empty_schema_probes
    empty_schema = empty_schema_probes()
    raise SystemExit(not(prefix and controls and empty_schema))
