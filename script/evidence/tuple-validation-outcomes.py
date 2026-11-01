"""Compare completed, suite-qualified Forge outcomes without running Forge."""
import pathlib
import re
import sys


def parse(log, label='log'):
    out, suite, active, trailer = {}, None, False, False
    suite_results = {}
    aggregate = None
    declared = 0
    for line in log.splitlines():
        header = re.match(r'Ran (\d+) tests? for (\S+)', line)
        if header:
            assert not active, f'{label}: incomplete suite {suite}'
            declared, suite = int(header[1]), header[2]
            assert suite not in suite_results, f'{label}: repeated suite {suite}'
            active, trailer, aggregate = True, False, None
            current = {}
            continue
        if line.startswith('Failing tests:'):
            trailer = True
        if trailer:
            continue
        result = re.match(r'^\[(PASS|FAIL|SKIP)(?::.*?)?\]\s+(\w+\([^)]*\))(?:\s|$)', line)
        group = re.fullmatch(r'\[(PASS|FAIL|SKIP)\]', line)
        if result or group:
            assert active, f'{label}: result outside suite'
            status = (result or group)[1]
            name = result[2] if result else '<invariant-group>'
            key = f'{suite}::{name}'
            assert key not in out, f'{label}: duplicate key {key}'
            out[key] = current[key] = status
        completion = re.match(r'Suite result: .*? (\d+) passed; (\d+) failed; (\d+) skipped;', line)
        if completion:
            assert active, f'{label}: completion without suite'
            counts = tuple(sum(v == s for v in current.values()) for s in ('PASS', 'FAIL', 'SKIP'))
            assert counts == tuple(map(int, completion.groups())), f'{label}: suite counts mismatch {suite}'
            assert len(current) == declared, f'{label}: declared count mismatch {suite}'
            suite_results[suite] = set(current)
            active = False
        total = re.match(r'Ran (\d+) test suites? .*?: (\d+) tests? passed, (\d+) failed, (\d+) skipped', line)
        if total:
            assert not active, f'{label}: incomplete suite {suite}'
            assert int(total[1]) == len(suite_results), f'{label}: suite total mismatch'
            aggregate = tuple(map(int, total.groups()[1:]))
            assert aggregate == tuple(sum(v == s for v in out.values()) for s in ('PASS', 'FAIL', 'SKIP')), f'{label}: aggregate mismatch'
    assert not active, f'{label}: incomplete suite {suite}'
    assert aggregate is not None and out, f'{label}: missing final aggregate'
    return out


def outcomes(path):
    return parse(path.read_text(errors='replace'), path.name)


def changes(run):
    for engine in ('cancun', 'prague', 'amsterdam'):
        cur = outcomes(run / f'full-{engine}-0.log')
        cand = outcomes(run / f'full-{engine}-1.log')
        for test in sorted(set(cur) | set(cand)):
            a, b = cur.get(test, 'ABSENT'), cand.get(test, 'ABSENT')
            if a != b:
                yield f'{engine}\t{test}\t{a}\t{b}'


if __name__ == '__main__':
    rows = list(changes(pathlib.Path(sys.argv[1])))
    print('engine\ttest\tcurrent\tcandidate')
    print('\n'.join(rows))
