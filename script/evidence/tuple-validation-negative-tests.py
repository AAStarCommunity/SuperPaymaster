"""Offline controls; all mutations are confined to temporary copies of retained evidence."""
import importlib.util
import json
from pathlib import Path
import re
import shutil
import sys
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('tuple_runner', Path(__file__).with_name('tuple-validation-run.py'))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)
RUN = Path(sys.argv.pop(1)).resolve()


def fixture(status='PASS', test='test_x(uint256)', reason=''):
    counts = [int(status == s) for s in ('PASS', 'FAIL', 'SKIP')]
    p, f, s = counts
    return (f'Ran 1 test for fixture.sol:FixtureTest\n'
            f'[{status}{reason}] {test} (runs: 1)\n'
            f'Suite result: ok. {p} passed; {f} failed; {s} skipped; finished in 1s\n'
            f'Ran 1 test suite in 1s: {p} tests passed, {f} failed, {s} skipped (1 total tests)\n')


class OfflineControls(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='tuple-controls-')
        self.addCleanup(self.tmp.cleanup)
        self.run = Path(self.tmp.name) / 'run'
        shutil.copytree(RUN, self.run)

    def reject(self, message):
        runner.seal(self.run)
        with self.assertRaisesRegex(AssertionError, message):
            runner.verify(self.run)

    def test_untouched(self):
        runner.verify(self.run)

    def test_source_hash_not_at_recorded_revision(self):
        path = self.run / 'source-hashes.json'
        hashes = json.loads(path.read_text())
        hashes['foundry.toml'] = '0' * 64
        path.write_text(json.dumps(hashes, indent=2))
        self.reject('sources differ from the recorded revision')

    def test_extra_source_not_at_recorded_revision(self):
        path = self.run / 'source-hashes.json'
        hashes = json.loads(path.read_text())
        hashes['contracts/test/v2/NotAtRevision.t.sol'] = '0' * 64
        path.write_text(json.dumps(hashes, indent=2))
        self.reject('sources differ from the recorded revision')

    def test_unrelated_boundary(self):
        path = self.run / 'boundary-0-469304.log'
        path.write_text(fixture(test='test_unrelated()').replace('FixtureTest', 'UnrelatedTest'))
        self.reject('selected test identities mismatch')

    def test_removed_suite_reduced_count(self):
        path = self.run / 'full-cancun-0.log'
        text = path.read_text()
        text, removed = re.subn(r'Ran 2 tests for [^\n]*:DebugTest\n.*?Suite result: [^\n]*\n', '', text, flags=re.S)
        self.assertEqual(removed, 1)
        def reduce_total(m):
            return (f'Ran {int(m[1])-1} test suites{m[2]}: {int(m[3])-2} tests passed, '
                    f'{m[4]} failed, {m[5]} skipped ({int(m[6])-2} total tests)')
        text, changed = re.subn(r'Ran (\d+) test suites(.*?): (\d+) tests passed, (\d+) failed, (\d+) skipped \((\d+) total tests\)', reduce_total, text)
        self.assertEqual(changed, 1)
        path.write_text(text)
        # Also update derived statuses: inventory validation must independently reject it.
        states = json.loads((self.run / 'statuses.json').read_text())
        states['full-cancun-0'] = runner.statuses(text)
        (self.run / 'statuses.json').write_text(json.dumps(states))
        self.reject('full-suite inventory differs')

    def test_empty_statuses(self):
        (self.run / 'statuses.json').write_text('{}\n')
        self.reject('statuses.json differs from logs')

    def test_bracketed_fuzz_failure(self):
        path = self.run / 'boundary-0-469304.log'
        path.write_text(fixture('FAIL', reason=': counterexample: calldata=0x01 args=[160]'))
        self.assertEqual(runner._parser.outcomes(path), {'fixture.sol:FixtureTest::test_x(uint256)': 'FAIL'})
        original = runner._parser.outcomes(self.run / 'full-amsterdam-0.log')
        matches = [value for key, value in original.items() if '::testFuzz_G2_I8_I9_I10_conservation(' in key]
        self.assertEqual(matches, ['FAIL'])

    def test_skip_transitions(self):
        for engine in runner.ENGINES:
            (self.run / f'full-{engine}-0.log').write_text(fixture())
            (self.run / f'full-{engine}-1.log').write_text(fixture('SKIP'))
        rows = list(runner._parser.changes(self.run))
        self.assertEqual(len(rows), 3)
        self.assertTrue(all(row.endswith('\tPASS\tSKIP') for row in rows))
        for engine in runner.ENGINES:
            (self.run / f'full-{engine}-0.log').write_text(fixture('SKIP'))
            (self.run / f'full-{engine}-1.log').write_text(fixture(test='test_other()'))
        rows = list(runner._parser.changes(self.run))
        self.assertEqual(sum(row.endswith('\tSKIP\tABSENT') for row in rows), 3)

    def test_appended_incomplete_run(self):
        path = self.run / 'full-amsterdam-0.log'
        with path.open('a') as stream:
            stream.write('\nRan 1 test for appended.sol:AppendedTest\n[FAIL: unfinished] test_x() (gas: 1)\n')
        self.reject('incomplete suite')

    def test_duplicate_key(self):
        path = self.run / 'boundary-0-469304.log'
        text = path.read_text()
        result = next(line for line in text.splitlines() if line.startswith('[PASS]'))
        path.write_text(text.replace(result, result + '\n' + result, 1))
        self.reject('duplicate key')


if __name__ == '__main__':
    unittest.main(verbosity=2)
