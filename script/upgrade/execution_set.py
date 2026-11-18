#!/usr/bin/env python3
"""Freeze the AST-derived execution set for verification by the system shasum.

This is a second line of defence against accidental deviation, not a same-user
security boundary. Dynamic imports require review; literal imports are transitive.
"""
import argparse
import ast
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]
ENTRIES = ('script/a3a/a3a_send.py', 'script/upgrade/manifest_send.py',
           'script/a3a/a3a_exec.py', 'script/upgrade/manifest_exec.py',
           'script/upgrade/sp_upgrade_exec.py', 'script/upgrade/execution_integrity.py',
           'script/upgrade/execution_set.py')


def execution_files(root=ROOT):
    # Index all repository Python modules, including modules reached by sys.path
    # adjustments. Ambiguous names are included conservatively, never omitted.
    index = {}
    packages = set()
    env = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
    env.update(GIT_CONFIG_NOSYSTEM='1', GIT_NO_REPLACE_OBJECTS='1')
    files = subprocess.run([str(Path(shutil.which('git')).resolve()), '--no-replace-objects',
                            'ls-files', '--cached', '--others', '--exclude-standard', '-z'],
                           cwd=root, env=env, capture_output=True)
    # Non-Git fixture directories are also supported. Real repositories use Git's
    # file inventory, so ignored build caches and nested copies cannot contaminate it.
    paths = ([root / os.fsdecode(p) for p in files.stdout.split(b'\0') if p]
             if files.returncode == 0 and files.stdout else root.rglob('*.py'))
    for path in paths:
        if path.suffix != '.py' or not path.is_file():
            continue
        packages.update(parent.name for parent in path.parents if parent != root and parent.is_relative_to(root))
        index.setdefault(path.stem, set()).add(path)
        if path.name == '__init__.py':
            index.setdefault(path.parent.name, set()).add(path)
    pending = [root / p for p in ENTRIES if (root / p).is_file()]
    seen = set()
    while pending:
        path = pending.pop()
        if path in seen:
            continue
        seen.add(path)
        for parent in path.parents:
            if parent == root:
                break
            initializer = parent / '__init__.py'
            if initializer.is_file():
                pending.append(initializer)
        for node in ast.walk(ast.parse(path.read_text(), filename=str(path))):
            names = []
            if isinstance(node, ast.Import):
                names = [alias.name for alias in node.names]
            elif isinstance(node, ast.ImportFrom):
                base = (node.module or '').split('.')[0]
                if node.level or base in index or base in packages:
                    names = [node.module or '', *(alias.name for alias in node.names)]
            for name in names:
                if name.split('.')[0] not in index and name.split('.')[0] not in packages:
                    continue
                for part in name.split('.'):
                    pending.extend(index.get(part, ()))
    return sorted(p.relative_to(root).as_posix() for p in seen)


def manifest(root=ROOT):
    return ''.join(hashlib.sha256((root / p).read_bytes()).hexdigest() + '  ' + p + '\n'
                   for p in execution_files(root))


def freeze_manifest(plan, out, root=ROOT):
    content = manifest(root)
    digest = hashlib.sha256(content.encode()).hexdigest()
    execution = plan.setdefault('execution', {})
    if 'manifestSha256' in execution and execution['manifestSha256'] != digest:
        raise RuntimeError('execution_set_sha256')
    execution['manifestSha256'] = digest
    (out / 'execution-set.sha256').write_text(content)
    return digest


def cast_identity(binary):
    resolved = shutil.which(str(binary))
    if resolved is None:
        raise RuntimeError('cast executable unavailable')
    path = Path(resolved).resolve()
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    result = subprocess.run([str(path), '--version'], check=True, capture_output=True, text=True)
    return dict(path=str(path), sha256=digest, version=result.stdout.strip())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--plan', type=Path)
    parser.add_argument('--packet', type=Path)
    parser.add_argument('--cast', help='reviewed cast executable; required when freezing a packet')
    args = parser.parse_args()
    if any((args.plan, args.packet, args.cast)) and not all((args.plan, args.packet, args.cast)):
        parser.error('--plan, --packet and --cast must be supplied together')
    content = manifest()
    args.manifest.write_text(content)
    digest = hashlib.sha256(content.encode()).hexdigest()
    if args.packet:
        plan = json.loads(args.plan.read_bytes())
        signer = cast_identity(args.cast)
        plan['execution'] = dict(manifestSha256=digest,
                                 cast={k: signer[k] for k in ('sha256', 'version')})
        args.packet.write_text(json.dumps(plan, indent=2) + '\n')
    print(digest)


if __name__ == '__main__':
    main()
