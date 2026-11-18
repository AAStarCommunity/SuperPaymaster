#!/usr/bin/env python3
"""Create/check creation pins using a fresh, isolated offline Cancun build."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
FORGE = '/Users/jason/.foundry/bin/forge'
CAST = '/Users/jason/.foundry/bin/cast'


def creation_bytes(root, name, runs):
    candidates = set()
    for path in Path(root).rglob('*.json'):
        obj = json.loads(path.read_text())
        metadata = obj.get('metadata', {})
        if isinstance(metadata, str): metadata = json.loads(metadata)
        settings = metadata.get('settings', {})
        if name not in settings.get('compilationTarget', {}).values(): continue
        if settings.get('optimizer', {}).get('runs') != runs or settings.get('evmVersion') != 'cancun': continue
        code = obj['bytecode']['object']
        if not code.startswith('0x'): code = '0x' + code
        if not re.fullmatch(r'0x(?:[0-9a-fA-F]{2})+', code): raise ValueError('unlinked/empty bytecode: ' + name)
        candidates.add(code.lower())
    if len(candidates) != 1: raise ValueError('missing/ambiguous release artifact: ' + name)
    return candidates.pop()


def check_pins(expected, actual):
    if expected != actual:
        raise ValueError('creation pin mismatch: ' + ', '.join(sorted(k for k in expected.keys() | actual.keys() if expected.get(k) != actual.get(k))))


def clean_build_pins():
    names = re.findall(r'"([A-Za-z0-9]+)"', (ROOT/'contracts/script/v3/DeployLivePins.sol').read_text().split('return [', 1)[1].split('];', 1)[0])
    names.append('TimelockHandoverBootstrap')
    with tempfile.TemporaryDirectory(prefix='.creation-build-', dir=ROOT) as tmp:
        project = Path(tmp)
        ignore = shutil.ignore_patterns('.git', '.env*', 'out', 'cache', 'node_modules', '__pycache__', 'evidence')
        for name in ('contracts', 'singleton-paymaster', 'lib', 'script'):
            if (ROOT/name).exists(): shutil.copytree(ROOT/name, project/name, ignore=ignore)
        shutil.copy2(ROOT/'foundry.toml', project/'foundry.toml')
        out = project/'out-clean'; out.mkdir()
        env = dict(os.environ, DEFAULT_ARTIFACTS_OUT='out-clean', FOUNDRY_OUT='out-clean', FOUNDRY_CACHE_PATH='cache-clean')
        subprocess.run(['nice', '-n', '10', FORGE, 'build', '--offline', '--evm-version', 'cancun'], cwd=project, env=env, check=True)
        result = {}
        for name in names:
            code = creation_bytes(out, name, 200 if name in ('Registry', 'TimelockHandoverBootstrap') else 500)
            result[name] = subprocess.check_output([CAST, 'keccak', code], text=True).strip()
        return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('pin_file', type=Path)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    path = args.pin_file.resolve()
    if not path.is_relative_to(ROOT): raise ValueError('pin file must be in worktree')
    actual = clean_build_pins()
    if args.check: check_pins(json.loads(path.read_text()), actual)
    else: path.write_text(json.dumps(actual, indent=2, sort_keys=True) + '\n')


if __name__ == '__main__': main()
