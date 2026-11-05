#!/usr/bin/env python3
"""Q5 (DSR 2026-11-05): does evm_revert restore the block timestamp after a control's wait_until?

Several manifest controls call sp_upgrade_exec.wait_until (evm_setNextBlockTimestamp + evm_mine) inside an
evm_snapshot and then evm_revert. Main-path executionTimestamps are only evidence if the revert also undoes
the time jump. This measures it on the pinned engine, offline (local chain) and on a fork at the pin.

Usage (repository root):
  python3 -B script/evidence/q5_snapshot_timestamp.py --engine DIR --mode local
  python3 -B script/evidence/q5_snapshot_timestamp.py --engine DIR --mode fork --rpc-file FILE --block N
Scope (trust root): main-path executionTimestamps are explicit (latest header + 1, set with
evm_setNextBlockTimestamp right before the step is mined) and asserted by manifest_timestamp,
B4_timestamp (manifest_exec) and mined_execution_timestamp (sp_upgrade_exec). What they need from the engine is (a) evm_revert restores the latest header,
(b) an explicit timestamp below the control's jump is accepted afterwards; both are checked for single and
nested snapshots. The auto-mined checks additionally show the jump is not inherited and the offset is not
restored too low, within each comparison's wall-clock window.
Each auto-mined comparison is against a no-jump baseline mined right before that segment's jump, within a
window equal to the wall time measured between the two blocks (plus SLACK). The blocks are at least SEPARATION
apart, so the parent + 1 clamp cannot mask an offset restored too low. A correct engine passes as long as each
compared segment takes less than DAY/2 of wall time; a window of DAY/2 or more is undecidable and FAILs
(fail-closed), whatever the endpoint latency. A leaked jump or lost offset (~DAY) is outside every window.

The RPC URL is read from FILE and only ever held by this process: anvil forks from a local relay
(127.0.0.1), relay failures return a bare 502, JSON-RPC errors are reported by code only and transport errors
by exception type only. Engine stdout/stderr are discarded; the only engine text kept is the first line of
`anvil --version` (the engine identity, checked against a3a_exec.COMMIT).
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
# Seconds added on each side of a wall-clock window: integer block timestamps and the parent+1 clamp.
SLACK = 2
# Minimum wall time between two compared blocks. The engine clamps a block to parent + 1, which would hide a
# clock offset restored too low; forcing SEPARATION > 2 * SLACK + 1 makes the window's lower bound exceed what
# the clamp alone can produce.
SEPARATION = 6
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
        try:
            out = json.load(urllib.request.urlopen(req, timeout=120))
        except Exception as e:
            # Transport errors (e.g. an HTTP reason phrase) are engine content too: type name only.
            raise RuntimeError(f'{method}: transport error {type(e).__name__}') from None
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


def run(rpc, clock=time.time, sleep=time.sleep):
    checks, n0, t0 = [], *latest(rpc)

    def check(name, observed, expected, **extra):
        checks.append(dict(name=name, observed=observed, expected=expected, ok=observed == expected, **extra))

    def apart(since):
        if clock() < since + SEPARATION:
            sleep(since + SEPARATION - clock())

    def sample(measure, after=None):
        # One auto-timestamped block in its own snapshot, bracketed by wall-clock reads: its timestamp was taken
        # by the engine clock somewhere in [w0, w1]. `after`: the baseline it will be compared against.
        if after is not None:
            apart(after['wall'][1])
        s = rpc('evm_snapshot', [])
        w0 = clock()
        d = measure(rpc, t0)
        w1 = clock()
        restore(rpc, s)
        return dict(delta=d, wall=(w0, w1))

    def follows(name, after, base):
        # Same engine clock, no inherited jump: the two blocks are apart by the wall time between them, within
        # SLACK for integer timestamps and the parent+1 clamp. The window is as wide as the run actually took,
        # never a fixed budget, so a slow endpoint cannot fail it and a leaked jump (~DAY) cannot pass it.
        lo = after['wall'][0] - base['wall'][1] - SLACK
        hi = after['wall'][1] - base['wall'][0] + SLACK
        gap = after['delta'] - base['delta']
        check(name, lo <= gap <= hi and hi - lo < DAY // 2, True, gap=gap, window=[lo, hi])

    # Per segment, the baseline is mined right before the segment's jump (never after it: a leaked jump would
    # move a post-jump baseline too) and the comparison window covers only that segment.
    # 1. Single snapshot: jump 10 days, revert.
    base_mine, base_tx = sample(mined_delta), sample(tx_delta)
    s = rpc('evm_snapshot', [])
    wait_until(rpc, t0 + 10 * DAY)
    check('single_jumped', latest(rpc)[1], t0 + 10 * DAY)
    check('single_revert', reverted(rpc, s), True)
    check('single_latest_restored', latest(rpc), (n0, t0))
    after_mine, after_tx = sample(mined_delta, base_mine), sample(tx_delta, base_tx)
    # Neither the jump inherited nor the clock left at the jump's offset (behind, when the pin is older than wall time).
    follows('single_next_block_not_jumped', after_mine, base_mine)
    follows('single_next_tx_block_not_jumped', after_tx, base_tx)
    # Main path sets an explicit executionTimestamp earlier than the control's jump; it must be accepted.
    s = rpc('evm_snapshot', [])
    rpc('evm_setNextBlockTimestamp', [t0 + 100])
    rpc('evm_mine', [])
    check('single_explicit_earlier_ts', latest(rpc)[1], t0 + 100)
    restore(rpc, s)

    # 2. Nested snapshots (controls run inside an outer snapshot).
    nested_base_mine, nested_base_tx = sample(mined_delta), sample(tx_delta)
    outer = rpc('evm_snapshot', [])
    wait_until(rpc, t0 + DAY)
    inner = rpc('evm_snapshot', [])
    wait_until(rpc, t0 + 6 * DAY)
    check('nested_inner_revert', reverted(rpc, inner), True)
    check('nested_inner_restored_ts', latest(rpc)[1], t0 + DAY)
    check('nested_outer_revert', reverted(rpc, outer), True)
    check('nested_outer_restored', latest(rpc), (n0, t0))
    # Auto-timestamped blocks after the nested reverts must not inherit either jump (header restore alone is not enough).
    nested_mine, nested_tx = sample(mined_delta, nested_base_mine), sample(tx_delta, nested_base_tx)
    follows('nested_next_block_not_jumped', nested_mine, nested_base_mine)
    follows('nested_next_tx_block_not_jumped', nested_tx, nested_base_tx)
    # Inner-only revert: the next block follows the outer jump (+1 day plus the wall time since it), not the inner one (+6 days).
    outer = rpc('evm_snapshot', [])
    w0 = clock()
    wait_until(rpc, t0 + DAY)
    w1 = clock()
    inner = rpc('evm_snapshot', [])
    wait_until(rpc, t0 + 6 * DAY)
    restore(rpc, inner)
    # Separated from the outer jump, so an outer offset lost on the inner revert (clamped to parent + 1) is below lo.
    apart(w1)
    w2 = clock()
    inner_mine = mined_delta(rpc, t0)
    lo, hi = w2 - w1 - SLACK, clock() - w0 + SLACK
    check('inner_revert_next_block_follows_outer', lo <= inner_mine - DAY <= hi and hi - lo < DAY // 2, True,
          gap=inner_mine - DAY, window=[lo, hi])
    check('inner_outer_revert', reverted(rpc, outer), True)
    s = rpc('evm_snapshot', [])
    rpc('evm_setNextBlockTimestamp', [t0 + 50])
    rpc('evm_mine', [])
    check('nested_explicit_earlier_ts', latest(rpc)[1], t0 + 50)
    restore(rpc, s)
    check('final_state', latest(rpc), (n0, t0))
    return dict(slackSeconds=SLACK, separationSeconds=SEPARATION, pinBlock=n0, pinTimestamp=t0,
                baselineMineDelta=base_mine['delta'], baselineTxDelta=base_tx['delta'],
                afterJumpMineDelta=after_mine['delta'], afterJumpTxDelta=after_tx['delta'],
                nestedBaselineMineDelta=nested_base_mine['delta'], nestedBaselineTxDelta=nested_base_tx['delta'],
                nestedMineDelta=nested_mine['delta'], nestedTxDelta=nested_tx['delta'],
                innerRevertMineDelta=inner_mine, checks=checks)


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
