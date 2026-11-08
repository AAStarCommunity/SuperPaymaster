#!/usr/bin/env python3
"""Eighteen bounded, foreground DSR2 probes; mutations exist only in temp copies."""
import ast
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from gate_assertions import assertion_mentions
from test_gate_dsr2 import CASES, SECOND

ROOT = Path(__file__).resolve().parents[2]
EARLIER = {
    'fraud_token_pinned_runtime': ('manifest_exec.py', 487),
    'evidence_dvt-ci_hash': ('manifest_exec.py', 78),
    'verifier_build_identity': ('manifest_exec.py', 625),
    'fixed_anni': ('manifest_exec.py', 631),
    'fixed_dvt': ('manifest_exec.py', 637),
    'fixed_committee': ('manifest_exec.py', 638),
    'sender': ('sp_upgrade_exec.py', 734),
    'sender_identity': ('sp_upgrade_exec.py', 735),
    'a3a_sender_history': ('manifest_exec.py', 1822),
    'drain_inventory': ('manifest_exec.py', 2143),
    'old_owner_role_init_ids': ('old_owner_isolation.py', 344),
}


def run(tree, row, mode):
    result = subprocess.run([sys.executable, '-B', '-m', 'unittest',
        'test_gate_dsr2.' + row['class'] + '.test_' + mode + '_' + row['gate']],
        cwd=tree/'script/upgrade', capture_output=True, text=True, timeout=120)
    return result.returncode, result.stdout + result.stderr


def delete(tree, filename, line):
    assert tree != ROOT
    path = tree/'script/upgrade'/filename
    source = path.read_text()
    matches = [n for n in ast.walk(ast.parse(source)) if isinstance(n, ast.Expr) and n.lineno == line
               and isinstance(n.value, ast.Call) and isinstance(n.value.func, ast.Attribute)
               and n.value.func.attr in ('need', 'exact_keys')]
    if len(matches) != 1:
        raise AssertionError(f'{filename}:{line}: expected 1 source site, got {len(matches)}')
    n = matches[0]
    lines = source.splitlines(keepends=True)
    # Preserve line numbers for the subsequent target deletion.
    if n.lineno == n.end_lineno:
        original = lines[n.lineno-1]
        lines[n.lineno-1] = original[:n.col_offset] + 'pass' + original[n.end_col_offset:]
    else:
        lines[n.lineno-1:n.end_lineno] = [' '*n.col_offset+'pass\n'] + ['\n']*(n.end_lineno-n.lineno)
    path.write_text(''.join(lines))
    return len(matches)


def main(senders_only=False):
    report = []
    for row in CASES:
        gate = row['gate']
        if senders_only and row['earlier'] != 'sender_identity':
            continue
        code, shadow = run(ROOT, row, 'shadow')
        logs = dict(shadow=shadow)
        with tempfile.TemporaryDirectory(prefix='commit6e-dsr2-') as tmp:
            tree = Path(tmp)
            shutil.copytree(ROOT/'script', tree/'script', ignore=shutil.ignore_patterns('__pycache__'))
            esites = delete(tree, *EARLIER[row['earlier']])
            b1code, b1 = run(tree, row, 'target')
            logs['b1'] = b1
            # A green exact-Gate assertion proves the bad input FAILed at T.
            if b1code == 0 and code == 0:
                b1redcode, b1red = run(tree, row, 'shadow')
                logs['b1_red'] = b1red
                b1strict = (b1redcode != 0 and b1red.count('FAIL:') >= 1
                            and b1red.count('ERROR:') == 0 and assertion_mentions(b1red, gate))
                sites = delete(tree, row['file'], row['line'])
                b2code, b2 = run(tree, row, 'target')
                logs['b2'] = b2
                failures, errors = b2.count('FAIL:'), b2.count('ERROR:')
                named = assertion_mentions(b2, gate)
                passed = b1strict and sites == 1 and b2code != 0 and failures >= 1 and errors == 0 and named
                method = 'b'
                final = (f'DSR2_PAIR {gate} {"PASS" if passed else "BLOCKED"} E={row["earlier"]} '
                         f'source_sites={sites} E_sites={esites} baseline=green b1=exact_T b3=exact_E '
                         f'b1_failures={b1red.count("FAIL:")} b1_errors={b1red.count("ERROR:")} '
                         f'b1_named={assertion_mentions(b1red, gate)} failures={failures} errors={errors} named={named}')
            else:
                passed = False
                method = 'chain' if "AssertionError:" in b1 and 'Gate not raised' not in b1 else 'c'
                if 'ERROR:' in b1:
                    method = 'blocked-error'
                final = (f'DSR2_PAIR {gate} BLOCKED E={row["earlier"]} method={method} '
                         f'E_sites={esites} shadow={"green" if code == 0 else "RED"} '
                         f'b1_failures={b1.count("FAIL:")} b1_errors={b1.count("ERROR:")} T_reached=False')
        print('\n'.join(logs.values()) + final, flush=True)
        report.append(dict(gate=gate, earlier=row['earlier'], method=method, passed=passed, final=final, logs=logs))
    out = Path('/tmp/commit6e-dsr2')
    out.mkdir(exist_ok=True)
    (out/('senders.json' if senders_only else 'probes.json')).write_text(json.dumps(report, indent=2)+'\n')
    if senders_only:
        print(f'DSR2_AGGREGATE accepted={15 + sum(r["passed"] for r in report)}/18 preserved_accepted=15 rerun={len(report)} blocked={sum(not r["passed"] for r in report)} errors_accepted=0', flush=True)
        return
    print(f'DSR2_PROBES COMPLETE accepted={sum(r["passed"] for r in report)}/18 blocked={sum(not r["passed"] for r in report)} errors_accepted=0', flush=True)


def strict(code, log, gate):
    return code != 0 and log.count('FAIL:') >= 1 and log.count('ERROR:') == 0 and assertion_mentions(log, gate)


def remaining():
    report = []
    for row in CASES:
        gate = row['gate']
        if gate not in SECOND:
            continue
        logs = {}
        shadow_code, logs['shadow'] = run(ROOT, row, 'shadow')
        with tempfile.TemporaryDirectory(prefix='commit6e-dsr2-final-') as tmp:
            tree = Path(tmp)
            shutil.copytree(ROOT/'script', tree/'script', ignore=shutil.ignore_patterns('__pycache__'))
            e_sites = delete(tree, *EARLIER[row['earlier']])
            second_code, logs['second'] = run(tree, row, 'second')
            observation = (f'DSR2_SECOND {gate} {"PASS" if second_code == 0 else "BLOCKED"} '
                           f'delete_only={row["earlier"]} exact_stop={SECOND[gate][0]}')
            print(observation, flush=True)
            # Sender ruling requires U:735 deletion; the new accessor remains intact.
            second_site = ('sp_upgrade_exec.py', 735) if gate.startswith('sender_') else SECOND[gate][1:]
            second_sites = delete(tree, *second_site)
            target_code, logs['target'] = run(tree, row, 'target')
            s1code, logs['s1'] = run(tree, row, 'shadow')
            sites = delete(tree, row['file'], row['line'])
            s2code, logs['s2'] = run(tree, row, 'target')
            passed = (shadow_code == second_code == target_code == 0 and e_sites == second_sites == sites == 1
                      and strict(s1code, logs['s1'], gate) and strict(s2code, logs['s2'], gate))
            method = 'three-level' if not gate.startswith('sender_') else 'dead-code-candidate'
            final = (f'DSR2_FINAL {gate} {"PASS" if passed else "BLOCKED"} method={method} '
                     f'source_sites={sites} E_sites={e_sites} second_sites={second_sites} '
                     f'baseline={"green" if target_code == 0 else "RED"} shadow={"exact_E" if shadow_code == 0 else "RED"} '
                     f's1_failures={logs["s1"].count("FAIL:")} s1_errors={logs["s1"].count("ERROR:")} '
                     f's1_named={assertion_mentions(logs["s1"], gate)} '
                     f'failures={logs["s2"].count("FAIL:")} errors={logs["s2"].count("ERROR:")} '
                     f'named={assertion_mentions(logs["s2"], gate)}')
            print(''.join(logs.values()) + final, flush=True)
            report.append(dict(gate=gate, passed=passed, method=method, observation=observation, final=final, logs=logs))
    out = Path('/tmp/commit6e-dsr2')
    out.mkdir(exist_ok=True)
    (out/'remaining.json').write_text(json.dumps(report, indent=2)+'\n')
    print(f'DSR2_REMAINING COMPLETE processed={len(report)} accepted={sum(r["passed"] for r in report)} '
          f'blocked={sum(not r["passed"] for r in report)} preserved_accepted=12 errors_accepted=0', flush=True)


if __name__ == '__main__':
    remaining() if '--remaining' in sys.argv else main(senders_only='--senders' in sys.argv)
