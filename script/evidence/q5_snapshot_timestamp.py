#!/usr/bin/env python3
"""Q5 (DSR 2026-11-05): does evm_revert restore the block timestamp after a control's wait_until?

Several manifest controls call sp_upgrade_exec.wait_until (evm_setNextBlockTimestamp + evm_mine) inside an
evm_snapshot and then evm_revert. Main-path executionTimestamps are only evidence if the revert also undoes
the time jump. This measures it on the pinned engine, offline (local chain) and on a fork at the pin.

Usage (repository root):
  python3 -B script/evidence/q5_snapshot_timestamp.py --engine DIR --mode local
  python3 -B script/evidence/q5_snapshot_timestamp.py --engine DIR --mode fork --rpc-file FILE --block N
Scope (trust root): main-path executionTimestamps are explicit (latest header + 1, set with
evm_setNextBlockTimestamp right before the step is mined) and asserted by manifest_timestamp /
mined_execution_timestamp. What they need from the engine is (a) evm_revert restores the latest header,
(b) an explicit timestamp below the control's jump is accepted afterwards; both are checked for single and
nested snapshots. The auto-mined checks additionally show the jump is not inherited; they do not pin the exact
clock offset (an offset restored too low is masked by header clamping and cannot move an explicit timestamp).
A wall-clock step larger than TOLERANCE during the run makes it FAIL (fail-closed).

The RPC URL is read from FILE and only ever held by this process: anvil forks from a local relay
(127.0.0.1), relay failures return a bare 502, and JSON-RPC errors are reported by code only. Engine output is discarded.
"""
import sys
sys.dont_write_bytecode = True
import argparse
import http.server
import json
import re
import socket
import subprocess
import threading
import time
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'a3a'))  # script/a3a
import a3a_exec  # noqa: E402  (COMMIT only)

DAY = 86400
# Bound (both directions) on wall-clock/RPC latency between the no-jump baseline block and the post-revert block.
TOLERANCE = 60
SENDER = '0x000000000000000000000000000000000000c0de'


def relay(upstream):
    class Relay(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            body = self.rfile.read(int(self.headers['content-length']))
            try:
                req = urllib.request.Request(upstream, body, {'content-type': 'application/json'})
                data = urllib.request.urlopen(req, timeout=60).read()
            except Exception:
                self.send_response(502)
                self.end_headers()
                return
            self.send_response(200)
            self.send_header('content-type', 'application/json')
            self.send_header('content-length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, *args):
            pass
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Relay)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


class Local:
    def __init__(self, port):
        self.url, self.n = f'http://127.0.0.1:{port}', 0

    def __call__(self, method, params):
        self.n += 1
        body = json.dumps(dict(jsonrpc='2.0', id=self.n, method=method, params=params)).encode()
        req = urllib.request.Request(self.url, body, {'content-type': 'application/json'})
        out = json.load(urllib.request.urlopen(req, timeout=120))
        if 'error' in out:
            # Upstream error text can carry credentials in any form; report the code only.
            code = out['error'].get('code') if isinstance(out['error'], dict) else None
            code = code if type(code) is int else 'non-integer'
            raise RuntimeError(f'{method}: JSON-RPC error code {code}')
        return out['result']


def qty(value):
    # Never echo engine/upstream content in an error.
    if not (isinstance(value, str) and re.fullmatch(r'0x[0-9a-fA-F]{1,64}', value)):
        raise RuntimeError('malformed quantity from engine')
    return int(value, 16)


def reverted(rpc, snap):
    # Recorded as a bool only; a revert that does not return true also stops unchecked reverts below.
    return rpc('evm_revert', [snap]) is True


def restore(rpc, snap):
    if not reverted(rpc, snap):
        raise RuntimeError('evm_revert did not return true')


def latest(rpc):
    b = rpc('eth_getBlockByNumber', ['latest', False])
    return qty(b['number']), qty(b['timestamp'])


def wait_until(rpc, timestamp):
    # Same calls as sp_upgrade_exec.wait_until.
    if latest(rpc)[1] < timestamp:
        rpc('evm_setNextBlockTimestamp', [timestamp])
        rpc('evm_mine', [])


def mined_delta(rpc, t0):
    rpc('evm_mine', [])
    return latest(rpc)[1] - t0


def tx_delta(rpc, t0):
    rpc('anvil_setBalance', [SENDER, hex(10**18)])
    rpc('anvil_impersonateAccount', [SENDER])
    h = rpc('eth_sendTransaction', [dict(**{'from': SENDER}, to=SENDER, value='0x0')])
    for _ in range(100):
        r = rpc('eth_getTransactionReceipt', [h])
        if r:
            break
        time.sleep(.1)
    else:
        raise RuntimeError('no receipt')
    b = rpc('eth_getBlockByNumber', [r['blockNumber'], False])
    return qty(b['timestamp']) - t0


def run(rpc):
    checks, n0, t0 = [], *latest(rpc)

    def check(name, observed, expected):
        checks.append(dict(name=name, observed=observed, expected=expected, ok=observed == expected))

    # Baseline: what the next block looks like with no time jump (wall clock still advances).
    s = rpc('evm_snapshot', [])
    base_mine = mined_delta(rpc, t0)
    check('baseline_revert', reverted(rpc, s), True)
    s = rpc('evm_snapshot', [])
    base_tx = tx_delta(rpc, t0)
    check('baseline_tx_revert', reverted(rpc, s), True)

    # 1. Single snapshot: jump 10 days, revert.
    s = rpc('evm_snapshot', [])
    wait_until(rpc, t0 + 10 * DAY)
    check('single_jumped', latest(rpc)[1], t0 + 10 * DAY)
    check('single_revert', reverted(rpc, s), True)
    check('single_latest_restored', latest(rpc), (n0, t0))
    s = rpc('evm_snapshot', [])
    after_mine = mined_delta(rpc, t0)
    restore(rpc, s)
    s = rpc('evm_snapshot', [])
    after_tx = tx_delta(rpc, t0)
    restore(rpc, s)
    # The next auto-timestamped block must be within TOLERANCE s (either way) of the no-jump baseline: neither the
    # jump inherited nor the clock left at the jump's offset when the pin is older than wall time.
    check('single_next_block_not_jumped', abs(after_mine - base_mine) < TOLERANCE, True)
    check('single_next_tx_block_not_jumped', abs(after_tx - base_tx) < TOLERANCE, True)
    # Main path sets an explicit executionTimestamp earlier than the control's jump; it must be accepted.
    s = rpc('evm_snapshot', [])
    rpc('evm_setNextBlockTimestamp', [t0 + 100])
    rpc('evm_mine', [])
    check('single_explicit_earlier_ts', latest(rpc)[1], t0 + 100)
    restore(rpc, s)

    # 2. Nested snapshots (controls run inside an outer snapshot).
    outer = rpc('evm_snapshot', [])
    wait_until(rpc, t0 + DAY)
    inner = rpc('evm_snapshot', [])
    wait_until(rpc, t0 + 6 * DAY)
    check('nested_inner_revert', reverted(rpc, inner), True)
    check('nested_inner_restored_ts', latest(rpc)[1], t0 + DAY)
    check('nested_outer_revert', reverted(rpc, outer), True)
    check('nested_outer_restored', latest(rpc), (n0, t0))
    # Auto-timestamped blocks after the nested reverts must not inherit either jump (header restore alone is not enough).
    s = rpc('evm_snapshot', [])
    nested_mine = mined_delta(rpc, t0)
    restore(rpc, s)
    s = rpc('evm_snapshot', [])
    nested_tx = tx_delta(rpc, t0)
    restore(rpc, s)
    check('nested_next_block_not_jumped', abs(nested_mine - base_mine) < TOLERANCE, True)
    check('nested_next_tx_block_not_jumped', abs(nested_tx - base_tx) < TOLERANCE, True)
    # Inner-only revert: the next block follows the outer jump (+1 day), not the inner one (+6 days).
    outer = rpc('evm_snapshot', [])
    wait_until(rpc, t0 + DAY)
    inner = rpc('evm_snapshot', [])
    wait_until(rpc, t0 + 6 * DAY)
    restore(rpc, inner)
    inner_mine = mined_delta(rpc, t0)
    check('inner_revert_next_block_follows_outer', 0 < inner_mine - DAY < TOLERANCE, True)
    check('inner_outer_revert', reverted(rpc, outer), True)
    s = rpc('evm_snapshot', [])
    rpc('evm_setNextBlockTimestamp', [t0 + 50])
    rpc('evm_mine', [])
    check('nested_explicit_earlier_ts', latest(rpc)[1], t0 + 50)
    restore(rpc, s)
    check('final_state', latest(rpc), (n0, t0))
    return dict(toleranceSeconds=TOLERANCE, pinBlock=n0, pinTimestamp=t0, baselineMineDelta=base_mine, baselineTxDelta=base_tx,
                afterJumpMineDelta=after_mine, afterJumpTxDelta=after_tx, nestedMineDelta=nested_mine,
                nestedTxDelta=nested_tx, innerRevertMineDelta=inner_mine, checks=checks)


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--engine', type=Path, required=True)
    p.add_argument('--mode', choices=('local', 'fork'), required=True)
    p.add_argument('--rpc-file', type=Path)
    p.add_argument('--block', type=int)
    args = p.parse_args()
    version = subprocess.run([str(args.engine / 'anvil'), '--version'], capture_output=True, text=True).stdout
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        port = s.getsockname()[1]
    cmd = [str(args.engine / 'anvil'), '--hardfork', 'amsterdam', '--order', 'fifo', '--host', '127.0.0.1',
           '--port', str(port), '--silent']
    server = None
    if args.mode == 'fork':
        server = relay(args.rpc_file.read_text().strip())
        cmd += ['--fork-url', f'http://127.0.0.1:{server.server_port}', '--fork-block-number', str(args.block), '--chain-id', '11155111',
                '--no-fork-node-info', '--accounts', '0']
    proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        rpc = Local(port)
        for _ in range(300):
            try:
                rpc('eth_chainId', [])
                break
            except Exception:
                if proc.poll() is not None:
                    sys.exit('engine exited')
                time.sleep(.1)
        out = dict(mode=args.mode, engine=version.strip().splitlines()[0],
                   engineCommitPinned=a3a_exec.COMMIT in version, **run(rpc))
        if args.mode == 'fork':
            out['forkBlockRequested'] = args.block
    finally:
        proc.terminate()
        proc.wait(timeout=10)
        if server:
            server.shutdown()
    print(json.dumps(out, indent=1))
    ok = out['engineCommitPinned'] and all(c['ok'] for c in out['checks'])
    print('Q5', 'PASS' if ok else 'FAIL')
    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()
