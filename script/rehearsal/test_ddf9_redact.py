"""redact_error must not treat a checker comparison as a credential (acceptance at 3e80d173)."""
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from deploylive_deploy_day import redact_error
import deploylive_controls as c
import tempfile
from types import SimpleNamespace

FIXTURE = Path(__file__).resolve().parent / 'fixtures/deploy-day/checker-189.txt'


class RedactTest(unittest.TestCase):
    def test_real_checker_output_is_unchanged(self):
        # Real post-deploy checker output (189 rows, no URL): it must survive redaction verbatim,
        # otherwise safe_logs replaces it with REDACTED text after every broadcast.
        text = FIXTURE.read_text()
        self.assertIn('SP.APNTS_TOKEN == expected', text)
        self.assertIn('SUMMARY 189 passed, 0 failed, 189 total', text)
        self.assertEqual(redact_error(text), text)

    def test_safe_logs_keeps_checker_output_after_broadcast(self):
        base = Path(__file__).resolve().parents[2] / 'cache/ddf9'; base.mkdir(parents=True, exist_ok=True)
        env = {'DEPLOYLIVE_RPC': 'http://127.0.0.1:8545',
               'DEPLOYLIVE_SOURCE_RPC': 'https://a.example/v2/k3yAbc123def456',
               'DEPLOYLIVE_SECOND_RPC': 'https://b.example/public'}
        text = FIXTURE.read_text()
        with tempfile.TemporaryDirectory(dir=base) as tmp:
            evidence = Path(tmp)
            c.safe_logs(evidence, 'checker', SimpleNamespace(stdout=text, stderr=''), env, after_broadcast=True)
            self.assertEqual((evidence/'checker.stdout.log').read_text(), text)
            self.assertFalse((evidence/'REDACTED_AFTER_BROADCAST').exists())
            # Control: a real credential in the same stream is still redacted after broadcast.
            c.safe_logs(evidence, 'checker2', SimpleNamespace(stdout=text + 'k3yAbc123def456\n', stderr=''), env, after_broadcast=True)
            self.assertNotIn('k3yAbc123def456', (evidence/'checker2.stdout.log').read_text())
            self.assertTrue((evidence/'REDACTED_AFTER_BROADCAST').exists())
            # A later redaction appends; both streams stay recorded and reach the PASS record.
            c.safe_logs(evidence, 'checker3', SimpleNamespace(stdout='', stderr='k3yAbc123def456'), env, after_broadcast=True)
            self.assertEqual((evidence/'REDACTED_AFTER_BROADCAST').read_text(), 'checker2.stdout\nchecker3.stderr\n')
            self.assertEqual(c.redacted_streams(evidence), ['checker2.stdout', 'checker3.stderr'])
        with tempfile.TemporaryDirectory(dir=base) as tmp:
            self.assertEqual(c.redacted_streams(Path(tmp)), [])

    def test_checker_separator_is_not_an_assignment(self):
        for row in ('PASS  runtime gToken :: release runtime pin; compiler immutable references masked',
                    'PASS  version gToken :: GToken-2.2.0'):
            with self.subTest(row=row):
                self.assertEqual(redact_error(row), row)
        self.assertNotIn('abc123', redact_error('gToken: abc123'))

    def test_assignments_still_redacted(self):
        for raw in ('token=abc123', 'TOKEN: abc123', 'access_token = "abc123"', 'api_key=abc123',
                    'password:abc123', '"secret": "abc123"', 'Authorization=abc123'):
            with self.subTest(raw=raw):
                self.assertNotIn('abc123', redact_error(raw))
        self.assertNotIn('abc123', redact_error('Bearer abc123'))
        self.assertNotIn('host.example', redact_error('see https://host.example/k'))


if __name__ == '__main__':
    unittest.main()
