"""Re-run the PR-2 review's surviving mutations against test_gate_name_hygiene.py, on copies.

Usage: python3 script/upgrade/probe_gate_name_hygiene_mutants.py <worktree>. Every row must print RED.
"""
import json, shutil, subprocess, sys, tempfile
from pathlib import Path
WT = Path(sys.argv[1])
M = [
 ('readback_value_ -> readback_value_fraudProofVerifier()_WRONG_', 'script/upgrade/manifest_exec.py',
  "a.need('readback_value_'+p.get", "a.need('readback_value_fraudProofVerifier()_WRONG_'+p.get"),
 ('rename only the C_price_bound_exec producer', 'script/upgrade/manifest_exec.py',
  "a.need('C_price_bound_exec', 0 <", "a.need('C_price_bound_execX', 0 <"),
 ('add another occurrence of frozen chain', 'script/upgrade/manifest_exec.py',
  "def ", "def _mut():\n    a.need('chain', 1, 2)\n\n\ndef "),
 ('restore old C_price_bound in runtime', 'script/upgrade/manifest_exec.py',
  "a.need('C_price_bound_exec', 0 <", "a.need('C_price_bound', 0 <"),
 ('add old C_price_bound to a test file', 'script/upgrade/test_manifest_exec.py',
  "import ", "_OLD = 'C_price_bound'\nimport "),
 ('old-name consumer outside the five former runtime files', 'script/upgrade/local_phase_c_comparators.py',
  "import ", "def _mut(e):\n    return e.record['gate'] == 'verifier_commit'\n\n\nimport "),
 ('fabricated frozen rename row', 'script/upgrade/gate_renames_pr2.json', None, None),
]
red = 0
for label, path, old, new in M:
    with tempfile.TemporaryDirectory() as tmp:
        for d in ('script', '.github'):
            shutil.copytree(WT/d, Path(tmp)/d, ignore=shutil.ignore_patterns('__pycache__'))
        f = Path(tmp)/path; text = f.read_text()
        if old is None:
            d = json.loads(text); d['renamed'].append(dict(name='chain_x', file='script/upgrade/manifest_exec.py', functions=['run'], previous=['chain']))
            f.write_text(json.dumps(d))
        else:
            assert old in text, label
            f.write_text(text.replace(old, new, 1))
        r = subprocess.run([sys.executable, '-B', str(Path(tmp)/'script/upgrade/test_gate_name_hygiene.py')], capture_output=True, text=True)
        tail = r.stderr.strip().splitlines()
        failed = [l for l in tail if l.startswith(('FAIL:', 'ERROR:'))]
        red += bool(r.returncode and failed)
        print(f"{'RED' if r.returncode and failed else 'GREEN(survived)'} | {label} | {tail[-1]} | {'; '.join(failed)}")
print(f'HYGIENE_MUTANTS {red}/{len(M)} red')
sys.exit(0 if red == len(M) else 1)
