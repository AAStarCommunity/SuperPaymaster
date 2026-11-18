"""Re-run the PR-2 review's mutations against test_gate_name_hygiene.py, on copies of the tree.

Usage: python3 script/upgrade/probe_gate_name_hygiene_mutants.py <worktree>

The probe is the evidence that the hygiene tests catch these mutations, so it fails loudly when it
fails itself. It exits non-zero unless all of the following hold:
- the unmutated copy passes the whole suite;
- every mutation changes the text (old != new, exactly one occurrence);
- every mutant run reports its named test as a FAIL (an assertion failure) and no ERROR anywhere.
An ERROR (an import failure, a missing engine) is never counted as caught.
"""
import json
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

WT = Path(sys.argv[1]).resolve()
SUITE = 'script/upgrade/test_gate_name_hygiene.py'
# (label, file, old, new, the test that must FAIL)
M = [
    ('readback_value_ -> readback_value_fraudProofVerifier()_WRONG_', 'script/upgrade/manifest_exec.py',
     "a.need('readback_value_'+p.get", "a.need('readback_value_fraudProofVerifier()_WRONG_'+p.get",
     'test_consumed_gate_names_are_exactly_producible'),
    ('rename only the C_price_bound_exec producer', 'script/upgrade/manifest_exec.py',
     "a.need('C_price_bound_exec', 0 <", "a.need('C_price_bound_execX', 0 <",
     'test_consumed_gate_names_are_exactly_producible'),
    ('add another occurrence of frozen chain', 'script/upgrade/manifest_exec.py',
     "\ndef ", "\ndef _mut():\n    a.need('chain', 1, 2)\n\n\ndef ", 'test_no_new_repeated_gate_name'),
    ('restore old C_price_bound in runtime', 'script/upgrade/manifest_exec.py',
     "a.need('C_price_bound_exec', 0 <", "a.need('C_price_bound', 0 <", 'test_replaced_names_have_no_literal_left'),
    ('add old C_price_bound to a test file', 'script/upgrade/test_manifest_exec.py',
     "\nimport ", "\n_OLD = 'C_price_bound'\nimport ", 'test_replaced_names_have_no_literal_left'),
    ('old-name consumer outside the five former runtime files', 'script/upgrade/local_phase_c_comparators.py',
     "\nimport ", "\ndef _mut(e):\n    return e.record['gate'] == 'verifier_commit'\n\n\nimport ",
     'test_replaced_names_have_no_literal_left'),
    ('replace one frozen rename row', 'script/upgrade/gate_renames_pr2.json', None, None,
     'test_frozen_records_are_pinned'),
]


def run_suite(tmp):
    r = subprocess.run([sys.executable, '-B', str(Path(tmp)/SUITE)], capture_output=True, text=True)
    lines = r.stderr.splitlines()
    fails = {m.group(1) for l in lines for m in [re.match(r'FAIL: (\w+)', l)] if m}
    errors = [l for l in lines if l.startswith('ERROR:')]
    return r.returncode, fails, errors, (lines[-1] if lines else '')


def copy_tree(tmp):
    for d in ('script', '.github'):
        shutil.copytree(WT/d, Path(tmp)/d, ignore=shutil.ignore_patterns('__pycache__'))
    # generate_replaced() archives the base commit with git: give the copy the repository.
    subprocess.run(['git', 'init', '-q', tmp], check=True)
    subprocess.run(['git', '-C', tmp, 'fetch', '-q', '--depth=1', str(WT), 'HEAD'], check=True)
    base = json.loads((WT/'script/upgrade/gate_names_replaced_pr2.json').read_text())['base']
    subprocess.run(['git', '-C', tmp, 'fetch', '-q', str(WT), base], check=True)


failures = []
with tempfile.TemporaryDirectory() as tmp:
    copy_tree(tmp)
    rc, fails, errors, tail = run_suite(tmp)
    print(f'baseline | rc={rc} | {tail} | fails={sorted(fails)} errors={errors}')
    if rc != 0 or fails or errors:
        print('HYGIENE_MUTANTS FAIL: the unmutated suite is not green')
        sys.exit(1)

red = 0
for label, path, old, new, expected in M:
    with tempfile.TemporaryDirectory() as tmp:
        copy_tree(tmp)
        f = Path(tmp)/path
        text = f.read_text()
        if old is None:
            d = json.loads(text)
            d['renamed'][0] = dict(d['renamed'][0], name='chain_x')
            mutated = json.dumps(d, indent=1)+'\n'
        else:
            if old == new or text.count(old) < 1:
                print(f'NOT APPLIED | {label}'); failures.append(label); continue
            mutated = text.replace(old, new, 1)
        if mutated == text:
            print(f'NOT APPLIED | {label}'); failures.append(label); continue
        f.write_text(mutated)
        rc, fails, errors, tail = run_suite(tmp)
        caught = rc != 0 and expected in fails and not errors
        red += caught
        if not caught:
            failures.append(label)
        print(f"{'RED' if caught else 'NOT CAUGHT'} | {label} | expected {expected} | fails={sorted(fails)} "
              f"errors={len(errors)} | {tail}")
print(f'HYGIENE_MUTANTS {red}/{len(M)} red' + (f'; not caught: {failures}' if failures else ''))
sys.exit(0 if red == len(M) and not failures else 1)
