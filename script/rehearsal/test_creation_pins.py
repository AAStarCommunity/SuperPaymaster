import importlib
import json
from pathlib import Path
import tempfile
import unittest

OUTPUT = Path(__file__).resolve().parents[2] / "cache/deploylive-tests/python"
OUTPUT.mkdir(parents=True, exist_ok=True)

class CreationPinsTest(unittest.TestCase):
    def test_pin_selects_release_profile_and_detects_tampering(self):
        pins = importlib.import_module('creation_pins')
        with tempfile.TemporaryDirectory(dir=OUTPUT) as tmp:
            root = Path(tmp)
            for runs in (200, 500):
                obj = {'metadata': {'settings': {'optimizer': {'runs': runs}, 'evmVersion': 'cancun', 'viaIR': True, 'compilationTarget': {'C.sol': 'C'}}}, 'bytecode': {'object': '0x' + ('aa' if runs == 500 else 'bb')}}
                (root/f'C.{runs}.json').write_text(json.dumps(obj))
            self.assertEqual(pins.creation_bytes(root, 'C', 500), '0xaa')
            with self.assertRaises(ValueError): pins.check_pins({'C': '0xaa'}, {'C': '0xbb'})
            pins.check_pins({'C': '0xaa'}, {'C': '0xaa'})
            obj['bytecode']['object'] = '0xcc'
            (root/'duplicate.json').write_text(json.dumps(obj))
            with self.assertRaises(ValueError): pins.creation_bytes(root, 'C', 500)
