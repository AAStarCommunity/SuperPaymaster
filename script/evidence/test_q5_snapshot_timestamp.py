#!/usr/bin/env python3
"""Offline controls for q5_snapshot_timestamp.run(): an in-memory chain with anvil's clock-offset semantics.

evm_setNextBlockTimestamp(t) also moves the engine clock offset to t - wall, so a revert that restores the
block headers but not the offset leaves later auto-timestamped blocks in the future. The correct model must
pass every check; every faulty model must fail at least one. step: wall seconds each RPC call takes (DSR
2026-11-05 measured 10-20 s per call on a remote fork), so a correct engine must also pass on a slow endpoint.
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
    def __init__(self, fault=None, lag=0, step=0):
        # lag: how far wall time is ahead of the pin block (an old fork pin).
        self.fault, self.wall, self.offset, self.pending, self.step = fault, T0 + lag, 0, None, step
        self.blocks, self.snaps, self.stack, self.receipts = [T0], {}, [], {}

    def mine(self):
        ts = self.pending if self.pending is not None else max(self.blocks[-1] + 1, self.wall + self.offset + 1)
        self.pending = None
        self.blocks.append(ts)
        return len(self.blocks) - 1

    def clock(self):
        return self.wall

    def sleep(self, seconds):
        self.wall += seconds

    def __call__(self, method, params):
        self.wall += self.step
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
            if not self.stack:
                self.snaps_base = self.offset
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
            elif self.fault == 'low':
                # Restored, but a day too low: only the parent + 1 clamp keeps later blocks moving.
                self.offset = offset - q5.DAY
            elif self.fault == 'lost_inner' and depth > 0:
                # The inner revert drops the outer jump's offset back to the pre-outer one.
                self.offset = self.snaps_base
            elif self.fault == 'lost_inner':
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
STEPS = (0, 15)
CASES = [(lag, step) for lag in LAGS for step in STEPS]


class Q5Controls(unittest.TestCase):
    def failed(self, fault, lag, step=0):
        chain = Chain(fault, lag, step)
        return [c['name'] for c in q5.run(chain, clock=chain.clock, sleep=chain.sleep)['checks'] if not c['ok']]

    def test_correct_engine_passes(self):
        for lag, step in CASES:
            with self.subTest(lag=lag, step=step):
                self.assertEqual(self.failed(None, lag, step), [])

    def test_slow_endpoint_is_slow(self):
        # The step=15 case is a real slow run: the whole run spans far more than the old fixed 60 s budget, and
        # the nested comparison alone (DSR's two failing checks) spans more than 60 s too.
        chain = Chain(step=15)
        out = q5.run(chain, clock=chain.clock, sleep=chain.sleep)
        self.assertGreater(chain.wall - T0, 600)
        nested = {c['name']: c for c in out['checks']}['nested_next_block_not_jumped']
        self.assertTrue(nested['ok'])
        self.assertGreater(nested['window'][1] - nested['window'][0], 60)

    def test_offset_never_restored_fails(self):
        for lag, step in CASES:
            with self.subTest(lag=lag, step=step):
                self.assertIn('single_next_block_not_jumped', self.failed('all', lag, step))

    def test_leaked_jump_of_a_day_fails_on_a_slow_endpoint(self):
        # DSR: a revert that leaves the time where the control put it (gap ~ +DAY or more) must FAIL even
        # with the window widened by a slow endpoint.
        chain = Chain('all', 0, 15)
        checks = {c['name']: c for c in q5.run(chain, clock=chain.clock, sleep=chain.sleep)['checks']}
        for name in ('single_next_block_not_jumped', 'nested_next_block_not_jumped'):
            self.assertFalse(checks[name]['ok'], name)
            self.assertGreaterEqual(checks[name]['gap'], q5.DAY)

    def test_offset_not_restored_for_nested_snapshots_fails(self):
        # Headers and explicit timestamps still look right; only auto-mined blocks expose it.
        for lag, step in CASES:
            with self.subTest(lag=lag, step=step):
                self.assertIn('inner_revert_next_block_follows_outer', self.failed('nested', lag, step))

    def test_offset_not_restored_for_outer_snapshots_fails(self):
        # Codex round 2: with an old pin the post-revert block is far *behind* the baseline, not ahead of it.
        for lag, step in CASES:
            with self.subTest(lag=lag, step=step):
                self.assertIn('single_next_block_not_jumped', self.failed('outer', lag, step))

    def test_offset_restored_too_low_fails(self):
        # Codex Q5 challenge P1: the parent + 1 clamp hides a low offset unless the compared blocks are SEPARATION apart.
        for lag, step in CASES:
            with self.subTest(lag=lag, step=step):
                self.assertIn('single_next_block_not_jumped', self.failed('low', lag, step))

    def test_outer_offset_lost_on_inner_revert_fails(self):
        for lag, step in CASES:
            with self.subTest(lag=lag, step=step):
                self.assertIn('inner_revert_next_block_follows_outer', self.failed('lost_inner', lag, step))

    def test_undecidable_window_fails(self):
        # A run so slow that a window reaches DAY/2 cannot tell a leak from latency: FAIL, even for a correct engine.
        failed = self.failed(None, 0, q5.DAY // 8)
        self.assertIn('single_next_block_not_jumped', failed)
        self.assertIn('inner_revert_next_block_follows_outer', failed)

    def test_baseline_is_mined_before_the_jump(self):
        # A baseline taken after the jump would move with a leak and hide it. For both baseline segments (the
        # 10-day jump and the first 1-day jump), a block and a tx must be mined after the previous explicit
        # timestamp and before the segment's jump.
        calls = []
        class Log(Chain):
            def __call__(self, method, params):
                calls.append((method, params))
                return super().__call__(method, params)
        chain = Log()
        q5.run(chain, clock=chain.clock, sleep=chain.sleep)
        sets = [(i, p[0]) for i, (m, p) in enumerate(calls) if m == 'evm_setNextBlockTimestamp']
        for jump in (T0 + 10 * q5.DAY, T0 + q5.DAY):
            with self.subTest(jump=jump):
                at = next(n for n, (i, v) in enumerate(sets) if v == jump)
                lo, hi = (sets[at - 1][0] if at else -1), sets[at][0]
                between = {m for m, _ in calls[lo + 1:hi]}
                self.assertLessEqual({'evm_mine', 'eth_sendTransaction'}, between)

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


    def test_engine_content_never_surfaces(self):
        # Codex round 3: non-integer error code, malformed quantity, non-boolean revert result.
        class Secret(Chain):
            def __init__(self, shape):
                super().__init__()
                self.shape = shape
            def __call__(self, method, params):
                if self.shape == 'block' and method == 'eth_getBlockByNumber':
                    return dict(number='SYNTHETIC_SECRET', timestamp='0x1')
                if self.shape == 'revert' and method == 'evm_revert':
                    super().__call__(method, params)
                    return 'SYNTHETIC_SECRET'
                return super().__call__(method, params)
        for shape in ('block', 'revert'):
            with self.subTest(shape=shape):
                try:
                    text = repr(q5.run(Secret(shape)))
                except RuntimeError as e:
                    text = str(e)
                self.assertNotIn('SYNTHETIC_SECRET', text)
        rpc = q5.Local(0)
        body = b'{"jsonrpc":"2.0","id":1,"error":{"code":"SYNTHETIC_SECRET"}}'
        class Reply:
            def read(self): return body
        q5.urllib.request.urlopen, real = (lambda *a, **k: Reply()), q5.urllib.request.urlopen
        try:
            with self.assertRaises(RuntimeError) as caught:
                rpc('eth_chainId', [])
        finally:
            q5.urllib.request.urlopen = real
        self.assertEqual(str(caught.exception), 'eth_chainId: JSON-RPC error code non-integer')
        # Codex round 4: an HTTP error's reason phrase must not surface either.
        def http_error(*a, **k):
            raise q5.urllib.error.HTTPError('http://127.0.0.1:0', 500, 'SYNTHETIC_SECRET', {}, None)
        q5.urllib.request.urlopen, real = http_error, q5.urllib.request.urlopen
        try:
            with self.assertRaises(RuntimeError) as caught:
                rpc('eth_chainId', [])
        finally:
            q5.urllib.request.urlopen = real
        self.assertEqual(str(caught.exception), 'eth_chainId: transport error HTTPError')
        self.assertIsNone(caught.exception.__cause__)


if __name__ == '__main__':
    unittest.main()
