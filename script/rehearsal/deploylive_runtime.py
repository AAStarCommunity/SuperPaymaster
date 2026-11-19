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
    refuse_fixture_directory(ROOT / value)
    return value


def refuse_fixture_directory(directory):
    """Validate production artifact authority; explicit test helper injection is separate."""
    path = Path(directory).absolute()
    for component in (path, *path.parents):
        if component.is_symlink():
            raise ValueError('symlink is not a release artifact directory')
    def check_fixture(candidate):
        parts = tuple(part.casefold() for part in candidate.parts)
        if 'fixtures' in parts or any(parts[i:i+2] == ('contracts', 'test') for i in range(len(parts)-1)):
            raise ValueError('test fixture directory is not a release artifact directory')
    check_fixture(path)
    try:
        resolved = path.resolve(strict=True)
    except OSError:
        raise ValueError('invalid artifact directory') from None
    check_fixture(resolved)
    if not resolved.is_dir(): raise ValueError('invalid artifact directory')
    return resolved


def release_artifact(name, directory=None):
    candidates = []
    for path in (Path(directory) if directory is not None else ROOT / artifact_directory()).glob('**/' + name + '.sol/*.json'):
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


def masked_runtime(code, references):
    value = bytearray.fromhex(code.removeprefix('0x'))
    if not value: raise ValueError('empty runtime')
    for refs in references.values():
        for ref in refs:
            start, length = ref['start'], ref['length']
            if start < 0 or length <= 0 or start + length > len(value):
                raise ValueError('invalid immutable range')
            value[start:start + length] = bytes(length)
    return '0x' + value.hex()


def matches(expected, actual):
    try:
        refs = expected.get('immutableReferences', {})
        return masked_runtime(expected['object'], refs) == masked_runtime(actual, refs)
    except (ValueError, TypeError, KeyError):
        return False


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
