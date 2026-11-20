"""Offline Daybreak r2 regressions; no node, transport or build output required."""
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import deploylive_readback as r


class Round8Test(unittest.TestCase):
    def test_H1_production_flags_and_node_claims_do_not_authorize(self):
        for chain in (10, 11155111):
            for endpoint in ('https://remote.invalid', 'http://127.0.0.1:8545'):
                with self.subTest(chain=chain, endpoint=endpoint):
                    self.assertFalse(r.single_provider_allowed(chain, endpoint))
        self.assertTrue(r.single_provider_allowed(31337, 'http://127.0.0.1:8545'))
        source = (r.ROOT/'script/rehearsal/deploylive_postdeploy_check.py').read_text()
        self.assertNotIn('anvil_nodeInfo', source)
        self.assertNotIn("os.environ.get('DEPLOYLIVE_REHEARSAL')", source)

    def test_H1_provider_identity_refusals(self):
        for a, b in [('Alchemy', 'Alchemy'), ('Alchemy', 'alchemy'), ('Unknown', 'Infura'), ('Alchemy', 'Unknown'), ('', 'Infura')]:
            with self.subTest(a=a,b=b), self.assertRaises(ValueError):
                r.independent_providers(a, b)
        r.independent_providers('Alchemy', 'Infura')

    def pin(self, name='EXTENSION', kind='bytes32'):
        return {'immutableRanges': [dict(id='1', name=name, type=kind, start='0', length='32')]}

    def test_H2_every_type_requires_entry(self):
        for kind in ('bytes32', 'uint256', 'struct ShortString'):
            with self.subTest(kind=kind), self.assertRaisesRegex(ValueError, 'coverage'):
                r.validate_immutable_policy({'X':self.pin(kind=kind)}, {'immutableBindings':{'X':{}}}, {}, {})

    def test_H2_unknown_address_shape_cannot_hide(self):
        with self.assertRaisesRegex(ValueError, 'unbound immutable has address shape: X.EXTENSION'):
            r.immutable_bindings(self.pin(), '0x'+'00'*12+'fe'*20, {'EXTENSION':{'unbound':'known gap'}}, {}, artifact='X')

    def test_H2_chain_id_exact(self):
        rule = {'_cachedChainId':{'chainId':True, 'why':'EIP-712 chain cache'}}
        pin = self.pin('_cachedChainId', 'uint256')
        for chain in (10,11155111,31337):
            good = r.immutable_bindings(pin, '0x'+f'{chain:064x}', rule, {}, chain=chain)
            self.assertEqual(good['_cachedChainId']['value'], str(chain))
            with self.assertRaisesRegex(ValueError, 'immutable binding failed'):
                r.immutable_bindings(pin, '0x'+f'{chain+1:064x}', rule, {}, chain=chain)

    def test_H2_stale_and_mixed_rules(self):
        for rules in ({'stale':{'unbound':'gap'}}, {'EXTENSION':{'unbound':'gap','allowed':['zero'],'why':'bad'}}):
            with self.subTest(rules=rules), self.assertRaises(ValueError):
                r.validate_immutable_policy({'X':self.pin()}, {'immutableBindings':{'X':rules}}, {}, {})

    def test_M1_array_coverage(self):
        for value in ([], ['0x'+'12'*20]):
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, 'coverage'):
                r.validate_config({'recoveryOwners':value}, {}, {}, {})
            r.validate_config({'guardians':value}, {}, {'guardians':'Signing principals'}, {})

    def test_M2_gap_wording(self):
        spec = (r.ROOT/'docs/spec/deploylive-readback-runtime-pins.md').read_text()
        self.assertIn('creation-code pin and plan comparison on the DEPLOYMENT path', spec)
        self.assertIn('the checker alone cannot prove them', spec)
        self.assertNotIn('| `_cachedChainId` |', spec)
        self.assertNotIn('suspected untyped address immutable', spec)

    def test_Lb_evidence_confinement_and_symlinks(self):
        with tempfile.TemporaryDirectory(dir=r.ROOT/'cache') as tmp:
            root = Path(tmp)
            record = root/'readback.json'; record.write_text('preserve')
            self.assertEqual(r.evidence_path(str(root)), record)
            for invalid in (r.ROOT, r.ROOT/'deployments', root/'../..', Path('/tmp')):
                with self.subTest(invalid=invalid), self.assertRaises(ValueError): r.evidence_path(str(invalid))
            link = root/'link'; link.symlink_to(root, target_is_directory=True)
            with self.assertRaises(ValueError): r.evidence_path(str(link))
            record.unlink(); record.symlink_to(root/'other')
            with self.assertRaises(ValueError): r.evidence_path(str(root))

    def test_H1_full_checker_lying_node_and_provider_aliases(self):
        import os
        from test_deploylive_postdeploy_check import CheckerTest
        with patch.dict(os.environ, DEPLOYLIVE_REHEARSAL='1'):
            rc, output = CheckerTest().run_checker('second_missing', op=True)
        self.assertEqual(rc, 1, output)
        self.assertIn('FAIL  second provider', output)
        for primary, secondary in [('Alchemy','Alchemy'), ('Unknown','Infura'), ('Alchemy','Unknown')]:
            rc, output = CheckerTest().run_checker(op=True, primary_provider=primary, secondary_provider=secondary)
            self.assertEqual(rc, 1, output)
            self.assertIn('FAIL  second provider', output)

    def test_H2_unbound_nonaddress_and_repeated_reference(self):
        rule = {'EXTENSION': {'unbound': 'Known gap'}}
        for word in ('00'*32, 'ff'+'00'*31):
            result = r.immutable_bindings(self.pin(), '0x'+word, rule, {}, artifact='X')
            self.assertEqual(result['EXTENSION']['value'], '0x'+word)
        pin = self.pin(); pin['immutableRanges'].append(dict(pin['immutableRanges'][0], start='32'))
        with self.assertRaisesRegex(ValueError, 'inconsistent immutable references'):
            r.immutable_bindings(pin, '0x'+'ff'*32+'ee'*32, rule, {}, artifact='X')

    def test_Lb_direct_invocation_preserves_unrelated_file(self):
        import os
        import subprocess
        import sys
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve(); output = root/'readback.json'; output.write_text('preserve')
            config = root/'config.json'; config.write_text('{}')
            result = subprocess.run([sys.executable, str(r.ROOT/'script/rehearsal/deploylive_postdeploy_check.py'),
                                     'unused', str(config), '0x'+'11'*20, '0x'+'22'*20],
                                    env=dict(os.environ, DEPLOYLIVE_EVIDENCE_DIR=str(root), DEPLOYLIVE_ENDPOINT_PROVIDER='Alchemy', DEPLOYLIVE_EXPECTED_CHAIN_ID='10'),
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn('evidence must be below worktree cache root', result.stdout)
            self.assertEqual(output.read_text(), 'preserve')

    def test_H2_checker_names_unbound_shape_failure(self):
        from test_deploylive_postdeploy_check import CheckerTest
        rc, output = CheckerTest().run_checker(('immutable', 'APNTsCapped', '_hashedName', '0x'+'fe'*20))
        self.assertEqual(rc, 1, output)
        self.assertIn('unbound immutable has address shape: APNTsCapped._hashedName', output)

    def test_H2_checker_chain_cache_failure(self):
        from test_deploylive_postdeploy_check import CheckerTest
        for artifact in ('APNTsCapped','GTokenAuthorization','xPNTsToken','MicroPaymentChannel'):
            rc, output = CheckerTest().run_checker(('immutable', artifact, '_cachedChainId', hex(1)))
            self.assertEqual(rc, 1, output)
            self.assertIn('FAIL  readback snapshot policy', output)
