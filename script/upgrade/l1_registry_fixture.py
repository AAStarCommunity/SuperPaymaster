"""Test-only archive selection and authenticated offline fixture materialization."""
import gzip
import hashlib
import json
import os
import tempfile
from functools import lru_cache
from pathlib import Path
from fixtures.make_l1_registry_fixture import BUILD_INFO, COMMIT, FIXTURE, SOURCE_SHA256

# Keep the temporary tree alive for callers that cache the returned path.
_TEMP_TREES = []


def archive_tree():
    """Override the archive parent to exercise CI fallback without moving evidence."""
    return Path(os.environ.get('L1_REGISTRY_ARCHIVE_ROOT', '/private/tmp/l1-builds')) / COMMIT


def materialize_fixture(destination, fixture=FIXTURE):
    manifest = json.loads((fixture / 'manifest.json').read_text())
    if manifest['source_build_info_sha256'] != SOURCE_SHA256 or manifest['source_commit'] != COMMIT:
        raise ValueError('L-1 fixture provenance mismatch')
    files = manifest['files']
    actual = {p.relative_to(fixture).as_posix() for p in fixture.rglob('*') if p.is_file()}
    if actual != set(files) | {'manifest.json'} or BUILD_INFO + '.gz' not in files:
        raise ValueError('L-1 fixture file set mismatch')
    verified = {}
    for name, digest in files.items():
        relative = Path(name)
        if relative.is_absolute() or '..' in relative.parts:
            raise ValueError('invalid fixture path')
        content = (fixture / relative).read_bytes()
        if hashlib.sha256(content).hexdigest() != digest:
            raise ValueError('L-1 fixture SHA256 mismatch: ' + name)
        verified[name] = content
    # Verify every file before decompressing or writing any of them.
    for name, content in verified.items():
        path = destination / (name[:-3] if name.endswith('.gz') else name)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(gzip.decompress(content) if name.endswith('.gz') else content)
    return destination


@lru_cache(maxsize=None)
def _registry_tree(archive):
    if archive.is_dir():
        return archive
    temporary = tempfile.TemporaryDirectory(prefix='l1-registry-fixture-')
    _TEMP_TREES.append(temporary)
    return materialize_fixture(Path(temporary.name) / COMMIT)


def registry_tree():
    return _registry_tree(archive_tree())
