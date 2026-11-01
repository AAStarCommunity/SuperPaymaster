#!/usr/bin/env python3
"""Offline negative controls; never writes to the supplied evidence directory.

python3 script/evidence/test_rr5_lifecycle_verify.py [run-directory]
"""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

RUNNER = Path(__file__).with_name('rr5-lifecycle-run.py').resolve()
SOURCE = Path(sys.argv.pop(1) if len(sys.argv) > 1 else
              'docs/design/aoa-balance-mode/data/rr5-lifecycle-isolation/run').resolve()


class EvidenceControls(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='rr5-negative-')
        self.addCleanup(self.tmp.cleanup)
        self.out = Path(self.tmp.name)/'run'
        shutil.copytree(SOURCE, self.out)
        self.manifest = json.loads((self.out/'manifest.json').read_text())
        self.commands = [json.loads(s) for s in (self.out/'commands.jsonl').read_text().splitlines()]
        self.row = self.manifest['amsterdam/balance/rr_base']

    def check(self, reason=None):
        (self.out/'manifest.json').write_text(json.dumps(self.manifest))
        for c in self.commands:
            c['sha256'] = hashlib.sha256((self.out/c['log']).read_bytes()).hexdigest()
        (self.out/'commands.jsonl').write_text(''.join(json.dumps(c)+'\n' for c in self.commands))
        (self.out/'SHA256SUMS').write_text(''.join(
            f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n'
            for p in sorted(self.out.iterdir()) if p.name != 'SHA256SUMS'))
        result = subprocess.run([sys.executable, str(RUNNER), '--verify', str(self.out)],
                                text=True, capture_output=True, cwd=RUNNER.parents[2])
        if reason is None:
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('PASS (156, 4044)', result.stdout)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertIn(reason, result.stderr)

    def test_untouched(self):
        result = subprocess.run([sys.executable, str(RUNNER), '--verify', str(self.out)],
                                text=True, capture_output=True, cwd=RUNNER.parents[2])
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_null_band(self):
        for row in self.manifest.values():
            if not row.get('split'): row['non_guard_scan'] = None
        self.check('scan summary')

    def test_substituted_scan(self):
        other = self.manifest['amsterdam/balance/fresh_release']
        self.row['scan'] = other['scan']
        self.row['first_complete_scan'] = other['first_complete_scan']
        self.check("row['scan'] == sid")

    def test_dropped_bisections(self):
        self.commands = [c for c in self.commands if '-bisect-' not in c['id']]
        self.check('command order/identity')

    def test_wrong_selector(self):
        c = next(c for c in self.commands if c['id'] == self.row['scan'])
        p = self.out/c['log']
        p.write_text(p.read_text().replace(self.row['guard_selector'], '0xdeadbeef'))
        self.row['guard_selector'] = '0xdeadbeef'
        self.check('point classification')

    def test_empty_guard_revert(self):
        c = next(c for c in self.commands if c['id'] == self.row['guard_lo'])
        p = self.out/c['log']
        p.write_text(p.read_text().replace('ret: '+self.row['guard_selector'], 'ret: 0x'))
        self.check('point classification')


if __name__ == '__main__':
    unittest.main(verbosity=2)
