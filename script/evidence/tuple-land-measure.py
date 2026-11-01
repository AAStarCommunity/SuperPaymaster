#!/usr/bin/env python3
"""Record missing tuple-480 trajectories, with exact old-tuple positive controls.

Run from a clean commit. Verification is offline and reads frozen arrays from
head.txt's git revision, never from the verifier's current checkout.
"""
import argparse
import hashlib
import itertools
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SOURCE = 'contracts/test/v2/SuperPaymasterPostOpGasProfile.t.sol'
ENGINES = ('amsterdam', 'cancun', 'prague')
MODES = ('balance', 'credit')
BUDGETS = (440000, 480000)


def git(*args):
    return subprocess.check_output(['git', *args], cwd=ROOT, text=True)


def inventory():
    return itertools.product(ENGINES, MODES, BUDGETS)


def name(engine, mode, budget):
    return f'{engine}-{mode}-{budget}'


def selectors(engine, mode, budget):
    return {
        'PROFILE_AMSTERDAM': str(engine == 'amsterdam').lower(),
        'TRAJECTORY_BUDGET': str(budget), 'TRAJECTORY_RECORD': 'true',
        'TUPLE_480': str(budget == 480000).lower(), 'TUPLE_CANDIDATE': 'false',
    }


def command(engine, mode, deps):
    exe = ('~/Dev/aastar/tools/foundry-rams/nightly-4e8874b/forge'
           if engine == 'amsterdam' else '~/.foundry/bin/forge')
    cmd = [os.path.expanduser(exe), 'test', '--offline', '-vv',
           '--match-path', SOURCE, '--match-contract',
           f'^PostOpProfile{mode.title()}TrajectoryTest$', '--match-test', '^test_trajectory$']
    if engine != 'cancun':
        cmd += ['--evm-version', 'prague']
    if engine == 'amsterdam':
        cmd += ['--no-isolate', '--hardfork', 'amsterdam']
    for alias, path in (('@chainlink/contracts/', 'chainlink-brownie-contracts/contracts/'),
                        ('solady/', 'solady/src/')):
        cmd += ['-R', f'{alias}={deps}/contracts/lib/{path}']
    return cmd


def frozen(revision):
    source = git('show', f'{revision}:{SOURCE}')
    arrays = re.findall(r'\[uint256\((\d+)\),\s*([\d,\s]+)\]', source)
    values = [[int(first), *map(int, rest.split(','))] for first, rest in arrays]
    if len(values) != 4 or any(len(v) != 8 for v in values):
        raise ValueError('expected four frozen eight-checkpoint arrays at recorded HEAD')
    return {e: dict(zip(('credit', 'balance'), values[:2] if e == 'amsterdam' else values[2:]))
            for e in ENGINES}


def parse(log):
    points = re.findall(r'^\s*checkpoint (\d+) (\d+)\s*$', log, re.M)
    if [int(i) for i, _ in points] != list(range(8)):
        raise ValueError('missing, duplicate or unordered checkpoints')
    if len(re.findall(r'^\[PASS\] test_trajectory\(\)', log, re.M)) != 1:
        raise ValueError('trajectory settlement assertion did not pass')
    if not re.search(r'1 tests? passed, 0 failed, 0 skipped', log) or '[FAIL' in log:
        raise ValueError('missing successful test summary')
    return [int(v) for _, v in points]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def collect(out):
    revision = (out / 'head.txt').read_text().strip()
    if not re.fullmatch(r'[0-9a-f]{40}', revision):
        raise ValueError('invalid HEAD')
    expected = frozen(revision)
    rows = json.loads((out / 'commands.json').read_text())
    specs = list(inventory())
    if len(rows) != len(specs):
        raise ValueError('expected exactly 12 commands')
    result = {e: {m: {} for m in MODES} for e in ENGINES}
    for row, (e, m, b) in zip(rows, specs):
        if (row['id'] != name(e, m, b) or row['env'] != selectors(e, m, b)
                or row['argv'] != command(e, m, row['deps']) or row['exit'] != 0):
            raise ValueError('incorrect command, selector or exit')
        points = parse((out / (row['id'] + '.log')).read_text())
        if b == 440000 and points != expected[e][m]:
            raise ValueError(f'{e}/{m}: 440000 control differs from frozen HEAD arrays')
        result[e][m][str(b)] = points
    return result


def verify(out):
    required = {'head.txt', 'working-tree.txt', 'commands.json', 'checkpoints.json', 'SHA256SUMS'}
    required |= {name(*s) + '.log' for s in inventory()}
    required |= {e + '-version.txt' for e in ENGINES}
    if {p.name for p in out.iterdir()} != required or any(not p.is_file() or p.is_symlink() for p in out.iterdir()):
        raise ValueError('incorrect artifact inventory')
    lines = (out / 'SHA256SUMS').read_text().splitlines()
    manifest = dict(line.split('  ', 1)[::-1] for line in lines)
    if len(lines) != len(manifest) or set(manifest) != required - {'SHA256SUMS'}:
        raise ValueError('incorrect hash inventory')
    for file, sha in manifest.items():
        if digest(out / file) != sha:
            raise ValueError('hash mismatch: ' + file)
    if (out / 'working-tree.txt').read_text():
        raise ValueError('measurement must originate from a clean commit')
    if collect(out) != json.loads((out / 'checkpoints.json').read_text()):
        raise ValueError('checkpoints.json differs from logs')
    print('PASS: 12 trajectories; six exact 440000 controls; inventory and hashes')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path, help='empty output directory (existing artifact for --verify)')
    parser.add_argument('--verify', action='store_true', help='verify only; do not execute Forge')
    parser.add_argument('--dry-run', action='store_true', help='print 12 commands; write nothing and do not execute Forge')
    args = parser.parse_args()
    out = args.output.resolve()
    if args.verify:
        verify(out)
        return
    deps = os.environ.get('PROFILE_DEPS_ROOT')
    if not deps or not Path(deps).is_dir():
        parser.error('PROFILE_DEPS_ROOT must name a checkout with initialized dependencies')
    deps = str(Path(deps).resolve())
    for path in ('chainlink-brownie-contracts/contracts', 'solady/src'):
        if not (Path(deps) / 'contracts/lib' / path).is_dir():
            parser.error('missing dependency: ' + path)
    if out.exists() and (not out.is_dir() or any(out.iterdir())):
        parser.error('output directory must be empty')
    if args.dry_run:
        for e, m, b in inventory():
            print(json.dumps({'id': name(e, m, b), 'env': selectors(e, m, b), 'argv': command(e, m, deps)}))
        return
    status = git('status', '--porcelain', '--untracked-files=all')
    if status:
        parser.error('commit measurement code first: working tree must be clean')
    revision = git('rev-parse', 'HEAD')
    frozen(revision.strip())
    out.mkdir(parents=True, exist_ok=True)
    (out / 'head.txt').write_text(revision)
    (out / 'working-tree.txt').write_text(status)
    clean = {k: v for k, v in os.environ.items() if not k.startswith(
        ('FOUNDRY_', 'PROFILE_', 'TRAJECTORY_', 'TUPLE_', 'T480_', 'MULTI_', 'G2_'))}
    rows = []
    with tempfile.TemporaryDirectory(prefix='tuple-land-') as build:
        for e in ENGINES:
            version = subprocess.check_output([command(e, 'balance', deps)[0], '--version'], text=True)
            (out / f'{e}-version.txt').write_text(version)
        for e, m, b in inventory():
            cmd, env = command(e, m, deps), selectors(e, m, b)
            runenv = clean | env | {'FOUNDRY_OUT': f'{build}/{e}/out',
                                   'FOUNDRY_CACHE_PATH': f'{build}/{e}/cache'}
            p = subprocess.run(cmd, cwd=ROOT, env=runenv, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, text=True)
            (out / (name(e, m, b) + '.log')).write_text(p.stdout)
            rows.append(dict(id=name(e, m, b), argv=cmd, env=env, deps=deps, exit=p.returncode))
            (out / 'commands.json').write_text(json.dumps(rows, indent=2) + '\n')
            if p.returncode:
                raise ValueError('Forge failed: ' + name(e, m, b))
            points = parse(p.stdout)
            if b == 440000 and points != frozen(revision.strip())[e][m]:
                raise ValueError('positive control failed: ' + name(e, m, b))
            print(name(e, m, b), points, flush=True)
    (out / 'checkpoints.json').write_text(json.dumps(collect(out), indent=2) + '\n')
    (out / 'SHA256SUMS').write_text(''.join(f'{digest(p)}  {p.name}\n' for p in sorted(out.iterdir())))
    verify(out)


if __name__ == '__main__':
    main()
