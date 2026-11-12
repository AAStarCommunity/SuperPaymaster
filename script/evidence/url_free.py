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
    'graphql', 'nix', 'rs', 'example', 'bak', 'old', 'ref', 'rsp', 'pyc', 'redacted', 'superseded'}
# Ports are 1-5 digits; a port must not run into a word character (`rpc:0x...` is not one).
# Labels allow '_' (container/local DNS) and a root dot before the port (`rpc.internal.:8545`).
_PORT = r':\d{1,5}(?![\w])'
HOST_PORT = re.compile(_NOT_AFTER + r'((?:[A-Za-z0-9_-]+\.)+([A-Za-z0-9_-]+))\.?' + _PORT)
# Single-label host:port (`rpc:443`, `"rpc:443"`, `(rpc:80)`, `rpc_node:8545`, `rpc.:8545`).
SINGLE_HOST_PORT = re.compile(_NOT_AFTER + r'[A-Za-z][A-Za-z0-9_-]*\.?' + _PORT)
DIAG_HOST_PORT = re.compile(r'(?i)\b(?:dial(?:\s+(?:tcp|udp))?|resolv\w*|connect\w*(?:\s+to)?|host|endpoint|peer|node|rpc|url)\s+[A-Za-z][A-Za-z0-9_-]*' + _PORT)
IPV6 = re.compile(r'\[[0-9A-Fa-f.]*:[0-9A-Fa-f.]*:[0-9A-Fa-f:.]*(?:%\w+)?\](?::\d{1,5})?|(?<![\w:])(?:[0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f]{0,4}(?![\w:])')
# Bracketed IPv6 needs two colons (`[:8]` is a Python slice).
# All-hex unbracketed IPv6 (`abcd::cafe`, `::`) only after a network word, because `abc::def`
# is also a Rust path; outside such context a digit is required (see _ipv6).
IPV6_IN_CONTEXT = re.compile(r'(?i)(?:caused by:|connect\w*(?:\s+to)?|address|addr|endpoint|peer|node|rpc|url)\s*["\'(\[]?\s*'
                             r'((?:[0-9a-f]{0,4}:){2,7}[0-9a-f]{0,4})(?![\w:])')
PATTERNS = {
    'scheme': re.compile(r'[A-Za-z][A-Za-z0-9+.-]*://'),
    'ipv4': re.compile(r'(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?::\d{1,5})?(?![\d.])'),
    'localhost-port': re.compile(r'\blocalhost:\d{1,5}\b', re.I),
    'hostname': re.compile(_NOT_AFTER + r'(?:[a-z0-9-]+\.)+(?:com|net|org|io|xyz|dev|app|cloud|co|ai|tech|network|gg)\b(?!\.\w)', re.I),
}


def _host_port(text):
    return any(m.group(2).lower() not in FILE_EXTENSIONS for m in HOST_PORT.finditer(text))


def _ipv6(text):
    # Unbracketed: require '::' or seven colons so clock times (01:28:11) do not match, and a
    # decimal digit so Rust paths (`abc::def`) do not; all-hex addresses need network context.
    def shaped(t):
        return '::' in t or t.count(':') == 7
    return (any(m.group(0).startswith('[') or (any(c.isdigit() for c in m.group(0)) and shaped(m.group(0)))
                for m in IPV6.finditer(text))
            or any(shaped(m.group(1)) for m in IPV6_IN_CONTEXT.finditer(text)))


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
