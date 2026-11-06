"""Scoped execution read barrier; plan construction must finish before entry."""
import builtins
from contextlib import contextmanager
import io
import json
import os
from pathlib import Path
import shlex
import stat
import subprocess
import sp_upgrade_exec as u


def reviewed_allowlist():
    data = json.loads(Path(__file__).with_name('execution_read_allowlist.json').read_text())
    u.a.need('execution_allowlist_schema', set(data), {'paths', 'reason'})
    result = set()
    for relative, reason in data['paths'].items():
        path = Path(relative)
        u.a.need('execution_allowlist_entry', bool(reason.strip()) and not path.is_absolute()
                 and '..' not in path.parts, True)
        result.add((u.ROOT / path).resolve())
    return frozenset(result)


def require_read(allowed, description):
    if not allowed:
        raise u.a.Gate('execution_repo_read', description, 'reviewed execution read')


@contextmanager
def guard(allowlist):
    root = u.ROOT.resolve()
    original_open, original_io = builtins.open, io.open
    original_text, original_bytes, original_run = Path.read_text, Path.read_bytes, subprocess.run

    def check_path(file, mode='r'):
        if isinstance(file, int):
            # Subprocess stdout/stderr pipes are not repository files. Regular
            # read descriptors have no reviewed path identity and stay refused.
            kind = os.fstat(file).st_mode
            require_read(stat.S_ISFIFO(kind) or stat.S_ISSOCK(kind)
                         or not ('r' in mode or '+' in mode), 'file descriptor')
            return
        if 'r' not in mode and '+' not in mode:
            return
        path = Path(os.path.abspath(os.fsdecode(file)))
        # Check every resolved prefix: an in-repo symlink may point outside,
        # including when the repo itself is reached through a symlink alias.
        paths = {path, path.resolve(), *(parent.resolve() / path.relative_to(parent)
                                      for parent in path.parents)}
        require_read(all(not p.is_relative_to(root) or p in allowlist for p in paths), str(path))

    def opened(file, mode='r', *args, **kwargs):
        check_path(file, mode)
        return original_open(file, mode, *args, **kwargs)

    def io_opened(file, mode='r', *args, **kwargs):
        check_path(file, mode)
        return original_io(file, mode, *args, **kwargs)

    def read_text(path, *args, **kwargs):
        check_path(path)
        return original_text(path, *args, **kwargs)

    def read_bytes(path, *args, **kwargs):
        check_path(path)
        return original_bytes(path, *args, **kwargs)

    def run(*args, **kwargs):
        command = args[0] if args else kwargs['args']
        words = shlex.split(os.fsdecode(command)) if isinstance(command, (str, bytes)) else command
        # No git operation is needed during execution. Reject even -C/--git-dir
        # and shell forms, independently of cwd (worktree gitdirs may be external).
        require_read(not any(Path(os.fsdecode(word)).name == 'git' for word in words), str(command))
        return original_run(*args, **kwargs)

    try:
        builtins.open, io.open = opened, io_opened
        Path.read_text, Path.read_bytes, subprocess.run = read_text, read_bytes, run
        yield
    finally:
        builtins.open, io.open = original_open, original_io
        Path.read_text, Path.read_bytes, subprocess.run = original_text, original_bytes, original_run
