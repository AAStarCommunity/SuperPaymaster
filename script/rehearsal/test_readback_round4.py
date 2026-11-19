"""Round four regressions; all transport is simulated."""
import json
import os
from pathlib import Path
import unittest
from unittest.mock import patch
import deploylive_readback as r
import test_deploylive_postdeploy_check as fixture
addr, ZERO, fixture_artifact = fixture.addr, fixture.ZERO, fixture.fixture_artifact


class Round4Test(unittest.TestCase):
    run_checker = fixture.CheckerTest.run_checker

    def test_b1_call_time_selection(self):
        marker = {'fixture': True}
        with patch('deploylive_runtime.release_artifact', return_value=marker):
            self.assertIs(fixture_artifact('SuperPaymaster'), marker)

    def test_b2_typed_pins(self):
        pins = json.loads((r.ROOT/'deployments/runtime-pins.10.json').read_text())['artifacts']
        for name, pin in pins.items():
            for ref in pin['immutableRanges']:
                with self.subTest(artifact=name, id=ref['id']):
                    self.assertTrue(ref.get('name'))
                    self.assertTrue(ref.get('type'))

    def test_b2_helper_mutations(self):
        for artifact, name in [('SuperPaymaster', 'EXTENSION'), ('xPNTsFactoryV2', 'implementation'),
                               ('xPNTsTokenV2', 'EXTENSION'), ('xPNTsFactory', 'implementation')]:
            for value in (addr(999), ZERO):
                with self.subTest(artifact=artifact, value=value):
                    rc, out = self.run_checker(('immutable', artifact, name, value))
                    self.assertEqual(rc, 1, out)
                    self.assertIn('FAIL  readback snapshot policy', out)

    def test_b2_missing_policy(self):
        rc, out = self.run_checker('missing_immutable_policy')
        self.assertEqual(rc, 1, out)

    def test_b2_nonzero_helpers(self):
        for key in ('spAdminImpl', 'xPNTsTokenV1Impl', 'xPNTsTokenV2Impl', 'xPNTsTokenV2Ext'):
            with self.subTest(key=key):
                rc, out = self.run_checker(('config', key, ZERO))
                self.assertEqual(rc, 1, out)

    def test_b2_recorded_bindings(self):
        records = []
        rc, out = self.run_checker(capture_record=records)
        self.assertEqual(rc, 0, out)
        items = {item['configKey']: item for item in records[0]['contracts']}
        for key, name, target in (('spImpl', 'EXTENSION', 'spAdminImpl'),
                                  ('xPNTsFactoryV2', 'implementation', 'xPNTsTokenV2Impl'),
                                  ('xPNTsTokenV2Impl', 'EXTENSION', 'xPNTsTokenV2Ext'),
                                  ('xPNTsFactory', 'implementation', 'xPNTsTokenV1Impl')):
            with self.subTest(key=key):
                binding = items[key]['immutableBindings'][name]
                self.assertEqual(binding['value'], items[target]['address'])
                self.assertIn('config:' + target, binding['resolvesTo'])
                self.assertIs(binding['policyMatches'], True)
        self.assertEqual(items['spImpl']['immutableBindings']['__self']['value'], items['spImpl']['address'])
        self.assertIsNone(items['pnts']['immutableBindings'])

    def test_n3_absent_row(self):
        rc, out = self.run_checker()
        self.assertEqual(rc, 0, out)
        self.assertIn('runtime pnts :: zero address; not deployed', out)

    def test_n4_redaction(self):
        from deploylive_deploy_day import redact_error
        for text in ('token::x', 'password=:x', 'token: x'):
            with self.subTest(text=text): self.assertNotIn('x', redact_error(text))
        for text in ('gToken :: GToken-2.2.0', 'SP.APNTS_TOKEN == expected'):
            self.assertEqual(redact_error(text), text)

class EarlyInputsTest(unittest.TestCase):
    def test_n1_explicit_evidence_and_invalid_args_preserve_file(self):
        import tempfile
        import subprocess
        import sys
        with tempfile.TemporaryDirectory(dir=r.ROOT/'cache') as tmp:
            cfg = Path(tmp)/'config.json'; cfg.write_text('{}')
            evidence = Path(tmp)/'readback.json'; evidence.write_text('keep')
            env = dict(os.environ)
            env.pop('DEPLOYLIVE_EVIDENCE_DIR', None); env.pop('DEPLOYLIVE_LOCAL_EVIDENCE', None)
            command = [sys.executable, str(r.ROOT/'script/rehearsal/deploylive_postdeploy_check.py'), 'unused', str(cfg), addr(1), addr(2)]
            result = subprocess.run(command, env=env, capture_output=True, text=True)
            self.assertIn('evidence directory', result.stdout + result.stderr)
            self.assertEqual(evidence.read_text(), 'keep')
            env['DEPLOYLIVE_EVIDENCE_DIR'] = tmp
            result = subprocess.run(command + ['--bad'], env=env, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(evidence.read_text(), 'keep')

    def test_n2_provider_validated_before_commit_or_endpoints(self):
        import deploylive_controls as c
        from test_ddf8_no_credential import NoCredentialTest
        fixture = NoCredentialTest(); fixture.setUp()
        try:
            path = fixture.inputs(DEPLOYLIVE_SECOND_RPC_NO_CREDENTIAL='1')
            for provider in ('', 'https://invalid'):
                with self.subTest(provider=provider), self.assertRaisesRegex((RuntimeError, ValueError), 'provider NAME required'):
                    c.load_inputs(path, {'DEPLOYLIVE_ENDPOINT_PROVIDER': provider}, commit_reader=lambda: 'a'*40)
        finally: fixture.tearDown()

class ImmutableBytesTest(unittest.TestCase):
    def test_no_getter_required_and_all_references_canonical(self):
        pin = {'immutableRanges': [dict(id='7', name='hidden', type='contract Helper', start=str(i), length='32') for i in (1, 33)]}
        rule = {'hidden': {'allowed': ['config:helper'], 'why': 'Constructor helper'}}
        word = bytes.fromhex(addr(123)[2:].zfill(64))
        code = '0x' + (b'\x60' + word + word).hex()
        result = r.immutable_bindings(pin, code, rule, {addr(123).lower(): ['config:alias', 'config:helper']})
        self.assertEqual(result['hidden']['value'].lower(), addr(123).lower())
        self.assertTrue(result['hidden']['policyMatches'])
        for raw in (b'\x60'+word+bytes(32), b'\x60'+b'\x01'+word[1:]+word, b'\x60'+word+word[:-1]):
            with self.subTest(raw=raw.hex()), self.assertRaises(ValueError):
                r.immutable_bindings(pin, '0x'+raw.hex(), rule, {addr(123).lower(): ['config:helper']})
        for entries in ({}, dict(rule, stale=rule['hidden'])):
            with self.assertRaises(ValueError): r.immutable_bindings(pin, code, entries, {})

    def test_zero_requires_explicit_label_and_reason(self):
        pin = {'immutableRanges': [dict(id='1', name='hidden', type='address', start='0', length='32')]}
        code = '0x'+'00'*32
        for rule in ({'allowed': ['config:helper'], 'why': 'Alias'}, {'allowed': ['zero'], 'why': ''}):
            with self.assertRaises(ValueError): r.immutable_bindings(pin, code, {'hidden': rule}, {ZERO: ['zero','config:helper']})
        result = r.immutable_bindings(pin, code, {'hidden': {'allowed': ['zero'], 'why': 'Intentionally absent'}}, {ZERO: ['zero']})
        self.assertEqual(result['hidden']['value'], ZERO)

    def test_full_ast_missing_or_stale_policy_fails(self):
        import runtime_pins as p
        with self.assertRaisesRegex(ValueError, 'full build-info AST'):
            p.build_declarations(Path('out'), 'Imported', {'deployedBytecode': {'object': '0x60', 'immutableReferences': {'1': []}}}, [])
        pins = {'Imported': {'immutableRanges': [dict(id='1', name='hidden', type='address', start='0', length='32')]}}
        for entries in ({'Imported': {}}, {'Imported': {'hidden': {'allowed':['zero'], 'why':'absent'}, 'stale': {}}}):
            with self.assertRaises(ValueError): r.validate_immutable_policy(pins, {'immutableBindings': entries}, {}, {})

class FullAstTest(unittest.TestCase):
    def test_imported_declaration_and_matching_compilation(self):
        import runtime_pins as p
        artifact = {'deployedBytecode': {'object': '0x60', 'immutableReferences': {'17': [{'start': 0, 'length': 32}]}}}
        node = {'nodeType': 'VariableDeclaration', 'id': 17, 'name': 'hidden', 'mutability': 'immutable',
                'typeDescriptions': {'typeString': 'contract Imported'}}
        build = {'output': {'contracts': {'Main.sol': {'Main': {'evm': {'deployedBytecode': {'object': '60'}}}}},
                            'sources': {'Imported.sol': {'ast': {'nodes': [node]}}}}}
        self.assertEqual(p.build_declarations(Path('unused'), 'Main', artifact, [build]),
                         {'17': {'name': 'hidden', 'type': 'contract Imported'}})
        bad = json.loads(json.dumps(build)); bad['output']['sources']['Imported.sol']['ast']['nodes'][0]['name'] = 'wrong'
        with self.assertRaises(ValueError): p.build_declarations(Path('unused'), 'Main', artifact, [build, bad])
        bad['output']['contracts']['Main.sol']['Main']['evm']['deployedBytecode']['object'] = '61'
        self.assertEqual(p.build_declarations(Path('unused'), 'Main', artifact, [build, bad])['17']['name'], 'hidden')
