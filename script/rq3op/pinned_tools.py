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
            found = os.environ.get('CAST_1_7_1') if name == 'cast' else shutil.which(name)
            if name == 'cast' and (not found or not Path(found).is_file() or not os.access(found, os.X_OK)):
                raise RuntimeError('STOP CAST_1_7_1 must name an executable')
            if not found:
                raise RuntimeError('missing required tool: '+name)
            paths[name] = str(Path(found).absolute())
        self.env = {'PATH': ':'.join(dict.fromkeys([*(str(Path(p).parent) for p in (paths['cast'], paths['git'])), '/usr/bin', '/bin'])),
                    'LC_ALL': 'C', 'CAST_1_7_1': paths['cast']}
        for key in ('DEPLOYLIVE_ENDPOINT_PROVIDER', 'DEPLOYLIVE_EVIDENCE_DIR',
                    'DEPLOYLIVE_SECOND_RPC_FILE', 'DEPLOYLIVE_SECOND_ENDPOINT_PROVIDER',
                    'DEPLOYLIVE_LOCAL_EVIDENCE', 'DEFAULT_ARTIFACTS_OUT',
                    'DEPLOYLIVE_SNAPSHOT_BLOCK_HASH', 'ETH_RPC_URL', 'DEPLOYLIVE_EXPECTED_CHAIN_ID'):
            if key in os.environ: self.env[key] = os.environ[key]
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
        overrides = kwargs.get('env', {})
        kwargs['env'] = dict(self.env)
        # Only explicit per-call endpoint/pin/expected-chain overrides cross the sanitized boundary.
        for key in ('ETH_RPC_URL', 'DEPLOYLIVE_SNAPSHOT_BLOCK_HASH', 'DEPLOYLIVE_EXPECTED_CHAIN_ID'):
            if key in overrides: kwargs['env'][key] = overrides[key]
        return self.runner(command, *args, **kwargs)

    @contextmanager
    def active(self):
        previous = subprocess.run
        subprocess.run = self.run
        try:
            yield self
        finally:
            subprocess.run = previous
