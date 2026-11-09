#!/usr/bin/env python3
"""Bounded foreground paired probes; only temporary copies lose gates."""
import ast
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from probe_gate_dsr2 import ROOT, delete, strict
from gate_assertions import assertion_mentions
from test_gate_dsr2_rpc import CASES

OUT = Path('/tmp/commit6e-dsr2-rpc')


def run(tree, row, mode):
    p = subprocess.run([sys.executable, '-B', '-m', 'unittest',
        'test_gate_dsr2_rpc.RpcShadowTests.test_' + mode + '_' + row['gate']],
        cwd=tree/'script/upgrade', capture_output=True, text=True, timeout=120)
    return p.returncode, p.stdout + p.stderr


def typed_delete(tree, row, line=None):
    assert tree.resolve() != ROOT.resolve()
    path = tree/'script/upgrade/manifest_exec.py'
    source = path.read_text()
    nodes = [n for n in ast.walk(ast.parse(source)) if isinstance(n, ast.Expr)
             and n.lineno == (line or row['line']) and isinstance(n.value, ast.Call)
             and ast.unparse(n.value.func) == 'a.typed']
    assert len(nodes) == 1, f'{row["gate"]}: source sites={len(nodes)}'
    n = nodes[0]
    lines = source.splitlines(keepends=True)
    assert n.lineno == n.end_lineno
    original = lines[n.lineno-1]
    lines[n.lineno-1] = original[:n.col_offset] + 'pass' + original[n.end_col_offset:]
    path.write_text(''.join(lines))
    return len(nodes)


def main():
    OUT.mkdir(exist_ok=True)
    report = []
    for row in CASES:
        logs, codes = {}, {}
        def check(tree, key, mode):
            codes[key], logs[key] = run(tree, row, mode)
            return codes[key]
        gate = row['gate']
        passed, method, reason, observation = False, 'paired', '', ''
        sites = 0
        try:
            check(ROOT, 'shadow', 'shadow')
            with tempfile.TemporaryDirectory(prefix='commit6e-dsr2-rpc-') as tmp:
                tree = Path(tmp)
                shutil.copytree(ROOT/'script', tree/'script', ignore=shutil.ignore_patterns('__pycache__'))
                delete(tree, 'manifest_exec.py', row['e_line'])
                if 'second' in row:
                    method = 'three-level'
                    check(tree, 'second', 'second')
                    observation = (f'DSR2_RPC_SECOND {gate} delete_only={row["earlier"]} '
                                   f'exact_stop={row["second"][0]} baseline={"green" if codes["second"] == 0 else "RED"} '
                                   f'failures={logs["second"].count("FAIL:")} errors={logs["second"].count("ERROR:")}')
                    typed_delete(tree, row, row['second'][1])
                check(tree, 'target', 'target')
                if codes['target'] == 0:
                    check(tree, 's1', 'shadow')
                    sites = typed_delete(tree, row)
                    check(tree, 's2', 'target')
                    passed = (codes['shadow'] == codes.get('second', 0) == 0
                              and sites == 1 and strict(codes['s1'], logs['s1'], gate)
                              and strict(codes['s2'], logs['s2'], gate))
                    if not passed:
                        reason = 'strict criterion failed; see stage logs'
                else:
                    method = 'blocked-error' if 'ERROR:' in logs['target'] else 'dead-code-candidate'
                    reason = '\n'.join(x for x in logs['target'].splitlines()
                                       if x.startswith(('AssertionError:', 'FAILED', 'ERROR:', 'FAIL:', 'ValueError:', 'RuntimeError:')))
                    # Never delete T when T has not fired.
        except Exception as exc:
            reason = f'{type(exc).__name__}: {exc}'
            method = 'blocked-runner'
        final = (f'DSR2_RPC {gate} {"PASS" if passed else "BLOCKED"} method={method} source_sites={sites} '
                 f'baseline={"green" if codes.get("target") == 0 else "RED"} '
                 f'shadow={"exact_E" if codes.get("shadow") == 0 else "RED"} '
                 f's1_failures={logs.get("s1", "").count("FAIL:")} s1_errors={logs.get("s1", "").count("ERROR:")} '
                 f's1_named={assertion_mentions(logs.get("s1", ""), gate)} '
                 f'failures={logs.get("s2", "").count("FAIL:")} errors={logs.get("s2", "").count("ERROR:")} '
                 f'named={assertion_mentions(logs.get("s2", ""), gate)}')
        result = dict(gate=gate, earlier=row['earlier'], second=row.get('second'), method=method,
                      passed=passed, observation=observation, final=final, reason=reason, logs=logs)
        report.append(result)
        (OUT/'probes.json').write_text(json.dumps(report, indent=2)+'\n')
        print('\n'.join(filter(None, [observation, final, reason])), flush=True)
    aggregate = (f'DSR2_RPC_AGGREGATE scope=manifest_exec.py:{",".join(str(r["line"]) for r in CASES)} '
                 f'processed={len(report)} accepted={sum(r["passed"] for r in report)} '
                 f'blocked={sum(not r["passed"] for r in report)} errors_accepted=0')
    print(aggregate, flush=True)
    (OUT/'aggregate.txt').write_text(aggregate+'\n')


if __name__ == '__main__':
    main()
