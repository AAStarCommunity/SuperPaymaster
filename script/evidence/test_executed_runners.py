"""Offline execution provenance controls using a stub engine, never RPC."""
import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import executed_run as execution
import test_exec_inventory as inv
import rams_fork_run as rams

ROOT = Path(__file__).resolve().parents[2]
TMP = ROOT/'.codex-work'
TMP.mkdir(parents=True, exist_ok=True)


class ExecutedControls(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir=TMP)
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.forge = self.root/'forge'
        self.forge.write_text('''#!/usr/bin/env python3
import json, os, sys
if '--version' in sys.argv:
 print('forge Version: stub\\nCommit SHA: ' + 'a'*40)
else:
 path = 'contracts/test/rams/RamsARouteRehearsal.t.sol' if '--match-path' in sys.argv else 'a.t.sol'
 if '--list' in sys.argv:
  print(json.dumps({path: {'C': ['test_a']}}))
 else:
  print('Ran 1 test for '+path+':C\\n[PASS] test_a()')
  if 'SEPOLIA_FORK_RPC' in os.environ:
   print(os.environ['SEPOLIA_FORK_RPC']+' https://other.invalid/secret wss://socket.invalid/token')
''')
        self.forge.chmod(0o755)
        (self.root/'a.t.sol').write_text('contract C {}')
        self.clean = mock.patch.object(execution, 'snapshot', return_value={'head': 'b'*40, 'sources': {}})
        self.clean.start()
        self.addCleanup(self.clean.stop)

    def test_all_engines_and_relabel_rejected(self):
        for engine in ('cancun', 'prague', 'amsterdam'):
            out = self.root/engine
            self.assertEqual(inv.run_inventory(engine, self.forge, out, self.root), 0)
            saved = json.loads((out/'inventory.json').read_text())
            self.assertEqual(saved['provenance'], 'executed')
            self.assertEqual(inv.verify(out/'inventory.json'), 0)
            saved['engine'] = 'amsterdam' if engine != 'amsterdam' else 'cancun'
            (out/'inventory.json').write_text(json.dumps(saved))
            with self.assertRaisesRegex(ValueError, 'engine argv/env mismatch'):
                inv.verify(out/'inventory.json')

    def test_dirty_tree(self):
        with mock.patch.object(execution, 'snapshot', side_effect=ValueError('dirty tree')):
            with self.assertRaisesRegex(ValueError, 'dirty tree'):
                inv.run_inventory('cancun', self.forge, self.root/'out', self.root)
        # Exercise the actual status gate without creating commits.
        with mock.patch.object(execution.subprocess, 'check_output', return_value=' M a.t.sol\n'):
            with self.assertRaisesRegex(ValueError, 'dirty tree'):
                self.clean.stop()
                try:
                    execution.snapshot(self.root)
                finally:
                    self.clean.start()

    def test_version_without_commit(self):
        self.forge.write_text('#!/bin/sh\necho "forge Version: stub"\n')
        with self.assertRaisesRegex(ValueError, '40-hex commit'):
            inv.run_inventory('cancun', self.forge, self.root/'out', self.root)

    def test_changed_tree_during_run(self):
        with mock.patch.object(execution, 'snapshot', side_effect=[{'head': 'a'}, {'head': 'b'}]):
            with self.assertRaisesRegex(ValueError, 'changed during execution'):
                inv.run_inventory('cancun', self.forge, self.root/'out', self.root)

    def test_rr5_different_tree_rejected(self):
        # Actual verifier against historical evidence fails current-source comparison.
        with self.assertRaisesRegex(ValueError, 'RR5 RELEASE verification failed'):
            execution.rr5_logs(ROOT/'docs/design/aoa-balance-mode/data/rr5-lifecycle-isolation/run', 'cancun', ROOT)

    def test_caller_asserted_stdout(self):
        (self.root/'declared').write_text(json.dumps({'a.t.sol': {'C': ['test_a']}}))
        (self.root/'log').write_text('Ran 1 test for a.t.sol:C\n[PASS] test_a()')
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            rc = inv.main(['--declared', str(self.root/'declared'), '--log', str(self.root/'log'),
                           '--engine', 'cancun', '--root', str(self.root), '--out-json', str(self.root/'json'),
                           '--out-md', str(self.root/'md')])
        self.assertEqual(rc, 0)
        self.assertIn('caller-asserted; not release evidence', output.getvalue())

    def rams_source(self, line=40):
        test = self.root/rams.TEST
        test.parent.mkdir(parents=True, exist_ok=True)
        test.write_text('\n' * (line - 1) + '        assertEq(block.chainid, 11155111, "RAMS: Sepolia only");\n')

    def test_rams_host_without_scheme_rejected(self):
        # The scrubber removes scheme URLs and the literal RPC; a bare host must still fail the run.
        self.rams_source()
        self.forge.write_text(self.forge.read_text().replace(
            "print(os.environ['SEPOLIA_FORK_RPC']", "print('node eth-sepolia.example.com:443 ' + os.environ['SEPOLIA_FORK_RPC']"))
        rpc = self.root/'rpc'
        rpc.write_text('https://secret.invalid/token')
        ops = self.root/'operators'
        ops.write_text('0x'+'1'*40)
        with mock.patch.object(rams, 'snapshot', return_value={'head': 'a'*40}):
            with self.assertRaisesRegex(ValueError, r'URL-like content in evidence: test\.log: [a-z,-]*host'):
                rams.run(self.forge, rpc, 'dummy', 123, ops, self.root/'rams', self.root)

    def test_rams_never_saves_url(self):
        self.rams_source(85)
        rpc = self.root/'rpc'
        rpc.write_text('https://secret.invalid/token')
        ops = self.root/'operators'
        ops.write_text('0x'+'1'*40)
        out = self.root/'rams'
        with mock.patch.object(rams, 'snapshot', return_value={'head': 'a'*40}):
            self.assertEqual(rams.run(self.forge, rpc, 'dummy', 123, ops, out, self.root), 0)
        for path in out.rglob('*'):
            if path.is_file():
                self.assertNotIn('://', path.read_text())
                self.assertNotIn('secret.invalid', path.read_text())
        report = json.loads((out/'rams.json').read_text())
        self.assertEqual(report['counts']['executed'], 1)
        self.assertEqual(report['provenance'], 'executed')
        self.assertEqual(report['chainId_assertion'], rams.TEST + ':85')

    def test_full_run_rams_never_counted(self):
        report, rc = inv.inventory({rams.TEST: {'C': ['test_a']}},
                                  ['Ran 1 test for '+rams.TEST+':C\n[PASS] test_a()'], 'amsterdam')
        self.assertEqual(report['executed'], 0)
        self.assertEqual(report['unexecuted'][0]['reason'], 'fork-only: see rams_fork_run')
        self.assertEqual(rc, 1)


if __name__ == '__main__':
    unittest.main(verbosity=2)
