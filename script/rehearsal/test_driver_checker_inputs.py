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
        with self.assertRaisesRegex(ValueError, 'DEPLOYLIVE_EXPECTED_CHAIN_ID required'):
            import deploylive_fork_deploy as f
            from deploylive_readback import expected_chain_id
            expected_chain_id({})


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
