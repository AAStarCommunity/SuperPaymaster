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
ANNI = '0x'+'66'*20
DVT = '0x'+'77'*20
COMMITTEE = '0x'+'88'*20
OLD = '0x'+'99'*20
ART = dict(commit='a'*40, forgeVersion='forge Version: 1.7.1', contracts={name: dict(
    bytecode='0x60006000f3', runtimeIdentity=dict(artifactRuntime='0x6000', ranges=[]),
    storageLayout={}, metadata={}) for name in m.NAMES})


def pin():
    p = base.pin()
    p['senders']['anni'] = dict(address=ANNI, nonce=55, balance=100*10**18)
    p['pauseList'] = sorted([u.DEPLOYER, ANNI, base.HOLDER])
    p['historicalOperators'] = list(p['pauseList'])
    p.update(oldAggregator=OLD, oldActivity={}, bindings={DVT:'0x6000', COMMITTEE:'0x6000'},
        stake=10**17, stakeDelay=86400, withdrawTime=0, entryPointDeposit=10**17,
        totalTrackedBalance=293414*10**16, protocolRevenue=39959*10**16,
        operatorBalances={u.DEPLOYER:169001*10**16, ANNI:84454*10**16, base.HOLDER:0})
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
        releaseEvidence={key:'c'*64 for key in ('conformance','mutation','slither','sourceVerificationPlan')},
        verifier=dict(commit='d'*40, ciSha256='e'*64, buildSha256='f'*64,
                      artifact=dict(bytecode='0x60006000f3', runtimeIdentity=dict(artifactRuntime='0x6000', ranges=[]))), pop=pops)


class FakeChain:
    """Read-only state for B2/B4; unknown RPC requests always fail the test."""
    def __init__(self, plan):
        self.plan = plan
        self.balances = dict(totalTrackedBalance=m.BUFFER, protocolRevenue=m.BUFFER,
                            operatorBalances={x:0 for x in plan['pin']['pauseList']})
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
            for who, amount in self.balances['operatorBalances'].items():
                if data == a.calldata('operators(address)', who):
                    return a.cast('abi-encode', 'c(uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256)',
                                  amount, 1, 1, 0, 0, 0, 0, 0, 0)
                if data == a.calldata('isSlashPending(address)', who):
                    return a.cast('abi-encode', 'c(uint256)', self.pending)
        raise AssertionError((method, params))


class ManifestTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name)/'external.json'
        self.pin = pin()
        self.data = input_data(self.pin)
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
        for i in range(4):
            approval, execution = steps[2*i:2*i+2]
            n = self.pin['safeNonce']+i
            self.assertEqual(approval['safeNonce'], n)
            self.assertEqual(execution['safeNonce'], n)
            self.assertEqual(approval['safeHash'], u.safe_hash(approval['inner'], n))
            self.assertEqual(execution['tx']['data'], u.safe_payload(execution['inner']))

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
        for mutate in (lambda c:c.balances.update(totalTrackedBalance=m.BUFFER+1),
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

    def test_solvency_probe_records_deficit_and_restores(self):
        chain = FakeChain(self.plan)
        chain.local = True
        history = []
        def rpc(method, params):
            history.append(method)
            if method == 'evm_snapshot': return 'snap'
            if method == 'evm_revert': return True
            raise AssertionError(method)
        rpc.local = True
        initial = dict(chain.balances, cappedBalance=0)
        deposited = dict(totalTrackedBalance=m.BUFFER+10**18, protocolRevenue=m.BUFFER,
                         operatorBalances={u.DEPLOYER:10**18, ANNI:0, base.HOLDER:0})
        withdrawn = dict(totalTrackedBalance=10**18, protocolRevenue=0,
                         operatorBalances=deposited['operatorBalances'])
        with patch.object(a, 'address', return_value=u.SAFE), patch.object(u, 'fixture_tx', return_value={}), \
             patch.object(u, 'receipt', return_value={}), patch.object(m, 'balances', side_effect=[deposited, withdrawn]), \
             patch.object(a, 'word', side_effect=[10**18, 10**18-m.BUFFER]):
            result = m.solvency_probe(rpc, self.plan, initial)
        self.assertFalse(result['allSolvent'])
        self.assertEqual([x['shortfall'] for x in result['observations']], [m.BUFFER]*3)
        self.assertEqual(history, ['evm_snapshot', 'evm_revert'])

    def test_all_requested_controls_registered(self):
        self.assertEqual(set(m.CONTROLS), {'early_unpause','factory_binding','early_bls','early_swap',
            'funded_swap','old_reputation','registry_nonowner','early_verifier','repeat_verifier','verifier_skip'})


    def rehearse_fake(self, already_applied=False, solvent=True):
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
            raise AssertionError((method, params))
        rpc.local = True
        rpc.engine_process = SimpleNamespace()
        def word(r, target, sig, *args, **kw):
            if sig == 'nonce()': return state['safe']
            if sig == 'getTimestamp(bytes32)': return state['etas'][args[0]]
            if sig == 'pendingFraudProofVerifierReadyAt()': return state['verifierEta']
            if sig == 'balanceOf(address)': return 0
            raise AssertionError(sig)
        def measure(remote, r, plan, step, overrides, ts, calibrate):
            step.update(executionTimestamp=ts, estimateGas=100000, localEstimateGas=100000,
                        forkGasUsed=90000, minedGasMinimum=80000 if step['tx']['to'] is None else None,
                        rrRequired=False, rrWitness=None)
            step['tx']['gas'] = hex(130000)
            return {}
        def receipt(r, tx):
            step = next(x for x in self.plan['steps'] if x['tx'] == tx)
            sid = step['id']
            self.assertEqual(state['nonces'][tx['from']], a.qty(tx['nonce']))
            state['nonces'][tx['from']] += 1
            state['now'] = state['next']
            state['safe'] += int(sid.endswith('_exec'))
            if sid.endswith('schedule_exec'):
                state['etas'][self.plan['operations'][step['operation']]['id']] = state['now']+u.DELAY
            if sid == 'A12b': state['verifierEta'] = state['now']+4*m.DAY
            if sid == 'upgrade_execute_exec': state['gasEta'] = state['now']+u.DELAY
            sent.append((sid, state['now']))
            return dict(status='0x1', gasUsed=hex(90000), blockNumber='0x150', transactionHash='0x'+'12'*32, logs=[])
        def pre(r, plan, step, context, measured=False):
            if step['id'] == 'activation_execute_exec':
                self.assertIn('upgradeBlock', context)
                context['B2'] = {'checked':True}
                gates.append(len(sent))
            return step['tx']
        def controls(r, plan, sid, output):
            if sid == 'after_B4': output.extend(dict(control=x) for x in m.CONTROLS)
        patches = [
            patch.object(a, 'process_alive'), patch.object(a, 'nonce', side_effect=lambda r,who,*args:state['nonces'][who]),
            patch.object(a, 'word', side_effect=word),
            patch.object(a, 'block_data', side_effect=lambda *args:dict(timestamp=hex(state['now']), number='0x150', gasLimit='0xbebc200')),
            patch.object(a, 'call', side_effect=lambda *args, **kw:a.cast('abi-encode', 'c(uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256)',
                *u.GAS, *u.GAS, state['gasEta'])),
            patch.object(a, 'mined_identity'), patch.object(a, 'trace_overrides'),
            patch.object(u, 'measure_step', side_effect=measure), patch.object(u, 'receipt', side_effect=receipt),
            patch.object(u, 'safe_trace'), patch.object(u, 'safe_exec_events'), patch.object(u, 'check_inventory'),
            patch.object(u, 'assert_frozen'), patch.object(m, 'pre_send', side_effect=pre),
            patch.object(m, 'controls_at', side_effect=controls), patch.object(m, 'check_predicate', return_value=True), patch.object(m, 'batch_readback', return_value={}),
            patch.object(m, 'b4_needed', return_value=not already_applied),
            patch.object(m, 'balances', return_value=dict(totalTrackedBalance=m.BUFFER, protocolRevenue=m.BUFFER,
                operatorBalances={x:0 for x in self.pin['pauseList']})),
            patch.object(m, 'solvency_probe', return_value={'allSolvent':solvent})]
        with contextlib.ExitStack() as stack:
            for p in patches: stack.enter_context(p)
            if solvent:
                m.run_manifest(None, rpc, self.plan, Path(self.tmp.name))
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

    def test_rehearsal_b4_skip_keeps_nonce(self):
        sent, _, _, state = self.rehearse_fake(already_applied=True)
        self.assertNotIn('B4', dict(sent))
        self.assertTrue(self.plan['steps'][-1]['skipped'])
        self.assertEqual(state['nonces'][u.DEPLOYER], a.qty(self.plan['steps'][-1]['tx']['nonce']))
        m.validate_plan(self.plan, self.inputs, frozen=True)

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

    def test_sign_send_refused(self):
        self.assertEqual(m.main(['sign']), 3)
        self.assertEqual(m.main(['send']), 3)


if __name__ == '__main__':
    unittest.main()
