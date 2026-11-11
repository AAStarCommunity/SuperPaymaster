#!/usr/bin/env python3
"""Offline negative controls; never writes to the supplied evidence directory.

python3 script/evidence/test_rr5_lifecycle_verify.py [run-directory]
"""
import importlib.util
from unittest import mock
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
        self.tmp = tempfile.TemporaryDirectory(prefix='rr5-negative-', dir=RUNNER.parents[2]/'.codex-work')
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
        result = subprocess.run([sys.executable, str(RUNNER), '--verify', str(self.out), '--require-engines', 'amsterdam'],
                                text=True, capture_output=True, cwd=RUNNER.parents[2])
        if reason is None:
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('PASS (156, 4044)', result.stdout)
            self.assertIn('verified engines: amsterdam,cancun,prague', result.stdout)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertIn(reason, result.stderr)

    def test_historical_record_without_compile_evm(self):
        result = subprocess.run([sys.executable, str(RUNNER), '--verify', str(self.out), '--require-engines', 'amsterdam'],
                                text=True, capture_output=True, cwd=RUNNER.parents[2])
        self.assertEqual(result.returncode, 0, result.stderr)

    def mark_new_compile_evm_record(self):
        for key, row in self.manifest.items():
            engine = key.split('/', 1)[0]
            row['compileEvm'] = 'prague' if engine == 'prague' else 'cancun'
        for command in self.commands:
            command['compileEvm'] = 'prague' if command['engine'] == 'prague' else 'cancun'

    def test_new_amsterdam_cancun_record_rejects_prague_argv(self):
        self.mark_new_compile_evm_record()
        self.check('command argv')

    def test_new_amsterdam_cancun_record_accepts_cancun_argv(self):
        self.mark_new_compile_evm_record()
        for command in self.commands:
            if command['engine'] == 'amsterdam':
                i = command['argv'].index('--evm-version')
                command['argv'][i + 1] = 'cancun'
        self.check()

    def test_missing_production_source(self):
        before = json.loads((self.out/'source-before.json').read_text())
        before.pop(next(iter(before)))
        for name in ('source-before.json', 'source-after.json'):
            (self.out/name).write_text(json.dumps(before))
        self.check('production source inventory mismatch')

    def test_cancun_only_rejected_for_release(self):
        self.manifest = {k: v for k, v in self.manifest.items() if k.startswith('cancun/')}
        self.commands = [c for c in self.commands if c['engine'] == 'cancun']
        for engine in ('amsterdam', 'prague'):
            (self.out / f'{engine}-version.txt').unlink()
        self.check('missing required engines: amsterdam')

    def test_missing_engine_version(self):
        (self.out/'amsterdam-version.txt').unlink()
        self.check('engine inventory mismatch')

    def test_recorded_measurement_prefix_changed(self):
        spec = importlib.util.spec_from_file_location('rr5_runner', RUNNER)
        runner = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(runner)
        original = subprocess.check_output
        def changed_recorded(argv, *args, **kwargs):
            result = original(argv, *args, **kwargs)
            if argv[:2] == ['git', 'show'] and argv[2].endswith(':script/evidence/rr5-lifecycle-run.py'):
                self.assertIn(b'    serial = 0', result)
                return result.replace(b'    serial = 0', b'    serial = 1', 1)
            return result
        with mock.patch.object(runner.subprocess, 'check_output', side_effect=changed_recorded):
            with self.assertRaisesRegex(AssertionError, 'measurement main prefix changed'):
                runner.verify(self.out)

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


    def test_option_like_output_is_rejected_before_running(self):
        # '--help' used to be taken as EMPTY_OUT and started a full run there.
        for argv in (['--help'], ['--engines', 'amsterdam', '-x']):
            result = subprocess.run([sys.executable, str(RUNNER), *argv],
                                    text=True, capture_output=True, cwd=self.tmp.name)
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertIn('usage:', result.stderr)
            self.assertFalse((Path(self.tmp.name)/argv[-1]).exists())

if __name__ == '__main__':
    unittest.main(verbosity=2)
