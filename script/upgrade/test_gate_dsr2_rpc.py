"""Offline DSR ruling-2 controls for the eleven requested rpc_result sites."""
import copy
import unittest
import test_gate_template_controls as templates
from gate_assertions import assert_stop

m = templates.manifest.m
CASES = []
for suffix, line, path in (
    ('key', 457, ('aggregator',)),
    ('key_2', 458, ('domainSeparator',)),
    ('who', 464, ('valid', 'guiltyGuardians', 0)),
    ('fraudProof', 472, ('valid', 'fraudProof')),
    ('address', 474, ('forkState', 'token', 'address')),
    ('address_2', 482, ('forkState', 'token', 'address')),
    ('runtime', 484, ('forkState', 'token', 'runtimeBytecode')),
    ('fraudProof_2', 510, ('mustReject', 2, 'fraudProof')),
    ('domainDigest', 517, ('mustReject', 3, 'domainDigest')),
):
    CASES.append(dict(gate='rpc_result_fraud_fixture_' + suffix, line=line, path=path,
                      earlier='fraud_schema_pattern_fixture.export.' + '.'.join(map(str, path)),
                      e_line=403))
CASES += [dict(gate='rpc_result_validate_external_key', line=643, earlier='fixed_anni', e_line=631),
          dict(gate='rpc_result_validate_external_who', line=664, earlier='sampled_deployer_only', e_line=660)]


class RpcShadowTests(templates.ManifestTemplateTests):
    pass


def action(self, row):
    if 'path' not in row:
        data = copy.deepcopy(self.inputs['data'])
        if row['line'] == 643:
            data['anni'] = 'invalid'
        else:
            data['sampled'] = ['invalid']
        m.validate_external(data)
        return
    wrapper = copy.deepcopy(self.export)
    path = row['path']
    parent = wrapper['export']
    for key in path[:-1]:
        parent = parent[key]
    # Prefixless domain/token values remain ABI-readable but violate wire regexes.
    # Other lowercased fields use short hex, preserving the malformed shape.
    old = parent[path[-1]]
    if row['line'] in (458, 474, 482):
        parent[path[-1]] = old[2:]
    else:
        parent[path[-1]] = old[:-2] if row['line'] in (457, 464) else '0X' + old[2:]
    if row['line'] == 464:
        for negative in wrapper['export']['mustReject']:
            if negative['id'] != 'N1':
                negative['guiltyGuardians'][0] = parent[path[-1]]
    if row['line'] == 472:
        for negative in wrapper['export']['mustReject']:
            if negative['id'] != 'N3':
                negative['fraudProof'] = parent[path[-1]]
    m.fraud_fixture(self.file_ref('dsr2-rpc-' + row['gate'], wrapper))


def control(row, expected):
    def test(self):
        with assert_stop(self, expected):
            action(self, row)
    return test


for row in CASES:
    for mode, expected in [('shadow', row['earlier']), ('target', row['gate'])]:
        setattr(RpcShadowTests, 'test_' + mode + '_' + row['gate'], control(row, expected))
    if row['line'] == 482:
        row['second'] = ('rpc_result_fraud_fixture_address', 474)
        setattr(RpcShadowTests, 'test_second_' + row['gate'], control(row, row['second'][0]))


def load_tests(loader, tests, pattern):
    return unittest.TestSuite(RpcShadowTests('test_shadow_' + row['gate']) for row in CASES)


if __name__ == '__main__':
    unittest.main()
