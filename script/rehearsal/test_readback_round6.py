"""DSR immutable bindings and the main compiler-configuration fence."""
import hashlib
import json
import subprocess
import unittest
import deploylive_readback as r
import test_deploylive_postdeploy_check as fixture

MAIN_FOUNDRY_SHA256 = 'ca7bafd6efb7a011dbfa6b20f97b44d05a68cb2b40b3c7bd63ad9940edd39971'


class Round6Test(unittest.TestCase):
    run_checker = fixture.CheckerTest.run_checker

    def test_constructor_bindings_recorded(self):
        records = []
        rc, out = self.run_checker(capture_record=records)
        self.assertEqual(rc, 0, out)
        items = {c['configKey']: c for c in records[0]['contracts']}
        cap = items['gToken']['immutableBindings']['_cap']
        self.assertEqual(cap, dict(value=str(21_000_000 * 10**18), expectedUint=str(21_000_000 * 10**18), policyMatches=True))
        channel = items['microPaymentChannel']
        self.assertEqual(channel['immutableBindings']['_cachedThis']['value'], channel['address'])
        self.assertIn('PASS  immutable gToken._cap', out)
        self.assertIn('PASS  immutable microPaymentChannel._cachedThis', out)
        # Record validation must not trust a forged policyMatches flag.
        cap['value'] = '1'
        policy = json.loads((r.ROOT/'deployments/readback-policy.json').read_text())
        with self.assertRaisesRegex(ValueError, 'record uint immutable mismatch'):
            # The cap occurs after proxy rows; retain their recorded slot expectations.
            r.validate_record(records[0], {k: v['address'] for k, v in items.items()}, policy)

    def test_different_cap_fails(self):
        rc, out = self.run_checker(('immutable', 'GTokenAuthorization', '_cap', hex(22_000_000 * 10**18)))
        self.assertEqual(rc, 1, out)
        self.assertIn('FAIL  immutable gToken._cap', out)

    def test_channel_self_address_fails(self):
        rc, out = self.run_checker(('immutable', 'MicroPaymentChannel', '_cachedThis', fixture.addr(999)))
        self.assertEqual(rc, 1, out)
        self.assertIn('FAIL  immutable microPaymentChannel._cachedThis', out)

    def test_channel_high_bytes_fail(self):
        # Correct low 20 bytes, nonzero high twelve bytes.
        rc, out = self.run_checker(('immutable', 'MicroPaymentChannel', '_cachedThis', hex((1 << 160) + 13)))
        self.assertEqual(rc, 1, out)

    def test_proxy_self_addresses_fail(self):
        policy = json.loads((r.ROOT/'deployments/readback-policy.json').read_text())
        records = []
        rc, out = self.run_checker(capture_record=records)
        self.assertEqual(rc, 0, out)
        items = {c['configKey']: c for c in records[0]['contracts']}
        for artifact, impl, proxy in [('SuperPaymaster', 'spImpl', 'superPaymaster'),
                                      ('Registry', 'registryImpl', 'registry'),
                                      ('SuperPaymasterAdmin', 'spAdminImpl', 'superPaymaster')]:
            with self.subTest(artifact=artifact):
                self.assertEqual(policy['immutableBindings'][artifact]['__self']['allowed'], ['config:' + impl])
                self.assertEqual(items[impl]['immutableBindings']['__self']['value'], items[impl]['address'])
                self.assertNotEqual(items[impl]['address'], items[proxy]['address'])
                rc, out = self.run_checker(('immutable', artifact, '__self', items[proxy]['address']))
                self.assertEqual(rc, 1, out)
                self.assertIn('FAIL  readback snapshot policy', out)

    def test_foundry_matches_main(self):
        main = subprocess.run(['git', 'show', 'origin/main:foundry.toml'], cwd=r.ROOT, capture_output=True)
        actual = (r.ROOT/'foundry.toml').read_bytes()
        if main.returncode == 0:
            self.assertEqual(actual, main.stdout, 'foundry.toml differs from origin/main')
        else:
            self.assertEqual(hashlib.sha256(actual).hexdigest(), MAIN_FOUNDRY_SHA256)
