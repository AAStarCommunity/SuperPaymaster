"""Regression counterexamples for the independent 6e tooling review."""
import contextlib
import io
import json
import unittest
from unittest.mock import patch
import gate_rename_ast_diff as diff
import test_gate_names as names


class ReviewControls(unittest.TestCase):
    def test_lookup_in_label_rejected(self):
        self.check_rejected("a.need(d['old'], 0, 1)", 'script/example.py')

    def test_test_lookup_rejected(self):
        self.check_rejected("assert response['old'] == 1", 'script/test_example.py')

    def test_unproven_record_rejected(self):
        self.check_rejected("dict(gate='old')", 'script/example.py')

    def check_rejected(self, source, file):
        mapping = {'old': [dict(new='old_pin', file=file, function='<module>', line=1)]}
        self.assertTrue(diff.compare(source, source.replace("'old'", "'old_pin'"), mapping, file)[1])

    def check_duplicate(self, source):
        literal, dynamic = names.inventory({'seed.py': source})
        self.assertFalse(dynamic)
        self.assertEqual(len(literal['dup']), 2)
        with self.assertRaisesRegex(AssertionError, 'gate_name_uniqueness'):
            names.require_unique(literal)

    def test_distinct_forwarded_guards(self):
        self.check_duplicate("def check(gate):\n a.need(gate, 0, 1)\n a.need(gate, 2, 3)\ncheck('dup')\n")

    def test_helper_alias(self):
        self.check_duplicate("check = a.need\na.need('dup', 0, 1)\ncheck(gate='dup', observed=0, expected=1)\n")

    def test_wrapper_default(self):
        self.check_duplicate("def check(gate='dup'):\n a.need(gate, 0, 1)\ncheck()\na.need('dup', 0, 1)\n")

    def test_stale_open_binding(self):
        row = json.loads(names.OPEN_REGISTRY.read_text())[0]
        row['probe']['function'] = 'nonexistent_probe'
        row['probe']['test_method'] = 'nonexistent_test'
        with self.assertRaisesRegex(AssertionError, 'binding'):
            names.require_templates([row], [row])

    def test_wrong_executable_site_binding(self):
        row = json.loads(names.OPEN_REGISTRY.read_text())[0]
        row['line'] += 1
        with self.assertRaisesRegex(AssertionError, 'binding'):
            names.require_templates([row], [row])

    def test_shared_label_parameter_rejected(self):
        source = "def check(gate):\n a.need(gate, 0, 1)\n consume(gate)\ncheck('old')\n"
        mapping = {'old': [dict(new='old_pin', file='seed.py', function='<module>', line=4)]}
        self.assertTrue(diff.compare(source, source.replace("'old'", "'old_pin'"), mapping, 'seed.py')[1])

    def test_shared_expected_parameter_rejected(self):
        source = ("def check(gate):\n try:\n  action()\n except a.Gate as error:\n"
                  "  tripped = error.record['gate']\n a.need('control', tripped, gate)\n consume(gate)\ncheck('old')\n")
        mapping = {'old': [dict(new='old_pin', file='seed.py', function='<module>', line=8)]}
        self.assertTrue(diff.compare(source, source.replace("'old'", "'old_pin'"), mapping, 'seed.py')[1])

    def test_execution_binding_multiset(self):
        from gate_probe_bindings import reconcile
        expected = [('seed.py', 3, 'dup', ReviewControls, 'test_helper_alias')]
        with patch('gate_probe_bindings.registered_cases', return_value=expected):
            reconcile([], expected)
            for actual in ([], expected * 2, [('other.py', *expected[0][1:])],
                           [('seed.py', 4, *expected[0][2:])],
                           [('seed.py', 3, 'other', *expected[0][3:])]):
                with self.subTest(actual=actual), self.assertRaisesRegex(AssertionError, 'executed binding mismatch'):
                    reconcile([], actual)

    def test_keyword_only_default(self):
        self.check_duplicate("def check(*, gate='dup'):\n a.need(gate, 0, 1)\ncheck()\na.need('dup', 0, 1)\n")

    def test_unsupported_alias_escape_rejected(self):
        with self.assertRaisesRegex(ValueError, 'unsupported helper alias'):
            names.inventory({'seed.py': "check = a.need\nother = check\nother('dup', 0, 1)\n"})

    def test_deleted_file_rejected(self):
        file = 'script/upgrade/manifest_exec.py'
        with patch.object(diff, 'files', side_effect=[{file}, set()]), patch.object(diff, 'read', return_value='{}'):
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                result = diff.main(['BEFORE', 'AFTER'])
        self.assertEqual(result, 1, output.getvalue())
        self.assertIn('GATE_RENAME_AST_DIFF FAIL', output.getvalue())


if __name__ == '__main__':
    unittest.main()
