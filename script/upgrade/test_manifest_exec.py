#!/usr/bin/env python3
"""Offline manifest tests; only cast ABI encoding/keccak use a subprocess."""
import sys
sys.dont_write_bytecode = True
import copy
from collections import UserDict
from gate_assertions import assert_stop
import contextlib
from types import SimpleNamespace
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import manifest_exec as m
import test_sp_upgrade_exec as base
import test_old_owner_isolation as isolation_tests
from test_old_owner_isolation import OldOwnerIsolationTests

a, u = m.a, m.u
REAL_FUNDING_GATE = m.funding_gate
REAL_RELEASE_GATE = m.release_gate
REAL_A3A_VALIDATE_PLAN = a.validate_plan
ANNI = m.ANNI
DVT = m.DVT
SAMPLE = json.loads(Path(__file__).with_name('fixtures').joinpath('dvt-fraud-drill-sample-4.11.json').read_text())
VERIFIER_CODE = json.loads(Path(__file__).with_name('fixtures').joinpath('dvt-creation.json').read_text())['creationBytecode']
COMMITTEE = m.COMMITTEE
OLD = m.OLD_AGGREGATOR
ART = dict(scope=dict(contracts=list(m.NAMES), files=['contracts/src/SuperPaymaster.sol']), commit='a'*40, aggregatorVersion=m.AGG_VERSION, forgeVersion='forge Version: 1.7.1', contracts={name: dict(
    bytecode='0x60006000f3a00001', runtimeIdentity=dict(artifactRuntime='0x6000', ranges=[]),
    storageLayout={}, metadata={}) for name in m.NAMES})

ART['oldOwnerInventory'] = copy.deepcopy(isolation_tests.inventory())
for release_name, deployed_name in (('xPNTsFactoryV2', 'xPNTsFactory'), ('xPNTsTokenV2', 'xPNTsToken'), ('xPNTsTokenV2Ext', 'xPNTsToken')):
    ART['oldOwnerInventory'][release_name] = copy.deepcopy(ART['oldOwnerInventory'][deployed_name])
import ast
import re
ART['calldataSignatures'] = sorted({n.value for module in (m,u) for n in ast.walk(ast.parse(Path(module.__file__).read_text()))
    if isinstance(n,ast.Constant) and isinstance(n.value,str) and re.fullmatch(r'[A-Za-z][A-Za-z0-9_]*\([a-zA-Z0-9_,()\[\]]*\)',n.value)} |
    {verb+suffix for verb in ('schedule','execute') for suffix in
     ['(address,uint256,bytes,bytes32,bytes32'+(',uint256)' if verb == 'schedule' else ')'),
      'Batch(address[],uint256[],bytes[],bytes32,bytes32'+(',uint256)' if verb == 'schedule' else ')')]})

ART['calldataSignatures'] += ['setBLSAggregator(address)','setBlsAggregator(address)','setMinThreshold(uint256)','setDefaultThreshold(uint256)','configureRole(bytes32,'+u.CONFIG_TYPE+')']

for art in ART['contracts'].values(): art['creationHashes'] = m.creation_hashes(art['bytecode'])

ART['contracts']['BLSAggregator']['storageLayout'] = dict(storage=[dict(label='proposalSignersCommitment', slot='29', offset=0, type='map')],
    types={'map':dict(encoding='mapping', key='uint', value='bytes'), 'uint':dict(label='uint256'), 'bytes':dict(label='bytes32')})



PC_OWNER, PC_BUNDLER, PC_SIGNER = '0x'+'a1'*20, '0x'+'b1'*20, '0x'+'c1'*20
PC_ACCOUNT, PC_IMPL = '0x'+'d1'*20, '0x'+'e1'*20
PC_STAKING, PC_GTOKEN, PC_MYSBT = '0x'+'71'*20, '0x'+'72'*20, '0x'+'73'*20
PC_RUNTIMES = {k: '0x'+format(i+1, '064x') for i, k in enumerate(m.PC_RUNTIMES)}
BASELINES = {
    'F1TestToken': dict(bytecode='0x60006000f3a00002', runtimeIdentity=dict(artifactRuntime='0x'+'00'*32+'60',
        ranges=[dict(name='MINTER', start=0, length=32)]), source=m.F1_SOURCE, commit=ART['commit']),
    'F1Oracle': dict(bytecode='0x60006000f3a00003', runtimeIdentity=dict(artifactRuntime='0x6001', ranges=[]),
        source=m.F1_SOURCE, commit=ART['commit']),
    'VerifyingPaymaster': dict(bytecode='0x60006000f3a00004', artifact=m.BASELINE_ARTIFACTS['VerifyingPaymaster'],
        artifactSha256='f1'*32, source='samples/VerifyingPaymaster.sol', sourceSha256='f2'*32, commit=ART['commit'],
        constructor=m.VPM_CONSTRUCTOR),
    'TokenPaymaster': dict(bytecode='0x60006000f3a00005', artifact=m.BASELINE_ARTIFACTS['TokenPaymaster'],
        artifactSha256='f3'*32, source='samples/TokenPaymaster.sol', sourceSha256='f4'*32, commit=ART['commit'],
        constructor=m.TPM_CONSTRUCTOR)}
for _name, _label in (('SuperPaymaster', 'cachedPrice'), ('xPNTsTokenV2', '_auto'), ('xPNTsTokenV2', '_budget')):
    ART['contracts'][_name]['storageLayout'].setdefault('storage', []).append(
        dict(label=_label, slot=str(40+len(ART['contracts'][_name]['storageLayout']['storage'])), offset=0, type='t'))


def phase_c_pin(p):
    return dict(owner=dict(address=PC_OWNER, nonce=0, balance=0, code='0x'),
        bundler=dict(address=PC_BUNDLER, nonce=0, balance=10**17, code='0x'),
        verifyingSigner=dict(address=PC_SIGNER, nonce=0, balance=0, code='0x'),
        capped=dict(cap=10**27, totalSupply=0, minter=u.SAFE, deployerBalance=10**18),
        sp=dict(aPNTsPriceUSD=2*10**16, protocolFeeBPS=1000, cachedPrice=[3000*10**8, p['timestamp'], 1, 8],
                deployerOperator=[169001*10**16, 1, 0, int('0x'+'5a'*20, 16), 100, 0, int(u.DEPLOYER, 16), 7, 3]),
        roles=dict(COMMUNITY=1, PAYMASTER_SUPER=1),
        endUser=dict(roleConfig=base.cfg(), staking=PC_STAKING, gtoken=PC_GTOKEN, mysbt=PC_MYSBT, deployerGToken=1000*10**18),
        account=dict(factoryCodeHash=PC_RUNTIMES['accountFactory'], implementation=PC_IMPL,
            implementationCodeHash=PC_RUNTIMES['accountImplementation'], implementationEntryPoint=p['immutables']['entryPoint'],
            counterfactual=PC_ACCOUNT, codeHash=a.EMPTY_KECCAK, status=[0, 0, 0]))


def phase_c_inputs(file_ref):
    arm = dict(call=60000, verification=80000, paymasterVerification=120000, postOp=40000, preVerification=50000, outer=300000)
    return dict(bundler=PC_BUNDLER, accountOwner=PC_OWNER, verifyingSigner=PC_SIGNER, account=PC_ACCOUNT, salt=7,
        accountImplementation=PC_IMPL, runtimeKeccak=dict(PC_RUNTIMES),
        accountEvidence=file_ref('account-evidence', {'synthetic': True}),
        rehearsal=dict(evidence=file_ref('rehearsal-evidence', {'synthetic': True}),
            arms=dict(SP={k: v for k, v in arm.items() if k != 'postOp'}, VPM=dict(arm, postOp=0), TPM=dict(arm)),
            ownerPreparation={k: 100000 for k in m.OWNER_PREPARATION},
            ownerMaintenance=[dict(name='tpm-refresh-1', gas=50000)], bundlerMaintenance=[dict(name='withdraw', gas=40000)]))


def gas_evidence(plan, step):
    index = next(i for i, item in enumerate(plan['steps']) if item['id'] == step['id'])
    return dict(estimateContext=dict(block=plan['pin']['block'],
        stateOverrides={a.APPROVER: {'nonce': '0x1'}} if index else {},
        blockOverrides={'time': hex(step['executionTimestamp'])}),
        priorSteps=[item['id'] for item in plan['steps'][:index]], blockGasLimit=200_000_000)


def freeze_gas(plan, step):
    step.update(estimateGas=100000, localEstimateGas=100000, forkGasUsed=90000,
        skipped=False, rrRequired=False, rrWitness=None,
        minedGasMinimum=80000 if step['tx']['to'] is None else None)
    step['tx']['gas'] = hex(130000)
    step['gasEvidence'] = gas_evidence(plan, step)
    if 'variants' in step:
        step['variants']['apply'] = dict(step['tx'])
        step['variants']['placeholder']['gas'] = hex(130000)
        step['variantMeasurements'] = {'placeholder': {key: copy.deepcopy(step[key])
            for key in u.MEASURED_KEYS | {'gasEvidence'}}}

def fraud_data(p, agg):
    guardians = sorted(x['validator'] for x in p['guardianInventory'] if x['validator'] != a.ZERO)
    pid, mask, token = 2**200+123, 7, '0x'+'ab'*20
    proof = a.cast('abi-encode', 'c(uint256,address,uint8,uint256,address,uint256,address[])',
                   pid, u.DEPLOYER, 1, 42, token, mask, '['+','.join(guardians)+']')
    f = dict(toolCommit='b'*40, verifierCommit=m.VERIFIER_COMMIT, aggregator=agg,
        verifier=a.create_address(u.DEPLOYER, p['senders']['deployer']['nonce']+23), registry=u.REG,
        domainSeparator=m.domain_separator(agg), block=a.qty(p['block']), pid=pid, fraudProofId=1,
        guiltyGuardians=guardians, fraudProof=proof, signerMask=mask, messageHash=m.fraud_message_hash(m.domain_separator(agg), pid, u.DEPLOYER, 1, 42, token),
        mockToken=dict(address=token, runtime=SAMPLE['forkState']['token']['runtimeBytecode'], runtimeHash=m.MOCK_TOKEN_RUNTIME_HASH, over=False))
    f['commitment'] = dict(slot=m.commitment_slot(ART['contracts']['BLSAggregator']['storageLayout'], pid),
        value=a.keccak(a.cast('abi-encode', 'c(bytes32,bytes32,uint256,bytes32,uint256,address[])',
        f['domainSeparator'], a.keccak('SuperPaymaster.BLS.SignersCommitment.v1'), pid,
        f['messageHash'], mask, '['+','.join(guardians)+']')))
    digest = a.keccak(a.cast('abi-encode', 'c(bytes32,bytes32,uint256,address[])', f['domainSeparator'],
        a.keccak('SuperPaymaster.BLS.FraudProof.v1'), 1, '['+','.join(guardians)+']'))
    changed = proof[:2+5*64]+format(mask^1,'064x')+proof[2+6*64:]
    f['invalid'] = dict(N1=dict(guiltyGuardians=guardians[:-1]), N2=dict(over=True),
        N3=dict(fraudProof=changed), N4=dict(domainDigest='0x'+format(int(digest,16)^1,'064x')))
    return f


def fraud_export(f):
    """Serialize synthetic drill state in the actual DVT wire format."""
    e = copy.deepcopy(SAMPLE)
    for key in ('aggregator', 'verifier', 'registry', 'domainSeparator', 'block'):
        e[key] = f[key]
    e['version'] = m.AGG_VERSION
    e['forkState']['token'].update(address=f['mockToken']['address'], runtimeBytecode=f['mockToken']['runtime'])
    e['forkState']['commitment'].update(key=str(f['pid']), value=f['commitment']['value'])
    words = u.uints(f['fraudProof'])
    e['valid'].update(proposalId=str(f['pid']), fraudProofId=str(f['fraudProofId']),
        guiltyGuardians=f['guiltyGuardians'], fraudProof=f['fraudProof'], signerMask=hex(f['signerMask']),
        operator=u.addr_word(words[1]), slashLevel=words[2], epoch=str(words[3]),
        domainDigest='0x'+format(int(f['invalid']['N4']['domainDigest'],16)^1,'064x'))
    for n in e['mustReject']:
        n.update(guiltyGuardians=f['guiltyGuardians'], fraudProof=f['fraudProof'])
    e['mustReject'][0].update(f['invalid']['N1'])
    e['mustReject'][2].update(f['invalid']['N3'])
    e['mustReject'][3].update(f['invalid']['N4'])
    return dict(toolCommit=f['toolCommit'], verifierCommit=f['verifierCommit'], export=e)


def old_exit_rpc(p, guardian=None, expires=1789019460, occupied=0, slash=0, maximum=13):
    def rpc(method, params):
        if method == 'eth_getCode': return '0x' if a.qty(params[1]) == 0 else '0x6000'
        if method == 'eth_getBlockByNumber':
            return dict(number=p['stateBlock'], hash=p['stateBlockHash'], timestamp=hex(p['stateTimestamp']))
        if method == 'eth_getLogs':
            if guardian is None: return []
            return [dict(address=OLD, topics=[a.keccak('GuardianExitRequested(address,uint256,uint256)'),
                '0x'+guardian[2:].zfill(64)], data='0x', blockNumber='0x1', blockHash='0x'+'ab'*32,
                transactionHash='0x'+'cd'*32, transactionIndex='0x0', logIndex='0x0')]
        if method == 'eth_call':
            data = params[0]['data']
            calls = [('guardianExitRequests(address)', (guardian,), [1788933060, expires]),
                     ('MAX_VALIDATORS()', (), [maximum]),
                     ('pendingGuardianSlashCount(address)', (guardian,), [slash])]
            calls += [('validatorAtSlot(uint8)', (i,), [int(guardian,16) if i == occupied else 0]) for i in range(1,14)]
            for sig, args, values in calls:
                if data == a.calldata(sig, *args):
                    return '0x'+''.join(format(v, '064x') for v in values)
        raise AssertionError((method, params))
    return rpc


def set_old_exit_evidence(p, guardian=None, **kw):
    activity, reads = m.record_old_activity(old_exit_rpc(p, guardian, **kw), OLD, p['stateBlock'], [])
    p['oldActivity'] = activity
    p['oldActivityReads'] = dict(primary=reads, secondary=copy.deepcopy(reads))
    return p


def pin():
    p = base.pin()
    p['senders']['anni'] = dict(address=ANNI, nonce=55, balance=100*10**18)
    p['pauseList'] = sorted([u.DEPLOYER, ANNI, base.HOLDER])
    p['historicalOperators'] = list(p['pauseList'])
    p.update(oldAggregator=OLD, oldActivity={}, bindings={DVT:'0x6000', COMMITTEE:'0x63f2fde38b00'},
        stake=10**17, stakeDelay=86400, withdrawTime=0, entryPointDeposit=10**17,
        totalTrackedBalance=293414*10**16, protocolRevenue=39959*10**16,
        operatorBalances={u.DEPLOYER:169001*10**16, ANNI:84454*10**16, base.HOLDER:0})
    p['guardianInventory'] = [dict(slot=i, validator=('0x'+format(i, '040x')) if i <= 3 else a.ZERO) for i in range(1, 14)]
    p['pendingAPNTsTokenEta'] = 1794226596
    p['oldOwnerIsolation'] = isolation_tests.evidence(p)
    p['oldTimelock'] = m.old_timelock_holds_nothing(old_timelock_rpc(p, p['stateBlock']), p, p['stateBlock'])
    set_old_exit_evidence(p)
    p['phaseC'] = phase_c_pin(p)
    return p


def input_data(p):
    # Synthetic bytecode and invalid-on-chain PoPs are deliberately only unit fixtures.
    agg = a.create_address(u.DEPLOYER, p['senders']['deployer']['nonce']+12)
    pops = []
    for i in range(3):
        validator = '0x'+format(i+1, '040x')
        pk = '('+','.join([a.ZERO32]*4)+')'
        sig = '('+','.join([a.ZERO32]*8)+')'
        pops.append(dict(validator=validator, slot=i+1, aggregator=agg, domainSeparator=m.domain_separator(agg), pinBlockHash=p['blockHash'],
                         calldata=a.calldata(m.POP, validator, pk, i+1, sig)))
    return dict(anni=ANNI, dvt=DVT, committee=COMMITTEE, sampled=[u.DEPLOYER],
        depositTargetWei=10**18, releaseTag='unit-fixture', registryBaselineCommit='b'*40,
        releaseEvidence={key:'c'*64 for key in m.EVIDENCE_KINDS},
        verifier=dict(commit=m.VERIFIER_COMMIT, artifactPath='unit-fixture', ciSha256='e'*64, buildSha256=m.VERIFIER_SHA256,
                      artifact=dict(bytecode=VERIFIER_CODE, runtimeIdentity=dict(artifactRuntime='0x6000', ranges=[]))), pop=pops)


def orphan_replies(pin):
    # The orphaned-timelock reads (roles, authorities, Safe, allowances) answered as "holds nothing".
    o = m.isolation
    raw = isolation_tests.raw
    replies = {}
    discovery = isolation_tests.fixture_rpc(copy.deepcopy(pin))
    for target, sig in ((u.REG, 'GTOKEN_STAKING()'), (u.REG, 'MYSBT()'), (u.SP, 'xpntsFactory()'),
                        (isolation_tests.STAKING, 'GTOKEN()'), (isolation_tests.FACTORY, 'getAllTokens()')):
        replies[(target, a.calldata(sig))] = a.call(discovery, target, sig, block=pin['stateBlock'])
    for who in pin['pauseList']:
        replies[(u.SP, a.calldata('operators(address)', who))] = raw([0]*9)
    for target, sig, args, kind in o.authority_rows(pin['oldOwnerIsolation']):
        if kind == 'config':
            values = [32]+[0]*13
            values[10], values[11] = 384, int(u.DEPLOYER, 16)
        else:
            values = [int(u.DEPLOYER, 16) if kind == 'address' else 0]
        replies.setdefault((target, a.calldata(sig, *args)), raw(values))
    for role in [a.ZERO32, *(a.keccak(r+'_ROLE') for r in ('PROPOSER', 'EXECUTOR', 'CANCELLER'))]:
        replies[(u.TL, a.calldata('hasRole(bytes32,address)', role, o.OLD_TIMELOCK))] = raw([0])
    replies[(u.SAFE, a.calldata('getOwners()'))] = raw([32, 2, int(a.APPROVER, 16), int(a.EXECUTOR, 16)])
    replies[(u.SAFE, a.calldata('isModuleEnabled(address)', o.OLD_TIMELOCK))] = raw([0])
    for token in pin['oldOwnerIsolation']['tokens']:
        for holder in o.allowance_holders():
            replies[(token, a.calldata('allowance(address,address)', holder, o.OLD_TIMELOCK))] = raw([0])
    for (target, data), value in list(replies.items()):
        if o.OLD_TIMELOCK[2:] in data:
            replies[(target, data.replace(o.OLD_TIMELOCK[2:], o.OLD[2:]))] = value
    return replies


def with_orphan_reads(rpc, pin, block):
    # pre_send re-checks the orphaned timelock before every send; fixtures for other pre_send gates answer
    # exactly those reads at `block` and pass every other request to their own strict handler.
    replies = orphan_replies(pin)
    def wrapped(method, params):
        if method == 'eth_getLogs' and a.qty(params[0]['fromBlock']) > a.qty(pin['stateBlock']) and (
                isinstance(params[0]['topics'][0], list) or params[0]['topics'][0] in (a.keccak('Approval(address,address,uint256)'), a.keccak(m.isolation.ROLE_EVENT))):
            return []
        if method == 'eth_call' and (params[0]['to'], params[0]['data']) in replies and params[1] == block:
            return replies[(params[0]['to'], params[0]['data'])]
        return rpc(method, params)
    wrapped.local = getattr(rpc, 'local', False)
    return wrapped


def old_timelock_rpc(pin, block, bad=None):
    replies = orphan_replies(pin)
    discovery = isolation_tests.fixture_rpc(copy.deepcopy(dict(pin, stateBlock=block)))
    history = isolation_tests.fixture_rpc(copy.deepcopy(pin))
    if bad:
        target, sig, args, value = bad
        replies[(target, a.calldata(sig, *args))] = value
    def rpc(method, params):
        if method == 'eth_getLogs' and params[0]['topics'][0] == a.keccak('Approval(address,address,uint256)'):
            return []
        if method == 'eth_getLogs': return history(method, params)
        if method == 'eth_call' and (params[0]['to'], params[0]['data']) in replies:
            assert params[1] == block
            return replies[(params[0]['to'], params[0]['data'])]
        return discovery(method, params)
    return rpc


class DeltaTests(unittest.TestCase):
    def setUp(self):
        self.pin = pin()
        self.block = hex(a.qty(self.pin['stateBlock'])+1)
        self.role = a.keccak('POST_PIN_ROLE')
        self.holder = '0x'+'ac'*20
        self.token = self.pin['oldOwnerIsolation']['tokens'][0]

    def rpc(self, fault=None, kind='approval'):
        o = m.isolation
        topic = a.keccak('Approval(address,address,uint256)' if kind == 'approval' else o.ROLE_EVENT if kind == 'config' else o.REGISTERED if kind == 'registered' else o.GRANTED)
        target = self.token if kind == 'approval' else u.REG
        topics = [topic, '0x'+self.holder[2:].zfill(64), '0x'+o.OLD_TIMELOCK[2:].zfill(64)] if kind == 'approval' else [topic, self.role]
        if kind in ('grant', 'registered'):
            topics += ['0x'+(o.OLD if fault == 'old_role' else u.SAFE)[2:].zfill(64)] + (['0x'+u.SAFE[2:].zfill(64)] if kind == 'grant' else [])
        event = dict(address=target, removed=False, topics=topics, blockNumber=self.block,
                     blockHash=self.pin['stateBlockHash'], data=isolation_tests.raw([0, 123]))
        if fault == 'address': event['address'] = u.SP
        if fault == 'removed': event['removed'] = True
        if fault == 'topics': event['topics'] = topics+[a.ZERO32]
        if fault == 'range': event['blockNumber'] = self.pin['stateBlock']
        if fault == 'canonical': event['blockHash'] = a.ZERO32
        baseline = old_timelock_rpc(self.pin, self.block)
        def rpc(method, params):
            if method == 'eth_getLogs':
                query = params[0]
                ts = query['topics'][0]
                return [event] if query['address'] == target and (topic in ts if isinstance(ts, list) else topic == ts) else []
            if method == 'eth_getBlockByNumber':
                return dict(number='0x0' if fault == 'number' else self.block, hash=self.pin['stateBlockHash'], timestamp='0x123', gasLimit='0xbebc200')
            if method == 'eth_chainId': return '0x0'
            if method == 'eth_call':
                self.assertEqual(params[1], self.block)
                to, data = params[0]['to'], params[0]['data']
                if data == a.calldata('allowance(address,address)', self.holder, o.OLD_TIMELOCK):
                    return isolation_tests.raw([int(fault == 'allowance')])
                if to == u.REG and data == a.calldata('getRoleConfig(bytes32)', self.role):
                    values = [32]+[0]*13
                    values[10], values[11] = 384, int(o.OLD_TIMELOCK if fault == 'config_owner' else u.SAFE, 16)
                    return isolation_tests.raw(values)
                for who, gate in ((o.OLD, 'old_role'), (o.OLD_TIMELOCK, 'timelock_role')):
                    if data == a.calldata('hasRole(bytes32,address)', self.role, who):
                        return isolation_tests.raw([int(fault == gate)])
                if fault == 'xpnts' and data == a.calldata('getAllTokens()'):
                    tokens = sorted(set(self.pin['oldOwnerIsolation']['xpnts']) | {self.holder})
                    return isolation_tests.raw([32, len(tokens), *[int(t,16) for t in tokens]])
                if fault == 'targets' and data == a.calldata('MYSBT()'):
                    return isolation_tests.raw([int(self.holder,16)])
            return baseline(method, params)
        rpc.local = True
        return rpc

    def check(self, fault, kind='approval'):
        rpc = self.rpc(fault, kind)
        with assert_stop(self, 'old_timelock_delta_' + fault) as caught:
            delta = m.post_pin_delta(rpc, self.pin, self.block)
            m.old_timelock_holds_nothing(rpc, self.pin, self.block, delta['approvalOwners'])
        self.assertEqual(caught.exception.record['gate'], 'old_timelock_delta_'+fault)

    def test_pre_send_delta_call(self):
        tree = ast.parse(Path(m.__file__).read_text())
        pre = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == 'pre_send')
        self.assertEqual(sum(isinstance(n, ast.Call) and isinstance(n.func, ast.Name) and n.func.id == 'post_pin_delta' for n in ast.walk(pre)), 1, 'old_timelock_delta_allowance')
        self.assertNotIn(self.holder, m.isolation.allowance_holders())
        self.assertNotIn(self.holder, self.pin['oldTimelock']['approvalOwners'].get(self.token, []))
        with patch.object(m, 'handover_gate'), assert_stop(self, 'old_timelock_delta_allowance') as caught:
            m.pre_send(self.rpc('allowance'), dict(pin=self.pin, steps=[]), dict(tx={}), {})
        self.assertEqual(caught.exception.record['gate'], 'old_timelock_delta_allowance')

    def test_unrelated(self):
        for kind in ('approval', 'config', 'grant', 'registered'):
            rpc = self.rpc(kind=kind)
            delta = m.post_pin_delta(rpc, self.pin, self.block)
            m.old_timelock_holds_nothing(rpc, self.pin, self.block, delta['approvalOwners'])
            self.assertEqual(sum(delta['logCounts'].values()), 1)
            self.assertEqual(delta['fromBlock'], self.block)
            if kind == 'approval': self.assertIn(self.holder, delta['approvalOwners'][self.token])
            else: self.assertIn(self.role, delta['rolesChecked'][u.REG])

    def test_empty_range_discovery(self):
        self.block = self.pin['stateBlock']
        rpc = self.rpc('xpnts')
        def no_logs(method, params):
            self.assertNotEqual(method, 'eth_getLogs')
            return rpc(method, params)
        with assert_stop(self, 'old_timelock_delta_xpnts') as caught:
            m.post_pin_delta(no_logs, self.pin, self.block)
        self.assertEqual(caught.exception.record['gate'], 'old_timelock_delta_xpnts')


DELTA_CASES = dict(address='approval', removed='approval', topics='approval', range='approval',
                   canonical='approval', number='approval', allowance='approval', config_owner='config',
                   timelock_role='grant', old_role='registered', targets='approval', xpnts='approval')
for _fault, _kind in DELTA_CASES.items():
    setattr(DeltaTests, 'test_old_timelock_delta_'+_fault, lambda self, f=_fault, k=_kind: self.check(f, k))


class FakeChain:
    """Read-only state for B2/B4; unknown RPC requests always fail the test."""
    def __init__(self, plan):
        self.plan = plan
        self.balances = dict(totalTrackedBalance=m.BUFFER, protocolRevenue=m.BUFFER,
                            operatorBalances={x:0 for x in plan['pin']['pauseList']})
        self.backing = m.BUFFER
        self.pending = 0
        self.paused = 1
        self.verifier = a.ZERO
        self.unpause = False
        self.calls = []

    def __call__(self, method, params):
        self.calls.append((method, params))
        if method == 'eth_getBlockByNumber':
            return dict(number='0x200', hash=base.HASH, timestamp=hex(self.plan['pin']['timestamp']), gasLimit='0xbebc200')
        if method == 'eth_getLogs':
            topic = params[0]['topics'][0]
            log = dict(address=u.SP, blockNumber='0x150', blockHash=base.HASH,
                       transactionHash='0x'+'12'*32, transactionIndex='0x0', logIndex='0x0', removed=False)
            if topic == a.keccak('GlobalPauseSet(address,bool)'):
                return [dict(log, topics=[topic, '0x'+u.TL[2:].zfill(64)], data=a.cast('abi-encode', 'c(bool)', str(not self.unpause).lower()))]
            if topic == a.keccak('Upgraded(address)'):
                return [dict(log, topics=[topic, '0x'+self.plan['implementation'][2:].zfill(64)], data='0x')]
        if method == 'eth_call':
            data = params[0]['data']
            if data.startswith(a.keccak('hasRole(bytes32,address)')[:10]):
                return a.ZERO32
            calls = {'totalTrackedBalance()':self.balances['totalTrackedBalance'],
                     'protocolRevenue()':self.balances['protocolRevenue'], 'paused()':self.paused,
                     'fraudProofVerifier()':int(self.verifier, 16)}
            for sig, value in calls.items():
                if data == a.calldata(sig):
                    return a.cast('abi-encode', 'c(uint256)', value)
            if data == a.calldata('balanceOf(address)', u.SP):
                return a.cast('abi-encode', 'c(uint256)', self.backing)
            for who, amount in self.balances['operatorBalances'].items():
                if data == a.calldata('operators(address)', who):
                    return a.cast('abi-encode', 'c(uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256)',
                                  amount, 1, 1, 0, 0, 0, 0, 0, 0)
                if data == a.calldata('isSlashPending(address)', who):
                    return a.cast('abi-encode', 'c(uint256)', self.pending)
        raise AssertionError((method, params))


def dvt_ci_run():
    # Supplied run metadata; no network lookup. Other job names are fixture examples.
    return dict(runId=41262513958, headSha=m.VERIFIER_COMMIT, overall='failure', jobs={
        'Security Audit': 'failure', 'CI Success': 'failure',
        **{name: 'success' for name in m.DVT_SUITES}})


def dvt_accepted_failures():
    return [dict(name='Security Audit', reference='dsr-rulings.md: 2026-11-02 ruling 1 (npm)')]


class DvtCiEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.e = dict(kind='dvt-ci', subjectCommit=m.VERIFIER_COMMIT, spCommit=ART['commit'],
            aggregatorVersion=m.AGG_VERSION, tool=dict(name='CI', version='1'),
            counts=dict(passed=23, failed=0, skipped=0), result='PASS',
            suites={k:dict(passed=v, failed=0, skipped=0, result='PASS') for k,v in m.DVT_SUITES.items()},
            ciRun=dvt_ci_run(), acceptedFailures=dvt_accepted_failures())
        self.e['suites']['CC115GenuinePragueCrossRepo']['env'] = {'FOUNDRY_EVM_VERSION':'prague'}

    def validate(self, raw=None):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)/'ci.json'
            path.write_text(json.dumps(self.e) if raw is None else raw)
            return m.evidence_file(dict(path=str(path), sha256=hashlib.sha256(path.read_bytes()).hexdigest()),
                                   'dvt-ci', ART['commit'])

    def test_real_run_accepted(self):
        self.assertEqual(self.validate(), self.e)

    def test_unaccepted_job_stop(self):
        self.e['ciRun']['jobs']['Build'] = 'failure'
        with self.assertRaises(a.Gate): self.validate()

    def test_missing_ci_run_stop(self):
        del self.e['ciRun']
        with self.assertRaises(a.Gate): self.validate()

    def test_head_mismatch_stop(self):
        self.e['ciRun']['headSha'] = 'f'*40
        with self.assertRaises(a.Gate): self.validate()

    def test_extra_acceptance_schema_stop(self):
        self.e['acceptedFailures'].append(dict(name='Build', reference='unapproved'))
        with self.assertRaises(a.Gate): self.validate()

    def test_duplicate_acceptance_schema_stop(self):
        self.e['acceptedFailures'] *= 2
        with self.assertRaises(a.Gate): self.validate()

    def test_wrong_acceptance_schema_stop(self):
        for name in self.e['ciRun']['jobs']: self.e['ciRun']['jobs'][name] = 'success'
        self.e['ciRun']['overall'] = 'success'
        self.e['acceptedFailures'][0]['name'] = 'Build'
        with self.assertRaises(a.Gate): self.validate()

    def test_success_with_failure_stop(self):
        self.e['ciRun']['overall'] = 'success'
        with self.assertRaises(a.Gate): self.validate()

    def test_derived_failure_alone_stop(self):
        self.e['ciRun']['jobs']['Security Audit'] = 'success'
        with self.assertRaises(a.Gate): self.validate()

    def test_failure_without_failed_job_stop(self):
        for name in self.e['ciRun']['jobs']: self.e['ciRun']['jobs'][name] = 'success'
        with self.assertRaises(a.Gate): self.validate()

    def test_success_without_acceptances(self):
        for name in self.e['ciRun']['jobs']: self.e['ciRun']['jobs'][name] = 'success'
        self.e['ciRun']['overall'] = 'success'
        self.e['acceptedFailures'] = []
        self.assertEqual(self.validate(), self.e)

    def test_ci_schema_fields_stop(self):
        original = copy.deepcopy(self.e)
        for field, value in [('runId', True), ('headSha', 'z'*40), ('overall', 'cancelled'),
                             ('jobs', []), ('jobs', [dict(name='Build', conclusion='')])]:
            with self.subTest(field=field):
                self.e = copy.deepcopy(original)
                self.e['ciRun'][field] = value
                with self.assertRaises(a.Gate): self.validate()
        self.e = copy.deepcopy(original)
        self.e['acceptedFailures'][0]['reference'] = ' '
        with self.assertRaises(a.Gate): self.validate()

    def test_duplicate_job_names_stop(self):
        for name in ('Security Audit', 'CI Success', 'Build'):
            for first, second in (('failure', 'failure'), ('success', 'failure'), ('failure', 'success')):
                with self.subTest(name=name, first=first, second=second):
                    raw = json.dumps(self.e).replace('"jobs": {', '"jobs": {' +
                        json.dumps(name) + ': ' + json.dumps(first) + ', ' +
                        json.dumps(name) + ': ' + json.dumps(second) + ', ')
                    with self.assertRaises(a.Gate): self.validate(raw)

    def test_renamed_failed_job_stop(self):
        raw = json.dumps(self.e).replace('"jobs": {', '"jobs": {"Build": "failure", ')
        with self.assertRaises(a.Gate): self.validate(raw)
        for name in ('Security Audit', 'CI Success'):
            with self.subTest(name=name):
                with self.assertRaises(a.Gate):
                    self.validate(raw.replace('"Build"', json.dumps(name)))

    def test_exempt_conclusions_stop(self):
        for name in ('Security Audit', 'CI Success'):
            for conclusion in ('cancelled', 'timed_out', 'action_required', 'neutral',
                               'startup_failure', 'unknown', 'bogus'):
                with self.subTest(name=name, conclusion=conclusion):
                    self.e['ciRun'] = dvt_ci_run()
                    self.e['ciRun']['jobs'][name] = conclusion
                    with self.assertRaises(a.Gate): self.validate()

    def test_reference_single_line_stop(self):
        for reference in ('DSR\nruling 1', 'DSR\rruling 1', 'DSR ruling 1\n',
                          ' DSR ruling 1', 'DSR ruling 1 '):
            with self.subTest(reference=repr(reference)):
                self.e['acceptedFailures'][0]['reference'] = reference
                with self.assertRaises(a.Gate): self.validate()

    def test_failure_without_acceptance_stop(self):
        self.e['acceptedFailures'] = []
        with self.assertRaises(a.Gate): self.validate()

    def test_skipped_exempt_jobs_and_single_character_reference(self):
        self.e['ciRun']['jobs'] = {'Security Audit': 'skipped', 'CI Success': 'skipped'}
        self.e['ciRun']['overall'] = 'success'
        self.e['acceptedFailures'][0]['reference'] = 'R'
        self.assertEqual(self.validate(), self.e)

    def test_empty_job_map_stop(self):
        self.e['ciRun'].update(jobs={}, overall='success')
        with self.assertRaises(a.Gate): self.validate()

    def test_job_name_single_line_stop(self):
        for name in ('', ' ', 'Build\njob', 'Build\n'):
            with self.subTest(name=repr(name)):
                self.e['ciRun'] = dvt_ci_run()
                self.e['ciRun']['jobs'][name] = 'success'
                with self.assertRaises(a.Gate): self.validate()

    def test_exact_exemption_names_stop(self):
        for name in ('security audit', 'Security Audit ', 'ci success'):
            with self.subTest(name=name):
                self.e['ciRun'] = dvt_ci_run()
                self.e['ciRun']['jobs'][name] = 'failure'
                with self.assertRaises(a.Gate): self.validate()


class Round8Controls(unittest.TestCase):
    def dvt_rebuild(self, mutate=None):
        creation = VERIFIER_CODE
        runtime = '0x6001'
        arts = {'OverIssueFraudProofVerifier': {'bytecode': {'object':creation}},
                'MockOverIssuableToken': {'deployedBytecode': {'object':runtime}}}
        if mutate == 'creation': arts['OverIssueFraudProofVerifier']['bytecode']['object'] = '0x00' + creation[4:]
        if mutate == 'metadata':
            raw = bytearray.fromhex(creation[2:])
            raw[3260] ^= 1
            arts['OverIssueFraudProofVerifier']['bytecode']['object'] = '0x' + raw.hex()
        if mutate == 'runtime': arts['MockOverIssuableToken']['deployedBytecode']['object'] += '00'
        real_run = m.subprocess.run
        def run(args, **kw):
            if args[0] == str(a.REBUILD_FORGE):
                return SimpleNamespace(returncode=0, stdout='forge Version: 1.7.1\n')
            return real_run(args, **kw)
        m.rebuild_dvt.cache_clear()
        self.addCleanup(m.rebuild_dvt.cache_clear)
        with patch.object(m.subprocess, 'run', side_effect=run), patch.object(a, 'archive_commit'), \
             patch.object(a, 'raw_artifact', side_effect=lambda root,name:arts[name]), \
             patch.object(m, 'VERIFIER_CREATION', a.keccak(creation)), \
             patch.object(m, 'MOCK_TOKEN_RUNTIME_HASH', a.keccak(runtime)), \
             patch.dict(m.os.environ, {'MANIFEST_DVT_REPO': '/nonexistent-dvt-repo'}):
            return m.rebuild_dvt()

    def test_dvt_repo_must_be_configured(self):
        m.rebuild_dvt.cache_clear()
        self.addCleanup(m.rebuild_dvt.cache_clear)
        env = {k: v for k, v in m.os.environ.items() if k != 'MANIFEST_DVT_REPO'}
        with patch.dict(m.os.environ, env, clear=True), assert_stop(self, 'dvt_repo_configured') as caught:
            m.rebuild_dvt()
        self.assertEqual(caught.exception.record['gate'], 'dvt_repo_configured')

    def test_dvt_rebuild_metadata_change_allowed(self):
        self.dvt_rebuild('metadata')

    def test_dvt_rebuilt_creation_gate(self):
        self.dvt_rebuild()
        with assert_stop(self, 'dvt_rebuilt_creation') as caught: self.dvt_rebuild('creation')
        self.assertEqual(caught.exception.record['gate'], 'dvt_rebuilt_creation')

    def test_dvt_mock_rebuilt_runtime_gate(self):
        self.dvt_rebuild()
        with assert_stop(self, 'dvt_mock_rebuilt_runtime') as caught: self.dvt_rebuild('runtime')
        self.assertEqual(caught.exception.record['gate'], 'dvt_mock_rebuilt_runtime')

    def swap_control(self, late=False, broken_eta=False, bad_accounting=False, wrong_reason=False, old_impl=False):
        p = pin()
        token, old = '0x'+'34'*20, '0x'+'56'*20
        now = p['pendingAPNTsTokenEta'] + (m.DAY if late else -m.DAY)
        replacement = '0x'+'78'*20
        state = dict(time=now, eta=p['pendingAPNTsTokenEta'], pending=token, token=old, nonce=10,
                     implementation=p['implementation'] if old_impl else replacement)
        original = copy.deepcopy(state)
        snapshots, attempts = [], []
        plan = dict(pin=dict(p, capped=token), addresses={'BLSAggregator':OLD}, implementation=replacement)
        def rpc(method, params):
            if method == 'eth_getStorageAt':
                self.assertEqual(params, [u.SP, u.IMPL_SLOT, 'latest'])
                return '0x'+state['implementation'][2:].zfill(64)
            if method == 'evm_snapshot':
                snapshots.append(copy.deepcopy(state)); return len(snapshots)-1
            if method == 'evm_revert':
                state.clear(); state.update(snapshots[params[0]]); return True
            if method == 'debug_traceTransaction':
                return {'output':a.calldata('Unauthorized()' if wrong_reason else 'InvalidConfiguration()')}
            if method == 'evm_setNextBlockTimestamp': state['next'] = params[0]; return True
            if method == 'evm_mine': state['time'] = state.pop('next'); return True
            raise AssertionError((method, params))
        def word(rpc, target, sig, *args, **kwargs):
            return {'totalTrackedBalance()':m.BUFFER+int(bad_accounting), 'protocolRevenue()':m.BUFFER,
                    'pendingAPNTsTokenEta()':state['eta'], 'nonce()':0,
                    'pendingFraudProofVerifierReadyAt()':now+100}[sig]
        def address(rpc, target, sig):
            return {'owner()':u.TL, 'pendingAPNTsToken()':state['pending'], 'APNTS_TOKEN()':state['token']}[sig]
        def fixture(rpc, sender, target, data):
            if data != a.calldata('applyFraudProofVerifier()'):
                self.assertEqual((sender, target), (u.TL, u.SP))
            return {'from':sender, 'to':target, 'data':data, 'nonce':hex(state['nonce'])}
        def receipt(rpc, tx, status='0x1'):
            self.assertEqual(a.qty(tx['nonce']), state['nonce'])
            state['time'] += 1; state['nonce'] += 1
            actual = '0x1'
            if tx['data'] == a.calldata('setAPNTsToken(address)', token):
                state.update(pending=token, eta=state['time']+7*m.DAY)
            elif tx['data'] == a.calldata('executeAPNTsTokenChange()'):
                premature = state['time'] < state['eta']
                attempts.append((premature, tx['data']))
                if premature and not (broken_eta and state['implementation'] == replacement): actual = '0x0'
                else: state.update(token=state['pending'], pending=a.ZERO, eta=0)
            else: raise AssertionError(tx)
            a.need('receipt_status', actual, status)
            return dict(status=actual, transactionHash=base.HASH)
        with patch.object(a, 'word', side_effect=word), patch.object(a, 'address', side_effect=address), \
             patch.object(a, 'nonce', side_effect=lambda rpc,who:state['nonce']), \
             patch.object(a, 'block_data', side_effect=lambda *args:dict(timestamp=hex(state['time']))), \
             patch.object(u, 'fixture_tx', side_effect=fixture), patch.object(u, 'receipt', side_effect=receipt), \
             patch.object(a, 'receipt', side_effect=receipt):
            try:
                # A13 must accept pins on either side of the original S7 ETA.
                with patch.object(a, 'negative', return_value={'control':'early_verifier'}):
                    m.controls_at(rpc, plan, 'A13.stake', [])
                controls = []
                m.controls_at(rpc, plan, 'A17', controls)
                self.assertEqual(controls, [])
                m.controls_at(rpc, plan, 'after_upgrade_execute_exec', controls)
                self.assertEqual(controls[0]['control'], 'early_swap')
                self.assertGreater(controls[0]['eta'], now)
                self.assertEqual(attempts, [(True, a.calldata('executeAPNTsTokenChange()')),
                                            (False, a.calldata('executeAPNTsTokenChange()'))])
            finally:
                self.assertEqual(state, original)

    def test_early_swap_early_pin(self): self.swap_control()

    def test_early_swap_late_pin(self): self.swap_control(late=True)

    def test_early_swap_detects_missing_eta_guard(self):
        with assert_stop(self, 'receipt_status') as caught: self.swap_control(broken_eta=True)
        self.assertEqual(caught.exception.record['gate'], 'receipt_status')

    def test_early_swap_refuses_old_implementation(self):
        with assert_stop(self, 'early_swap_implementation') as caught: self.swap_control(old_impl=True, broken_eta=True)
        self.assertEqual(caught.exception.record['gate'], 'early_swap_implementation')

    def test_early_swap_requires_valid_accounting(self):
        with assert_stop(self, 'early_swap_accounting') as caught: self.swap_control(bad_accounting=True)
        self.assertEqual(caught.exception.record['gate'], 'early_swap_accounting')

    def test_early_swap_requires_eta_revert_reason(self):
        with assert_stop(self, 'negative_early_swap_reason') as caught: self.swap_control(wrong_reason=True)
        self.assertEqual(caught.exception.record['gate'], 'negative_early_swap_reason')


class RebuiltScopeTests(unittest.TestCase):
    def test_scope_computed_in_pinned_offline_tree_and_cached(self):
        import subprocess
        from test_release_evidence import compiled_fixture
        import release_evidence
        m.rebuild_commit.cache_clear()
        self.addCleanup(m.rebuild_commit.cache_clear)
        m.rebuild.cache_clear()
        self.addCleanup(m.rebuild.cache_clear)
        arts = {name: dict(bytecode=dict(object=art['bytecode']),
                          runtimeIdentity=art['runtimeIdentity'], storageLayout=art['storageLayout'])
                for name, art in ART['contracts'].items()}
        arts['BLSAggregator']['ast'] = dict(nodeType='FunctionDefinition', name='version',
            body=dict(nodeType='Literal', value=m.AGG_VERSION))
        trees = []
        def archive(repo, commit, tree):
            self.assertEqual(commit, ART['commit'])
            trees.append(tree)
            tree.mkdir()
        def run(command, **kwargs):
            if command[:2] == ['git', 'rev-parse']:
                return subprocess.CompletedProcess(command, 0, ART['commit'])
            if '--version' in command:
                return subprocess.CompletedProcess(command, 0, 'forge Version: 1.7.1')
            self.assertIn('--offline', command)
            self.assertEqual(kwargs['cwd'], trees[0])
            self.assertEqual(kwargs['env']['FOUNDRY_PROFILE'], 'default')
            if 'build' in command:
                self.assertIn('--ast', command)
                self.assertIn('--build-info', command)
                compiled_fixture(kwargs['cwd'])
                return subprocess.CompletedProcess(command, 0, '')
            return subprocess.CompletedProcess(command, 0, json.dumps(ART['contracts']['BLSAggregator']['storageLayout']))
        with patch.object(m.subprocess, 'run', side_effect=run), \
             patch.object(m.isolation, 'extract', return_value=ART['oldOwnerInventory']) as extracted, \
             patch.object(a, 'archive_commit', side_effect=archive), \
             patch.object(a, 'compile_commit', return_value=(arts, {})), \
             patch.object(a, 'metadata_identity', return_value={}), \
             patch.object(m, 'commitment_slot', return_value='slot'), \
             patch.object(m, 'creation_hashes', return_value={}), \
             patch.object(release_evidence, 'compiled_scope', wraps=release_evidence.compiled_scope) as scope:
            built = m.rebuild()
            self.assertIn('contracts/src/SuperPaymaster.sol', built['scope']['files'])
            self.assertEqual(built['scope']['contracts'], list(m.NAMES))
            self.assertIs(m.rebuild(), built)
            json.dumps(built)  # Manifest rebuild metadata must remain serializable.
            scope.assert_called_once_with(trees[0])
            extracted.assert_called_once_with(trees[0], tuple(sorted(set(m.isolation.NAMES) | {'xPNTsFactoryV2', 'xPNTsTokenV2', 'xPNTsTokenV2Ext'})))
            self.assertEqual(built['oldOwnerInventory'], ART['oldOwnerInventory'])
        self.assertTrue(trees[0].exists())
        m.rebuild_commit(ART['commit'])['treeOwner'].cleanup()
        m.rebuild_commit.cache_clear()


class ManifestTests(unittest.TestCase):
    def setUp(self):
        source_validation = patch.object(m.isolation,'validate_deployed',side_effect=lambda section,pin,sources,pending=None:(m.isolation.require_adopted_sources(pending),m.isolation.validate(section,pin,{k: ART['oldOwnerInventory'][k] for k in m.isolation.NAMES})))
        source_validation.start(); self.addCleanup(source_validation.stop)
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name)/'external.json'
        self.pin = pin()
        self.data = input_data(self.pin)
        def file_ref(name, value):
            path = Path(self.tmp.name)/(name+'.json')
            path.write_text(json.dumps(value))
            return dict(path=str(path), sha256=hashlib.sha256(path.read_bytes()).hexdigest())
        self.file_ref = file_ref
        self.plan_validator = patch.object(a, 'validate_plan')
        self.plan_validator.start(); self.addCleanup(self.plan_validator.stop)
        self.data['releaseEvidence'] = {}
        for kind in m.EVIDENCE_KINDS:
            e = dict(kind=kind, subjectCommit=ART['commit'], tool=dict(name='synthetic', version='1'),
                     counts=dict(passed=1, failed=0, skipped=0), result='PASS')
            if kind.startswith('dvt-'):
                e.update(subjectCommit=m.VERIFIER_COMMIT, spCommit=ART['commit'], aggregatorVersion=m.AGG_VERSION)
            if kind == 'conformance':
                e['scope'] = 'checker-logic-offline'
                e['controls'] = json.loads((Path(__file__).resolve().parents[1]/'evidence/a4-conformance-record.template.json').read_text())['controls']
                # Synthetic validator fixture, not an attestation of the blocked local Anvil run.
                for control in e['controls'].values(): control['result'] = 'PASS'
            if kind == 'mutation': e['controls'] = {k:dict(redTest=v, mutated='FAIL', restored='PASS') for k,v in m.MUTATIONS.items()}
            if kind.startswith('dvt-'):
                e['counts']['passed'] = 23
                e['suites'] = {k:dict(passed=v, failed=0, skipped=0, result='PASS') for k,v in m.DVT_SUITES.items()}
                e['suites']['CC115GenuinePragueCrossRepo']['env'] = {'FOUNDRY_EVM_VERSION':'prague'}
            if kind == 'dvt-ci':
                e.update(ciRun=dvt_ci_run(), acceptedFailures=dvt_accepted_failures())
            if kind == 'slither':
                e['tool']['name'] = 'slither'
                e['rawReport'] = file_ref('slither.raw', dict(success=True, error=None, results={}))
                e['rawReport']['path'] = 'slither.raw.json'
                e['findings'] = dict(threshold='Low', aboveThreshold=[], accepted=[], outOfScope=[], inScopeTotal=0)
                e['scope'] = dict(contracts=list(m.NAMES), files=['contracts/src/SuperPaymaster.sol'])
                table = dict(storage=[dict(label='balance', slot='0', offset=0, type='uint256')], namespaces=[])
                e['storageLayout'] = [dict(core=c, extension=x, reference=r, testReferences=[], coreTable=table, extensionTable=table)
                                      for c, x, r in m.LAYOUT_PAIRS]
            if kind == 'reproducible-build':
                e['contracts'] = {k:m.creation_hashes('0x60006000f3a00001') for k in m.NAMES}
                e['contracts']['OverIssueFraudProofVerifier'] = m.creation_hashes(VERIFIER_CODE, 'OverIssueFraudProofVerifier')
            self.data['releaseEvidence'][kind] = file_ref(kind, e)
        self.data['releaseEvidence']['sourceVerificationPlan'] = file_ref('source-plan', {'synthetic':True})
        self.data['phaseC'] = phase_c_inputs(file_ref)
        rows = []
        for sid in a.STEP_IDS:
            label = 'approver' if sid in ('S5a', 'S6a') else 'executor' if sid in ('S5b', 'S6b') else 'deployer'
            earlier = {'S1':5, 'S2':4, 'S3':3, 'S4':2, 'S5a':2, 'S5b':2}.get(sid, 1)
            rows.append(dict(id=sid, tx={'from': self.pin['senders'][label]['address'],
                'nonce':hex(self.pin['senders'][label]['nonce']-earlier), 'data':'0x'}))
        self.data['a3aPlan'] = file_ref('a3a', dict(steps=rows, pin=dict(senders={label:dict(nonce=min(a.qty(s['tx']['nonce']) for s in rows if s['tx']['from'] == sender['address'])) for label,sender in self.pin['senders'].items() if label != 'anni'})))
        self.data['a3aPlan']['receipts'] = {sid:'0x'+format(i+1, '064x') for i,sid in enumerate(a.STEP_IDS)}
        self.pin['a3aHistory'] = {}
        self.pin['a3aGapReads'] = []
        for step in rows:
            txhash = self.data['a3aPlan']['receipts'][step['id']]
            self.pin['a3aHistory'][step['id']] = dict(
                receipt=dict(transactionHash=txhash, status='0x1', blockNumber='0x1', blockHash=base.HASH),
                transaction=dict(step['tx'], hash=txhash, type='0x2', input='0x', blockNumber='0x1', blockHash=base.HASH))
        ci = self.data['releaseEvidence']['dvt-ci']
        self.data['verifier'].update(ciPath=ci['path'], ciSha256=ci['sha256'])
        self.fraud = fraud_data(self.pin, self.data['pop'][0]['aggregator'])
        self.export = fraud_export(self.fraud)
        self.data['fraudProofFixture'] = file_ref('fraud', self.export)
        fixture_artifact = self.data['verifier'].pop('artifact')
        self.real_verifier_artifact = m.verifier_artifact
        for target, name, value in ((m, 'verifier_artifact', fixture_artifact), (m, 'rebuild_dvt', dict(bytecode=fixture_artifact['bytecode'], creationHashes=m.creation_hashes(fixture_artifact['bytecode'], 'OverIssueFraudProofVerifier'))), (m, 'release_gate', None)):
            mock = patch.object(target, name, return_value=value)
            mock.start()
            self.addCleanup(mock.stop)
        self.path.write_text(json.dumps(self.data))
        # Phase C funding re-reads are exercised against a stateful fake in test_manifest_phase_c.py;
        # here they are isolated so the A/B/D fakes need not model post-Phase-C balances.
        self.funding_patch = patch.object(m, 'funding_gate', return_value={'synthetic': 'funding'})
        self.funding_patch.start(); self.addCleanup(self.funding_patch.stop)
        self.baseline_patch = patch.object(m, 'rebuild_baselines', return_value=BASELINES)
        self.baseline_patch.start(); self.addCleanup(self.baseline_patch.stop)
        self.commit_patch = patch.object(m, 'rebuild_commit', return_value=ART)
        self.commit_patch.start(); self.addCleanup(self.commit_patch.stop)
        self.patch = patch.object(m, 'rebuild', return_value=ART)
        self.patch.start()
        self.addCleanup(self.patch.stop)
        self.inputs = m.external(self.path)
        self.plan = m.build_plan(self.pin, self.inputs)

    def staged_chain(self):
        early = copy.deepcopy(self.inputs)
        early['data'].pop('pop')
        early['data'].pop('fraudProofFixture')
        early['sha256'] = '1'*64
        a7 = m.build_plan(self.pin, early, 'a7')
        def source(plan):
            return dict(plan=plan, readback=dict(prefixDigest=plan['prefixDigest'],
                        domainSeparator=plan['expectedDomainSeparator']))
        middle = copy.deepcopy(self.inputs)
        middle['data'].pop('fraudProofFixture')
        middle['sha256'] = '2'*64
        sources = dict(a7=source(a7))
        b4 = m.build_plan(self.pin, middle, 'b4', sources)
        sources['b4'] = source(b4)
        return a7, b4, sources

    def test_staged_builds(self):
        a7, b4, sources = self.staged_chain()
        self.assertEqual(a7['steps'][-1]['id'], 'A7')
        self.assertEqual(b4['steps'][-1]['id'], 'B4')
        full = m.build_plan(self.pin, self.inputs, 'full', sources)
        m.verify_prefix(full, a7, 'a7')
        m.verify_prefix(full, b4, 'b4')
        self.assertEqual(full['operations']['activation'], b4['operations']['activation'])
        for stage, keys in (('full', ('pop', 'fraudProofFixture')), ('b4', ('pop',))):
            for key in keys:
                bad = copy.deepcopy(self.inputs); del bad['data'][key]
                with self.assertRaises(a.Gate): m.build_plan(self.pin, bad, stage)

    def test_staged_prefix_guards(self):
        a7, b4, sources = self.staged_chain()
        full = m.build_plan(self.pin, self.inputs, 'full', sources)
        for kind in ('constructor', 'nonce', 'address', 'pin'):
            bad = copy.deepcopy(full)
            if kind == 'constructor': bad['steps'][0]['tx']['data'] += '00'
            if kind == 'nonce': bad['steps'][0]['tx']['nonce'] = '0xffff'
            if kind == 'address': bad['addresses']['BLSAggregator'] = ANNI
            if kind == 'pin': bad['pin']['blockHash'] = a.ZERO32
            with self.subTest(kind=kind), self.assertRaises(a.Gate): m.verify_prefix(bad, a7, 'a7')

    def test_staged_timing_prefix(self):
        a7, b4, sources = self.staged_chain()
        full = m.build_plan(self.pin, self.inputs, 'full', sources)
        for field in ('activationScheduleNotBefore', 'executionTimestamp', 'warpTarget', 'delay'):
            bad = copy.deepcopy(b4)
            if field == 'activationScheduleNotBefore':
                bad[field] = 9999999999
            elif field == 'delay':
                next(p for s in bad['steps'] for p in s['readbacks'] if p['kind'] == 'eta')['delay'] = 9999999999
            else:
                for step in bad['steps']: step[field] = 9999999999
            bad['prefixDigest'] = m.prefix_digest(bad)
            with self.subTest(field=field):
                with assert_stop(self, 'prefix_exact') as caught:
                    m.verify_prefix(full, bad, 'b4')
                self.assertEqual(caught.exception.record['gate'], 'prefix_exact')

    def test_staged_source_rebuild(self):
        _, _, sources = self.staged_chain()
        for field in ('activationScheduleNotBefore', 'executionTimestamp', 'controls'):
            bad = copy.deepcopy(sources)
            plan = bad['b4']['plan']
            if field == 'executionTimestamp':
                for step in plan['steps']: step[field] = 9999999999
            else:
                plan[field] = 9999999999
            plan['prefixDigest'] = m.prefix_digest(plan)
            bad['b4']['readback']['prefixDigest'] = plan['prefixDigest']
            with self.subTest(field=field), assert_stop(self, 'source_plan_bytes') as caught:
                m.build_plan(self.pin, self.inputs, 'full', bad)
            self.assertEqual(caught.exception.record['gate'], 'source_plan_bytes')

    def test_stage_source_is_exact_rebuild(self):
        a7, b4, sources = self.staged_chain()
        for original in (a7, b4):
            measured = copy.deepcopy(original)
            for step in measured['steps']:
                step.update(estimateGas=100000, skipped=False)
                step['tx']['gas'] = hex(130000)
            measured['budgetsWei'] = {}
            with patch.object(a, 'call', return_value=original['expectedDomainSeparator']):
                source = m.stage_source(measured, SimpleNamespace(local=True))
            self.assertEqual(m.source_plan_bytes(source['plan']), m.source_plan_bytes(original))
            sources[original['stage']] = source
        m.build_plan(self.pin, self.inputs, 'full', sources)
        sources['b4']['plan']['steps'][0]['estimateGas'] = 100000
        with self.assertRaisesRegex(a.Gate, 'source_plan_bytes'):
            m.build_plan(self.pin, self.inputs, 'full', sources)

    def test_stage_artifact_separation(self):
        a7, b4, sources = self.staged_chain()
        pin_path = Path(self.tmp.name)/'stage-pin.json'
        pin_path.write_text(json.dumps(self.pin))
        source_path = Path(self.tmp.name)/'a7-source.json'
        source_path.write_text(json.dumps(sources['a7']))
        for plan in (a7, b4):
            cli_out = Path(self.tmp.name)/('cli-'+plan['stage'])
            args = ['plan', '--stage', plan['stage'], '--pin', str(pin_path),
                    '--inputs', str(self.path), '--out', str(cli_out)]
            if plan['stage'] == 'b4': args += ['--a7-source', str(source_path)]
            self.assertEqual(m.main(args), 0)
            name = 'stage-'+plan['stage']+'.json'
            self.assertEqual(sorted(p.name for p in cli_out.iterdir()), [name, name+'.sha256'])
            out = Path(self.tmp.name)/plan['stage']
            out.mkdir()
            m.save_artifact(out, plan)
            self.assertFalse((out/'plan.json').exists())
            self.assertFalse((out/'plan.json.sha256').exists())
            artifact = out/('stage-'+plan['stage']+'.json')
            self.assertFalse(json.loads(artifact.read_text())['final'])
            renamed = out/'renamed-final.json'
            renamed.write_bytes(artifact.read_bytes())
            for command in ('sign', 'send'):
                self.assertEqual(m.main([command, '--plan', str(renamed)]), 1)
            with self.assertRaises(a.Gate): u.save_plan(out, plan)
            with self.assertRaisesRegex(a.Gate, 'final_artifact'):
                REAL_A3A_VALIDATE_PLAN(plan, frozen=True)
            with patch.object(a, 'validate_plan', REAL_A3A_VALIDATE_PLAN):
                with self.assertRaisesRegex(a.Gate, 'final_artifact'):
                    a.signing_transaction(renamed, hashlib.sha256(renamed.read_bytes()).hexdigest(), 'A7', None)
            altered = dict(plan, stage='full')
            with self.assertRaises(a.Gate): m.save_artifact(out, altered)

    def replay_stage_to_fork(self, stage, calibrated=False, tamper=None):
        # The existing fixture supplies synthetic build artifacts. Loading, input
        # parsing, rebuilding, and validation stay real; stop at the fork boundary.
        inputs = m.external(self.path, stage)
        sources = {'a7': self.staged_chain()[2]['a7']} if stage == 'b4' else None
        plan = m.build_plan(self.pin, inputs, stage, sources)
        if calibrated:
            for step in plan['steps']:
                freeze_gas(plan, step)
            m.budget(plan)
        saved = Path(self.tmp.name)/('saved-'+stage+str(calibrated)+str(tamper))
        saved.mkdir()
        m.save_artifact(saved, plan)
        artifact = saved/('stage-'+stage+'.json')
        sidecar = artifact.with_name(artifact.name+'.sha256')
        self.assertEqual(sidecar.read_text().split()[0], hashlib.sha256(artifact.read_bytes()).hexdigest())
        if tamper == 'sidecar':
            sidecar.write_text('0'*64+'  '+artifact.name+'\n')
        elif tamper == 'final':
            bad = dict(plan, final=True)
            a.write_json(artifact, bad)
            sidecar.write_text(hashlib.sha256(artifact.read_bytes()).hexdigest()+'\n')
        out = saved/'replay'
        rpc_file = saved/'rpc'
        rpc_file.write_text('https://offline.invalid')
        # collect() reads Phase C state only for the stages that build Phase C.
        collected = {k: v for k, v in copy.deepcopy(self.pin).items() if k != 'phaseC' or stage in m.PC_STAGES}
        with patch.object(a, 'RPC'), patch.object(m, 'collect', return_value=collected), \
             patch.object(a, 'fork', side_effect=a.Gate('test_fork_boundary', False, True)) as fork:
            code = m.main(['simulate', '--stage', stage, '--inputs', str(self.path),
                           '--out', str(out), '--rpc-file', str(rpc_file),
                           '--rpc-file-secondary', str(rpc_file), '--block', self.pin['block'],
                           '--plan', str(artifact)])
        self.assertEqual(code, 1)
        failure = json.loads((out/'FAILURE.json').read_text())
        expected = {'sidecar':'plan_hash', 'final':'stage_not_final'}.get(tamper, 'test_fork_boundary')
        self.assertEqual(failure['gate'], expected)
        if tamper:
            fork.assert_not_called()
        else:
            fork.assert_called_once()
            loaded = m.load_artifact(artifact)
            self.assertEqual(loaded, plan)
            self.assertIs(loaded['final'], False)
            with self.assertRaisesRegex(a.Gate, 'final_artifact'):
                u.save_plan(saved, loaded)
            for command in ('sign', 'send'):
                self.assertEqual(m.main([command, '--plan', str(artifact)]), 1)

    def test_stage_artifact_cli_replay(self):
        for stage in ('a7', 'b4'):
            for calibrated in (False, True):
                with self.subTest(stage=stage, calibrated=calibrated):
                    self.replay_stage_to_fork(stage, calibrated)

    def test_stage_artifact_tampered_sidecar(self):
        for stage in ('a7', 'b4'):
            with self.subTest(stage=stage):
                self.replay_stage_to_fork(stage, tamper='sidecar')

    def test_stage_artifact_loader_rejects_final(self):
        for stage in ('a7', 'b4'):
            with self.subTest(stage=stage):
                self.replay_stage_to_fork(stage, tamper='final')

    def test_staged_metadata_guards(self):
        a7, b4, sources = self.staged_chain()
        for field, value in (('stage', 'full'), ('prefixDigest', '0'*64)):
            bad = copy.deepcopy(a7); bad[field] = value
            with self.subTest(field=field), self.assertRaises(a.Gate): m.verify_prefix(b4, bad, 'a7')
        bad = copy.deepcopy(a7); bad['steps'].pop(); bad['prefixDigest'] = m.prefix_digest(bad)
        with self.assertRaises(a.Gate): m.verify_prefix(b4, bad, 'a7')
        for field in ('prefixDigest', 'domainSeparator'):
            bad = copy.deepcopy(sources); bad['a7']['readback'][field] = a.ZERO32
            with self.subTest(field=field), self.assertRaises(a.Gate): m.build_plan(self.pin, self.inputs, 'full', bad)
        with self.assertRaises(a.Gate): m.build_plan(self.pin, self.inputs, 'b4')
        with self.assertRaises(a.Gate): m.build_plan(self.pin, self.inputs, 'invalid')

    def test_staged_domain_guards(self):
        bad = copy.deepcopy(self.inputs); bad['data']['pop'][0]['domainSeparator'] = a.ZERO32
        with self.assertRaises(a.Gate): m.build_plan(self.pin, bad)
        with patch.object(m, 'fraud_fixture', return_value=dict(domainSeparator=a.ZERO32)):
            with self.assertRaises(a.Gate): m.build_plan(self.pin, self.inputs)
        rpc = SimpleNamespace(local=True)
        with patch.object(a, 'call', return_value=a.ZERO32):
            with self.assertRaises(a.Gate): m.stage_readback(self.plan, rpc)
        with patch.object(a, 'call', return_value=self.plan['expectedDomainSeparator']):
            with self.assertRaises(a.Gate): m.stage_readback(self.plan, SimpleNamespace(local=False))
            self.assertEqual(m.stage_readback(self.plan, rpc)['domainSeparator'], self.plan['expectedDomainSeparator'])

    def test_staged_runner_guards(self):
        plan = copy.deepcopy(self.plan)
        plan.update(stage='b4', steps=[self.step('B4')])
        plan.pop('phaseC')
        rpc = unittest.mock.Mock(local=True, archive_overrides={})
        with contextlib.ExitStack() as stack:
            for obj, name in ((m, 'validate_plan'), (a, 'process_alive'), (m, 'controls_at'),
                              (u, 'wait_until'), (a, 'word'), (u, 'log'), (a, 'trace_overrides'),
                              (m, 'budget'), (a, 'write_json')):
                stack.enter_context(patch.object(obj, name))
            stack.enter_context(patch.object(m, 'b4_controls', return_value=[]))
            execute = stack.enter_context(patch.object(m, 'execute_b4', return_value=dict(step='wrong', receipt={})))
            stack.enter_context(patch.object(m, 'stage_readback', return_value={}))
            closing = stack.enter_context(patch.object(m, 'dvt_closing', return_value={}))
            fraud = stack.enter_context(patch.object(m, 'fraud_rehearsal'))
            with self.assertRaises(a.Gate): m.run_manifest(None, rpc, plan, Path(self.tmp.name))
            execute.return_value = dict(step='B4', receipt={})
            self.assertEqual(m.run_manifest(None, rpc, plan, Path(self.tmp.name))['stage'], 'b4')
            closing.assert_called_once_with(rpc, plan)
            fraud.assert_not_called()

    def test_staged_cli_guard(self):
        out = Path(self.tmp.name)/'cli-stage'
        plan = dict(self.plan, stage='a7', final=False)
        with patch.object(m, 'external', return_value=self.inputs), \
             patch.object(m, 'collect', return_value=self.pin), \
             patch.object(m, 'validate_plan'), patch.object(a, 'load_plan', return_value=plan), \
             patch.object(a, 'fork', side_effect=RuntimeError('must not start')) as fork:
            self.assertEqual(m.main(['simulate', '--inputs', str(self.path), '--out', str(out),
                '--rpc-file', str(self.path), '--rpc-file-secondary', str(self.path),
                '--block', self.pin['block'], '--plan', str(self.path)]), 1)
            fork.assert_not_called()

    def step(self, sid):
        return next(s for s in self.plan['steps'] if s['id'] == sid)

    def test_phase_d_calldata_order_and_nonces(self):
        rows = [s for s in self.plan['steps'] if s['id'].startswith('D.')]
        expected = [('D.registry.transfer', u.REG, 'transferOwnership(address)', u.TL)]
        for name, target, owner in m.handover_contracts(self.plan['addresses'])[1:]:
            if name in ('aggregator', 'old_aggregator'):
                expected.append(('D.'+name+'.admin', target, 'setSlashPolicyAdmin(address)', u.SAFE))
            expected.append(('D.'+name+'.transfer', target, 'transferOwnership(address)', owner))
        direct = [s for s in rows if s['sender'] == 'deployer']
        self.assertEqual([s['id'] for s in direct], [e[0] for e in expected])
        for offset, (step, (_, target, sig, owner)) in enumerate(zip(direct, expected), 1):
            self.assertEqual(step['tx']['to'], target)
            self.assertEqual(step['tx']['data'], a.calldata(sig, owner))
            # Phase C deployer transactions sit between B4 and Phase D on the same counter.
            last = [s for s in self.plan['steps'] if s['sender'] == 'deployer' and not s['id'].startswith('D.')][-1]
            self.assertEqual(last.get('phase'), 'C')
            self.assertEqual(a.qty(step['tx']['nonce']), a.qty(last['tx']['nonce'])+offset)
            self.assertTrue(step['readbacks'])
        self.assertEqual(self.plan['schema'], '3.1')
        self.assertEqual([s['id'] for s in rows[1:5]], [
            'D.registry_schedule_approve', 'D.registry_schedule_exec',
            'D.registry_execute_approve', 'D.registry_execute_exec'])

    def test_registry_accept_operation_and_readbacks(self):
        op = self.plan['operations']['registry_accept']
        self.assertEqual(op['targets'], [u.REG])
        self.assertEqual(op['data'], [a.calldata('acceptOwnership()')])
        self.assertEqual(op['predecessor'], self.plan['operations']['activation']['id'])
        self.assertEqual(op['id'], u.operation_hash(op['targets'], op['data'], op['predecessor'], op['salt'], False))
        self.assertEqual(u.DELAY, 48*3600)
        self.assertEqual(self.step('D.registry.transfer')['readbacks'], m.registry_ownership(u.DEPLOYER, u.TL))
        self.assertEqual(self.step('D.registry_execute_exec')['readbacks'][1:], m.registry_ownership(u.TL, a.ZERO))
        slot = int(a.keccak(a.cast('abi-encode', 'c(uint256)', int(a.keccak('aastar.storage.Ownership2Step'),16)-1)),16) & ~255
        self.assertEqual(int(m.PENDING_OWNER_SLOT,16), slot)
        for i, verb in enumerate(('schedule', 'execute'), 5):
            for suffix in ('approve', 'exec'):
                step = self.step('D.registry_'+verb+'_'+suffix)
                # Phase C's C1 Safe mint takes the nonce after 6d (§4), before Phase D.
                self.assertEqual(step['safeNonce'], self.pin['safeNonce']+i+int('C1_exec' in self.plan['phaseC']['steps']))
                self.assertEqual(step['inner'], u.op_call(op, verb))
                self.assertEqual(step['safeHash'], m.safe_hash(step['inner'], step['safeNonce']))

    def test_handover_gates_require_each_completed_step(self):
        all_ids = {s['id'] for s in self.plan['steps']}
        for sid in ('D.aggregator.admin', 'D.aggregator.transfer', 'D.old_aggregator.admin', 'D.old_aggregator.transfer'):
            with patch.object(m, 'check_predicate'):
                m.handover_gate(None, self.plan, self.step(sid), {'passed':all_ids})
                for missing in ('A10.0', 'A10.1', 'A10.2', 'A11.min', 'A11.default', 'B4', 'activation_execute_exec'):
                    with self.subTest(sid=sid, missing=missing), self.assertRaises(a.Gate):
                        m.handover_gate(None, self.plan, self.step(sid), {'passed':all_ids-{missing}})
        with patch.object(m, 'check_predicate') as check:
            for suffix in ('approve', 'exec'):
                step = self.step('D.registry_schedule_'+suffix)
                with self.assertRaises(a.Gate):
                    m.handover_gate(None, self.plan, step, {'passed':all_ids-{'D.registry.transfer'}})
                m.handover_gate(None, self.plan, step, {'passed':all_ids})
            self.assertTrue(check.called)
        bad = copy.deepcopy(self.plan)
        bad['pin']['bindings'][COMMITTEE] = '0x6000'
        with self.assertRaises(a.Gate):
            m.handover_gate(None, bad, self.step('D.committee.transfer'), {'passed':all_ids})

    def test_registry_accept_salt_binds_inputs_hash(self):
        expected = a.keccak('manifest-v3.1/'+self.pin['blockHash']+'/'+self.inputs['sha256']+'/registry_accept')
        self.assertEqual(self.plan['operations']['registry_accept']['salt'], expected)
        changed = copy.deepcopy(self.inputs)
        changed['sha256'] = 'f'*64
        other = m.build_plan(self.pin, changed)['operations']['registry_accept']
        self.assertNotEqual(other['salt'], expected)
        self.assertNotEqual(other['id'], self.plan['operations']['registry_accept']['id'])

    def test_committee_handover_requires_completed_binding(self):
        passed = {s['id'] for s in self.plan['steps']}
        step = self.step('D.committee.transfer')
        m.handover_gate(None, self.plan, step, {'passed':passed})
        with assert_stop(self, 'handover_dependencies') as caught:
            m.handover_gate(None, self.plan, step, {'passed':passed-{'A8.committee'}})
        self.assertEqual(caught.exception.record['gate'], 'handover_dependencies')

    def test_aggregator_transfer_requires_completed_admin(self):
        passed = {s['id'] for s in self.plan['steps']}
        for name in ('aggregator', 'old_aggregator'):
            step = self.step('D.'+name+'.transfer')
            # Even an already-correct live admin cannot replace the completed step.
            def call(rpc, target, sig, *args):
                self.assertEqual((target, sig), (step['tx']['to'], 'slashPolicyAdmin()'))
                return a.cast('abi-encode', 'c(address)', u.SAFE)
            with self.subTest(name=name), patch.object(a, 'call', side_effect=call):
                m.handover_gate(None, self.plan, step, {'passed':passed})
                with assert_stop(self, 'handover_dependencies') as caught:
                    m.handover_gate(None, self.plan, step, {'passed':passed-{'D.'+name+'.admin'}})
                self.assertEqual(caught.exception.record['gate'], 'handover_dependencies')

    def test_committee_rejects_two_step_runtime(self):
        passed = {s['id'] for s in self.plan['steps']}
        step = self.step('D.committee.transfer')
        m.handover_gate(None, self.plan, step, {'passed':passed})
        for selector, gate in (('79ba5097', 'committee_no_accept_ownership'),
                               ('e30c3978', 'committee_no_pending_owner')):
            bad = copy.deepcopy(self.plan)
            bad['pin']['bindings'][COMMITTEE] += ('63'+selector).upper()
            with self.subTest(selector=selector):
                with assert_stop(self, gate) as caught:
                    m.handover_gate(None, bad, step, {'passed':passed})
                self.assertEqual(caught.exception.record['gate'], gate)
        self.assertIn(m.address_pred(COMMITTEE, 'owner()', u.SAFE), step['readbacks'])

    def test_pre_send_registry_owner_follows_completed_accept(self):
        step = self.step('D.committee.transfer')
        self.plan['pin']['oldActivity'] = {'dvtProposals':[]}
        def rpc(method, params):
            self.assertEqual((method, params), ('eth_chainId', []))
            return hex(a.CHAIN)
        rpc.local = True
        rpc = with_orphan_reads(rpc, self.plan['pin'], '0x150')
        real_word, real_call = a.word, a.call
        for accepted in (False, True):
            passed = {s['id'] for s in self.plan['steps']}-{'D.registry_execute_exec'}
            if accepted: passed.add('D.registry_execute_exec')
            for owner in (u.DEPLOYER, u.TL):
                def address(r, target, sig, *args):
                    self.assertEqual(sig, 'owner()')
                    return owner if target == u.REG else u.TL
                with self.subTest(accepted=accepted, owner=owner), contextlib.ExitStack() as stack:
                    for mock in (
                        patch.object(a, 'nonce', return_value=a.qty(step['tx']['nonce'])),
                        patch.object(a, 'word', side_effect=lambda r,t,s,*args,**kw: step['safeNonce'] if s == 'nonce()' else real_word(r,t,s,*args,**kw)),
                        patch.object(a, 'address', side_effect=address),
                        patch.object(a, 'call', side_effect=lambda r,t,s,*args,**kw: a.ZERO32 if s == 'hasRole(bytes32,address)' else u.frozen_config(self.pin['roleConfig']) if s == 'getRoleConfig(bytes32)' else real_call(r,t,s,*args,**kw)),
                        patch.object(a, 'block_data', return_value={'number':'0x150'}),
                        patch.object(u, 'safe_state', return_value=self.pin['safe']),
                        patch.object(u, 'governance'),
                        patch.object(u, 'code', side_effect=lambda r,t,*args:self.pin['bindings'][t]),
                        patch.object(m, 'discovery_coverage', return_value=copy.deepcopy(self.plan['pin'])),
                        patch.object(m, 'old_activity', return_value={}),
                        patch.object(m, 'dvt_activity', return_value=[])):
                        stack.enter_context(mock)
                    context = dict(passed=passed, frozen=True, transferred=True, activated=True)
                    if owner == (u.TL if accepted else u.DEPLOYER):
                        self.assertEqual(m.pre_send(rpc, self.plan, step, context), step['tx'])
                    else:
                        with assert_stop(self, 'registry_owner') as caught:
                            m.pre_send(rpc, self.plan, step, context)
                        self.assertEqual(caught.exception.record['gate'], 'registry_owner')

    def test_run_manifest_final_frozen_check_requires_timelock_owner(self):
        # Isolate the terminal checkpoint: no transactions or engine are needed.
        plan = copy.deepcopy(self.plan)
        plan['steps'] = []
        plan['pin']['senders'] = {}
        plan['controls'] = ['owner_handover']
        def rpc(method, params):
            if (method, params) == ('anvil_impersonateAccount', [PC_OWNER]): return True
            raise AssertionError((method, params))
        rpc.local = True
        class CheckpointPassed(Exception): pass
        for owner in (u.TL, u.DEPLOYER):
            with self.subTest(owner=owner), patch.object(m, 'validate_plan'), \
                 patch.object(m, 'CONTROLS', ['owner_handover']), patch.object(m, 'PC_CONTROLS', []), \
                 patch.object(m, 'handover_controls', return_value={'control':'owner_handover'}), \
                 patch.object(a, 'address', return_value=owner), \
                 patch.object(a, 'call', side_effect=lambda r,t,s,*args,**kw: a.ZERO32 if s == 'hasRole(bytes32,address)' else u.frozen_config(self.pin['roleConfig'])), \
                 patch.object(m, 'dvt_closing', return_value={}), \
                 patch.object(m, 'balances', side_effect=CheckpointPassed):
                if owner == u.TL:
                    with self.assertRaises(CheckpointPassed):
                        m.run_manifest(None, rpc, plan, Path(self.tmp.name))
                else:
                    with assert_stop(self, 'registry_authority') as caught:
                        m.run_manifest(None, rpc, plan, Path(self.tmp.name))
                    self.assertEqual(caught.exception.record['gate'], 'registry_authority')

    def test_pending_owner_getter_and_slot_mismatch_stop(self):
        for bad in ('getter', 'slot'):
            def rpc(method, params):
                if method == 'eth_getStorageAt': return hex(0 if bad == 'slot' else int(u.TL,16))
                raise AssertionError(method)
            def call(r, target, sig, *args):
                value = u.DEPLOYER if sig == 'owner()' else (a.ZERO if bad == 'getter' else u.TL)
                return a.cast('abi-encode', 'c(address)', value)
            with patch.object(a, 'call', side_effect=call), self.assertRaises(a.Gate):
                for pred in m.registry_ownership(u.DEPLOYER, u.TL): m.check_predicate(rpc, pred)

    def test_handover_controls_assert_reasons_success_and_restore(self):
        for failure in (None, 'negative', 'positive', 'readback'):
            history, negatives, positives = [], [], []
            def rpc(method, params):
                history.append(method)
                return 'snapshot' if method == 'evm_snapshot' else True
            rpc.local = True
            def fixture(r, sender, target, data): return {'from':sender, 'to':target, 'data':data}
            def negative(r, tx, expected, name):
                policy = tx['data'][:10] in (a.calldata('setSlashThreshold(uint8,uint8)', 0, 2)[:10],
                    a.calldata('setGuardianSlashBps(uint16)', 3000)[:10])
                error = 'NotSlashPolicyAdmin(address)' if policy else 'OwnableUnauthorizedAccount(address)'
                self.assertEqual(expected, a.calldata(error, tx['from']))
                negatives.append(tx)
                if failure == 'negative': raise a.Gate('wrong_reason', '0x', expected)
                return {'control':name}
            def receipt(r, tx):
                positives.append(tx)
                return {'status':'0x0' if failure == 'positive' else '0x1'}
            with patch.object(a, 'word', side_effect=lambda r, t, sig, *args: 2 if sig == 'slashThresholds(uint8)' else 1000), \
                 patch.object(u, 'fixture_tx', side_effect=fixture), patch.object(a, 'negative', side_effect=negative), \
                 patch.object(u, 'receipt', side_effect=receipt), patch.object(m, 'check_predicate',
                 side_effect=a.Gate('readback', 0, 1) if failure == 'readback' else None):
                if failure:
                    with self.assertRaises(a.Gate): m.handover_controls(rpc, self.plan)
                else:
                    result = m.handover_controls(rpc, self.plan)
                    self.assertTrue(result['restored'])
                    self.assertEqual(len(negatives), 18)
                    self.assertEqual(len(positives), 14)
                    expected_probes = [(u.SP, u.TL, a.calldata('setProtocolFee(uint256)', 1000))]
                    for target in (self.plan['addresses']['BLSAggregator'], m.OLD_AGGREGATOR):
                        expected_probes += [(target, u.SAFE, a.calldata(sig, *args)) for sig, args in (
                            ('setSlashThreshold(uint8,uint8)', (0, 2)),
                            ('setGuardianSlashBps(uint16)', (1000,)))]
                    self.assertEqual([(tx['to'], tx['from'], tx['data']) for tx in positives[-5:]], expected_probes)
                    expected_denied = [(target, sender, data) for target, _, data in expected_probes
                                       for sender in ((u.DEPLOYER, u.SAFE) if target == u.SP else (u.DEPLOYER,))]
                    self.assertEqual([(tx['to'], tx['from'], tx['data']) for tx in negatives[-6:]], expected_denied)
                    self.assertEqual(history.count('evm_snapshot'), 12)
                    for tx in positives:
                        owner = next(owner for _, target, owner in [*m.handover_contracts(self.plan['addresses']), ('sp', u.SP, u.TL)] if target == tx['to'])
                        self.assertEqual(tx['from'], owner)
            self.assertEqual(history[-1], 'evm_revert')
            self.assertEqual(history.count('evm_snapshot'), history.count('evm_revert'))

    def test_registry_accept_trace_requires_timelock_caller(self):
        step = self.step('D.registry_execute_exec')
        trace = {'from':step['tx']['from'], 'to':u.SAFE, 'input':step['tx']['data'], 'calls':[
            {'from':u.SAFE, 'to':u.TL, 'input':step['inner'], 'calls':[
                {'from':u.TL, 'to':u.REG, 'input':a.calldata('acceptOwnership()')}]}]}
        m.handover_trace(lambda *args:trace, self.plan, step, {'transactionHash':base.HASH})
        for field, value in (('from', u.SAFE), ('error', 'execution reverted'), ('input', '0x')):
            bad = copy.deepcopy(trace)
            bad['calls'][0]['calls'][0][field] = value
            with self.subTest(field=field), self.assertRaises(a.Gate):
                m.handover_trace(lambda *args:bad, self.plan, step, {'transactionHash':base.HASH})

    def test_frozen_registry_tracks_completed_handover(self):
        original = copy.deepcopy(self.pin)
        with patch.object(u, 'assert_frozen') as check:
            for handed_over in (False, True):
                m.assert_manifest_frozen(None, self.pin, handed_over)
                expected = dict(self.pin, registryOwner=u.TL if handed_over else self.pin['registryOwner'])
                check.assert_called_with(None, expected)
        self.assertEqual(self.pin, original)

    def test_determinism(self):
        self.assertEqual(self.plan, m.build_plan(copy.deepcopy(self.pin), copy.deepcopy(self.inputs)))
        m.validate_plan(self.plan, self.inputs)

    def test_nonce_sequences(self):
        for label, sender in self.pin['senders'].items():
            steps = [s for s in self.plan['steps'] if s['sender'] == label]
            self.assertEqual([a.qty(s['tx']['nonce']) for s in steps], list(range(sender['nonce'], sender['nonce']+len(steps))))
            self.assertTrue(all(s['tx']['from'] == sender['address'] for s in steps))

    def test_create_addresses(self):
        creates = [s for s in self.plan['steps'] if s['tx']['to'] is None]
        # Ten A/B CREATEs plus Phase C's T, VPM, Q, oracle and TPM.
        self.assertEqual(len(creates), 15)
        self.assertEqual([s['id'] for s in creates if s.get('phase') == 'C'], ['C10', 'C12', 'C13.token', 'C13.oracle', 'C14'])
        for s in creates:
            self.assertEqual(s['creates'], a.create_address(s['tx']['from'], a.qty(s['tx']['nonce'])))
        self.assertEqual(self.plan['extension'], a.create_address(self.plan['implementation'], 1))

    def test_b1_exact(self):
        ad = self.plan['addresses']
        op = self.plan['operations']['upgrade']
        self.assertEqual(op['data'], [a.calldata('upgradeToAndCall(address,bytes)', self.plan['implementation'], a.calldata('setGlobalPaused(bool)', 'true')),
            a.calldata('queueGasParams(uint32,uint32,uint32,uint32)', *u.GAS), a.calldata('setXPNTsFactory(address)', ad['xPNTsFactoryV2']),
            a.calldata('queueBLSAggregator(address)', ad['BLSAggregator'])])
        self.assertEqual(op['targets'], [u.SP]*4)

    def test_b3_exact(self):
        op = self.plan['operations']['activation']
        expected = [a.calldata(x+'()') for x in ('executeGasParams','applyBLSAggregator','executeAPNTsTokenChange')]
        expected += [a.calldata('setOperatorPaused(address,bool)', x, 'false') for x in self.data['sampled']]
        expected += [a.calldata('setGlobalPaused(bool)', 'false')]
        self.assertEqual(op['data'], expected)
        self.assertTrue(op['batch'])
        self.assertEqual(op['predecessor'], self.plan['operations']['upgrade']['id'])
        self.assertNotIn(a.calldata('setOperatorPaused(address,bool)', base.HOLDER, 'false'), op['data'])

    def test_safe_nonces_hashes(self):
        steps = [s for s in self.plan['steps'] if 'safeHash' in s]
        for i in range(7):
            approval, execution = steps[2*i:2*i+2]
            n = self.pin['safeNonce']+i
            self.assertEqual(approval['safeNonce'], n)
            self.assertEqual(execution['safeNonce'], n)
            self.assertEqual(approval['safeHash'], m.safe_hash(approval['inner'], n, approval.get('safeTarget', u.TL)))
            self.assertEqual(execution['tx']['data'], m.safe_payload(execution['inner'], execution.get('safeTarget', u.TL)))

    def test_eta_rule(self):
        eta = self.pin['pendingAPNTsTokenEta']
        self.assertEqual(self.plan['activationScheduleNotBefore'], eta-u.DELAY)
        m.activation_eta_gate(self.plan, eta-u.DELAY, eta)
        for schedule, execute in ((eta-u.DELAY-1, eta-1), (eta, eta+u.DELAY-1)):
            with self.assertRaises(a.Gate):
                m.activation_eta_gate(self.plan, schedule, execute)

    def test_b2_success(self):
        result = m.b2_gate(FakeChain(self.plan), self.plan, '0x150')
        self.assertTrue(result['inflightProof']['continuousGlobalPause'])

    def test_b2_stop_conditions(self):
        for mutate in (lambda c:setattr(c, 'backing', 0), lambda c:setattr(c, 'backing', m.BUFFER+1), lambda c:c.balances.update(totalTrackedBalance=m.BUFFER+1),
                       lambda c:c.balances.update(totalTrackedBalance=m.BUFFER+1, protocolRevenue=m.BUFFER+1),
                       lambda c:setattr(c, 'pending', 1), lambda c:setattr(c, 'unpause', True),
                       lambda c:setattr(c, 'paused', 0),
                       lambda c:c.balances['operatorBalances'].update({ANNI:1})):
            chain = FakeChain(self.plan)
            mutate(chain)
            with self.subTest(mutate=mutate), self.assertRaises(a.Gate):
                m.b2_gate(chain, self.plan, '0x150')

    def test_b4_skip_does_not_send(self):
        chain = FakeChain(self.plan)
        self.assertTrue(m.b4_needed(chain, self.plan))
        chain.verifier = self.plan['addresses']['OverIssueFraudProofVerifier']
        self.assertFalse(m.b4_needed(chain, self.plan))
        self.assertTrue(all(method == 'eth_call' for method, _ in chain.calls))
        self.assertEqual(self.plan['steps'][-1]['id'], 'D.old_aggregator.transfer')

    def test_exact_drains(self):
        for label in ('deployer','anni'):
            amount = self.pin['operatorBalances'][self.pin['senders'][label]['address']]
            self.assertEqual(self.step('A15.'+label)['tx']['data'], a.calldata('withdraw(uint256)', amount))
        self.assertEqual(self.step('A15.revenue')['tx']['data'],
            a.calldata('withdrawProtocolRevenue(address,uint256)', u.DEPLOYER, self.pin['protocolRevenue']-m.BUFFER))
        self.assertEqual(a.qty(self.step('A13.stake')['tx']['value']), 9*10**17)

    def test_drain_refusals(self):
        for field, value in (('totalTrackedBalance', 0), ('protocolRevenue', -1)):
            bad = copy.deepcopy(self.pin)
            bad[field] = value
            with self.assertRaises(a.Gate):
                m.build_plan(bad, self.inputs)
        bad = copy.deepcopy(self.pin)
        bad['operatorBalances'][base.HOLDER] = 1
        bad['totalTrackedBalance'] += 1
        with self.assertRaises(a.Gate):
            m.build_plan(bad, self.inputs)

    def test_missing_external_refused(self):
        for path in (None, Path(self.tmp.name)/'absent.json'):
            with self.assertRaises(a.Gate):
                m.external(path)
        with self.assertRaises(a.Gate):
            m.build_plan(self.pin)
        for key in ('verifier', 'pop'):
            data = copy.deepcopy(self.data)
            del data[key]
            self.path.write_text(json.dumps(data))
            with self.assertRaises(a.Gate):
                m.external(self.path)

    def test_pop_binding(self):
        for field, value in (('aggregator', a.ZERO), ('pinBlockHash', a.ZERO32)):
            bad = copy.deepcopy(self.inputs)
            bad['data']['pop'][0][field] = value
            with self.assertRaises(a.Gate):
                m.build_plan(self.pin, bad)

    def test_external_hash(self):
        self.assertEqual(self.inputs['sha256'], hashlib.sha256(self.path.read_bytes()).hexdigest())
        self.path.write_text(self.path.read_text()+'\n')
        new = m.external(self.path)
        self.assertNotEqual(new['sha256'], self.inputs['sha256'])
        with self.assertRaises(a.Gate):
            m.validate_plan(self.plan, new)

    def test_partial_or_mutated_plan_refused(self):
        for mutation in (lambda p:p['steps'].pop(), lambda p:p['steps'][0]['tx'].update(nonce='0x1'),
                         lambda p:p['operations']['activation']['data'].pop(2),
                         lambda p:p.update(unexpected=True)):
            bad = copy.deepcopy(self.plan)
            mutation(bad)
            with self.assertRaises(a.Gate):
                m.validate_plan(bad, self.inputs)

    def test_each_step_concrete_and_readback(self):
        for s in self.plan['steps']:
            self.assertTrue(s['readbacks'])
            self.assertIn(s['sender'], set(self.pin['senders']) | ({'owner'} if s.get('phase') == 'C' else set()))
            self.assertTrue(s['tx']['data'].startswith('0x'))
        self.assertTrue(any(s['id'] == 'A12a' for s in self.plan['steps']))
        self.assertTrue(any(s['id'] == 'A12b' for s in self.plan['steps']))

    def test_remote_execution_refused(self):
        with self.assertRaises(a.Gate):
            m.run_manifest(None, FakeChain(self.plan), self.plan, Path(self.tmp.name))


    def test_budget_includes_stake_and_deposit(self):
        for s in self.plan['steps']:
            s['tx']['gas'] = hex(100000)
            for tx in s.get('variants', {}).values(): tx['gas'] = hex(100000)
        m.budget(self.plan)
        d_steps = [s for s in self.plan['steps'] if s['sender'] == 'deployer']
        pc = self.plan['phaseC']
        values = (18*10**17+2*m.PC_STAKE+sum(pc['entryPointTopUps'].values())+pc['ownerTopUp']+pc['bundlerTopUp'])
        self.assertEqual(pc['deployerValueWei'], values)
        self.assertEqual(self.plan['budgetsWei']['deployer'], len(d_steps)*100000*a.MAX_FEE+values)
        # DSR F-02 (2026-11-05): exact shortfall, 1 wei short; keys {requiredWei, balanceWei, shortfallWei}.
        required = self.plan['budgetsWei']['deployer']
        self.plan['pin']['senders']['deployer']['balance'] = required-1
        with assert_stop(self, 'budget_deployer') as caught:
            m.budget(self.plan)
        self.assertEqual(caught.exception.record['gate'], 'budget_deployer')
        self.assertEqual(caught.exception.record['observed'],
                         dict(balanceWei=required-1, requiredWei=required, shortfallWei=1))

    def test_runtime_patches_named_immutables(self):
        art = dict(runtimeIdentity=dict(artifactRuntime='0x'+'00'*32+'ab',
            ranges=[dict(name='REGISTRY', start=0, length=32)]))
        self.assertEqual(m.runtime_bytes(art, {'REGISTRY':int(u.REG, 16)}), '0x'+u.REG[2:].zfill(64)+'ab')
        with self.assertRaises(a.Gate):
            m.runtime_bytes(art, {})

    def test_pop_selector_and_duplicates_refused(self):
        for mutate in (lambda d:d['pop'][0].update(calldata='0xdeadbeef'),
                       lambda d:d['pop'].__setitem__(1, d['pop'][0])):
            data = copy.deepcopy(self.data)
            mutate(data)
            self.path.write_text(json.dumps(data))
            with self.assertRaises(a.Gate):
                m.external(self.path)

    def test_b2_unknown_history_refused(self):
        chain = FakeChain(self.plan)
        with patch.object(u, 'scan', return_value=[]), self.assertRaises(a.Gate):
            m.b2_gate(chain, self.plan, '0x150')

    def test_all_manifest_stages_require_remote_gas_evidence(self):
        for stage in ('a7', 'b4', 'full'):
            inputs = m.external(self.path, stage)
            sources = {'a7': self.staged_chain()[2]['a7']} if stage == 'b4' else None
            plan = m.build_plan(self.pin, inputs, stage, sources)
            derived = copy.deepcopy(plan)
            for step in plan['steps']:
                freeze_gas(plan, step)
            m.budget(plan)
            m.validate_plan(plan, inputs, frozen=True)
            with patch.object(m, 'build_plan', return_value=derived):
                for index, step in enumerate(plan['steps']):
                    for variant in ('apply', 'placeholder') if 'variants' in step else ('apply',):
                        bad = copy.deepcopy(plan)
                        target = bad['steps'][index]
                        if variant == 'placeholder':
                            target = target['variantMeasurements']['placeholder']
                        del target['estimateGas']
                        with self.subTest(stage=stage, step=step['id'], variant=variant):
                            with assert_stop(self, 'remote_estimate_missing') as caught:
                                m.validate_plan(bad, inputs, frozen=True)
                            self.assertEqual(caught.exception.record['gate'], 'remote_estimate_missing')
                            self.assertEqual(caught.exception.record['step'], step['id'])

    def test_no_gas_or_budget_fabricated(self):
        self.assertNotIn('budgetsWei', self.plan)
        self.assertTrue(all('gas' not in s['tx'] for s in self.plan['steps']))

    def test_sampled_deployer_only(self):
        for sampled in (sorted([u.DEPLOYER, ANNI]), [ANNI], [], [u.DEPLOYER, u.DEPLOYER]):
            with self.subTest(sampled=sampled):
                data = copy.deepcopy(self.data)
                data['sampled'] = sampled
                with assert_stop(self, 'sampled_deployer_only') as caught:
                    m.validate_external(data)
                self.assertEqual(caught.exception.record['gate'], 'sampled_deployer_only')

    def test_pin_pending_token_eta(self):
        pin = copy.deepcopy(self.pin)
        pin['pendingAPNTsTokenEta'] = 1794226597
        with assert_stop(self, 'pin_pending_token_eta') as caught:
            m.build_plan(pin, self.inputs)
        self.assertEqual(caught.exception.record['gate'], 'pin_pending_token_eta')

    def test_unpause_outside_6d_refused(self):
        m.validate_plan(self.plan, self.inputs)
        plan = copy.deepcopy(self.plan)
        step = next(s for s in plan['steps'] if s['id'].startswith('A14.'))
        step['tx']['data'] = a.calldata('setOperatorPaused(address,bool)', u.DEPLOYER, 'false')
        with assert_stop(self, 'manifest_tx_data') as caught:
            m.validate_plan(plan, self.inputs)
        self.assertEqual(caught.exception.record['gate'], 'manifest_tx_data')

    def test_unpause_only_in_activation_batch(self):
        # DSR Q4: setOperatorPaused(op,false) for any op appears only in the 6c/6d activation batch, and only for D.
        sel = a.calldata('setOperatorPaused(address,bool)', u.DEPLOYER, 'false')[2:10]
        unpause = re.compile(sel+'0{24}([0-9a-f]{40})'+'0'*64)
        found = {s['id']: unpause.findall(s['tx']['data'].lower()) for s in self.plan['steps']}
        found = {k: v for k, v in found.items() if v}
        self.assertEqual(found, {'activation_schedule_exec': [u.DEPLOYER[2:]], 'activation_execute_exec': [u.DEPLOYER[2:]]})
        self.assertEqual(unpause.findall(''.join(self.plan['operations']['activation']['data']).lower()), [u.DEPLOYER[2:]])

    def test_unsampled_operator_remains_paused(self):
        checks = []
        def capture(rpc, pred, timestamp=None):
            checks.append(pred)
        with patch.object(a, 'call', return_value=a.cast('abi-encode', 'c(uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256)',
                          *u.GAS, 0, 0, 0, 0, 0)), patch.object(m, 'check_predicate', side_effect=capture):
            m.batch_readback(None, self.plan, True, 100)
        pauses = {p['args'][0]:p['expected'] for p in checks if p.get('signature') == 'operators(address)'}
        self.assertEqual(pauses, {u.DEPLOYER:0, ANNI:1, base.HOLDER:1})

    def test_solvency_probe_accrues_before_withdrawing(self):
        for backing in (0, m.BUFFER):
            state = dict(tracked=m.BUFFER, revenue=m.BUFFER, backing=backing, deposit=0, queued=False)
            history = []
            def rpc(method, params):
                history.append(method)
                if method == 'evm_snapshot': return 'snap'
                if method == 'evm_revert': return True
                raise AssertionError(method)
            rpc.local = True
            def balances(*args):
                return dict(totalTrackedBalance=state['tracked'], protocolRevenue=state['revenue'],
                            operatorBalances={u.DEPLOYER:state['deposit']})
            def receipt(r, tx):
                data = tx
                if data == a.calldata('deposit(uint256)', 10**18):
                    state['deposit'] += 10**18
                    state['backing'] += 10**18
                    state['tracked'] += 10**18
                if data == a.calldata('queueSlash(address)', u.DEPLOYER): state['queued'] = True
                if data.startswith(a.keccak('slashOperator(address,uint8,uint256,string)')[:10]):
                    self.assertTrue(state['queued'])
                    state['revenue'] += m.BUFFER
                    state['deposit'] -= m.BUFFER
                if data.startswith(a.keccak('withdrawProtocolRevenue(address,uint256)')[:10]):
                    if state['revenue']-m.BUFFER < m.BUFFER:
                        raise a.Gate('InsufficientRevenue', state['revenue'], 2*m.BUFFER)
                    state['revenue'] -= m.BUFFER
                    state['tracked'] -= m.BUFFER
                    state['backing'] -= m.BUFFER
                return {}
            initial = dict(balances(), cappedBalance=backing)
            with patch.object(a, 'address', return_value=u.SAFE), \
                 patch.object(u, 'fixture_tx', side_effect=lambda r,s,t,d:d), \
                 patch.object(u, 'receipt', side_effect=receipt), patch.object(m, 'balances', side_effect=balances), \
                 patch.object(a, 'word', side_effect=lambda r,t,s,*args: state['revenue'] if s == 'protocolRevenue()' else state['backing']), \
                 patch.object(a, 'block_data', return_value={'timestamp':'0x1'}), patch.object(u, 'wait_until'):
                result = m.solvency_probe(rpc, self.plan, initial)
            self.assertEqual(result['allSolvent'], backing == m.BUFFER)
            self.assertEqual([x['shortfall'] for x in result['observations']], [m.BUFFER-backing]*3)
            self.assertEqual(history, ['evm_snapshot', 'evm_revert'])

    def test_all_requested_controls_registered(self):
        self.assertEqual(set(m.CONTROLS), {'early_unpause','factory_binding','early_bls','early_swap',
            'funded_swap','old_reputation','registry_nonowner','early_verifier','repeat_verifier','verifier_placeholder','verifier_frontrun','verifier_wrong','unbacked_swap','owner_handover'})


    def rehearse_fake(self, already_applied=False, solvent=True, frontrun=False, fault=None, gate='post_swap_solvency'):
        state = dict(now=self.pin['timestamp'], safe=self.pin['safeNonce'], next=None,
                     nonces={v['address']:v['nonce'] for v in [*self.pin['senders'].values(), self.pin['phaseC']['owner']]}, etas={})
        funded = lambda: m.BUFFER+(self.plan['phaseC']['operatorTopUp'] if 'C2.deposit' in dict(sent) else 0)
        def accounting(*args):
            balances = {x:0 for x in self.pin['pauseList']}
            if 'C2.deposit' in dict(sent): balances[u.DEPLOYER] = self.plan['phaseC']['operatorTarget']
            return dict(totalTrackedBalance=funded(), protocolRevenue=m.BUFFER+int(fault == 'after6d'), operatorBalances=balances)
        sent, waits, gates = [], [], []
        def rpc(method, params):
            if method == 'anvil_impersonateAccount': return True
            if method == 'evm_setNextBlockTimestamp':
                state['next'] = params[0]
                return True
            if method == 'evm_mine':
                state['now'] = state['next']
                waits.append(state['now'])
                return '0x0'
            if method == 'eth_getTransactionByHash': return {}
            if method == 'eth_estimateGas': return hex(21000)
            raise AssertionError((method, params))
        rpc.local = True
        rpc.engine_process = SimpleNamespace()
        def word(r, target, sig, *args, **kw):
            if sig == 'nonce()': return state['safe']
            if sig == 'getTimestamp(bytes32)': return state['etas'][args[0]]
            if sig == 'pendingFraudProofVerifierReadyAt()': return state['verifierEta']
            if sig == 'balanceOf(address)': return funded()
            raise AssertionError(sig)
        def measure(remote, r, plan, step, overrides, ts, calibrate):
            step.update(executionTimestamp=ts, estimateGas=100000, localEstimateGas=100000,
                        forkGasUsed=90000, minedGasMinimum=80000 if step['tx']['to'] is None else None,
                        rrRequired=False, rrWitness=None)
            step['tx']['gas'] = hex(130000)
            step['gasEvidence'] = gas_evidence(plan, step)
            return {}
        def receipt(r, tx, status='0x1'):
            step = next(x for x in self.plan['steps'] if x['tx']['nonce'] == tx['nonce'] and x['tx']['from'] == tx['from'])
            sid = step['id']
            self.assertEqual(state['nonces'][tx['from']], a.qty(tx['nonce']))
            state['nonces'][tx['from']] += 1
            state['now'] = state['next'] or state['now']
            state['safe'] += int(sid.endswith('_exec'))
            if sid.endswith('schedule_exec'):
                state['etas'][self.plan['operations'][step['operation']]['id']] = state['now']+u.DELAY
            if sid == 'A12b': state['verifierEta'] = state['now']+4*m.DAY
            if sid == 'upgrade_execute_exec': state['gasEta'] = state['now']+u.DELAY
            sent.append((sid, state['now']))
            return dict(status='0x0' if sid == 'B4' and frontrun else '0x1', gasUsed=hex(21000 if tx['data'] == '0x' and sid == 'B4' else 90000), blockNumber='0x150', transactionHash='0x'+'12'*32, logs=[])
        def pre(r, plan, step, context, measured=False):
            if step['id'] == 'activation_execute_exec':
                self.assertIn('upgradeBlock', context)
                context['B2'] = {'checked':True}
                gates.append(len(sent))
            return step['tx']
        def controls(r, plan, sid, output):
            if sid == 'after_upgrade_execute_exec':
                self.assertEqual(sent[-1][0], 'upgrade_execute_exec')
            if sid == 'after_B4': output.extend(dict(control=x) for x in m.CONTROLS if x != 'owner_handover')
        def phase_c_controls(r, plan, sid, output, context):
            if sid == 'after_phase_c':
                self.assertEqual(sent[-1][0], plan['phaseC']['steps'][-1])
                self.assertEqual({'activation_execute_exec', 'B4'} <= context['passed'], True)
                output.extend(dict(control=x) for x in m.PC_CONTROLS[int(fault == 'drop_control'):])
        patches = [
            patch.object(m, 'phase_c_controls', side_effect=phase_c_controls),
            patch.object(m, 'phase_c_accounting', side_effect=lambda r, plan: dict(accounting(), cappedBalance=funded()+int(fault == 'drift'))),
            patch.object(m, 'sp_attempt_precheck', return_value={'synthetic': True}),
            patch.object(a, 'process_alive'), patch.object(a, 'nonce', side_effect=lambda r,who,*args:state['nonces'][who]),
            patch.object(a, 'word', side_effect=word),
            patch.object(a, 'block_data', side_effect=lambda *args:dict(timestamp=hex(state['now']), number='0x150', gasLimit='0xbebc200')),
            patch.object(a, 'call', side_effect=lambda *args, **kw:a.cast('abi-encode', 'c(uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256)',
                *u.GAS, *u.GAS, state['gasEta'])),
            patch.object(a, 'mined_identity'), patch.object(a, 'trace_overrides'),
            patch.object(m, 'b4_controls', return_value=[]),
            patch.object(u, 'probe', return_value=({'status':'0x1', 'gasUsed':hex(21000)}, None)),
            patch.object(u, 'fresh_gas', return_value={'mode': 'pinned-consistency', 'block': self.plan['pin']['block']}), patch.object(u, 'measure_step', side_effect=measure), patch.object(u, 'receipt', side_effect=receipt),
            patch.object(m, 'handover_controls', return_value={'control':'owner_handover'}),
            patch.object(m, 'handover_trace'), patch.object(m, 'mint_trace'), patch.object(u, 'safe_trace'), patch.object(u, 'safe_exec_events'), patch.object(u, 'check_inventory'),
            patch.object(u, 'assert_frozen'), patch.object(m, 'pre_send', side_effect=pre),
            patch.object(m, 'controls_at', side_effect=controls), patch.object(m, 'check_predicate', return_value=True), patch.object(m, 'batch_readback', return_value={}),
            patch.object(m, 'b4_needed', return_value=not already_applied),
            patch.object(m, 'balances', side_effect=accounting),
            patch.object(m, 'fraud_rehearsal', return_value={'synthetic':True}),
            patch.object(m, 'dvt_closing', return_value={'closing':True}),
            patch.object(m, 'solvency_probe', return_value={'allSolvent':solvent})]
        with contextlib.ExitStack() as stack:
            for p in patches: stack.enter_context(p)
            if solvent and fault is None:
                m.run_manifest(None, rpc, self.plan, Path(self.tmp.name))
                self.assertEqual(u.fresh_gas.call_count, len(self.plan['steps']))
                self.assertEqual([c.args[1]['id'] for c in u.fresh_gas.call_args_list],
                                 [s['id'] for s in self.plan['steps']])
                self.assertEqual(sum(call.args[2] == 'after_upgrade_execute_exec'
                                     for call in m.controls_at.call_args_list), 1)
                m.fraud_rehearsal.assert_called_once_with(rpc, self.plan)
                m.dvt_closing.assert_called_once_with(rpc, self.plan)
            else:
                with assert_stop(self, gate) as caught:
                    m.run_manifest(None, rpc, self.plan, Path(self.tmp.name))
                self.assertEqual(caught.exception.record['gate'], gate)
        return sent, waits, gates, state

    def test_rehearsal_phase_c_controls_complete(self):
        sent, _, _, _ = self.rehearse_fake(fault='drop_control', gate='phase_c_controls_complete')
        self.assertEqual(sent[-1][0], 'D.old_aggregator.transfer')

    def test_rehearsal_after_6d_accounting(self):
        sent, _, _, _ = self.rehearse_fake(fault='after6d', gate='after_6d_accounting')
        self.assertEqual(sent[-1][0], 'activation_execute_exec')

    def test_rehearsal_accounting_unchanged_since_phase_c(self):
        self.rehearse_fake(fault='drift', gate='accounting_unchanged_since_phase_c')

    def test_rehearsal_funding_rechecked_after_phase_c(self):
        from test_manifest_phase_c import Chain
        def drained(rpc, plan):
            chain = Chain(plan, 'after_phase_c')
            chain.balances[chain.B] = plan['phaseC']['bundlerTarget']-1
            # Use real read helpers with the offline chain, including the production gate.
            with patch.object(a, 'word', base_word), patch.object(a, 'block_data', base_block), chain.patches()[0]:
                return REAL_FUNDING_GATE(chain, plan)
        base_word, base_block = a.word, a.block_data
        with patch.object(m, 'funding_gate', side_effect=drained):
            sent, _, _, _ = self.rehearse_fake(fault='funding', gate='C_funding_bundler')
        self.assertEqual(sent[-1][0], self.plan['phaseC']['steps'][-1], 'C_funding_bundler')

    def test_rehearsal_orders_all_steps_warps_and_b2(self):
        sent, waits, gates, state = self.rehearse_fake()
        self.assertEqual([x[0] for x in sent], [s['id'] for s in self.plan['steps']])
        times = dict(sent)
        self.assertGreaterEqual(times['upgrade_execute_exec'], times['upgrade_schedule_exec']+u.DELAY)
        self.assertGreaterEqual(times['activation_schedule_approve'], times['upgrade_execute_exec']+u.DELAY)
        self.assertGreaterEqual(times['activation_execute_exec'], self.pin['pendingAPNTsTokenEta'])
        self.assertGreaterEqual(times['activation_execute_exec'], times['activation_schedule_exec']+u.DELAY)
        self.assertGreaterEqual(times['D.registry_execute_exec'], times['D.registry_schedule_exec']+u.DELAY)
        self.assertGreaterEqual(times['B4'], times['A12b']+4*m.DAY)
        # Phase C runs after 6d and B4 and before every Phase D transaction (§3, §4).
        ids = [x[0] for x in sent]
        c_ids = self.plan['phaseC']['steps']
        self.assertEqual(ids[ids.index('B4')+1:ids.index('B4')+1+len(c_ids)], c_ids)
        self.assertEqual(ids[ids.index('B4')+1+len(c_ids)], 'D.registry.transfer')
        for sid in c_ids:
            self.assertGreater(times[sid], times['activation_execute_exec'])
            self.assertGreaterEqual(times[sid], self.pin['pendingAPNTsTokenEta'])
        self.assertEqual(gates, [[x[0] for x in sent].index('activation_execute_exec')]*2)
        self.assertTrue(waits)
        m.validate_plan(self.plan, self.inputs, frozen=True)

    def test_rehearsal_b4_placeholder_consumes_reserved_nonce(self):
        sent, _, _, state = self.rehearse_fake(already_applied=True)
        self.assertIn('B4', dict(sent))
        self.assertFalse(self.plan['steps'][-1]['skipped'])
        self.assertEqual(state['nonces'][u.DEPLOYER], a.qty(self.plan['steps'][-1]['tx']['nonce'])+1)
        m.validate_plan(self.plan, self.inputs, frozen=True)

    def test_rehearsal_frontrun_status_zero_continues(self):
        sent, _, _, state = self.rehearse_fake(frontrun=True)
        result = json.loads((Path(self.tmp.name)/'manifest-simulate.json').read_text())
        self.assertEqual(result['status'], 'PASS')
        record = next(x for x in result['steps'] if x['step'] == 'B4')
        self.assertEqual((record['step'], record['variant'], record['receipt']['status']), ('B4', 'apply', '0x0'))
        # Phase C funding is re-read at the end of Phase C (stubbed here; real gate in the Phase C suite).
        self.assertEqual(result['phaseCFunding'], {'synthetic': 'funding'})
        self.assertEqual(state['nonces'][u.DEPLOYER], a.qty(self.plan['steps'][-1]['tx']['nonce'])+1)

    def test_rehearsal_stops_on_solvency_without_pass_record(self):
        sent, _, _, _ = self.rehearse_fake(solvent=False)
        self.assertEqual(sent[-1][0], 'D.old_aggregator.transfer')
        self.assertTrue((Path(self.tmp.name)/'manifest-solvency.json').exists())
        self.assertFalse((Path(self.tmp.name)/'manifest-simulate.json').exists())


    def test_unsigned_dvt_proposal_stops(self):
        # Superseded fixture shape: the getter inventory is now authoritative (see stale tests).
        self.assertEqual(len(self.stale_proposals()), 9)
        with assert_stop(self, 'dvt_stale_proposal_listed') as caught:
            self.stale_proposals(lambda rows: rows[7].update(executed=False))
        self.assertEqual(caught.exception.record['gate'], 'dvt_stale_proposal_listed')

    def stale_proposals(self, edit=None, next_id=10, omit_log=()):
        rows = {i: dict(operator=m.STALE_PROPOSAL_OPERATOR, level=1, executed=i in (3, 7),
                        evidence=m.STALE_PROPOSALS[1 if i < 7 else 8][1]) for i in range(1, 10)}
        if edit:
            edit(rows)
        logs = [dict(topics=[a.keccak('ProposalCreated(uint256,address,uint8)'), '0x'+format(i, '064x')])
                for i in rows if i not in omit_log]
        def call(rpc, target, sig, proposal, block=None):
            self.assertEqual((target, sig), (DVT, 'proposals(uint256)'))
            r = rows.get(proposal, dict(operator=a.ZERO, level=0, executed=False, evidence=0, exists=False))
            return a.cast('abi-encode', 'c(address,uint8,string,bool,bool,bytes32)', r['operator'], r['level'],
                          'fixture', str(r['executed']).lower(), str(r.get('exists', True)).lower(), '0x'+format(r['evidence'], '064x'))
        def word(rpc, target, sig, *args, **kw):
            self.assertEqual((target, sig), (DVT, 'nextProposalId()'))
            return next_id
        with patch.object(u, 'creation', return_value=1), patch.object(u, 'scan', return_value=logs), \
             patch.object(a, 'call', side_effect=call), patch.object(a, 'word', side_effect=word):
            return m.dvt_activity(None, DVT, '0x100')

    def test_stale_dvt_proposals_accepted_only_exactly(self):
        self.assertEqual(len(self.stale_proposals()), 9)
        def unexecuted(i): return lambda rows: rows[i].update(executed=False)
        def extra(rows): rows[10] = dict(rows[8])
        def extra_executed(rows): rows[10] = dict(rows[7])
        def operator(rows): rows[2].update(operator=u.DEPLOYER)
        def level(rows): rows[4].update(level=2)
        def evidence(rows): rows[8].update(evidence=m.STALE_PROPOSALS[1][1])
        def sibling(rows): rows[3].update(evidence=m.STALE_PROPOSALS[8][1])
        def sibling_level(rows): rows[7].update(level=2)
        def sibling_operator(rows): rows[3].update(operator=u.DEPLOYER)
        def stale_executed(rows): rows[8].update(executed=True)
        cases = [(dict(edit=unexecuted(3)), 'dvt_stale_proposal_listed'),
                 (dict(edit=extra), 'dvt_proposal_inventory'), (dict(edit=extra_executed), 'dvt_proposal_inventory'),
                 (dict(omit_log=(2,)), 'dvt_proposal_inventory'), (dict(omit_log=tuple(range(1, 10))), 'dvt_proposal_inventory'),
                 (dict(edit=operator), 'dvt_stale_proposal_shape'), (dict(edit=level), 'dvt_stale_proposal_shape'),
                 (dict(edit=evidence), 'dvt_stale_proposal_shape'), (dict(edit=sibling), 'dvt_stale_sibling_executed'),
                 (dict(edit=sibling_level), 'dvt_stale_sibling_executed'), (dict(edit=sibling_operator), 'dvt_stale_sibling_executed'),
                 (dict(edit=stale_executed), 'dvt_stale_open_set'), (dict(next_id=11), 'dvt_stale_next_id')]
        for kw, gate in cases:
            with self.subTest(gate=gate, case=getattr(kw.get('edit'), '__name__', kw)):
                with assert_stop(self, gate) as caught:
                    self.stale_proposals(**kw)
                self.assertEqual(caught.exception.record['gate'], gate)

    def never_recheck_change(self, closing, field='neverGrantedReads', gate='old_owner_never_granted_recheck'):
        plan = copy.deepcopy(self.plan)
        plan['pin']['oldActivity']['dvtProposals'] = [{'recorded':True}]
        row = plan['pin']['oldOwnerIsolation'][field][-1]
        # oldRoleReads rows are OLD's memberships: a post-pin grant to OLD (e.g. via safeMintForRole).
        holder = row.get('holder', m.isolation.OLD)
        rpc = old_timelock_rpc(plan['pin'],'0x200',
            (row['target'],'hasRole(bytes32,address)',[row['role'],holder],isolation_tests.raw([1])))
        rpc.local = True
        with contextlib.ExitStack() as stack:
            for item in self.closing_rpc(plan['pin']['oldAggregator']):
                stack.enter_context(item)
            if not closing:
                # Reach the normal chain guard if the recheck gate is removed.
                original = rpc
                def rpc(method,params):
                    if method == 'eth_chainId': return '0x0'
                    return original(method,params)
                rpc.local = True
                stack.enter_context(patch.object(m,'handover_gate'))
            with assert_stop(self, gate) as caught:
                if closing:
                    m.dvt_closing(rpc,plan)
                else:
                    m.pre_send(rpc,plan,dict(tx={}),{})
            self.assertEqual(caught.exception.record['gate'],gate)

    def test_never_granted_closing_change(self):
        self.never_recheck_change(True)

    def test_never_granted_pre_send_change(self):
        self.never_recheck_change(False)


    def xpnts_owner_change(self, closing):
        for owner in (m.isolation.OLD,m.isolation.OLD_TIMELOCK):
            plan = copy.deepcopy(self.plan)
            plan['pin']['oldActivity']['dvtProposals'] = [{'recorded':True}]
            token = plan['pin']['oldOwnerIsolation']['xpnts'][-1]
            rpc = old_timelock_rpc(plan['pin'],'0x200',
                (token,'communityOwner()',[],isolation_tests.raw([int(owner,16)])))
            original = rpc
            def rpc(method,params):
                if method == 'eth_chainId': return '0x0'
                return original(method,params)
            rpc.local = True
            with contextlib.ExitStack() as stack:
                for item in self.closing_rpc(plan['pin']['oldAggregator']): stack.enter_context(item)
                stack.enter_context(patch.object(m,'handover_gate'))
                with assert_stop(self, 'old_owner_xpnts_owner_recheck') as caught:
                    if closing: m.dvt_closing(rpc,plan)
                    else: m.pre_send(rpc,plan,dict(tx={}),{})
                self.assertEqual(caught.exception.record['gate'],'old_owner_xpnts_owner_recheck')

    def test_xpnts_owner_closing(self):
        self.xpnts_owner_change(True)

    def test_xpnts_owner_pre_send(self):
        self.xpnts_owner_change(False)

    def test_old_role_closing_change(self):
        self.never_recheck_change(True, 'oldRoleReads', 'old_owner_role_recheck')

    def test_old_role_pre_send_change(self):
        self.never_recheck_change(False, 'oldRoleReads', 'old_owner_role_recheck')

    def closing_rpc(self, pointer, activity='pin', executed=(), stray=None):
        # Every read must name the one closing block (0x200); `stray` points one target elsewhere.
        getters = {u.REG: 'blsAggregator()', DVT: 'BLS_AGGREGATOR()', COMMITTEE: 'blsAggregator()'}
        def address(r, target, sig, block=None):
            self.assertEqual((sig, block), (getters[target], '0x200'))
            return u.SP if target == stray else pointer
        real_call = a.call
        def call(r, target, sig, *args, block=None):
            if (target, sig) != (DVT, 'proposals(uint256)'):
                return real_call(r, target, sig, *args, block=block)
            proposal, = args
            self.assertEqual((target, sig, block), (DVT, 'proposals(uint256)', '0x200'))
            return a.cast('abi-encode', 'c(address,uint8,string,bool,bool,bytes32)', m.STALE_PROPOSAL_OPERATOR, 1,
                          'fixture', str(proposal in executed).lower(), 'true', a.ZERO32)
        def activity_at(r, target, block):
            self.assertEqual((target, block), (DVT, '0x200'))
            return [{'recorded': True}] if activity == 'pin' else [{'changed': True}]
        return [patch.object(a, 'address', side_effect=address), patch.object(a, 'call', side_effect=call),
                patch.object(a, 'block_data', return_value=dict(number='0x200')),
                patch.object(m, 'dvt_activity', side_effect=activity_at),
                patch.object(m, 'discovery_coverage', side_effect=lambda plan, passed: copy.deepcopy(plan['pin']))]

    def check_old_timelock(self, gate, bad=None, pin=None):
        pin = pin or self.pin
        for closing in (False, True):
            block = '0x200' if closing else pin['stateBlock']
            rpc = old_timelock_rpc(pin, block, bad)
            with self.subTest(closing=closing), contextlib.ExitStack() as stack:
                if closing:
                    plan = copy.deepcopy(self.plan)
                    plan['pin'] = copy.deepcopy(pin)
                    plan['pin']['oldActivity']['dvtProposals'] = [{'recorded': True}]
                    pointer = plan['addresses']['BLSAggregator']
                    for item in self.closing_rpc(pointer): stack.enter_context(item)
                    action = lambda: m.dvt_closing(rpc, plan)
                else:
                    action = lambda: m.old_timelock_holds_nothing(rpc, pin, block)
                expected = 'old_owner_xpnts_owner_recheck' if closing and bad and bad[1] == 'communityOwner()' else gate
                with assert_stop(self, expected) as caught: action()
                self.assertEqual(caught.exception.record['gate'], expected)

    def assert_timelock_build_gate(self, gate, mutate):
        changed = copy.deepcopy(self.pin)
        mutate(changed)
        try:
            with assert_stop(self, gate) as caught:
                m.build_plan(changed, self.inputs)
        except (KeyError, TypeError, IndexError) as error:
            self.fail(f'Expected named gate {gate}, got {type(error).__name__}')
        self.assertEqual(caught.exception.record['gate'], gate)

    def test_old_timelock_required(self):
        self.assert_timelock_build_gate('old_timelock_required', lambda p: p.pop('oldTimelock'))

    def test_old_timelock_schema(self):
        self.assert_timelock_build_gate('old_timelock_schema', lambda p: p['oldTimelock'].update(extra=True))

    def test_old_timelock_block(self):
        self.assert_timelock_build_gate('old_timelock_block', lambda p: p['oldTimelock']['reads'][0].update(block='0x123'))

    def test_old_timelock_replay_reads(self):
        self.assert_timelock_build_gate('old_timelock_replay', lambda p: p['oldTimelock']['reads'][0].update(target=u.SP))

    def test_old_timelock_replay_owners(self):
        self.assert_timelock_build_gate('old_timelock_replay', lambda p: p['oldTimelock']['approvalOwners'].clear())

    def test_old_timelock_unused(self):
        self.assert_timelock_build_gate('old_timelock_unused', lambda p: p['oldTimelock']['reads'].append(copy.deepcopy(p['oldTimelock']['reads'][0])))

    def test_old_timelock_tampered_result(self):
        self.assert_timelock_build_gate('old_timelock_tl_roles', lambda p: p['oldTimelock']['reads'][0].update(result=isolation_tests.raw([1])))

    def test_old_timelock_allowance(self):
        token = self.pin['oldOwnerIsolation']['tokens'][0]
        bad = (token, 'allowance(address,address)', [u.SAFE, m.isolation.OLD_TIMELOCK], isolation_tests.raw([1]))
        self.check_old_timelock('old_timelock_allowance', bad)
        def mutate(p):
            p['oldTimelock']['reads'] = [dict(r, result=bad[3]) if
                (r.get('target'), r.get('signature'), r.get('args')) == bad[:3] else r for r in p['oldTimelock']['reads']]
        self.assert_timelock_build_gate('old_timelock_allowance', mutate)

    def approval_rpc(self, block, amount=1, incomplete=False, malformed=False):
        token = self.pin['oldOwnerIsolation']['tokens'][0]
        holder = '0x'+'ac'*20
        self.assertNotIn(holder, m.isolation.allowance_holders())
        baseline = old_timelock_rpc(self.pin, block,
            (token, 'allowance(address,address)', [holder, m.isolation.OLD_TIMELOCK], isolation_tests.raw([amount])))
        topic = a.keccak('Approval(address,address,uint256)')
        event = dict(address=token, blockNumber='0x2', removed=malformed,
            topics=[topic, '0x'+holder[2:].zfill(64), '0x'+m.isolation.OLD_TIMELOCK[2:].zfill(64)],
            data=isolation_tests.raw([1]))
        def rpc(method, params):
            if method == 'eth_getLogs' and params[0]['topics'][0] == topic:
                query = params[0]
                self.assertEqual(query['topics'], [topic, None, event['topics'][2]])
                if incomplete and query['fromBlock'] == '0x1' and query['toBlock'] == block:
                    return []
                return [event] if query['address'] == token and a.qty(query['fromBlock']) <= 2 <= a.qty(query['toBlock']) else []
            return baseline(method, params)
        return rpc, token, holder

    def test_old_timelock_external_approval(self):
        rpc, _, _ = self.approval_rpc(self.pin['stateBlock'])
        with assert_stop(self, 'old_timelock_allowance') as caught:
            m.old_timelock_holds_nothing(rpc, self.pin, self.pin['stateBlock'])
        self.assertEqual(caught.exception.record['gate'], 'old_timelock_allowance')

    def test_old_timelock_external_approval_closing(self):
        rpc, _, _ = self.approval_rpc('0x200')
        plan = copy.deepcopy(self.plan)
        plan['pin']['oldActivity']['dvtProposals'] = [{'recorded': True}]
        with contextlib.ExitStack() as stack:
            for item in self.closing_rpc(plan['addresses']['BLSAggregator']): stack.enter_context(item)
            with assert_stop(self, 'old_timelock_allowance') as caught:
                m.dvt_closing(rpc, plan)
            self.assertEqual(caught.exception.record['gate'], 'old_timelock_allowance')

    def test_old_timelock_external_approval_pre_send(self):
        # Challenge round 2 P2: a pinned Approval owner grants the orphan an allowance after the pin; pre_send
        # (not only closing) must stop before any transaction is sent.
        rpc, token, holder = self.approval_rpc('0x200')
        plan = copy.deepcopy(self.plan)
        plan['pin']['oldTimelock'] = dict(plan['pin'].get('oldTimelock') or {}, approvalOwners={token: [holder]})
        def sender(method, params):
            if method == 'eth_getLogs': return []
            if method == 'eth_chainId': return '0x0'
            return rpc(method, params)
        sender.local = True
        with contextlib.ExitStack() as stack:
            for item in self.closing_rpc(plan['pin']['oldAggregator']): stack.enter_context(item)
            stack.enter_context(patch.object(m, 'handover_gate'))
            with assert_stop(self, 'old_timelock_allowance') as caught:
                m.pre_send(sender, plan, dict(tx={}), {})
            self.assertEqual(caught.exception.record['gate'], 'old_timelock_allowance')

    def test_old_timelock_external_approval_revoked(self):
        rpc, token, holder = self.approval_rpc(self.pin['stateBlock'], amount=0)
        pin = copy.deepcopy(self.pin)
        pin['oldTimelock'] = m.old_timelock_holds_nothing(rpc, pin, pin['stateBlock'])
        self.assertEqual(pin['oldTimelock']['approvalOwners'][token], [holder])
        m.validate_old_timelock(pin)

    def test_old_timelock_approval_incomplete(self):
        rpc, _, _ = self.approval_rpc(self.pin['stateBlock'], incomplete=True)
        with assert_stop(self, 'old_owner_log_partition') as caught:
            m.old_timelock_holds_nothing(rpc, self.pin, self.pin['stateBlock'])
        self.assertEqual(caught.exception.record['gate'], 'old_owner_log_partition')

    def approval_history_control(self, invalid_range):
        pin = copy.deepcopy(self.pin)
        rpc, token, _ = self.approval_rpc(pin['stateBlock'], amount=0, malformed=not invalid_range)
        if invalid_range:
            pin['oldOwnerIsolation']['inventory']['deployedSources'] = [dict(target=token, creationBlock=0)]
        with assert_stop(self, 'old_timelock_approval_history'):
            m.old_timelock_holds_nothing(rpc, pin, pin['stateBlock'])

    def test_old_timelock_approval_history_range(self):
        self.approval_history_control(True)

    def test_old_timelock_approval_history_log(self):
        self.approval_history_control(False)

    def test_old_timelock_approval_creation_bounds(self):
        pin = copy.deepcopy(self.pin)
        tokens = pin['oldOwnerIsolation']['tokens']
        pin['isolationDeployments'] = {token: 3 for token in tokens}
        pin['oldOwnerIsolation']['inventory']['deployedSources'] = [dict(target=tokens[0], creationBlock=2)]
        rpc = old_timelock_rpc(pin, pin['stateBlock'])
        evidence = m.old_timelock_holds_nothing(rpc, pin, pin['stateBlock'])
        for token in tokens:
            queries = [r['params'][0] for r in evidence['reads'] if r.get('method') == 'eth_getLogs'
                       and r['params'][0]['address'] == token]
            self.assertEqual(len(queries), 3)
            self.assertEqual(queries[0]['fromBlock'], '0x2' if token == tokens[0] else '0x3')
            self.assertEqual(queries[0]['toBlock'], pin['stateBlock'])
        pin['oldTimelock'] = evidence
        m.validate_old_timelock(pin)

    def test_old_timelock_log_replay(self):
        for mutation in ('omit', 'mismatch', 'unused', 'owners'):
            pin = copy.deepcopy(self.pin)
            rpc, token, _ = self.approval_rpc(pin['stateBlock'], amount=0)
            pin['oldTimelock'] = m.old_timelock_holds_nothing(rpc, pin, pin['stateBlock'])
            rows = pin['oldTimelock']['reads']
            index = next(i for i, row in enumerate(rows) if row.get('method') == 'eth_getLogs')
            if mutation == 'omit': rows.pop(index)
            if mutation == 'mismatch': rows[index]['params'][0]['address'] = u.SAFE
            if mutation == 'unused': rows.append(copy.deepcopy(rows[index]))
            if mutation == 'owners': pin['oldTimelock']['approvalOwners'][token] = []
            with self.subTest(mutation=mutation):
                with assert_stop(self, 'old_timelock_unused' if mutation == 'unused' else 'old_timelock_replay') as caught:
                    m.validate_old_timelock(pin)
                self.assertEqual(caught.exception.record['gate'],
                    'old_timelock_unused' if mutation == 'unused' else 'old_timelock_replay')

    def check_closing_inventory(self, new_role=False):
        block = '0x200'
        rpc = old_timelock_rpc(self.pin, block)
        new = '0x'+'ab'*20
        role = '0x'+'ab'*32
        def changed(method, params):
            if method == 'eth_getLogs' and params[0]['topics'] == [a.keccak(m.isolation.ROLE_EVENT)] and new_role:
                rows = rpc(method, params)
                return rows + [dict(rows[0], topics=[a.keccak(m.isolation.ROLE_EVENT), role])] if rows else []
            if method == 'eth_call':
                data = params[0]['data']
                if new_role and data == a.calldata('getRoleConfig(bytes32)', role):
                    values = [32]+[0]*13
                    values[10], values[11] = 384, int(m.isolation.OLD_TIMELOCK, 16)
                    return isolation_tests.raw(values)
                # The forbidden state: the orphan holds the role configured after the pin. With the inventory
                # gate removed, a later gate must reject it under another name (an assertion failure, not an error).
                if new_role and data.startswith(a.calldata('hasRole(bytes32,address)', role, '0x'+'00'*20)[:74]):
                    holder = '0x'+data[-40:]
                    return isolation_tests.raw([int(holder == m.isolation.OLD_TIMELOCK.lower())])
                if not new_role and data == a.calldata('getAllTokens()'):
                    tokens = u.addr_array(rpc(method, params)) + [new]
                    return isolation_tests.raw([32, len(tokens), *(int(t, 16) for t in tokens)])
                if params[0]['to'] == new and data == a.calldata('owner()'):
                    return isolation_tests.raw([int(m.isolation.OLD_TIMELOCK, 16)])
            return rpc(method, params)
        plan = copy.deepcopy(self.plan)
        plan['pin']['oldActivity']['dvtProposals'] = [{'recorded': True}]
        with contextlib.ExitStack() as stack:
            for item in self.closing_rpc(plan['addresses']['BLSAggregator']): stack.enter_context(item)
            with assert_stop(self, 'old_timelock_inventory') as caught:
                m.dvt_closing(changed, plan)
            self.assertEqual(caught.exception.record['gate'], 'old_timelock_inventory')

    def test_configured_roles_closing_without_events(self):
        pin = copy.deepcopy(self.pin)
        section = pin['oldOwnerIsolation']
        section['roleHistory'] = {target: [] for target in section['roleHistory']}
        section['configuredRoles'] = sorted(r['value'] for r in section['inventory']['Registry']['roles'])
        rpc = isolation_tests.fixture_rpc(pin)
        with patch.object(m.isolation, 'role_history', return_value=[]), patch.object(
                m.isolation, 'bounded_history_logs', return_value=[]):
            try:
                result = m.closing_timelock_inventory(rpc, pin, pin['stateBlock'])
            except a.Gate as fault:
                self.fail(fault.record['gate'])
        self.assertEqual(result['oldOwnerIsolation']['configuredRoles'], section['configuredRoles'])

    def test_old_timelock_inventory_new_role(self):
        self.check_closing_inventory(new_role=True)

    def test_old_timelock_inventory_new_token(self):
        block = '0x200'
        rpc = old_timelock_rpc(self.pin, block)
        new = '0x'+'ab'*20
        def changed(method, params):
            if method == 'eth_call' and params[0]['data'] == a.calldata('getAllTokens()'):
                tokens = u.addr_array(rpc(method, params)) + [new]
                return isolation_tests.raw([32, len(tokens), *(int(t, 16) for t in tokens)])
            return rpc(method, params)
        # End at inventory validation; a deleted gate must not reach unrelated authority RPCs.
        with assert_stop(self, 'old_timelock_inventory') as caught:
            m.closing_timelock_inventory(changed, self.pin, block)
        self.assertEqual(caught.exception.record['gate'], 'old_timelock_inventory')

    def test_old_timelock_tl_roles(self):
        for role in [a.ZERO32, *(a.keccak(r+'_ROLE') for r in ('PROPOSER', 'EXECUTOR', 'CANCELLER'))]:
            self.check_old_timelock('old_timelock_tl_roles',
                (u.TL, 'hasRole(bytes32,address)', [role, m.isolation.OLD_TIMELOCK], isolation_tests.raw([1])))

    def test_old_timelock_authority(self):
        for target, sig, args, kind in m.isolation.authority_rows(self.pin['oldOwnerIsolation']):
            if target == u.TL: continue
            if kind == 'config':
                values = [32]+[0]*13
                values[10], values[11] = 384, int(m.isolation.OLD_TIMELOCK, 16)
            else:
                values = [1 if kind == 'bool' else int(m.isolation.OLD_TIMELOCK, 16)]
            with self.subTest(target=target, signature=sig):
                self.check_old_timelock('old_timelock_authority', (target, sig, args, isolation_tests.raw(values)))

    def test_old_timelock_safe(self):
        for sig, args, values in [('getOwners()', [], [32, 1, int(m.isolation.OLD_TIMELOCK, 16)]),
                                 ('isModuleEnabled(address)', [m.isolation.OLD_TIMELOCK], [1])]:
            self.check_old_timelock('old_timelock_safe', (u.SAFE, sig, args, isolation_tests.raw(values)))

    def test_old_timelock_holds_nothing(self):
        pin = copy.deepcopy(self.pin)
        section = pin['oldOwnerIsolation']
        target = section['targets']['GToken']
        section['inventory'].setdefault('targetInventories', {})[target] = dict(
            authorities=[], mappings=[], roles=[], hasRole=False)
        self.check_old_timelock('old_timelock_holds_nothing', pin=pin)

    def test_old_timelock_reads_bound_to_block(self):
        for block in (self.pin['stateBlock'], '0x200'):
            result = m.old_timelock_holds_nothing(old_timelock_rpc(self.pin, block), self.pin, block)
            self.assertEqual(result['block'], block)
            self.assertTrue(result['reads'])
            self.assertEqual({r['block'] for r in result['reads']}, {block})
            self.assertEqual({r[0] for r in m.isolation.authority_rows(self.pin['oldOwnerIsolation'])},
                set(self.pin['oldOwnerIsolation']['targets'].values()) | set(self.pin['oldOwnerIsolation']['xpnts']))

    def test_dvt_closing_binds_pointer_and_stale_proposals(self):
        new, old = self.plan['addresses']['BLSAggregator'], self.plan['pin']['oldAggregator']
        cases = [('full', new, {}, None), ('b4', new, {}, None), ('a7', old, {}, None),
                 ('full', old, {}, 'closing_registry_pointer'), ('a7', new, {}, 'closing_registry_pointer'),
                 ('full', new, dict(stray=u.REG), 'closing_registry_pointer'),
                 ('full', new, dict(stray=DVT), 'closing_dvt_pointer'), ('a7', old, dict(stray=DVT), 'closing_dvt_pointer'),
                 ('full', new, dict(stray=COMMITTEE), 'closing_committee_pointer'),
                 ('a7', old, dict(stray=COMMITTEE), 'closing_committee_pointer'),
                 ('full', new, dict(activity='changed'), 'closing_dvt_activity'),
                 ('full', new, dict(executed=(8,)), 'closing_stale_unexecuted')]
        for stage, pointer, extra, gate in cases:
            with self.subTest(stage=stage, pointer=pointer, extra=extra), contextlib.ExitStack() as stack:
                for p in self.closing_rpc(pointer, **extra): stack.enter_context(p)
                plan = copy.deepcopy(dict(self.plan, stage=stage))
                plan['pin'].setdefault('oldActivity', {})['dvtProposals'] = [{'recorded': True}]
                if gate is None:
                    closing = m.dvt_closing(old_timelock_rpc(plan['pin'], '0x200'), plan)
                    self.assertEqual(closing['staleUnexecuted'], [1, 2, 4, 5, 6, 8, 9])
                    self.assertEqual((closing['block'], closing['pointers']),
                                     ('0x200', dict(registry=pointer, dvt=pointer, committee=pointer)))
                else:
                    with assert_stop(self, gate) as caught:
                        m.dvt_closing(old_timelock_rpc(plan['pin'], '0x200'), plan)
                    self.assertEqual(caught.exception.record['gate'], gate)

    def test_old_pointers_require_old_aggregator(self):
        d = dict(dvt=DVT, committee=COMMITTEE)
        old = self.plan['pin']['oldAggregator']
        for bad, gate in ((None, None), ('dvt', 'old_pointer'), ('committee', 'old_pointer'), ('owner', 'pointer_owner')):
            def address(r, target, sig, block):
                if sig == 'owner()': return u.SP if bad == 'owner' else u.DEPLOYER
                return u.SP if {'dvt': DVT, 'committee': COMMITTEE}.get(bad) == target else old
            with self.subTest(bad=bad), patch.object(a, 'address', side_effect=address), \
                 patch.object(u, 'code', return_value='0x00'):
                if gate is None:
                    self.assertEqual(set(m.old_pointers(None, d, old, '0x1')), {DVT, COMMITTEE})
                else:
                    with assert_stop(self, gate) as caught:
                        m.old_pointers(None, d, old, '0x1')
                    self.assertEqual(caught.exception.record['gate'], gate)

    def test_runner_and_collector_wire_closing_and_pointer_gates(self):
        tree = ast.parse(Path(m.__file__).read_text())
        def calls(fn, name):
            node = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == fn)
            return sum(isinstance(c, ast.Call) and isinstance(c.func, ast.Name) and c.func.id == name for c in ast.walk(node))
        self.assertEqual(calls('run_manifest', 'dvt_closing'), 2)
        self.assertEqual(calls('collect', 'old_pointers'), 1)
        self.assertEqual(calls('collect', 'dvt_activity'), 1)

    def test_unhandled_external_fields_do_not_allow_partial_builder(self):
        for key in ('verifier', 'pop', 'committee'):
            inputs = copy.deepcopy(self.inputs)
            del inputs['data'][key]
            with self.assertRaises(a.Gate):
                m.build_plan(self.pin, inputs)

    def test_builder_rejects_empty_sample_and_bindings(self):
        for field in ('sampled', 'bindings'):
            inputs, pin = copy.deepcopy(self.inputs), copy.deepcopy(self.pin)
            if field == 'sampled': inputs['data']['sampled'] = []
            else: pin['bindings'] = {}
            with self.assertRaises(a.Gate): m.build_plan(pin, inputs)

    def test_zero_attestations_refused(self):
        for key in ('ciSha256', 'buildSha256'):
            bad = copy.deepcopy(self.inputs)
            bad['data']['verifier'][key] = '0'*64
            with self.assertRaises(a.Gate): m.build_plan(self.pin, bad)

    def test_extra_deployer_transaction_before_pin_refused(self):
        bad = copy.deepcopy(self.pin)
        bad['senders']['deployer']['nonce'] += 1
        with self.assertRaises(a.Gate): m.build_plan(bad, self.inputs)

    def test_fixed_contract_identities(self):
        for key in ('dvt', 'committee'):
            bad = copy.deepcopy(self.inputs)
            bad['data'][key] = ANNI
            with self.assertRaises(a.Gate): m.build_plan(self.pin, bad)

    def test_verifier_file_provenance(self):
        art = dict(bytecode={'object':'0x6000'}, deployedBytecode=dict(object='0x'+'00'*160,
            immutableReferences={'5519':[dict(start=i, length=32) for i in (0,32,64)],
                                 '5522':[dict(start=i, length=32) for i in (96,128)]}))
        path = Path(self.tmp.name)/'verifier.json'
        path.write_text(json.dumps(art))
        v = dict(self.data['verifier'], artifactPath=str(path))
        with self.assertRaises(a.Gate): self.real_verifier_artifact(v)
        # Exercise parsing using an explicitly synthetic reviewed identity.
        with patch.object(m, 'VERIFIER_SHA256', hashlib.sha256(path.read_bytes()).hexdigest()), \
             patch.object(m, 'VERIFIER_CREATION', a.keccak('0x6000')):
            parsed = self.real_verifier_artifact(v)
            self.assertEqual(len(parsed['runtimeIdentity']['ranges']), 5)
            bad = dict(v, commit='0'*40)
            with self.assertRaises(a.Gate): self.real_verifier_artifact(bad)
            art['deployedBytecode']['immutableReferences'] = {}
            path.write_text(json.dumps(art))
            with patch.object(m, 'VERIFIER_SHA256', hashlib.sha256(path.read_bytes()).hexdigest()):
                with self.assertRaises(a.Gate): self.real_verifier_artifact(v)

    def test_registry_baseline_rejects_head_and_runtime_mismatch(self):
        for baseline in (ART['commit'], 'b'*40):
            def run(cmd, **kw):
                return SimpleNamespace(returncode=0, stdout='' if 'status' in cmd else (ART['commit'] if ('refs/tags/' in cmd[-1] or cmd[-1] == 'HEAD') else baseline))
            pin = dict(self.pin, registryImplementation=ANNI, registryImplementationCode='0xdead')
            with patch.object(m.subprocess, 'run', side_effect=run), \
                 patch.object(a, 'compile_commit', return_value=({'Registry':ART['contracts']['Registry']}, {})):
                with self.assertRaises(a.Gate) as caught:
                    REAL_RELEASE_GATE(self.inputs, ART, pin)
            self.assertEqual(caught.exception.record['gate'],
                'registry_baseline_not_head' if baseline == ART['commit'] else 'registry_baseline_runtime')

    def test_a12a_getters_are_enforced(self):
        step = self.step('A12a')
        for broken in ('AGGREGATOR()', 'REGISTRY()'):
            def call(rpc, target, sig, *args):
                value = ANNI if target == step['creates'] and sig == broken else (
                    self.plan['addresses']['BLSAggregator'] if sig == 'AGGREGATOR()' else u.REG)
                return '0x'+value[2:].zfill(64)
            with patch.object(a, 'call', side_effect=call), patch.object(u, 'code', return_value='0x6000'):
                with self.subTest(broken=broken), self.assertRaises(a.Gate):
                    for pred in step['readbacks']: m.check_predicate(None, pred)

    def test_a12a_runtime_is_enforced(self):
        with patch.object(u, 'code', return_value='0xdead'), self.assertRaises(a.Gate):
            m.check_predicate(None, self.step('A12a')['readbacks'][0])

    def pre_send_fixture(self, bad_runtime=False, bad_buffer=False):
        chain = FakeChain(self.plan)
        chain.local = True
        if bad_buffer: chain.backing = 0
        step = copy.deepcopy(self.step('activation_execute_exec'))
        del step['safeHash']
        self.plan['pin']['oldActivity'] = {'dvtProposals':[]}
        real_word = a.word
        def word(r, t, sig, *args, **kw):
            if sig == 'nonce()': return step['safeNonce']
            if sig == 'pendingAPNTsTokenEta()': return self.pin['pendingAPNTsTokenEta']
            if sig == 'getTimestamp(bytes32)': return self.pin['pendingAPNTsTokenEta']
            return real_word(r, t, sig, *args, **kw)
        def rpc(method, params):
            if method == 'eth_chainId': return hex(a.CHAIN)
            return chain(method, params)
        rpc.local = True
        rpc = with_orphan_reads(rpc, self.plan['pin'], '0x200')
        with patch.object(a, 'nonce', return_value=a.qty(step['tx']['nonce'])), \
             patch.object(a, 'word', side_effect=word), \
             patch.object(a, 'address', side_effect=lambda r,t,s,*args: self.pin['capped'] if s == 'pendingAPNTsToken()' else u.DEPLOYER), \
             patch.object(u, 'safe_state', return_value=self.pin['safe']), patch.object(u, 'governance'), \
             patch.object(u, 'code', side_effect=lambda r,t,*args:'0xdead' if bad_runtime else self.pin['bindings'][t]), \
             patch.object(m, 'old_activity', return_value={}), patch.object(m, 'dvt_activity', return_value=[]), \
             patch.object(u, 'assert_frozen'):
            return m.pre_send(rpc, self.plan, step, dict(frozen=True, upgradeBlock='0x150',
                activationScheduledAt=self.pin['pendingAPNTsTokenEta']-u.DELAY))

    def test_pre_send_real_b2_is_required(self):
        self.pre_send_fixture()
        with assert_stop(self, 'B2_capped_buffer') as caught: self.pre_send_fixture(bad_buffer=True)
        self.assertEqual(caught.exception.record['gate'], 'B2_capped_buffer')

    def test_pre_send_bound_runtime_is_required(self):
        with assert_stop(self, 'bound_runtime') as caught: self.pre_send_fixture(bad_runtime=True)
        self.assertEqual(caught.exception.record['gate'], 'bound_runtime')

    def test_b2a_order_and_missing_mint_refused(self):
        ids = [s['id'] for s in self.plan['steps']]
        self.assertLess(ids.index('upgrade_execute_exec'), ids.index('B2a_approve'))
        self.assertLess(ids.index('B2a_exec'), ids.index('activation_schedule_approve'))
        step = self.step('B2a_exec')
        self.assertEqual(step['safeTarget'], self.pin['capped'])
        self.assertEqual(step['inner'], a.calldata('mint(address,uint256)', u.SP, m.BUFFER))
        self.plan['steps'].remove(step)
        with self.assertRaises(a.Gate): m.validate_plan(self.plan, self.inputs)

    def test_b4_exact_variants_and_hash_binding(self):
        step = self.step('B4')
        self.assertEqual(set(step['variants']), {'apply', 'placeholder'})
        self.assertEqual(step['variants']['apply'], step['tx'])
        self.assertEqual(step['variants']['placeholder'],
                         dict(step['tx'], to=u.DEPLOYER, value='0x0', data='0x'))
        original = hashlib.sha256(json.dumps(self.plan, sort_keys=True).encode()).hexdigest()
        for name in ('apply', 'placeholder'):
            bad = copy.deepcopy(self.plan)
            next(s for s in bad['steps'] if s['id'] == 'B4')['variants'][name]['value'] = '0x1'
            self.assertNotEqual(hashlib.sha256(json.dumps(bad, sort_keys=True).encode()).hexdigest(), original)
            with self.assertRaises(a.Gate): m.validate_plan(bad, self.inputs)
        for field, value in (('to', ANNI), ('data', '0x00'), ('nonce', '0x1'),
                             ('maxFeePerGas', '0x1'), ('maxPriorityFeePerGas', '0x1')):
            bad = copy.deepcopy(self.plan)
            next(s for s in bad['steps'] if s['id'] == 'B4')['variants']['placeholder'][field] = value
            with self.assertRaises(a.Gate): m.validate_plan(bad, self.inputs)
        step['variants']['third'] = dict(step['tx'])
        with self.assertRaises(a.Gate): m.validate_plan(self.plan, self.inputs)

    def test_b4_read_selects_only_allowed_variant(self):
        chain = FakeChain(self.plan)
        for verifier, variant in ((a.ZERO, 'apply'),
                (self.plan['addresses']['OverIssueFraudProofVerifier'], 'placeholder'),
                (ANNI, 'apply')):
            chain.verifier = verifier
            name, tx = m.select_b4(chain, self.plan, self.step('B4'))
            self.assertEqual(name, variant)
            self.assertEqual(tx, self.step('B4')['variants'][variant])

    def test_b4_poststate_status_exception_is_narrow(self):
        expected = self.plan['addresses']['OverIssueFraudProofVerifier']
        for variant in ('apply', 'placeholder', 'third'):
            for status in (0, 1, 2):
                for active, pending, eta in ((expected, a.ZERO, 0), (ANNI, a.ZERO, 0),
                        (expected, ANNI, 0), (expected, a.ZERO, 1)):
                    values = dict(zip(('fraudProofVerifier()', 'pendingFraudProofVerifier()',
                                       'pendingFraudProofVerifierReadyAt()'),
                                      (int(active,16), int(pending,16), eta)))
                    passes = (variant in ('apply','placeholder') and
                        (status == 1 or (status == 0 and variant == 'apply')) and
                        active == expected and pending == a.ZERO and eta == 0)
                    with self.subTest(variant=variant,status=status,values=values), patch.object(a, 'call',
                            side_effect=lambda r,t,s,*args: '0x'+format(values[s], '064x')):
                        if passes: m.b4_post_state(None, self.plan, variant, {'status':hex(status)})
                        else:
                            with self.assertRaises(a.Gate):
                                m.b4_post_state(None, self.plan, variant, {'status':hex(status)})

    def test_b4_frozen_execution_controls_and_receipt_record(self):
        step = self.step('B4')
        step['tx']['gas'] = hex(130000)
        step['variants']['apply'] = dict(step['tx'])
        freeze_gas(self.plan, step)
        expected = self.plan['addresses']['OverIssueFraudProofVerifier']
        for mode in ('preapplied', 'frontrun', 'wrong'):
            frozen = copy.deepcopy(step)
            state = dict(verifier=expected if mode == 'preapplied' else a.ZERO,
                         nonce=a.qty(step['tx']['nonce']))
            sent, context = [], {}
            def rpc(method, params):
                if method == 'eth_estimateGas': return hex(21000)
                if method == 'eth_getTransactionByHash': return {}
                if method == 'evm_setNextBlockTimestamp':
                    self.assertEqual(params, [0x101])
                    return True
                raise AssertionError(method)
            def receipt(rpc, tx, status=None):
                self.assertIsNone(status)
                self.assertEqual(a.qty(tx['nonce']), state['nonce'])
                state['nonce'] += 1
                sent.append(tx)
                state['verifier'] = ANNI if mode == 'wrong' else expected
                return dict(status='0x1' if mode == 'preapplied' else '0x0',
                    gasUsed=hex(21000), transactionHash='0x'+'12'*32, blockNumber='0xb4')
            def call(rpc, target, signature, *args):
                value = int(state['verifier'], 16) if signature == 'fraudProofVerifier()' else 0
                return '0x'+format(value, '064x')
            def block_data(rpc, block):
                return dict(timestamp='0x101' if block == '0xb4' else '0x100', gasLimit=hex(a.GAS_CAP))
            with patch.object(a, 'block_data', side_effect=block_data), \
                 patch.object(a, 'call', side_effect=call), \
                 patch.object(a, 'address', side_effect=lambda *args:state['verifier']), \
                 patch.object(a, 'nonce', side_effect=lambda *args:state['nonce']), \
                 patch.object(a, 'word', return_value=step['safeNonce']), \
                 patch.object(a, 'mined_identity'), patch.object(m, 'pre_send'), \
                 patch.object(u, 'receipt', side_effect=receipt), \
                 patch.object(u, 'fresh_gas', return_value={'mode': 'pinned-consistency', 'block': self.plan['pin']['block']}), patch.object(u, 'measure_step'), patch.object(u, 'replay_remote_measurement'), \
                 patch.object(u, 'probe', return_value=({'status':'0x1','gasUsed':hex(21000)}, None)), \
                 patch.object(u, 'log') as log:
                if mode == 'wrong':
                    with self.assertRaises(a.Gate):
                        m.execute_b4(None, rpc, self.plan, step, context, {}, False, Path(self.tmp.name))
                else:
                    result = m.execute_b4(None, rpc, self.plan, step, context, {}, False, Path(self.tmp.name))
                    self.assertEqual(result['variant'], 'placeholder' if mode == 'preapplied' else 'apply')
                    self.assertEqual(state['nonce'], a.qty(step['tx']['nonce'])+1)
                self.assertEqual(len(sent), 1)
                self.assertEqual(log.call_args.args[1]['receipt'], context['B4Receipt']['receipt'])
                self.assertEqual(sent[0], step['variants']['placeholder' if mode == 'preapplied' else 'apply'])
            step.pop('skipped', None)
            frozen.pop('skipped', None)
            self.assertEqual(step, frozen)

    def test_s7_receipt_status_and_nonce_required_by_builder(self):
        for field in ('status', 'nonce'):
            bad = copy.deepcopy(self.pin)
            proof = bad['a3aHistory']['S7']
            if field == 'status': proof['receipt']['status'] = '0x0'
            else: proof['transaction']['nonce'] = '0x0'
            with self.assertRaises(a.Gate): m.build_plan(bad, self.inputs)

    def test_builder_runs_release_validation(self):
        with patch.object(m, 'release_gate', side_effect=a.Gate('release_test', False, True)):
            with assert_stop(self, 'release_test') as caught: m.build_plan(self.pin, self.inputs)
        self.assertEqual(caught.exception.record['gate'], 'release_test')

    def test_unproven_approver_executor_gaps_refused(self):
        for label in ('approver', 'executor'):
            bad = copy.deepcopy(self.pin)
            bad['senders'][label]['nonce'] += 1
            with self.assertRaises(a.Gate): m.build_plan(bad, self.inputs)

    def test_format_only_release_hash_refused(self):
        bad = copy.deepcopy(self.inputs)
        bad['data']['releaseEvidence']['conformance'] = 'a'*64
        with self.assertRaises(a.Gate): m.build_plan(self.pin, bad)

    def test_evidence_semantics_each_kind(self):
        for kind in m.EVIDENCE_KINDS:
            original = json.loads(Path(self.data['releaseEvidence'][kind]['path']).read_text())
            mutations = [dict(result='FAIL'), dict(counts=dict(passed=0, failed=0, skipped=0)),
                dict(counts=dict(passed=1, failed=1, skipped=0)), dict(counts=dict(passed=1, failed=0)),
                dict(subjectCommit='f'*40), dict(tool=dict(name='synthetic', version=''))]
            if kind.startswith('dvt-'):
                mutations += [dict(spCommit='f'*40), dict(aggregatorVersion='BLSAggregator-4.11.0')]
            for mutation in mutations:
                with self.subTest(kind=kind, mutation=mutation):
                    ref = self.file_ref('bad-evidence', dict(original, **mutation))
                    with self.assertRaises(a.Gate): m.evidence_file(ref, kind, ART['commit'])

    def test_stale_tree_evidence_refused(self):
        with patch.object(m.subprocess, 'run', return_value=SimpleNamespace(stdout=' M contracts/source.sol', returncode=0)):
            with assert_stop(self, 'release_clean_tree') as caught: REAL_RELEASE_GATE(self.inputs, ART, self.pin)
        self.assertEqual(caught.exception.record['gate'], 'release_clean_tree')

    def test_built_aggregator_version_required(self):
        build = dict(ART, aggregatorVersion='BLSAggregator-4.11.0')
        with patch.object(m.subprocess, 'run', return_value=SimpleNamespace(stdout='', returncode=0)):
            with assert_stop(self, 'built_aggregator_version') as caught: REAL_RELEASE_GATE(self.inputs, build, self.pin)
        self.assertEqual(caught.exception.record['gate'], 'built_aggregator_version')

    def test_cached_build_current_head_required(self):
        def run(cmd, **kwargs):
            return SimpleNamespace(returncode=0, stdout='' if 'status' in cmd else 'f'*40)
        with patch.object(m.subprocess, 'run', side_effect=run):
            with assert_stop(self, 'release_current_head') as caught: REAL_RELEASE_GATE(self.inputs, ART, self.pin)
        self.assertEqual(caught.exception.record['gate'], 'release_current_head')

    def registry_layout_fixture(self, change, gate):
        layout = dict(storage=[dict(label='_owner' if i == 0 else 'v'+str(i), slot=str(i), offset=0, type='struct') for i in range(32)],
            types={'struct':dict(encoding='inplace', label='S', numberOfBytes='32', members=[dict(label='nested', slot='0', offset=0, type='uint')]),
                   'uint':dict(encoding='inplace', label='uint256', numberOfBytes='32')})
        old = copy.deepcopy(ART['contracts']['Registry']); old['storageLayout'] = copy.deepcopy(layout)
        build = copy.deepcopy(ART); build['contracts']['Registry']['storageLayout'] = layout
        change(layout, old['storageLayout'])
        def run(cmd, **kw):
            return SimpleNamespace(returncode=0, stdout='' if 'status' in cmd else ART['commit'] if ('refs/tags/' in cmd[-1] or cmd[-1] == 'HEAD') else 'b'*40)
        with patch.object(m.subprocess, 'run', side_effect=run), patch.object(a, 'compile_commit', return_value=({'Registry':old}, {})):
            with assert_stop(self, gate) as caught:
                REAL_RELEASE_GATE(self.inputs, build, dict(self.pin, registryImplementation=ANNI, registryImplementationCode='0x6000'))
        self.assertEqual(caught.exception.record['gate'], gate)

    def test_registry_recursive_layout_required(self):
        self.registry_layout_fixture(lambda new, old:new['types']['struct']['members'][0].update(offset=1), 'registry_layout')

    def test_registry_32_variables_required(self):
        self.registry_layout_fixture(lambda new, old:(new['storage'].pop(), old['storage'].pop()), 'registry_storage_count')

    def test_registry_owner_slot_required(self):
        self.registry_layout_fixture(lambda new, old:(new['storage'][0].update(slot='1'), old['storage'][0].update(slot='1')), 'registry_owner_slot')

    def test_b2_single_upgrade_required(self):
        chain = FakeChain(self.plan)
        def rpc(method, params):
            result = chain(method, params)
            if method == 'eth_getLogs' and params[0]['topics'][0] == a.keccak('Upgraded(address)'):
                return [result[0], dict(result[0], logIndex='0x1')]
            return result
        with assert_stop(self, 'B2_single_upgrade') as caught: m.b2_gate(rpc, self.plan, '0x100')
        self.assertEqual(caught.exception.record['gate'], 'B2_single_upgrade')

    def test_b2_implementation_identity_required(self):
        chain = FakeChain(self.plan)
        def rpc(method, params):
            result = chain(method, params)
            if method == 'eth_getLogs' and params[0]['topics'][0] == a.keccak('Upgraded(address)'):
                result[0]['topics'][1] = '0x'+ANNI[2:].zfill(64)
            return result
        with assert_stop(self, 'B2_upgrade_identity') as caught: m.b2_gate(rpc, self.plan, '0x100')
        self.assertEqual(caught.exception.record['gate'], 'B2_upgrade_identity')

    def test_guardian_inventory_and_anni_required(self):
        # guardian_inventory is load-bearing for the stage-a7 old-exit derivation (the PoP
        # set equals the slot inventory), so assert this exact gate, not any later one.
        bad = copy.deepcopy(self.pin)
        bad['guardianInventory'][0]['validator'] = ANNI
        with assert_stop(self, 'guardian_inventory') as caught: m.build_plan(bad, self.inputs)
        self.assertEqual(caught.exception.record['gate'], 'guardian_inventory')
        bad = copy.deepcopy(self.pin)
        bad['guardianInventory'][3]['validator'] = '0xf36c9317765634e4995ce1e7210b5738225425b0'
        with assert_stop(self, 'guardian_inventory') as caught: m.build_plan(bad, self.inputs)
        self.assertEqual(caught.exception.record['gate'], 'guardian_inventory')
        bad = copy.deepcopy(self.pin)
        bad['guardianInventory'][0]['slot'] = 4
        with self.assertRaises(a.Gate): m.build_plan(bad, self.inputs)
        bad = copy.deepcopy(self.data); bad['anni'] = base.HOLDER
        with self.assertRaises(a.Gate): m.validate_external(bad)

    def test_all_a3a_steps_mined_identity_required(self):
        for sid in a.STEP_IDS:
            with self.subTest(step=sid):
                bad = copy.deepcopy(self.pin)
                bad['a3aHistory'][sid]['transaction']['input'] = '0x1234'
                with self.assertRaises(a.Gate): m.validate_nonce_history(bad, self.inputs)

    def test_governance_evidence_revalidated_by_builder(self):
        harness = SafeGovernanceTests()
        harness.setUp()
        self.addCleanup(harness.doCleanups)
        ap = json.loads(Path(self.inputs['data']['a3aPlan']['path']).read_text())
        for label, last in [('approver', 98), ('executor', 754)]:
            who = a.SENDERS[label]
            steps = [s for s in ap['steps'] if s['tx']['from'] == who]
            shift = last-max(a.qty(s['tx']['nonce']) for s in steps)
            for step in steps:
                step['tx']['nonce'] = hex(a.qty(step['tx']['nonce'])+shift)
                self.pin['a3aHistory'][step['id']]['transaction']['nonce'] = step['tx']['nonce']
            ap['pin']['senders'][label]['nonce'] += shift
            self.pin['senders'][label]['nonce'] = harness.pin['senders'][label]['nonce']
        spec = self.inputs['data']['a3aPlan']
        receipts = spec['receipts']
        spec.update(self.file_ref('governance-a3a', ap), receipts=receipts)
        digest = spec['sha256']
        self.inputs['data']['safeGovernanceGaps'] = harness.inputs['data']['safeGovernanceGaps']
        self.pin['stateBlock'] = harness.pin['stateBlock']
        set_old_exit_evidence(self.pin)
        self.pin['oldOwnerIsolation'] = isolation_tests.evidence(self.pin)
        self.pin['oldTimelock'] = m.old_timelock_holds_nothing(old_timelock_rpc(self.pin, self.pin['stateBlock']), self.pin, self.pin['stateBlock'])
        self.pin['safeNonce'] = harness.pin['safeNonce']
        self.pin['safe']['owners'] = harness.pin['safe']['owners']
        self.pin['safe']['codes'] = {who:code for who,code in self.pin['safe']['codes'].items() if who in (a.SAFE, a.DEPLOYER)}
        self.pin['safe']['codes'].update(harness.pin['safe']['codes'])
        m.governance_evidence(self.pin, self.inputs, [harness.rpc('a'), harness.rpc('b')])
        m.build_plan(self.pin, self.inputs, 'a7')
        self.assertEqual(spec['sha256'], digest)
        self.pin['safeGovernanceGaps']['reads']['b'][0]['result']['input'] = '0x00'
        with assert_stop(self, 'safe_gap_input') as caught: m.build_plan(self.pin, self.inputs, 'a7')
        self.assertEqual(caught.exception.record['gate'], 'safe_gap_input')

    def test_embedded_a3a_contract_call_gap_refused(self):
        inputs = copy.deepcopy(self.inputs)
        spec = inputs['data']['a3aPlan']
        plan = json.loads(Path(spec['path']).read_text())
        gap = {'from':u.DEPLOYER, 'nonce':'0x1', 'hash':'0x'+'ab'*32}
        plan['nonceGaps'] = [gap]
        spec.update(self.file_ref('gap-plan', plan))
        mined = dict(gap, blockNumber='0x1', blockHash=base.HASH, type='0x2', input='0x12345678', to=u.REG)
        pin = copy.deepcopy(self.pin)
        pin['a3aGapReads'] = [dict(method='eth_getTransactionByHash', params=[gap['hash']], result=mined)]
        with assert_stop(self, 'a3a_nonce_complete_deployer') as caught: m.validate_nonce_history(pin, inputs)
        self.assertEqual(caught.exception.record['gate'], 'a3a_nonce_complete_deployer')

    def test_fraud_sample_format_only(self):
        self.assertEqual(m.fraud_format_only(SAMPLE), SAMPLE)
        wrapped = dict(toolCommit='b'*40, verifierCommit=m.VERIFIER_COMMIT, export=SAMPLE)
        with self.assertRaises(a.Gate): m.fraud_fixture(self.file_ref('old-sample', wrapped))
        with self.assertRaises(a.Gate): m.fraud_fixture(self.file_ref('bare-sample', SAMPLE))

    def test_fraud_sample_412_schema_and_bindings(self):
        wrapped = dict(toolCommit='b'*40, verifierCommit=m.VERIFIER_COMMIT, export=copy.deepcopy(SAMPLE))
        e = wrapped['export']
        e.update(version=m.AGG_VERSION, aggregator=self.plan['addresses']['BLSAggregator'],
                 verifier=self.plan['addresses']['OverIssueFraudProofVerifier'])
        # Address substitution proves format compatibility, not an authenticated fork domain.
        p = dict(block=e['block'], guardianInventory=[dict(validator=x.lower()) for x in e['valid']['guiltyGuardians']])
        ref = self.file_ref('sample-412', wrapped)
        parsed = m.fraud_fixture(ref, p, e['aggregator'], e['verifier'], ART['contracts']['BLSAggregator']['storageLayout'])
        self.assertEqual(parsed['commitment']['slot'], m.commitment_slot(ART['contracts']['BLSAggregator']['storageLayout'], parsed['pid']))
        for key in ('aggregator', 'verifier', 'version'):
            bad = copy.deepcopy(wrapped); bad['export'][key] = SAMPLE[key]
            with self.subTest(key=key), self.assertRaises(a.Gate):
                m.fraud_fixture(self.file_ref('old-'+key, bad), p, e['aggregator'], e['verifier'])
        bad = copy.deepcopy(self.inputs)
        bad['data']['fraudProofFixture'] = self.file_ref('old-build', dict(wrapped, export=SAMPLE))
        with self.assertRaises(a.Gate): m.build_plan(self.pin, bad)

    def test_fraud_fixture_schema_and_binding(self):
        changes = [(['verifierCommit'], 'f'*40), (['toolCommit'], 'x'),
            (['export','aggregator'], ANNI), (['export','verifier'], ANNI),
            (['export','version'], 'BLSAggregator-4.11.0'), (['export','chainId'], 1),
            (['export','block'], 0), (['export','registry'], ANNI),
            (['export','valid','guiltyGuardians'], list(reversed(self.fraud['guiltyGuardians']))),
            (['export','valid','guiltyGuardians'], sorted([ANNI, *self.fraud['guiltyGuardians'][:2]])),
            (['export','forkState','commitment','mapping'], 'other'),
            (['export','forkState','commitment','key'], '1'),
            (['export','forkState','commitment','value'], a.ZERO32),
            (['export','forkState','commitment','check'], 'skip readback'),
            (['export','forkState','token','overIssuedStorageSlot'], 1),
            (['export','valid','operator'], ANNI), (['export','valid','epoch'], '2'),
            (['export','valid','slashLevel'], 2), (['export','valid','domainDigest'], a.ZERO32),
            (['export','valid','proposalId'], str(2**256)), (['export','valid','signerMask'], '0x0')]
        for path, value in changes:
            bad = copy.deepcopy(self.export); target = bad
            for key in path[:-1]: target = target[key]
            target[path[-1]] = value
            with self.subTest(path=path), self.assertRaises(a.Gate):
                m.fraud_fixture(self.file_ref('bad-fraud', bad), self.pin,
                    self.plan['addresses']['BLSAggregator'], self.plan['addresses']['OverIssueFraudProofVerifier'],
                    ART['contracts']['BLSAggregator']['storageLayout'])
        for key in ('toolCommit', 'verifierCommit'):
            bad = copy.deepcopy(self.export); del bad[key]
            with self.assertRaises(a.Gate): m.fraud_fixture(self.file_ref('missing-commit', bad))
        bad = copy.deepcopy(self.export); bad['export']['forkState']['commitment']['slot'] = a.ZERO32
        with self.assertRaises(a.Gate): m.fraud_fixture(self.file_ref('caller-slot', bad))
        bad = copy.deepcopy(self.inputs); del bad['data']['fraudProofFixture']
        with self.assertRaises(a.Gate): m.build_plan(self.pin, bad)

    def test_fraud_tool_revision_is_separate(self):
        ref = self.file_ref('tool-revision', dict(self.export, toolCommit='c'*40))
        self.assertEqual(m.fraud_fixture(ref)['toolCommit'], 'c'*40)
        self.assertEqual(m.fraud_fixture(ref)['verifierCommit'], m.VERIFIER_COMMIT)

    def test_fraud_mutations_are_exact(self):
        mutations = [(0, 'guiltyGuardians', self.fraud['guiltyGuardians']),
                     (1, 'change', 'do nothing'), (1, 'fraudProof', '0x00'),
                     (2, 'fraudProof', self.fraud['fraudProof']), (2, 'fraudProof', '0x'),
                     (3, 'domainDigest', a.ZERO32), (3, 'call', 'queueGuardianSlash'),
                     (3, 'guiltyGuardians', [ANNI]*3), (0, 'expect', 'succeeds')]
        for index, key, value in mutations:
            f = copy.deepcopy(self.export); f['export']['mustReject'][index][key] = value
            with self.subTest(index=index, key=key), self.assertRaises(a.Gate):
                m.fraud_fixture(self.file_ref('bad-mutation', f))
        for index in range(4):
            f = copy.deepcopy(self.export); del f['export']['mustReject'][index]
            with self.assertRaises(a.Gate): m.fraud_fixture(self.file_ref('missing-negative', f))
        f = copy.deepcopy(self.export); f['export']['mustReject'].reverse()
        with self.assertRaises(a.Gate): m.fraud_fixture(self.file_ref('wrong-order', f))

    def test_fraud_runtime_digest_refusal(self):
        for offset in (0, 130, 210, 340):
            f = copy.deepcopy(self.export)
            raw = bytearray.fromhex(f['export']['forkState']['token']['runtimeBytecode'][2:]); raw[offset] ^= 1
            f['export']['forkState']['token']['runtimeBytecode'] = '0x'+raw.hex()
            with self.subTest(offset=offset), self.assertRaises(a.Gate):
                m.fraud_fixture(self.file_ref('bad-runtime', f))
        with patch.object(m, 'MOCK_TOKEN_STRIPPED_RUNTIME_HASH', a.ZERO32), self.assertRaises(a.Gate):
            m.fraud_fixture(self.data['fraudProofFixture'])
        self.assertEqual(a.calldata('isOverIssued()'), '0xbeaf15d9')

    def test_fraud_layout_changes_slot(self):
        layout = copy.deepcopy(ART['contracts']['BLSAggregator']['storageLayout'])
        layout['storage'][0]['slot'] = '30'
        actual = m.fraud_fixture(self.data['fraudProofFixture'], layout=layout)['commitment']['slot']
        self.assertEqual(actual, m.commitment_slot(layout, self.fraud['pid']))
        self.assertNotEqual(actual, self.fraud['commitment']['slot'])

    def test_fraud_layout_must_be_uint_bytes32_mapping(self):
        for key, value in (('storage', []), ('types', {'map':dict(encoding='inplace')})):
            layout = copy.deepcopy(ART['contracts']['BLSAggregator']['storageLayout']); layout[key] = value
            with self.assertRaises(a.Gate): m.commitment_slot(layout, self.fraud['pid'])

    def test_fraud_rehearsal_valid_invalid_and_restoration(self):
        for failure in (None, 'event', 'state', 'slot', 'N1', 'N2', 'N3', 'N4', 'runtime', 'domain', 'id', 'restore', 'message', 'isOverIssued_before', 'isOverIssued_after'):
            with self.subTest(failure=failure):
                f = self.fraud
                agg, verifier = f['aggregator'], f['verifier']
                token = f['mockToken']['address']
                state = dict(code='0x', commitment=a.ZERO32, over=0, queued=False)
                snapshots, calls, sent = {}, [], []
                gh = a.keccak(a.cast('abi-encode', 'c(address[])', '['+','.join(f['guiltyGuardians'])+']'))
                def rpc(method, params):
                    calls.append((method, params))
                    if method == 'evm_snapshot':
                        sid = str(len(calls)); snapshots[sid] = copy.deepcopy(state); return sid
                    if method == 'evm_revert':
                        state.update(snapshots.pop(params[0]))
                        if failure == 'restore' and not snapshots: state['commitment'] = base.HASH
                        return True
                    if method.startswith('anvil_set'):
                        self.assertTrue(snapshots, 'write outside drill snapshot')
                        if method == 'anvil_setCode': state['code'] = params[1]
                        elif params[0] == agg: state['commitment'] = a.ZERO32 if failure == 'slot' else params[2]
                        else: state['over'] = int(params[2],16)
                        return None
                    if method == 'debug_traceTransaction':
                        name = ('valid','N1','N2','N3')[len(sent)-1]
                        return dict(error='execution reverted', output='0xdeadbeef' if name == failure else a.calldata('InvalidFraudProof(uint256)', 1))
                    raise AssertionError(method)
                rpc.local = True
                def code(rpc, target, block):
                    if target == token: return state['code']
                    return '0x6001' if failure == 'runtime' else '0x6000'
                def call(rpc, target, signature, *args):
                    if signature == 'domainSeparator()': return a.ZERO32 if failure == 'domain' else f['domainSeparator']
                    if signature.startswith('slashMessageHash'): return a.ZERO32 if failure == 'message' else f['messageHash']
                    if signature.startswith('proposalSignersCommitment'): return state['commitment']
                    if signature.startswith('guardianSlashCases'):
                        return a.cast('abi-encode', 'c(uint256,uint256,uint256,uint256)', int(gh,16),
                            int(a.keccak(f['fraudProof']),16), 123, int(state['queued'] and failure != 'state'))
                    raise AssertionError(signature)
                def word(rpc, target, signature, *args):
                    if signature.startswith('deriveFraudProofId'): return 2 if failure == 'id' else 1
                    if signature == 'isOverIssued()':
                        return 1-state['over'] if failure == ('isOverIssued_after' if state['over'] else 'isOverIssued_before') else state['over']
                    if signature == 'over()': return state['over']
                    if signature.startswith('verify'):
                        self.assertFalse(state['queued']); self.assertEqual(state['over'], 0)
                        self.assertEqual(args[0], f['invalid']['N4']['domainDigest'])
                        return int(failure == 'N4')
                    raise AssertionError(signature)
                def receipt(rpc, tx, status='0x1'):
                    index = len(sent)
                    self.assertFalse(state['queued'])
                    self.assertEqual(state['over'], int(index == 2))
                    self.assertEqual(status, '0x1' if index == 0 else '0x0')
                    self.assertEqual(tx['to'], agg)
                    guardians = f['invalid']['N1']['guiltyGuardians'] if index == 1 else f['guiltyGuardians']
                    payload = f['invalid']['N3']['fraudProof'] if index == 3 else f['fraudProof']
                    self.assertEqual(tx['data'], a.calldata(m.FRAUD_SIG, 1, '['+','.join(guardians)+']', payload))
                    sent.append(tx); state['queued'] = index == 0
                    log = dict(address=agg, topics=[a.keccak('GuardianSlashQueued(uint256,bytes32,uint256,address[])'), '0x'+format(1,'064x')],
                        data=a.cast('abi-encode', 'c(bytes32,uint256,address[])', gh, 123, '['+','.join(guardians)+']'))
                    return dict(status=status, transactionHash=base.HASH, logs=[] if failure == 'event' else [log])
                with patch.object(u, 'fixture_tx', side_effect=lambda rpc,sender,target,data:dict(to=target,data=data)), \
                     patch.object(u, 'receipt', side_effect=receipt), patch.object(u, 'code', side_effect=code), \
                     patch.object(a, 'address', return_value=verifier), patch.object(a, 'word', side_effect=word), \
                     patch.object(a, 'call', side_effect=call):
                    if failure:
                        with self.assertRaises(a.Gate): m.fraud_rehearsal(rpc, self.plan)
                    else:
                        result = m.fraud_rehearsal(rpc, self.plan)
                        self.assertEqual(len(result['proofs']), 5)
                        self.assertEqual(len(result['storageWrites']), 3)
                        self.assertEqual(result['mainReadback'], dict(before=a.ZERO32, after=a.ZERO32))
                        self.assertEqual(len({x['snapshotId'] for x in result['proofs']}), 5)
                        self.assertTrue(all(x['revertSelector'] == a.keccak('InvalidFraudProof(uint256)')[:10] for x in result['proofs'][1:4]))
                self.assertFalse(snapshots)
                self.assertEqual(state['code'], '0x')
                self.assertFalse(state['queued'])

    def test_conformance_scope_required(self):
        original=json.loads(Path(self.data['releaseEvidence']['conformance']['path']).read_text())
        for scope in (None, 'fixed-block-state'):
            e=copy.deepcopy(original)
            if scope is None: del e['scope']
            else: e['scope']=scope
            with self.subTest(scope=scope), self.assertRaises(a.Gate):
                m.evidence_file(self.file_ref('missing-scope',e),'conformance')

    def test_conformance_each_negative_required(self):
        original=json.loads(Path(self.data['releaseEvidence']['conformance']['path']).read_text())
        for name in original['controls']:
            for value in (None, []):
                e=copy.deepcopy(original)
                if value is None: del e['controls'][name]['negativeControl']
                else: e['controls'][name]['negativeControl']=value
                with self.subTest(name=name,value=value), self.assertRaises(a.Gate):
                    m.evidence_file(self.file_ref('missing-negative',e),'conformance')

    def test_conformance_each_test_must_exist(self):
        original=json.loads(Path(self.data['releaseEvidence']['conformance']['path']).read_text())
        for name in original['controls']:
            for field in ('test','positiveControl','negativeControl'):
                e=copy.deepcopy(original)
                if field=='test': e['controls'][name][field]='test_not_a_real_test'
                else: e['controls'][name][field][0]['test']='test_not_a_real_test'
                with self.subTest(name=name,field=field), self.assertRaises(a.Gate):
                    m.evidence_file(self.file_ref('missing-test',e),'conformance')

    def test_named_evidence_required_each_kind(self):
        for kind in m.EVIDENCE_KINDS:
            e = json.loads(Path(self.data['releaseEvidence'][kind]['path']).read_text())
            field = {'conformance':'controls', 'mutation':'controls', 'slither':'findings',
                     'reproducible-build':'contracts', 'dvt-ci':'suites', 'dvt-conformance-4.12':'suites'}[kind]
            e[field] = {}
            with self.subTest(kind=kind), self.assertRaises(a.Gate):
                m.evidence_file(self.file_ref('missing-detail', e), kind, ART['commit'])

    def test_prague_skipped_counterexample(self):
        kind = 'dvt-conformance-4.12'
        e = json.loads(Path(self.data['releaseEvidence'][kind]['path']).read_text())
        e['counts'] = dict(passed=1, failed=0, skipped=11)
        with self.assertRaises(a.Gate): m.evidence_file(self.file_ref('skipped', e), kind)
        e['counts'] = dict(passed=23, failed=0, skipped=0)
        e['suites']['CC115GenuinePragueCrossRepo']['env'] = {}
        with self.assertRaises(a.Gate): m.evidence_file(self.file_ref('wrong-evm', e), kind)

    def test_creation_layout_packet(self):
        self.assertEqual(self.plan['creationMetadataLayouts'], {'OverIssueFraudProofVerifier': m.VERIFIER_METADATA_LAYOUT})
        changed = copy.deepcopy(self.plan)
        changed['creationMetadataLayouts']['OverIssueFraudProofVerifier']['segments'] = []
        with self.assertRaises(a.Gate): m.validate_plan(changed, self.inputs)

    def test_creation_hash_comparison(self):
        contracts = copy.deepcopy(ART['contracts'])
        e = dict(contracts={k:v['creationHashes'].copy() for k,v in contracts.items()})
        self.assertEqual(m.compare_build_evidence(e, contracts), [])
        name = m.NAMES[0]
        e['contracts'][name]['fullCreationKeccak'] = a.ZERO32
        with self.assertRaises(a.Gate): m.compare_build_evidence(e, contracts)
        e['contracts'][name]['strippedCreationKeccak'] = a.ZERO32
        with self.assertRaises(a.Gate): m.compare_build_evidence(e, contracts)
        left, right = (m.creation_hashes(x) for x in ('0x6000a16161010004', '0x6000a16161020004'))
        self.assertNotEqual(left['strippedCreationKeccak'], right['strippedCreationKeccak'])
        self.assertNotEqual(left['fullCreationKeccak'], right['fullCreationKeccak'])

    def test_unpinned_and_substituted_mock_refused(self):
        for digest in (None, a.ZERO32):
            with patch.object(m, 'MOCK_TOKEN_RUNTIME_HASH', digest), self.assertRaises(a.Gate):
                m.fraud_fixture(self.data['fraudProofFixture'])

    def history_rpc(self, bad_canonical=False):
        def rpc(method, params):
            if method == 'eth_getBlockByNumber': return dict(hash=a.ZERO32 if bad_canonical else base.HASH)
            for sid, proof in self.pin['a3aHistory'].items():
                if params == [self.data['a3aPlan']['receipts'][sid]]:
                    if method == 'eth_getTransactionReceipt': return proof['receipt']
                    if method == 'eth_getTransactionByHash': return proof['transaction']
            raise AssertionError((method, params))
        return rpc

    def test_reconcile_direct_and_canonical_receipt(self):
        p = copy.deepcopy(self.pin)
        m.reconcile_nonces(self.history_rpc(), p, self.inputs)
        self.assertEqual(p['a3aHistory'], self.pin['a3aHistory'])
        with assert_stop(self, 'a3a_canonical_receipt') as caught:
            m.reconcile_nonces(self.history_rpc(True), p, self.inputs)
        self.assertEqual(caught.exception.record['gate'], 'a3a_canonical_receipt')

    def test_internal_nonce_hole_refused(self):
        spec = copy.deepcopy(self.data['a3aPlan'])
        plan = json.loads(Path(spec['path']).read_text())
        # S1=100, unrelated nonce=101, remaining deployer steps=102..105.
        rows = [s for s in plan['steps'] if s['tx']['from'] == u.DEPLOYER]
        for step,n in zip(rows, (100,102,103,104,105)): step['tx']['nonce'] = hex(n)
        plan['pin']['senders']['deployer']['nonce'] = 100
        spec.update(self.file_ref('hole', plan))
        inputs = copy.deepcopy(self.inputs); inputs['data']['a3aPlan'] = spec
        p = copy.deepcopy(self.pin); p['senders']['deployer']['nonce'] = 106
        with assert_stop(self, 'a3a_nonce_complete_deployer') as caught: m.reconcile_nonces(self.history_rpc(), p, inputs)
        self.assertEqual(caught.exception.record['gate'], 'a3a_nonce_complete_deployer')

    def test_history_calls_frozen_historical_validator_after_hash(self):
        with patch.object(a, 'validate_plan', side_effect=a.Gate('relabeled_payload', False, True)) as validate:
            with self.assertRaises(a.Gate): m.history_steps(self.pin, self.inputs)
            self.assertEqual(validate.call_args.kwargs, dict(frozen=True, historical=True))
            bad = copy.deepcopy(self.inputs); bad['data']['a3aPlan']['sha256'] = 'f'*64
            validate.reset_mock()
            with self.assertRaises(a.Gate): m.history_steps(self.pin, bad)
            validate.assert_not_called()

    def test_collect_direct_fake_chain(self):
        history = self.history_rpc()
        legacy = old_timelock_rpc(self.pin, self.pin['stateBlock'])
        def rpc(method, params):
            if method in ('eth_call', 'eth_getLogs'): return legacy(method, params)
            if method == 'eth_getBalance': return '0x100'
            if method == 'eth_getStorageAt': return '0x'+ANNI[2:].zfill(64)
            return history(method, params)
        def address(rpc, target, sig, block):
            return u.DEPLOYER if sig in ('owner()', 'slashPolicyAdmin()') else OLD
        def word(rpc, target, sig, *args, **kw):
            if sig == 'MAX_VALIDATORS()': return 13
            if sig == 'validatorAtSlot(uint8)': return args[0] if args[0] <= 3 else 0
            raise AssertionError(sig)
        def call(rpc, target, sig, *args, **kw):
            if sig == 'version()': return a.cast('abi-encode', 'c(string)', 'Registry-5.8.0')
            if sig.startswith('getDepositInfo'): return a.cast('abi-encode','c(uint256,bool,uint256,uint256,uint256)', 1, 'true', 1, 86400, 0)
            raise AssertionError(sig)
        with patch.object(m.isolation, 'collect_deployed', return_value=self.pin['oldOwnerIsolation']), \
             patch.object(u, 'collect', return_value=copy.deepcopy(self.pin)), \
             patch.object(a, 'nonce', return_value=55), patch.object(u, 'code', side_effect=lambda r,t,b:'0x' if t == ANNI else '0x6000'), \
             patch.object(a, 'call', side_effect=call), patch.object(a, 'word', side_effect=word), \
             patch.object(a, 'address', side_effect=address), patch.object(m, 'old_activity', return_value={}), \
             patch.object(m, 'dvt_activity', return_value=[]), patch.object(m, 'balances', return_value={k:self.pin[k] for k in ('totalTrackedBalance','protocolRevenue','operatorBalances')}), \
             patch.object(m, 'collect_phase_c', return_value=copy.deepcopy(self.pin['phaseC'])) as phase_c:
            collected = m.collect(rpc, '0x100', self.inputs)
            def wrong_admin(rpc, target, sig, block):
                return ANNI if sig == 'slashPolicyAdmin()' else address(rpc, target, sig, block)
            with patch.object(a, 'address', side_effect=wrong_admin):
                with assert_stop(self, 'old_aggregator_slash_policy_admin') as caught:
                    m.collect(rpc, '0x100', self.inputs)
            self.assertEqual(caught.exception.record['gate'], 'old_aggregator_slash_policy_admin')
        self.assertEqual({r['block'] for r in collected['oldTimelock']['reads']}, {collected['stateBlock']})
        phase_c.assert_called_once()
        self.assertEqual(collected['phaseC'], self.pin['phaseC'])
        self.assertEqual(collected['a3aHistory'], self.pin['a3aHistory'])
        self.assertEqual(collected['guardianInventory'], self.pin['guardianInventory'])

    def test_required_evidence_results_cannot_be_forged_by_totals(self):
        for kind in ('conformance','mutation','dvt-ci','dvt-conformance-4.12'):
            original = json.loads(Path(self.data['releaseEvidence'][kind]['path']).read_text())
            field = 'suites' if kind.startswith('dvt-') else 'controls'
            for name in original[field]:
                e = copy.deepcopy(original)
                if kind == 'conformance': e[field][name] = 'SKIP'
                elif kind == 'mutation': e[field][name]['restored'] = 'FAIL'
                else: e[field][name]['skipped'] = 1
                with self.subTest(kind=kind,name=name), self.assertRaises(a.Gate):
                    m.evidence_file(self.file_ref('bad-result',e),kind)
        e = json.loads(Path(self.data['releaseEvidence']['slither']['path']).read_text())
        e['findings']['aboveThreshold'] = ['unreviewed']
        with self.assertRaises(a.Gate): m.evidence_file(self.file_ref('finding',e),'slither')
        e['findings']['accepted'] = [dict(id='unreviewed',classification='accepted',reason='reviewed exception')]
        e['findings']['inScopeTotal'] = 1
        self.raw_findings(e, [('unreviewed', 'High', 'contracts/src/SuperPaymaster.sol')])
        m.evidence_file(self.file_ref('accepted-finding',e),'slither')

    def raw_findings(self, value, findings):
        raw = dict(success=True, error=None, results=dict(detectors=[dict(id=id, impact=impact,
            elements=[dict(source_mapping=dict(filename_relative=file))]) for id, impact, file in findings]))
        ref = self.file_ref('slither.raw', raw)
        value['rawReport'] = dict(path='slither.raw.json', sha256=ref['sha256'])

    def test_finding_path_canonical_gate(self):
        for path in ('./contracts/src/SuperPaymaster.sol', 'contracts//src/X.sol',
                     'contracts/../X.sol', '/tmp/X.sol', 'contracts\\X.sol', ''):
            value = json.loads(Path(self.data['releaseEvidence']['slither']['path']).read_text())
            value['findings']['outOfScope'] = [dict(id='hidden', impact='High', files=[path], classification='unclassified')]
            with self.subTest(path=path):
                with assert_stop(self, 'evidence_finding_path_canonical') as caught:
                    m.validate_evidence_details(value, 'slither', Path(self.tmp.name))
                self.assertEqual(caught.exception.record['gate'], 'evidence_finding_path_canonical')

    def test_finding_symlink_canonical_gate(self):
        value = json.loads(Path(self.data['releaseEvidence']['slither']['path']).read_text())
        tree = Path(self.tmp.name) / 'tree'
        tree.mkdir()
        (tree / 'Alias.sol').symlink_to('Actual.sol')
        value['findings']['outOfScope'] = [dict(id='alias', impact='High',
            files=['Alias.sol'], classification='unclassified')]
        with patch.object(m, 'rebuild_commit', return_value=dict(ART, tree=tree)):
            with assert_stop(self, 'evidence_finding_path_canonical') as caught:
                m.validate_evidence_details(value, 'slither', Path(self.tmp.name))
        self.assertEqual(caught.exception.record['gate'], 'evidence_finding_path_canonical')

    def test_slither_raw_rederived_gate(self):
        for attack in ('drop', 'hash', 'move'):
            value = json.loads(Path(self.data['releaseEvidence']['slither']['path']).read_text())
            self.raw_findings(value, [('hidden', 'High', 'contracts/src/SuperPaymaster.sol')])
            if attack == 'hash':
                value['rawReport']['sha256'] = 'f' * 64
            if attack == 'move':
                value['findings']['outOfScope'] = [dict(id='hidden', impact='High',
                    files=['contracts/lib/Fake.sol'], classification='unclassified')]
            with self.subTest(attack=attack):
                with assert_stop(self, 'evidence_slither_rederived') as caught:
                    m.validate_evidence_details(value, 'slither', Path(self.tmp.name))
                self.assertEqual(caught.exception.record['gate'], 'evidence_slither_rederived')

    def test_raw_absolute_mapping_rejected(self):
        for field in ('filename_relative', 'filename_absolute', 'filename_short'):
            for top_level in (False, True):
                with self.subTest(field=field, top_level=top_level):
                    value = json.loads(Path(self.data['releaseEvidence']['slither']['path']).read_text())
                    self.raw_findings(value, [('outside', 'High', 'contracts/lib/Outside.sol')])
                    value['findings']['outOfScope'] = [dict(id='outside', impact='High',
                        files=['contracts/lib/Outside.sol'], classification='unclassified')]
                    raw_path = Path(self.tmp.name) / 'slither.raw.json'
                    raw = json.loads(raw_path.read_text())
                    item = raw['results']['detectors'][0]
                    mapping = {field: '/__evidence_tree__/contracts/lib/Outside.sol'}
                    if top_level:
                        item['source_mapping'] = mapping
                    else:
                        item['elements'][0]['source_mapping'].update(mapping)
                    ref = self.file_ref('slither.raw', raw)
                    value['rawReport']['sha256'] = ref['sha256']
                    with assert_stop(self, 'evidence_slither_rederived') as caught:
                        m.validate_evidence_details(value, 'slither', Path(self.tmp.name))
                    self.assertEqual(caught.exception.record['gate'], 'evidence_slither_rederived')

    def test_raw_report_symlink_escape_rejected(self):
        for parent in (False, True):
            with self.subTest(parent=parent), tempfile.TemporaryDirectory() as external:
                value = json.loads(Path(self.data['releaseEvidence']['slither']['path']).read_text())
                raw = Path(self.tmp.name) / 'slither.raw.json'
                outside = Path(external) / 'report.json'
                outside.write_bytes(raw.read_bytes())
                link = Path(self.tmp.name) / ('linked-parent' if parent else 'linked-file')
                link.symlink_to(Path(external) if parent else outside, target_is_directory=parent)
                value['rawReport']['path'] = link.name + ('/report.json' if parent else '')
                with patch.object(m, 'reviewed_file', wraps=m.reviewed_file) as reviewed:
                    with assert_stop(self, 'evidence_slither_rederived') as caught:
                        m.validate_evidence_details(value, 'slither', Path(self.tmp.name))
                    self.assertEqual(caught.exception.record['gate'], 'evidence_slither_rederived')
                    reviewed.assert_not_called()

    def test_outside_high_medium_allowed(self):
        for impact in ('High', 'Medium'):
            value = json.loads(Path(self.data['releaseEvidence']['slither']['path']).read_text())
            value['findings']['outOfScope'] = [dict(id='lib', impact=impact,
                files=['contracts/lib/Token.sol'], classification='unclassified')]
            self.raw_findings(value, [('lib', impact, 'contracts/lib/Token.sol')])
            with self.subTest(impact=impact):
                m.validate_evidence_details(value, 'slither', Path(self.tmp.name))

    def test_scope_empty_and_dependency_disjointness(self):
        original = json.loads(Path(self.data['releaseEvidence']['slither']['path']).read_text())
        for files in ([], ['']):
            value = copy.deepcopy(original)
            value['scope']['files'] = files
            with assert_stop(self, 'evidence_scope_files') as caught:
                m.validate_evidence_details(value, 'slither', Path(self.tmp.name))
            self.assertEqual(caught.exception.record['gate'], 'evidence_scope_files')
        original['scope']['files'] = ['contracts/lib/Base.sol']
        with assert_stop(self, 'evidence_scope_recomputed') as caught:
            m.validate_evidence_details(original, 'slither', Path(self.tmp.name))
        self.assertEqual(caught.exception.record['gate'], 'evidence_scope_recomputed')
        with patch.object(m, 'rebuild_commit', return_value=dict(commit=ART['commit'], scope=copy.deepcopy(original['scope']))):
            m.validate_evidence_details(original, 'slither', Path(self.tmp.name))
        original['scope']['files'] = ART['scope']['files']
        original['findings']['outOfScope'] = [dict(id='lib', impact='High',
            files=['contracts/src/SuperPaymaster.sol'], classification='unclassified')]
        with assert_stop(self, 'evidence_outside_files') as caught:
            m.validate_evidence_details(original, 'slither', Path(self.tmp.name))
        self.assertEqual(caught.exception.record['gate'], 'evidence_outside_files')

    def test_fabricated_scope_hides_high_finding(self):
        value = json.loads(Path(self.data['releaseEvidence']['slither']['path']).read_text())
        value['scope']['files'] = ['contracts/lib/Fabricated.sol']
        value['findings']['outOfScope'] = [dict(id='hidden', impact='High',
            files=['contracts/src/SuperPaymaster.sol'], classification='unclassified')]
        with assert_stop(self, 'evidence_scope_recomputed') as caught:
            m.validate_evidence_details(value, 'slither', Path(self.tmp.name))
        self.assertEqual(caught.exception.record['gate'], 'evidence_scope_recomputed')

    def test_finding_ids_unique_across_scope_partitions(self):
        original = json.loads(Path(self.data['releaseEvidence']['slither']['path']).read_text())
        outside = dict(id='duplicate', impact='High', files=['contracts/lib/Outside.sol'],
                       classification='unclassified')
        for overlap in (False, True):
            value = copy.deepcopy(original)
            value['findings']['outOfScope'] = [outside] if overlap else [outside, outside]
            if overlap:
                value['findings'].update(aboveThreshold=['duplicate'], inScopeTotal=1,
                    accepted=[dict(id='duplicate', classification='accepted', reason='reviewed')])
            with self.subTest(overlap=overlap), self.assertRaises(a.Gate) as caught:
                m.validate_evidence_details(value, 'slither', Path(self.tmp.name))
            self.assertEqual(caught.exception.record['gate'],
                             'evidence_outside_not_reviewed' if overlap else 'evidence_outside_unique')

    def test_closure_finding_cannot_be_outside(self):
        value = json.loads(Path(self.data['releaseEvidence']['slither']['path']).read_text())
        value['findings']['outOfScope'] = [dict(id='hidden', impact='High',
            files=ART['scope']['files'], classification='unclassified')]
        with assert_stop(self, 'evidence_outside_files') as caught:
            m.validate_evidence_details(value, 'slither', Path(self.tmp.name))
        self.assertEqual(caught.exception.record['gate'], 'evidence_outside_files')

    def test_evidence_full_creation_required(self):
        value = json.loads(Path(self.data['releaseEvidence']['reproducible-build']['path']).read_text())
        for name in m.NAMES:
            changed = copy.deepcopy(value)
            changed['contracts'][name]['strippedCreationKeccak'] = a.ZERO32
            with self.subTest(contract=name), assert_stop(self, 'evidence_full_creation_' + name) as caught:
                m.validate_evidence_details(changed, 'reproducible-build')
            self.assertEqual(caught.exception.record['gate'], 'evidence_full_creation_'+name)

    def test_layout_pair_identity_required(self):
        original = json.loads(Path(self.data['releaseEvidence']['slither']['path']).read_text())
        for index in range(len(m.LAYOUT_PAIRS)):
            for field in ('core', 'extension', 'reference'):
                value = copy.deepcopy(original)
                value['storageLayout'][index][field] = 'substituted'
                with self.subTest(index=index, field=field), assert_stop(self, 'evidence_layout_identity') as caught:
                    m.validate_evidence_details(value, 'slither', Path(self.tmp.name))
                self.assertEqual(caught.exception.record['gate'], 'evidence_layout_identity')

    def test_layout_pair_parity_required(self):
        value = json.loads(Path(self.data['releaseEvidence']['slither']['path']).read_text())
        value['storageLayout'][0]['extensionTable']['storage'][0]['slot'] = '999'
        with assert_stop(self, 'evidence_layout_parity') as caught:
            m.validate_evidence_details(value, 'slither', Path(self.tmp.name))
        self.assertEqual(caught.exception.record['gate'], 'evidence_layout_parity')

    def test_slither_scope_counts_and_parity_tampering_rejected(self):
        original = json.loads(Path(self.data['releaseEvidence']['slither']['path']).read_text())
        def change_count(e): e['findings']['inScopeTotal'] = 1
        def omit_pair(e): e['storageLayout'].pop()
        def change_slot(e): e['storageLayout'][0]['extensionTable']['storage'][0]['slot'] = '1'
        def change_namespace(e): e['storageLayout'][1]['extensionTable']['namespaces'].append(
            dict(label='namespace', slot='100', offset=0, type='address'))
        def wrong_scope(e): e['scope']['contracts'].pop()
        def reviewed_outside(e): e['findings']['outOfScope'] = [dict(id='outside', impact='High',
            files=['contracts/lib/Other.sol'], classification='accepted')]
        def overlap(e): e['findings']['outOfScope'] = [dict(id='outside', impact='High',
            files=['contracts/src/SuperPaymaster.sol'], classification='unclassified')]
        for mutate in (change_count, omit_pair, change_slot, change_namespace, wrong_scope, reviewed_outside, overlap):
            value = copy.deepcopy(original)
            mutate(value)
            with self.subTest(mutation=mutate.__name__), self.assertRaises(a.Gate):
                m.validate_evidence_details(value, 'slither', Path(self.tmp.name))

    def test_collect_registry_version_negative(self):
        with patch.object(m.isolation, 'collect_deployed', return_value=self.pin['oldOwnerIsolation']), \
             patch.object(u, 'collect', return_value=copy.deepcopy(self.pin)), \
             patch.object(a, 'nonce', return_value=55), patch.object(u, 'code', return_value='0x'), \
             patch.object(a, 'call', return_value='0x'):
            with assert_stop(self, 'registry_version') as caught: m.collect(lambda method,params:'0x1', '0x100', self.inputs)
        self.assertEqual(caught.exception.record['gate'], 'registry_version')

    def test_sign_send_refused(self):
        self.assertEqual(m.main(['sign']), 3)
        self.assertEqual(m.main(['send']), 3)


class RealCreationTests(unittest.TestCase):
    root = Path(__file__).with_name('fixtures')

    def verifier(self):
        return json.loads((self.root / 'dvt-creation.json').read_text())['creationBytecode']

    def compare(self, name, first, second):
        return m.compare_build_evidence({'contracts': {name: m.creation_hashes(first, name)}},
            {name: {'bytecode': second, 'creationHashes': m.creation_hashes(second, name)}})

    def test_real_rc6_full_creation(self):
        for path in (self.root / 'real-creation').glob('*.json'):
            if path.name == 'INDEX.json': continue
            fixture = json.loads(path.read_text())
            code, name = fixture['creationBytecode'], fixture['contract']
            with self.subTest(contract=name):
                hashes = m.creation_hashes(code)
                self.assertEqual(hashes['fullCreationKeccak'], a.keccak(code))
                self.assertEqual(hashes['strippedCreationKeccak'], hashes['fullCreationKeccak'])
                self.assertEqual(self.compare(name, code, code), [])
                for changed in ('0x00' + code[4:], code + '00', code[:-2] + 'ff'):
                    with self.assertRaises(a.Gate): self.compare(name, code, changed)

    def test_sp_full_hash_guard(self):
        name = 'SuperPaymaster'
        code = json.loads((self.root / 'real-creation' / (name + '.json')).read_text())['creationBytecode']
        hashes = m.creation_hashes(code)
        forged = dict(hashes, fullCreationKeccak=a.ZERO32)
        with self.assertRaises(a.Gate):
            m.compare_build_evidence({'contracts': {name: forged}},
                {name: {'bytecode': code, 'creationHashes': hashes}})

    def test_dvt_real_metadata_only(self):
        code = self.verifier()
        self.assertEqual(a.keccak(code), m.VERIFIER_CREATION)
        self.assertEqual(m.creation_hashes(code, 'OverIssueFraudProofVerifier')['strippedCreationKeccak'], m.VERIFIER_EXECUTABLE)
        fixture = json.loads((self.root / 'dvt-creation.json').read_text())
        self.assertEqual(fixture['metadataLayout'], m.VERIFIER_METADATA_LAYOUT)
        self.assertEqual(code[2+319*2:], fixture['runtimeBytecode'][2:])
        changed = bytearray.fromhex(code[2:])
        changed[3260] ^= 1  # IPFS digest, inside the pinned CBOR bytes value.
        changed = '0x' + changed.hex()
        self.assertEqual(self.compare('OverIssueFraudProofVerifier', code, changed), ['OverIssueFraudProofVerifier'])
        self.assertEqual(m.verifier_executable(code), m.verifier_executable(changed))

    def test_dvt_outside_segment_and_forged_pattern(self):
        code = self.verifier()
        for offset, value in ((0, b'\x00'), (100, bytes.fromhex('a164736f6c6343000821000a'))):
            changed = bytearray.fromhex(code[2:])
            changed[offset:offset+len(value)] = value
            with self.subTest(offset=offset), self.assertRaises(a.Gate):
                self.compare('OverIssueFraudProofVerifier', code, '0x' + changed.hex())

    def test_dvt_wrong_segment_count_or_position(self):
        for segments in ([], m.VERIFIER_METADATA_LAYOUT['segments'] * 2,
                         [{'offset': 3246, 'length': 54}]):
            with self.subTest(segments=segments), self.assertRaises(a.Gate):
                m.verifier_executable(self.verifier(), {'byteLength': 3300, 'segments': segments})

    def test_dvt_appended_data(self):
        for suffix in ('00', 'a164736f6c6343000821000a'):
            with self.subTest(suffix=suffix), self.assertRaises(a.Gate):
                m.creation_hashes(self.verifier() + suffix, 'OverIssueFraudProofVerifier')

    def test_verifier_metadata_solc_required(self):
        changed = bytearray.fromhex(self.verifier()[2:])
        changed[-3] ^= 1
        with assert_stop(self, 'verifier_metadata_solc') as caught:
            m.verifier_executable('0x' + changed.hex())
        self.assertEqual(caught.exception.record['gate'], 'verifier_metadata_solc')

    def test_verifier_segment_length_required(self):
        changed = bytearray.fromhex(self.verifier()[2:])
        changed[-1] -= 1
        with assert_stop(self, 'verifier_segment_length') as caught:
            m.verifier_executable('0x' + changed.hex())
        self.assertEqual(caught.exception.record['gate'], 'verifier_segment_length')

    def test_reproducible_reference_bytes_required(self):
        name = 'SuperPaymaster'
        first, second = '0x6000', '0x6001'
        hashes = m.creation_hashes(second, name)
        # Evidence and rebuilt hashes agree; only the independent reference differs.
        with assert_stop(self, 'reproducible_bytes_' + name) as caught:
            m.compare_build_evidence(dict(contracts={name: hashes}),
                {name: dict(bytecode=second, creationHashes=hashes)},
                reference_contracts={name: dict(bytecode=first)})
        self.assertEqual(caught.exception.record['gate'], 'reproducible_bytes_'+name)

    def test_dvt_segment_length_and_keys(self):
        code = self.verifier()
        for offset, value in ((3299, 0x32), (3249, ord('x'))):
            changed = bytearray.fromhex(code[2:])
            changed[offset] = value
            with self.subTest(offset=offset), self.assertRaises(a.Gate):
                m.creation_hashes('0x' + changed.hex(), 'OverIssueFraudProofVerifier')


class SafeGovernanceTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(__file__).with_name('fixtures')/'safe-governance'
        self.chain = json.loads((self.root/'chain-reads.json').read_text())
        self.original_hashes = {key: {endpoint: item['tx']['hash'] for endpoint, item in endpoints.items()}
                                for key, endpoints in self.chain.items()}
        self.inputs = dict(data=json.loads((self.root/'inputs.json').read_text()))
        self.packet = json.loads((self.root/'packet-460e0244.json').read_text())
        self.pin = dict(stateBlock=hex(12060363), safeNonce=4,
            safe=dict(owners=sorted(self.packet['expectedReadback']['owners']), threshold=2,
                      codes={w:'0x' for w in self.packet['expectedReadback']['owners']}),
            senders={label:dict(address=who, nonce=n) for label,who,n in
                     [('deployer', a.DEPLOYER, 12139), ('approver', a.APPROVER, 101), ('executor', a.EXECUTOR, 756)]})
        self.chain_state = {endpoint: copy.deepcopy(self.pin) for endpoint in ('a', 'b')}
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        path = Path(self.tmp.name)/'plan.json'
        path.write_text(json.dumps(dict(steps=[dict(id=sid, tx={'from':who, 'nonce':hex(n)}) for sid,who,n in
            [('S7',a.DEPLOYER,12138), ('S6a',a.APPROVER,98), ('S6b',a.EXECUTOR,754)]])))
        self.inputs['data']['a3aPlan'] = dict(path=str(path), sha256=hashlib.sha256(path.read_bytes()).hexdigest())

    def rpc(self, endpoint):
        def read(method, params):
            for key, endpoints in self.chain.items():
                value = endpoints[endpoint]
                if params[0] == self.original_hashes[key][endpoint]:
                    return value[{'eth_getTransactionByHash':'tx', 'eth_getTransactionReceipt':'receipt', 'debug_traceTransaction':'diff'}[method]]
                if method == 'eth_getBlockByNumber' and params[0] == value['tx']['blockNumber']:
                    return value['block']
            if method == 'eth_getCode': return self.chain_state[endpoint]['safe']['codes'][params[0]]
            if method == 'eth_call':
                data = params[0]['data']
                if data == a.calldata('getOwners()'):
                    return a.cast('abi-encode', 'c(address[])', '['+','.join(self.chain_state[endpoint]['safe']['owners'])+']')
                if data == a.calldata('getThreshold()'): return '0x'+format(self.chain_state[endpoint]['safe']['threshold'], '064x')
                if data == a.calldata('nonce()'): return '0x'+format(self.chain_state[endpoint]['safeNonce'], '064x')
            raise AssertionError((method, params))
        return read

    def verify(self):
        m.nonce_expectations(self.pin, self.inputs)
        m.governance_evidence(self.pin, self.inputs, [self.rpc('a'), self.rpc('b')])
        m.governance_evidence(self.pin, self.inputs)

    def stop(self, gate, mutate):
        self.verify()  # The same harness must pass before each mutation.
        mutate()
        with assert_stop(self, gate) as caught: self.verify()
        self.assertEqual(caught.exception.record['gate'], gate)

    def test_real_chain_and_offline_replay(self):
        self.verify()
        evidence = self.pin['safeGovernanceGaps']
        self.assertFalse(evidence['partOfA3aPlan'])
        self.assertEqual([r['traceEndpoints'] for r in evidence['transactions']], [1, 1, 1])
        evidence['reads']['a'][0]['result']['input'] = '0x00'
        with assert_stop(self, 'safe_gap_input') as caught: m.governance_evidence(self.pin, self.inputs)
        self.assertEqual(caught.exception.record['gate'], 'safe_gap_input')

    def test_replay_duplicate_unused_and_endpoint_copy(self):
        for mutation, gate in [('duplicate', 'safe_gap_proof_duplicate'),
                               ('unused', 'safe_gap_proof_unused'), ('copy', 'safe_gap_trace_counts')]:
            with self.subTest(mutation=mutation):
                self.verify()
                evidence = self.pin['safeGovernanceGaps']
                if mutation == 'duplicate':
                    evidence['reads']['a'].append(copy.deepcopy(evidence['reads']['a'][0]))
                elif mutation == 'unused':
                    evidence['reads']['a'].append(dict(method='eth_unused', params=[], result=None))
                else:
                    evidence['reads']['b'] = copy.deepcopy(evidence['reads']['a'])
                    for tx in evidence['transactions']: tx['traceEndpoints'] = 2
                with assert_stop(self, gate) as caught:
                    m.governance_evidence(self.pin, self.inputs)
                self.assertEqual(caught.exception.record['gate'], gate)

    def test_miner_aliases(self):
        for miner in (a.SAFE, a.APPROVER, a.EXECUTOR, self.packet['swapOwner']['old'], self.packet['swapOwner']['new']):
            with self.subTest(miner=miner):
                self.setUp()
                for endpoint in ('a', 'b'):
                    original = self.chain['A99'][endpoint]['block']['miner']
                    self.stop('safe_gap_miner_alias', lambda: self.chain['A99'][endpoint]['block'].update(miner=miner))
                    self.chain['A99'][endpoint]['block']['miner'] = original

    def test_log_identity_fields(self):
        for field in ('transactionHash', 'blockHash', 'blockNumber', 'transactionIndex', 'logIndex'):
            with self.subTest(field=field):
                self.setUp()
                log = self.chain['E755']['a']['receipt']['logs'][1]
                value = a.ZERO32 if field.endswith('Hash') else hex(a.qty(log[field]) + 2)
                self.stop('safe_gap_log_' + field, lambda: log.update({field:value}))

    def test_receipt_index_bound_to_mined_transaction(self):
        # Receipt and all logs moved together to another index: only the mined tx binds it.
        def move():
            for endpoint in ('a', 'b'):
                receipt = self.chain['E755'][endpoint]['receipt']
                receipt['transactionIndex'] = '0x0'
                for log in receipt['logs']: log['transactionIndex'] = '0x0'
        self.stop('safe_gap_receipt_identity', move)

    def test_malformed_trace_gates(self):
        cases = [
            ('shape', 'safe_gap_trace_account_shape'), ('unknown', 'safe_gap_trace_account_shape'),
            ('balance', 'safe_gap_trace_balance'), ('nonce', 'safe_gap_trace_nonce'),
            ('storage_list', 'safe_gap_trace_storage'), ('storage_key', 'safe_gap_trace_storage'),
            ('storage_value', 'safe_gap_trace_storage'), ('code', 'safe_gap_trace_code'),
            ('missing_sender', 'safe_gap_sender_pre_balance'),
            ('missing_miner', 'safe_gap_miner_balance'), ('miner_equal', 'safe_gap_miner_balance'),
            ('miner_less', 'safe_gap_miner_balance'), ('miner_invalid', 'safe_gap_trace_balance')]
        for case, gate in cases:
            with self.subTest(case=case):
                self.setUp()
                def mutate():
                    item = self.chain['A99']['a']
                    pre, post = item['diff']['pre'], item['diff']['post']
                    sender, miner = item['tx']['from'], item['block']['miner']
                    if case == 'shape': pre[sender] = []
                    elif case == 'unknown': pre[sender]['other'] = 0
                    elif case == 'balance': pre[sender]['balance'] = 1
                    elif case == 'nonce': pre[sender]['nonce'] = '0x63'
                    elif case == 'storage_list': pre[sender]['storage'] = []
                    elif case == 'storage_key': pre[sender]['storage'] = {'bad':a.ZERO32}
                    elif case == 'storage_value': pre[sender]['storage'] = {a.ZERO32:False}
                    elif case == 'code': pre[sender]['code'] = 1
                    elif case == 'missing_sender': del pre[sender]['balance']
                    elif case == 'missing_miner': post[miner] = {}
                    elif case == 'miner_invalid': post[miner]['balance'] = 'invalid'
                    else:
                        pre.setdefault(miner, {})['balance'] = post[miner]['balance']
                        if case == 'miner_less': post[miner]['balance'] = '0x0'
                self.stop(gate, mutate)

    def test_event_topics_derived_offline(self):
        for signature, topic in m.SAFE_EVENTS.items(): self.assertEqual(a.keccak(signature), topic)
        self.verify()

    def test_transaction_controls(self):
        for field, value, gate in [('input',self.chain['A99']['a']['tx']['input'][:-2]+'00','input'), ('authorizationList',[{}],'authorizations'), ('authorizationList',None,'authorizations'),
                                 ('chainId','0x1','chainId'), ('gas','0x1','gas'), ('type','0x4','type')]:
            with self.subTest(field=field):
                self.setUp()
                self.stop('safe_gap_'+gate, lambda: self.chain['A99']['a']['tx'].update({field:value}))

    def test_status_controls(self):
        for key,status in [('A99','0x1'), ('A100','0x0'), ('E755','0x0')]:
            with self.subTest(key=key):
                self.setUp()
                self.stop('safe_gap_status', lambda: self.chain[key]['a']['receipt'].update(status=status))

    def test_log_controls(self):
        self.stop('safe_gap_logs', lambda: self.chain['A100']['a']['receipt']['logs'].append(copy.deepcopy(self.chain['A100']['a']['receipt']['logs'][0])))
        self.setUp()
        self.stop('safe_gap_logs', lambda: self.chain['E755']['b']['receipt']['logs'][1]['topics'].__setitem__(0, a.ZERO32))
        self.setUp()
        self.stop('safe_gap_logs', lambda: self.chain['A99']['a']['receipt']['logs'].append(self.chain['A100']['a']['receipt']['logs'][0]))

    def test_storage_controls(self):
        post = lambda: self.chain['E755']['a']['diff']['post'][a.SAFE]['storage']
        self.stop('safe_gap_storage_slots', lambda: post().update({a.ZERO32:a.ZERO32}))
        for key in ['0x'+format(5,'064x'), a.keccak('0x'+a.APPROVER[2:].zfill(64)+format(2,'064x'))]:
            self.setUp()
            self.stop('safe_gap_storage_value', lambda: post().update({key:'0x'+format(5,'064x')}))
        self.setUp()
        self.stop('safe_gap_storage_slots', lambda: self.chain['E755']['a']['diff']['pre'][a.SAFE]['storage'].update({a.ZERO32:'0x'+format(1, '064x')}))

    def test_trace_account_controls(self):
        for field,value in [('balance','0x1'), ('code','0x00'), ('nonce',2)]:
            self.setUp()
            self.stop('safe_gap_safe_fields', lambda: self.chain['A100']['a']['diff']['post'][a.SAFE].update({field:value}))
        self.setUp()
        self.stop('safe_gap_trace_accounts', lambda: self.chain['E755']['a']['diff']['post'].update({a.ZERO:{'balance':'0x1'}}))
        self.setUp()
        self.stop('safe_gap_trace_accounts', lambda: self.chain['A99']['a']['diff']['post'].update({a.SAFE:{'storage':{a.ZERO32:'0x1'}}}))
        self.setUp()
        self.stop('safe_gap_trace_available', lambda: self.chain['A99']['a'].update(diff={'__error':'unavailable'}))

    def test_packet_digest(self):
        self.stop('safe_gap_packet', lambda: self.inputs['data']['safeGovernanceGaps'][0].update(sha256='1'*64))

    def test_pin_owner_controls(self):
        self.stop('safe_gap_pin_owners', lambda: self.pin['safe'].update(owners=sorted(a.safe_owners(hex(12060358)))))
        self.setUp()
        self.stop('safe_gap_owner_eoa', lambda: self.pin['safe']['codes'].update({a.APPROVER:'0xef0100'+'11'*20}))
        self.setUp()
        self.stop('safe_gap_pin_nonce', lambda: self.pin.update(safeNonce=5))
        self.setUp()
        self.stop('safe_gap_pin_threshold', lambda: self.pin['safe'].update(threshold=1))

    def test_live_owner_code_on_one_endpoint(self):
        self.verify()
        original = self.rpc('b')
        def delegated(method, params):
            if method == 'eth_getCode' and params[0] == a.APPROVER: return '0xef0100'+'11'*20
            return original(method, params)
        with assert_stop(self, 'safe_gap_owner_eoa') as caught:
            m.governance_evidence(self.pin, self.inputs, [self.rpc('a'), delegated])
        self.assertEqual(caught.exception.record['gate'], 'safe_gap_owner_eoa')

    def test_dual_identity_and_sender_balance(self):
        self.stop('safe_gap_dual_identity', lambda: self.chain['E755']['b']['block'].update(miner='0x'+'22'*20))
        self.setUp()
        def unpaid():
            diff = self.chain['A100']['a']['diff']
            diff['post'][a.APPROVER]['balance'] = diff['pre'][a.APPROVER]['balance']
        self.stop('safe_gap_sender_balance', unpaid)

    def test_owner_swap_block_bound_to_chain(self):
        self.verify()
        with patch.object(a, 'OWNER_SWAP_BLOCK', 12060360):
            with assert_stop(self, 'safe_gap_owner_swap_block') as caught: m.governance_evidence(self.pin, self.inputs, [self.rpc('a'), self.rpc('b')])
        self.assertEqual(caught.exception.record['gate'], 'safe_gap_owner_swap_block')

    def test_miner_priority_fee_exact(self):
        for key in ('A99', 'A100', 'E755'):
            for delta in (1, -1):
                with self.subTest(key=key, delta=delta):
                    self.setUp()
                    def shift():
                        diff, miner = self.chain[key]['a']['diff'], self.chain[key]['a']['block']['miner']
                        diff['post'][miner]['balance'] = hex(int(diff['post'][miner]['balance'], 16) + delta)
                    self.stop('safe_gap_miner_balance', shift)

    def test_base_fee_required_and_agreed(self):
        self.stop('safe_gap_base_fee', lambda: self.chain['A100']['a']['block'].pop('baseFeePerGas'))
        self.setUp()
        def shift():
            item = self.chain['A100']['b']
            item['block']['baseFeePerGas'] = hex(a.qty(item['block']['baseFeePerGas']) + 1)
            item['receipt']['effectiveGasPrice'] = hex(a.qty(item['receipt']['effectiveGasPrice']) + 1)
        self.stop('safe_gap_dual_identity', shift)

    def test_effective_gas_price_anchor(self):
        for endpoint in ('a', 'b'):
            for case in ('above_cap', 'below_base', 'off_by_one'):
                with self.subTest(endpoint=endpoint, case=case):
                    self.setUp()
                    item = self.chain['A99'][endpoint]
                    price = {'above_cap': a.qty(item['tx']['maxFeePerGas']) + 1,
                             'below_base': a.qty(item['block']['baseFeePerGas']) - 1,
                             'off_by_one': a.qty(item['receipt']['effectiveGasPrice']) + 1}[case]
                    self.stop('safe_gap_effective_gas_price',
                              lambda: item['receipt'].update(effectiveGasPrice=hex(price)))

    def test_zero_gas_used(self):
        for endpoint in ('a', 'b'):
            with self.subTest(endpoint=endpoint):
                self.setUp()
                self.stop('safe_gap_gas_used_positive',
                          lambda: self.chain['A99'][endpoint]['receipt'].update(gasUsed='0x0'))

    def test_dual_receipt_gas_used(self):
        item = self.chain['A99']['b']
        self.stop('safe_gap_dual_identity',
                  lambda: item['receipt'].update(gasUsed=hex(a.qty(item['receipt']['gasUsed']) + 1)))

    def test_miner_absent_pre_balance(self):
        for key in ('A99', 'A100', 'E755'):
            with self.subTest(key=key):
                self.setUp()
                item = self.chain[key]['a']
                miner = item['block']['miner']
                item['diff']['pre'].pop(miner)
                priority_fee = a.qty(item['receipt']['gasUsed']) * (
                    a.qty(item['receipt']['effectiveGasPrice']) - a.qty(item['block']['baseFeePerGas']))
                item['diff']['post'][miner]['balance'] = hex(priority_fee)
                self.stop('safe_gap_miner_balance',
                          lambda: item['diff']['post'][miner].update(balance=hex(priority_fee + 1)))

    def test_block_transaction_membership(self):
        for endpoint in ('a', 'b'):
            for case, gate in [('other_index', 'safe_gap_block_transaction'),
                               ('missing', 'safe_gap_block_transactions'),
                               ('out_of_range', 'safe_gap_block_transaction'),
                               ('different_list', 'safe_gap_dual_identity')]:
                with self.subTest(endpoint=endpoint, case=case):
                    self.setUp()
                    def mutate():
                        item = self.chain['A99'][endpoint]
                        transactions = item['block']['transactions']
                        index = a.qty(item['tx']['transactionIndex'])
                        other = 0 if index else 1
                        if case == 'missing': item['block'].pop('transactions')
                        elif case == 'out_of_range': item['block']['transactions'] = []
                        elif case == 'different_list': transactions[other] = a.ZERO32
                        else: transactions[index], transactions[other] = transactions[other], transactions[index]
                    self.stop(gate, mutate)

    def test_exact_nonce_coverage(self):
        self.stop('prepin_nonce_approver', lambda: self.pin['senders']['approver'].update(nonce=102))
        self.setUp()
        self.stop('prepin_nonce_approver', lambda: self.inputs['data']['safeGovernanceGaps'].pop(0))
        self.setUp()
        self.stop('safe_gap_unique', lambda: self.inputs['data']['safeGovernanceGaps'].append(self.inputs['data']['safeGovernanceGaps'][0]))
        self.setUp()
        self.stop('prepin_nonce_approver', lambda: self.inputs['data']['a3aPlan'].update(nonceGaps=[
            {'from':a.APPROVER, 'nonce':hex(99), 'hash':self.chain['A99']['a']['tx']['hash']}]))
        self.setUp()
        self.stop('prepin_nonce_deployer', lambda: self.pin['senders']['deployer'].update(nonce=12140))

    def test_missing_transaction(self):
        self.verify()
        original = self.rpc('b')
        def missing(method, params):
            if method == 'eth_getTransactionByHash': return None
            return original(method, params)
        with assert_stop(self, 'safe_gap_found') as caught:
            m.governance_evidence(self.pin, self.inputs, [self.rpc('a'), missing])
        self.assertEqual(caught.exception.record['gate'], 'safe_gap_found')

    def test_block_controls(self):
        self.stop('safe_gap_before_pin', lambda: self.chain['E755']['a']['tx'].update(blockNumber=hex(12060364)))
        self.setUp()
        self.stop('safe_gap_canonical', lambda: self.chain['A100']['b']['block'].update(hash=a.ZERO32))

    def test_trace_rpc_failure_is_recorded_and_fails_closed(self):
        self.verify()
        def unavailable(endpoint):
            original = self.rpc(endpoint)
            def read(method, params):
                if method == 'debug_traceTransaction':
                    raise a.Gate('rpc_fault', {'method':method, 'code':-32601}, 'successful RPC')
                return original(method, params)
            return read
        m.governance_evidence(self.pin, self.inputs, [self.rpc('a'), unavailable('b')])
        m.governance_evidence(self.pin, self.inputs)
        self.assertEqual([r['traceEndpoints'] for r in self.pin['safeGovernanceGaps']['transactions']], [1,1,1])
        with assert_stop(self, 'safe_gap_trace_available') as caught:
            m.governance_evidence(self.pin, self.inputs, [unavailable('a'), unavailable('b')])
        self.assertEqual(caught.exception.record['gate'], 'safe_gap_trace_available')

    def test_replay_evidence_required_and_counts_checked(self):
        self.verify()
        self.pin['safeGovernanceGaps']['transactions'][0]['traceEndpoints'] = 2
        with assert_stop(self, 'safe_gap_trace_counts') as caught: m.governance_evidence(self.pin, self.inputs)
        self.assertEqual(caught.exception.record['gate'], 'safe_gap_trace_counts')
        del self.pin['safeGovernanceGaps']
        with assert_stop(self, 'safe_gap_evidence') as caught: m.governance_evidence(self.pin, self.inputs)
        self.assertEqual(caught.exception.record['gate'], 'safe_gap_evidence')

    def test_sender_and_miner_trace_controls(self):
        cases = [('sender_nonce', 'safe_gap_sender_nonce'),
                 ('sender_balance_up', 'safe_gap_sender_balance'),
                 ('sender_wrong_delta', 'safe_gap_sender_balance'),
                 ('sender_storage', 'safe_gap_sender_storage'),
                 ('sender_code', 'safe_gap_sender_code'),
                 ('miner_storage', 'safe_gap_miner_storage'),
                 ('sender_absent', 'safe_gap_trace_sender'),
                 ('sender_fields', 'safe_gap_sender_fields'),
                 ('miner_fields', 'safe_gap_miner_fields'),
                 ('trace_shape', 'safe_gap_trace_shape')]
        for case, gate in cases:
            with self.subTest(case=case):
                self.setUp()
                def mutate():
                    item = self.chain['A99']['a']
                    pre, post = item['diff']['pre'], item['diff']['post']
                    sender, miner = item['tx']['from'], item['block']['miner']
                    if case == 'sender_nonce': post[sender]['nonce'] += 1
                    elif case == 'sender_balance_up': post[sender]['balance'] = hex(a.qty(pre[sender]['balance']) + 1)
                    elif case == 'sender_wrong_delta': post[sender]['balance'] = hex(a.qty(post[sender]['balance']) + 1)
                    elif case == 'sender_storage': pre[sender]['storage'] = {a.ZERO32:a.ZERO32}
                    elif case == 'sender_code': pre[sender]['code'] = '0x00'
                    elif case == 'miner_storage': pre.setdefault(miner, {})['storage'] = {a.ZERO32:a.ZERO32}
                    elif case == 'sender_absent': del pre[sender]
                    elif case == 'sender_fields': post[sender]['code'] = '0x'
                    elif case == 'miner_fields': post[miner]['nonce'] = 1
                    elif case == 'trace_shape': item['diff']['extra'] = {}
                self.stop(gate, mutate)

    def test_log_bytes_and_removed_controls(self):
        for key, index, field, value, gate in [
                ('A100', 0, 'data', '0x00', 'safe_gap_log_data'),
                ('E755', 0, 'data', '0x00', 'safe_gap_log_data'),
                ('E755', 1, 'data', '0x00', 'safe_gap_log_data'),
                ('E755', 0, 'removed', True, 'safe_gap_log_removed')]:
            with self.subTest(key=key, index=index, field=field):
                self.setUp()
                self.stop(gate, lambda: self.chain[key]['a']['receipt']['logs'][index].update({field:value}))

    def test_dual_transaction_index(self):
        def move():
            item = self.chain['E755']['b']
            old = a.qty(item['tx']['transactionIndex'])
            transactions = item['block']['transactions']
            transactions[old], transactions[old + 1] = transactions[old + 1], transactions[old]
            index = hex(old + 1)
            for obj in [item['tx'], item['receipt'], *item['receipt']['logs']]:
                obj['transactionIndex'] = index
        self.stop('safe_gap_dual_identity', move)

    def test_independent_chain_state(self):
        for endpoint in ('a', 'b'):
            for field, gate in [('owners', 'safe_gap_pin_owners'), ('threshold', 'safe_gap_pin_threshold'),
                                ('nonce', 'safe_gap_pin_nonce'), ('code', 'safe_gap_owner_eoa')]:
                with self.subTest(endpoint=endpoint, field=field):
                    self.setUp()
                    def mutate():
                        state = self.chain_state[endpoint]
                        if field == 'owners': state['safe']['owners'] = [a.ZERO]
                        elif field == 'threshold': state['safe']['threshold'] = 1
                        elif field == 'nonce': state['safeNonce'] = 5
                        else: state['safe']['codes'][a.APPROVER] = '0x00'
                    self.stop(gate, mutate)

    def test_mined_and_receipt_controls(self):
        for part, field, value, gate in [
                ('tx', 'hash', a.ZERO32, 'safe_gap_hash'),
                ('block', 'number', '0x1', 'safe_gap_block_number'),
                ('receipt', 'logs', {}, 'safe_gap_logs_shape'),
                ('receipt', 'gasUsed', None, 'safe_gap_gas_used'),
                ('receipt', 'effectiveGasPrice', None, 'safe_gap_gas_price')]:
            with self.subTest(part=part, field=field):
                self.setUp()
                self.stop(gate, lambda: self.chain['A99']['a'][part].update({field:value}))
        for part, gate in [('block', 'safe_gap_block'), ('receipt', 'safe_gap_receipt')]:
            with self.subTest(part=part):
                self.setUp()
                self.stop(gate, lambda: self.chain['A99']['a'].update({part:None}))

    def test_packet_semantic_controls(self):
        # Digest checking is tested separately. Inject a reviewed packet here to
        # isolate semantic defenses behind the fixed digest allowlist.
        for case, gate in [('reviewed', 'safe_gap_reviewed_packet'), ('step', 'safe_gap_step'),
                           ('packet_step', 'safe_gap_packet_step'), ('safe', 'safe_gap_safe'),
                           ('chain', 'safe_gap_packet_chain'), ('hash', 'safe_gap_safe_hash')]:
            with self.subTest(case=case):
                self.setUp()
                entry = self.inputs['data']['safeGovernanceGaps'][1]
                packet = copy.deepcopy(self.packet)
                inputs = dict(data=dict(safeGovernanceGaps=[entry]))
                with patch.object(m, 'reviewed_file', return_value=packet):
                    m.governance_entries(inputs)
                    if case == 'reviewed': entry['sha256'] = '1'*64
                    elif case == 'step': entry['step'] = 'invalid'
                    elif case == 'packet_step': packet['transactions'].append(copy.deepcopy(packet['transactions'][0]))
                    elif case == 'safe':
                        for tx in packet['transactions']: tx['to'] = a.ZERO
                    elif case == 'chain': packet['chainId'] = 1
                    elif case == 'hash': packet['safeTxHash'] = a.ZERO32
                    with assert_stop(self, gate) as caught: m.governance_entries(inputs)
                    self.assertEqual(caught.exception.record['gate'], gate)

    def test_list_and_endpoint_controls(self):
        with assert_stop(self, 'safe_gap_list') as caught: m.governance_entries(dict(data=dict(safeGovernanceGaps={})))
        self.assertEqual(caught.exception.record['gate'], 'safe_gap_list')
        for check in (m.check_governance, m.governance_evidence):
            with self.subTest(check=check.__name__):
                with assert_stop(self, 'safe_gap_endpoints') as caught:
                    if check == m.check_governance: check([self.rpc('a')], self.pin, self.inputs)
                    else: check(self.pin, self.inputs, [self.rpc('a')])
                self.assertEqual(caught.exception.record['gate'], 'safe_gap_endpoints')
        inputs = copy.deepcopy(self.inputs)
        inputs['data']['safeGovernanceGaps'] = inputs['data']['safeGovernanceGaps'][:2]
        with assert_stop(self, 'safe_gap_swap_required') as caught:
            m.check_governance([self.rpc('a'), self.rpc('b')], self.pin, inputs)
        self.assertEqual(caught.exception.record['gate'], 'safe_gap_swap_required')

    def test_collection_rejects_endpoint_count_before_delegating(self):
        # The nested verifier repeats this guard. Isolate the collection boundary
        # so removing its own check cannot hide behind the same downstream gate.
        with patch.object(m, 'check_governance', side_effect=AssertionError('delegated invalid endpoints')):
            with assert_stop(self, 'safe_gap_endpoints') as caught:
                m.governance_evidence(self.pin, self.inputs, [self.rpc('a')])
        self.assertEqual(caught.exception.record['gate'], 'safe_gap_endpoints')

    def test_evidence_controls(self):
        self.verify()
        with assert_stop(self, 'safe_gap_evidence_undeclared') as caught: m.governance_evidence(self.pin, dict(data={}))
        self.assertEqual(caught.exception.record['gate'], 'safe_gap_evidence_undeclared')
        self.pin['safeGovernanceGaps']['partOfA3aPlan'] = True
        with assert_stop(self, 'safe_gap_not_a3a') as caught: m.governance_evidence(self.pin, self.inputs)
        self.assertEqual(caught.exception.record['gate'], 'safe_gap_not_a3a')
        self.verify()
        self.pin['safeGovernanceGaps']['reads']['b'].pop(0)
        with assert_stop(self, 'safe_gap_proof_read') as caught: m.governance_evidence(self.pin, self.inputs)
        self.assertEqual(caught.exception.record['gate'], 'safe_gap_proof_read')


class NamedStopAssertionTests(unittest.TestCase):
    def test_expected_gate(self):
        with assert_stop(self, 'expected'):
            a.need('expected', False, True)

    def test_wrong_gate_names_both(self):
        with self.assertRaisesRegex(AssertionError, 'expected') as caught:
            with assert_stop(self, 'expected'):
                a.need('other', False, True)
        self.assertIn('other', str(caught.exception))

    def test_acceptance_names_gate(self):
        with self.assertRaisesRegex(AssertionError, 'expected: Gate not raised'):
            with assert_stop(self, 'expected'):
                pass

    def test_unexpected_exception_propagates(self):
        fault = ValueError('unrelated failure')
        with self.assertRaises(ValueError) as caught:
            with assert_stop(self, 'expected'):
                raise fault
        self.assertIs(caught.exception, fault)


class GasGateControls(unittest.TestCase):
    def setUp(self):
        self.step = dict(id='approve', executionTimestamp=100,
            tx={'from': a.APPROVER, 'to': a.SAFE, 'data': '0x', 'value': '0x0',
                'nonce': '0x63', 'chainId': hex(a.CHAIN),
                'maxFeePerGas': '0x10', 'maxPriorityFeePerGas': '0x1'})
        self.plan = dict(pin={'block': '0x123'}, steps=[{'id': 'prior'}, self.step])
        freeze_gas(self.plan, self.step)
        self.step['estimateGas'] = 135104
        self.step['localEstimateGas'] = 53160
        self.step['forkGasUsed'] = 68394
        self.step['tx']['gas'] = hex(u.margin_limit(135104))

    def stop(self, gate, action=None):
        with assert_stop(self, gate) as caught:
            (action or (lambda: u.validate_gas_evidence(self.plan, self.step)))()
        self.assertEqual(caught.exception.record['gate'], gate)
        self.assertEqual(caught.exception.record['step'], self.step['id'])

    def test_positive(self):
        u.validate_gas_evidence(self.plan, self.step)

    def test_gas_evidence_missing(self):
        self.step['gasEvidence'] = UserDict(self.step['gasEvidence'])
        self.stop('gas_evidence_missing')

    def test_remote_estimate_context(self):
        self.step['gasEvidence']['estimateContext'] = UserDict(self.step['gasEvidence']['estimateContext'])
        self.stop('remote_estimate_context')

    def test_measurement_executionTimestamp_context(self):
        self.step['executionTimestamp'] = 0
        self.step['gasEvidence']['estimateContext']['blockOverrides'] = {'time': '0x0'}
        # Isolate the context check from the separately tested transaction validator.
        with patch.object(u, 'validate_gas'):
            self.stop('measurement_executionTimestamp')

    def test_measurement_executionTimestamp_transaction(self):
        self.step['executionTimestamp'] = 0
        self.stop('measurement_executionTimestamp', lambda: self.validate_transaction_gas())

    def validate_transaction_gas(self):
        with u.gas_step(self.step):
            u.validate_gas(self.step)

    def test_measurement_blockGasLimit(self):
        self.step['gasEvidence']['blockGasLimit'] = 200_000_000.0
        self.stop('measurement_blockGasLimit')

    def test_fresh_estimate_pin(self):
        def rpc(method, params):
            if method == 'eth_estimateGas': return hex(120000)
            return dict(gasLimit=hex(200_000_000), hash='0x'+'ab'*32,
                        number='0x123', timestamp='0x64')
        self.stop('fresh_estimate_pin', lambda: u.fresh_gas(
            rpc, self.step, {}, 100, pin_block=None))

    def test_remote_fresh_estimate_unavailable(self):
        def rpc(method, params):
            self.assertEqual(method, 'eth_estimateGas')
            raise RuntimeError('remote estimate unavailable')
        self.stop('remote_fresh_estimate_unavailable', lambda: u.fresh_gas(rpc, self.step))

    def b4_measurement_control(self, gate, key):
        # Each invocation builds an independent plan before injecting one key.
        derived = dict(pin={'block': '0x123', 'senders': {}}, externalInputs={}, steps=[
            dict(id='B4', executionTimestamp=100, sender='approver',
                 tx={k: v for k, v in self.step['tx'].items() if k != 'gas'})])
        derived['steps'][0]['variants'] = {
            name: copy.deepcopy(derived['steps'][0]['tx']) for name in ('apply', 'placeholder')}
        self.plan = copy.deepcopy(derived)
        self.step = self.plan['steps'][0]
        freeze_gas(self.plan, self.step)
        m.budget(self.plan)
        with patch.object(m, 'build_plan', return_value=derived):
            m.validate_plan(self.plan, {}, frozen=True)
            target = self.step['variantMeasurements']
            if gate == 'B4_placeholder_measurements':
                target = target['placeholder']
            target[key] = copy.deepcopy(self.step['tx']) if key == 'tx' else 'unexpected'
            self.stop(gate, lambda: m.validate_plan(self.plan, {}, frozen=True))

    def test_B4_variant_measurements(self):
        self.b4_measurement_control('B4_variant_measurements', 'unexpected')

    def test_B4_placeholder_measurements_tx(self):
        self.b4_measurement_control('B4_placeholder_measurements', 'tx')

    def test_B4_placeholder_measurements_unexpected(self):
        self.b4_measurement_control('B4_placeholder_measurements', 'unexpected')

    def test_remote_margin(self):
        self.step['tx']['gas'] = hex(u.margin_limit(68394))
        self.stop('measured_gas_limit')

    def test_missing_remote(self):
        del self.step['estimateGas']
        self.stop('remote_estimate_missing')

    def test_wrong_pin(self):
        self.step['gasEvidence']['estimateContext']['block'] = '0x124'
        self.stop('remote_estimate_pin')

    def test_missing_override(self):
        self.step['gasEvidence']['estimateContext']['stateOverrides'] = {}
        self.stop('remote_estimate_overrides')

    def test_wrong_time_override(self):
        self.step['gasEvidence']['estimateContext']['blockOverrides'] = {'time': hex(self.step['executionTimestamp']+1)}
        self.stop('remote_estimate_time')

    def test_wrong_prior_steps(self):
        # One prior step missing from the recorded prefix.
        self.step['gasEvidence']['priorSteps'] = []
        self.stop('remote_estimate_prior_steps')

    def test_tampered_prior_steps(self):
        for prior in (['other'], ['prior', 'prior']):
            with self.subTest(prior=prior):
                self.setUp()
                self.step['gasEvidence']['priorSteps'] = prior
                self.stop('remote_estimate_prior_steps')

    def test_block_limit(self):
        self.step['gasEvidence']['blockGasLimit'] = a.qty(self.step['tx']['gas'])-1
        self.stop('block_gas_limit')

    def test_fresh_estimate(self):
        def rpc(method, params):
            if method == 'eth_estimateGas':
                self.assertEqual(params[1:], ['latest'])
                return hex(a.qty(self.step['tx']['gas'])+1)
            return dict(gasLimit=hex(200_000_000), hash='0x'+'ab'*32, number='0x123', timestamp='0x64')
        self.stop('fresh_estimate', lambda: u.fresh_gas(rpc, self.step))

    def test_fresh_modes(self):
        for overrides in (None, {}, {a.SAFE: {'balance': '0x1'}}):
            calls = []
            def rpc(method, params):
                calls.append((method, copy.deepcopy(params)))
                if method == 'eth_estimateGas': return hex(120000)
                return dict(gasLimit=hex(200_000_000), hash='0x'+'ab'*32, number='0x123', timestamp='0x63')
            result = u.fresh_gas(rpc, self.step, overrides, 100, pin_block='0x123')
            block = 'latest' if overrides is None else '0x123'
            mode = 'live' if overrides is None else 'pinned-consistency'
            self.assertEqual(result, dict(mode=mode, block=block))
            self.assertEqual(calls[0][1][1:], [block] if overrides is None else
                             [block, overrides, {'time': '0x64'}])
            self.assertEqual(calls[1], ('eth_getBlockByNumber', [block, False]))

    def test_b4_replays_both_variants_before_selection(self):
        self.step['id'] = 'B4'
        self.plan['externalInputs'] = {}
        overrides = {a.SAFE: {'balance': '0x123'}}
        def rpc(method, params):
            if method == 'eth_estimateGas': return hex(120000)
            if method == 'eth_getBlockByNumber':
                return dict(timestamp=hex(99), gasLimit=hex(200_000_000), hash='0x'+'ab'*32, number='0x123')
            raise AssertionError(method)
        self.step.update(estimateGas=120000, localEstimateGas=120000, forkGasUsed=120000)
        self.step['tx']['gas'] = hex(u.margin_limit(120000))
        self.step['gasEvidence']['estimateContext']['stateOverrides'] = overrides
        self.step['variants'] = {name: copy.deepcopy(self.step['tx']) for name in ('apply', 'placeholder')}
        self.step['variantMeasurements'] = {'placeholder': {
            k: copy.deepcopy(self.step[k]) for k in u.MEASURED_KEYS | {'gasEvidence'}}}
        original = copy.deepcopy(self.step)
        for variant in ('apply', 'placeholder'):
            for mutation, gate in (('estimate', 'replay_estimateGas'), ('override', 'replay_gasEvidence')):
                self.step = copy.deepcopy(original)
                self.plan['steps'][-1] = self.step
                target = self.step if variant == 'apply' else self.step['variantMeasurements']['placeholder']
                if mutation == 'estimate':
                    target['estimateGas'] = 100000
                    target['localEstimateGas'] = target['forkGasUsed'] = 100000
                    self.step['variants'][variant]['gas'] = hex(130000)
                    if variant == 'apply': self.step['tx']['gas'] = hex(130000)
                else:
                    target['gasEvidence']['estimateContext']['stateOverrides'] = {a.ZERO: {}}
                with self.subTest(variant=variant, mutation=mutation), patch.object(m, 'select_b4') as select:
                    self.stop(gate, lambda: m.execute_b4(
                        rpc, rpc, self.plan, self.step, {}, overrides, False))
                    select.assert_not_called()

    def test_b4_preapplied_real_measurement(self):
        self.plan['pin'] = dict(pin(), **self.plan['pin'])
        # Stop at the pre-send chain check: all replay and selection helpers are real.
        class ReachedPreSend(Exception):
            pass
        self.step.update(id='B4', estimateGas=120000, localEstimateGas=120000,
                         forkGasUsed=120000)
        self.plan['externalInputs'] = {}
        verifier = '0x'+'12'*20
        self.plan['addresses'] = dict(BLSAggregator=a.SAFE, OverIssueFraudProofVerifier=verifier)
        overrides = self.step['gasEvidence']['estimateContext']['stateOverrides']
        self.step['tx'].update(data=a.calldata('applyFraudProofVerifier()'),
                               gas=hex(u.margin_limit(120000)))
        self.step['variants'] = dict(apply=copy.deepcopy(self.step['tx']),
                                    placeholder=dict(self.step['tx'], data='0x'))
        self.step['variantMeasurements'] = {'placeholder': {
            k: copy.deepcopy(self.step[k]) for k in u.MEASURED_KEYS | {'gasEvidence'}}}
        original = copy.deepcopy(self.step)
        for tamper in (None, 'estimate', 'evidence'):
            self.step = copy.deepcopy(original)
            self.plan['steps'][-1] = self.step
            if tamper == 'estimate': self.step['estimateGas'] += 1
            if tamper == 'evidence': self.step['gasEvidence']['estimateContext']['stateOverrides'] = {a.ZERO: {}}
            remote_payloads, local_payloads = [], []
            def remote(method, params):
                if method == 'eth_estimateGas':
                    self.assertEqual(params[1:], ['0x123', overrides, {'time': hex(100)}])
                    remote_payloads.append(params[0]['data'])
                    return hex(120000)
                if method == 'eth_getBlockByNumber':
                    return dict(timestamp=hex(99), gasLimit=hex(200_000_000),
                                hash='0x'+'ab'*32, number='0x123')
                raise AssertionError(method)
            def fork(method, params):
                if method == 'eth_getBlockByNumber': return remote(method, params)
                if method == 'eth_call':
                    if params[0]['data'].startswith(a.keccak('hasRole(bytes32,address)')[:10]): return a.ZERO32
                    return '0x'+format(int(verifier, 16), '064x')
                if method == 'eth_estimateGas':
                    if params[0]['data'] != '0x': raise RuntimeError('NoPendingVerifierRotation')
                    self.assertEqual(params[1:], ['latest'])
                    local_payloads.append(params[0]['data'])
                    return hex(120000)
                if method == 'eth_chainId': raise ReachedPreSend()
                raise AssertionError(method)
            fork.local = True
            fork = with_orphan_reads(fork, self.plan['pin'], '0x123')
            self.plan['pin']['oldTimelock'] = dict(approvalOwners={t: [] for t in self.plan['pin']['oldOwnerIsolation']['tokens']})
            with self.subTest(tamper=tamper):
                if tamper:
                    self.stop('replay_estimateGas' if tamper == 'estimate' else 'replay_gasEvidence',
                        lambda: m.execute_b4(remote, fork, self.plan, self.step, {}, overrides, False))
                    self.assertEqual(local_payloads, [])
                else:
                    with self.assertRaises(ReachedPreSend):
                        m.execute_b4(remote, fork, self.plan, self.step, {}, overrides, False)
                    self.assertEqual(local_payloads, ['0x'])
                    self.assertEqual(remote_payloads, [self.step['tx']['data'], '0x', '0x'])

    def test_shared_measurement_records_remote_context_and_replays(self):
        self.plan['externalInputs'] = {}
        self.step['tx']['nonce'] = hex(13000)
        fork = base.GasFork(minimum=68394, used=68394, estimate=53160)
        calls = []
        def remote(method, params):
            calls.append((method, copy.deepcopy(params)))
            if method == 'eth_estimateGas': return hex(135104)
            if method == 'eth_getBlockByNumber': return dict(gasLimit=hex(200_000_000),
                hash='0x'+'ab'*32, number='0x123', timestamp='0x64')
            raise AssertionError(method)
        overrides = {a.SAFE: {'stateDiff': {a.ZERO32: a.ZERO32}}}
        u.measure_step(remote, fork, self.plan, self.step, overrides, 2000, True)
        u.validate_gas_evidence(self.plan, self.step)
        self.assertEqual(calls[0][1][1:], ['0x123', overrides, {'time': hex(2000)}])
        self.assertEqual(self.step['estimateGas'], 135104)
        self.assertEqual(self.step['localEstimateGas'], 53160)
        self.assertEqual(self.step['forkGasUsed'], 68394)
        self.assertEqual(a.qty(self.step['tx']['gas']), u.margin_limit(135104))
        frozen = copy.deepcopy(self.step)
        u.measure_step(remote, fork, self.plan, self.step, overrides, 2000, False)
        self.assertEqual(self.step, frozen)
        changed = {a.SAFE: {'stateDiff': {a.ZERO32: '0x'+'01'*32}}}
        self.stop('replay_gasEvidence', lambda: u.measure_step(
            remote, fork, self.plan, self.step, changed, 2000, False))
        u.fresh_gas(remote, self.step, overrides, 2000, pin_block=self.plan['pin']['block'])
        estimates = [params for method, params in calls if method == 'eth_estimateGas']
        self.assertEqual(estimates[-1][1:], ['0x123', overrides, {'time': hex(2000)}])

    def test_unavailable_remote(self):
        def rpc(method, params):
            raise RuntimeError('overrides unsupported')
        self.stop('remote_estimate_unavailable', lambda: u.measure_step(
            rpc, rpc, self.plan, self.step, {}, 100, True))


class GasProbeReportingTests(unittest.TestCase):
    def test_all_single_site_deletions_are_strict(self):
        import probe_gas_gates as probes
        for name, gate in probes.CASES.items():
            with self.subTest(gate=gate):
                red, log = probes.strict_outcome(name, gate)
                self.assertTrue(red, gate+'\n'+log)

    def test_suppressed_gate_cannot_be_reported_as_another_defense(self):
        import probe_gas_gates as probes
        with patch.object(u, 'validate_gas_evidence',
                          side_effect=a.Gate('remote_estimate_missing', False, True)):
            with self.assertRaises(AssertionError):
                probes.strict_outcome('test_missing_remote', 'remote_estimate_missing')



class OldExitExemptionTests(unittest.TestCase):
    guardian = '0xf36c9317765634e4995ce1e7210b5738225425b0'

    def fixture(self, **kw):
        p = base.pin()
        p.update(oldAggregator=OLD, stateTimestamp=1789019461)
        return p, old_exit_rpc(p, kw.pop('guardian', self.guardian), **kw)

    def control(self, gate, **kw):
        pop = kw.pop('pop', [])
        p, rpc = self.fixture(**kw)
        with assert_stop(self, gate) as caught:
            m.old_activity(rpc, OLD, p['stateBlock'], pop)
        self.assertEqual(caught.exception.record['gate'], gate)

    def test_not_expired(self):
        self.control('old_exit_exempt_expired', expires=1789019461)

    def test_slot(self):
        self.control('old_exit_exempt_slot', occupied=13)

    def test_slash(self):
        self.control('old_exit_exempt_slash', slash=1)

    def test_listed(self):
        self.control('old_exit_exempt_listed', guardian='0x'+'99'*20)

    def test_pop(self):
        self.control('old_exit_exempt_pop', pop=[dict(validator=self.guardian.upper())])

    def test_stage_b4_pop_containing_exempt_guardian_stops(self):
        # Once the PoP exists (b4/full), condition (4) is checked against it directly.
        self.control('old_exit_exempt_pop', pop=[dict(validator=self.guardian)])

    def test_stage_a7_pop_derived_from_slot_inventory(self):
        # Stage a7 has no PoP input yet: condition (4) follows from (2), because the PoP
        # validator set must equal the old aggregator's nonempty slot inventory.
        p, rpc = self.fixture()
        result = m.old_activity(rpc, OLD, p['stateBlock'], None)
        self.assertEqual([(x['inPop'], x['popSource']) for x in result['exemptions']], [(False, 'slot-inventory')])
        # A slot holder still STOPs, at the load-bearing slot gate.
        self.control('old_exit_exempt_slot', occupied=13, pop=None)

    def test_maximum(self):
        self.control('old_exit_max_validators', maximum=14)

    def test_gate_removal_probes(self):
        for suffix, test in [('expired','not_expired'), ('slot','slot'), ('slash','slash'),
                             ('listed','listed'), ('pop','pop'), ('max_validators','maximum')]:
            gate = 'old_exit_'+suffix if suffix == 'max_validators' else 'old_exit_exempt_'+suffix
            with self.subTest(gate=gate):
                tree = ast.parse(Path(m.__file__).read_text())
                function = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == 'old_activity')
                class RemoveGate(ast.NodeTransformer):
                    count = 0
                    def visit_Expr(self, node):
                        call = node.value
                        if (isinstance(call, ast.Call) and isinstance(call.func, ast.Attribute)
                                and call.func.attr == 'need' and call.args
                                and isinstance(call.args[0], ast.Constant) and call.args[0].value == gate):
                            self.count += 1
                            return ast.copy_location(ast.Pass(), node)
                        return self.generic_visit(node)
                remover = RemoveGate()
                mutant = remover.visit(ast.Module(body=[function], type_ignores=[]))
                self.assertEqual(remover.count, 1)
                namespace = dict(vars(m))
                exec(compile(ast.fix_missing_locations(mutant), m.__file__, 'exec'), namespace)
                with patch.object(m, 'old_activity', namespace['old_activity']):
                    with self.assertRaises(AssertionError):
                        getattr(self, 'test_'+test)()
                getattr(self, 'test_'+test)()
                print('OLD_EXIT_PROBE '+gate+' removed=RED restored=PASS')

    def test_pin_replay_both_endpoints_and_tampering(self):
        p, rpc = self.fixture()
        activity, reads = m.record_old_activity(rpc, OLD, p['stateBlock'], [])
        p.update(oldActivity=activity, oldActivityReads=dict(primary=reads, secondary=copy.deepcopy(reads)))
        m.validate_old_activity(p, [])
        evidence = activity['exemptions'][0]
        self.assertEqual(len(evidence['slotScan']), 13)
        self.assertEqual(evidence['pinTime'], p['stateTimestamp'])
        for endpoint in ('primary', 'secondary'):
            bad = copy.deepcopy(p)
            bad['oldActivityReads'][endpoint].pop()
            with self.assertRaises(a.Gate): m.validate_old_activity(bad, [])
        bad = copy.deepcopy(p)
        bad['oldActivity']['exemptions'][0]['slashCount'] = 1
        with assert_stop(self, 'old_exit_evidence') as caught: m.validate_old_activity(bad, [])
        self.assertEqual(caught.exception.record['gate'], 'old_exit_evidence')
        with assert_stop(self, 'old_exit_exempt_pop') as caught:
            m.validate_old_activity(p, [dict(validator=self.guardian)])
        self.assertEqual(caught.exception.record['gate'], 'old_exit_exempt_pop')

    def test_pre_send_rereads_slots_and_time(self):
        p, rpc = self.fixture()
        p['oldActivity'] = m.old_activity(rpc, OLD, p['stateBlock'], [])
        plan = dict(pin=p, externalInputs=dict(data=dict(pop=[])))
        later = copy.deepcopy(p)
        later['stateTimestamp'] += 100
        m.unchanged_old_activity(old_exit_rpc(later, self.guardian), plan, later['stateBlock'])
        for slot in range(1, 14):
            with assert_stop(self, 'old_exit_exempt_slot') as caught:
                m.unchanged_old_activity(old_exit_rpc(later, self.guardian, occupied=slot), plan, later['stateBlock'])
            self.assertEqual(caught.exception.record['gate'], 'old_exit_exempt_slot')

    def test_unchanged_old_activity_detects_new_activity_after_pin(self):
        # Passes every internal gate (the proposal is executed) but changes the activity:
        # only the pin comparison old_activity_unchanged can catch it.
        p, rpc = self.fixture()
        p['oldActivity'] = m.old_activity(rpc, OLD, p['stateBlock'], [])
        plan = dict(pin=p, externalInputs=dict(data=dict(pop=[])))
        base_rpc = old_exit_rpc(p, self.guardian)
        aggregated = a.keccak('SignatureAggregated(uint256,bytes,uint256)')
        def later(method, params):
            if method == 'eth_getLogs':
                return base_rpc(method, params) + [dict(address=OLD, topics=[aggregated, '0x'+'0'*63+'7'],
                    data='0x', blockNumber='0x2', blockHash='0x'+'ef'*32, transactionHash='0x'+'12'*32,
                    transactionIndex='0x0', logIndex='0x0')]
            if method == 'eth_call' and params[0]['data'] == a.calldata('executedProposals(uint256)', 7):
                return '0x'+format(1, '064x')
            return base_rpc(method, params)
        with assert_stop(self, 'old_activity_unchanged') as caught:
            m.unchanged_old_activity(later, plan, p['stateBlock'])
        self.assertEqual(caught.exception.record['gate'], 'old_activity_unchanged')

    def test_pre_send_calls_unchanged_old_activity(self):
        # Wiring guard: the helper above is only effective if pre_send invokes it.
        tree = ast.parse(Path(m.__file__).read_text())
        pre_send = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == 'pre_send')
        calls = [c for c in ast.walk(pre_send) if isinstance(c, ast.Call)
                 and isinstance(c.func, ast.Name) and c.func.id == 'unchanged_old_activity']
        self.assertEqual(len(calls), 1)

    def test_pre_send_enforces_exit_gate(self):
        p, good = self.fixture()
        p['oldActivity'] = m.old_activity(good, OLD, p['stateBlock'], [])
        p = dict(pin(), **p)
        p.update(bindings={}, safe={})
        plan = dict(pin=p, steps=[], externalInputs=dict(data=dict(pop=[])))
        step = dict(tx={'from':u.DEPLOYER, 'nonce':'0x0'}, safeNonce=0)
        bad = old_exit_rpc(p, self.guardian, occupied=13)
        def rpc(method, params):
            if method == 'eth_chainId': return hex(a.CHAIN)
            if method == 'eth_call' and params[0]['data'].startswith(a.keccak('hasRole(bytes32,address)')[:10]): return a.ZERO32
            return bad(method, params)
        rpc.local = True
        rpc = with_orphan_reads(rpc, p, p['stateBlock'])
        p['oldTimelock'] = dict(approvalOwners={t: [] for t in p['oldOwnerIsolation']['tokens']})
        original_word = a.word
        def word(r, target, sig, *args, **kw):
            if target == u.SAFE and sig == 'nonce()': return 0
            return original_word(r, target, sig, *args, **kw)
        with patch.object(m, 'handover_gate'), patch.object(a, 'nonce', return_value=0), \
             patch.object(a, 'word', side_effect=word), patch.object(u, 'safe_state', return_value={}), \
             patch.object(u, 'governance'):
            p['timelockCreation'] = 1
            with assert_stop(self, 'old_exit_exempt_slot') as caught: m.pre_send(rpc, plan, step, {})
        self.assertEqual(caught.exception.record['gate'], 'old_exit_exempt_slot')

    def test_endpoint_replay_reruns_predicates(self):
        for kwargs, gate in [({'expires':1789019461}, 'old_exit_exempt_expired'),
                             ({'occupied':13}, 'old_exit_exempt_slot'),
                             ({'slash':1}, 'old_exit_exempt_slash'),
                             ({'maximum':12}, 'old_exit_max_validators'),
                             ({'guardian':'0x'+'99'*20}, 'old_exit_exempt_listed')]:
            p, good = self.fixture()
            activity, reads = m.record_old_activity(good, OLD, p['stateBlock'], [])
            _, bad = self.fixture(**kwargs)
            original = a.need
            def removed(name, actual, expected):
                if name != gate: return original(name, actual, expected)
            with patch.object(a, 'need', side_effect=removed):
                _, bad_reads = m.record_old_activity(bad, OLD, p['stateBlock'], [])
            for endpoint in ('primary','secondary'):
                with self.subTest(gate=gate, endpoint=endpoint):
                    p.update(oldActivity=activity, oldActivityReads=dict(primary=reads, secondary=reads))
                    p['oldActivityReads'][endpoint] = bad_reads
                    with assert_stop(self, gate) as caught: m.validate_old_activity(p, [])
                    self.assertEqual(caught.exception.record['gate'], gate)

    def test_cleared_notice_needs_no_exemption(self):
        p, rpc = self.fixture()
        original = a.call
        def cleared(rpc, old, sig, *args, **kw):
            if sig == 'guardianExitRequests(address)': return '0x'+'00'*64
            return original(rpc, old, sig, *args, **kw)
        with patch.object(a, 'call', side_effect=cleared):
            self.assertEqual(m.old_activity(rpc, OLD, p['stateBlock'])['exemptions'], [])


# F-05 and Q3: one broken precondition per named gate.
class F05Fixture(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixture = ManifestTests('test_determinism')
        cls.addClassCleanup(cls.fixture.doCleanups)
        cls.fixture.setUp()

    def setUp(self):
        self.pin, self.plan = copy.deepcopy((self.fixture.pin, self.fixture.plan))
        self.inputs = copy.deepcopy(self.fixture.inputs)
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = self.fixture.path
    step = ManifestTests.step

    def stop(self, gate, action):
        # gate=None is the positive control: the unbroken fixture must pass every gate.
        if gate is None:
            return action()
        with assert_stop(self, gate) as caught:
            action()
        self.assertEqual(caught.exception.record['gate'], gate)


class F05PreSendGates(F05Fixture):
    def test_positive_control(self): self.check(None)

    def check(self, gate):
        step = copy.deepcopy(self.step('B2a_exec'))
        freeze_gas(self.plan, step)
        nonce = a.qty(step['tx']['nonce'])
        self.pin['oldActivity']['dvtProposals'] = []
        self.plan['pin']['oldActivity']['dvtProposals'] = []
        def rpc(method, params):
            if method == 'eth_chainId': return hex(a.CHAIN)
            if method == 'eth_estimateGas':
                return hex(a.qty(step['tx']['gas']) + int(gate == 'fresh_estimate'))
            raise AssertionError((method, params))
        rpc.local = True
        rpc = with_orphan_reads(rpc, self.plan['pin'], '0x200')
        real_word, real_call = a.word, a.call
        def word(rpc, target, sig, *args, **kw):
            if sig == 'nonce()': return step['safeNonce'] + int(gate == 'safe_nonce')
            if sig == 'pendingAPNTsTokenEta()':
                return self.pin['pendingAPNTsTokenEta'] + int(gate == 'pending_token_eta')
            return real_word(rpc, target, sig, *args, **kw)
        def address(rpc, target, sig, *args):
            if sig == 'pendingAPNTsToken()':
                return a.ZERO if gate == 'pending_token' else self.pin['capped']
            return a.ZERO if target == u.SP and gate == 'SP_owner' else u.DEPLOYER
        with contextlib.ExitStack() as stack:
            for item in [
                patch.object(m, 'handover_gate'), patch.object(m, 'unchanged_old_activity'),
                patch.object(a, 'nonce', side_effect=lambda r,w,block='latest':
                    nonce + int(gate == ('pending_nonce' if block == 'pending' else 'sender_nonce'))),
                patch.object(a, 'word', side_effect=word), patch.object(a, 'address', side_effect=address),
                patch.object(a, 'call', side_effect=lambda r,t,s,*args,**kw: a.ZERO32 if s == 'hasRole(bytes32,address)' else (a.ZERO32 if gate == 'onchain_safe_hash' else step['safeHash']) if s.startswith('getTransactionHash(') else real_call(r,t,s,*args,**kw)),
                patch.object(a, 'block_data', return_value=dict(number='0x200',
                    gasLimit=hex(a.qty(step['tx']['gas']) - int(gate == 'block_gas_limit')))),
                patch.object(u, 'safe_state', return_value={} if gate == 'safe_state' else self.pin['safe']),
                patch.object(u, 'governance'), patch.object(u, 'assert_frozen'),
                patch.object(u, 'code', side_effect=lambda r,t,b:self.pin['bindings'][t]),
                patch.object(m, 'dvt_activity', return_value=['changed'] if gate == 'dvt_activity_unchanged'
                    else self.pin['oldActivity']['dvtProposals'])]:
                stack.enter_context(item)
            self.stop(gate, lambda:m.pre_send(rpc, self.plan, step, dict(frozen=True), measured=True))

    def test_sender_nonce(self): self.check('sender_nonce')

    def test_pending_nonce(self): self.check('pending_nonce')

    def test_safe_nonce(self): self.check('safe_nonce')

    def test_safe_state(self): self.check('safe_state')

    def test_dvt_activity_unchanged(self): self.check('dvt_activity_unchanged')

    def test_SP_owner(self): self.check('SP_owner')

    def test_pending_token(self): self.check('pending_token')

    def test_pending_token_eta(self): self.check('pending_token_eta')

    def test_onchain_safe_hash(self): self.check('onchain_safe_hash')

    def test_fresh_estimate(self): self.check('fresh_estimate')

    def test_block_gas_limit(self): self.check('block_gas_limit')


class F05RunManifestGates(F05Fixture):
    def test_positive_control(self): self.check(None)

    def check(self, gate):
        run = m.run_manifest
        def injected(remote, rpc, plan, out, calibrate=True):
            nonce, word, receipt, execute, balances = a.nonce, a.word, u.receipt, m.execute_b4, m.balances
            terminal = False
            def handover(rpc, plan):
                nonlocal terminal
                terminal = True
                return dict(control='missing' if gate == 'controls_complete' else 'owner_handover')
            def read_nonce(*args, **kw):
                return nonce(*args, **kw) + int(gate == 'post_nonce')
            def read_word(r, target, sig, *args, **kw):
                value = word(r, target, sig, *args, **kw)
                return value + int((sig == 'nonce()' and gate == 'post_safe_nonce') or
                                   (terminal and sig == 'balanceOf(address)' and gate == 'post_swap_capped_balance'))
            def mined(*args, **kw):
                result = receipt(*args, **kw)
                if gate == 'manifest_receipt_gas': result['gasUsed'] = hex(a.qty(result['gasUsed'])+1)
                return result
            def b4(*args, **kw):
                result = execute(*args, **kw)
                if gate == 'steps_complete': result['step'] = 'wrong'
                return result
            def accounting(*args, **kw):
                state = balances(*args, **kw)
                if terminal:
                    state['totalTrackedBalance'] += int(gate == 'post_swap_tracked')
                    state['protocolRevenue'] += int(gate == 'post_swap_revenue')
                return state
            with patch.object(a, 'nonce', side_effect=read_nonce), patch.object(a, 'word', side_effect=read_word), \
                 patch.object(u, 'receipt', side_effect=mined), patch.object(m, 'execute_b4', side_effect=b4), \
                 patch.object(m, 'balances', side_effect=accounting), \
                 patch.object(m, 'handover_controls', side_effect=handover), \
                 patch.object(m, 'solvency_probe', return_value=dict(allSolvent=gate != 'post_swap_solvency')):
                return run(remote, rpc, plan, out, calibrate)
        with patch.object(m, 'run_manifest', side_effect=injected):
            self.stop(gate, lambda:ManifestTests.rehearse_fake(self))

    def test_post_nonce(self): self.check('post_nonce')

    def test_post_safe_nonce(self): self.check('post_safe_nonce')

    def test_manifest_receipt_gas(self): self.check('manifest_receipt_gas')

    def test_steps_complete(self): self.check('steps_complete')

    def test_controls_complete(self): self.check('controls_complete')

    def test_post_swap_tracked(self): self.check('post_swap_tracked')

    def test_post_swap_revenue(self): self.check('post_swap_revenue')

    def test_post_swap_capped_balance(self): self.check('post_swap_capped_balance')

    def test_post_swap_solvency(self): self.check('post_swap_solvency')


class F05ExecuteB4Gates(F05Fixture):
    def test_positive_control(self): self.check(None)

    def check(self, gate):
        step = self.step('B4')
        freeze_gas(self.plan, step)
        tx = step['tx']
        def rpc(method, params):
            if method == 'eth_getTransactionByHash': return {}
            if method == 'evm_setNextBlockTimestamp': return True
            raise AssertionError((method, params))
        def block_data(rpc, block):
            # latest is 0x100, so B4 is measured for 0x101; the mined block (0xb4) reports when it was mined.
            mined = 0x101 + int(gate == 'B4_timestamp')
            return dict(timestamp=hex(mined) if block == '0xb4' else '0x100', gasLimit='0xbebc200')
        with patch.object(a, 'block_data', side_effect=block_data), \
             patch.object(u, 'measure_step'), patch.object(m, 'pre_send'), \
             patch.object(u, 'fresh_gas', return_value={}), patch.object(a, 'mined_identity'), \
             patch.object(m, 'b4_needed', return_value=True), patch.object(m, 'b4_post_state', return_value=[]), \
             patch.object(u, 'receipt', return_value=dict(transactionHash=base.HASH, gasUsed='0x1', status='0x1', blockNumber='0xb4')), \
             patch.object(a, 'nonce', return_value=a.qty(tx['nonce']) + int(gate != 'B4_nonce_consumed')), \
             patch.object(a, 'word', return_value=step['safeNonce'] + int(gate == 'B4_safe_nonce')):
            self.stop(gate, lambda:m.execute_b4(None, rpc, self.plan, step, {}, {}, True))

    def test_B4_timestamp(self): self.check('B4_timestamp')

    def test_B4_nonce_consumed(self): self.check('B4_nonce_consumed')

    def test_B4_safe_nonce(self): self.check('B4_safe_nonce')


class F05BuildPlanGates(F05Fixture):
    def test_stake_not_unlocking(self):
        self.pin['withdrawTime'] = 1
        self.stop('stake_not_unlocking', lambda:m.build_plan(self.pin, self.inputs))


class F05CollectGates(F05Fixture):
    def test_positive_control(self): self.check(None)

    def check(self, gate):
        legacy = old_timelock_rpc(self.pin, self.pin['stateBlock'])
        def rpc(method, params):
            if method in ('eth_call', 'eth_getLogs'): return legacy(method, params)
            if method in ('eth_getBalance', 'eth_getStorageAt'): return '0x1'
            raise AssertionError((method, params))
        def call(rpc, target, sig, *args, **kw):
            if sig == 'version()': return a.cast('abi-encode', 'c(string)', 'Registry-5.8.0')
            if sig == 'getDepositInfo(address)':
                return '0x'+''.join(format(x, '064x') for x in (10**18, 1, 10**18, 86400,
                    int(gate == 'stake_not_unlocking')))
            raise AssertionError(sig)
        def address(rpc, target, sig, *args):
            if sig == 'blsAggregator()': return OLD
            if sig in ('owner()', 'slashPolicyAdmin()'):
                return a.ZERO if sig == 'owner()' and gate == 'old_aggregator_owner' else u.DEPLOYER
            raise AssertionError(sig)
        with contextlib.ExitStack() as stack:
            for item in [patch.object(u, 'collect', return_value=copy.deepcopy(self.pin)),
                patch.object(a, 'nonce', return_value=self.pin['senders']['anni']['nonce']),
                patch.object(u, 'code', side_effect=lambda r,t,b:'0x6000' if t != ANNI or gate == 'anni_eoa' else '0x'),
                patch.object(a, 'call', side_effect=call), patch.object(a, 'address', side_effect=address),
                patch.object(a, 'word', side_effect=lambda r,t,s,*args,**kw:13 if s == 'MAX_VALIDATORS()' else 0),
                patch.object(m, 'reconcile_nonces'), patch.object(m, 'record_old_activity', return_value=({}, [])),
                patch.object(m, 'dvt_activity', return_value=[]), patch.object(m, 'old_pointers', return_value={}),
                patch.object(m, 'balances', return_value={}),
                patch.object(m, 'collect_phase_c', return_value=self.pin['phaseC']),
                patch.object(m.isolation, 'collect_deployed', return_value=self.pin['oldOwnerIsolation'])]:
                stack.enter_context(item)
            self.stop(gate, lambda:m.collect(rpc, self.pin['block'], self.inputs))

    def test_old_aggregator_owner(self): self.check('old_aggregator_owner')

    def test_anni_eoa(self): self.check('anni_eoa')

    def test_stake_not_unlocking(self): self.check('stake_not_unlocking')


class F05MainGates(F05Fixture):
    def test_independent_pin(self):
        changed = copy.deepcopy(self.pin)
        changed['blockHash'] = a.ZERO32
        with patch.object(m, 'collect', side_effect=[copy.deepcopy(self.pin), changed]):
            self.stop('independent_pin', lambda:m.collect_pair(None, None, self.pin['block'], self.inputs))

    def test_positive_control(self): self.check(None)

    def check(self, gate):
        out = Path(self.tmp.name)/'main'
        rpc_file = Path(self.tmp.name)/'fake-rpc.txt'
        rpc_file.write_text('offline-fixture')
        changed = copy.deepcopy(self.pin)
        changed['blockHash'] = a.ZERO32
        @contextlib.contextmanager
        def fork(*args):
            (out/'engine.stderr').write_text('')
            yield SimpleNamespace(local=True)
        def failure(out, record):
            raise a.Gate(record['gate'], record.get('observed'), record.get('expected'))
        pins = dict(simulation_pin=[changed, changed], pin_recheck=[self.pin, changed]).get(gate, [self.pin, self.pin])
        with patch.object(a, 'RPC', return_value=SimpleNamespace()), \
             patch.object(m, 'collect_pair', side_effect=pins), patch.object(m, 'build_plan', return_value=self.plan), \
             patch.object(a, 'fork', side_effect=fork), patch.object(m, 'run_manifest'), \
             patch.object(a, 'relay_evidence'), patch.object(m, 'save_artifact'), \
             patch.object(a, 'failure_record', side_effect=failure):
            self.stop(gate, lambda:m.main(['simulate', '--inputs', str(self.path), '--out', str(out),
                '--rpc-file', str(rpc_file), '--rpc-file-secondary', str(rpc_file), '--block', self.pin['block']]))

    def test_simulation_pin(self): self.check('simulation_pin')

    def test_pin_recheck(self): self.check('pin_recheck')



class F05Q3ForkControls(F05Fixture):
    def mint(self, gate):
        step = self.step('B2a_exec')
        child = dict(to=step['safeTarget'], **{'from':u.SAFE}, input=step['inner'])
        trace = dict(to=u.SAFE, **{'from':step['tx']['from']}, input=step['tx']['data'], calls=[child])
        if gate == 'mint_trace_top': trace['from'] = a.ZERO
        if gate == 'mint_trace_success': trace['error'] = 'reverted'
        if gate == 'mint_trace_count': trace['calls'].append(copy.deepcopy(child))
        if gate == 'mint_trace_call': child['input'] = '0x'
        def rpc(method, params):
            self.assertEqual(method, 'debug_traceTransaction')
            return trace
        self.stop(gate, lambda:m.mint_trace(rpc, step, dict(transactionHash=base.HASH)))

    def unbacked(self, gate):
        chain = FakeChain(self.plan)
        chain.backing = int(gate == 'unbacked_initial')
        chain.balances['totalTrackedBalance'] += int(gate == 'unbacked_shortfall')
        original = copy.deepcopy(chain.balances)
        def rpc(method, params):
            if method == 'evm_snapshot': return 'snapshot'
            if method == 'evm_revert':
                chain.balances = copy.deepcopy(original)
                return gate != 'unbacked_restore'
            if method == 'eth_call' and params[0]['data'] == a.calldata('gasParams()'):
                return '0x'+''.join(format(x, '064x') for x in (*u.GAS, *u.GAS, self.pin['timestamp']))
            if method == 'eth_call' and params[0]['data'] == a.calldata('getTimestamp(bytes32)', self.plan['operations']['activation']['id']):
                return '0x'+format(self.pin['pendingAPNTsTokenEta'], '064x')
            return chain(method, params)
        def receipt(rpc, tx, **kw):
            chain.backing = 0
            return dict(status='0x1')
        def fixture(rpc, sender, target, data):
            return {'from':sender, 'to':target, 'data':data}
        with contextlib.ExitStack() as stack:
            for item in [patch.object(u, 'wait_until'), patch.object(u, 'fixture_tx', side_effect=fixture),
                         patch.object(u, 'receipt', side_effect=receipt)]:
                stack.enter_context(item)
            if gate == 'unbacked_refusal_gate':
                stack.enter_context(patch.object(m, 'b2_gate', side_effect=a.Gate('B2_wrong', False, True)))
            if gate == 'unbacked_plan_refusal_gate':
                stack.enter_context(patch.object(m, 'validate_plan', side_effect=a.Gate('manifest_wrong', False, True)))
            self.stop(gate, lambda:m.unbacked_swap_control(rpc, self.plan))

    def b4(self, gate):
        step = self.step('B4')
        verifier = self.plan['addresses']['OverIssueFraudProofVerifier']
        state = dict(verifier=a.ZERO, pending=verifier, nonce=a.qty(step['tx']['nonce']), sent=0)
        snapshots = []
        def rpc(method, params):
            if method == 'evm_snapshot':
                snapshots.append(copy.deepcopy(state))
                return len(snapshots)-1
            if method == 'evm_revert':
                state.clear(); state.update(snapshots[params[0]])
                return gate != 'B4_control_restore'
            if method == 'eth_call':
                calls = {'fraudProofVerifier()':int(state['verifier'], 16),
                    'pendingFraudProofVerifier()':int(state['pending'], 16),
                    'pendingFraudProofVerifierReadyAt()':0}
                for sig, value in calls.items():
                    if params[0]['data'] == a.calldata(sig): return '0x'+format(value, '064x')
            raise AssertionError((method, params))
        def fixture(rpc, sender, target, data):
            return {'from':sender, 'to':target, 'data':data, 'nonce':hex(state['nonce'])}
        def receipt(rpc, tx, status='0x1'):
            data = tx['data']
            if data == a.calldata('proposeFraudProofVerifier(address)', self.pin['oldAggregator']):
                state['pending'] = self.pin['oldAggregator']
                state['nonce'] += 1
                return dict(status='0x1')
            if tx['from'] == a.EXECUTOR:
                state['verifier'], state['pending'] = state['pending'], a.ZERO
                return dict(status='0x1')
            state['sent'] += 1
            if not ((gate == 'B4_next_nonce' and state['sent'] == 1) or
                    (gate == 'B4_later_nonce' and state['sent'] == 2)):
                state['nonce'] += 1
            actual = '0x1' if data == '0x' else '0x0'
            if gate == 'B4_control_status' and len(snapshots) == 2: actual = '0x1'
            if gate == 'B4_wrong_status' and len(snapshots) == 3: actual = '0x1'
            return dict(status=actual)
        select, post = m.select_b4, m.b4_post_state
        selections = []
        def selected(*args):
            name, tx = select(*args)
            selections.append(name)
            if gate == 'B4_control_initial' and len(selections) == 1: name = 'placeholder'
            if gate == 'B4_control_placeholder' and len(selections) == 2: name = 'apply'
            return name, tx
        def post_state(*args):
            if len(snapshots) == 3:
                if gate == 'B4_wrong_gate': raise a.Gate('readback_wrong', False, True)
                if gate == 'B4_wrong_must_stop': return []
            return post(*args)
        with patch.object(a, 'nonce', side_effect=lambda *args:state['nonce']), \
             patch.object(u, 'fixture_tx', side_effect=fixture), patch.object(u, 'receipt', side_effect=receipt), \
             patch.object(u, 'wait_until'), patch.object(m, 'select_b4', side_effect=selected), \
             patch.object(m, 'b4_post_state', side_effect=post_state):
            self.stop(gate, lambda:m.b4_controls(rpc, self.plan, step))

    def test_positive_controls(self):
        for helper in (self.mint, self.unbacked, self.b4):
            with self.subTest(helper=helper.__name__):
                helper(None)

    def test_mint_trace_top(self): self.mint('mint_trace_top')

    def test_mint_trace_success(self): self.mint('mint_trace_success')

    def test_mint_trace_count(self): self.mint('mint_trace_count')

    def test_mint_trace_call(self): self.mint('mint_trace_call')

    def test_unbacked_initial(self): self.unbacked('unbacked_initial')

    def test_unbacked_shortfall(self): self.unbacked('unbacked_shortfall')

    def test_unbacked_refusal_gate(self): self.unbacked('unbacked_refusal_gate')

    def test_unbacked_plan_refusal_gate(self): self.unbacked('unbacked_plan_refusal_gate')

    def test_unbacked_restore(self): self.unbacked('unbacked_restore')

    def test_B4_control_initial(self): self.b4('B4_control_initial')

    def test_B4_control_placeholder(self): self.b4('B4_control_placeholder')

    def test_B4_wrong_gate(self): self.b4('B4_wrong_gate')

    def test_B4_wrong_status(self): self.b4('B4_wrong_status')

    def test_B4_wrong_must_stop(self): self.b4('B4_wrong_must_stop')

    def test_B4_control_status(self): self.b4('B4_control_status')

    def test_B4_next_nonce(self): self.b4('B4_next_nonce')

    def test_B4_later_nonce(self): self.b4('B4_later_nonce')

    def test_B4_control_restore(self): self.b4('B4_control_restore')



class DiscoveryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixture = ManifestTests()
        cls.fixture.setUp()
        cls.addClassCleanup(cls.fixture.doCleanups)

    def setUp(self):
        self.plan = copy.deepcopy(self.fixture.plan)
        self.pin = self.plan['pin']
        self.passed = {s['id'] for s in self.plan['steps']}
        self.block = '0x200'

    def gate(self, name, action):
        with assert_stop(self, name):
            action()

    def rpc(self, plan=None, passed=None, extra=None, bad=None):
        plan = plan or self.plan
        passed = self.passed if passed is None else passed
        coverage = m.discovery_coverage(plan, passed)
        state = m.expected_discovery(plan, passed)
        section = coverage['oldOwnerIsolation']
        factory = state['targets']['xPNTsFactory']
        replies = orphan_replies(plan['pin'])
        replies[(plan['addresses']['xPNTsFactoryV2'],a.calldata('getAllTokens()'))] = isolation_tests.raw([32,0])
        replies[(u.SP, a.calldata('xpntsFactory()'))] = isolation_tests.raw([int(factory, 16)])
        tokens = state['xpnts'] if factory == plan['pin']['oldOwnerIsolation']['targets']['xPNTsFactory'] else sorted(set(state['xpnts']) - set(plan['pin']['oldOwnerIsolation']['xpnts']))
        if extra: tokens = tokens + [extra]
        replies[(factory, a.calldata('getAllTokens()'))] = isolation_tests.raw([32, len(tokens), *[int(t,16) for t in tokens]])
        for target, sig, args, kind in m.isolation.authority_rows(section):
            if kind == 'config': continue
            for holder in (m.isolation.OLD, m.isolation.OLD_TIMELOCK):
                arguments = [holder if v == m.isolation.OLD_TIMELOCK else v for v in args]
                replies.setdefault((target, a.calldata(sig, *arguments)), isolation_tests.raw([int(u.DEPLOYER,16) if kind == 'address' else 0]))
        for token in section['xpnts']:
            replies[(token, a.calldata('communityOwner()'))] = isolation_tests.raw([int(u.DEPLOYER,16)])
        for token in section['tokens']:
            for holder in m.isolation.allowance_holders():
                for spender in (m.isolation.OLD, m.isolation.OLD_TIMELOCK):
                    replies[(token,a.calldata('allowance(address,address)',holder,spender))] = isolation_tests.raw([0])
        if bad:
            target, sig, args, value = bad
            replies[(target,a.calldata(sig,*args))] = isolation_tests.raw([value])
        baseline = old_timelock_rpc(plan['pin'], self.block)
        def rpc(method, params):
            if method == 'eth_getLogs':
                if params[0]['address'] == u.REG and a.qty(params[0]['fromBlock']) <= a.qty(plan['pin']['stateBlock']):
                    return baseline(method,params)
                return []
            if method == 'eth_getCode': return '0x6000'
            if method == 'eth_chainId': return '0x0'
            if method == 'eth_getBlockByNumber': return dict(number=self.block,hash=plan['pin']['stateBlockHash'],timestamp='0x123',gasLimit='0xbebc200')
            if method == 'eth_call':
                self.assertEqual(params[1], self.block)
                key = (params[0]['to'],params[0]['data'])
                if key in replies: return replies[key]
            return baseline(method,params)
        rpc.local = True
        return rpc

    def closing(self, rpc, plan=None):
        plan = plan or self.plan
        plan['pin']['oldActivity']['dvtProposals'] = [{'recorded': True}]
        pointer = plan['pin']['oldAggregator'] if plan['stage'] == 'a7' else plan['addresses']['BLSAggregator']
        with contextlib.ExitStack() as stack:
            # Keep the real coverage helper; only unrelated DVT reads are stubbed.
            for item in self.fixture.closing_rpc(pointer)[:-1]: stack.enter_context(item)
            with patch.object(m.isolation, 'role_history', side_effect=lambda rpc,pin,target,spec,creation: list(pin['oldOwnerIsolation']['roleHistory'].get(target,[]))):
                return m.dvt_closing(rpc,plan)

    def pre(self, rpc, passed=None):
        with patch.object(m, 'handover_gate'):
            return m.pre_send(rpc,self.plan,dict(tx={}),dict(passed=self.passed if passed is None else passed))

    def test_stages(self):
        class Checked(Exception): pass
        a7, b4, _ = self.fixture.staged_chain()
        for plan in (a7,b4,m.build_plan(self.pin,self.fixture.inputs,'c'),self.plan):
            passed = set()
            for step in plan['steps']:
                rpc = self.rpc(plan,passed)
                with patch.object(m,'handover_gate',side_effect=Checked), self.assertRaises(Checked):
                    m.pre_send(rpc,plan,step,dict(passed=passed))
                passed.add(step['id'])
                expected = plan['expectedDiscoveryAfter'][step['id']]
                self.assertEqual(m.current_discovery(self.rpc(plan,passed),m.discovery_coverage(plan,passed),self.block),expected)
            self.closing(self.rpc(plan,passed),plan)

    def test_expected_states(self):
        state = m.pin_discovery(self.pin)
        factory = self.plan['addresses']['xPNTsFactoryV2']
        token = a.create_address(factory,1)
        for step in self.plan['steps']:
            sid = step['id']
            if sid == 'A4.factory': state['targets']['releaseFactory'] = factory
            if sid == 'upgrade_execute_exec':
                state['targets']['legacyFactory'] = state['targets']['xPNTsFactory']
                state['targets']['xPNTsFactory'] = factory
            if sid in ('C3.deploy','C3.configure'): state['xpnts'] = sorted(set(state['xpnts']) | {token})
            self.assertEqual(self.plan['expectedDiscoveryAfter'][sid],state,sid)

    def closing_inventory(self, gained_role=False):
        coverage = m.discovery_coverage(self.plan, self.passed)
        pinned = self.pin['oldOwnerIsolation']['roleHistory']
        target = self.pin['oldOwnerIsolation']['targets']['xPNTsFactory']
        self.assertIn(target, pinned)
        self.assertNotEqual(coverage['discoveryExpected'], m.pin_discovery(self.pin))
        def history(rpc, pin, address, spec, creation):
            roles = list(pinned.get(address, []))
            if gained_role and address == target:
                roles.append('0x'+'ab'*32)
            return roles
        with patch.object(m.isolation, 'role_history', side_effect=history):
            return m.closing_timelock_inventory(self.rpc(), coverage, self.block)

    def test_closing_planned_discovery_pinned_history_unchanged(self):
        result = self.closing_inventory()
        for target, roles in self.pin['oldOwnerIsolation']['roleHistory'].items():
            self.assertEqual(result['oldOwnerIsolation']['roleHistory'][target], roles)
        self.assertIn(self.plan['addresses']['xPNTsFactoryV2'], result['oldOwnerIsolation']['roleHistory'])

    def test_old_timelock_inventory_pinned_history(self):
        self.gate('old_timelock_inventory_pinned_history', lambda: self.closing_inventory(gained_role=True))

    def test_creation_before_upgrade_execution(self):
        index = next(i for i, s in enumerate(self.plan['steps']) if s['id'] == 'upgrade_execute_exec')
        self.plan['steps'].insert(index, dict(id='test.creation', tx=dict(to=None, data='0x6000')))
        expected = m.build_expected_discovery(self.plan)
        self.assertEqual(expected['upgrade_execute_exec'], self.plan['expectedDiscoveryAfter']['upgrade_execute_exec'])
        self.plan['steps'][index+1]['tx']['to'] = None
        self.gate('discovery_factory_argument', lambda: m.build_expected_discovery(self.plan))

    def test_discovery_step_table(self):
        self.plan['steps'] = [s for s in self.plan['steps'] if s['id'] != 'A6.upgrade']
        self.gate('discovery_step_table',lambda:m.build_expected_discovery(self.plan))

    def test_discovery_unlisted_effect(self):
        step = copy.deepcopy(next(s for s in self.plan['steps'] if s['id'] == 'C3.configure'))
        step['id'] = 'unplanned'
        self.plan['steps'].append(step)
        self.gate('discovery_unlisted_effect',lambda:m.build_expected_discovery(self.plan))

    def test_discovery_factory_prediction(self):
        next(s for s in self.plan['steps'] if s['id'] == 'A4.factory')['creates'] = u.SP
        self.gate('discovery_factory_prediction',lambda:m.build_expected_discovery(self.plan))

    def test_discovery_factory_argument(self):
        step = next(s for s in self.plan['steps'] if s['id'] == 'upgrade_execute_exec')
        step['tx']['data'] = a.calldata('setXPNTsFactory(address)',u.SP)
        self.gate('discovery_factory_argument',lambda:m.build_expected_discovery(self.plan))

    def test_discovery_token_prediction(self):
        next(s for s in self.plan['steps'] if s['id'] == 'C3.deploy')['tx']['to'] = u.SP
        self.gate('discovery_token_prediction',lambda:m.build_expected_discovery(self.plan))

    def test_discovery_operator_argument(self):
        next(s for s in self.plan['steps'] if s['id'] == 'C3.configure')['tx']['data'] = a.calldata('configureOperator(address,address)',u.SP,m.PC_TREASURY)
        self.gate('discovery_operator_argument',lambda:m.build_expected_discovery(self.plan))

    def test_discovery_old_authority(self):
        factory = self.pin['oldOwnerIsolation']['targets']['xPNTsFactory']
        self.gate('discovery_old_authority',lambda:self.pre(self.rpc(bad=(factory,'owner()',[],int(m.isolation.OLD,16)))))

    def test_extra_token_pre(self):
        self.gate('old_owner_release_factory_enumeration',lambda:self.pre(self.rpc(extra=u.SP)))

    def test_wrong_factory_pre(self):
        self.gate('old_timelock_delta_targets',lambda:self.pre(self.rpc(bad=(u.SP,'xpntsFactory()',[],int(self.pin['oldOwnerIsolation']['targets']['xPNTsFactory'],16)))))

    def test_extra_token_closing(self):
        # Exercise inventory drift independently of the factory enumeration gates.
        coverage = m.discovery_coverage(self.plan, self.passed)
        observed = copy.deepcopy(coverage['discoveryExpected'])
        observed['xpnts'].append(u.SP)
        with patch.object(m, 'current_discovery', return_value=observed), patch.object(
                m.isolation, 'role_history', side_effect=lambda rpc,pin,target,spec,creation: list(pin['oldOwnerIsolation']['roleHistory'].get(target,[]))):
            self.gate('old_timelock_inventory', lambda: m.closing_timelock_inventory(self.rpc(), coverage, self.block))

    def test_extra_token_in_inactive_factory(self):
        for passed, factory in (({'A4.factory'}, self.plan['addresses']['xPNTsFactoryV2']),
                                (self.passed, self.pin['oldOwnerIsolation']['targets']['xPNTsFactory'])):
            original = self.rpc(passed=passed)
            def rpc(method,params):
                if method == 'eth_call' and params[0] == dict(to=factory,data=a.calldata('getAllTokens()')):
                    return isolation_tests.raw([32,1,int(u.SP,16)])
                return original(method,params)
            rpc.local = True
            self.gate('old_owner_original_factory_enumeration' if passed == self.passed else 'old_timelock_delta_xpnts',lambda:self.pre(rpc,passed))

    def test_old_allowance_after_switch(self):
        for token in self.pin['oldOwnerIsolation']['xpnts']:
            bad = (token,'allowance(address,address)',[u.DEPLOYER,m.isolation.OLD_TIMELOCK],1)
            self.gate('old_timelock_allowance',lambda:self.pre(self.rpc(bad=bad)))
            self.gate('old_timelock_allowance',lambda:self.closing(self.rpc(bad=bad)))

    def test_new_owner_pre(self):
        token = a.create_address(self.plan['addresses']['xPNTsFactoryV2'],1)
        self.gate('old_owner_xpnts_owner_recheck',lambda:self.pre(self.rpc(bad=(token,'communityOwner()',[],int(m.isolation.OLD,16)))))

    def test_new_owner_closing(self):
        token = a.create_address(self.plan['addresses']['xPNTsFactoryV2'],1)
        self.gate('old_owner_xpnts_owner_recheck',lambda:self.closing(self.rpc(bad=(token,'communityOwner()',[],int(m.isolation.OLD_TIMELOCK,16)))))

    def test_build_call(self):
        plan = m.build_plan(self.pin,self.fixture.inputs,'a7')
        self.assertIn('expectedDiscoveryAfter',plan,'discovery_step_table')
        self.assertEqual(set(plan['expectedDiscoveryAfter']),{s['id'] for s in plan['steps']},'discovery_step_table')

    def test_release_inventory(self):
        coverage = m.discovery_coverage(self.plan,self.passed)
        spec = coverage['oldOwnerIsolation']['inventory']['targetInventories']
        self.assertEqual(spec[self.plan['addresses']['xPNTsFactoryV2']],ART['oldOwnerInventory']['xPNTsFactoryV2'])
        self.assertIn(a.create_address(self.plan['addresses']['xPNTsFactoryV2'],1),spec)

    def test_old_owner_original_factory_enumeration(self):
        for tokens in ([], list(m.isolation.ROUND_CLONES[:1]), list(m.isolation.ROUND_CLONES)):
            original = self.rpc()
            factory = self.pin['oldOwnerIsolation']['targets']['xPNTsFactory']
            def rpc(method, params):
                if method == 'eth_call' and params[0] == dict(to=factory, data=a.calldata('getAllTokens()')):
                    return isolation_tests.raw([32, len(tokens), *[int(t,16) for t in tokens]])
                return original(method, params)
            self.gate('old_owner_original_factory_enumeration', lambda: m.current_discovery(rpc, m.discovery_coverage(self.plan,self.passed), self.block))

    def test_old_owner_release_factory_enumeration(self):
        self.gate('old_owner_release_factory_enumeration', lambda: m.current_discovery(self.rpc(extra=u.SP), m.discovery_coverage(self.plan,self.passed), self.block))

    def test_postswitch_enumeration(self):
        coverage = m.discovery_coverage(self.plan,self.passed)
        original = self.rpc()
        old_factory = self.pin['oldOwnerIsolation']['targets']['xPNTsFactory']
        def rpc(method,params):
            if method == 'eth_call' and params[0] == dict(to=old_factory,data=a.calldata('getAllTokens()')):
                tokens = self.pin['oldOwnerIsolation']['xpnts']
                return isolation_tests.raw([32,len(tokens),*[int(t,16) for t in tokens]])
            return original(method,params)
        try:
            actual = m.current_discovery(rpc,coverage,self.block)
        except a.Gate as fault:
            self.fail(fault.record['gate'])
        self.assertEqual(actual,m.expected_discovery(self.plan,self.passed),'old_timelock_delta_xpnts')

    def test_preswitch_enumeration(self):
        rpc = self.rpc(passed=set(),bad=(self.pin['oldOwnerIsolation']['targets']['xPNTsFactory'],'getAllTokens()',[],32))
        original = rpc
        def missing(method,params):
            if method == 'eth_call' and params[0]['data'] == a.calldata('getAllTokens()'): return isolation_tests.raw([32,0])
            return original(method,params)
        self.gate('old_owner_factory_enumeration',lambda:m.current_discovery(missing,m.discovery_coverage(self.plan,set()),self.block))


DISCOVERY_GATES = ('discovery_step_table', 'discovery_unlisted_effect', 'discovery_factory_prediction',
                   'discovery_factory_argument', 'discovery_token_prediction', 'discovery_operator_argument',
                   'discovery_old_authority', 'old_timelock_inventory_pinned_history',
                   'old_owner_original_factory_enumeration', 'old_owner_release_factory_enumeration')
DISCOVERY_CALLS = [
    ('rebuild_commit', 'isolation.inventory_source(tree, mode="release", names=tuple(sorted(set(isolation.NAMES) | {"xPNTsFactoryV2", "xPNTsTokenV2", "xPNTsTokenV2Ext"})))', 'discovery_old_authority'),
    ('build_expected_discovery', "pin_discovery(plan['pin'])", 'discovery_step_table'),
    ('expected_discovery', "pin_discovery(plan['pin'])", 'old_timelock_delta_targets'),
    ('discovery_coverage', 'expected_discovery(plan, passed)', 'old_timelock_delta_targets'),
    ('closing_timelock_inventory', 'current_discovery(rpc, pin, block)', 'old_timelock_inventory'),
    ('closing_timelock_inventory', 'pin_discovery(pin)', 'old_timelock_inventory'),
    ('post_pin_delta', 'current_discovery(rpc, pin, block)', 'old_timelock_delta_targets'),
    ('post_pin_delta', 'pin_discovery(pin)', 'old_timelock_delta_xpnts'),
    ('dvt_closing', "discovery_coverage(plan, {s['id'] for s in plan['steps']})", 'old_timelock_inventory'),
    ('dvt_closing', 'discovery_old_authority(rpc, closing, block)', 'discovery_old_authority'),
    ('finish', 'build_expected_discovery(plan)', 'discovery_step_table'),
    ('pre_send', "discovery_coverage(plan, context.get('passed', set()))", 'old_timelock_delta_targets'),
    ('pre_send', 'discovery_old_authority(rpc, coverage, block)', 'discovery_old_authority'),
    ('pre_send', 'isolation.never_granted_recheck(rpc, coverage, block)', 'old_owner_xpnts_owner_recheck'),
    ('dvt_closing', 'isolation.never_granted_recheck(rpc, coverage, block)', 'old_owner_xpnts_owner_recheck'),
    ('current_discovery', 'isolation.discover_targets(rpc, dict(pin, stateBlock=block))', 'old_timelock_delta_xpnts'),
    ('current_discovery', "u.code(rpc, pin['discoveryReleaseFactory'], block)", 'old_timelock_delta_targets'),
    ('discovery_old_authority', "isolation.authority_rows(pin['oldOwnerIsolation'])", 'discovery_old_authority'),
    ('discovery_old_authority', 'a.call(rpc, target, sig, *args, block=block)', 'discovery_old_authority'),
    ('discovery_old_authority', "a.call(rpc, token, 'allowance(address,address)', holder, isolation.OLD, block=block)", 'discovery_old_authority'),
    ('build_expected_discovery', "isolation.assert_manifest_calldata([step], plan['rebuild']['calldataSignatures'])", 'discovery_unlisted_effect'),
    ('pre_send', "old_timelock_holds_nothing(rpc, coverage, block, delta['approvalOwners'])", 'old_timelock_allowance'),
    ('dvt_closing', 'old_timelock_holds_nothing(rpc, closing, block)', 'old_timelock_allowance'),
    ('dvt_closing', 'closing_timelock_inventory(rpc, coverage, block)', 'old_timelock_inventory'),
    ('current_discovery', "a.call(rpc, pin['discoveryReleaseFactory'], 'getAllTokens()', block=block)", 'old_timelock_delta_xpnts'),
    ('current_discovery', "a.call(rpc, pin['discoveryOriginalFactory'], 'getAllTokens()', block=block)", 'old_timelock_delta_xpnts'),
]


class DiscoveryCallTests(unittest.TestCase):
    """Deletion controls bind each caller to its named behavioral gate above."""
    pass


def discovery_call_test(function, expression, gate):
    def test(self):
        source = Path(m.__file__).read_text()
        tree = ast.parse(source)
        fn = next(n for n in ast.walk(tree) if isinstance(n,ast.FunctionDef) and n.name == function)
        sites = [n for n in ast.walk(fn) if isinstance(n,ast.Call) and ast.get_source_segment(source,n) == expression]
        self.assertEqual(len(sites),1,gate)
    return test


for _i, (_function, _expression, _gate) in enumerate(DISCOVERY_CALLS):
    setattr(DiscoveryCallTests,'test_call_'+str(_i),discovery_call_test(_function,_expression,_gate))

if __name__ == '__main__':
    unittest.main()
