#!/usr/bin/env python3
"""Q5 (DSR 2026-11-05): does evm_revert restore the block timestamp after a control's wait_until?

Several manifest controls call sp_upgrade_exec.wait_until (evm_setNextBlockTimestamp + evm_mine) inside an
evm_snapshot and then evm_revert. Main-path executionTimestamps are only evidence if the revert also undoes
the time jump. This measures it on the pinned engine, offline (local chain) and on a fork at the pin.

Usage (repository root):
  python3 -B script/evidence/q5_snapshot_timestamp.py --engine DIR --mode local
  python3 -B script/evidence/q5_snapshot_timestamp.py --engine DIR --mode fork --rpc-file FILE --block N
The RPC URL is read from FILE and never printed; engine output is discarded.
"""
import sys
sys.dont_write_bytecode = True
import argparse
import json
import socket
import subprocess
import time
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'a3a'))  # script/a3a
import a3a_exec  # noqa: E402  (COMMIT only)

DAY = 86400
# Upper bound on wall-clock/RPC latency between the no-jump baseline block and the post-revert block.
TOLERANCE = 60
SENDER = '0x000000000000000000000000000000000000c0de'


class Local:
    def __init__(self, port):
        self.url, self.n = f'http://127.0.0.1:{port}', 0

    def __call__(self, method, params):
        self.n += 1
        body = json.dumps(dict(jsonrpc='2.0', id=self.n, method=method, params=params)).encode()
        req = urllib.request.Request(self.url, body, {'content-type': 'application/json'})
        out = json.load(urllib.request.urlopen(req, timeout=120))
        if 'error' in out:
            raise RuntimeError(f'{method}: {out["error"]}')
        return out['result']


def latest(rpc):
    b = rpc('eth_getBlockByNumber', ['latest', False])
    return int(b['number'], 16), int(b['timestamp'], 16)


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
    return int(b['timestamp'], 16) - t0


def run(rpc):
    checks, n0, t0 = [], *latest(rpc)

    def check(name, observed, expected):
        checks.append(dict(name=name, observed=observed, expected=expected, ok=observed == expected))

    # Baseline: what the next block looks like with no time jump (wall clock still advances).
    s = rpc('evm_snapshot', [])
    base_mine = mined_delta(rpc, t0)
    check('baseline_revert', rpc('evm_revert', [s]), True)
    s = rpc('evm_snapshot', [])
    base_tx = tx_delta(rpc, t0)
    check('baseline_tx_revert', rpc('evm_revert', [s]), True)

    # 1. Single snapshot: jump 10 days, revert.
    s = rpc('evm_snapshot', [])
    wait_until(rpc, t0 + 10 * DAY)
    check('single_jumped', latest(rpc)[1], t0 + 10 * DAY)
    check('single_revert', rpc('evm_revert', [s]), True)
    check('single_latest_restored', latest(rpc), (n0, t0))
    s = rpc('evm_snapshot', [])
    after_mine = mined_delta(rpc, t0)
    rpc('evm_revert', [s])
    s = rpc('evm_snapshot', [])
    after_tx = tx_delta(rpc, t0)
    rpc('evm_revert', [s])
    # The next auto-timestamped block must not inherit the jump: within TOLERANCE s of the no-jump baseline.
    check('single_next_block_not_jumped', after_mine - base_mine < TOLERANCE, True)
    check('single_next_tx_block_not_jumped', after_tx - base_tx < TOLERANCE, True)
    # Main path sets an explicit executionTimestamp earlier than the control's jump; it must be accepted.
    s = rpc('evm_snapshot', [])
    rpc('evm_setNextBlockTimestamp', [t0 + 100])
    rpc('evm_mine', [])
    check('single_explicit_earlier_ts', latest(rpc)[1], t0 + 100)
    rpc('evm_revert', [s])

    # 2. Nested snapshots (controls run inside an outer snapshot).
    outer = rpc('evm_snapshot', [])
    wait_until(rpc, t0 + DAY)
    inner = rpc('evm_snapshot', [])
    wait_until(rpc, t0 + 6 * DAY)
    check('nested_inner_revert', rpc('evm_revert', [inner]), True)
    check('nested_inner_restored_ts', latest(rpc)[1], t0 + DAY)
    check('nested_outer_revert', rpc('evm_revert', [outer]), True)
    check('nested_outer_restored', latest(rpc), (n0, t0))
    s = rpc('evm_snapshot', [])
    rpc('evm_setNextBlockTimestamp', [t0 + 50])
    rpc('evm_mine', [])
    check('nested_explicit_earlier_ts', latest(rpc)[1], t0 + 50)
    rpc('evm_revert', [s])
    check('final_state', latest(rpc), (n0, t0))
    return dict(toleranceSeconds=TOLERANCE, pinBlock=n0, pinTimestamp=t0, baselineMineDelta=base_mine, baselineTxDelta=base_tx,
                afterJumpMineDelta=after_mine, afterJumpTxDelta=after_tx, checks=checks)


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
    if args.mode == 'fork':
        url = args.rpc_file.read_text().strip()
        cmd += ['--fork-url', url, '--fork-block-number', str(args.block), '--chain-id', '11155111',
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
    print(json.dumps(out, indent=1))
    ok = out['engineCommitPinned'] and all(c['ok'] for c in out['checks'])
    print('Q5', 'PASS' if ok else 'FAIL')
    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()
