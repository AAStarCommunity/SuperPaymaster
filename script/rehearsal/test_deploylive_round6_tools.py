"""Offline round-six tool regressions; temporary files stay in this worktree."""
import importlib
import json
from pathlib import Path
import tempfile
import unittest
import deploylive_rehearse as r

ROOT = Path(__file__).resolve().parent

OUTPUT = Path(__file__).resolve().parents[2] / "cache/deploylive-tests/python"
OUTPUT.mkdir(parents=True, exist_ok=True)

class Round6ToolsTest(unittest.TestCase):
    def test_artifact_creation_runtime_and_missing(self):
        compare = importlib.import_module('compare_artifacts')
        with tempfile.TemporaryDirectory(dir=OUTPUT) as tmp:
            a, b = Path(tmp)/'a', Path(tmp)/'b'
            for d in (a, b):
                (d/'C.sol').mkdir(parents=True)
                (d/'C.sol/C.json').write_text(json.dumps({'bytecode': {'object': '0x00'}, 'deployedBytecode': {'object': '0x01'}}))
            self.assertEqual(compare.compare(a, b), [])
            for key in ('bytecode', 'deployedBytecode'):
                obj = json.loads((a/'C.sol/C.json').read_text()); obj[key]['object'] = '0xff'
                (b/'C.sol/C.json').write_text(json.dumps(obj))
                self.assertEqual(compare.compare(a, b), [('C.sol/C.json', True)])
            (b/'C.sol/C.json').unlink()
            self.assertEqual(compare.compare(a, b), [('C.sol/C.json', True)])

    def test_verbosity_refused_in_flags_environment_and_config(self):
        for args, env, default in [(['-vvv'], {}, 0), (['-v', '-vv'], {}, 0),
                                   (['--verbosity', '3'], {}, 0), ([], {'FOUNDRY_VERBOSITY': '4'}, 0), ([], {}, 3)]:
            with self.subTest(args=args, env=env, default=default), self.assertRaises(RuntimeError):
                r.guard_bls_verbosity(args, env, default)
        r.guard_bls_verbosity(['-vv'], {}, 3)

    def test_evidence_scan_all_files_and_secret_encodings(self):
        with tempfile.TemporaryDirectory(dir=OUTPUT) as tmp:
            path = Path(tmp)/'nested'; path.mkdir()
            evidence = path/'receipt.bin'
            for leak in ('https://rpc.example/private/path', 'rpc.example', 'private', 'path', '0x' + f'{123456789:064x}', '123456789'):
                evidence.write_bytes(leak.encode())
                with self.subTest(leak=leak), self.assertRaises(RuntimeError):
                    r.scan_evidence(Path(tmp), 'https://rpc.example/private/path', [123456789])
            evidence.write_text('PASS receipt redacted')
            r.scan_evidence(Path(tmp), 'https://rpc.example/private/path', [123456789])

    def test_round7_runtime_masks_only_immutable_ranges(self):
        from deploylive_runtime import matches
        expected = {'object': '0x01020304', 'immutableReferences': {'7': [{'start': 1, 'length': 2}]}}
        self.assertTrue(matches(expected, '0x01ffff04'))
        self.assertFalse(matches(expected, '0x01ffff05'))
        self.assertFalse(matches(expected, '0x01ffff'))
        self.assertFalse(matches({'object': '0x'}, '0x'))
        expected['immutableReferences']['7'][0]['length'] = 9
        self.assertFalse(matches(expected, '0x01020304'))
