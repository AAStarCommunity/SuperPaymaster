#!/usr/bin/env python3
"""Trim the authenticated L-1 compiler output for offline authority tests."""
import argparse
import gzip
import hashlib
import io
import json
from pathlib import Path

COMMIT = 'a839347e04b40da287522c3641e12121ef2e8e9e'
BUILD_INFO = 'out/build-info/e34c552b450719a1.json'
SOURCE_SHA256 = 'b83fa70c805b322d603955b4b5643cb8daf6f61320e970e03af6d79398151a95'
FIXTURE = Path(__file__).with_name('l1-registry-a839347e')
# These are the extract() targets present in this compilation unit.
NAMES = ('GTokenStaking', 'Registry', 'SuperPaymaster', 'PaymasterFactory',
         'GToken', 'MySBT', 'xPNTsFactory', 'xPNTsToken', 'TimelockController')
COMMAND = ('python3 -B script/upgrade/fixtures/make_l1_registry_fixture.py '
           '--archive /private/tmp/l1-builds/' + COMMIT +
           ' --output script/upgrade/fixtures/l1-registry-a839347e')


def encoded(value):
    return (json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=True) + '\n').encode()


def generate(archive, output):
    raw = (archive / BUILD_INFO).read_bytes()
    if hashlib.sha256(raw).hexdigest() != SOURCE_SHA256:
        raise ValueError('archived build-info SHA256 mismatch')
    data = json.loads(raw)
    # extract()/inventory_source() require complete source text and AST references,
    # but never read output.contracts. Artifact reads in extract() use only abi.
    trimmed = dict(id=data['id'], input=dict(sources={
        p: dict(content=s['content']) for p, s in data['input']['sources'].items()}),
        output=dict(sources={p: dict(ast=s['ast'], id=s['id'])
                             for p, s in data['output']['sources'].items()}))
    buffer = io.BytesIO()
    with gzip.GzipFile(filename='', fileobj=buffer, mode='wb', mtime=0, compresslevel=9) as stream:
        stream.write(encoded(trimmed))
    files = {BUILD_INFO + '.gz': buffer.getvalue()}
    artifact_hashes = {}
    for name in NAMES:
        base = archive / 'out' / (name + '.sol')
        path = base / (name + '.default.json')
        if not path.exists():
            path = base / (name + '.json')
        artifact = path.read_bytes()
        artifact_hashes[path.relative_to(archive).as_posix()] = hashlib.sha256(artifact).hexdigest()
        files['out/' + name + '.sol/' + name + '.json'] = encoded(dict(abi=json.loads(artifact)['abi']))
    manifest = dict(source_build_info_sha256=SOURCE_SHA256, source_commit=COMMIT,
                    source_artifact_sha256s=artifact_hashes, generator_command=COMMAND,
                    files={p: hashlib.sha256(b).hexdigest() for p, b in sorted(files.items())})
    files['manifest.json'] = encoded(manifest)
    for name, content in sorted(files.items()):
        path = output / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', type=Path, default=Path('/private/tmp/l1-builds') / COMMIT)
    parser.add_argument('--output', type=Path, default=FIXTURE)
    args = parser.parse_args()
    generate(args.archive, args.output)
