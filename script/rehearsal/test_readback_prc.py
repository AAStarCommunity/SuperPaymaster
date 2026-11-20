"""PR C: extension reachability and release gas tuple, entirely offline."""
import copy
import json
import re
import unittest
from unittest.mock import patch
import deploylive_readback as r
import test_deploylive_postdeploy_check as fixture
fixture_artifact = fixture.fixture_artifact

GAS = [500000, 450000, 5000, 450000, 0, 0, 0, 0, 0]

def encoded(values):
    return '0x' + ''.join(f'{v:064x}' for v in values)

class PrC(unittest.TestCase):
    run_checker = fixture.CheckerTest.run_checker

    def test_release_union_and_source_fallback(self):
        policy = json.loads((r.ROOT/'deployments/readback-policy.json').read_text())
        expected_pairs = {'SuperPaymaster': 'SuperPaymasterAdmin', 'xPNTsTokenV2': 'xPNTsTokenV2Ext'}
        self.assertEqual(policy['extensions'], expected_pairs)
        for core, extension in expected_pairs.items():
            source = next((r.ROOT/'contracts/src').rglob(core + '.sol')).read_text()
            self.assertRegex(source, r'address\s+public\s+immutable\s+EXTENSION')
            fallback = source[source.index('fallback()'):]
            self.assertIn('delegatecall(gas(),', fallback)
            self.assertIn('EXTENSION', fallback)
            expected = set(r.getter_functions(r.release_artifact(core)['abi'])) | set(r.getter_functions(r.release_artifact(extension)['abi']))
            self.assertEqual(set(r.getter_functions(r.enumeration_abi(core, policy))), expected)
            self.assertEqual(set(policy['getters'][core]), expected)
            self.assertEqual(expected - set(r.getter_functions(r.release_artifact(core)['abi'])), {'getMetadata'} if core == 'xPNTsTokenV2' else set())
            mapping = json.loads((r.ROOT/'deployments/readback-artifacts.json').read_text())
            keys = ('superPaymaster', 'spImpl') if core == 'SuperPaymaster' else ('pnts', 'xPNTsTokenV2Impl')
            for key in keys:
                selected = r.PROXY_ABI.get(key, mapping[key])
                self.assertEqual(selected, core)
                self.assertEqual(set(r.getter_functions(r.enumeration_abi(selected, policy))), expected)

    def test_new_fallback_getter_requires_core_policy(self):
        def artifact(name, *args, **kwargs):
            obj = copy.deepcopy(fixture_artifact(name, *args, **kwargs))
            if name == 'xPNTsTokenV2Ext':
                obj['abi'].append(dict(type='function', name='newFallbackAddress', inputs=[], outputs=[dict(type='address')], stateMutability='view'))
            return obj
        policy = json.loads((r.ROOT/'deployments/readback-policy.json').read_text())
        mapping = json.loads((r.ROOT/'deployments/readback-artifacts.json').read_text())
        labels = re.findall(r'"(?:config|external):([^" ]+)"', json.dumps(policy))
        config = dict.fromkeys(set(labels) | set(policy['zeroAllowedConfigKeys']), '0x' + '12'*20)
        with patch.object(r, 'release_artifact', side_effect=artifact):
            with self.assertRaisesRegex(ValueError, r'policy getter coverage: xPNTsTokenV2$'):
                r.validate_policy(policy, mapping, config, config)

    def test_extensions_only_code_and_immutables(self):
        records, trace = [], []
        rc, output = self.run_checker(capture_record=records, request_trace=trace)
        self.assertEqual(rc, 0, output)
        items = {c['configKey']: c for c in records[0]['contracts']}
        for core, ext, shared in [('spImpl', 'spAdminImpl', ['REGISTRY', 'ETH_USD_PRICE_FEED', 'entryPoint']), ('xPNTsTokenV2Impl', 'xPNTsTokenV2Ext', ['PROTOCOL_REGISTRY'])]:
            self.assertEqual(items[ext]['addressGetters'], {})
            self.assertIsNone(items[ext]['version'])
            self.assertFalse(any(args[0] == 'eth_call' and json.loads(args[1])['to'].lower() == items[ext]['address'].lower() for args, _ in trace))
            self.assertTrue(items[ext]['maskedMatchesPin'])
            for field in shared:
                self.assertEqual(items[ext]['immutableBindings'][field]['value'], items[core]['immutableBindings'][field]['value'])
        self.assertIn('getMetadata', items['xPNTsTokenV2Impl']['addressGetters'])
        policy = json.loads((r.ROOT/'deployments/readback-policy.json').read_text())
        for key, core in [('superPaymaster', 'SuperPaymaster'), ('spImpl', 'SuperPaymaster'), ('xPNTsTokenV2Impl', 'xPNTsTokenV2')]:
            self.assertEqual(set(items[key]['addressGetters']), set(policy['getters'][core]))

    def test_default_constants_bound(self):
        release = json.loads((r.ROOT/'docs/release/rq3-runtime-expectations.json').read_text())
        source = (r.ROOT/release['source']).read_text()
        for key, value in zip(('MIN_POST_OP_GAS', 'SETTLE_GAS_BOUND', 'C_WRAP_GAS', 'C_POSTOP_GAS'), GAS):
            self.assertEqual(release[key], value)
            self.assertEqual(int(re.search(r'\b' + key + r' = ([\d_]+)', source)[1].replace('_', '')), release[key])

    def test_gas_words_exact(self):
        for word in range(9):
            for delta in (-1, 1) if word < 4 else (1,):
                values = GAS.copy(); values[word] += delta
                with self.subTest(word=word, delta=delta):
                    rc, output = self.run_checker(('superPaymaster', 'gasParams()', [], encoded(values)))
                    self.assertEqual(rc, 1, output)
                    self.assertIn(f'FAIL  SP.gasParams[{word}]', output)

    def test_gas_pinned_and_replayed(self):
        trace = []
        rc, output = self.run_checker(op=True, check_blocks=True, request_trace=trace)
        self.assertEqual(rc, 0, output)
        self.assertEqual(len(re.findall(r'^PASS  SP.gasParams\[', output, re.M)), 9)
        # The fixture checks every state read's EIP-1898 selector; inspect both providers.
        from test_deploylive_postdeploy_check import digest, addr
        calls = [(args, secondary) for args, secondary in trace if args[0] == 'eth_call' and digest('gasParams()') in args[1]]
        self.assertEqual({secondary for _, secondary in calls}, {False, True})

if __name__ == '__main__': unittest.main()
