"""Offline Daybreak round-two regressions."""
import inspect
import unittest
from types import SimpleNamespace
from unittest.mock import patch
import plan_three_arm as q

PIN = '0x'+'12'*32

class RoundTwo(unittest.TestCase):
    def test_planner_provider_independence(self):
        env = dict(DEPLOYLIVE_ENDPOINT_PROVIDER='Alchemy', DEPLOYLIVE_SECOND_ENDPOINT_PROVIDER='Infura')
        for first, second, names in (
            ('https://x.alchemy.com', 'https://x.alchemy.com', env),
            ('https://x.alchemy.com', 'https://y.infura.io', dict(env, DEPLOYLIVE_SECOND_ENDPOINT_PROVIDER='Alchemy')),
            ('https://x.alchemy.com', 'https://y.infura.io', dict(env, DEPLOYLIVE_ENDPOINT_PROVIDER='Unknown')),
            ('https://evil.invalid', 'https://y.infura.io', env),
        ):
            with self.subTest(first=first, second=second, names=names):
                left, right = q.http_transport(first), q.http_transport(second)
                with patch.object(q, 'load', return_value={}), patch.object(q, 'Pair') as pair, patch.object(q, 'run_checker') as checker:
                    pair.return_value.return_value = '0xa'
                    with self.assertRaises(q.a.Gate):
                        q._generate('config', 'inputs', left, right, first, None, None, None, SimpleNamespace(env=names))
                    checker.assert_not_called()

        # Prove the accepted path uses the same checker function and the actual transport URLs.
        import sys
        sys.path.insert(0, str(q.ROOT/'script/rehearsal'))
        import deploylive_readback as readback
        left, right = q.http_transport('https://x.alchemy.com'), q.http_transport('https://y.infura.io')
        with patch.object(q, 'load', return_value={}), patch.object(q, 'Pair') as pair, patch.object(q, 'run_checker', side_effect=RuntimeError('validated')) as checker, patch.object(readback, 'independent_providers', wraps=readback.independent_providers) as validate:
            pair.return_value.return_value = '0xa'
            with self.assertRaisesRegex(RuntimeError, 'validated'):
                q._generate('config', 'inputs', left, right, left.endpoint, None, None, None, SimpleNamespace(env=env))
            validate.assert_called_once_with('Alchemy', 'Infura', left.endpoint, right.endpoint)
            checker.assert_called_once()
        # Even overlapping approved suffixes cannot make one hostname independent.
        with patch.object(readback.json, 'loads', return_value={'alchemy':['.shared.example'], 'infura':['.shared.example']}):
            with self.assertRaises(ValueError):
                readback.independent_providers('Alchemy', 'Infura', 'https://x.shared.example/a', 'https://x.shared.example/b')

    def test_pending_nonce_each_provider_matches_pin(self):
        for pending in ((1, 1), (0, 1), (1, 0)):
            calls = []
            def client(index):
                def rpc(method, params):
                    calls.append((index, method, params))
                    if method == 'eth_getBlockByNumber': return dict(hash=PIN, number='0x20')
                    return hex(pending[index]) if params[-1] == 'pending' else '0x0'
                return rpc
            with self.subTest(pending=pending):
                pair = q.Pair(client(0), client(1))
                with self.assertRaises(q.a.Gate): pair('eth_getTransactionCount', ['account', 'pending'])
                self.assertTrue(any(isinstance(params[-1], dict) for _, method, params in calls if method == 'eth_getTransactionCount'))

    def test_checker_argv_contains_no_url(self):
        cfg = dict(commit='a'*40, guardianN=2, deployer='d', governanceOwner='s')
        calls = []
        tools = SimpleNamespace(env={}, records={})
        def runner(command, **kw):
            calls.append((command, kw))
            return SimpleNamespace(returncode=0, stdout=f'SNAPSHOT_BLOCK_HASH {PIN}\nSUMMARY 242 passed, 0 failed, 242 total')
        with patch.object(q, 'authenticate_checker', return_value={}):
            q.run_checker('config', cfg, 'https://x.alchemy.com/credential', 31337, block=PIN,
                          tools=tools, runner=runner, commit_reader=lambda:cfg['commit'])
        self.assertFalse(any('://' in arg for arg in calls[0][0]))
        self.assertEqual(calls[0][1]['env']['ETH_RPC_URL'], 'https://x.alchemy.com/credential')

    def test_checker_block_is_required(self):
        self.assertIs(inspect.signature(q.run_checker).parameters['block'].default, inspect.Parameter.empty)

    def test_checker_none_block_cannot_accept_unbound_summary(self):
        cfg = dict(commit='a'*40, guardianN=2, deployer='d', governanceOwner='s')
        with patch.object(q, 'authenticate_checker', return_value={}):
            with self.assertRaises(q.a.Gate):
                q.run_checker('config', cfg, 'unused', 31337, block=None, tools=SimpleNamespace(env={}, records={}),
                              runner=lambda *a, **k:SimpleNamespace(returncode=0, stdout='SUMMARY 242 passed, 0 failed, 242 total'),
                              commit_reader=lambda:cfg['commit'])
