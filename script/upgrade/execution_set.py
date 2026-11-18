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


SUPPLEMENTARY = (
    'script/upgrade/gate_name_frozen.json',
    'script/upgrade/gate_names_replaced_pr2.json',
    'script/upgrade/gate_renames_pr2.json',
    'script/upgrade/legacy_timelock_allowlist.json',
    'script/upgrade/execution_data_reads.json',
    'docs/release/a3a-precheck-v4/a3a-precheck.json',
    'docs/release/a3a-precheck-v4/snapshot.json',
    'script/evidence/a4-conformance-record.template.json',
)


def static_files(root, source):
    """Resolve literal Path joins and aliases; also include literal repo filenames."""
    tree = ast.parse(source.read_text())
    names = {'ROOT': root, 'HERE': source.parent, '__file__': source}

    def value(node):
        if isinstance(node, ast.Constant) and isinstance(node.value, (str, int)):
            return node.value
        if isinstance(node, ast.Name):
            return names.get(node.id)
        if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Div):
            left, right = value(node.left), value(node.right)
            if isinstance(left, Path) and isinstance(right, str):
                return left / right
        if isinstance(node, ast.Attribute):
            base = value(node.value)
            if isinstance(base, Path) and node.attr in ('parent', 'parents'):
                return getattr(base, node.attr)
        if isinstance(node, ast.Subscript) and isinstance(node.value, ast.Attribute) and node.value.attr == 'parents':
            base, index = value(node.value.value), value(node.slice)
            if isinstance(base, Path) and isinstance(index, int) and 0 <= index < len(base.parents):
                return base.parents[index]
        if isinstance(node, ast.Call):
            args = [value(arg) for arg in node.args]
            if isinstance(node.func, ast.Name) and node.func.id == 'Path' and len(args) == 1 and isinstance(args[0], (str, Path)):
                return Path(args[0])
            if isinstance(node.func, ast.Attribute):
                base = value(node.func.value)
                if isinstance(base, Path):
                    if node.func.attr in ('resolve', 'absolute') and not args:
                        return base
                    if node.func.attr in ('with_name', 'joinpath') and args and all(isinstance(arg, str) and arg for arg in args):
                        return getattr(base, node.func.attr)(*args)
        return None

    assignments = [node for node in ast.walk(tree) if isinstance(node, ast.Assign)]
    for _ in range(len(assignments) + 1):
        changed = False
        for node in assignments:
            result = value(node.value)
            for target in node.targets:
                if isinstance(target, ast.Name) and isinstance(result, Path) and names.get(target.id) != result:
                    names[target.id] = result
                    changed = True
        if not changed:
            break
    found = set()
    for node in ast.walk(tree):
        result = value(node)
        candidates = [result] if isinstance(result, Path) else []
        if isinstance(node, ast.Constant) and isinstance(node.value, str) and '\n' not in node.value and 0 < len(node.value) < 240:
            candidates += [root / node.value, source.parent / node.value]
        for path in candidates:
            if path.is_absolute() and path.is_relative_to(root) and path.is_file():
                found.add(path)
    return found


def data_files(root, modules):
    found = {root / name for name in SUPPLEMENTARY if (root / name).is_file()}
    for source in modules:
        found.update(static_files(root, source))
    return found


def read_sites(source):
    """Stable AST signatures: new dynamic reads require explicit review too."""
    sites = []
    for node in ast.walk(ast.parse(source)):
        if isinstance(node, (ast.BinOp, ast.Assign)) and any(
                isinstance(part, ast.Name) and part.id in ('ROOT', 'HERE', '__file__')
                for part in ast.walk(node)):
            sites.append(ast.unparse(node))
        if not isinstance(node, ast.Call):
            continue
        function = node.func
        if ((isinstance(function, ast.Name) and function.id == 'open') or
                (isinstance(function, ast.Attribute) and function.attr in
                 ('open', 'read_text', 'read_bytes', 'load'))):
            sites.append(ast.unparse(node))
    return sorted(sites)


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
        # Literal subprocess scripts and file-based imports also carry dependencies.
        pending.extend(p for p in static_files(root, path) if p.suffix == '.py' and p not in seen)
    seen.update(data_files(root, seen))
    return sorted(p.relative_to(root).as_posix() for p in seen)


def manifest(root=ROOT):
    return ''.join(hashlib.sha256((root / p).read_bytes()).hexdigest() + '  ' + p + '\n'
                   for p in execution_files(root))


def pin_manifest(plan, digest):
    execution = plan.setdefault('execution', {})
    if 'manifestSha256' in execution and execution['manifestSha256'] != digest:
        raise RuntimeError('execution_set_sha256')
    execution['manifestSha256'] = digest
    return execution


def freeze_manifest(plan, out, root=ROOT):
    content = manifest(root)
    digest = hashlib.sha256(content.encode()).hexdigest()
    pin_manifest(plan, digest)
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
    digest = hashlib.sha256(content.encode()).hexdigest()
    if args.packet:
        plan = json.loads(args.plan.read_bytes())
        execution = pin_manifest(plan, digest)
        signer = cast_identity(args.cast)
        if 'cast' in execution and execution['cast'] != signer:
            raise RuntimeError('execution_cast_identity')
        execution['cast'] = signer
        args.packet.write_text(json.dumps(plan, indent=2) + '\n')
    args.manifest.write_text(content)
    print(digest)


if __name__ == '__main__':
    main()
