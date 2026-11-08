"""Executor source and checkout checks for accidental dirty/altered execution.

This checks files, not in-memory bytecode, and is not an OS security sandbox.
"""
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import sp_upgrade_exec as u
from sp_upgrade_exec import a


def git(*args):
    env = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
    env['GIT_CONFIG_NOSYSTEM'] = '1'
    return subprocess.run(['git', *args], cwd=u.ROOT, env=env,
                          capture_output=True, check=True).stdout


def tree_gates(commit):
    root = Path(os.fsdecode(git('rev-parse', '--show-toplevel').strip())).resolve()
    a.need('execution_root', str(root), str(u.ROOT.resolve()))
    flags = git('ls-files', '-v', '-z').split(b'\0')
    a.need('execution_index_flags', [os.fsdecode(row) for row in flags
                                    if row and (chr(row[0]).islower() or row[:1] == b'S')], [])
    a.need('execution_head', git('rev-parse', 'HEAD').decode().strip(), commit)
    a.need('execution_clean_tree', git('status', '--porcelain', '--untracked-files=all').decode(), '')


def module_gates(commit):
    root = u.ROOT.resolve()
    tracked = set(git('ls-tree', '-r', '--name-only', '-z', commit).split(b'\0'))
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
    tree_gates(commit)
    module_gates(commit)
