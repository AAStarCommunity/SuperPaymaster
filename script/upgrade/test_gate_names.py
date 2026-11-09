#!/usr/bin/env python3
"""Offline gate-site uniqueness and reviewed dynamic-template coverage."""
import ast
from collections import defaultdict
import json
import hashlib
from pathlib import Path
import unittest
from gate_rename_ast_diff import ROOT, gate_sites, compare

SOURCES = ('script/upgrade/manifest_exec.py', 'script/upgrade/old_owner_isolation.py')
REGISTRY = ROOT / 'script/upgrade/gate_templates.json'
OPEN_REGISTRY = ROOT / 'script/upgrade/gate_open_templates.json'


def require_prefix_disjointness(literal, templates, finite_templates=()):
    prefixes = [row['fixed_prefix'] for row in templates]
    collisions = [(prefix, name) for prefix in prefixes if prefix
                  for name in literal if name.startswith(prefix)]
    collisions += [(left, right) for i, left in enumerate(prefixes) if left
                   for right in prefixes[i + 1:] if right and
                   (left.startswith(right) or right.startswith(left))]
    for row in finite_templates:
        node = ast.parse(row['template'], mode='eval').body
        while isinstance(node, ast.BinOp) and isinstance(node.op, ast.Add):
            node = node.left
        if isinstance(node, ast.Constant) and isinstance(node.value, str) and node.value:
            collisions += [(prefix, node.value) for prefix in prefixes if prefix and
                           (prefix.startswith(node.value) or node.value.startswith(prefix))]
    if collisions or any(not prefix for prefix in prefixes):
        raise AssertionError('gate_prefix_disjointness: ' + repr(collisions) +
                             (' missing fixed prefix' if not all(prefixes) else ''))


def inventory(sources=None):
    literal, dynamic = defaultdict(list), []
    if sources is None:
        sources = {file: (ROOT / file).read_text() for file in SOURCES}
    from gate_typed_sites import inventory as typed_inventory
    typed_rows = typed_inventory(sources)
    for file, source in sources.items():
        for function, call, value in gate_sites(ast.parse(source, file), expand=True):
            site = dict(file=file, function=function, line=call.lineno,
                        primitive_line=call.gate_primitive_line, primitive_column=call.gate_primitive_column)
            if isinstance(value, ast.Constant) and isinstance(value.value, str):
                literal[value.value].append(site)
            else:
                dynamic.append(dict(site, template=ast.unparse(value)))
    if set(sources) == set(SOURCES):
        registry = json.loads(REGISTRY.read_text())
        by_site = {(r['file'], r['line'], r['template']): r for r in registry}
        for row in dynamic:
            registered = by_site.get((row['file'], row['line'], row['template']))
            if registered:
                for label in registered['labels']:
                    literal[expanded_name(row['template'], label)].append(dict(row, label=label))
    if set(sources) != set(SOURCES):
        for row in typed_rows:
            value = row['gate']
            if isinstance(value, ast.Constant) and isinstance(value.value, str):
                known = literal[value.value]
                if not any(site['file'] == row['file'] and site['line'] == row['line'] and
                           site.get('primitive_column') == row['column'] for site in known):
                    known.append({k: row[k] for k in ('file', 'function', 'line', 'column')})
    if set(sources) == set(SOURCES):
        for row in typed_inventory():
            value = row['gate']
            if isinstance(value, ast.Constant) and value.value.startswith('rpc_result_'):
                if row['file'] not in SOURCES:
                    literal[value.value].append({k: row[k] for k in ('file', 'function', 'line', 'column')})
            assert not (isinstance(value, ast.Constant) and value.value == 'rpc_result'), 'bare typed gate'
    return literal, dynamic


def expanded_name(template, label):
    def expand(node):
        if isinstance(node, ast.Constant) and isinstance(node.value, str):
            return node.value
        if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Add):
            return expand(node.left) + expand(node.right)
        if isinstance(node, (ast.Name, ast.Subscript)):
            return label
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == 'str':
            return label
        if ast.unparse(node) == "p.get('signature', kind)":
            return label
        if isinstance(node, ast.IfExp):
            assert label in (ast.literal_eval(node.body), ast.literal_eval(node.orelse))
            return label
        raise AssertionError('gate_templates: unsupported finite expansion ' + ast.dump(node))
    return expand(ast.parse(template, mode='eval').body)


def require_unique(literal):
    duplicates = {name: sites for name, sites in literal.items() if len(sites) > 1}
    if duplicates:
        raise AssertionError('gate_name_uniqueness: duplicate_names=' + str(len(duplicates)) + ' ' + json.dumps(duplicates, sort_keys=True))
    return len(duplicates)


def finite_labels(source, line, template):
    """Enumerate the containing loop's label column without executing production."""
    tree = ast.parse(source)
    # Non-loop finite domains were reviewed from callers, schemas and branches.
    # Bind each reviewed enumeration to the exact enclosing production AST.
    domains = json.loads((ROOT / 'script/upgrade/gate_finite_domains.json').read_text())
    for row in domains:
        if row['line'] == line and row['template'] == template:
            scopes = [n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef)
                      and n.name == row['function'] and n.lineno <= line <= n.end_lineno]
            if scopes:
                assert all(hashlib.sha256((ROOT / file).read_bytes()).hexdigest() == digest
                           for file, digest in row['source_sha256'].items()), 'gate_templates: reviewed domain dependency changed'
                assert hashlib.sha256(ast.dump(scopes[0]).encode()).hexdigest() == row['scope_sha256'], 'gate_templates: reviewed domain source changed'
                return row['labels']
    variables = {n.id for n in ast.walk(ast.parse(template, mode='eval')) if isinstance(n, ast.Name)}
    constants = {target.id: node.value for node in tree.body if isinstance(node, ast.Assign)
                 for target in node.targets if isinstance(target, ast.Name)}
    loops = sorted((node for node in ast.walk(tree) if isinstance(node, ast.For)
                    and node.lineno <= line <= node.end_lineno), key=lambda node: node.lineno, reverse=True)
    for loop in loops:
        targets = loop.target.elts if isinstance(loop.target, (ast.Tuple, ast.List)) else [loop.target]
        selected = [index for index, target in enumerate(targets)
                    if isinstance(target, ast.Name) and target.id in variables]
        if not selected:
            continue
        assert len(selected) == 1, 'gate_templates: multiple label variables require review'
        values = constants.get(loop.iter.id) if isinstance(loop.iter, ast.Name) else loop.iter
        assert isinstance(values, (ast.Tuple, ast.List)), 'gate_templates: open label domain requires review'
        result = []
        for value in values.elts:
            item = value.elts[selected[0]] if isinstance(loop.target, (ast.Tuple, ast.List)) else value
            try:
                result.append(ast.literal_eval(item))
            except (ValueError, TypeError):
                raise AssertionError('gate_templates: label is not a finite literal') from None
        assert all(isinstance(value, str) for value in result), 'gate_templates: non-string labels'
        return result
    raise AssertionError('gate_templates: no finite containing label loop')


def require_templates(dynamic, registry):
    def key(row):
        return row['file'], row['function'], row['line'], row['template']
    registered = {key(row): row for row in registry}
    assert len(registered) == len(registry), 'gate_templates: duplicate registration'
    missing = [row for row in dynamic if key(row) not in registered]
    assert not missing, 'gate_templates: unregistered dynamic names ' + json.dumps(missing, sort_keys=True)
    assert set(registered) == {key(row) for row in dynamic}, 'gate_templates: stale registration'
    for row in registry:
        if row.get('domain') == 'R':
            assert row.get('fixed_prefix'), 'gate_templates: R site has no fixed prefix ' + str(row)
            assert not row.get('blocker'), 'gate_templates: blocked R site ' + str(row)
            assert row.get('why_not_enumerable'), 'gate_templates: missing open-domain justification'
            probe = row.get('probe', {})
            assert probe.get('gate', '').startswith(row['fixed_prefix']), 'gate_templates: missing R fixture probe'
            from gate_probe_bindings import validate_site_binding
            validate_site_binding(row, probe)
            continue
        labels = row['labels']
        expected = finite_labels((ROOT / row['file']).read_text(), row['line'], row['template'])
        assert labels == expected, 'gate_templates: enumerated labels changed ' + str(expected)
        if any(p['file'] == 'script/upgrade/probe_gate_r.py' for p in row['probes'].values()):
            import gate_r_domains
            derived = (gate_r_domains.isolation_labels(row['line']) if row['file'].endswith('old_owner_isolation.py')
                       else gate_r_domains.labels(row['line']))
            assert labels == derived, 'gate_templates: reclassified constant domain changed'
        if not labels:
            import gate_r_domains
            assert row.get('empty_schema_acceptance') and row['line'] == 381 and not gate_r_domains.labels(381), 'gate_templates: empty label domain without synthetic-schema proof'
        if row.get('empty_schema_acceptance'):
            from test_gate_empty_schema import SCHEMA, constraint_counts, EmptySchemaTests
            proof = row['empty_schema_acceptance']
            assert row['line'] in (381, 389), 'gate_templates: unexpected empty schema site'
            assert constraint_counts(json.loads(SCHEMA.read_text())) == (0, 0), 'gate_templates: revisit empty schema probes'
            assert (ROOT / proof['file']).is_file() and proof['function'] == 'run_probes'
            assert callable(getattr(EmptySchemaTests, proof['test_method']))
            assert callable(getattr(EmptySchemaTests, proof['tripwire']))
        assert len(labels) == len(set(labels)), 'gate_templates: duplicate enumerated labels'
        assert set(row['probes']) == set(labels), 'gate_templates: missing per-label probes'
        for label, probe in row['probes'].items():
            if probe['file'] in ('script/upgrade/probe_gate_r.py', 'script/upgrade/probe_gate_dsr2.py'):
                from gate_probe_bindings import validate_site_binding
                validate_site_binding(row, probe)
            path = ROOT / probe['file']
            tree = ast.parse(path.read_text())
            functions = {n.name for n in ast.walk(tree) if isinstance(n, ast.FunctionDef)}
            assert probe['function'] in functions, 'gate_templates: probe function missing ' + label
            assert probe['gate'] == expanded_name(row['template'], label), 'gate_templates: probe gate differs ' + label


class GateNameTests(unittest.TestCase):
    def test_literal_names_unique(self):
        literal, _ = inventory()
        count = require_unique(literal)
        print(f'GATE_NAMES duplicate_names={count}', flush=True)

    def test_dynamic_templates_registered(self):
        _, dynamic = inventory()
        require_templates(dynamic, json.loads(REGISTRY.read_text()) + json.loads(OPEN_REGISTRY.read_text()))

    def test_open_prefixes_disjoint(self):
        literal, _ = inventory()
        require_prefix_disjointness(literal, json.loads(OPEN_REGISTRY.read_text()), json.loads(REGISTRY.read_text()))

    def test_prefix_counterexamples_rejected(self):
        for literals, prefixes in ((['manifest_error'], ['manifest_']),
                                   ([], ['old_owner_role_', 'old_owner_role_admin_']),
                                   ([], ['old_owner_role_admin_', 'old_owner_role_'])):
            with self.subTest(prefixes=prefixes):
                with self.assertRaisesRegex(AssertionError, 'gate_prefix_disjointness',
                                            msg='gate_prefix_disjointness: collision accepted'):
                    require_prefix_disjointness(literals, [dict(fixed_prefix=p) for p in prefixes])
        for fixed, finite in (('member_', "'member_role_' + label"),
                              ('member_role_', "'member_' + label")):
            with self.assertRaisesRegex(AssertionError, 'gate_prefix_disjointness',
                                        msg='gate_prefix_disjointness: finite prefix collision accepted'):
                require_prefix_disjointness([], [dict(fixed_prefix=fixed)], [dict(template=finite)])

    def test_registered_finite_templates_labels_and_probes(self):
        _, dynamic = inventory()
        registry = json.loads(REGISTRY.read_text())
        keys = {(row['file'], row['line']) for row in registry}
        reviewed = [row for row in dynamic if (row['file'], row['line']) in keys]
        require_templates(reviewed, registry)

    def test_ast_diff_accepts_only_mapped_gate_strings(self):
        mapping = {'old': [dict(new='old_pin', file='script/example.py', function='check', line=2)]}
        before = "def check():\n a.need('old', 1, 1)\n"
        after = "def check():\n a.need('old_pin', 1, 1)\n"
        allowed, rejected = compare(before, after, mapping, 'script/example.py')
        self.assertEqual(len(allowed), 1)
        self.assertEqual(rejected, [])
        for changed in (after.replace('1, 1', '0, 1'), after.replace('a.need', 'other')):
            with self.subTest(changed=changed):
                self.assertTrue(compare(before, changed, mapping, 'script/example.py')[1])
        self.assertTrue(compare("value = 'old'", "value = 'old_pin'", mapping, 'script/example.py')[1])
        self.assertTrue(compare("value = 'old'", "value = 'old_pin'", mapping, 'script/test_example.py')[1])

    def test_ast_diff_scopes_prefix_expression_to_gate(self):
        before = "def check(case):\n a.need(case['gate'], 0, 1)\n"
        after = "def check(case):\n a.need('fork_case_' + case['gate'], 0, 1)\n"
        mapping = {"case['gate']": [dict(new="'fork_case_' + case['gate']", kind='prefix_expression',
                                         file='seed.py', function='check', line=2)]}
        self.assertFalse(compare(before, after, mapping, 'seed.py')[1])
        self.assertTrue(compare(before, after.replace(', 0, 1', ', 1, 1'), mapping, 'seed.py')[1])
        self.assertTrue(compare(before.replace('a.need', 'consume'), after.replace('a.need', 'consume'), mapping, 'seed.py')[1])

    def test_seeded_duplicate_rejected(self):
        literal, _ = inventory({'seed.py': "def fixture():\n a.need('seed', 1, 1)\n a.Gate('seed', 0, 1)\n"})
        with self.assertRaisesRegex(AssertionError, 'gate_name_uniqueness',
                                    msg='gate_name_uniqueness: duplicate accepted'):
            require_unique(literal)

    def test_transitive_wrapper_duplicate_rejected(self):
        source = ("def newly_added(label):\n a.need(label, 1, 1)\n"
                  "def outer(name):\n newly_added(label=name)\n"
                  "outer('duplicate_wrapper')\nouter('duplicate_wrapper')\n")
        literal, dynamic = inventory({'seed.py': source})
        self.assertEqual(dynamic, [])
        with self.assertRaisesRegex(AssertionError, 'duplicate_wrapper',
                                    msg='gate_name_uniqueness: forwarding duplicate accepted'):
            require_unique(literal)

    def test_suffix_expansion_and_lexical_scope(self):
        source = ("def wrapper(name):\n a.need(name + '_hash', 1, 1)\n"
                  "def outer(gate):\n wrapper(gate)\n"
                  "outer('reviewed')\n"
                  "def unrelated():\n def wrapper(value):\n  return value\n wrapper('reviewed')\n")
        literal, dynamic = inventory({'seed.py': source})
        self.assertEqual(set(literal), {'reviewed_hash'})
        self.assertEqual(len(literal['reviewed_hash']), 1)
        self.assertEqual(dynamic, [])
        mapping = {'reviewed': [dict(new='reviewed_pin', file='seed.py', function='<module>', line=5)]}
        self.assertFalse(compare(source, source.replace("outer('reviewed')", "outer('reviewed_pin')"), mapping, 'seed.py')[1])

    def test_suffix_definition_duplicates_rejected(self):
        source = ("def wrap(label):\n a.need(label + '_hash', 1, 1)\n"
                  "wrap('reviewed')\na.need('reviewed_hash', 1, 1)\n")
        literal, _ = inventory({'seed.py': source})
        with self.assertRaisesRegex(AssertionError, 'reviewed_hash',
                                    msg='gate_name_uniqueness: suffix duplicate accepted'):
            require_unique(literal)

    def test_forwarded_expected_name_is_reference(self):
        source = ("def check(gate):\n"
                  " try:\n  action()\n except a.Gate as error:\n  tripped = error.record['gate']\n"
                  " a.need('control', tripped, gate)\n"
                  "def outer(name):\n check(name)\nouter('old')\n")
        mapping = {'old': [dict(new='old_pin', file='seed.py', function='<module>', line=9)]}
        self.assertFalse(compare(source, source.replace("outer('old')", "outer('old_pin')"), mapping, 'seed.py')[1])
        literal, _ = inventory({'seed.py': source})
        self.assertEqual(set(literal), {'control'})

    def test_only_direct_record_forwarding_excluded(self):
        source = ("a.Gate(error['gate'], error['observed'], error['expected'])\n"
                  "a.Gate(error['gate'] + '_suffix', error['observed'], error['expected'])\n"
                  "a.Gate(case['gate'], 0, 1)\n")
        _, dynamic = inventory({'seed.py': source})
        self.assertEqual([row['line'] for row in dynamic], [2, 3])

    def test_unregistered_dynamic_rejected(self):
        _, dynamic = inventory({'seed.py': "def fixture(label):\n a.need('seed_' + label, 1, 1)\n"})
        with self.assertRaisesRegex(AssertionError, 'gate_templates: unregistered',
                                    msg='gate_templates: dynamic accepted'):
            require_templates(dynamic, [])


def open_name_test(row):
    def test(self):
        expression = row['expression']
        if row['template'] == 'gate':
            tree = ast.parse((ROOT / row['file']).read_text())
            scope = next(n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef)
                         and n.name == row['function'] and n.lineno <= row['line'] <= n.end_lineno)
            bindings = [n for n in ast.walk(scope) if isinstance(n, ast.Assign)
                        and n.lineno < row['line'] and any(isinstance(t, ast.Name) and t.id == 'gate' for t in n.targets)]
            self.assertEqual(expression, ast.unparse(max(bindings, key=lambda n:n.lineno).value))
        else:
            self.assertEqual(expression, row['template'])
        names = []
        for label in ('fixture_label_one', 'fixture_label_two'):
            bindings = dict(name=label, label=label, who=label, token=label,
                            role={'name':label}, row={'name':label}, case={'gate':label})
            if " + role" in expression and "role['name']" not in expression:
                bindings['role'] = label
            names.append(eval(compile(ast.parse(expression,mode='eval'),'<reviewed-template>','eval'),
                              {'__builtins__': {}}, bindings))
        self.assertNotEqual(*names)
        self.assertTrue(all(name.startswith(row['fixed_prefix']) for name in names))
    return test


for _row in json.loads(OPEN_REGISTRY.read_text()):
    setattr(GateNameTests, 'test_open_two_labels_' + Path(_row['file']).stem + '_' + str(_row['line']), open_name_test(_row))


if __name__ == '__main__':
    unittest.main()
