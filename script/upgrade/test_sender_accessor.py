"""Offline positive, ordered-pair, and fingerprint controls for crash-red #21."""
import ast
import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import test_gate_template_controls as templates
from gate_assertions import assert_stop
from gate_rename_ast_diff import ROOT, compare

m, a = templates.manifest.m, templates.manifest.a
ACCESSOR = 'a3a_sender_history_rows_present'
EARLIER = 'a3a_sender_history'


class SenderAccessorTests(templates.ManifestTemplateTests):
    def test_sender_accessor_pair(self):
        observed = []
        need = a.need
        def record(gate, *args, **kwargs):
            observed.append(gate)
            return need(gate, *args, **kwargs)
        with patch.object(a, 'need', side_effect=record):
            m.nonce_expectations(self.pin, self.inputs)
        index = observed.index(EARLIER)
        self.assertEqual(observed[index:index + 2], [EARLIER, ACCESSOR],
                         ACCESSOR + ': required accessor pair ' + EARLIER)
        # Positive exact-name firing requires deleting the identical earlier guard.
        # Compile only a temporary copy and restore the module even on failure.
        source = Path(m.__file__).read_text()
        tree = ast.parse(source)
        sites = [n for n in ast.walk(tree) if isinstance(n, ast.Expr) and n.lineno == 1822]
        self.assertEqual(len(sites), 1)
        class Delete(ast.NodeTransformer):
            def visit_Expr(self, node):
                return ast.copy_location(ast.Pass(), node) if node is sites[0] else self.generic_visit(node)
        with tempfile.TemporaryDirectory(prefix='sender-positive-') as tmp:
            path = Path(tmp) / 'manifest_exec.py'
            path.write_text(ast.unparse(ast.fix_missing_locations(Delete().visit(tree))))
            saved = m.__dict__.copy()
            try:
                exec(compile(path.read_text(), str(path), 'exec'), m.__dict__)
                pin = copy.deepcopy(self.pin)
                pin['senders']['deployer']['address'] = a.ZERO
                with assert_stop(self, ACCESSOR):
                    m.nonce_expectations(pin, self.inputs)
            finally:
                m.__dict__.clear()
                m.__dict__.update(saved)

    def test_sender_accessor_registration(self):
        import test_gate_names as names
        rows = json.loads((ROOT / 'script/upgrade/gate_production_additions.json').read_text())
        row, = [r for r in rows if r['gate'] == ACCESSOR]
        literal, _ = names.inventory()
        self.assertEqual(literal[ACCESSOR], [dict(file=row['file'], function=row['function'], line=row['line'],
                                                primitive_line=row['line'], primitive_column=row['column'])])
        names.require_prefix_disjointness(literal, json.loads(names.OPEN_REGISTRY.read_text()),
                                          json.loads(names.REGISTRY.read_text()))
        after = (ROOT / row['file']).read_text()
        marker = "a.need('a3a_sender_history_rows_present', bool(rows), True); "
        before = after.replace(marker, '')
        # This synthetic pair changes only the accessor; bind only its declaration.
        # The real HEAD comparison separately requires every production declaration.
        with tempfile.TemporaryDirectory(prefix='accessor-declaration-') as directory:
            root = Path(directory)
            metadata = root / 'script/upgrade'
            metadata.mkdir(parents=True)
            for name in ('gate_rename_references', 'gate_rename_structural', 'gate_typed_changes'):
                (metadata / (name + '.json')).write_text('[]')
            (metadata / 'gate_production_additions.json').write_text(json.dumps([row]))
            with patch('gate_rename_ast_diff.ROOT', root):
                self.assertFalse(compare(before, after, {}, row['file'])[1])
                for altered in (after.replace(marker, marker.replace('bool(rows)', 'True')),
                                after.replace(marker, ''), '\n' + after, after.replace(marker, marker + marker)):
                    self.assertTrue(compare(before, altered, {}, row['file'])[1])


def load_tests(loader, tests, pattern):
    return unittest.TestSuite(SenderAccessorTests(name) for name in
        ('test_sender_accessor_pair', 'test_sender_accessor_registration'))


if __name__ == '__main__':
    unittest.main()
