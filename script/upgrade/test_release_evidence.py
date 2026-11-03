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
        self.template = json.loads((e.m.u.ROOT / e.CONFORMANCE_MAP).read_text())
        mapping = self.tree / e.CONFORMANCE_MAP
        mapping.parent.mkdir(parents=True)
        mapping.write_text(json.dumps(self.template))
        for spec in self.template['controls'].values():
            for ref in [spec] + spec['positiveControl'] + spec['negativeControl']:
                p = self.tree / ref['suite']
                p.parent.mkdir(parents=True, exist_ok=True)
                p.write_text('# fixture')
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
        if '-c' in command and e.CHECKER_RUNNER in command:
            name = command[-2]
            failed, skipped = int(self.fail_suite), int(self.skip_suite)
            Path(command[-1]).write_text(json.dumps(dict(test='Controls.' + name,
                run=1, passed=1-failed-skipped, failed=failed, skipped=skipped)))
            return result(code=failed)
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
            e.generate(kind, COMMIT, self.tree, self.out, FORGE, **kwargs)
        path = self.out / (kind + '.json')
        value = json.loads(path.read_text())
        jsonschema.Draft202012Validator(self.schema).validate(value)
        ref = dict(path=str(path), sha256=hashlib.sha256(path.read_bytes()).hexdigest())
        self.assertEqual(e.m.evidence_file(ref, kind, COMMIT), value)
        return value

    def test_conformance_schema_and_executor(self):
        value = self.generate('conformance')
        self.assertEqual(value['counts']['passed'], 36)
        self.assertEqual(value['scope'], 'checker-logic-offline')
        self.assertTrue(all(c['result'] == 'PASS' for c in value['controls'].values()))
        self.assertEqual(len(value['controls']), 9)
        audit = json.loads((self.out / 'conformance.audit.json').read_text())
        self.assertEqual(sum(len(v) for v in audit['controls'].values()), value['counts']['passed'])
        self.assertTrue(all(Path(cmd[-3]).resolve().is_relative_to(self.tree.resolve())
                            for cmd, _ in self.calls if '-c' in cmd))

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
                e.generate('conformance', COMMIT, self.tree, self.out, FORGE)
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
                    e.forge_test(FORGE, self.tree, 'contracts/test/Example.t.sol')
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
                        e.forge_test(FORGE, self.tree, 'contracts/test/Example.t.sol')
                self.assertFalse((self.out / 'conformance.json').exists())

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
                    e.forge_test(FORGE, self.tree, 'contracts/test/Example.t.sol')
            self.assertFalse((self.out / 'conformance.json').exists())

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
        for flag in ('--config-file', '--json'):
            scratch = Path(commands[0][commands[0].index(flag) + 1])
            self.assertFalse(scratch.is_relative_to(self.tree))
            self.assertFalse(scratch.exists())

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

    def test_main_conformance_uses_archived_mapping(self):
        def archive(repo, commit, tree):
            import shutil
            shutil.copytree(self.tree, tree)
            template = json.loads((tree / e.CONFORMANCE_MAP).read_text())
            # A valid reviewed change present only in the selected archive.
            template['controls']['C1']['test'] = 'test_all_positive'
            (tree / e.CONFORMANCE_MAP).write_text(json.dumps(template))
        with patch.object(e, 'clean_commit', return_value=COMMIT), \
             patch.object(e.a, 'archive_commit', side_effect=archive) as archived, patch.object(e, 'install_node_deps'), \
             patch.object(e.subprocess, 'run', side_effect=self.fake_run):
            self.assertEqual(e.main(['conformance', '--commit', 'v1', '--out', str(self.out)]), 0)
        self.assertEqual(archived.call_args.args[1], COMMIT)
        value = json.loads((self.out / 'conformance.json').read_text())
        self.assertEqual(value['controls']['C1']['test'], 'test_all_positive')
        jsonschema.Draft202012Validator(self.schema).validate(value)
        e.m.validate_evidence_details(value, 'conformance')
        self.assertTrue((self.out / 'SHA256SUMS').is_file())

    def test_main_failed_kind_has_no_checksums(self):
        def archive(repo, commit, tree):
            import shutil
            shutil.copytree(self.tree, tree)
        self.fail_suite = True
        with patch.object(e, 'clean_commit', return_value=COMMIT), \
             patch.object(e.a, 'archive_commit', side_effect=archive) as archived, patch.object(e, 'install_node_deps'), \
             patch.object(e.subprocess, 'run', side_effect=self.fake_run):
            self.assertEqual(e.main(['conformance', '--commit', 'v1', '--out', str(self.out)]), 1)
        self.assertEqual(archived.call_args.args[1], COMMIT)
        self.assertFalse((self.out / 'conformance.json').exists())
        self.assertFalse((self.out / 'SHA256SUMS').exists())

    def test_missing_mapping_is_not_attested(self):
        (self.tree / e.CONFORMANCE_MAP).unlink()
        with self.assertRaisesRegex(e.Stop, 'mapping required'):
            e.conformance(self.tree, FORGE, {})

    def test_missing_negative_control_rejected(self):
        self.template['controls']['C1']['negativeControl'] = []
        (self.tree / e.CONFORMANCE_MAP).write_text(json.dumps(self.template))
        with self.assertRaisesRegex(e.Stop, 'missing negativeControl'):
            self.generate('conformance')
        self.assertFalse((self.out / 'conformance.json').exists())
        self.template['subjectCommit'] = COMMIT
        self.template['result'] = 'PASS'
        self.template['counts'] = dict(passed=36, failed=0, skipped=0)
        for c in self.template['controls'].values():
            c['result'] = 'PASS'
        with self.assertRaises(jsonschema.ValidationError):
            jsonschema.Draft202012Validator(self.schema).validate(self.template)
        with self.assertRaises(e.a.Gate):
            e.m.validate_evidence_details(self.template, 'conformance')

    def test_one_failing_named_control_prevents_pass(self):
        def fake(command, **kwargs):
            if e.CHECKER_RUNNER in command and command[-2] == 'test_c9_inflight':
                Path(command[-1]).write_text(json.dumps(dict(test='Controls.test_c9_inflight',
                    run=1, passed=0, failed=1, skipped=0)))
                return result(code=1)
            return self.fake_run(command, **kwargs)
        with patch.object(e.subprocess, 'run', side_effect=fake):
            with self.assertRaisesRegex(e.Stop, 'test_c9_inflight'):
                e.generate('conformance', COMMIT, self.tree, self.out, FORGE)
        self.assertFalse((self.out / 'conformance.json').exists())

    def test_all_partial_failure_has_no_checksums(self):
        def generate(kind, commit, tree, out, *args):
            if kind == 'mutation':
                raise e.Stop('failed mutation')
            e.write_json(out / (kind + '.json'), dict(result='PASS'))
        with patch.object(e, 'clean_commit', return_value=COMMIT), \
             patch.object(e.a, 'archive_commit', side_effect=lambda repo, commit, tree: tree.mkdir()), patch.object(e, 'install_node_deps'), \
             patch.object(e, 'generate', side_effect=generate):
            self.assertEqual(e.main(['all', '--commit', 'v1', '--out', str(self.out)]), 1)
        self.assertTrue((self.out / 'conformance.json').is_file())
        self.assertFalse((self.out / 'SHA256SUMS').exists())

    def test_real_named_runner_outcomes(self):
        path = self.tree / 'controls.py'
        path.write_text("import unittest\nclass Controls(unittest.TestCase):\n"
                        "    def test_ok(self): pass\n"
                        "    def test_bad(self): self.fail('negative control failed')\n"
                        "    @unittest.skip('skip')\n    def test_skip(self): pass\n")
        self.assertEqual(e.checker_test(self.tree, FORGE,
            dict(suite='controls.py', test='test_ok'))['passed'], 1)
        for name in ('test_bad', 'test_skip', 'test_missing'):
            with self.subTest(name=name), self.assertRaises(e.Stop):
                e.checker_test(self.tree, FORGE, dict(suite='controls.py', test=name))

    def test_main_writes_sha_manifest(self):
        with patch.object(e, 'clean_commit', return_value=COMMIT), patch.object(e.a, 'archive_commit', side_effect=lambda repo, commit, tree: tree.mkdir(parents=True)), patch.object(e, 'install_node_deps'), \
             patch.object(e.subprocess, 'run', side_effect=self.fake_run), patch.object(e.shutil, 'which', return_value='/mock/bin/slither'):
            # archive mock still needs a working directory for tool mocks only.
            self.assertEqual(e.main(['slither', '--commit', 'v1', '--out', str(self.out)]), 0)
        for line in (self.out / 'SHA256SUMS').read_text().splitlines():
            digest, name = line.split('  ')
            self.assertEqual(digest, hashlib.sha256((self.out / name).read_bytes()).hexdigest())



class CheckerRunnerModuleFixtures(unittest.TestCase):
    """The real CHECKER_RUNNER (no mocks) must honour setUpModule: a module-level skip or failure is never PASS."""
    def run_runner(self, fixture):
        with tempfile.TemporaryDirectory() as tmp:
            module = Path(tmp)/'fixture_mod.py'
            module.write_text(fixture)
            out = Path(tmp)/'result.json'
            proc = subprocess.run([sys.executable, '-I', '-c', e.CHECKER_RUNNER, str(module), 'test_ok', str(out)],
                                  capture_output=True, text=True)
            return proc.returncode, (json.loads(out.read_text()) if out.exists() else None)

    def test_module_skip_is_not_pass(self):
        code, result = self.run_runner(
            'import unittest\n'
            'def setUpModule():\n    raise unittest.SkipTest("prerequisite missing")\n'
            'class T(unittest.TestCase):\n    def test_ok(self):\n        pass\n')
        self.assertNotEqual(code, 0)
        self.assertTrue(result is None or result['passed'] == 0, result)

    def test_module_setup_error_is_not_pass(self):
        code, result = self.run_runner(
            'import unittest\n'
            'def setUpModule():\n    raise RuntimeError("broken prerequisite")\n'
            'class T(unittest.TestCase):\n    def test_ok(self):\n        pass\n')
        self.assertNotEqual(code, 0)
        self.assertTrue(result is None or result['passed'] == 0, result)

    def test_plain_pass_still_passes(self):
        code, result = self.run_runner(
            'import unittest\n'
            'class T(unittest.TestCase):\n    def test_ok(self):\n        pass\n')
        self.assertEqual(code, 0)
        self.assertEqual((result['run'], result['passed'], result['skipped']), (1, 1, 0))


class InstallNodeDeps(unittest.TestCase):
    def test_missing_lock_stops(self):
        with tempfile.TemporaryDirectory() as tmp, self.assertRaisesRegex(e.Stop, 'pnpm-lock.yaml required'):
            e.install_node_deps(Path(tmp))

    def test_missing_pnpm_stops(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(e.shutil, 'which', return_value=None), \
             self.assertRaisesRegex(e.Stop, 'pnpm not found'):
            (Path(tmp)/'pnpm-lock.yaml').write_text('lockfileVersion: 9.0\n')
            e.install_node_deps(Path(tmp))

    def test_failed_install_stops(self):
        failed = subprocess.CompletedProcess(['pnpm'], 1, '', 'ERR_PNPM_NO_OFFLINE_TARBALL')
        with tempfile.TemporaryDirectory() as tmp, patch.object(e.shutil, 'which', return_value='/bin/pnpm'), \
             patch.object(e.subprocess, 'run', return_value=failed), self.assertRaisesRegex(e.Stop, 'frozen-lockfile --offline failed'):
            (Path(tmp)/'pnpm-lock.yaml').write_text('lockfileVersion: 9.0\n')
            e.install_node_deps(Path(tmp))

    def test_success_without_viem_stops(self):
        ok = subprocess.CompletedProcess(['pnpm'], 0, '', '')
        with tempfile.TemporaryDirectory() as tmp, patch.object(e.shutil, 'which', return_value='/bin/pnpm'), \
             patch.object(e.subprocess, 'run', return_value=ok), self.assertRaisesRegex(e.Stop, 'viem missing'):
            (Path(tmp)/'pnpm-lock.yaml').write_text('lockfileVersion: 9.0\n')
            e.install_node_deps(Path(tmp))

    def test_match_test_regex_uses_signature(self):
        calls = []
        def fake_run(command, tree, env):
            calls.append(command); raise e.Stop('stop after capture')
        with patch.object(e, 'run', side_effect=fake_run), self.assertRaises(e.Stop):
            e.forge_test(Path('/forge'), Path('/tree'), 'contracts/test/x.t.sol', 'C', 'test_ok')
        self.assertIn('^test_ok\\(\\)$', calls[0])

if __name__ == '__main__':
    unittest.main()
