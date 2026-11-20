"""Shared stable Cast startup identity for the driver and checker."""
import re
import subprocess

CAST_VERSION_PATTERN = re.compile(r'^cast Version: 1\.7\.1(?:-stable)?(?:[ \t].*)?$', re.M)


def stable_cast(binary):
    try:
        result = subprocess.run([binary, '--version'], capture_output=True, text=True, timeout=10)
        return result.returncode == 0 and bool(CAST_VERSION_PATTERN.search(result.stdout))
    except (OSError, subprocess.SubprocessError, UnicodeError):
        return False
