"""Runner controls using a stub engine, never the real nightly binary."""
import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import floor_margin_run as runner
from test_floor_margin_extract import HEADER, SUMMARY, fixture

ROOT = Path(__file__).resolve().parents[2]
(ROOT / '.codex-work').mkdir(exist_ok=True)
HEAD = subprocess.check_output(['git', '-C', str(ROOT), 'rev-parse', 'HEAD'], text=True).strip()


class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir=ROOT / '.codex-work')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.binary = self.root / 'forge-stub'
        self.out = self.root / 'evidence'
        self.real_output = subprocess.check_output

    def stub(self, version='forge fixture\nCommit SHA: ' + 'b' * 40, rc=0):
        log = HEADER + ''.join(fixture()) + SUMMARY
        self.binary.write_text('#!/usr/bin/env python3\nimport json, os, sys\n'
                               f'if sys.argv[1:] == ["--version"]:\n    print({version!r})\n'
                               'else:\n'
                               f'    open({str(self.root / "observed.json")!r}, "w").write(json.dumps(dict(argv=sys.argv, profile=os.environ.get("PROFILE_AMSTERDAM"))))\n'
                               f'    print({log!r})\n    sys.exit({rc})\n')
        self.binary.chmod(0o755)

    def checkout(self, status=''):
        # Mock only git status, since the test is running amid uncommitted fixes.
        # HEAD is always read from the real local checkout.
        def output(argv, **kwargs):
            if argv[:4] == ['git', '-C', str(ROOT), 'status']:
                return status
            return self.real_output(argv, **kwargs)
        return patch.object(runner.subprocess, 'check_output', side_effect=output)

    def test_execution_records_observed_values(self):
        self.stub()
        with self.checkout('?? .codex-work/ignored\n'), patch.dict(os.environ, {'HEAD': '0' * 40}):
            report = runner.run(self.binary, self.out, ROOT)
        observed = json.loads((self.root / 'observed.json').read_text())
        self.assertEqual(report['head'], HEAD)
        self.assertEqual(report['argv'], observed['argv'])
        self.assertEqual(report['env'], {'PROFILE_AMSTERDAM': observed['profile']})
        self.assertEqual(report['engine_commit'], 'b' * 40)
        self.assertEqual(report['provenance'], 'executed')
        self.assertIn(runner.TEST, report['sources'])

    def test_foreign_head_cannot_be_supplied(self):
        self.stub()
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as exc:
            runner.main(['--nightly', str(self.binary), '--out-dir', str(self.out), '--head', '0' * 40])
        self.assertEqual(exc.exception.code, 2)
        self.assertFalse(self.out.exists())

    def test_dirty_tree(self):
        self.stub()
        with self.checkout(' M contracts/src/Dirty.sol\n'), self.assertRaisesRegex(ValueError, 'dirty tree'):
            runner.run(self.binary, self.out, ROOT)
        self.assertFalse(self.out.exists())

    def test_existing_evidence_is_not_overwritten(self):
        self.stub()
        self.out.mkdir()
        artifact = self.out / 'floor-margin.json'
        artifact.write_text('previous evidence')
        with self.checkout(), self.assertRaisesRegex(ValueError, 'already contains'):
            runner.run(self.binary, self.out, ROOT)
        self.assertEqual(artifact.read_text(), 'previous evidence')

    def test_version_without_commit(self):
        self.stub(version='forge Version: fixture')
        with self.checkout(), self.assertRaisesRegex(ValueError, '40-hex commit'):
            runner.run(self.binary, self.out, ROOT)
        self.assertFalse(self.out.exists())

    def test_failed_run(self):
        self.stub(rc=7)
        with self.checkout(), self.assertRaisesRegex(ValueError, 'rc=7'):
            runner.run(self.binary, self.out, ROOT)
        self.assertTrue((self.out / 'floor.log').exists())
        self.assertFalse((self.out / 'floor-margin.json').exists())


if __name__ == '__main__':
    unittest.main()
