"""Offline fixtures only: RPC and ABI command boundaries are mocked."""
import copy
import unittest
from unittest.mock import patch
import deploylive_rehearse as r


class RehearsalTest(unittest.TestCase):
    def test_endpoint_restriction_before_rpc(self):
        for url in ('http://127.0.0.1:8545', 'http://[::1]:8545', 'http://localhost:8545'):
            r.local_endpoint(url)
        for url in ('https://example.org', 'http://example.org', 'http://127.0.0.1.evil',
                    'http://user:password@localhost:8545', 'file:///tmp/rpc'):
            with self.subTest(url=url), self.assertRaises(RuntimeError):
                r.RPC(url)

    def test_client_and_fork_guards(self):
        for responses in (['geth'], ['anvil', {'forkedNetwork': None}]):
            with patch.object(r.RPC, '__call__', side_effect=responses), self.assertRaises(RuntimeError):
                r.RPC('http://127.0.0.1:8545')
        with patch.object(r.RPC, '__call__', side_effect=['anvil/v1', {'forkedNetwork': {'chainId': 10}}]):
            r.RPC('http://127.0.0.1:8545')

    def test_same_receipt_pause_evidence(self):
        event = dict(address='0x01', topics=['0xab', '0x02', '0x03'], data='0x04')
        receipt = dict(status='0x1', logs=[event])
        self.assertTrue(r.hook_receipt(receipt, '0x01', '0x02', '0xab', '0x03'))
        for key, value in [('address', '0xff'), ('topics', ['0xab', '0xff', '0x03']),
                           ('topics', ['0xab', '0x02', '0xff']), ('data', '0x01')]:
            bad = copy.deepcopy(receipt)
            bad['logs'][0][key] = value
            self.assertFalse(r.hook_receipt(bad, '0x01', '0x02', '0xab', '0x03'))
        for bad in (dict(status='0x0', logs=[event]), dict(status='0x1', logs=[])):
            self.assertFalse(r.hook_receipt(bad, '0x01', '0x02', '0xab', '0x03'))

    def test_cleanup_even_on_failure(self):
        calls = []
        def rpc(*args):
            calls.append(args)
        def action():
            raise RuntimeError('fixture failure')
        with self.assertRaises(RuntimeError):
            r.impersonate(rpc, 'account', action)
        self.assertEqual(calls[-1], ('anvil_stopImpersonatingAccount', 'account'))

    def test_hook_warps_and_checks_exit_receipt(self):
        calls = []
        def encode(values):
            return '0x' + ''.join(f'{v:064x}' for v in values)
        class FakeRPC:
            exited = False
            def __call__(self, *args):
                calls.append(args)
            def call(self, target, signature, *args):
                if signature.startswith('hasRole'):
                    return encode([0 if self.exited else 1])
                if signature.startswith('operators'):
                    return encode([1, 1, int(self.exited), 0, 0, 0, 0, 0, 0])
                if signature.startswith('getLockedStake'):
                    return encode([100])
                if signature.startswith('getRoleConfig'):
                    return encode([32] + [0] * 11 + [1234])
                raise AssertionError(signature)
            def send(self, *args):
                calls.append(('send', *args))
                self.exited = True
                return {'status': '0x1', 'logs': [dict(address='0x01', topics=['0xab', '0x02', '0x03'], data='0x04')]}
        with patch.object(r, 'cast', return_value='0xab'):
            r.hook(FakeRPC(), dict(registry='reg', superPaymaster='0x01', staking='0x03'), '0x02')
        self.assertIn(('evm_increaseTime', 1235), calls)
        self.assertIn(('evm_mine',), calls)
        self.assertEqual([c for c in calls if c[0] == 'send'], [('send', '0x02', '0xab', 'reg')])



if __name__ == '__main__':
    unittest.main()
