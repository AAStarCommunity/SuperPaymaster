#!/usr/bin/env python3
"""Offline controls for q5_snapshot_timestamp.run(): an in-memory chain with anvil's clock-offset semantics.

evm_setNextBlockTimestamp(t) also moves the engine clock offset to t - wall, so a revert that restores the
block headers but not the offset leaves later auto-timestamped blocks in the future. The correct model must
pass every check; both faulty models must fail at least one.
Repository root: python3 -B script/evidence/test_q5_snapshot_timestamp.py
"""
import sys
sys.dont_write_bytecode = True
import copy
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import q5_snapshot_timestamp as q5  # noqa: E402

T0 = 1793816148


class Chain:
    def __init__(self, fault=None, lag=0):
        # lag: how far wall time is ahead of the pin block (an old fork pin).
        self.fault, self.wall, self.offset, self.pending = fault, T0 + lag, 0, None
        self.blocks, self.snaps, self.stack, self.receipts = [T0], {}, [], {}

    def mine(self):
        ts = self.pending if self.pending is not None else max(self.blocks[-1] + 1, self.wall + self.offset + 1)
        self.pending = None
        self.blocks.append(ts)
        return len(self.blocks) - 1

    def __call__(self, method, params):
        if method == 'eth_getBlockByNumber':
            n = len(self.blocks) - 1 if params[0] == 'latest' else int(params[0], 16)
            return dict(number=hex(n), timestamp=hex(self.blocks[n]))
        if method == 'evm_setNextBlockTimestamp':
            self.pending, self.offset = params[0], params[0] - self.wall
            return None
        if method == 'evm_mine':
            self.mine()
            return '0x0'
        if method == 'evm_snapshot':
            sid = hex(len(self.snaps) + 1)
            self.snaps[sid] = (copy.copy(self.blocks), self.offset, len(self.stack))
            self.stack.append(sid)
            return sid
        if method == 'evm_revert':
            blocks, offset, depth = self.snaps.pop(params[0])
            while self.stack and self.stack.pop() != params[0]:
                pass
            self.blocks = blocks
            if self.fault is None or (self.fault == 'nested' and depth == 0) or (self.fault == 'outer' and depth > 0):
                self.offset = offset
            return True
        if method in ('anvil_setBalance', 'anvil_impersonateAccount'):
            return None
        if method == 'eth_sendTransaction':
            h = '0x%064x' % (len(self.receipts) + 1)
            self.receipts[h] = dict(blockNumber=hex(self.mine()))
            return h
        if method == 'eth_getTransactionReceipt':
            return self.receipts.get(params[0])
        raise AssertionError(method)


LAGS = (0, 30 * q5.DAY)


class Q5Controls(unittest.TestCase):
    def failed(self, fault, lag):
        return [c['name'] for c in q5.run(Chain(fault, lag))['checks'] if not c['ok']]

    def test_correct_engine_passes(self):
        for lag in LAGS:
            with self.subTest(lag=lag):
                self.assertEqual(self.failed(None, lag), [])

    def test_offset_never_restored_fails(self):
        for lag in LAGS:
            with self.subTest(lag=lag):
                self.assertIn('single_next_block_not_jumped', self.failed('all', lag))

    def test_offset_not_restored_for_nested_snapshots_fails(self):
        # Headers and explicit timestamps still look right; only auto-mined blocks expose it.
        for lag in LAGS:
            with self.subTest(lag=lag):
                self.assertIn('inner_revert_next_block_follows_outer', self.failed('nested', lag))

    def test_offset_not_restored_for_outer_snapshots_fails(self):
        # Codex round 2: with an old pin the post-revert block is far *behind* the baseline, not ahead of it.
        for lag in LAGS:
            with self.subTest(lag=lag):
                self.assertIn('single_next_block_not_jumped', self.failed('outer', lag))

    def test_rpc_error_text_never_surfaces(self):
        rpc = q5.Local(0)
        body = b'{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"invalid API key: SYNTHETIC_SECRET https:\\/\\/x.invalid\\/v2\\/SYNTHETIC_SECRET"}}'
        class Reply:
            def read(self): return body
        q5.urllib.request.urlopen, real = (lambda *a, **k: Reply()), q5.urllib.request.urlopen
        try:
            with self.assertRaises(RuntimeError) as caught:
                rpc('eth_chainId', [])
        finally:
            q5.urllib.request.urlopen = real
        self.assertEqual(str(caught.exception), 'eth_chainId: JSON-RPC error code -32000')


if __name__ == '__main__':
    unittest.main()
