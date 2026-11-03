#!/usr/bin/env python3
"""Mocked tools only: no Forge builds/suites, git commands, or network access."""
import sys
sys.dont_write_bytecode = True
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import jsonschema
import release_evidence as e

COMMIT = 'a' * 40
FORGE = Path('/mock/bin/forge')
HASHES = dict(fullCreationKeccak='0x' + '12' * 32, strippedCreationKeccak='0x' + '34' * 32)


def result(stdout='', code=0, stderr=''):
    return subprocess.CompletedProcess([], code, stdout, stderr)


def forge_json(statuses=('Success',), reason=None):
    # Forge 1.7.x suite map, including the per-test result fields.
    return json.dumps({'contracts/test/Example.t.sol:ExampleTest': {
        'duration': {'secs': 0, 'nanos': 123456},
        'test_results': {f'test_{i}_passed()': {
            'status': status, 'reason': reason if status == 'Failure' else None,
            'counterexample': None, 'logs': [], 'decoded_logs': [],
            'kind': {'Standard': {'gas': 1234}}, 'traces': [],
            'labeled_addresses': {}, 'duration': {'secs': 0, 'nanos': 123}
        } for i, status in enumerate(statuses)}, 'warnings': []}})


class EvidenceTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.tree = self.root / 'tree'
        self.out = self.root / 'out'
        self.tree.mkdir()
        self.out.mkdir()
        self.schema = json.loads(Path(e.__file__).with_name('release-evidence.schema.json').read_text())
        self.suites = {f'C{i}': dict(path=f'contracts/test/C{i}.t.sol', contract=f'Control{i}', evm='cancun') for i in range(1, 10)}
        for spec in self.suites.values():
            p = self.tree / spec['path']
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text('// fixture')
        for path in (e.MANIFEST, e.VENDOR):
            p = self.tree / path
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text((e.m.u.ROOT / path).read_text())
        self.originals = {p: (self.tree / p).read_text() for p in (e.MANIFEST, e.VENDOR)}
        self.active = None
        self.fail_suite = False
        self.skip_suite = False
        self.slither_findings = []
        self.calls = []

    def fake_run(self, command, **kwargs):
        command = [str(x) for x in command]
        self.calls.append((command, kwargs))
        if '--version' in command:
            return result('0.11.5' if command[0].endswith('slither') else 'forge Version: 1.7.1')
        if command[0].endswith('slither'):
            Path(command[command.index('--json') + 1]).write_text(json.dumps(dict(success=True, error=None, results=dict(detectors=self.slither_findings) if self.slither_findings else {})))
            return result(stderr=f'INFO:Slither:. analyzed (42 contracts with 101 detectors), {len(self.slither_findings)} result(s) found\n')
        if 'build' in command:
            return result()
        mutated = [name for name in e.m.MUTATIONS if self.is_mutated(name)]
        if 'unittest' in command:
            test = command[-1].split('.')[-1]
            red = any(e.m.MUTATIONS[name] == test for name in mutated)
            return result(stderr=f'{test}\nRan 1 test in 0.1s\n' + ('AssertionError\nFAILED (failures=1)' if red else 'OK\n'), code=int(red))
        if 'test' in command:
            expected = 2
            for name, count in [('CC115CrossRepoConformance', 7), ('CC115GenuinePragueCrossRepo', 11), ('VendoredProvenanceSelfCheck', 5)]:
                if any(name in arg for arg in command):
                    expected = count
            if '--match-test' in command:
                expected = 1
            errors = [e.m.MUTATIONS[name] for name in mutated if e.mutation_edit(name)[0] == e.VENDOR]
            fail = bool(errors) or self.fail_suite
            self.assertIn('--json', command)
            statuses = ['Failure'] if fail else ['Success'] * expected
            if self.skip_suite:
                statuses.append('Skipped')
            return result(forge_json(statuses, errors[0] if errors else 'assertion failed'), int(fail))
        raise AssertionError('unexpected subprocess: ' + str(command))

    def is_mutated(self, name):
        path, old, new = e.mutation_edit(name)
        current = (self.tree / path).read_text()
        return current == self.originals[path].replace(old, new)

    def generate(self, kind, **kwargs):
        with patch.object(e.subprocess, 'run', side_effect=self.fake_run), patch.object(e.shutil, 'which', return_value='/mock/bin/slither'):
            e.generate(kind, COMMIT, self.tree, self.out, FORGE, self.suites, **kwargs)
        path = self.out / (kind + '.json')
        value = json.loads(path.read_text())
        jsonschema.Draft202012Validator(self.schema).validate(value)
        ref = dict(path=str(path), sha256=hashlib.sha256(path.read_bytes()).hexdigest())
        self.assertEqual(e.m.evidence_file(ref, kind, COMMIT), value)
        return value

    def test_conformance_schema_and_executor(self):
        value = self.generate('conformance')
        self.assertEqual(value['counts']['passed'], 41)
        self.assertEqual(len(value['controls']), 9)
        prague = [kw['env'] for cmd, kw in self.calls if any('GenuinePrague' in arg for arg in cmd)]
        self.assertEqual(prague[0]['FOUNDRY_EVM_VERSION'], 'prague')
        audit = json.loads((self.out / 'conformance.audit.json').read_text())
        self.assertTrue(any('counts' in cmd and cmd['exitCode'] == 0 for cmd in audit['commands']))

    def test_mutation_schema_and_executor_and_restoration(self):
        value = self.generate('mutation')
        self.assertEqual(value['counts']['passed'], 10)
        for path, content in self.originals.items():
            self.assertEqual((self.tree / path).read_text(), content)
        self.assertEqual(sum('unittest' in cmd for cmd, _ in self.calls), 12)
        self.assertEqual(sum('test' in cmd for cmd, _ in self.calls), 18)

    def test_slither_schema_and_executor(self):
        self.slither_findings = [dict(id='reviewed-1', impact='High')]
        value = self.generate('slither', accepted=[dict(id='reviewed-1', reason='Reviewed mitigation in release decision')])
        self.assertEqual(value['findings']['aboveThreshold'], ['reviewed-1'])

    def test_unaccepted_slither_has_no_pass(self):
        self.slither_findings = [dict(id='unreviewed', impact='Medium')]
        with self.assertRaises(e.Stop):
            self.generate('slither')
        self.assertFalse((self.out / 'slither.json').exists())

    def test_reproducible_schema_and_executor(self):
        arts = {name: dict(bytecode={'object': '0x6000'}) for name in e.m.NAMES}
        verifier = dict(bytecode='0x6000', creationHashes=HASHES)
        with patch.object(e.a, 'compile_commit', return_value=(arts, {})) as build, \
             patch.object(e.m, 'rebuild_dvt', return_value=verifier) as dvt, \
             patch.object(e.m, 'creation_hashes', return_value=HASHES):
            value = self.generate('reproducible-build')
        self.assertEqual(build.call_count, 2)
        self.assertEqual(dvt.call_count, 2)
        self.assertEqual(len(value['contracts']), 11)
        audit = json.loads((self.out / 'reproducible-build.audit.json').read_text())
        self.assertEqual(audit['rebuild']['metadataOnlyDifferences'], [])
        self.assertEqual(audit['rebuild']['verifierCreationHashes'], HASHES)

    def test_metadata_differences_are_recorded_but_executable_differences_stop(self):
        arts = {name: dict(bytecode={'object': '0x6000'}) for name in e.m.NAMES}
        verifier = dict(bytecode='0x6000', creationHashes=HASHES)
        for executable in (False, True):
            with self.subTest(executable=executable):
                calls = 0
                changed = dict(HASHES)
                changed['strippedCreationKeccak' if executable else 'fullCreationKeccak'] = '0x' + '56' * 32
                def hashes(code):
                    nonlocal calls
                    calls += 1
                    # Ten hashes in each SP build, then eleven recomputed by comparison.
                    return dict(changed if calls == 11 or calls == 21 else HASHES)
                with patch.object(e.a, 'compile_commit', return_value=(arts, {})), \
                     patch.object(e.m, 'rebuild_dvt', return_value=verifier), \
                     patch.object(e.m, 'creation_hashes', side_effect=hashes):
                    if executable:
                        with self.assertRaises(e.a.Gate):
                            self.generate('reproducible-build')
                        self.assertFalse((self.out / 'reproducible-build.json').exists())
                    else:
                        self.generate('reproducible-build')
                        audit = json.loads((self.out / 'reproducible-build.audit.json').read_text())
                        self.assertEqual(audit['rebuild']['metadataOnlyDifferences'], ['SuperPaymaster'])
                        (self.out / 'reproducible-build.json').unlink()

    def test_missing_forge_has_no_pass(self):
        with patch.object(e.subprocess, 'run', side_effect=FileNotFoundError('forge')):
            with self.assertRaisesRegex(e.Stop, 'tool unavailable'):
                e.generate('conformance', COMMIT, self.tree, self.out, FORGE, self.suites)
        self.assertFalse((self.out / 'conformance.json').exists())

    def test_failed_and_skipped_suite_have_no_pass(self):
        for fail, skip in ((True, False), (False, True)):
            self.fail_suite, self.skip_suite = fail, skip
            with self.assertRaises(e.Stop):
                self.generate('conformance')
            self.assertFalse((self.out / 'conformance.json').exists())
            self.assertEqual(json.loads((self.out / 'conformance.audit.json').read_text())['result'], 'STOP')

    def test_missing_slither_stops(self):
        with patch.object(e.subprocess, 'run', side_effect=self.fake_run), patch.object(e.shutil, 'which', return_value=None):
            with self.assertRaisesRegex(e.Stop, 'Slither is not installed'):
                e.generate('slither', COMMIT, self.tree, self.out, FORGE)
        self.assertFalse((self.out / 'slither.json').exists())

    def test_dirty_tree_refused_before_any_build(self):
        for dirty in (' M contracts/src/Test.sol\n', '?? untracked\n', ' m contracts/lib/dep\n'):
            with patch.object(e.subprocess, 'run', return_value=result(dirty)) as run:
                with self.assertRaisesRegex(e.Stop, 'dirty tree'):
                    e.clean_commit('v1', self.tree)
            self.assertEqual(run.call_count, 1)

    def test_commit_must_have_resolvable_tag(self):
        with patch.object(e.subprocess, 'run', side_effect=[result(), result(COMMIT), result()]):
            with self.assertRaisesRegex(e.Stop, 'local release tag'):
                e.clean_commit(COMMIT, self.tree)
        with patch.object(e.subprocess, 'run', side_effect=[result(), result(COMMIT), result('v1'), result(COMMIT)]):
            self.assertEqual(e.clean_commit('v1', self.tree), COMMIT)

    def test_no_tests_or_compilation_error_is_not_red_evidence(self):
        with self.assertRaises(e.Stop):
            e.forge_counts('Compiler error: unexpected token')
        self.assertEqual(e.forge_counts(forge_json(('Success', 'Success')), 'Ran 1 test suite: 2 tests passed; 0 failed; 0 skipped;')['passed'], 2)

    def test_mutant_that_stays_green_stops_and_restores(self):
        with patch.object(e, 'python_red_test'):
            # Forge output is healthy despite the mutated source: never call it a killed mutant.
            with patch.object(e.subprocess, 'run', return_value=result(forge_json())):
                with self.assertRaises(e.Stop):
                    e.mutation(self.tree, FORGE, {})
        for path, content in self.originals.items():
            self.assertEqual((self.tree / path).read_text(), content)

    def test_forge_zero_exit_failure_skip_and_malformed_refused(self):
        for output in (forge_json(('Success', 'Failure')), forge_json(('Success', 'Skipped')),
                       '{}', '{"suite": {"test_results": {}}}', forge_json(('Unknown',)),
                       forge_json() + '\nSuite result: ok. 1 passed; 0 failed; 0 skipped;',
                       'Suite result: ok. 1 passed; 0 failed; 0 skipped;'):
            with self.subTest(output=output), patch.object(e.subprocess, 'run', return_value=result(output)):
                with self.assertRaises(e.Stop):
                    e.generate('conformance', COMMIT, self.tree, self.out, FORGE, self.suites)
                self.assertFalse((self.out / 'conformance.json').exists())

    def test_forge_final_summary_must_agree(self):
        for summary in ('Ran 1 test suite in 1ms: 2 tests passed; 0 failed; 0 skipped (2 total tests)',
                        'Ran 1 test suite: 1 test passed; 1 failed; 0 skipped;',
                        'Ran 1 test suite: unknown',
                        'Suite result: ok. 1 passed; 0 failed; 0 skipped;'):
            with self.subTest(summary=summary), self.assertRaises(e.Stop):
                e.forge_counts(forge_json(), summary)
        self.assertEqual(e.forge_counts(forge_json(),
            'Ran 1 test suite in 1ms: 1 test passed; 0 failed; 0 skipped (1 total tests)'),
            dict(passed=1, failed=0, skipped=0))

    def test_forge_failure_markers_anywhere_prevent_pass(self):
        for marker in ('[FAIL: assertion failed] test_bad() (gas: 123)',
                       '[SKIP] test_bad() (gas: 0)', 'Failing tests:',
                       'Encountered 1 failing test, 1 test succeeded'):
            for stream in ('stdout', 'stderr'):
                data = json.loads(forge_json())
                diagnostic = 'runner diagnostic: ' + marker + '\n'
                if stream == 'stdout':
                    # Valid successful JSON can itself contain contradictory logs.
                    suite = next(iter(data.values()))
                    next(iter(suite['test_results'].values()))['decoded_logs'] = [diagnostic]
                output = result(json.dumps(data), stderr=diagnostic if stream == 'stderr' else '')
                with self.subTest(marker=marker, stream=stream), \
                     patch.object(e.subprocess, 'run', return_value=output):
                    with self.assertRaisesRegex(e.Stop, 'failure or skip markers'):
                        e.generate('conformance', COMMIT, self.tree, self.out, FORGE, self.suites)
                self.assertFalse((self.out / 'conformance.json').exists())
                self.assertEqual(json.loads((self.out / 'conformance.audit.json').read_text())['result'], 'STOP')

    def test_forge_pass_count_must_equal_listed_tests(self):
        with patch.object(e, 'run', return_value=result(forge_json(('Success', 'Success')))), \
             patch.object(e, 'forge_counts', return_value=dict(passed=1, failed=0, skipped=0)):
            with self.assertRaisesRegex(e.Stop, 'Forge suite failed'):
                e.forge_test(FORGE, self.tree, 'contracts/test/Example.t.sol')
        with patch.object(e, 'run', return_value=result(forge_json(('Success', 'Success')))):
            self.assertEqual(e.forge_test(FORGE, self.tree, 'contracts/test/Example.t.sol')['passed'], 2)

    def test_forge_expected_red_accepts_failure_diagnostics(self):
        with patch.object(e.subprocess, 'run', return_value=result(
                forge_json(('Failure',), 'guardian-set mismatch'), code=1,
                stderr='[FAIL: guardian-set mismatch] test_guardians() (gas: 123)\nFailing tests:\nEncountered 1 failing test')):
            with e.capture_commands([]):
                counts = e.forge_test(FORGE, self.tree, 'contracts/test/Example.t.sol', red='guardian-set mismatch')
        self.assertEqual(counts, dict(passed=0, failed=1, skipped=0))

    def test_forge_duplicate_keys_stop_at_every_level(self):
        suite_name, suite = next(iter(json.loads(forge_json()).items()))
        test_name, success = next(iter(suite['test_results'].items()))
        failure = dict(success, status='Failure', reason='assertion failed')
        duplicate_tests = '{' + json.dumps(test_name) + ':' + json.dumps(failure) + ',' + json.dumps(test_name) + ':' + json.dumps(success) + '}'
        outputs = [
            '{' + json.dumps(suite_name) + ':' + json.dumps(dict(suite, test_results={test_name: failure})) + ',' + json.dumps(suite_name) + ':' + json.dumps(suite) + '}',
            forge_json().replace(json.dumps(suite['test_results']), duplicate_tests),
            forge_json().replace('"status": "Success"', '"status": "Failure", "status": "Success"'),
            forge_json().replace('"logs": []', '"logs": [], "logs": []'),
        ]
        for output in outputs:
            with self.subTest(output=output), patch.object(e.subprocess, 'run', return_value=result(output)):
                with self.assertRaisesRegex(e.Stop, 'duplicate JSON key'):
                    e.generate('conformance', COMMIT, self.tree, self.out, FORGE, self.suites)
            self.assertFalse((self.out / 'conformance.json').exists())
            self.assertEqual(json.loads((self.out / 'conformance.audit.json').read_text())['result'], 'STOP')

    def test_slither_duplicate_keys_stop_at_every_level(self):
        reports = [
            '{"success":false,"success":true,"error":null,"results":{}}',
            '{"success":true,"error":null,"results":{"detectors":[{"id":"high-1","impact":"High"}]},"results":{}}',
            '{"success":true,"error":null,"results":{"detectors":[{"id":"high-1","impact":"High"}],"detectors":[]}}',
            '{"success":true,"error":null,"results":{"detectors":[{"id":"high-1","impact":"High","impact":"Low"}]}}',
        ]
        for report in reports:
            def fake(command, **kwargs):
                r = self.fake_run(command, **kwargs)
                if '--json' in command and str(command[0]).endswith('slither'):
                    Path(command[command.index('--json') + 1]).write_text(report)
                return r
            with self.subTest(report=report), patch.object(e.subprocess, 'run', side_effect=fake), \
                 patch.object(e.shutil, 'which', return_value='/mock/bin/slither'):
                with self.assertRaisesRegex(e.Stop, 'duplicate JSON key'):
                    e.generate('slither', COMMIT, self.tree, self.out, FORGE)
            self.assertFalse((self.out / 'slither.json').exists())
            self.assertEqual(json.loads((self.out / 'slither.audit.json').read_text())['result'], 'STOP')

    def test_slither_clean_0115_and_repo_exclusions(self):
        (self.tree / 'slither.config.json').write_text(json.dumps({
            'exclude_informational': True, 'exclude_low': True,
            'detectors_to_exclude': 'reentrancy-eth', 'filter_paths': 'contracts'}))
        value = self.generate('slither', threshold='Informational')
        self.assertEqual(value['findings']['aboveThreshold'], [])
        audit = json.loads((self.out / 'slither.audit.json').read_text())
        self.assertEqual(audit['slither']['results'], {})
        selection = audit['slitherSelection']['config']
        self.assertFalse(selection['exclude_informational'])
        self.assertFalse(selection['exclude_low'])
        self.assertIsNone(selection['detectors_to_exclude'])
        commands = [cmd for cmd, _ in self.calls if '--config-file' in cmd]
        self.assertEqual(len(commands), 1)
        self.assertEqual(json.loads(Path(commands[0][commands[0].index('--config-file') + 1]).read_text()), selection)

    def test_slither_incomplete_unsuccessful_or_changed_selection_refused(self):
        for failure in ('success', 'marker', 'count', 'selection'):
            def fake(command, **kwargs):
                r = self.fake_run(command, **kwargs)
                if '--json' in command and str(command[0]).endswith('slither'):
                    report = Path(command[command.index('--json') + 1])
                    if failure == 'success':
                        report.write_text(json.dumps(dict(success=False, results={})))
                    elif failure == 'marker':
                        return result()
                    elif failure == 'count':
                        return result(stderr='. analyzed (42 contracts with 101 detectors), 1 result(s) found')
                    else:
                        config = Path(command[command.index('--config-file') + 1])
                        data = json.loads(config.read_text())
                        data['exclude_informational'] = True
                        config.write_text(json.dumps(data))
                return r
            with self.subTest(failure=failure), patch.object(e.subprocess, 'run', side_effect=fake), \
                 patch.object(e.shutil, 'which', return_value='/mock/bin/slither'):
                with self.assertRaises(e.Stop):
                    e.generate('slither', COMMIT, self.tree, self.out, FORGE, threshold='Informational')
                self.assertFalse((self.out / 'slither.json').exists())

    def test_main_forge_invalid_results_exit_nonzero(self):
        mapping = self.root / 'suites.json'
        mapping.write_text(json.dumps(self.suites))
        for output in (forge_json(('Failure',)), forge_json(('Skipped',)), 'not JSON'):
            def archive(repo, commit, tree):
                tree.mkdir(parents=True)
                for spec in self.suites.values():
                    path = tree / spec['path']
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_text('// fixture')
            def fake(command, **kwargs):
                return result(output) if 'test' in command else self.fake_run(command, **kwargs)
            with tempfile.TemporaryDirectory() as out, patch.object(e, 'clean_commit', return_value=COMMIT), \
                 patch.object(e.a, 'archive_commit', side_effect=archive), \
                 patch.object(e.subprocess, 'run', side_effect=fake):
                self.assertEqual(e.main(['conformance', '--commit', 'v1', '--out', out,
                                         '--suite-map', str(mapping)]), 1)
                self.assertFalse((Path(out) / 'conformance.json').exists())

    def test_missing_mapping_is_not_attested(self):
        with self.assertRaisesRegex(e.Stop, 'mapping required'):
            e.conformance(self.tree, FORGE, None, {})

    def test_main_writes_sha_manifest(self):
        with patch.object(e, 'clean_commit', return_value=COMMIT), patch.object(e.a, 'archive_commit', side_effect=lambda repo, commit, tree: tree.mkdir(parents=True)), \
             patch.object(e.subprocess, 'run', side_effect=self.fake_run), patch.object(e.shutil, 'which', return_value='/mock/bin/slither'):
            # archive mock still needs a working directory for tool mocks only.
            self.assertEqual(e.main(['slither', '--commit', 'v1', '--out', str(self.out)]), 0)
        for line in (self.out / 'SHA256SUMS').read_text().splitlines():
            digest, name = line.split('  ')
            self.assertEqual(digest, hashlib.sha256((self.out / name).read_bytes()).hexdigest())


if __name__ == '__main__':
    unittest.main()
