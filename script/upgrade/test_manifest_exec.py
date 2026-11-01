#!/usr/bin/env python3
"""Offline manifest tests; only cast ABI encoding/keccak use a subprocess."""
import sys
sys.dont_write_bytecode = True
import copy
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

a, u = m.a, m.u
REAL_RELEASE_GATE = m.release_gate
ANNI = m.ANNI
DVT = m.DVT
SAMPLE = json.loads(Path(__file__).with_name('fixtures').joinpath('dvt-fraud-drill-sample-4.11.json').read_text())
COMMITTEE = m.COMMITTEE
OLD = m.OLD_AGGREGATOR
ART = dict(commit='a'*40, aggregatorVersion=m.AGG_VERSION, forgeVersion='forge Version: 1.7.1', contracts={name: dict(
    bytecode='0x60006000f3a00001', runtimeIdentity=dict(artifactRuntime='0x6000', ranges=[]),
    storageLayout={}, metadata={}) for name in m.NAMES})

for art in ART['contracts'].values(): art['creationHashes'] = m.creation_hashes(art['bytecode'])

ART['contracts']['BLSAggregator']['storageLayout'] = dict(storage=[dict(label='proposalSignersCommitment', slot='29', offset=0, type='map')],
    types={'map':dict(encoding='mapping', key='uint', value='bytes'), 'uint':dict(label='uint256'), 'bytes':dict(label='bytes32')})


def fraud_data(p, agg):
    guardians = sorted(x['validator'] for x in p['guardianInventory'] if x['validator'] != a.ZERO)
    pid, mask, token = 2**200+123, 7, '0x'+'ab'*20
    proof = a.cast('abi-encode', 'c(uint256,address,uint8,uint256,address,uint256,address[])',
                   pid, u.DEPLOYER, 1, 42, token, mask, '['+','.join(guardians)+']')
    f = dict(toolCommit='b'*40, verifierCommit=m.VERIFIER_COMMIT, aggregator=agg,
        verifier=a.create_address(u.DEPLOYER, p['senders']['deployer']['nonce']+23), registry=u.REG,
        domainSeparator=base.HASH, block=a.qty(p['block']), pid=pid, fraudProofId=1,
        guiltyGuardians=guardians, fraudProof=proof, signerMask=mask, messageHash=m.fraud_message_hash(base.HASH, pid, u.DEPLOYER, 1, 42, token),
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


def pin():
    p = base.pin()
    p['senders']['anni'] = dict(address=ANNI, nonce=55, balance=100*10**18)
    p['pauseList'] = sorted([u.DEPLOYER, ANNI, base.HOLDER])
    p['historicalOperators'] = list(p['pauseList'])
    p.update(oldAggregator=OLD, oldActivity={}, bindings={DVT:'0x6000', COMMITTEE:'0x6000'},
        stake=10**17, stakeDelay=86400, withdrawTime=0, entryPointDeposit=10**17,
        totalTrackedBalance=293414*10**16, protocolRevenue=39959*10**16,
        operatorBalances={u.DEPLOYER:169001*10**16, ANNI:84454*10**16, base.HOLDER:0})
    p['guardianInventory'] = [dict(slot=i, validator=('0x'+format(i, '040x')) if i <= 3 else a.ZERO) for i in range(1, 14)]
    p['pendingAPNTsTokenEta'] = p['timestamp']+7*m.DAY
    return p


def input_data(p):
    # Synthetic bytecode and invalid-on-chain PoPs are deliberately only unit fixtures.
    agg = a.create_address(u.DEPLOYER, p['senders']['deployer']['nonce']+12)
    pops = []
    for i in range(3):
        validator = '0x'+format(i+1, '040x')
        pk = '('+','.join([a.ZERO32]*4)+')'
        sig = '('+','.join([a.ZERO32]*8)+')'
        pops.append(dict(validator=validator, slot=i+1, aggregator=agg, pinBlockHash=p['blockHash'],
                         calldata=a.calldata(m.POP, validator, pk, i+1, sig)))
    return dict(anni=ANNI, dvt=DVT, committee=COMMITTEE, sampled=sorted([u.DEPLOYER, ANNI]),
        depositTargetWei=10**18, releaseTag='unit-fixture', registryBaselineCommit='b'*40,
        releaseEvidence={key:'c'*64 for key in m.EVIDENCE_KINDS},
        verifier=dict(commit=m.VERIFIER_COMMIT, artifactPath='unit-fixture', ciSha256='e'*64, buildSha256=m.VERIFIER_SHA256,
                      artifact=dict(bytecode='0x60006000f3a00001', runtimeIdentity=dict(artifactRuntime='0x6000', ranges=[]))), pop=pops)


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


class Round8Controls(unittest.TestCase):
    def dvt_rebuild(self, mutate=None):
        creation = '0x60006000f3a00001'
        runtime = '0x6001'
        arts = {'OverIssueFraudProofVerifier': {'bytecode': {'object':creation}},
                'MockOverIssuableToken': {'deployedBytecode': {'object':runtime}}}
        if mutate == 'creation': arts['OverIssueFraudProofVerifier']['bytecode']['object'] += '00'
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
             patch.object(m, 'MOCK_TOKEN_RUNTIME_HASH', a.keccak(runtime)):
            return m.rebuild_dvt()

    def test_dvt_rebuilt_creation_gate(self):
        self.dvt_rebuild()
        with self.assertRaises(a.Gate) as caught: self.dvt_rebuild('creation')
        self.assertEqual(caught.exception.record['gate'], 'dvt_rebuilt_creation')

    def test_dvt_mock_rebuilt_runtime_gate(self):
        self.dvt_rebuild()
        with self.assertRaises(a.Gate) as caught: self.dvt_rebuild('runtime')
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
        with self.assertRaises(a.Gate) as caught: self.swap_control(broken_eta=True)
        self.assertEqual(caught.exception.record['gate'], 'receipt_status')

    def test_early_swap_refuses_old_implementation(self):
        with self.assertRaises(a.Gate) as caught: self.swap_control(old_impl=True, broken_eta=True)
        self.assertEqual(caught.exception.record['gate'], 'early_swap_implementation')

    def test_early_swap_requires_valid_accounting(self):
        with self.assertRaises(a.Gate) as caught: self.swap_control(bad_accounting=True)
        self.assertEqual(caught.exception.record['gate'], 'early_swap_accounting')

    def test_early_swap_requires_eta_revert_reason(self):
        with self.assertRaises(a.Gate) as caught: self.swap_control(wrong_reason=True)
        self.assertEqual(caught.exception.record['gate'], 'negative_early_swap_reason')


class ManifestTests(unittest.TestCase):
    def setUp(self):
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
            if kind == 'conformance': e['controls'] = {f'C{i}':'PASS' for i in range(1,10)}
            if kind == 'mutation': e['controls'] = {k:dict(redTest=v, mutated='FAIL', restored='PASS') for k,v in m.MUTATIONS.items()}
            if kind.startswith('dvt-'):
                e['counts']['passed'] = 23
                e['suites'] = {k:dict(passed=v, failed=0, skipped=0, result='PASS') for k,v in m.DVT_SUITES.items()}
                e['suites']['CC115GenuinePragueCrossRepo']['env'] = {'FOUNDRY_EVM_VERSION':'prague'}
            if kind == 'slither':
                e['tool']['name'] = 'slither'
                e['findings'] = dict(threshold='Low', aboveThreshold=[], accepted=[])
            if kind == 'reproducible-build':
                e['contracts'] = {k:m.creation_hashes('0x60006000f3a00001') for k in (*m.NAMES, 'OverIssueFraudProofVerifier')}
            self.data['releaseEvidence'][kind] = file_ref(kind, e)
        self.data['releaseEvidence']['sourceVerificationPlan'] = file_ref('source-plan', {'synthetic':True})
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
        for target, name, value in ((m, 'verifier_artifact', fixture_artifact), (m, 'rebuild_dvt', dict(bytecode=fixture_artifact['bytecode'], creationHashes=m.creation_hashes(fixture_artifact['bytecode']))), (m, 'release_gate', None)):
            mock = patch.object(target, name, return_value=value)
            mock.start()
            self.addCleanup(mock.stop)
        self.path.write_text(json.dumps(self.data))
        self.inputs = m.external(self.path)
        self.patch = patch.object(m, 'rebuild', return_value=ART)
        self.patch.start()
        self.addCleanup(self.patch.stop)
        self.plan = m.build_plan(self.pin, self.inputs)

    def step(self, sid):
        return next(s for s in self.plan['steps'] if s['id'] == sid)

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
        self.assertEqual(len(creates), 10)
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
        for i in range(5):
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
        self.assertEqual(self.plan['steps'][-1]['id'], 'B4')

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
            self.assertIn(s['sender'], self.pin['senders'])
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
        self.assertEqual(self.plan['budgetsWei']['deployer'],
                         len(d_steps)*100000*a.MAX_FEE+18*10**17)
        self.plan['pin']['senders']['deployer']['balance'] = 0
        with self.assertRaises(a.Gate):
            m.budget(self.plan)

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

    def test_no_gas_or_budget_fabricated(self):
        self.assertNotIn('budgetsWei', self.plan)
        self.assertTrue(all('gas' not in s['tx'] for s in self.plan['steps']))

    def test_unsampled_operator_remains_paused(self):
        checks = []
        def capture(rpc, pred, timestamp=None):
            checks.append(pred)
        with patch.object(a, 'call', return_value=a.cast('abi-encode', 'c(uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256)',
                          *u.GAS, 0, 0, 0, 0, 0)), patch.object(m, 'check_predicate', side_effect=capture):
            m.batch_readback(None, self.plan, True, 100)
        pauses = {p['args'][0]:p['expected'] for p in checks if p.get('signature') == 'operators(address)'}
        self.assertEqual(pauses, {u.DEPLOYER:0, ANNI:0, base.HOLDER:1})

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
            'funded_swap','old_reputation','registry_nonowner','early_verifier','repeat_verifier','verifier_placeholder','verifier_frontrun','verifier_wrong','unbacked_swap'})


    def rehearse_fake(self, already_applied=False, solvent=True, frontrun=False):
        state = dict(now=self.pin['timestamp'], safe=self.pin['safeNonce'], next=None,
                     nonces={v['address']:v['nonce'] for v in self.pin['senders'].values()}, etas={})
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
            if sig == 'balanceOf(address)': return m.BUFFER
            raise AssertionError(sig)
        def measure(remote, r, plan, step, overrides, ts, calibrate):
            step.update(executionTimestamp=ts, estimateGas=100000, localEstimateGas=100000,
                        forkGasUsed=90000, minedGasMinimum=80000 if step['tx']['to'] is None else None,
                        rrRequired=False, rrWitness=None)
            step['tx']['gas'] = hex(130000)
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
            return dict(status='0x0' if sid == 'B4' and frontrun else '0x1', gasUsed=hex(21000 if tx['data'] == '0x' else 90000), blockNumber='0x150', transactionHash='0x'+'12'*32, logs=[])
        def pre(r, plan, step, context, measured=False):
            if step['id'] == 'activation_execute_exec':
                self.assertIn('upgradeBlock', context)
                context['B2'] = {'checked':True}
                gates.append(len(sent))
            return step['tx']
        def controls(r, plan, sid, output):
            if sid == 'after_upgrade_execute_exec':
                self.assertEqual(sent[-1][0], 'upgrade_execute_exec')
            if sid == 'after_B4': output.extend(dict(control=x) for x in m.CONTROLS)
        patches = [
            patch.object(a, 'process_alive'), patch.object(a, 'nonce', side_effect=lambda r,who,*args:state['nonces'][who]),
            patch.object(a, 'word', side_effect=word),
            patch.object(a, 'block_data', side_effect=lambda *args:dict(timestamp=hex(state['now']), number='0x150', gasLimit='0xbebc200')),
            patch.object(a, 'call', side_effect=lambda *args, **kw:a.cast('abi-encode', 'c(uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256)',
                *u.GAS, *u.GAS, state['gasEta'])),
            patch.object(a, 'mined_identity'), patch.object(a, 'trace_overrides'),
            patch.object(m, 'b4_controls', return_value=[]),
            patch.object(u, 'probe', return_value=({'status':'0x1', 'gasUsed':hex(21000)}, None)),
            patch.object(u, 'measure_step', side_effect=measure), patch.object(u, 'receipt', side_effect=receipt),
            patch.object(m, 'mint_trace'), patch.object(u, 'safe_trace'), patch.object(u, 'safe_exec_events'), patch.object(u, 'check_inventory'),
            patch.object(u, 'assert_frozen'), patch.object(m, 'pre_send', side_effect=pre),
            patch.object(m, 'controls_at', side_effect=controls), patch.object(m, 'check_predicate', return_value=True), patch.object(m, 'batch_readback', return_value={}),
            patch.object(m, 'b4_needed', return_value=not already_applied),
            patch.object(m, 'balances', return_value=dict(totalTrackedBalance=m.BUFFER, protocolRevenue=m.BUFFER,
                operatorBalances={x:0 for x in self.pin['pauseList']})),
            patch.object(m, 'fraud_rehearsal', return_value={'synthetic':True}),
            patch.object(m, 'solvency_probe', return_value={'allSolvent':solvent})]
        with contextlib.ExitStack() as stack:
            for p in patches: stack.enter_context(p)
            if solvent:
                m.run_manifest(None, rpc, self.plan, Path(self.tmp.name))
                self.assertEqual(sum(call.args[2] == 'after_upgrade_execute_exec'
                                     for call in m.controls_at.call_args_list), 1)
                m.fraud_rehearsal.assert_called_once_with(rpc, self.plan)
            else:
                with self.assertRaises(a.Gate) as caught:
                    m.run_manifest(None, rpc, self.plan, Path(self.tmp.name))
                self.assertEqual(caught.exception.record['gate'], 'post_swap_solvency')
        return sent, waits, gates, state

    def test_rehearsal_orders_all_steps_warps_and_b2(self):
        sent, waits, gates, state = self.rehearse_fake()
        self.assertEqual([x[0] for x in sent], [s['id'] for s in self.plan['steps']])
        times = dict(sent)
        self.assertGreaterEqual(times['upgrade_execute_exec'], times['upgrade_schedule_exec']+u.DELAY)
        self.assertGreaterEqual(times['activation_schedule_approve'], times['upgrade_execute_exec']+u.DELAY)
        self.assertGreaterEqual(times['activation_execute_exec'], self.pin['pendingAPNTsTokenEta'])
        self.assertGreaterEqual(times['activation_execute_exec'], times['activation_schedule_exec']+u.DELAY)
        self.assertGreaterEqual(times['B4'], times['A12b']+4*m.DAY)
        self.assertEqual(gates, [len(sent)-2]*2)
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
        record = result['steps'][-1]
        self.assertEqual((record['step'], record['variant'], record['receipt']['status']), ('B4', 'apply', '0x0'))
        self.assertEqual(state['nonces'][u.DEPLOYER], a.qty(self.step('B4')['tx']['nonce'])+1)

    def test_rehearsal_stops_on_solvency_without_pass_record(self):
        sent, _, _, _ = self.rehearse_fake(solvent=False)
        self.assertEqual(sent[-1][0], 'B4')
        self.assertTrue((Path(self.tmp.name)/'manifest-solvency.json').exists())
        self.assertFalse((Path(self.tmp.name)/'manifest-simulate.json').exists())


    def test_unsigned_dvt_proposal_stops(self):
        logs = [dict(topics=[a.keccak('ProposalCreated(uint256,address,uint8)'), '0x'+format(1, '064x')])]
        for executed in (False, True):
            raw = a.cast('abi-encode', 'c(address,uint8,string,bool,bool,bytes32)',
                         u.DEPLOYER, 0, 'fixture', str(executed).lower(), 'true', a.ZERO32)
            with patch.object(u, 'creation', return_value=1), patch.object(u, 'scan', return_value=logs), patch.object(a, 'call', return_value=raw):
                if executed:
                    self.assertEqual(m.dvt_activity(None, DVT, '0x100'), logs)
                else:
                    with self.assertRaises(a.Gate):
                        m.dvt_activity(None, DVT, '0x100')

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
        with patch.object(a, 'nonce', return_value=a.qty(step['tx']['nonce'])), \
             patch.object(a, 'word', side_effect=word), \
             patch.object(a, 'address', side_effect=lambda r,t,s,*args: self.pin['capped'] if s == 'pendingAPNTsToken()' else u.DEPLOYER), \
             patch.object(u, 'safe_state', return_value=self.pin['safe']), patch.object(u, 'governance'), \
             patch.object(u, 'code', return_value='0xdead' if bad_runtime else '0x6000'), \
             patch.object(m, 'old_activity', return_value={}), patch.object(m, 'dvt_activity', return_value=[]), \
             patch.object(u, 'assert_frozen'):
            return m.pre_send(rpc, self.plan, step, dict(frozen=True, upgradeBlock='0x150',
                activationScheduledAt=self.pin['pendingAPNTsTokenEta']-u.DELAY))

    def test_pre_send_real_b2_is_required(self):
        self.pre_send_fixture()
        with self.assertRaises(a.Gate) as caught: self.pre_send_fixture(bad_buffer=True)
        self.assertEqual(caught.exception.record['gate'], 'B2_capped_buffer')

    def test_pre_send_bound_runtime_is_required(self):
        with self.assertRaises(a.Gate) as caught: self.pre_send_fixture(bad_runtime=True)
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
            bad['steps'][-1]['variants'][name]['value'] = '0x1'
            self.assertNotEqual(hashlib.sha256(json.dumps(bad, sort_keys=True).encode()).hexdigest(), original)
            with self.assertRaises(a.Gate): m.validate_plan(bad, self.inputs)
        for field, value in (('to', ANNI), ('data', '0x00'), ('nonce', '0x1'),
                             ('maxFeePerGas', '0x1'), ('maxPriorityFeePerGas', '0x1')):
            bad = copy.deepcopy(self.plan)
            bad['steps'][-1]['variants']['placeholder'][field] = value
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
        step['variants']['placeholder']['gas'] = hex(21000)
        expected = self.plan['addresses']['OverIssueFraudProofVerifier']
        for mode in ('preapplied', 'frontrun', 'wrong'):
            frozen = copy.deepcopy(step)
            state = dict(verifier=expected if mode == 'preapplied' else a.ZERO,
                         nonce=a.qty(step['tx']['nonce']))
            sent, context = [], {}
            def rpc(method, params):
                if method == 'eth_estimateGas': return hex(21000)
                if method == 'eth_getTransactionByHash': return {}
                raise AssertionError(method)
            def receipt(rpc, tx, status=None):
                self.assertIsNone(status)
                self.assertEqual(a.qty(tx['nonce']), state['nonce'])
                state['nonce'] += 1
                sent.append(tx)
                state['verifier'] = ANNI if mode == 'wrong' else expected
                return dict(status='0x1' if mode == 'preapplied' else '0x0',
                    gasUsed=hex(21000), transactionHash='0x'+'12'*32)
            def call(rpc, target, signature, *args):
                value = int(state['verifier'], 16) if signature == 'fraudProofVerifier()' else 0
                return '0x'+format(value, '064x')
            with patch.object(a, 'block_data', return_value=dict(timestamp='0x100', gasLimit=hex(a.GAS_CAP))), \
                 patch.object(a, 'call', side_effect=call), \
                 patch.object(a, 'address', side_effect=lambda *args:state['verifier']), \
                 patch.object(a, 'nonce', side_effect=lambda *args:state['nonce']), \
                 patch.object(a, 'word', return_value=step['safeNonce']), \
                 patch.object(a, 'mined_identity'), patch.object(m, 'pre_send'), \
                 patch.object(u, 'receipt', side_effect=receipt), \
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
            with self.assertRaises(a.Gate) as caught: m.build_plan(self.pin, self.inputs)
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
            with self.assertRaises(a.Gate) as caught: REAL_RELEASE_GATE(self.inputs, ART, self.pin)
        self.assertEqual(caught.exception.record['gate'], 'release_clean_tree')

    def test_built_aggregator_version_required(self):
        build = dict(ART, aggregatorVersion='BLSAggregator-4.11.0')
        with patch.object(m.subprocess, 'run', return_value=SimpleNamespace(stdout='', returncode=0)):
            with self.assertRaises(a.Gate) as caught: REAL_RELEASE_GATE(self.inputs, build, self.pin)
        self.assertEqual(caught.exception.record['gate'], 'built_aggregator_version')

    def test_cached_build_current_head_required(self):
        def run(cmd, **kwargs):
            return SimpleNamespace(returncode=0, stdout='' if 'status' in cmd else 'f'*40)
        with patch.object(m.subprocess, 'run', side_effect=run):
            with self.assertRaises(a.Gate) as caught: REAL_RELEASE_GATE(self.inputs, ART, self.pin)
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
            with self.assertRaises(a.Gate) as caught:
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
        with self.assertRaises(a.Gate) as caught: m.b2_gate(rpc, self.plan, '0x100')
        self.assertEqual(caught.exception.record['gate'], 'B2_single_upgrade')

    def test_b2_implementation_identity_required(self):
        chain = FakeChain(self.plan)
        def rpc(method, params):
            result = chain(method, params)
            if method == 'eth_getLogs' and params[0]['topics'][0] == a.keccak('Upgraded(address)'):
                result[0]['topics'][1] = '0x'+ANNI[2:].zfill(64)
            return result
        with self.assertRaises(a.Gate) as caught: m.b2_gate(rpc, self.plan, '0x100')
        self.assertEqual(caught.exception.record['gate'], 'B2_upgrade_identity')

    def test_guardian_inventory_and_anni_required(self):
        bad = copy.deepcopy(self.pin)
        bad['guardianInventory'][0]['validator'] = ANNI
        with self.assertRaises(a.Gate): m.build_plan(bad, self.inputs)
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
        with self.assertRaises(a.Gate) as caught: m.validate_nonce_history(pin, inputs)
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

    def test_creation_hash_comparison(self):
        contracts = copy.deepcopy(ART['contracts'])
        e = dict(contracts={k:v['creationHashes'].copy() for k,v in contracts.items()})
        self.assertEqual(m.compare_build_evidence(e, contracts), [])
        name = m.NAMES[0]
        e['contracts'][name]['fullCreationKeccak'] = a.ZERO32
        self.assertEqual(m.compare_build_evidence(e, contracts), [name])
        e['contracts'][name]['strippedCreationKeccak'] = a.ZERO32
        with self.assertRaises(a.Gate): m.compare_build_evidence(e, contracts)
        left, right = (m.creation_hashes(x) for x in ('0x6000a16161010004', '0x6000a16161020004'))
        self.assertEqual(left['strippedCreationKeccak'], right['strippedCreationKeccak'])
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
        with self.assertRaises(a.Gate) as caught:
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
        with self.assertRaises(a.Gate) as caught: m.reconcile_nonces(self.history_rpc(), p, inputs)
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
        def rpc(method, params):
            if method == 'eth_getBalance': return '0x100'
            if method == 'eth_getStorageAt': return '0x'+ANNI[2:].zfill(64)
            return history(method, params)
        def address(rpc, target, sig, block):
            return u.DEPLOYER if sig == 'owner()' else OLD
        def word(rpc, target, sig, *args, **kw):
            if sig == 'MAX_VALIDATORS()': return 13
            if sig == 'validatorAtSlot(uint8)': return args[0] if args[0] <= 3 else 0
            raise AssertionError(sig)
        def call(rpc, target, sig, *args, **kw):
            if sig == 'version()': return a.cast('abi-encode', 'c(string)', 'Registry-5.8.0')
            if sig.startswith('getDepositInfo'): return a.cast('abi-encode','c(uint256,bool,uint256,uint256,uint256)', 1, 'true', 1, 86400, 0)
            raise AssertionError(sig)
        with patch.object(u, 'collect', return_value=copy.deepcopy(self.pin)), \
             patch.object(a, 'nonce', return_value=55), patch.object(u, 'code', side_effect=lambda r,t,b:'0x' if t == ANNI else '0x6000'), \
             patch.object(a, 'call', side_effect=call), patch.object(a, 'word', side_effect=word), \
             patch.object(a, 'address', side_effect=address), patch.object(m, 'old_activity', return_value={}), \
             patch.object(m, 'dvt_activity', return_value=[]), patch.object(m, 'balances', return_value={k:self.pin[k] for k in ('totalTrackedBalance','protocolRevenue','operatorBalances')}):
            collected = m.collect(rpc, '0x100', self.inputs)
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
        e['findings']['accepted'] = [dict(id='unreviewed',reason='reviewed exception')]
        m.evidence_file(self.file_ref('accepted-finding',e),'slither')

    def test_collect_registry_version_negative(self):
        with patch.object(u, 'collect', return_value=copy.deepcopy(self.pin)), \
             patch.object(a, 'nonce', return_value=55), patch.object(u, 'code', return_value='0x'), \
             patch.object(a, 'call', return_value='0x'):
            with self.assertRaises(a.Gate) as caught: m.collect(lambda method,params:'0x1', '0x100', self.inputs)
        self.assertEqual(caught.exception.record['gate'], 'registry_version')

    def test_sign_send_refused(self):
        self.assertEqual(m.main(['sign']), 3)
        self.assertEqual(m.main(['send']), 3)


if __name__ == '__main__':
    unittest.main()
