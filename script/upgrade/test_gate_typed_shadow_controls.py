"""Real wire mutations prove earlier schema/fixed-value stops; targets remain red."""
import copy
import unittest
import test_gate_template_controls as templates
from gate_assertions import assert_stop

m = templates.manifest.m
CASES, SHADOWS = {}, []


class WireShadowTests(templates.ManifestTemplateTests):
    pass


def register(gate, path):
    expected = 'fraud_schema_pattern_fixture.' + '.'.join(map(str, path))
    def action(self):
        wrapper = copy.deepcopy(self.export)
        parent = wrapper
        for key in path[:-1]: parent = parent[key]
        parent[path[-1]] = '0X' + parent[path[-1]][2:]
        m.fraud_fixture(self.file_ref('typed-shadow-' + gate, wrapper))
    def target(self):
        with assert_stop(self, gate): action(self)
    def shadow(self):
        with assert_stop(self, expected): action(self)
    setattr(WireShadowTests, 'test_target_' + gate, target)
    setattr(WireShadowTests, 'test_shadow_' + gate, shadow)
    CASES[gate] = 'test_gate_typed_shadow_controls.WireShadowTests.test_target_' + gate
    SHADOWS.append('test_gate_typed_shadow_controls.WireShadowTests.test_shadow_' + gate)


for gate, path in {
    'rpc_result_fraud_fixture_key': ('export', 'aggregator'),
    'rpc_result_fraud_fixture_key_2': ('export', 'domainSeparator'),
    'rpc_result_fraud_fixture_who': ('export', 'valid', 'guiltyGuardians', 0),
    'rpc_result_fraud_fixture_fraudProof': ('export', 'valid', 'fraudProof'),
    'rpc_result_fraud_fixture_address': ('export', 'forkState', 'token', 'address'),
    'rpc_result_fraud_fixture_address_2': ('export', 'forkState', 'token', 'address'),
    'rpc_result_fraud_fixture_runtime': ('export', 'forkState', 'token', 'runtimeBytecode'),
    'rpc_result_fraud_fixture_fraudProof_2': ('export', 'mustReject', 2, 'fraudProof'),
    'rpc_result_fraud_fixture_domainDigest': ('export', 'mustReject', 3, 'domainDigest'),
}.items():
    register(gate, path)


def fixed(role, expected):
    def test(self):
        data = copy.deepcopy(self.inputs['data'])
        data[role] = '0X' + data[role][2:]
        with assert_stop(self, expected): m.validate_external(data)
    return test


for role in ('anni', 'dvt', 'committee'):
    name = 'test_shadow_fixed_' + role
    setattr(WireShadowTests, name, fixed(role, 'fixed_' + role))
    SHADOWS.append('test_gate_typed_shadow_controls.WireShadowTests.' + name)
setattr(WireShadowTests, 'test_target_rpc_result_validate_external_key', fixed('anni', 'rpc_result_validate_external_key'))
CASES['rpc_result_validate_external_key'] = 'test_gate_typed_shadow_controls.WireShadowTests.test_target_rpc_result_validate_external_key'


def load_tests(loader, tests, pattern):
    return unittest.TestSuite(loader.loadTestsFromName(name) for name in SHADOWS)


if __name__ == '__main__':
    unittest.main()
