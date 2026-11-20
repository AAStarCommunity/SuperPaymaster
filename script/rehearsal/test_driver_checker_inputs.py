"""Sepolia fork pre-run, 2026-11-20: the deploy-day driver must hand the checker the second
provider's name and the operator-stated chain id, or the checker cannot PASS on a production
chain. Both are operator inputs, validated by load_inputs, allowed through its environment
allowlist, bound into the input manifest, and the expected chain id must equal the broadcast
endpoint's chain before any broadcast."""
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import deploylive_controls as c
import test_ddf5 as prev


class DriverCheckerInputs(unittest.TestCase):
    setUp = prev.Ddf5Test.setUp
    driver = prev.Ddf5Test.driver

    def _inputs(self, root):
        lines = []
        for key in sorted(c.input_keys()):
            lines.append(f'{key}=')
        path = root / 'inputs.env'
        path.write_text('\n'.join(lines) + '\n')
        return path

    def test_malformed_values_refused(self):
        with patch.object(c, 'input_keys', return_value={'DEPLOYLIVE_EVIDENCE_DIR'}):
            path = Path(self.root) / 'one.env'; path.write_text(f'DEPLOYLIVE_EVIDENCE_DIR={self.root}\n')
            for bad in ({'DEPLOYLIVE_EXPECTED_CHAIN_ID': '010'}, {'DEPLOYLIVE_SECOND_ENDPOINT_PROVIDER': 'https://x'}):
                with self.assertRaises(ValueError):
                    c.load_inputs(path, dict({'DEPLOYLIVE_ENDPOINT_PROVIDER': 'Alchemy'}, **bad), commit_reader=lambda: 'a' * 40)

    def test_manifest_binds_both(self):
        base = dict(self.env, DEPLOYLIVE_SECOND_ENDPOINT_PROVIDER='Tenderly', DEPLOYLIVE_EXPECTED_CHAIN_ID='11155111')
        request = Path(self.root) / 'pop-request.json'
        one = c.manifest_bytes(base, request)
        self.assertNotEqual(one, c.manifest_bytes(dict(base, DEPLOYLIVE_EXPECTED_CHAIN_ID='10'), request))
        self.assertNotEqual(one, c.manifest_bytes(dict(base, DEPLOYLIVE_SECOND_ENDPOINT_PROVIDER='Infura'), request))

    def test_driver_refuses_expected_chain_mismatch_before_forge(self):
        import deploylive_readback
        with patch.object(deploylive_readback, 'expected_chain_id', return_value=10):
            with self.assertRaisesRegex(RuntimeError, 'DEPLOYLIVE_EXPECTED_CHAIN_ID differs'):
                self.driver(chain=11155111)
        self.assertFalse(any('script' in call for call in getattr(self, 'calls', [])), 'no forge before the chain check')

    def test_driver_requires_expected_chain(self):
        with self.assertRaisesRegex(RuntimeError, 'STOP DEPLOYLIVE_EXPECTED_CHAIN_ID required or invalid'):
            self.driver(env_overrides={'DEPLOYLIVE_EXPECTED_CHAIN_ID': None})
        self.assertEqual(self.calls, [])

    def test_fork_rehearsal_skips_provider_binding_production_does_not(self):
        # A fork rehearsal (anvil --chain-id 11155111 on 127.0.0.1) has no bound second provider;
        # the provider check applies only before a production broadcast. Same inputs, both modes.
        import deploylive_fork_deploy as f
        env = {'CAST_1_7_1': self.env['CAST_1_7_1'], 'DEPLOYLIVE_EXPECTED_CHAIN_ID': '11155111', 'DEPLOYLIVE_RPC': 'http://127.0.0.1:8545'}
        self.assertIsNone(f.require_checker_inputs(env, 11155111, production=False))
        with self.assertRaisesRegex(RuntimeError, 'STOP invalid checker provider pair'):
            f.require_checker_inputs(env, 11155111, production=True)
        with self.assertRaisesRegex(RuntimeError, 'differs from the broadcast endpoint chain'):
            f.require_checker_inputs(env, 31337, production=False)

    def test_non_production_cannot_reach_a_real_chain(self):
        # The provider exemption for non-production rests on this: without --production the
        # driver builds RPC(url), which requires a loopback HTTP Anvil fork, before any forge call
        # (deploylive_fork_deploy.py main; deploylive_rehearse.RPC/local_endpoint).
        import sys
        import deploylive_fork_deploy as f
        for url in ('https://eth-sepolia.g.alchemy.com/v2/key', 'http://sepolia.example.org:8545'):
            with self.subTest(url=url), patch.dict(os.environ, {'DEPLOYLIVE_EXPECTED_CHAIN_ID': '11155111', 'FOUNDRY_VERBOSITY': '2'}, clear=True), \
                    patch.object(sys, 'argv', ['driver', url, '0x' + '11' * 20]), \
                    patch.object(f, 'clean_source_commit', return_value='a' * 40), \
                    patch.object(f.subprocess, 'run') as run, patch.object(f, 'ReadOnlyRPC') as ro:
                with self.assertRaisesRegex(RuntimeError, 'loopback HTTP endpoint required'):
                    f.main()
                run.assert_not_called()
                ro.assert_not_called()

    def test_provider_inputs_stop_before_forge(self):
        for overrides in (
            {'DEPLOYLIVE_SECOND_ENDPOINT_PROVIDER': 'Alchemy'},
            {'DEPLOYLIVE_SECOND_ENDPOINT_PROVIDER': None},
            {'DEPLOYLIVE_RPC': 'https://secondary.infura.io/other'},
            {'DEPLOYLIVE_SECOND_RPC': 'https://different.infura.io/key'},
            {'DEPLOYLIVE_EXPECTED_CHAIN_ID': '010'},
        ):
            with self.subTest(overrides=overrides):
                with self.assertRaisesRegex(RuntimeError, 'STOP'):
                    self.driver(env_overrides=overrides)
                self.assertEqual(self.calls, [])

    def test_production_predict_checker_inputs_before_forge(self):
        import deploylive_fork_deploy as f
        env = {key: 'value' for key in c.input_keys() if not key.endswith('_FILE')}
        second = self.root/'second-rpc'
        second.write_text('https://secondary.infura.io/key')
        env.update(self.env, DEPLOYLIVE_RPC='https://primary.alchemy.com/key',
                   DEPLOYLIVE_SECOND_RPC=second.read_text(), DEPLOYLIVE_SECOND_RPC_FILE=str(second),
                   DEPLOYLIVE_ENDPOINT_PROVIDER='Alchemy', DEPLOYLIVE_SECOND_ENDPOINT_PROVIDER='Infura',
                   DEPLOYLIVE_EXPECTED_CHAIN_ID='11155111', DEPLOYLIVE_PRICE_SOURCE='chain', FOUNDRY_VERBOSITY='2')
        for overrides in (
            {'DEPLOYLIVE_EXPECTED_CHAIN_ID': None},
            {'DEPLOYLIVE_EXPECTED_CHAIN_ID': '010'},
            {'DEPLOYLIVE_EXPECTED_CHAIN_ID': '31337'},
            {'DEPLOYLIVE_EXPECTED_CHAIN_ID': '1'},
            {'DEPLOYLIVE_SECOND_ENDPOINT_PROVIDER': 'Alchemy'},
            {'DEPLOYLIVE_SECOND_ENDPOINT_PROVIDER': None},
            {'DEPLOYLIVE_RPC': 'https://secondary.infura.io/other'},
            {'DEPLOYLIVE_SECOND_RPC': 'https://different.infura.io/key'},
        ):
            candidate = dict(env)
            for key, value in overrides.items():
                if value is None: candidate.pop(key, None)
                else: candidate[key] = value
            with self.subTest(overrides=overrides), patch.dict(os.environ, candidate, clear=True), patch.object(f, 'ROOT', self.root), patch.object(f, 'clean_source_commit', return_value='a'*40), patch.object(f, 'verify_build', return_value='forge') as build, patch.object(f, 'config_path', return_value=self.root/'config.json'), patch.object(f.subprocess, 'run') as run, patch.object(f, 'ReadOnlyRPC') as rpc:
                with self.assertRaisesRegex(RuntimeError, 'STOP (DEPLOYLIVE_EXPECTED_CHAIN_ID required or invalid|invalid checker provider pair|production requires DEPLOYLIVE_EXPECTED_CHAIN_ID 10 or 11155111)'):
                    f.stage('predict', ['--production', '--evidence', str(self.root)])
                run.assert_not_called()
                build.assert_not_called()
                rpc.assert_not_called()


import json
import test_ddf4


class AllowlistKeepsCheckerInputs(unittest.TestCase):
    setUp = test_ddf4.Ddf4Test.setUp
    api = test_ddf4.Ddf4Test.api
    endpoint_files = test_ddf4.Ddf4Test.endpoint_files

    def test_allowlist_keeps_second_provider_and_expected_chain(self):
        c = self.api(); keys = c.input_keys(); values = {k: 'value' for k in keys}
        values.update({k: '' for k in keys if k.endswith('_NO_CREDENTIAL')})
        values.update(self.endpoint_files(keys))
        values['DEPLOYLIVE_EVIDENCE_DIR'] = str(self.root/'evidence'); values['DEFAULT_CACHE_PATH'] = str(self.root/'build-cache')
        path = self.root/'approved.inputs'; path.write_text('\n'.join(k+'='+json.dumps(x) for k, x in values.items()))
        env = c.load_inputs(path, {'UNLISTED': 'no', 'DEPLOYLIVE_ENDPOINT_PROVIDER': 'Alchemy',
                                   'DEPLOYLIVE_SECOND_ENDPOINT_PROVIDER': 'Tenderly', 'DEPLOYLIVE_EXPECTED_CHAIN_ID': '11155111'},
                            commit_reader=lambda: 'a'*40)
        self.assertEqual(env['DEPLOYLIVE_SECOND_ENDPOINT_PROVIDER'], 'Tenderly')
        self.assertEqual(env['DEPLOYLIVE_EXPECTED_CHAIN_ID'], '11155111')
        self.assertNotIn('UNLISTED', env)


if __name__ == '__main__':
    unittest.main()
