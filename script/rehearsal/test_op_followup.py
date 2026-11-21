"""Offline driver regressions for clestons #672 lows; transports are injected."""
import contextlib
import io
import json
import os
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch
from urllib.error import HTTPError
import deploylive_controls as c
import deploylive_fork_deploy as f
import test_ddf5 as fixture


class OPFollowup(unittest.TestCase):
    setUp = fixture.Ddf5Test.setUp
    driver = fixture.Ddf5Test.driver

    def op_driver(self, gas, stage=3):
        def mutate(plan, index):
            for tx in plan['transactions']:
                tx['transaction']['gas'] = hex(1_000_000)
            if index == stage:
                plan['transactions'][45]['transaction']['gas'] = hex(gas)
        # Deliberately loose bounds prove the independent Karst cap/headroom checks.
        self.driver(mutate, chain=11155420, bounds=[[0, 40_000_000]] * 97,
                    env_overrides={'DEPLOYLIVE_HARDFORK': 'op:karst'})

    def test_broadcast_155m_warns_and_runs_checker(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.op_driver(15_500_000)
        name = json.loads(fixture.FIX.read_text())['transactions'][45]['contractName']
        self.assertRegex(output.getvalue(), r'WARNING.*index=45.*' + name)
        self.assertTrue(hasattr(self, 'checker_env'))
        self.assertEqual(json.loads((self.root/'checker.PASS.json').read_text())['status'], 'PASS')

    def test_broadcast_above_hard_cap_stops(self):
        with self.assertRaisesRegex(RuntimeError, 'post-broadcast diff'):
            self.op_driver(2**24 + 1)
        self.assertIn('hard cap', (self.root/'postbroadcast.diff.json').read_text())
        self.assertFalse(hasattr(self, 'checker_env'))

    def test_final_simulation_headroom_stops_before_broadcast(self):
        with self.assertRaisesRegex(RuntimeError, 'final simulation.*Karst headroom'):
            self.op_driver(int(.9 * 2**24) + 1, stage=2)
        self.assertFalse(any('--broadcast' in cmd for cmd in self.calls))
        self.assertFalse(hasattr(self, 'checker_env'))

    def test_checker_uses_verified_path(self):
        verified = ['/verified/cast', '/verified/tools']
        with patch.object(f, 'require_checker_inputs', return_value=verified) as check:
            self.driver()
        check.assert_called_once()
        self.assertEqual(self.checker_env['PATH'], os.pathsep.join(verified))

    def rpc_error(self, status, message):
        rpc = f.ReadOnlyRPC('https://unused.invalid')
        rpc.opener = Mock()
        body = json.dumps(dict(jsonrpc='2.0', id=1, error=dict(code=-32600, message=message))).encode()
        if status == 200:
            rpc.opener.open.return_value = io.BytesIO(body)
        else:
            rpc.opener.open.side_effect = HTTPError(rpc.url, status, 'Bad Request', {}, io.BytesIO(body))
        return rpc

    def test_real_alchemy_op_messages_are_unsupported(self):
        # Verbatim (docs URL removed) from Alchemy, measured 2026-11-21 on OP Sepolia and OP mainnet: HTTP 400, -32600.
        for network in ('OPT_SEPOLIA', 'OPT_MAINNET'):
            message = f'eth_config is not available on the {network}. For more information see our docs: <URL>'
            with self.subTest(network=network), self.assertRaises(c.UnsupportedConfig):
                self.rpc_error(400, message)('eth_config')

    def test_rate_limit_http400_stops(self):
        with self.assertRaisesRegex(RuntimeError, 'STOP.*HTTP 400'):
            self.rpc_error(400, 'service unavailable: rate limit')('eth_config')

    def test_http200_unavailable_accepted(self):
        with self.assertRaises(c.UnsupportedConfig):
            self.rpc_error(200, 'eth_config is not available')('eth_config')

    def test_http200_rate_limit_stops(self):
        with self.assertRaisesRegex(RuntimeError, 'STOP.*rate limit'):
            self.rpc_error(200, 'service unavailable: rate limit')('eth_config')

    def test_http400_restriction(self):
        for status in (401, 403, 500):
            with self.subTest(status=status), self.assertRaisesRegex(RuntimeError, f'STOP.*HTTP {status}'):
                self.rpc_error(status, 'eth_config is not available')('eth_config')

    def predict(self, expected, actual, hardfork, error=None):
        env = {key: 'value' for key in c.input_keys() if not key.endswith('_FILE')}
        env.update(self.env, DEPLOYLIVE_EXPECTED_CHAIN_ID=str(expected), DEPLOYLIVE_HARDFORK=hardfork,
                   DEPLOYLIVE_RPC='https://unused.invalid', DEPLOYLIVE_PRICE_SOURCE='chain',
                   FOUNDRY_VERBOSITY='2', REHEARSAL_BLS_SCALARS='[]')
        rpc = Mock(return_value=hex(actual))
        def forge(*args, **kwargs):
            rpc.assert_called_once_with('eth_chainId')
            (self.root/f.REQUEST_PATH).write_text('{}')
            return SimpleNamespace(returncode=0, stdout='', stderr='')
        with patch.dict(os.environ, env, clear=True), patch.object(f, 'ROOT', self.root), patch.object(f, 'clean_source_commit', return_value='a'*40), patch.object(f, 'require_checker_inputs'), patch.object(f, 'ReadOnlyRPC', return_value=rpc) as transport, patch.object(f, 'verify_build', return_value='forge') as build, patch.object(f, 'config_path', return_value=self.root/'config.json'), patch.object(f.subprocess, 'run', side_effect=forge) as run:
            if error:
                with self.assertRaisesRegex(RuntimeError, error):
                    f.stage('predict', ['--production', '--evidence', str(self.root)])
                build.assert_not_called()
                run.assert_not_called()
            else:
                f.stage('predict', ['--production', '--evidence', str(self.root)])
                run.assert_called_once()
            transport.assert_called_once_with(env['DEPLOYLIVE_RPC'])
            rpc.assert_called_once_with('eth_chainId')

    def test_predict_chain_mismatch_before_forge(self):
        self.predict(10, 11155420, 'op:karst', 'chain.*mismatch')

    def test_predict_sepolia_wrong_hardfork_before_forge(self):
        self.predict(11155111, 11155111, 'prague', 'Sepolia requires')

    def test_predict_op_sepolia_reads_chain_once(self):
        self.predict(11155420, 11155420, 'op:karst')

    def test_nonproduction_op_wrong_hardfork(self):
        import test_deploylive_round9 as round9
        with patch.object(c, 'validate_hardfork', wraps=c.validate_hardfork) as check:
            with self.assertRaisesRegex(RuntimeError, 'validated OP hardfork'):
                round9.Round9Test().run_fork(11155420, hardfork='amsterdam')
        check.assert_called_once_with(11155420, 'amsterdam')
