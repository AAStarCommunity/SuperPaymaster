#!/usr/bin/env python3
"""Only two synthetic-site deletions and two schema tripwire mutations, in copies."""
import ast
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from gate_assertions import assertion_mentions
from test_gate_empty_schema import CASES

ROOT = Path(__file__).resolve().parents[2]


def run(tree, method):
    result = subprocess.run([sys.executable, '-B', '-m', 'unittest',
                             'test_gate_empty_schema.EmptySchemaTests.' + method],
                            cwd=tree / 'script/upgrade', capture_output=True, text=True)
    return result.returncode, result.stdout + result.stderr


def run_probes():
    results = []
    for line, kind, gate in CASES:
        for tripwire in (False, True):
            name = 'schema_tripwire_' + kind if tripwire else gate
            method = 'test_' + ('tripwire_' if tripwire else '') + kind
            with tempfile.TemporaryDirectory(prefix='commit6e-empty-') as directory:
                tree = Path(directory)
                shutil.copytree(ROOT / 'script', tree / 'script', ignore=shutil.ignore_patterns('__pycache__'))
                code, baseline = run(tree, method)
                path = tree / 'script/upgrade' / ('fraud-proof-fixture.schema.json' if tripwire else 'manifest_exec.py')
                if tripwire:
                    schema = json.loads(path.read_text())
                    schema['minProperties' if kind == 'min_properties' else 'enum'] = 1 if kind == 'min_properties' else [{}]
                    path.write_text(json.dumps(schema))
                    sites = 1
                else:
                    source = path.read_text()
                    parsed = ast.parse(source)
                    nodes = [n for n in ast.walk(parsed) if isinstance(n, ast.Expr) and n.lineno == line
                             and isinstance(n.value, ast.Call) and isinstance(n.value.func, ast.Attribute)
                             and n.value.func.attr == 'need'
                             and ast.unparse(n.value.args[0]) == ("'fraud_schema_properties_' + path" if kind == 'min_properties' else "'fraud_schema_enum_' + path")]
                    sites = len(nodes)
                    if sites == 1:
                        lines = source.splitlines(keepends=True)
                        node = nodes[0]
                        lines[node.lineno - 1:node.end_lineno] = [' ' * node.col_offset + 'pass\n']
                        path.write_text(''.join(lines))
                mutant_code, mutant = run(tree, method)
            failures, errors = mutant.count('FAIL:'), mutant.count('ERROR:')
            named = assertion_mentions(mutant, name)
            good = code == 0 and mutant_code != 0 and sites == 1 and failures >= 1 and errors == 0 and named
            final = (f'EMPTY_SCHEMA_{"TRIPWIRE" if tripwire else "PROBE"} {name} {"PASS" if good else "BLOCKED"} '
                     f'source_sites={sites} baseline={"green" if code == 0 else "RED"} failures={failures} errors={errors} named={named}')
            print(baseline + mutant + final, flush=True)
            results.append(dict(line=line, tripwire=tripwire, passed=good, final=final))
    resolved = all(row['passed'] for row in results)
    registry = json.loads((ROOT / 'script/upgrade/gate_templates.json').read_text())
    labels = sum(len(row['labels']) for row in registry if row['file'].endswith('manifest_exec.py') and row['line'] == 389)
    print(f'EMPTY_SCHEMA_ACCEPTANCE {"PASS" if resolved else "INCOMPLETE"} sites=2 controls={sum(r["passed"] for r in results)}/4 resolved_labels={labels if resolved else 0} blocked_labels={0 if resolved else labels} empty_enum_sites_resolved={int(resolved)} errors_accepted=0', flush=True)
    return resolved


if __name__ == '__main__':
    raise SystemExit(not run_probes())
