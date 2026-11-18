#!/usr/bin/env python3
"""Compare creation and runtime bytes, including missing artifacts."""
import json
from pathlib import Path
import sys


def inventory(root):
    result = {}
    for path in Path(root).rglob('*.json'):
        obj = json.loads(path.read_text())
        if 'bytecode' not in obj or 'deployedBytecode' not in obj:
            continue
        key = path.relative_to(root).as_posix()
        # The source compilation target is authoritative when metadata is present.
        metadata = obj.get('metadata', {})
        if isinstance(metadata, str):
            metadata = json.loads(metadata)
        sources = metadata.get('settings', {}).get('compilationTarget', {})
        is_test = any(s.endswith('.t.sol') or '/test/' in s or s.startswith('test/') for s in sources)
        if not sources:
            is_test = '.t.sol/' in key
        result[key] = (obj['bytecode']['object'].lower(), obj['deployedBytecode']['object'].lower(), not is_test)
    return result


def compare(a, b):
    left, right = inventory(a), inventory(b)
    return [(key, left.get(key, right.get(key))[2] or right.get(key, left.get(key))[2])
            for key in sorted(left.keys() | right.keys()) if left.get(key) != right.get(key)]


def main():
    if len(sys.argv) != 3:
        raise SystemExit('usage: compare_artifacts.py <dirA> <dirB>')
    changes = compare(Path(sys.argv[1]), Path(sys.argv[2]))
    for key, release in changes:
        print(('RELEASE' if release else 'TEST') + ' ' + key)
    return int(any(release for _, release in changes))


if __name__ == '__main__':
    sys.exit(main())
