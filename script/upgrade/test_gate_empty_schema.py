"""DSR ruling 1: exercise empty schema domains through the production loader."""
from contextlib import contextmanager
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import manifest_exec as m
from gate_assertions import assert_stop

SCHEMA = Path(m.__file__).with_name('fraud-proof-fixture.schema.json')
CASES = ((389, 'min_properties', 'fraud_schema_properties_export.synthetic'),
         (381, 'enum', 'fraud_schema_enum_export.synthetic'))


def constraint_counts(node):
    if isinstance(node, list):
        pairs = [constraint_counts(child) for child in node]
        return tuple(sum(p[i] for p in pairs) for i in range(2))
    if not isinstance(node, dict):
        return (0, 0)
    pairs = [constraint_counts(child) for child in node.values()]
    return (int(node.get('minProperties', 0) > 0) + sum(p[0] for p in pairs),
            int('enum' in node) + sum(p[1] for p in pairs))


@contextmanager
def schema_copy(schema):
    # Only intercept the schema-loading accessor, Path.read_text, for this exact
    # path. The production json.loads / format adapter / validator still run.
    read = Path.read_text
    with tempfile.TemporaryDirectory() as directory:
        temporary = Path(directory) / SCHEMA.name
        temporary.write_text(json.dumps(schema))
        def accessor(path, *args, **kwargs):
            return read(temporary if path == SCHEMA else path, *args, **kwargs)
        with patch.object(Path, 'read_text', accessor):
            yield


def sample(node):
    if 'const' in node:
        return node['const']
    kind = node.get('type')
    if kind == 'object':
        return {key: sample(child) for key, child in node.get('properties', {}).items()}
    if kind == 'array':
        return [sample(child) for child in node.get('prefixItems', [node.get('items')] * node['minItems'])]
    if kind == 'integer':
        return node.get('minimum', 0)
    pattern = node.get('pattern', '')
    if pattern.startswith('^0x'):
        return '0x' + ('1' * 40 if '{40}' in pattern else '1' * 64 if '{64}' in pattern else '01')
    return '0'


class EmptySchemaTests(unittest.TestCase):
    def check_synthetic(self, kind, gate):
        schema = json.loads(SCHEMA.read_text())
        export = schema['properties']['export']
        export['properties']['synthetic'] = ({'type': 'object', 'minProperties': 1}
                                              if kind == 'min_properties' else {'enum': ['allowed']})
        value = sample(export)
        value['version'] = 'BLSAggregator-4.12.0'
        value['synthetic'] = {'present': True} if kind == 'min_properties' else 'allowed'
        with schema_copy(schema):
            self.assertEqual(m.fraud_format_only(value), value)
            value['synthetic'] = {} if kind == 'min_properties' else 'forbidden'
            with assert_stop(self, gate):
                m.fraud_format_only(value)

    def test_min_properties(self):
        self.check_synthetic('min_properties', 'fraud_schema_properties_export.synthetic')

    def test_enum(self):
        self.check_synthetic('enum', 'fraud_schema_enum_export.synthetic')

    def test_tripwire_min_properties(self):
        self.assertEqual(constraint_counts(json.loads(SCHEMA.read_text()))[0], 0,
                         'schema_tripwire_min_properties: revisit synthetic probes')

    def test_tripwire_enum(self):
        self.assertEqual(constraint_counts(json.loads(SCHEMA.read_text()))[1], 0,
                         'schema_tripwire_enum: revisit synthetic probes')


if __name__ == '__main__':
    unittest.main()
