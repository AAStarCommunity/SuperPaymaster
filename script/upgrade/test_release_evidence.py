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
HASHES = dict(fullCreationKeccak='0x' + '12' * 32, strippedCreationKeccak='0x' + '12' * 32)


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


def compiled_fixture(tree):
    out = tree / 'out'
    out.mkdir(exist_ok=True)
    names = (*e.m.NAMES, 'SuperPaymasterAdminCalls', 'SuperPaymasterStorage', 'xPNTsV2Base')
    for i, name in enumerate(names, 1):
        source = 'contracts/src/' + name + '.sol'
        path = tree / source
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('// compiler fixture')
        bases = [i]
        if name in ('SuperPaymaster', 'SuperPaymasterAdmin'):
            bases += [12]
        if name in ('xPNTsTokenV2', 'xPNTsTokenV2Ext'):
            bases += [13]
        node = dict(id=i, name=name, nodeType='ContractDefinition', contractKind='contract', linearizedBaseContracts=bases)
        (out / (name + '.json')).write_text(json.dumps(dict(ast=dict(absolutePath=source, nodes=[node]))))


def layout_fixture():
    return dict(storage=[dict(label='balance', slot='0', offset=0, type='t_uint256')],
                types={'t_uint256':dict(label='uint256', encoding='inplace', numberOfBytes='32')})


def finding(identity, file='contracts/src/SuperPaymaster.sol', impact='High'):
    return dict(id=identity, impact=impact, elements=[dict(source_mapping=dict(filename_relative=file))])


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
            compiled_fixture(Path(kwargs['cwd']))
            return result()
        if 'inspect' in command:
            return result(json.dumps(layout_fixture()))
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
        self.slither_findings = [finding('reviewed-1')]
        value = self.generate('slither', accepted=[dict(id='reviewed-1', classification='accepted', reason='Reviewed mitigation in release decision')])
        self.assertEqual(value['findings']['aboveThreshold'], ['reviewed-1'])

    def test_unaccepted_slither_has_no_pass(self):
        self.slither_findings = [finding('unreviewed', impact='Medium')]
        with self.assertRaises(e.Stop):
            self.generate('slither')
        self.assertFalse((self.out / 'slither.json').exists())

    def test_scope_classification_dsr_and_outside(self):
        self.slither_findings = [finding('inside'), finding('outside', 'contracts/src/Unrelated.sol'),
                                 finding('lib', 'contracts/lib/Token.sol'), finding('low', impact='Low')]
        entry = dict(row=26, id='inside', check='uninitialized-state', location='contracts/src/SuperPaymaster.sol:12',
                     classification='false-positive', reason='Shared layout verified')
        value = self.generate('slither', accepted=[entry])
        self.assertEqual(value['findings']['accepted'], [entry])
        self.assertEqual(value['findings']['inScopeTotal'], 1)
        self.assertEqual([x['id'] for x in value['findings']['outOfScope']], ['outside', 'lib'])
        self.assertTrue(all(x['classification'] == 'unclassified' for x in value['findings']['outOfScope']))
        self.assertIn('contracts/src/SuperPaymasterStorage.sol', value['scope']['files'])
        self.assertIn('contracts/src/SuperPaymasterAdminCalls.sol', value['scope']['files'])
        self.assertEqual(len(value['storageLayout']), 2)
        inspections = [(c, kw) for c, kw in self.calls if 'inspect' in c]
        self.assertEqual(len(inspections), 4)
        self.assertTrue(all('--offline' in c and kw['env']['FOUNDRY_OFFLINE'] == 'true'
                            and kw['cwd'] == self.tree for c, kw in inspections))

    def test_classification_missing_stale_duplicate_invalid_and_count_stop(self):
        self.slither_findings = [finding('inside'), finding('outside', 'contracts/src/Other.sol')]
        good = dict(id='inside', classification='accepted', reason='review')
        cases = [[], [dict(good, id='stale')], [dict(good, id='outside')], [good, good],
                 [dict(good, classification='unclassified')], [dict(id='inside', reason='old format')],
                 [dict(good, reason=' ')], [good, dict(good, id='stale')]]
        for accepted in cases:
            with self.subTest(accepted=accepted), self.assertRaises(e.Stop):
                self.generate('slither', accepted=accepted)
            self.assertFalse((self.out / 'slither.json').exists())

    def test_layout_each_pair_and_each_field_mismatch_stops(self):
        for target in ('SuperPaymasterAdmin', 'xPNTsTokenV2Ext'):
            for field, value in [('label', 'different'), ('slot', '1'), ('offset', 1), ('type', 'other')]:
                def fake(command, **kwargs):
                    if 'inspect' in command and str(command[2]).endswith(':' + target):
                        data = layout_fixture()
                        data['types']['other'] = dict(label='uint128', encoding='inplace', numberOfBytes='16')
                        data['storage'][0][field] = value
                        return result(json.dumps(data))
                    return self.fake_run(command, **kwargs)
                with self.subTest(target=target, field=field), patch.object(e.subprocess, 'run', side_effect=fake), \
                     patch.object(e.shutil, 'which', return_value='/mock/slither'), self.assertRaisesRegex(e.Stop, 'layout mismatch'):
                    e.generate('slither', COMMIT, self.tree, self.out, FORGE)
                self.assertFalse((self.out / 'slither.json').exists())

    def test_layout_missing_entry_empty_and_failed_inspect_stop(self):
        for output in (result(code=1), result('{}'), result(json.dumps(dict(storage=[], types={})))):
            def fake(command, **kwargs):
                return output if 'inspect' in command else self.fake_run(command, **kwargs)
            with patch.object(e.subprocess, 'run', side_effect=fake), \
                 patch.object(e.shutil, 'which', return_value='/mock/slither'), self.assertRaises((e.Stop, KeyError)):
                e.generate('slither', COMMIT, self.tree, self.out, FORGE)
            self.assertFalse((self.out / 'slither.json').exists())

    def test_scope_uses_inheritance_excludes_libraries_and_unrelated(self):
        compiled_fixture(self.tree)
        path = self.tree / 'out/SuperPaymaster.json'
        data = json.loads(path.read_text())
        data['ast']['nodes'][0]['linearizedBaseContracts'].append(100)
        path.write_text(json.dumps(data))
        (self.tree / 'out/lib.json').write_text(json.dumps(dict(ast=dict(absolutePath='contracts/lib/Base.sol', nodes=[
            dict(id=100, name='Base', nodeType='ContractDefinition', contractKind='contract', linearizedBaseContracts=[100])]))))
        scope, _, _ = e.compiled_scope(self.tree)
        self.assertNotIn('contracts/lib/Base.sol', scope['files'])
        self.assertEqual(len(scope['files']), 13)
        (self.tree / 'out/SuperPaymaster.json').unlink()
        with self.assertRaisesRegex(e.Stop, 'scope root'):
            e.compiled_scope(self.tree)

    def test_duplicate_findings_and_missing_locations_stop(self):
        for findings in ([finding('same'), finding('same')], [dict(id='unknown', impact='High')]):
            self.slither_findings = findings
            with self.subTest(findings=findings), self.assertRaises(e.Stop):
                self.generate('slither')
            self.assertFalse((self.out / 'slither.json').exists())

    def test_mixed_scope_and_absolute_locations_are_in_scope(self):
        item = finding('mixed', 'contracts/lib/Outside.sol')
        item['elements'].append(dict(source_mapping=dict(filename_absolute=str(self.tree / 'contracts/src/SuperPaymaster.sol'))))
        self.slither_findings = [item]
        with self.assertRaises(e.Stop):
            self.generate('slither')
        value = self.generate('slither', accepted=[dict(id='mixed', classification='accepted', reason='reviewed')])
        self.assertEqual(value['findings']['aboveThreshold'], ['mixed'])
        self.assertEqual(value['findings']['outOfScope'], [])

    def test_namespaced_mismatch_stops_and_records_tables(self):
        def namespace(tree, root, nodes):
            return [dict(label='pendingOwner', slot='10' if root[1]['name'] == 'SuperPaymasterAdmin' else '9',
                         offset=0, type='address')]
        with patch.object(e, 'namespace_table', side_effect=namespace), self.assertRaisesRegex(e.Stop, 'layout mismatch'):
            self.generate('slither')
        audit = json.loads((self.out / 'slither.audit.json').read_text())
        pair = audit['storageLayout'][0]
        self.assertNotEqual(pair['coreTable']['namespaces'], pair['extensionTable']['namespaces'])

    def test_pending_owner_namespace_and_test_reference(self):
        relative = 'contracts/src/utils/Ownable2StepNamespaced.sol'
        path = self.tree / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text((e.m.u.ROOT / relative).read_text())
        node = dict(name='Ownable2StepNamespaced', linearizedBaseContracts=[1])
        rows = e.namespace_table(self.tree, (relative, node), {1: (relative, node)})
        self.assertEqual(rows[0]['label'], 'aastar.storage.Ownership2Step._pendingOwner')
        self.assertEqual(rows[0]['type'], 'address')
        test_path = self.tree / 'contracts/test/v2/SuperPaymasterD5bGov2.t.sol'
        test_path.parent.mkdir(parents=True, exist_ok=True)
        test_path.write_text('function test_gov2_sp_pendingOwner_erc7201_slot() public {}')
        value = self.generate('slither')
        self.assertEqual(value['storageLayout'][0]['testReferences'],
                         ['contracts/test/v2/SuperPaymasterD5bGov2.t.sol:test_gov2_sp_pendingOwner_erc7201_slot'])
        path.write_text(path.read_text().replace('sstore(slot, p)', 'sstore(0, p)'))
        with self.assertRaisesRegex(e.Stop, 'namespace binding changed'):
            e.namespace_table(self.tree, (relative, node), {1: (relative, node)})

    def test_layout_recursive_struct_drift(self):
        a = layout_fixture()
        a['types']['struct'] = dict(label='struct S', encoding='inplace', numberOfBytes='32', members=a['storage'])
        a['storage'] = [dict(label='config', slot='0', offset=0, type='struct')]
        import copy
        b = copy.deepcopy(a)
        b['types']['struct']['members'][0]['offset'] = 1
        self.assertNotEqual(e.layout_table(a), e.layout_table(b))

    def test_namespace_tables_and_changed_declaration_stop(self):
        path = self.tree / 'Initializable.sol'
        path.write_text('bytes32 private constant INITIALIZABLE_STORAGE = 0x' + 'ab' * 32 + ';\n$.slot := INITIALIZABLE_STORAGE')
        member = dict(name='InitializableStorage', documentation=dict(text='@custom:storage-location erc7201:openzeppelin.storage.Initializable'),
                      members=[dict(name='_initialized', typeDescriptions=dict(typeString='uint64')),
                               dict(name='_initializing', typeDescriptions=dict(typeString='bool'))])
        node = dict(linearizedBaseContracts=[1], nodes=[member])
        nodes = {1: ('Initializable.sol', node)}
        table = e.namespace_table(self.tree, ('Initializable.sol', node), nodes)
        self.assertEqual([x['offset'] for x in table], [0, 8])
        self.assertEqual(table[0]['slot'], str(int('ab' * 32, 16)))
        member['members'][0]['typeDescriptions']['typeString'] = 'uint128'
        with self.assertRaisesRegex(e.Stop, 'namespace layout changed'):
            e.namespace_table(self.tree, ('Initializable.sol', node), nodes)

    def test_reproducible_schema_and_executor(self):
        arts = {name: dict(bytecode={'object': '0x6000'}) for name in e.m.NAMES}
        verifier = dict(bytecode=json.loads(Path(__file__).with_name('fixtures').joinpath('dvt-creation.json').read_text())['creationBytecode'], creationHashes=HASHES)
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

    def test_sp_full_or_stripped_hash_differences_stop(self):
        arts = {name: dict(bytecode={'object': '0x6000'}) for name in e.m.NAMES}
        verifier = dict(bytecode=json.loads(Path(__file__).with_name('fixtures').joinpath('dvt-creation.json').read_text())['creationBytecode'], creationHashes=HASHES)
        for executable in (False, True):
            with self.subTest(executable=executable):
                calls = 0
                changed = dict(HASHES)
                changed['strippedCreationKeccak' if executable else 'fullCreationKeccak'] = '0x' + '56' * 32
                def hashes(code, name=None):
                    nonlocal calls
                    calls += 1
                    # Ten hashes in each SP build, then eleven recomputed by comparison.
                    return dict(changed if calls == 11 or calls == 21 else HASHES)
                with patch.object(e.a, 'compile_commit', return_value=(arts, {})), \
                     patch.object(e.m, 'rebuild_dvt', return_value=verifier), \
                     patch.object(e.m, 'creation_hashes', side_effect=hashes):
                    with self.assertRaises(e.a.Gate):
                        self.generate('reproducible-build')
                    self.assertFalse((self.out / 'reproducible-build.json').exists())

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


class RealReproducibleTests(unittest.TestCase):
    def fixtures(self):
        root = Path(__file__).with_name('fixtures')
        arts = {name: {'bytecode': {'object': json.loads((root / 'real-creation' / (name + '.json')).read_text())['creationBytecode']}}
                for name in e.m.NAMES}
        code = json.loads((root / 'dvt-creation.json').read_text())['creationBytecode']
        verifier = dict(bytecode=code, creationHashes=e.m.creation_hashes(code, 'OverIssueFraudProofVerifier'))
        return arts, verifier

    def test_real_reproducible_build(self):
        arts, verifier = self.fixtures()
        with patch.object(e.a, 'compile_commit', return_value=(arts, {})), patch.object(e.m, 'rebuild_dvt', return_value=verifier):
            payload, count = e.reproducible(COMMIT, 'forge Version: 1.7.1', {})
        self.assertEqual(count, 11)
        for name in e.m.NAMES:
            self.assertEqual(payload['contracts'][name]['fullCreationKeccak'], payload['contracts'][name]['strippedCreationKeccak'])

    def test_real_sp_change_stops_reproducible_build(self):
        import copy
        arts, verifier = self.fixtures()
        changed = copy.deepcopy(arts)
        changed['SuperPaymaster']['bytecode']['object'] += '00'
        with patch.object(e.a, 'compile_commit', side_effect=[(arts, {}), (changed, {})]), patch.object(e.m, 'rebuild_dvt', return_value=verifier):
            with self.assertRaises(e.a.Gate): e.reproducible(COMMIT, 'forge Version: 1.7.1', {})


if __name__ == '__main__':
    unittest.main()
