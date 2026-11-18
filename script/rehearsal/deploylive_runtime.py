"""Compare release runtimes, masking only compiler-declared immutable ranges."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def artifact(name, expected_pin, keccak):
    candidates = []
    for path in (ROOT / 'out' / (name + '.sol')).glob('*.json'):
        obj = json.loads(path.read_text())
        metadata = obj.get('metadata', {})
        if isinstance(metadata, str): metadata = json.loads(metadata)
        settings = metadata.get('settings', {})
        if (name in settings.get('compilationTarget', {}).values()
                and settings.get('optimizer', {}).get('runs') == (200 if name == 'Registry' else 500)
                and settings.get('evmVersion') == 'cancun' and settings.get('viaIR') is True):
            code = obj['bytecode']['object']
            if not code.startswith('0x'): code = '0x' + code
            rc, digest = keccak('keccak', code)
            if rc != 0 or digest.lower() != expected_pin.lower():
                raise ValueError('creation pin mismatch: ' + name)
            candidates.append(obj['deployedBytecode'])
    if not candidates or any(c != candidates[0] for c in candidates):
        raise ValueError('missing/ambiguous release runtime: ' + name)
    return candidates[0]


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
