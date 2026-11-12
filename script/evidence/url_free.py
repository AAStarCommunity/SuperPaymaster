"""Reject evidence artifacts that contain a URL or a host-shaped string.

Executed runners call `assert_dir_url_free` on their output directory before
reporting success. A match never prints the matched text, only the file and
the pattern class, so a leaked endpoint is not echoed to stdout.
"""
from pathlib import Path
import re
import sys

# A hostname-shaped token is ignored when it is a path component (preceded by '/', '~', '.', '-'
# or a word character) or when its last label is a file extension (`x.t.sol:85` is a source line,
# `deploy-core.sh` a script). No TLD in the list may equal a tracked file extension (test_url_free
# checks the repository file list). Known limit: a bare internal hostname with no port and no
# common TLD (`rpc`, `rpc.internal`) is not detectable; the configured RPC itself is scrubbed verbatim.
_NOT_AFTER = r'(?<![\w/~.-])'
FILE_EXTENSIONS = {
    'sol', 'py', 'json', 'jsonl', 'ndjson', 'log', 'md', 'js', 'mjs', 'ts', 'txt', 'sh', 'diff', 'patch', 'yml',
    'yaml', 'toml', 'gz', 'hex', 'tsv', 'csv', 'err', 'out', 'stdout', 'stderr', 'sha256', 'spec', 'adoc', 'pdf',
    'svg', 'png', 'lock', 'yul', 'tex', 'cmd', 'raw', 'exit', 'start', 'end', 'load', 'calldata', 'chainid',
    'graphql', 'nix', 'example', 'bak', 'old', 'ref', 'rsp', 'pyc', 'redacted', 'superseded'}
HOST_PORT = re.compile(_NOT_AFTER + r'((?:[A-Za-z0-9-]+\.)+([A-Za-z0-9-]+)):\d{2,5}(?!\d)')
# Single-label host:port (`rpc:8545`, `anvil:8545`): any 4-5 digit port, or any port after a
# network-diagnostic word (`dial tcp node:443`). Source lines are dotted (`x.t.sol:85`) or short.
SINGLE_HOST_PORT = re.compile(_NOT_AFTER + r'[A-Za-z][A-Za-z0-9-]*:\d{4,5}(?!\d)')
DIAG_HOST_PORT = re.compile(r'(?i)\b(?:dial(?:\s+(?:tcp|udp))?|resolv\w*|connect\w*(?:\s+to)?|host|endpoint|peer|node|rpc|url)\s+[A-Za-z][A-Za-z0-9-]*:\d{2,5}(?!\d)')
IPV6 = re.compile(r'\[[0-9A-Fa-f:.]*:[0-9A-Fa-f:.]*\](?::\d{1,5})?|(?<![\w:])(?:[0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f]{0,4}(?![\w:])')
PATTERNS = {
    'scheme': re.compile(r'[A-Za-z][A-Za-z0-9+.-]*://'),
    'ipv4': re.compile(r'(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?::\d{1,5})?(?![\d.])'),
    'localhost-port': re.compile(r'\blocalhost:\d{1,5}\b', re.I),
    'hostname': re.compile(_NOT_AFTER + r'(?:[a-z0-9-]+\.)+(?:com|net|org|io|xyz|dev|app|cloud|co|ai|tech|network|gg)\b(?!\.\w)', re.I),
}


def _host_port(text):
    return any(m.group(2).lower() not in FILE_EXTENSIONS and not m.group(2).isdigit() for m in HOST_PORT.finditer(text))


def _ipv6(text):
    # Unbracketed: require '::' or seven colons so clock times (01:28:11) do not match.
    # An address always has a digit; `abc::def`-style identifiers do not.
    return any(m.group(0).startswith('[') or (any(c.isdigit() for c in m.group(0)) and ('::' in m.group(0) or m.group(0).count(':') == 7))
               for m in IPV6.finditer(text))


def url_like(text):
    """Return the pattern classes found in text (no matched substrings)."""
    found = {name for name, p in PATTERNS.items() if p.search(text)}
    if _host_port(text) or SINGLE_HOST_PORT.search(text) or DIAG_HOST_PORT.search(text):
        found.add('host-port')
    if _ipv6(text):
        found.add('ipv6')
    return sorted(found)


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
