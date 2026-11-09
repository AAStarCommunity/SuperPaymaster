"""Fingerprint mismatches and unused declarations are never rename exemptions."""
import ast
import contextlib
import hashlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import gate_rename_ast_diff as d


class DeclarationControls(unittest.TestCase):
    def check(self, mutate):
        file = 'seed.py'
        before = "a.need(case['gate'], 0, 1)\n"
        after = "a.need('prefix_' + case['gate'], 0, 1)\n"
        digest = lambda n: hashlib.sha256(ast.dump(n).encode()).hexdigest()
        declaration = dict(file=file, line=1, path='seed.py.body[0].value.args[0]',
                           ast_sha256=[digest(ast.parse(s).body[0].value.args[0]) for s in (before, after)],
                           source_sha256=[hashlib.sha256(s.encode()).hexdigest() for s in (before, after)], reason='counterexample fixture')
        mapping = {"case['gate']": [dict(file=file, line=1, kind='prefix_expression', new="'prefix_' + case['gate']")]}
        with tempfile.TemporaryDirectory(prefix='6e-declaration-') as tmp:
            root = Path(tmp)
            directory = root / 'script/upgrade'
            directory.mkdir(parents=True)
            for name in ('gate_production_additions', 'gate_typed_changes', 'gate_rename_structural'):
                (directory / (name + '.json')).write_text('[]')
            path = directory / 'gate_rename_references.json'
            path.write_text(json.dumps([declaration]))
            with patch.object(d, 'ROOT', root):
                self.assertEqual(d.compare(before, after, mapping, file)[1], [])
                after, declarations = mutate(after, declaration)
                path.write_text(json.dumps(declarations))
                allowed, faults = d.compare(before, after, mapping, file)
        self.assertTrue(faults)
        for fault in faults:
            print('REJECTED ' + fault)
        print('GATE_RENAME_AST_DIFF FAIL counterexample=' + self._testMethodName)

    def test_declared_lookup_key_fingerprint(self):
        self.check(lambda after, row: (after.replace("case['gate']", "case['different']"), [row]))

    def test_stale_declaration(self):
        self.check(lambda after, row: (after, [row, dict(row, path='seed.py.body[99]')]))

    def test_fingerprint_mismatch_even_if_mapping_accepts(self):
        self.check(lambda after, row: (after, [dict(row, ast_sha256=['0' * 64, '0' * 64])]))


class OtherDeclarations(unittest.TestCase):
    def check_metadata(self, category, before, after, row, mutations):
        with tempfile.TemporaryDirectory(prefix='6e-other-declarations-') as tmp:
            root = Path(tmp)
            directory = root / 'script/upgrade'
            directory.mkdir(parents=True)
            for name in ('gate_production_additions', 'gate_typed_changes', 'gate_rename_structural',
                         'gate_rename_references'):
                (directory / (name + '.json')).write_text('[]')
            path = directory / (category + '.json')
            path.write_text(json.dumps([row]))
            with patch.object(d, 'ROOT', root):
                self.assertEqual(d.compare(before, after, {}, row['file'])[1], [])
                for change in mutations:
                    with self.subTest(change=change):
                        path.write_text(json.dumps([dict(row, **change)]))
                        self.assertTrue(d.compare(before, after, {}, row['file'])[1])
                path.write_text(json.dumps([row]))
                self.assertTrue(d.compare(before, before, {}, row['file'])[1])

    def test_non_python_declaration_is_unused(self):
        with tempfile.TemporaryDirectory(prefix='6e-non-python-declaration-') as tmp:
            root = Path(tmp)
            directory = root / 'script/upgrade'
            directory.mkdir(parents=True)
            for name in ('gate_production_additions', 'gate_typed_changes',
                         'gate_rename_structural', 'gate_rename_references'):
                (directory / (name + '.json')).write_text('[]')
            (directory / 'gate_rename_references.json').write_text('[{"file":"notes.txt"}]')
            with patch.object(d, 'ROOT', root), patch.object(d, 'files', return_value={'notes.txt'}), \
                    patch.object(d, 'read', return_value='{}'), contextlib.redirect_stdout(io.StringIO()) as output:
                self.assertEqual(d.main(['BEFORE', 'WORKTREE']), 1)
            self.assertIn('stale/unused declaration outside Python AST comparison', output.getvalue())

    def test_each_keyword_requires_exact_declaration(self):
        before = "import a3a_exec as a\na.typed('0x', rx)\n"
        after = "import a3a_exec as a\na.typed('0x', rx, gate='rpc_result_check_value')\n"
        keyword = ast.parse(after).body[1].value.keywords[0]
        row = dict(file='seed.py', kind='keyword', function='module', line=2, column=0,
                   gate='rpc_result_check_value', ast_sha256=hashlib.sha256(ast.dump(keyword).encode()).hexdigest())
        self.check_metadata('gate_typed_changes', before, after, row,
                            [dict(line=99), dict(ast_sha256='0'*64), dict(gate='wrong'), dict(function='wrong')])

    def test_signature_declaration_cannot_be_stale(self):
        before = "def typed(value, rx, gate='shared'):\n return value\n"
        after = "def typed(value, rx, gate):\n return value\n"
        row = dict(file='seed.py', kind='signature', path='seed.py.body[0].args',
                   ast_sha256=[hashlib.sha256(ast.dump(ast.parse(s).body[0].args).encode()).hexdigest()
                               for s in (before, after)])
        self.check_metadata('gate_typed_changes', before, after, row,
                            [dict(path='seed.py.body[99].args'), dict(ast_sha256=['0'*64]*2)])

    def test_structure_declaration_cannot_be_stale(self):
        before = "def test_check():\n assert value == 1\n"
        after = "def test_check():\n assert value == 2\n"
        row = dict(file='test_seed.py', name='test_check', reason='synthetic reviewed control',
                   ast_sha256=[hashlib.sha256(ast.dump(ast.parse(s).body[0]).encode()).hexdigest()
                               for s in (before, after)])
        self.check_metadata('gate_rename_structural', before, after, row,
                            [dict(name='wrong'), dict(ast_sha256=['0'*64]*2)])

    def test_production_addition_requires_exact_declaration(self):
        before = "def check():\n pass\n"
        after = "def check():\n pass\n a.need('new_gate', value, 1)\n"
        node = ast.parse(after).body[0].body[1]
        row = dict(file='seed.py', function='check', line=3, column=1, gate='new_gate',
                   ast_sha256=hashlib.sha256(ast.dump(node).encode()).hexdigest())
        self.check_metadata('gate_production_additions', before, after, row,
                            [dict(line=99), dict(ast_sha256='0'*64), dict(gate='wrong')])


if __name__ == '__main__':
    unittest.main()
