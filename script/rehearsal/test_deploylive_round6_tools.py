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
        # Rule change (DSR 2026-11-19): only credential-like path/query segments are needles (>=16
        # chars, or >=8 with letters and digits). A generic word such as 'private' no longer is: a
        # generic 6-character endpoint word matched a forge function name and stopped a deploy.
        url = 'https://rpc.example/private/k3yAbc123def456'
        with tempfile.TemporaryDirectory(dir=OUTPUT) as tmp:
            path = Path(tmp)/'nested'; path.mkdir()
            evidence = path/'receipt.bin'
            for leak in (url, 'rpc.example', 'k3yAbc123def456', 'K3YABC123DEF456', '0x' + f'{123456789:064x}', '123456789'):
                evidence.write_bytes(leak.encode())
                with self.subTest(leak=leak), self.assertRaisesRegex(RuntimeError, r'endpoint matched in nested/receipt.bin'):
                    r.scan_evidence(Path(tmp), url, [123456789])
            for benign in (b'path', b'private', b'PASS receipt redacted'):
                evidence.write_bytes(benign)
                r.scan_evidence(Path(tmp), url, [123456789])

    def test_generic_endpoint_word_in_real_forge_record(self):
        # Regression for the 1bda832d acceptance stop: a generic word of a gateway-style endpoint
        # appears in the real forge broadcast record (function names). Old rule: stop; new rule: pass.
        record = (Path(__file__).resolve().parent/'fixtures/deploy-day/broadcast-97.json').read_bytes()
        self.assertIn(b'Aggregator', record)
        url = 'https://sepolia.gateway.example/Aggregator/7Gk2xQ9mWb4Lp8Rt3Vz6Ha'
        r.scan_content(record, url, [], 'DEPLOYLIVE_SECOND_RPC', 'run-latest.json')
        old_rule = {f.lower() for f in url.split('/')[3:] if len(f) >= 6}
        self.assertTrue(any(f.encode() in record.lower() for f in old_rule), 'old rule would have matched')
        with self.assertRaisesRegex(RuntimeError, 'DEPLOYLIVE_SECOND_RPC matched in run-latest.json'):
            r.scan_content(record + b' 7gk2xq9mwb4lp8rt3vz6ha', url, [], 'DEPLOYLIVE_SECOND_RPC', 'run-latest.json')

    def test_self_check_refuses_unguardable_endpoint(self):
        for url in ('https://rpc.example/', 'https://rpc.example/short', 'https://rpc.example/onlyletterswords'[:-1]):
            if any(r.credential_like(f) for f in url.split('/')[3:] if f):
                continue
            with self.subTest(url=url), self.assertRaisesRegex(RuntimeError, 'cannot guard'):
                r.credential_fragments(url, strict=True)
        self.assertEqual(r.credential_fragments('http://127.0.0.1:8545', strict=True), set())
        self.assertIn('k3yAbc123def456', r.credential_fragments('https://a.example/v2/k3yAbc123def456', strict=True))

    def test_round7_runtime_masks_only_immutable_ranges(self):
        from deploylive_runtime import matches
        expected = {'object': '0x01020304', 'immutableReferences': {'7': [{'start': 1, 'length': 2}]}}
        self.assertTrue(matches(expected, '0x01ffff04'))
        self.assertFalse(matches(expected, '0x01ffff05'))
        self.assertFalse(matches(expected, '0x01ffff'))
        self.assertFalse(matches({'object': '0x'}, '0x'))
        expected['immutableReferences']['7'][0]['length'] = 9
        self.assertFalse(matches(expected, '0x01020304'))
