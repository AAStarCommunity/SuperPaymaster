"""Malformed fields supplied before production entry, preserving all earlier checks."""
import copy
import tempfile
from pathlib import Path
import unittest
import sp_upgrade_exec as u
import old_owner_isolation as o
import manifest_exec as m
import test_sp_upgrade_exec as base
import test_gate_template_controls as templates
from gate_assertions import assert_stop

a = u.a
BAD_HASH = '0X' + '00' * 32
CBOR = 'a164736f6c6343000821000a'
CASES = {}
ACTIONS = {}
SHADOWS = {'rpc_result_validate_external_who': 'sampled_deployer_only'}


class FieldTests(unittest.TestCase):
    pass


class ExternalFieldTests(templates.ManifestTemplateTests):
    pass


def register(cls, gate, action):
    def test(self):
        with assert_stop(self, gate):
            action(self)
    method = 'test_' + gate
    setattr(cls, method, test)
    CASES[gate] = 'test_gate_typed_fields.' + cls.__name__ + '.' + method
    ACTIONS[gate] = (cls, action)


def artifact_sources(self):
    with tempfile.TemporaryDirectory(prefix='typed-source-') as directory:
        root = Path(directory)
        (root / 'fixture.sol').write_text('contract Fixture {}')
        digest = a.keccak('0x' + (root / 'fixture.sol').read_bytes().hex())
        metadata = dict(sources={'fixture.sol': dict(keccak256='0X' + digest[2:])}, settings={})
        a.artifact_sources(metadata, source_root=root)


register(FieldTests, 'rpc_result_artifact_sources_keccak256', artifact_sources)
register(FieldTests, 'rpc_result_verifier_executable_code', lambda self: m.verifier_executable(
    '0X' + templates.manifest.VERIFIER_CODE[2:]))
for key in ('artifactRuntime', 'code'):
    def runtime(self, key=key):
        identity = dict(artifactRuntime='0x6000', ranges=[])
        code = '0x6000'
        if key == 'artifactRuntime': identity[key] = '0X6000'
        else: code = '0X6000'
        a.verify_runtime(None, {}, code, contract_name='TimelockController', identity=identity, values={})
    register(FieldTests, 'rpc_result_verify_runtime_' + key, runtime)

for key in ('code', 'object'):
    def parity(self, key=key):
        code = '0x6000' + CBOR
        artifact = dict(deployedBytecode=dict(object=code, immutableReferences={}))
        if key == 'code': code = '0X' + code[2:]
        else: artifact['deployedBytecode']['object'] = '0X' + code[2:]
        o.runtime_parity(code, artifact, expectations={})
    register(FieldTests, 'rpc_result_runtime_parity_' + key, parity)


def a3a_pin(self):
    pin = dict(block='0x1', blockHash=BAD_HASH, timestamp=a.ACTIVATION, deployerNonce=0,
               safeNonce=0, owners=[], timelock=a.ZERO, capped=a.ZERO, balance=0,
               senders={k:dict(address=v, nonce=0, balance=0) for k,v in a.SENDERS.items()},
               sp=dict(owner=a.ZERO, APNTS_TOKEN=a.ZERO, pendingAPNTsToken=a.ZERO,
                       pendingAPNTsTokenEta=0, APNTS_TOKEN_TIMELOCK=0))
    a.validate_pin(pin)


register(FieldTests, 'rpc_result_validate_pin_blockHash', a3a_pin)
register(FieldTests, 'rpc_result_validate_gaps_hash', lambda self: a.validate_gaps(dict(
    pin=dict(senders=dict(deployer=dict(nonce=0))),
    nonceGaps=[{'from':a.DEPLOYER, 'nonce':'0x0', 'hash':BAD_HASH}])))
register(FieldTests, 'rpc_result_admission_gas_data', lambda self: u.admission_gas(dict(data='0X00', to=a.ZERO)))
register(FieldTests, 'rpc_result_assert_manifest_calldata_data', lambda self: o.assert_manifest_calldata(
    [dict(tx=dict(to=a.ZERO, data='0X'))], []))


def evidence_hash(self):
    contracts = {name:dict(fullCreationKeccak=a.ZERO32, strippedCreationKeccak=a.ZERO32)
                 for name in (*m.NAMES, 'OverIssueFraudProofVerifier')}
    contracts[m.NAMES[0]]['fullCreationKeccak'] = BAD_HASH
    m.validate_evidence_details(dict(contracts=contracts), 'reproducible-build')


register(FieldTests, 'rpc_result_validate_evidence_details_value', evidence_hash)


def gas_witness(self):
    limit = u.margin_limit(20000000, 100000, 18000000)
    step = dict(tx=dict(to=None, gas=hex(limit)), minedGasMinimum=20000000,
                estimateGas=100000, localEstimateGas=100000, forkGasUsed=18000000,
                executionTimestamp=1, rrRequired=True,
                rrWitness=dict(engineCommit=a.COMMIT, transactionHash=BAD_HASH, gasLimit=limit,
                               stepIndex=0, pc=0, depth=1, gas=a.GAS_CAP-100000,
                               stateGasReservoir=limit-a.GAS_CAP))
    u.validate_gas(step)


register(FieldTests, 'rpc_result_validate_gas_transactionHash', gas_witness)

for index in (1, 2, 3):
    def roles(self, index=index):
        topics = [a.keccak('RoleAdminChanged(bytes32,bytes32,bytes32)'), a.ZERO32, a.ZERO32, a.ZERO32]
        topics[index] = BAD_HASH
        log = dict(address=a.ZERO, topics=topics, blockNumber='0x1', transactionIndex='0x0', logIndex='0x0')
        def rpc(method, params):
            if method == 'eth_getCode': return '0x'
            if method == 'eth_getLogs': return [log]
            self.assertEqual(method, 'eth_call')
            return a.ZERO32
        a.roles_readback(rpc, dict(pin=dict(timelock=a.ZERO), roles={
            role:[] for role in ('DEFAULT_ADMIN', 'PROPOSER', 'EXECUTOR', 'CANCELLER')}), '0x1')
    register(FieldTests, 'rpc_result_roles_readback_' + str(index), roles)

for field in ('blockHash', 'transactionHash'):
    def scan(self, field=field):
        log = base.event(a.ZERO32, base.HOLDER, block=1)
        log[field] = BAD_HASH
        u.scan(lambda method, params: [log], u.REG, 1, '0x1', [a.ZERO32])
    register(FieldTests, 'rpc_result_scan_' + field, scan)

for index in (1, 2):
    def inventory(self, index=index):
        rpc = base.InventoryRPC()
        target = u.SP if index == 1 else u.REG
        value = rpc.logs[target][0]['topics'][index]
        rpc.logs[target][0]['topics'][index] = '0X' + value[2:]
        u.inventory(rpc, '0x100', 1, 1)
    register(FieldTests, 'rpc_result_inventory_' + str(index), inventory)


def pending(self):
    topic = a.keccak('Cancelled(bytes32)')
    log = base.event(topic, base.HOLDER, block=1, target=u.TL)
    log['topics'] = [topic, BAD_HASH]
    u.pending_operations(lambda method, params: [log], 1, '0x1')


register(FieldTests, 'rpc_result_pending_operations_1', pending)
for suffix in ('field', 'who', 'who_2', 'who_3'):
    def pin(self, suffix=suffix):
        value = base.pin()
        if suffix == 'field': value['blockHash'] = BAD_HASH
        elif suffix == 'who':
            old = next(who for who in value['safe']['owners'] if who not in (a.APPROVER, a.EXECUTOR))
            bad = '0X' + old[2:]
            value['safe']['owners'] = sorted(bad if who == old else who for who in value['safe']['owners'])
            value['safe']['codes'][bad] = value['safe']['codes'].pop(old)
        elif suffix == 'who_2':
            value['holders'][0] = '0X' + value['holders'][0][2:]
            value['pauseList'] = sorted(set(value['holders']) | set(value['historicalOperators']))
        else: value['immutables']['entryPoint'] = '0X' + value['immutables']['entryPoint'][2:]
        u.validate_pin(value)
    register(FieldTests, 'rpc_result_validate_pin_' + suffix, pin)

for field in ('sid', 'validator', 'calldata', 'who'):
    def external(self, field=field):
        data = copy.deepcopy(self.inputs['data'])
        if field == 'sid': data['a3aPlan']['receipts'][a.STEP_IDS[0]] = BAD_HASH
        elif field in ('validator', 'calldata'):
            data['pop'][0][field] = '0X' + data['pop'][0][field][2:]
        else: data['sampled'][0] = '0X' + data['sampled'][0][2:]
        m.validate_external(data)
    register(ExternalFieldTests, 'rpc_result_validate_external_' + field, external)

for field in ('value', 'code'):
    def build(self, field=field):
        inputs, pin = copy.deepcopy(self.inputs), copy.deepcopy(self.pin)
        if field == 'value': inputs['sha256'] = inputs['sha256'][:-1]
        else:
            key = next(iter(pin['bindings']))
            pin['bindings'][key] = '0X' + pin['bindings'][key][2:]
        m.build_plan(pin, inputs)
    register(ExternalFieldTests, 'rpc_result_build_plan_' + field, build)


for gate, earlier in SHADOWS.items():
    cls, action = ACTIONS[gate]
    def shadow(self, action=action, earlier=earlier):
        with assert_stop(self, earlier):
            action(self)
    setattr(cls, 'test_shadow_' + gate, shadow)


def load_tests(loader, tests, pattern):
    # Shadowed target expectations are explicit red probes, not passing suite cases.
    names = [name for gate, name in CASES.items() if gate not in SHADOWS]
    names += ['test_gate_typed_fields.' + ACTIONS[gate][0].__name__ + '.test_shadow_' + gate for gate in SHADOWS]
    return unittest.TestSuite(loader.loadTestsFromName(name) for name in names)


if __name__ == '__main__':
    unittest.main()
