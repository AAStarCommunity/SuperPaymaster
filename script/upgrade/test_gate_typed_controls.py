"""Required typed labels, alias scanning, and exact DSR2 registration controls."""
import ast
import copy
import json
import unittest
import sp_upgrade_exec as u
from gate_typed_sites import inventory, ROOT
from gate_probe_bindings import validate_site_binding


class TypedControls(unittest.TestCase):
    def test_missing_gate_typeerror(self):
        with self.assertRaises(TypeError):
            getattr(u.a, 'typed')('0x', u.a.HEXDATA)

    def test_alias_inventory(self):
        for source in ("import a3a_exec as custom\ncheck = custom.typed\ncheck('x', rx)",
                       "from a3a_exec import typed as first\ncheck = first\ncheck('x', rx)",
                       "import sp_upgrade_exec as u\ncheck = u.a.typed\ncheck('x', rx)"):
            with self.subTest(source=source):
                with self.assertRaisesRegex(ValueError, 'typed missing gate'):
                    from test_gate_names import inventory as names_inventory
                    names_inventory({'seed.py': source})
                rows = inventory({'seed.py': source.replace("check('x', rx)", "check('x', rx, gate='unique')")})
                self.assertEqual(len(rows), 1)
                self.assertEqual(ast.literal_eval(rows[0]['gate']), 'unique')

    def test_new_gate_inventory_complete(self):
        declared = json.loads((ROOT / 'script/upgrade/gate_typed_inventory.json').read_text())
        observed = [r for r in inventory() if isinstance(r['gate'], ast.Constant)
                    and r['gate'].value.startswith('rpc_result_')]
        self.assertEqual(len(observed), len(declared))
        self.assertEqual({r['gate'] for r in declared}, {r['gate'].value for r in observed})
        self.assertEqual(len({r['gate'] for r in declared}), len(declared))
        keys = ('file', 'function', 'line', 'column')
        self.assertEqual({tuple(r[k] for k in keys) + (r['gate'],) for r in declared},
                         {tuple(r[k] for k in keys) + (r['gate'].value,) for r in observed})
        for row in observed:
            self.assertNotEqual(row['gate'].value, 'rpc_result')

    def test_probe_refuses_real_source(self):
        from probe_typed_gates import rewrite
        with self.assertRaisesRegex(AssertionError, 'refusing to mutate real worktree'):
            rewrite(ROOT / 'script/a3a/a3a_exec.py', {}, 'malformed', True)

    def test_registry_pair_binding(self):
        rows = json.loads((ROOT / 'script/upgrade/gate_templates.json').read_text())
        row = next(r for r in rows if r['file'].endswith('old_owner_isolation.py') and r['line'] == 530)
        probe = row['probes']['Registry']
        validate_site_binding(row, probe)
        for key, value in (('test_method', 'test_target_' + probe['gate']), ('target_method', 'missing'),
                           ('earlier', 'wrong'), ('function', 'remaining'), ('gate', 'wrong')):
            bad = copy.deepcopy(probe)
            bad[key] = value
            with self.subTest(key=key), self.assertRaisesRegex(AssertionError, 'binding'):
                validate_site_binding(row, bad)
        bad = dict(row, line=531)
        with self.assertRaisesRegex(AssertionError, 'binding'):
            validate_site_binding(bad, probe)


if __name__ == '__main__':
    unittest.main()
