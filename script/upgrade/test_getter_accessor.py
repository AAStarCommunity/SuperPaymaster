"""Offline exact-name and ordered-pair controls for crash-red #20."""
import ast
import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from gate_assertions import assert_stop
import test_old_owner_isolation as fixture
from gate_rename_ast_diff import ROOT, compare

ABI = 'old_owner_getter_abi_GToken_owner'
ACCESSOR = 'old_owner_getter_signature_present'


class GetterAccessorTests(unittest.TestCase):
    def test_getter_pair(self):
        with tempfile.TemporaryDirectory() as directory:
            tree = Path(directory)
            artifacts = fixture.fixture_ast(tree)
            good = copy.deepcopy(artifacts)
            artifacts['GToken']['abi'] = [n for n in artifacts['GToken']['abi'] if n.get('name') != 'owner']
            with patch.object(fixture.a, 'raw_artifact', side_effect=lambda t, n: artifacts[n]):
                with assert_stop(self, ABI):
                    fixture.o.extract(tree)
            observed = []
            need = fixture.a.need
            def record(gate, *args, **kwargs):
                observed.append(gate)
                return need(gate, *args, **kwargs)
            with patch.object(fixture.a, 'raw_artifact', side_effect=lambda t, n: good[n]), patch.object(fixture.a, 'need', side_effect=record):
                fixture.o.extract(tree)
            index = observed.index(ABI)
            self.assertEqual(observed[index:index + 2], [ABI, ACCESSOR],
                             ABI + ': required accessor pair ' + ACCESSOR)

    def test_addition_registry_and_fingerprint(self):
        import test_gate_names as names
        rows = json.loads((ROOT / 'script/upgrade/gate_production_additions.json').read_text())
        row, = [r for r in rows if r['gate'] == ACCESSOR]
        literal, _ = names.inventory()
        self.assertEqual(literal[ACCESSOR], [dict(file=row['file'], function=row['function'], line=row['line'],
                                                primitive_line=row['line'], primitive_column=row['column'])])
        path = ROOT / row['file']
        after = path.read_text()
        marker = "a.need('old_owner_getter_signature_present', sig in signatures, True); "
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
                for altered in (after.replace(marker, marker.replace('sig in signatures', 'True')),
                                after.replace(marker, ''), '\n' + after,
                                after.replace(marker, marker + marker)):
                    with self.subTest(altered=altered[:30]):
                        self.assertTrue(compare(before, altered, {}, row['file'])[1])


if __name__ == '__main__':
    unittest.main()
