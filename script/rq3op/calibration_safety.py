"""Shared calibration diagnostics and child-fork identity checks."""
import re
import socket
from pathlib import Path


def redact(value, *, opaque=False):
    # Untrusted upstream diagnostics may contain bare keys or file contents, not just URLs.
    if opaque:
        return '<upstream details redacted>'
    return re.sub(r'(?i)(?:https?|wss?)://[^\s\"\'<>]+', '<redacted-url>', str(value))


def read_upstream(path):
    try:
        return Path(path).read_text().strip()
    except Exception:
        raise SystemExit('STOP cannot read upstream file; contents redacted') from None


def choose_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


def require_fork(proc, rpc, pin):
    def alive():
        if proc is None or proc.poll() is not None:
            raise SystemExit('STOP child anvil is not alive')
    alive()
    try:
        client = rpc('web3_clientVersion', [])
        if not isinstance(client, str) or not client.lower().startswith('anvil'):
            raise ValueError('not anvil')
        try:
            info = rpc('anvil_nodeInfo', [])
            block = info['forkConfig']['forkBlockNumber']
        except Exception:
            info = rpc('anvil_metadata', [])
            block = info['forkedNetwork']['forkBlockNumber']
        observed = int(block, 0) if isinstance(block, str) else block
        if pin is None or isinstance(observed, bool) or observed != pin:
            raise ValueError('fork pin mismatch')
    except Exception:
        raise SystemExit('STOP endpoint is not anvil at requested fork pin') from None
    alive()
