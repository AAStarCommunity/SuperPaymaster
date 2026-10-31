"""List tests whose outcome differs between the current tuple (full-<engine>-0.log) and the
candidate tuple (full-<engine>-1.log) in a tuple-validation run directory.

Usage: python3 script/evidence/tuple-validation-outcomes.py <run-dir> > outcome-changes.tsv
Fails if any of the six full-suite logs is missing or has no test summary.
"""
import pathlib, re, sys

run = pathlib.Path(sys.argv[1])


def outcomes(path):
    text = path.read_text(errors='replace')
    assert re.search(r'\d+ tests passed, \d+ failed, \d+ skipped', text), f'{path.name}: no test summary'
    out, suite = {}, None
    for line in text.splitlines():
        if line.startswith('Failing tests:'):
            break  # the trailing summary repeats FAIL lines without their suite header
        m = re.match(r'Ran \d+ tests? for (\S+)', line)
        if m:
            suite = m.group(1)
        m = re.match(r'\[(PASS|FAIL)[^\]]*\]\s+(\w+\([^)]*\))', line)
        if m:
            out[f'{suite}::{m.group(2)}'] = m.group(1)
    return out


print('engine\ttest\tcurrent\tcandidate')
for engine in ['cancun', 'prague', 'amsterdam']:
    cur = outcomes(run / f'full-{engine}-0.log')
    cand = outcomes(run / f'full-{engine}-1.log')
    for test in sorted(set(cur) | set(cand)):
        a, b = cur.get(test, 'ABSENT'), cand.get(test, 'ABSENT')
        if a != b:
            print(f'{engine}\t{test}\t{a}\t{b}')
