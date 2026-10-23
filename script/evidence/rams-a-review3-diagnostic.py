#!/usr/bin/env python3
"""Offline checks for Route A evidence tooling; never invokes Forge or RPC."""
from pathlib import Path
import io
import json
import os
import re
import subprocess
import tempfile
from contextlib import redirect_stdout, redirect_stderr
from datetime import datetime
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
os.chdir(ROOT)


def run(args, **kwargs):
    return subprocess.run(args, check=True, text=True, capture_output=True, **kwargs)


cases = [
    ('Registry.sol:526:5', 'Registry.sol:526:5'),
    ('rpc.example.com:443/key', '<redacted-rpc-host>'),
    ('rpc.example.io/v2/secret', '<redacted-rpc-host>'),
    ('rpc.example.network/v3/secret', '<redacted-rpc-host>'),
    ('127.0.0.1:8545/key', '<redacted-rpc-host>'),
    ('[::1]:8545/key', '<redacted-rpc-host>'),
    ('2026-10-23T07:26:28Z', '2026-10-23T07:26:28Z'),
    *[(f'{scheme}://rpc.example.com/secret', '<redacted>') for scheme in ('http', 'https', 'ws', 'wss')],
]
for raw, expected in cases:
    actual = run(['bash', '-c', 'source script/evidence/rams-a-header.sh; rams_redact'], input=raw + '\n').stdout.rstrip('\n')
    assert actual == expected, (raw, actual, expected)
    print(f'PASS redaction: {raw} -> {actual}')

with tempfile.TemporaryDirectory(prefix='rams-review3-') as td:
    tmp = Path(td)
    target = 'contracts/test/rams/RamsARouteRehearsal.t.sol'
    base = run(['git', 'show', f'HEAD:{target}']).stdout
    definitions = Path('docs/design/aoa-balance-mode/data/rams-a/mutations-def4')
    for n in range(1, 19):
        definition = definitions / f'M{n}.diff'
        scratch = tmp / f'M{n}.sol'
        scratch.write_text(base)
        result = run(['patch', '--dry-run', '--batch', '--fuzz=0', str(scratch)], input=definition.read_text())
        assert 'fuzz' not in result.stdout and 'offset' not in result.stdout, result.stdout
        print(f'PASS HEAD patch --dry-run --batch --fuzz=0: M{n}')
        if n <= 15:
            old = run(['git', 'show', f'HEAD:{definition}']).stdout
            # Permit only unified hunk line-number changes (actual bytes also checked).
            normalize = lambda s: re.sub(r'^@@ .*? @@', '@@ @@', s, flags=re.M)
            assert normalize(old) == normalize(definition.read_text()), n
            assert old == definition.read_text(), n
    print('PASS M1-M15 regenerate byte-identically, including hunk line numbers')

    # Exercise the scanner with a deterministic transport stub, never a network call.
    scanner = Path('script/evidence/rams-a-inventory.sh').read_text().split("<<'PY'\n", 1)[1].rsplit('\nPY', 1)[0]
    output = tmp / 'inventory.json'
    calls = []

    def fake_urlopen(request, timeout):
        data = json.loads(request.data)
        calls.append(data)
        if data['method'] == 'eth_getCode':
            result = '0x' if data['params'][1] == hex(11151015) else '0x01'
        else:
            assert data['method'] == 'eth_getLogs'
            result = []
        return io.StringIO(json.dumps({'result': result}))

    env = {'RAMS_RPC_A': 'https://a.example.com', 'RAMS_RPC_C': 'https://c.example.org',
           'RAMS_LABEL_A': 'Provider A (operator supplied)', 'RAMS_LABEL_C': 'Provider C',
           'FROM_BLOCK': '11151016', 'FORK_BLOCK': '11151016'}
    with patch.dict(os.environ, env, clear=True), patch('sys.argv', ['scanner', str(output)]), patch('urllib.request.urlopen', fake_urlopen), redirect_stdout(io.StringIO()):
        exec(compile(scanner, 'inventory-inline', 'exec'), {})
    artifact = json.loads(output.read_text())
    assert artifact['endpointLabels'] == {'A': env['RAMS_LABEL_A'], 'C': env['RAMS_LABEL_C']}
    datetime.strptime(artifact['generatedUTC'], '%Y-%m-%dT%H:%M:%SZ')
    assert artifact['agree'] and len(calls) == 6
    assert 'https://' not in output.read_text()
    print('PASS inventory emits generatedUTC and operator-supplied labels (stubbed transport)')
    for label in ('A', 'C'):
        calls.clear()
        with patch.dict(os.environ, {**env, f'RAMS_LABEL_{label}': 'https://forbidden.example.com'}, clear=True), patch('sys.argv', ['scanner', str(tmp / 'rejected.json')]), patch('urllib.request.urlopen', fake_urlopen), redirect_stderr(io.StringIO()):
            try:
                exec(compile(scanner, 'inventory-inline', 'exec'), {})
            except SystemExit as error:
                assert error.code == 1
            else:
                raise AssertionError('URL label accepted')
        assert not calls and not (tmp / 'rejected.json').exists()
        print(f'PASS RAMS_LABEL_{label} rejects :// before transport or output')

# The current edit-only tree is deliberately dirty; the runner must refuse before Forge.
result = subprocess.run(['bash', 'script/evidence/rams-a-mutations-inplace.sh'], text=True, capture_output=True)
assert result.returncode == 1 and 'protected source/test/config paths differ from HEAD' in result.stderr, result
print('PASS mutation runner refuses dirty protected paths before Forge')
