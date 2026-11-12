"""Reject evidence artifacts that contain a URL or a host-shaped string.

Executed runners call `assert_dir_url_free` on their output directory before
reporting success. A match never prints the matched text, only the file and
the pattern class, so a leaked endpoint is not echoed to stdout.
"""
from pathlib import Path
import re
import sys

PATTERNS = {
    'scheme': re.compile(r'[A-Za-z][A-Za-z0-9+.-]*://'),
    'ipv4': re.compile(r'(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?::\d{1,5})?(?![\d.])'),
    'localhost-port': re.compile(r'\blocalhost:\d{1,5}\b', re.I),
    'hostname': re.compile(r'\b(?:[a-z0-9-]+\.)+(?:com|net|org|io|xyz|dev|app|cloud|co|ai|tech|network|gg|sh)\b(?!\.\w)', re.I),
}


def url_like(text):
    """Return the pattern classes found in text (no matched substrings)."""
    return sorted(name for name, p in PATTERNS.items() if p.search(text))


def assert_dir_url_free(directory):
    hits = []
    # Top-level evidence files only: forge out/ and cache/ subdirectories hold solc metadata,
    # whose source URLs (bzz-raw://, dweb:) are not evidence and not endpoints.
    for path in sorted(Path(directory).iterdir()):
        if path.is_file():
            found = url_like(path.read_text(errors='replace'))
            if found:
                hits.append(f'{path.name}: {",".join(found)}')
    if hits:
        raise ValueError('URL-like content in evidence: ' + '; '.join(hits))


def main(paths):
    bad = 0
    for arg in paths:
        p = Path(arg)
        try:
            if p.is_dir():
                assert_dir_url_free(p)
            elif url_like(p.read_text(errors='replace')):
                raise ValueError(f'URL-like content in evidence: {p.name}: ' + ','.join(url_like(p.read_text(errors='replace'))))
        except ValueError as exc:
            print(exc, file=sys.stderr)
            bad = 1
    return bad


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
