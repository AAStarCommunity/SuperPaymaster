"""Test-only clean checkout responses; all other subprocesses retain their target."""
import subprocess
from unittest.mock import patch


def clean_checkout(test, commit):
    original = subprocess.run

    def run(command, *args, **kwargs):
        if command == ['git', 'rev-parse', 'HEAD']:
            return subprocess.CompletedProcess(command, 0, commit+'\n', '')
        if command == ['git', 'status', '--porcelain', '--untracked-files=all']:
            return subprocess.CompletedProcess(command, 0, '', '')
        return original(command, *args, **kwargs)

    fixture = patch.object(subprocess, 'run', side_effect=run)
    fixture.start()
    test.addCleanup(fixture.stop)
