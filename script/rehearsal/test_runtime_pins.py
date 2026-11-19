import unittest
import importlib


class RuntimePinsTest(unittest.TestCase):
    def test_no_immutables(self):
        pins = importlib.import_module('runtime_pins')
        value = pins.runtime_pin({'object': '0x600100', 'immutableReferences': {}}, 500)
        self.assertEqual(value['maskedRuntimeKeccak'], value['rawRuntimeKeccak'])
        self.assertEqual(value['runtimeLength'], '3')

    def test_immutable_ranges(self):
        pins = importlib.import_module('runtime_pins')
        runtime = {'object': '0x60000000', 'immutableReferences': {'1': [{'start': 1, 'length': 2}]}}
        pin = pins.runtime_pin(runtime, 500)
        self.assertTrue(pins.matches_pin(pin, '0x60abcd00'))
        self.assertFalse(pins.matches_pin(pin, '0x61abcd00'))
        self.assertFalse(pins.matches_pin(pin, '0x'))
        for invalid in ({'start': '-1', 'length': '1'}, {'start': '0', 'length': '0'}, {'start': '3', 'length': '2'}):
            bad = dict(pin, immutableRanges=[dict(id='1', **invalid)])
            self.assertFalse(pins.matches_pin(bad, '0x60abcd00'))
        pin['maskedRuntimeKeccak'] = '0x' + '00' * 32
        self.assertFalse(pins.matches_pin(pin, '0x60abcd00'))

    def test_release_check_and_tampered_hash(self):
        import json
        import subprocess
        import sys
        import tempfile
        from pathlib import Path
        root = Path(__file__).resolve().parents[2]
        with tempfile.TemporaryDirectory(dir=root/'cache') as tmp:
            path = Path(tmp)/'runtime-pins.10.json'
            path.write_bytes((root/'deployments/runtime-pins.10.json').read_bytes())
            (path.parent/'creation-pins.10.json').write_bytes((root/'deployments/creation-pins.10.json').read_bytes())
            command = [sys.executable, str(root/'script/rehearsal/runtime_pins.py'), str(path), '--check', '--artifacts', str(root/'contracts/test/fixtures/deploylive/release-artifacts')]
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            obj = json.loads(path.read_text())
            admin = obj['artifacts']['SuperPaymasterAdmin']
            self.assertEqual(admin['creationPin'], 'embedded in SuperPaymaster')
            self.assertEqual(admin['optimizerRuns'], '500')
            self.assertNotIn('SuperPaymasterAdmin', json.loads((path.parent/'creation-pins.10.json').read_text()))
            obj['artifacts']['Registry']['maskedRuntimeKeccak'] = '0x' + '00'*32
            path.write_text(json.dumps(obj))
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('runtime pin mismatch', result.stderr)
            self.assertEqual((root/'deployments/runtime-pins.10.json').read_bytes(), (root/'deployments/runtime-pins.31337.json').read_bytes())
            self.assertEqual((root/'deployments/runtime-pins.10.json').read_bytes(), (root/'deployments/runtime-pins.11155111.json').read_bytes())

    def test_release_immutable_mutation(self):
        import runtime_pins as pins
        from deploylive_runtime import matches
        from test_deploylive_postdeploy_check import fixture_artifact as release_artifact
        proxy = pins.runtime_pin(release_artifact('ERC1967Proxy')['deployedBytecode'], 500)
        self.assertFalse(proxy['hasImmutables'])
        self.assertEqual(proxy['maskedRuntimeKeccak'], proxy['rawRuntimeKeccak'])
        runtime = release_artifact('SuperPaymaster')['deployedBytecode']
        pin = pins.runtime_pin(runtime, 500)
        code = bytearray.fromhex(runtime['object'][2:])
        reference = pin['immutableRanges'][0]
        code[int(reference['start'])] ^= 1
        actual = '0x' + code.hex()
        self.assertTrue(matches(runtime, actual))
        self.assertTrue(pins.matches_pin(pin, actual))
        self.assertNotEqual(pins.keccak(actual), pin['rawRuntimeKeccak'])
        code[0] ^= 1
        self.assertFalse(matches(runtime, '0x' + code.hex()))
        self.assertFalse(pins.matches_pin(pin, '0x' + code.hex()))

    def test_clean_build_preserves_solidity_sources(self):
        from pathlib import Path
        from unittest.mock import patch
        import creation_pins
        def build(command, cwd, **kwargs):
            self.assertTrue((Path(cwd)/'script/evidence/fixtures/A4CreditControl.sol').is_file())
        with patch.object(creation_pins.subprocess, 'run', side_effect=build):
            self.assertEqual(creation_pins.clean_build_pins(lambda directory: {}), {})
