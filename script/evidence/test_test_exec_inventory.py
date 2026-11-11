import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest

from test_exec_inventory import inventory, main

HEADER = 'Ran 2 tests for a.t.sol:C\n'
DECLARED = {'a.t.sol': {'C': ['test_a', 'test_b']}}


class InventoryTests(unittest.TestCase):
    def run_logs(self, *logs, allow=()):
        return inventory(DECLARED, logs, 'fixture', allow)

    def test_all_executed(self):
        report, rc = self.run_logs(HEADER + '[PASS] test_a()\n[PASS] test_b(uint256)')
        self.assertEqual((rc, report['executed'], report['failed']), (0, 2, 0))

    def test_setup_skip(self):
        report, rc = self.run_logs(HEADER + '[SKIP: skipped] setUp()')
        self.assertEqual((rc, len(report['unexecuted'])), (1, 2))
        self.assertEqual({r['reason'] for r in report['unexecuted']}, {'skipped'})

    def test_recap_and_failure(self):
        log = HEADER + '[FAIL: revert] test_a()\n[PASS] test_b()'
        report, rc = self.run_logs(log + '\nFailing tests:\n' + log)
        self.assertEqual((rc, report['executed'], report['failed']), (1, 2, 1))

    def test_union(self):
        report, rc = self.run_logs(HEADER + '[SKIP: skipped] setUp()',
                                  HEADER + '[PASS] test_a()', HEADER + '[PASS] test_b()')
        self.assertEqual((rc, report['executed']), (0, 2))

    def test_allowed_and_specific_reason(self):
        report, rc = self.run_logs(HEADER + '[SKIP: design] setUp()\n[SKIP: special] test_a()',
                                  allow=['design|special'])
        self.assertEqual((rc, report['allowed']), (0, 2))
        self.assertEqual(report['unexecuted'][0]['reason'], 'special')

    def test_missing_record_and_setup_failure(self):
        report, rc = self.run_logs('')
        self.assertEqual((rc, report['unexecuted'][0]['reason']), (1, 'no execution record'))
        report, rc = self.run_logs(HEADER + '[FAIL: broken] setUp()', allow=['broken'])
        self.assertEqual((rc, report['setup_failures']), (1, ['a.t.sol:C']))

    def test_unknown_cli_error_and_output(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).resolve().parents[2] / '.codex-work') as tmp:
            root = Path(tmp)
            (root / 'declared').write_text(json.dumps(DECLARED))
            args = ['--declared', str(root / 'declared'), '--log', str(root / 'log'),
                    '--engine', 'fixture', '--out-json', str(root / 'json'), '--out-md', str(root / 'md')]
            (root / 'log').write_text(HEADER + '[PASS] test_unknown()')
            with contextlib.redirect_stderr(io.StringIO()) as err:
                self.assertEqual(main(args), 2)
            self.assertIn('unknown test', err.getvalue())
            (root / 'log').write_text(HEADER + '[PASS] test_a()\n[PASS] test_b()')
            self.assertEqual(main(args), 0)
            self.assertEqual(json.loads((root / 'json').read_text())['executed'], 2)
            self.assertIn('| fixture | 2 | 2 | 0 | 0 |', (root / 'md').read_text())


if __name__ == '__main__':
    unittest.main()
