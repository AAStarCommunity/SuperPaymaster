"""Round five codehash bindings and scoped compiler metadata."""
import json
import unittest
from unittest.mock import patch
import deploylive_readback as r
import runtime_pins as pins
import test_deploylive_postdeploy_check as fixture


class Round5Test(unittest.TestCase):
    run_checker = fixture.CheckerTest.run_checker

    def test_codehash_matches_deployed_helper(self):
        records = []
        with patch.object(pins, 'build_declarations', side_effect=AssertionError('checker must not read AST')):
            rc, out = self.run_checker(capture_record=records)
        self.assertEqual(rc, 0, out)
        items = {c['configKey']: c for c in records[0]['contracts']}
        for field, target in [('implementationCodehash', 'xPNTsTokenV2Impl'),
                              ('extensionCodehash', 'xPNTsTokenV2Ext')]:
            self.assertIn('PASS  immutable xPNTsFactoryV2.' + field, out)
            binding = items['xPNTsFactoryV2']['immutableBindings'][field]
            self.assertEqual(binding['value'], items[target]['runtimeKeccak'])
            self.assertEqual(binding['codehashOf'], 'config:' + target)

    def test_wrong_codehash_fails(self):
        for field in ('implementationCodehash', 'extensionCodehash'):
            with self.subTest(field=field):
                rc, out = self.run_checker(('immutable', 'xPNTsFactoryV2', field, '0x' + 'ab'*32))
                self.assertEqual(rc, 1, out)
                self.assertIn('FAIL  immutable xPNTsFactoryV2.' + field, out)

    def test_artifacts_do_not_need_build_info(self):
        with patch.object(pins, 'build_declarations', side_effect=AssertionError('AST forbidden')):
            actual = pins.artifact_pins(r.ROOT/'out', r.ROOT/'deployments/creation-pins.10.json', derive_types=False)
        expected = json.loads((r.ROOT/'deployments/runtime-pins.10.json').read_text())
        for pin in expected['artifacts'].values():
            for ref in pin['immutableRanges']:
                ref.pop('name')
                ref.pop('type')
        self.assertEqual(actual, expected)

    def test_clean_build_info_is_subprocess_only(self):
        import os
        import creation_pins
        before = dict(os.environ)
        def build(command, cwd, env, **kwargs):
            self.assertEqual(env['FOUNDRY_BUILD_INFO'], 'true')
            self.assertEqual(env['FOUNDRY_OUT'], 'out-clean')
            self.assertEqual((cwd/'foundry.toml').read_bytes(), (r.ROOT/'foundry.toml').read_bytes())
        with patch.object(creation_pins.subprocess, 'run', side_effect=build):
            creation_pins.clean_build_pins(lambda _: None, build_info=True)
        self.assertEqual(dict(os.environ), before)

    def test_artifact_check_rejects_untyped_committed_range(self):
        import contextlib
        import io
        import sys
        import tempfile
        from pathlib import Path
        with tempfile.TemporaryDirectory(dir=r.ROOT/'cache') as tmp:
            path = Path(tmp)/'runtime-pins.10.json'
            expected = json.loads((r.ROOT/'deployments/runtime-pins.10.json').read_text())
            actual = json.loads(json.dumps(expected))
            for pin in actual['artifacts'].values():
                for ref in pin['immutableRanges']:
                    ref.pop('name')
                    ref.pop('type')
            for field in ('name', 'type'):
                bad = json.loads(json.dumps(expected))
                ref = next(p['immutableRanges'][0] for p in bad['artifacts'].values() if p['immutableRanges'])
                del ref[field]
                path.write_text(json.dumps(bad))
                with self.subTest(field=field), patch.object(sys, 'argv', ['pins', str(path), '--check', '--artifacts', 'unused']), patch.object(pins, 'artifact_pins', return_value=actual), contextlib.redirect_stdout(io.StringIO()):
                    with self.assertRaisesRegex(ValueError, 'untyped committed immutable'):
                        pins.main()

    def test_clean_check_compares_types(self):
        import sys
        expected = json.loads((r.ROOT/'deployments/runtime-pins.10.json').read_text())
        ref = next(p['immutableRanges'][0] for p in expected['artifacts'].values() if p['immutableRanges'])
        ref['type'] = 'bytes32' if ref['type'] != 'bytes32' else 'uint256'
        with patch.object(sys, 'argv', ['pins', str(r.ROOT/'deployments/runtime-pins.10.json'), '--check']), patch.object(pins, 'clean_build_pins', return_value=expected) as build:
            with self.assertRaisesRegex(ValueError, 'runtime pin mismatch'):
                pins.main()
            self.assertTrue(build.call_args.kwargs['build_info'])
