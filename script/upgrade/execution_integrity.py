"""Executor source and checkout checks for accidental dirty/altered execution.

This checks files, not in-memory bytecode, and is not an OS security sandbox.
"""
import hashlib
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys


def git_query(root, *args):
    env = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
    env.update(GIT_CONFIG_NOSYSTEM='1', GIT_NO_REPLACE_OBJECTS='1')
    binary = shutil.which('git')
    if binary is None:
        raise RuntimeError('git unavailable')
    return subprocess.run([str(Path(binary).resolve()), '--no-replace-objects', *args],
                          cwd=root, env=env, capture_output=True, check=True).stdout


def git_evidence(root):
    return dict(path=str(Path(shutil.which('git')).resolve()),
                version=git_query(root, '--version').decode().strip())


def reject_rewrites(root):
    if git_query(root, 'for-each-ref', '--format=%(refname)', 'refs/replace/'):
        raise RuntimeError('execution_replace_refs')
    grafts = Path(os.fsdecode(git_query(root, 'rev-parse', '--git-path', 'info/grafts').strip()))
    if not grafts.is_absolute():
        grafts = root / grafts
    if grafts.exists() or grafts.is_symlink():
        raise RuntimeError('execution_grafts')


def packet_check(plan):
    from execution_set import manifest
    digest = hashlib.sha256(manifest().encode()).hexdigest()
    if plan.get('execution', {}).get('manifestSha256') != digest:
        raise RuntimeError('execution_set_sha256')
    return dict(manifestSha256=digest)


def cli_preflight():
    """Before first-party imports, inspect a supplied plan using only stdlib.

    Building a new plan has no reviewed commit yet; deploy-day shasum is its
    external check. Library entry points check once their caller supplies a plan.
    """
    import argparse
    import json
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument('--plan', type=Path)
    parser.add_argument('--reviewed-plan-sha256')
    args, _ = parser.parse_known_args()
    if args.plan is not None:
        raw = args.plan.read_bytes()
        if args.reviewed_plan_sha256 and hashlib.sha256(raw).hexdigest() != args.reviewed_plan_sha256:
            raise RuntimeError('reviewed_plan_hash')
        check(json.loads(raw)['rebuild']['commit'])


def bootstrap(commit):
    """Authenticate dependencies without invoking any first-party code."""
    root = Path(__file__).resolve().parents[2]
    reject_rewrites(root)

    def committed(relative):
        return git_query(root, 'show', commit + ':' + relative)

    def verified(relative):
        path = root / relative
        return hashlib.sha256(path.read_bytes()).digest() == hashlib.sha256(committed(relative)).digest()

    # A Gate cannot be constructed from an unverified repository implementation.
    gate_path = 'script/a3a/a3a_exec.py'
    if not verified(gate_path) or not verified('script/evidence/lib/rpc_strict.py'):
        raise RuntimeError('bootstrap Gate source is not the committed repository file')
    # Authenticate the stdlib-only generator before running its AST traversal,
    # then compare the entire execution set before loading any business module.
    def require_verified(relative):
        if not verified(relative):
            raise RuntimeError('execution_bootstrap_source: ' + relative)

    generator_path = 'script/upgrade/execution_set.py'
    require_verified(generator_path)
    generator_spec = importlib.util.spec_from_file_location('_bootstrap_execution_set', root / generator_path)
    generator = importlib.util.module_from_spec(generator_spec)
    generator_spec.loader.exec_module(generator)
    for relative in generator.execution_files(root):
        require_verified(relative)
    tracked = git_query(root, 'ls-tree', '-r', '--name-only', commit).decode().splitlines()
    invalid = []
    for relative in tracked:
        path = Path(relative)
        if path.suffix != '.py' or path.parts[0] != 'script':
            continue
        module = sys.modules.get(path.stem)
        if module is None:
            continue
        origin = getattr(module, '__file__', None)
        if not origin or Path(origin).resolve() != (root / path).resolve() or not verified(relative):
            invalid.append(relative)

    name = '_execution_bootstrap_a3a_exec'
    spec = importlib.util.spec_from_file_location(name, root / gate_path)
    a = importlib.util.module_from_spec(spec)
    existing = sys.modules.get('a3a_exec')
    if existing is not None and gate_path not in invalid:
        # Preserve exception compatibility only with the authenticated canonical module.
        a._repository_gate_base = existing.Gate
    rpc_name = 'rpc_strict'
    rpc_spec = importlib.util.spec_from_file_location(rpc_name, root / 'script/evidence/lib/rpc_strict.py')
    rpc_module = importlib.util.module_from_spec(rpc_spec)
    rpc_spec.loader.exec_module(rpc_module)
    previous_rpc = sys.modules.get(rpc_name)
    sys.modules[rpc_name] = rpc_module
    previous = sys.modules.get(name)
    sys.modules[name] = a
    try:
        spec.loader.exec_module(a)
    finally:
        if previous_rpc is None:
            del sys.modules[rpc_name]
        else:
            sys.modules[rpc_name] = previous_rpc
        if previous is None:
            del sys.modules[name]
        else:
            sys.modules[name] = previous
    if invalid:
        raise a.Gate('execution_bootstrap_origin', invalid, [])


def git(*args):
    import sp_upgrade_exec as u
    return git_query(u.ROOT, *args)


def tree_gates(commit):
    import sp_upgrade_exec as u
    a = u.a
    reject_rewrites(u.ROOT)
    root = Path(os.fsdecode(git('rev-parse', '--show-toplevel').strip())).resolve()
    a.need('execution_root', str(root), str(u.ROOT.resolve()))
    flags = git('ls-files', '-v', '-z').split(b'\0')
    a.need('execution_index_flags', [os.fsdecode(row) for row in flags
                                    if row and (chr(row[0]).islower() or row[:1] == b'S')], [])
    a.need('execution_head', git('rev-parse', 'HEAD').decode().strip(), commit)
    a.need('execution_clean_tree', git('status', '--porcelain', '--untracked-files=all').decode(), '')


def module_gates(commit):
    import sp_upgrade_exec as u
    a = u.a
    root = u.ROOT.resolve()
    tracked = set(git('ls-tree', '-r', '--name-only', '-z', commit).split(b'\0'))
    for filename in sorted(tracked):
        relative = Path(os.fsdecode(filename))
        if relative.suffix != '.py' or relative.parts[:2] not in (
                ('script', 'a3a'), ('script', 'upgrade')):
            continue
        if relative.stem in sys.modules:
            module = sys.modules[relative.stem]
            origin = getattr(module, '__file__', None)
            a.need('execution_module_origin',
                   bool(origin) and Path(origin).resolve() == (root / relative).resolve(), True)
    for module in tuple(sys.modules.values()):
        filename = getattr(module, '__file__', None)
        if not filename:
            continue
        path = Path(filename).resolve()
        if not path.is_relative_to(root):
            continue
        if path.suffix == '.pyc':
            try:
                path = Path(importlib.util.source_from_cache(str(path))).resolve()
            except ValueError:
                path = path.with_suffix('.py').resolve()
        relative = path.relative_to(root).as_posix() if path.is_relative_to(root) else ''
        a.need('execution_module_tracked', bool(relative) and path.suffix == '.py'
                 and path.is_file() and os.fsencode(relative) in tracked, True)
        a.need('execution_module_bytes', path.read_bytes() == git('show', commit + ':' + relative), True)


def check(commit):
    bootstrap(commit)
    tree_gates(commit)
    module_gates(commit)
    import sp_upgrade_exec as u
    return dict(git=git_evidence(u.ROOT))
