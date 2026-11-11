"""Count declared functions with execution evidence, not Forge's skipped counter."""
import argparse
import json
import re
import sys
from pathlib import Path

SUITE = re.compile(r'^Ran \d+ tests? for (.+):([^:]+)$')
RESULT = re.compile(r'^\[(PASS|FAIL|SKIP)(.*?)\]\s+(\w+\([^)]*\))')


def inventory(declared, logs, engine, allow=()):
    names = set()
    for path, contracts in declared.items():
        for contract, tests in contracts.items():
            if not isinstance(tests, list) or not all(isinstance(t, str) for t in tests):
                raise ValueError('expected path -> contract -> list of test signatures')
            names.update((path, contract, t) for t in tests)
    executed, failed, skips, setups = set(), set(), {}, {}
    patterns = [re.compile(p) for p in allow]
    setup_failures = set()
    for log in logs:
        suite = None
        for line in log.splitlines():
            line = line.strip()
            if line == 'Failing tests:':
                break
            header = SUITE.match(line)
            if header:
                suite = header.groups()
                continue
            result = RESULT.match(line)
            if not result:
                continue
            if suite is None:
                raise ValueError('test result without suite header')
            status, message, test = result.groups()
            reason = message.lstrip(': ').strip() or status
            key = (*suite, test)
            if test == 'setUp()' and status in ('SKIP', 'FAIL'):
                if not any(n[:2] == suite for n in names):
                    raise ValueError(f'unknown suite: {suite}')
                setups[suite] = reason
                if status == 'FAIL':
                    setup_failures.add(':'.join(suite))
                continue
            if key not in names and (*suite, test.split('(')[0]) in names:
                key = (*suite, test.split('(')[0])
            if key not in names:
                raise ValueError(f'unknown test: {key}')
            if status in ('PASS', 'FAIL'):
                executed.add(key)
                if status == 'FAIL':
                    failed.add(key)
            else:
                skips[key] = reason
    missing = []
    for path, contract, test in sorted(names - executed):
        reason = skips.get((path, contract, test), setups.get((path, contract), 'no execution record'))
        allowed = any(p.search(reason) for p in patterns)
        missing.append(dict(function=f'{path}:{contract}.{test}', reason=reason,
                            status='allowed (design)' if allowed else 'unexecuted'))
    allowed = sum(row['status'] == 'allowed (design)' for row in missing)
    report = dict(engine=engine, declared=len(names), executed=len(executed), failed=len(failed),
                  allowed=allowed, unexecuted=missing, setup_failures=sorted(setup_failures))
    return report, int(bool(failed or setup_failures or len(missing) > allowed))


def markdown(report):
    def cell(value):
        return str(value).replace('|', r'\|').replace('\n', ' ')
    lines = ['| Engine | Declared | Executed | Failed | Allowed (design) |',
             '| --- | ---: | ---: | ---: | ---: |',
             '| ' + ' | '.join(cell(report[k]) for k in ('engine', 'declared', 'executed', 'failed', 'allowed')) + ' |',
             '', '| Unexecuted function | Reason | Status |', '| --- | --- | --- |']
    lines += ['| ' + ' | '.join(cell(row[k]) for k in ('function', 'reason', 'status')) + ' |'
              for row in report['unexecuted']]
    if report['setup_failures']:
        lines += ['', 'Failed setUp: ' + ', '.join(report['setup_failures'])]
    return '\n'.join(lines) + '\n'


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--declared', required=True)
    p.add_argument('--log', action='append', required=True)
    p.add_argument('--engine', required=True)
    p.add_argument('--allow-reason', action='append', default=[])
    p.add_argument('--out-json', required=True)
    p.add_argument('--out-md', required=True)
    a = p.parse_args(argv)
    try:
        report, rc = inventory(json.loads(Path(a.declared).read_text()),
                               [Path(f).read_text() for f in a.log], a.engine, a.allow_reason)
        Path(a.out_json).write_text(json.dumps(report, indent=2) + '\n')
        Path(a.out_md).write_text(markdown(report))
        return rc
    except (ValueError, OSError, TypeError, AttributeError, re.error) as exc:
        print(f'error: {exc}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
