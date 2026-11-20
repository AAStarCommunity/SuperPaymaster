"""Explicit per-endpoint NO_CREDENTIAL declaration for keyless endpoints (DSR 2026-11-19)."""
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import deploylive_controls as c


class NoCredentialTest(unittest.TestCase):
    def setUp(self):
        base = Path(__file__).resolve().parents[2] / 'cache/ddf8'; base.mkdir(parents=True, exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(dir=base); self.root = Path(self.tmp.name)
    def tearDown(self):
        self.tmp.cleanup()
    def url_file(self, name, url):
        p = self.root / name; p.write_text(url + '\n'); p.chmod(0o600); return str(p)

    def test_keyless_needs_declaration(self):
        keyless = self.url_file('keyless', 'https://sepolia.gateway.example/public')
        with self.assertRaisesRegex(RuntimeError, 'declare DEPLOYLIVE_SECOND_RPC_NO_CREDENTIAL=1'):
            c.read_endpoint_file('DEPLOYLIVE_SECOND_RPC', keyless)
        self.assertEqual(c.read_endpoint_file('DEPLOYLIVE_SECOND_RPC', keyless, no_credential=True),
                         'https://sepolia.gateway.example/public')

    def test_declaration_contradicted_by_credential_stops(self):
        keyed = self.url_file('keyed', 'https://eth.example/v2/k3yAbc123def456')
        with self.assertRaisesRegex(RuntimeError, 'declared credential-free but has a credential-like segment'):
            c.read_endpoint_file('DEPLOYLIVE_SOURCE_RPC', keyed, no_credential=True)
        self.assertEqual(c.read_endpoint_file('DEPLOYLIVE_SOURCE_RPC', keyed), 'https://eth.example/v2/k3yAbc123def456')

    def inputs(self, **over):
        values = {k: 'value' for k in c.input_keys()}
        values.update({k: '' for k in c.input_keys() if k.endswith('_NO_CREDENTIAL')})
        values.update(DEPLOYLIVE_RPC_FILE=self.url_file('fork', 'http://127.0.0.1:8545'),
                      DEPLOYLIVE_SOURCE_RPC_FILE=self.url_file('a', 'https://a.example/v2/k3yAbc123def456'),
                      DEPLOYLIVE_SECOND_RPC_FILE=self.url_file('b', 'https://b.example/public'),
                      REHEARSAL_SOURCE_RPC_FILE='', DEPLOYLIVE_EVIDENCE_DIR=str(self.root/'ev'), DEFAULT_CACHE_PATH=str(self.root/'b'))
        values.update(over)
        path = self.root / 'inputs.env'
        path.write_text('\n'.join(k + '=' + json.dumps(v) for k, v in values.items()))
        return path

    def test_load_inputs_flag_rules(self):
        with self.assertRaisesRegex(RuntimeError, 'NO_CREDENTIAL=1'):
            c.load_inputs(self.inputs(), {'DEPLOYLIVE_ENDPOINT_PROVIDER':'Fixture'}, commit_reader=lambda: 'a'*40)
        env = c.load_inputs(self.inputs(DEPLOYLIVE_SECOND_RPC_NO_CREDENTIAL='1'), {'DEPLOYLIVE_ENDPOINT_PROVIDER':'Fixture'}, commit_reader=lambda: 'a'*40)
        self.assertEqual(env['DEPLOYLIVE_SECOND_RPC'], 'https://b.example/public')
        with self.assertRaisesRegex(RuntimeError, 'must be empty or 1'):
            c.load_inputs(self.inputs(DEPLOYLIVE_SECOND_RPC_NO_CREDENTIAL='yes'), {'DEPLOYLIVE_ENDPOINT_PROVIDER':'Fixture'}, commit_reader=lambda: 'a'*40)
        with self.assertRaisesRegex(RuntimeError, 'set without REHEARSAL_SOURCE_RPC_FILE'):
            c.load_inputs(self.inputs(DEPLOYLIVE_SECOND_RPC_NO_CREDENTIAL='1', REHEARSAL_SOURCE_RPC_NO_CREDENTIAL='1'), {'DEPLOYLIVE_ENDPOINT_PROVIDER':'Fixture'}, commit_reader=lambda: 'a'*40)

    def test_declaration_is_part_of_the_manifest(self):
        request = self.root / 'pop-request.json'; request.write_text('{}')
        env = c.load_inputs(self.inputs(DEPLOYLIVE_SECOND_RPC_NO_CREDENTIAL='1'), {'DEPLOYLIVE_ENDPOINT_PROVIDER':'Fixture'}, commit_reader=lambda: 'a'*40)
        with_flag = c.manifest_bytes(env, request)
        self.assertIn(b'DEPLOYLIVE_SECOND_RPC_NO_CREDENTIAL=1\n', with_flag)
        self.assertNotEqual(with_flag, c.manifest_bytes(dict(env, DEPLOYLIVE_SECOND_RPC_NO_CREDENTIAL=''), request))


if __name__ == '__main__':
    unittest.main()
