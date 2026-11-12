"""Count declared functions with execution evidence, not Forge's skipped counter.

Trust boundary: trust local git HEAD/tree, pinned binaries and this tool. This
inventory binds input records; release measurements must come from a clean-tree
runner. Evidence rewriting with recomputed hashes is out of scope; reviewers rerun.
"""
import argparse
import hashlib
import subprocess
import json
import re
import sys
from pathlib import Path

SUITE = re.compile(r'^Ran \d+ tests? for (.+):([^:]+)$')
RESULT = re.compile(r'^\[(PASS|FAIL|SKIP)(.*?)\]\s+(\w+(?:\([^)]*\))?)')  # nightly prints invariants without '()'
ABSTRACT = r'(?:^|[}};])\s*abstract\s+contract\s+{}\b'


def solidity_code(source):
    # Preserve newlines and separators, but never interpret comment/string contents.
    return re.sub(r'//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'',
                  lambda m: ''.join('\n' if c == '\n' else ' ' for c in m[0]),
                  source, flags=re.DOTALL)


def inventory(declared, logs, engine, allow=(), root=None):
    names = set()
    abstract = []
    for path, contracts in declared.items():
        source = solidity_code((Path(root) / path).read_text()) if root is not None else ''
        for contract, tests in contracts.items():
            if not isinstance(tests, list) or not all(isinstance(t, str) for t in tests):
                raise ValueError('expected path -> contract -> list of test signatures')
            # Newer forge lists abstract bases; their tests only ever run in derived contracts.
            if source and re.search(ABSTRACT.format(re.escape(contract)), source, re.MULTILINE):
                abstract.append(f'{path}:{contract} ({len(tests)})')
                continue
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
            if key not in names and any(a.startswith(f'{suite[0]}:{suite[1]} ') for a in abstract):
                continue
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
                  allowed=allowed, unexecuted=missing, setup_failures=sorted(setup_failures),
                  excluded_abstract=abstract)
    return report, int(bool(failed or setup_failures or len(missing) > allowed))


def binding(path):
    path = Path(path).resolve()
    return dict(path=str(path), sha256=hashlib.sha256(path.read_bytes()).hexdigest())


def bound_inventory(declared, logs, engine, allow, root):
    root = Path(root).resolve()
    head = subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip()
    dirty = bool(subprocess.check_output(['git', '-C', str(root), 'status', '--porcelain',
                                         '--ignore-submodules=all'], text=True).strip())
    declarations = json.loads(Path(declared).read_text())
    report, rc = inventory(declarations, [Path(f).read_text() for f in logs], engine, allow, root)
    report.update(head=head, dirty=dirty, root=str(root), allow_reason=list(allow),
                  inputs=dict(declared=binding(declared), logs=[binding(f) for f in logs],
                              sources=[binding(root / f) for f in sorted(declarations)]))
    return report, rc


def verify(path):
    saved = json.loads(Path(path).read_text())
    inputs = saved['inputs']
    for item in [inputs['declared'], *inputs['logs'], *inputs['sources']]:
        if binding(item['path']) != item:
            raise ValueError('input hash mismatch: ' + item['path'])
    actual, rc = bound_inventory(inputs['declared']['path'], [i['path'] for i in inputs['logs']],
                                 saved['engine'], saved['allow_reason'], saved['root'])
    if actual != saved:
        raise ValueError('inventory mismatch (HEAD, tree status, inputs or derived counts)')
    return rc


def markdown(report):
    def cell(value):
        return str(value).replace('|', r'\|').replace('\n', ' ')
    lines = ['| Engine | Declared | Executed | Failed | Allowed (design) |',
             '| --- | ---: | ---: | ---: | ---: |',
             '| ' + ' | '.join(cell(report[k]) for k in ('engine', 'declared', 'executed', 'failed', 'allowed')) + ' |',
             '', '| Unexecuted function | Reason | Status |', '| --- | --- | --- |']
    lines += ['| ' + ' | '.join(cell(row[k]) for k in ('function', 'reason', 'status')) + ' |'
              for row in report['unexecuted']]
    if report.get('excluded_abstract'):
        lines += ['', 'Excluded abstract contracts (not runnable; tests run in derived contracts): '
                  + ', '.join(report['excluded_abstract'])]
    if report['setup_failures']:
        lines += ['', 'Failed setUp: ' + ', '.join(report['setup_failures'])]
    if 'inputs' in report:
        header = [f"HEAD: {report['head']}", f"Dirty: {report['dirty']}", f"Engine: {cell(report['engine'])}",
                  '', '| Input | Path | SHA256 |', '| --- | --- | --- |']
        for kind, items in report['inputs'].items():
            for item in (items if isinstance(items, list) else [items]):
                header.append('| ' + ' | '.join(map(cell, (kind, item['path'], item['sha256']))) + ' |')
        lines = header + [''] + lines
    return '\n'.join(lines) + '\n'


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--verify', help='re-hash inputs and re-derive a bound JSON inventory')
    p.add_argument('--declared', required=False)
    p.add_argument('--log', action='append', required=False)
    p.add_argument('--engine', required=False)
    p.add_argument('--allow-reason', action='append', default=[])
    p.add_argument('--out-json', required=False)
    p.add_argument('--out-md', required=False)
    p.add_argument('--root', default='.', help='project root for reading sources (abstract detection)')
    a = p.parse_args(argv)
    try:
        if a.verify:
            rc = verify(a.verify)
            print('Verified inventory and all inputs')
            return rc
        if not all((a.declared, a.log, a.engine, a.out_json, a.out_md)):
            p.error('--declared, --log, --engine, --out-json and --out-md are required')
        report, rc = bound_inventory(a.declared, a.log, a.engine, a.allow_reason, a.root)
        Path(a.out_json).write_text(json.dumps(report, indent=2) + '\n')
        Path(a.out_md).write_text(markdown(report))
        return rc
    except (ValueError, OSError, TypeError, AttributeError, KeyError, subprocess.CalledProcessError, re.error) as exc:
        print(f'error: {exc}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
