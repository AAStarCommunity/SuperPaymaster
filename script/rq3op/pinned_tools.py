"""Resolve operator tools once; exclude ambient subprocess configuration."""
import os
import hashlib
import shutil
import subprocess
from contextlib import contextmanager
from pathlib import Path

class PinnedTools:
    def __init__(self):
        self.runner = subprocess.run
        paths = {}
        for name in ('git', 'cast'):
            found = shutil.which(name)
            if not found:
                raise RuntimeError('missing required tool: '+name)
            paths[name] = str(Path(found).resolve())
        self.env = {'PATH': ':'.join(dict.fromkeys([*(str(Path(p).parent) for p in paths.values()), '/usr/bin', '/bin'])),
                    'LC_ALL': 'C'}
        if 'DEPLOYLIVE_ENDPOINT_PROVIDER' in os.environ:
            self.env['DEPLOYLIVE_ENDPOINT_PROVIDER'] = os.environ['DEPLOYLIVE_ENDPOINT_PROVIDER']
        self.records = {}
        for name, path in paths.items():
            result = self.runner([path, '--version'], env=self.env, capture_output=True, text=True, check=True)
            self.records[name] = dict(path=path, version=result.stdout.strip(),
                                      sha256=hashlib.sha256(Path(path).read_bytes()).hexdigest())

    def run(self, command, *args, **kwargs):
        command = list(command)
        name = Path(command[0]).name
        if name in self.records:
            command[0] = self.records[name]['path']
        kwargs['env'] = dict(self.env)
        return self.runner(command, *args, **kwargs)

    @contextmanager
    def active(self):
        previous = subprocess.run
        subprocess.run = self.run
        try:
            yield self
        finally:
            subprocess.run = previous
