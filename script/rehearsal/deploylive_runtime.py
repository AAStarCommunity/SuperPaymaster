"""Compare release runtimes, masking only compiler-declared immutable ranges."""
import json
import os
import re
import subprocess
from creation_pins import release_names
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def artifact_directory():
    value = os.environ.get('DEFAULT_ARTIFACTS_OUT', 'out')
    if not value or value.startswith('/') or value.endswith('/') or '..' in value.split('/') or any(c in value for c in ('\\', ':')):
        raise ValueError('invalid artifact directory')
    return value


def release_artifact(name):
    candidates = []
    for path in (ROOT / artifact_directory()).glob('**/' + name + '.sol/*.json'):
        obj = json.loads(path.read_text())
        metadata = obj.get('metadata', {})
        if isinstance(metadata, str): metadata = json.loads(metadata)
        settings = metadata.get('settings', {})
        if (name in settings.get('compilationTarget', {}).values()
                and settings.get('optimizer', {}).get('runs') == (200 if name in ('Registry', 'TimelockHandoverBootstrap') else 500)
                and settings.get('evmVersion') == 'cancun' and settings.get('viaIR') is True):
            candidates.append(obj)
    if not candidates or any((c['bytecode'], c['deployedBytecode']) != (candidates[0]['bytecode'], candidates[0]['deployedBytecode']) for c in candidates):
        raise ValueError('missing/ambiguous release artifact: ' + name)
    return candidates[0]


def compile_settings():
    result = {}
    for name in release_names():
        metadata = release_artifact(name)['metadata']
        if isinstance(metadata, str): metadata = json.loads(metadata)
        settings = metadata['settings']
        result[name] = dict(evmVersion=settings['evmVersion'], viaIR=settings['viaIR'], optimizerRuns=settings['optimizer']['runs'])
    return result


def artifact(name, expected_pin, keccak):
    obj = release_artifact(name)
    code = obj['bytecode']['object']
    if not code.startswith('0x'): code = '0x' + code
    rc, digest = keccak('keccak', code)
    if rc != 0 or digest.lower() != expected_pin.lower():
        raise ValueError('creation pin mismatch: ' + name)
    return obj['deployedBytecode']


def matches(expected, actual):
    left = bytearray.fromhex(expected['object'].removeprefix('0x'))
    right = bytearray.fromhex(actual.removeprefix('0x'))
    if not left or len(left) != len(right): return False
    for references in expected.get('immutableReferences', {}).values():
        for ref in references:
            start, length = ref['start'], ref['length']
            if start < 0 or length <= 0 or start + length > len(left): return False
            left[start:start + length] = right[start:start + length] = bytes(length)
    return left == right


def clean_source_commit(repo_root=ROOT, git_runner=None):
    """Return HEAD only when git can prove the worktree is clean."""
    runner = git_runner or subprocess.run
    head = runner(['git', '-C', str(repo_root), 'rev-parse', 'HEAD'], capture_output=True, text=True)
    if head.returncode != 0 or not re.fullmatch(r'[0-9a-f]{40}', head.stdout.strip()):
        raise RuntimeError('invalid git HEAD')
    status = runner(['git', '-C', str(repo_root), 'status', '--porcelain'], capture_output=True, text=True)
    if status.returncode != 0 or status.stdout.strip():
        raise RuntimeError('dirty worktree or unreadable git status')
    return head.stdout.strip()


def check_source_commit(config, chain, repo_root=ROOT, git_runner=None):
    commit = config.get('commit', '')
    if chain == 31337 and commit == '':
        return True
    if not isinstance(commit, str) or not re.fullmatch(r'[0-9a-f]{40}', commit):
        return False
    try:
        return commit == clean_source_commit(repo_root, git_runner)
    except (RuntimeError, OSError):
        return False
