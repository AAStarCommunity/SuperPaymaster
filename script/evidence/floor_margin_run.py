#!/usr/bin/env python3
"""Run and extract clean-checkout Amsterdam floor evidence.

Trust boundary: trust the local git checkout (HEAD and tree), the pinned Forge
binary and this tool. Caller metadata is never release evidence. An attacker
who can rewrite evidence and recompute hashes is out of scope; reviewers rerun.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

from floor_margin_extract import extract

TEST = 'contracts/test/measure/AmsterdamHandleOpsFloor.t.sol'


def git(root, *args):
    return subprocess.check_output(['git', '-C', str(root), *args], text=True).strip()


def clean_head(root):
    status = subprocess.check_output(['git', '-C', str(root), 'status', '--porcelain',
                                      '--ignore-submodules=all', '--untracked-files=all'], text=True)
    dirty = [line for line in status.splitlines()
             if not all(path.strip('"').startswith('.codex-work/')
                        for path in line[3:].split(' -> '))]
    if dirty:
        raise ValueError('dirty tree: ' + '; '.join(dirty))
    return git(root, 'rev-parse', 'HEAD')


def manifest(root):
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted([*root.glob('contracts/src/**/*.sol'), root / TEST])}


def run(nightly, out, root):
    root, out, nightly = root.resolve(), out.resolve(), nightly.resolve()
    head = clean_head(root)
    if any((out / name).exists() for name in ('floor.log', 'floor-margin.json')):
        raise ValueError('output already contains floor evidence; use a fresh directory')
    sources = manifest(root)
    version = subprocess.check_output([str(nightly), '--version'], cwd=root, text=True)
    commits = re.findall(r'\b[0-9a-fA-F]{40}\b', version)
    if len(set(commits)) != 1:
        raise ValueError('version must contain one full 40-hex commit')
    out.mkdir(parents=True, exist_ok=True)
    argv = [str(nightly), 'test', '--offline', '--no-isolate', '--evm-version', 'cancun',
            '--hardfork', 'amsterdam', '--match-path', TEST, '-vv',
            '--out', str(out / 'out'), '--cache-path', str(out / 'cache')]
    env = {'PROFILE_AMSTERDAM': 'true'}
    with (out / 'floor.log').open('w') as log:
        result = subprocess.run(argv, cwd=root, env={**os.environ, **env}, stdout=log, stderr=subprocess.STDOUT)
    if result.returncode:
        raise ValueError(f'measurement failed: rc={result.returncode}; see {out / "floor.log"}')
    if clean_head(root) != head or manifest(root) != sources:
        raise ValueError('checkout changed during measurement')
    log = (out / 'floor.log').read_text()
    report = extract([log], 'amsterdam', head, version, json.dumps(argv))
    report.update(provenance='executed', argv=argv, env=env, engine_commit=commits[0],
                  sources=sources, inputs=[dict(path=str(out / 'floor.log'),
                  sha256=hashlib.sha256((out / 'floor.log').read_bytes()).hexdigest())])
    (out / 'floor-margin.json').write_text(json.dumps(report, indent=2) + '\n')
    return report


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--nightly', type=Path, required=True)
    p.add_argument('--out-dir', type=Path, required=True)
    a = p.parse_args(argv)
    try:
        root = Path(git(Path.cwd(), 'rev-parse', '--show-toplevel'))
        report = run(a.nightly, a.out_dir, root)
        print('executed:', json.dumps(report['summary'], sort_keys=True))
        return 0
    except (ValueError, OSError, subprocess.CalledProcessError) as exc:
        print(f'error: {exc}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
