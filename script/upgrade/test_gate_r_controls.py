"""Offline controls for the constant-domain sites previously classified R."""
import copy
import json
import unittest
from pathlib import Path
from gate_assertions import assert_stop
import gate_r_domains as domains
import test_manifest_exec as fixture
from test_gate_template_controls import ManifestTemplateTests

m = fixture.m
CASES = []
BLOCKERS = []


from functools import lru_cache


@lru_cache(maxsize=1)
def constant_plan_fixture():
    case = fixture.ManifestTests()
    try:
        case.setUp()
        return copy.deepcopy((case.plan, case.inputs, case.pin))
    finally:
        case.doCleanups()


class ConstantRTests(unittest.TestCase):
    def setUp(self):
        self.plan, self.inputs, self.pin = copy.deepcopy(constant_plan_fixture())


for name in dir(ManifestTemplateTests):
    if name.startswith('test_'):
        setattr(ConstantRTests, name, None)


class SchemaRTests(unittest.TestCase):
    pass


def add(cls, line, label, gate, action):
    name = 'test_r_' + str(line) + '_' + label
    setattr(cls, name, action)
    CASES.append((cls, name, gate, line))


def control(line, label, gate):
    def test(self):
        if line == 1993:
            art = dict(runtimeIdentity=dict(artifactRuntime='0x' + '00' * 32,
                       ranges=[dict(name=label, start=0, length=32)]))
            m.runtime_bytes(art, {label: 1})
            with assert_stop(self, gate):
                m.runtime_bytes(art, __import__('collections').defaultdict(int))
        elif line == 2886:
            plan = copy.deepcopy(self.plan)
            # The test plan has every sender and Phase C owner from the fixed schema.
            for step in plan['steps']:
                step['tx']['gas'] = '0x5208'
                for tx in step.get('variants', {}).values():
                    tx['gas'] = '0x5208'
            for sender in plan['pin']['senders'].values():
                sender['balance'] = 10**30
            plan['pin']['phaseC']['owner']['balance'] = 10**30
            m.budget(plan)
            if label == 'owner':
                plan['pin']['phaseC']['owner']['balance'] = -10**30
            else:
                plan['pin']['senders'][label]['balance'] = -10**30
            with assert_stop(self, gate):
                m.budget(plan)
        elif line in (2897, 2910, 2913, 2920):
            expected = copy.deepcopy(self.plan)
            plan = copy.deepcopy(expected)
            m.validate_plan(plan, self.inputs, expected=expected)
            if line == 2897:
                plan[label] = None
                # externalInputs has an earlier, independently mandatory binding.
            elif line == 2910:
                next(s for s in plan['steps'] if label in s)[label] = None
            elif line == 2913:
                plan['steps'][0]['tx'][label] = 'different'
            else:
                step = next(s for s in plan['steps'] if 'variants' in s)
                step['variants']['placeholder'][label] = 'different'
            with assert_stop(self, gate):
                m.validate_plan(plan, plan['externalInputs'] if line == 2897 and label == 'externalInputs' else self.inputs, expected=expected)
        elif line == 2841:
            from unittest.mock import patch
            kind = label if label in ('code', 'codeHash', 'balance', 'storage') else 'word'
            p = dict(kind=kind, target=fixture.u.SP, signature=label, slot=fixture.a.ZERO32, expected=1)
            if kind == 'code': p['expected'] = '0x6000'
            if kind == 'codeHash': p['expected'] = m.a.keccak('0x6000')
            with patch.object(m.a, 'call', return_value='0x' + format(1, '064x')), patch.object(m.u, 'code', return_value='0x6000'):
                rpc = lambda method, params: '0x1' if method == 'eth_getBalance' else '0x' + format(1, '064x')
                m.check_predicate(rpc, p)
                p['expected'] = None
                with assert_stop(self, gate):
                    m.check_predicate(rpc, p)
        else:
            arts = copy.deepcopy(fixture.ART['contracts'])
            arts['OverIssueFraudProofVerifier'] = dict(bytecode=fixture.VERIFIER_CODE)
            for name, art in arts.items():
                art['creationHashes'] = m.creation_hashes(art['bytecode'], name)
            evidence = dict(contracts={name: copy.deepcopy(art['creationHashes']) for name, art in arts.items()})
            reference = copy.deepcopy(arts)
            m.compare_build_evidence(evidence, arts, reference)
            if line == 343:
                reference[label]['bytecode'] = '0x6001' + reference[label]['bytecode'][6:]
            elif line == 345:
                arts[label]['creationHashes'] = {}
            else:
                evidence['contracts'][label]['strippedCreationKeccak' if line == 347 else 'fullCreationKeccak'] = fixture.a.ZERO32
            with assert_stop(self, gate):
                m.compare_build_evidence(evidence, arts, reference)
    return test


def schema_value(node):
    if 'const' in node: return node['const']
    kind = node.get('type')
    if kind == 'object': return {key:schema_value(child) for key,child in node['properties'].items()}
    if kind == 'array': return [schema_value(child) for child in node.get('prefixItems', [node.get('items')]*node['minItems'])]
    if kind == 'integer': return node.get('minimum',0)
    pattern = node.get('pattern','')
    if pattern.startswith('BLSAggregator'): return 'BLSAggregator-4.12.0'
    if pattern.startswith('^0x'):
        return '0x' + ('1'*40 if '{40}' in pattern else '1'*64 if '{64}' in pattern else '01')
    if '[0-9a-f]{40}' in pattern: return 'a'*40
    return '0'


def schema_control(line, label, gate):
    node = next(node for path, node in domains.schema_nodes() if path == label)
    def test(self):
        # Use the actual fixed schema node; unrelated parent guards cannot hide this site.
        if line == 379:
            value = None
        elif line == 384:
            sample = schema_value(node)
            if node['type'] == 'string':
                value = type('FixtureString', (str,), {})(sample)
            elif node['type'] == 'integer':
                value = float(sample)
            elif node['type'] == 'array':
                value = tuple(sample)
            else:
                value = None
        elif line == 388:
            value = {}
        elif line == 389:
            value = schema_value(node)
        elif line == 394:
            def valid(n):
                if 'const' in n: return n['const']
                return {'object': {}, 'array': [], 'integer': 0, 'string': ''}.get(n.get('type'))
            value = {key: valid(node['properties'][key]) for key in node['required']}
            value = {'unexpected': True, **value}
        elif line == 398:
            value = []
        elif line == 403:
            value = '!'
        else:
            value = -1
        with assert_stop(self, gate):
            m._fraud_schema(value, node, label)
    return test


for row in json.loads(Path(__file__).with_name('gate_templates.json').read_text()):
    if row['file'].endswith('manifest_exec.py') and row['line'] in (343,345,347,349,379,381,384,388,389,394,398,403,405,1993,2841,2886,2897,2910,2913,2920):
        if row.get('empty_schema_acceptance'):
            continue  # DSR ruling 1: one synthetic deletion per site, with schema tripwires.
        line = row['line']
        try:
            labels = domains.labels(line)
        except KeyError:
            continue
        from test_gate_names import expanded_name
        for label in labels:
            gate = expanded_name(row['template'], label)
            if line in domains.SCHEMA_RULES:
                add(SchemaRTests, line, label, gate, schema_control(line, label, gate))
            else:
                add(SchemaRTests if line in (343,345,347,349,1993,2841) else ConstantRTests, line, label, gate, control(line, label, gate))


import test_old_owner_isolation as isolation


class OpenIsolationTests(isolation.OldOwnerIsolationTests):
    pass


for name in dir(isolation.OldOwnerIsolationTests):
    if name.startswith('test_'):
        setattr(OpenIsolationTests, name, None)


def isolation_control(gate):
    def test(self):
        _, key, value = next(row for row in self.mutations() if row[0] == gate)
        with assert_stop(self, gate):
            isolation.o.audit(isolation.fixture_rpc(self.pin, {key:value}), self.pin,
                              isolation.inventory(), isolation.FIXTURE_CALLSITE_TARGETS)
    return test


OPEN_GATES = {
    697: 'old_owner_role_member_declared_TimelockController_PROPOSER_ROLE',
    699: 'old_owner_role_admin_declared_ROLE_COMMUNITY',
    712: 'old_owner_authority_member_SuperPaymaster_pendingOwner',
    717: 'old_owner_mapping_member_Registry_authorized',
    785: 'old_owner_role_member_configured_Registry_' + isolation.CUSTOM_ROLE,
    787: 'old_owner_role_admin_configured_' + isolation.CUSTOM_ROLE,
    816: 'old_owner_operator_treasury_' + isolation.u.DEPLOYER,
    845: 'old_owner_allowance_pair_' + isolation.GTOKEN + '_' + isolation.u.SAFE,
}
for line, gate in OPEN_GATES.items():
    add(OpenIsolationTests,line,gate,gate,isolation_control(gate))


def extract_control(line, gate):
    def test(self):
        import tempfile
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as directory:
            tree=Path(directory); artifacts=isolation.fixture_ast(tree)
            path=tree/'out/build-info/test.json'; data=json.loads(path.read_text())
            root=data['output']['sources']['contracts/src/TimelockController.sol']['ast']['nodes'][0]
            if line==491:
                next(n for n in root['nodes'] if n['name']=='PROPOSER_ROLE')['value']={'nodeType':'Identifier','name':'unsupported'}
            elif line==493:
                artifacts['GToken']['abi']=[n for n in artifacts['GToken']['abi'] if n.get('name')!='owner']
            elif line==494:
                next(n for n in artifacts['GToken']['abi'] if n.get('name')=='owner')['outputs']=[{'type':'uint256'}]
            elif line==530:
                root['nodes']=[n for n in root['nodes'] if not n.get('name','').endswith('ROLE')]
            else:
                duplicate=copy.deepcopy(data)
                source=duplicate['output']['sources']['contracts/src/GToken.sol']['ast']['nodes'][0]
                source['nodes']=[n for n in source['nodes'] if n.get('name')!='owner']
                (path.parent/'zduplicate.json').write_text(json.dumps(duplicate))
            path.write_text(json.dumps(data))
            with patch.object(isolation.a,'raw_artifact',side_effect=lambda t,n:artifacts[n]):
                with assert_stop(self,gate):
                    isolation.o.extract(tree)
    return test


for line,gate in ((491,'old_owner_role_expression_PROPOSER_ROLE'),(493,'old_owner_getter_abi_GToken_owner'),
                  (494,'old_owner_getter_output_owner')):
    OPEN_GATES[line]=gate
    add(OpenIsolationTests,line,gate,gate,extract_control(line,gate))


def pending_slash(self):
    from unittest.mock import patch
    who=self.plan['pin']['pauseList'][0]
    gate='B2_pending_slash_'+who
    def word(rpc,target,signature,*args,**kwargs):
        return 1 if signature=='isSlashPending(address)' and args[0]==who else m.BUFFER
    with patch.object(m,'balances',return_value=dict(totalTrackedBalance=m.BUFFER,protocolRevenue=m.BUFFER,operatorBalances={})),patch.object(m.a,'word',side_effect=word):
        with assert_stop(self,gate):
            m.b2_gate(lambda *args: self.fail(gate+': unexpected fake RPC request'),self.plan,'0x1')


# fixture pin.pauseList is sorted; HOLDER is the first address.
OPEN_GATES[2691]='B2_pending_slash_'+fixture.base.HOLDER
add(ConstantRTests,2691,OPEN_GATES[2691],OPEN_GATES[2691],pending_slash)


def fork_control(self):
    role=isolation.inventory()['TimelockController']['roles'][0]['value']
    case=dict(sender=isolation.u.TL,gate='old_owner_event_role_member_TimelockController',
              transactions=[dict(target=isolation.u.TL,signature='grantRole(bytes32,address)',args=[role,'$ACCOUNT'])],
              getter=dict(target=isolation.u.TL,signature='hasRole(bytes32,address)',args=[role,'$ACCOUNT']))
    gate='old_owner_fork_case_'+case['gate']
    try:
        result=isolation.o.fork_probe(isolation.fixture_fork(self.pin),self.pin,case)
    except isolation.a.Gate as fault:
        self.fail(gate+': '+str(fault))
    self.assertEqual(result['status'],'verified',gate)


OPEN_GATES[1510]='old_owner_fork_case_old_owner_event_role_member_TimelockController'
add(OpenIsolationTests,1510,OPEN_GATES[1510],OPEN_GATES[1510],fork_control)

if __name__ == '__main__':
    unittest.main()
