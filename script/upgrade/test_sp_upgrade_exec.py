#!/usr/bin/env python3
"""Offline adversarial tests. cast does only local ABI encoding and hashing."""
import sys
sys.dont_write_bytecode = True
import contextlib
import copy
import hashlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import sp_upgrade_exec as ex

a = ex.a
OTHER = '0xbb05d2e9890bcec6141e40a1066bf8927169b75e'
HOLDER = '0x'+'11'*20
OLD_OPERATOR = '0x'+'22'*20
BLOCK = '0x100'
HASH = '0x'+'ab'*32
ART = dict(commit=ex.CANDIDATE, forgeVersion='forge Version: 1.7.1', contracts={name: dict(
    bytecode='0x60006000f3', runtime={'artifactRuntime': '0x6000', 'ranges': []},
    metadata={}, sourceHashes={}) for name in ex.ART_NAMES})


def cfg(active=True, owner=ex.DEPLOYER):
    return a.cast('abi-encode', 'c('+ex.CONFIG_TYPE+')',
        '(1,2,3,4,5,6,7,'+str(active).lower()+',8,"PAYMASTER_SUPER",'+owner+',9)')


def pin():
    owners = sorted([a.APPROVER, a.EXECUTOR, OTHER])
    return dict(block=BLOCK, blockHash=HASH, timestamp=a.ACTIVATION+100,
        stateBlock=BLOCK, stateBlockHash=HASH, stateTimestamp=a.ACTIVATION+100,
        senders={label: dict(address=who, nonce=13000+i, balance=100*10**18)
                 for i, (label, who) in enumerate(a.SENDERS.items())}, safeNonce=17,
        safe=dict(owners=owners, threshold=2, modules=[], guard=a.ZERO32,
                  codes={who: ('0x6000' if who == ex.SAFE else '0x') for who in [ex.SAFE, ex.DEPLOYER, *owners]}),
        registryOwner=ex.DEPLOYER, roleConfig=cfg(), immutables=dict(entryPoint='0x'+'33'*20,
        REGISTRY=ex.REG, ETH_USD_PRICE_FEED='0x'+'44'*20), implementation='0x'+'55'*20,
        implementationCode='0x6001', holders=[HOLDER], historicalOperators=[OLD_OPERATOR],
        pauseList=sorted([HOLDER, OLD_OPERATOR]), registryCreation=1, spCreation=2, timelockCreation=3,
        pendingOperations=[], capped=a.create_address(ex.DEPLOYER, 12133), pendingAPNTsTokenEta=999999,
        guardianBefore=a.ZERO)


def measured_plan(state=None, digest=None):
    p = ex.build_plan(state or pin(), digest)
    for i, step in enumerate(p['steps']):
        step.update(executionTimestamp=p['pin']['stateTimestamp']+i+1, estimateGas=100000,
                    localEstimateGas=110000, forkGasUsed=90000,
                    minedGasMinimum=80000 if step['tx']['to'] is None else None,
                    rrRequired=False, rrWitness=None)
        step['tx']['gas'] = hex(ex.margin_limit(100000,110000,90000))
    ex.budget(p)
    return p


def event(topic, who, block=10, index=0, target=ex.REG, extra=None):
    return dict(address=target, topics=[topic, *([] if extra is None else extra), '0x'+who[2:].zfill(64)],
        data='0x', blockNumber=hex(block), blockHash='0x'+'cd'*32, transactionHash='0x'+format(index+1, '064x'),
        transactionIndex='0x0', logIndex=hex(index), removed=False)


class InventoryRPC:
    def __init__(self):
        self.holders = [HOLDER]
        self.count = 1
        grant = a.keccak('RoleRegistered(bytes32,address,uint256,uint256)')
        configured = a.keccak('OperatorConfigured(address,address,address)')
        self.logs = {ex.REG: [event(grant, HOLDER, extra=[ex.role()])],
                     ex.SP: [event(configured, OLD_OPERATOR, target=ex.SP)]}
        self.requests = []

    def __call__(self, method, params):
        self.requests.append((method, copy.deepcopy(params)))
        if method == 'eth_getLogs':
            q = params[0]
            return [x for x in self.logs[q['address']] if int(q['fromBlock'], 16) <= int(x['blockNumber'], 16) <= int(q['toBlock'], 16)]
        if method == 'eth_call':
            data = params[0]['data']
            if data.startswith(a.calldata('getRoleUserCount(bytes32)', ex.role())[:10]):
                return '0x'+format(self.count, '064x')
            if data.startswith(a.calldata('hasRole(bytes32,address)', ex.role(), HOLDER)[:10]):
                return '0x'+format(int('0x'+data[-40:] in self.holders), '064x')
        raise AssertionError((method, params))


class GasFork:
    """Mined status has an independent threshold; estimates deliberately understate it."""
    local = True
    def __init__(self, minimum=20000000, used=18000000, estimate=50000):
        self.minimum, self.used, self.estimate = minimum, used, estimate
        self.state = {'nonce':13000,'safeNonce':17,'timestamp':1000,'tx':None,'receipt':None}
        self.snapshots, self.requests, self.next_snapshot = {}, [], 0
        self.reservoir = True
        self.fail_trace = False
        self.block_gas_limit = 200_000_000

    def __call__(self, method, params):
        self.requests.append((method,copy.deepcopy(params)))
        if method == 'evm_snapshot':
            self.next_snapshot += 1
            self.snapshots[self.next_snapshot] = copy.deepcopy(self.state)
            return self.next_snapshot
        if method == 'evm_revert':
            self.state = self.snapshots.pop(params[0])
            return True
        if method == 'evm_setNextBlockTimestamp':
            self.state['timestamp'] = params[0]
            return True
        if method == 'eth_getTransactionCount': return hex(self.state['nonce'])
        if method == 'eth_call': return '0x'+format(self.state['safeNonce'],'064x')
        if method == 'eth_estimateGas': return hex(self.estimate)
        if method == 'eth_sendTransaction':
            tx = copy.deepcopy(params[0])
            assert int(tx['nonce'],16) == self.state['nonce']
            self.state['nonce'] += 1
            gas = int(tx['gas'],16)
            h = '0x'+hashlib.sha256(json.dumps(tx,sort_keys=True).encode()).hexdigest()
            self.state['tx'] = dict(tx, to=tx.get('to'), input=tx['data'], type='0x2')
            self.state['receipt'] = dict(transactionHash=h, gasUsed=hex(self.used if gas >= self.minimum else gas),
                status='0x1' if gas >= self.minimum else '0x0', blockNumber='0x101',
                contractAddress=HOLDER if tx.get('to') is None else None)
            return h
        if method == 'eth_getBlockByNumber':
            return dict(hash='0x'+'ab'*32, number='0x101', timestamp=hex(self.state.get('timestamp', 2000)),
                        gasLimit=hex(self.block_gas_limit))
        if method == 'eth_getTransactionByHash': return self.state['tx']
        if method == 'eth_getTransactionReceipt': return self.state['receipt']
        if method == 'debug_traceTransaction':
            if self.fail_trace: raise RuntimeError('trace unavailable')
            gas = int(self.state['tx']['gas'],16)
            return {'structLogs':[dict(pc=0,depth=1,gas=a.GAS_CAP-100000,
                stateGasReservoir=gas-a.GAS_CAP if self.reservoir else 0)]}
        raise AssertionError((method,params))


class ExecutorTests(unittest.TestCase):
    def setUp(self):
        self.b = patch.object(ex, 'build', return_value=copy.deepcopy(ART))
        self.b.start()
        self.addCleanup(self.b.stop)

    def plan(self):
        return measured_plan()

    def fails(self, gate, fn, *args):
        with self.assertRaises(a.Gate) as caught:
            fn(*args)
        self.assertEqual(caught.exception.record['gate'], gate)

    def test_valid_plan_and_numeric_nonce_sequence(self):
        plan = self.plan()
        self.assertIs(ex.validate_plan(plan), plan)
        counters = {v['address']: v['nonce'] for v in plan['pin']['senders'].values()}
        safe = 17
        for step in plan['steps']:
            self.assertEqual(step['tx']['nonce'], hex(counters[step['tx']['from']]))
            self.assertEqual(step['safeNonce'], safe)
            counters[step['tx']['from']] += 1
            safe += step['id'].endswith('_exec')
        self.assertEqual(safe, 21)

    def test_plan_order_freeze_pauses_transfer_safe(self):
        p = self.plan()
        ids = [x['id'] for x in p['steps']]
        self.assertEqual(ids[:5], ['deploy', 'freeze', 'pause_0', 'pause_1', 'transfer'])
        self.assertEqual(ids[5:9], ['upgrade_schedule_approve', 'upgrade_schedule_exec', 'upgrade_execute_approve', 'upgrade_execute_exec'])
        self.assertEqual(p['operations']['activation']['predecessor'], p['operations']['upgrade']['id'])
        self.assertEqual(p['operations']['upgrade']['data'][0], a.calldata('upgradeToAndCall(address,bytes)',
                p['implementation'], a.calldata('setGlobalPaused(bool)', 'true')))

    def test_extension_is_internal_create_one(self):
        p = self.plan()
        self.assertEqual(p['extension'], a.create_address(p['implementation'], 1))
        self.assertEqual(sum(x['tx']['to'] is None for x in p['steps']), 1)

    def test_role_config_round_trip_preserves_every_other_field(self):
        original = cfg()
        frozen = ex.frozen_config(original)
        self.assertTrue(ex.config(original)['isActive'])
        self.assertFalse(ex.config(frozen)['isActive'])
        before, after = ex.uints(original), ex.uints(frozen)
        self.assertEqual([i for i, (x, y) in enumerate(zip(before, after)) if x != y], [8])
        decoded = a.cast('abi-decode', 'f(bytes32,'+ex.CONFIG_TYPE+')()', ex.freeze_calldata(original)[10:], '--input')
        self.assertIn('false', decoded)
        self.assertIn(ex.DEPLOYER, decoded.lower())

    def test_invalid_role_config_description_offset(self):
        raw = bytearray.fromhex(cfg()[2:])
        raw[320:352] = (9999).to_bytes(32, 'big')
        self.fails('config_description_offset', ex.config, '0x'+raw.hex())

    def test_invalid_role_config_bool(self):
        raw = bytearray.fromhex(cfg()[2:])
        raw[256:288] = (2).to_bytes(32, 'big')
        self.fails('config_range_7', ex.config, '0x'+raw.hex())

    def test_inventory_union_keeps_exited_historical_operator(self):
        rpc = InventoryRPC()
        result = ex.inventory(rpc, BLOCK, 1, 2)
        self.assertEqual(result, dict(holders=[HOLDER], historicalOperators=[OLD_OPERATOR], pauseList=sorted([HOLDER, OLD_OPERATOR])))
        self.assertTrue(all(p[-1] == BLOCK for m, p in rpc.requests if m == 'eth_call'))

    def test_inventory_reconciles_count(self):
        rpc = InventoryRPC()
        rpc.count = 2
        self.fails('holder_count', ex.inventory, rpc, BLOCK, 1, 2)

    def test_inventory_filters_exited_holders(self):
        rpc = InventoryRPC()
        rpc.holders = []
        self.fails('holder_count', ex.inventory, rpc, BLOCK, 1, 2)

    def test_scan_rejects_duplicate_logs(self):
        rpc = InventoryRPC()
        rpc.logs[ex.REG] *= 2
        self.fails('log_duplicate', ex.scan, rpc, ex.REG, 1, BLOCK, [])

    def test_scan_rejects_removed_logs(self):
        rpc = InventoryRPC()
        rpc.logs[ex.REG][0]['removed'] = True
        self.fails('log_removed', ex.scan, rpc, ex.REG, 1, BLOCK, [])

    def test_scan_rejects_wrong_emitter(self):
        rpc = InventoryRPC()
        rpc.logs[ex.REG][0]['address'] = ex.SP
        self.fails('log_emitter', ex.scan, rpc, ex.REG, 1, BLOCK, [])

    def test_scan_covers_every_chunk_including_last(self):
        requests = []
        def rpc(method, params):
            requests.append(params[0])
            return []
        self.assertEqual(ex.scan(rpc, ex.REG, 1, hex(4001), []), [])
        self.assertEqual([(x['fromBlock'], x['toBlock']) for x in requests], [('0x1', '0x7d0'), ('0x7d1', '0xfa0'), ('0xfa1', '0xfa1')])

    def test_creation_boundary_positive_and_negative(self):
        rpc = lambda m, p: '0x' if int(p[1], 16) < 17 else '0x6000'
        self.assertEqual(ex.creation(rpc, ex.TL, BLOCK), 17)

    def test_a3a_gate_refuses_absent_timelock(self):
        self.fails('a3a_timelock_code', ex.a3a_gate, lambda m, p: '0x', BLOCK)

    def a3a_ready(self, owner=ex.DEPLOYER, capped=None, capped_owner=ex.TL):
        capped = capped or a.create_address(ex.DEPLOYER, 12133)
        def address(rpc, target, sig, block='latest'):
            return {'pendingAPNTsToken()': capped, 'owner()': owner if target == ex.SP else capped_owner}[sig]
        return contextlib.ExitStack(), address

    def test_a3a_gate_requires_s6(self):
        stack, address = self.a3a_ready(capped_owner=ex.DEPLOYER)
        with stack:
            stack.enter_context(patch.object(ex, 'code', return_value='0x6000'))
            stack.enter_context(patch.object(ex, 'creation', return_value=3))
            stack.enter_context(patch.object(ex, 'timelock_creation'))
            stack.enter_context(patch.object(ex, 'governance'))
            stack.enter_context(patch.object(a, 'address', side_effect=address))
            self.fails('a3a_s6_owner', ex.a3a_gate, Mock(), BLOCK)

    def test_a3a_gate_requires_s7_before_transfer(self):
        stack, address = self.a3a_ready(owner=ex.TL)
        with stack:
            for name, value in [('code', '0x6000'), ('creation', 3), ('timelock_creation', None), ('governance', None)]:
                stack.enter_context(patch.object(ex, name, return_value=value))
            stack.enter_context(patch.object(a, 'address', side_effect=address))
            self.fails('a3a_s7_before_ownership_transfer', ex.a3a_gate, Mock(), BLOCK)

    def test_a3a_gate_requires_exact_s7_token(self):
        stack, address = self.a3a_ready(capped=HOLDER)
        with stack:
            for name, value in [('code', '0x6000'), ('creation', 3), ('timelock_creation', None), ('governance', None)]:
                stack.enter_context(patch.object(ex, name, return_value=value))
            stack.enter_context(patch.object(a, 'address', side_effect=address))
            self.fails('a3a_capped_address', ex.a3a_gate, Mock(), BLOCK)

    def test_reopening_registration_fails_even_same_authorities(self):
        with patch.object(a, 'address', return_value=ex.DEPLOYER), patch.object(a, 'call', return_value=cfg()):
            self.fails('registration_still_frozen', ex.assert_frozen, Mock(), pin())

    def test_registry_authority_drift(self):
        with patch.object(a, 'address', return_value=HOLDER):
            self.fails('registry_authority', ex.assert_frozen, Mock(), pin())

    def test_role_config_authority_drift(self):
        with patch.object(a, 'address', return_value=ex.DEPLOYER), patch.object(a, 'call', return_value=cfg(False, HOLDER)):
            self.fails('config_authority', ex.assert_frozen, Mock(), pin())

    def test_frozen_config_other_fields_cannot_drift(self):
        raw = bytearray.fromhex(cfg(False)[2:])
        raw[32:64] = (123).to_bytes(32, 'big')
        with patch.object(a, 'address', return_value=ex.DEPLOYER), patch.object(a, 'call', return_value='0x'+raw.hex()):
            self.fails('frozen_full_config', ex.assert_frozen, Mock(), pin())

    def test_pause_readback_failure_names_operator(self):
        with patch.object(a, 'call', return_value='0x'+'0'*576):
            self.fails('operator_paused_'+HOLDER, ex.require_pauses, Mock(), {'pauseList': [HOLDER]})

    def test_safe_hash_signatures_and_nonce(self):
        p = self.plan()
        step = next(s for s in p['steps'] if s['id'] == 'upgrade_schedule_exec')
        decoded = a.cast('abi-decode', 'f(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)()',
                         step['tx']['data'][10:], '--input')
        signatures = '0x'+''.join(who[2:].zfill(64)+'0'*64+'01' for who in sorted((a.EXECUTOR, a.APPROVER)))
        self.assertIn(signatures, decoded)
        self.assertEqual(step['safeHash'], ex.safe_hash(step['inner'], step['safeNonce']))
        self.assertNotEqual(step['safeHash'], ex.safe_hash(step['inner'], step['safeNonce']+1))

    def test_plan_contains_no_unpause_or_registration_reactivation(self):
        p = self.plan()
        for step in p['steps']:
            self.assertNotEqual(step['tx']['data'], a.calldata('setGlobalPaused(bool)', 'false'))
            self.assertNotIn(a.calldata('setOperatorPaused(address,bool)', HOLDER, 'false')[2:], step['tx']['data'][2:])
        self.assertEqual(p['operations']['activation']['data'], [a.calldata('executeGasParams()')])

    def test_operation_hash_matches_independent_cast(self):
        p = self.plan()
        op = p['operations']['activation']
        expected = a.keccak(a.cast('abi-encode', 'c(address,uint256,bytes,bytes32,bytes32)', ex.SP, 0,
                           a.calldata('executeGasParams()'), p['operations']['upgrade']['id'], op['salt']))
        self.assertEqual(op['id'], expected)

    def test_rpc_hash_mismatch(self):
        with patch.object(a, 'call', return_value=a.ZERO32):
            self.fails('onchain_operation_hash', ex.check_op_hash, Mock(), self.plan()['operations']['upgrade'])

    def test_pending_operations_cancel_and_reschedule_same_id(self):
        op = '0x'+'ef'*32
        sch = a.keccak('CallScheduled(bytes32,uint256,address,uint256,bytes,bytes32,uint256)')
        cancel = a.keccak('Cancelled(bytes32)')
        logs = [dict(topics=[sch, op, a.ZERO32]), dict(topics=[cancel, op]), dict(topics=[sch, op, a.ZERO32])]
        with patch.object(ex, 'scan', return_value=logs), patch.object(a, 'word', side_effect=[1, 999]):
            self.assertEqual(ex.pending_operations(Mock(), 3, BLOCK), [dict(id=op, state=1, eta=999, scheduledLogs=[logs[2]])])

    def test_pending_operation_executed_disappears(self):
        op = '0x'+'ef'*32
        sch = a.keccak('CallScheduled(bytes32,uint256,address,uint256,bytes,bytes32,uint256)')
        exe = a.keccak('CallExecuted(bytes32,uint256,address,uint256,bytes)')
        with patch.object(ex, 'scan', return_value=[dict(topics=[sch, op, a.ZERO32]), dict(topics=[exe, op, a.ZERO32])]):
            self.assertEqual(ex.pending_operations(Mock(), 3, BLOCK), [])

    def test_pending_operation_inconsistent_state_rejected(self):
        op = '0x'+'ef'*32
        sch = a.keccak('CallScheduled(bytes32,uint256,address,uint256,bytes,bytes32,uint256)')
        with patch.object(ex, 'scan', return_value=[dict(topics=[sch, op, a.ZERO32])]), patch.object(a, 'word', side_effect=[3, 1]):
            self.fails('pending_operation_state', ex.pending_operations, Mock(), 3, BLOCK)

    def safe_context(self, overrides=None):
        data = pin()['safe']
        overrides = overrides or {}
        owners = a.cast('abi-encode', 'c(address[])', '['+','.join(data['owners'])+']')
        page = a.cast('abi-encode', 'c(address[],address)', '[]', ex.SENTINEL)
        def call(rpc, target, sig, *args, **kw):
            return overrides.get(sig, owners if sig == 'getOwners()' else page)
        def rpc(method, params):
            return overrides.get(method, data['guard'] if method == 'eth_getStorageAt' else data['codes'][params[0]])
        stack = contextlib.ExitStack()
        stack.enter_context(patch.object(a, 'call', side_effect=call))
        stack.enter_context(patch.object(a, 'word', return_value=2))
        return stack, rpc

    def test_safe_collects_current_three_owners_and_deployer_code(self):
        stack, rpc = self.safe_context()
        with stack:
            self.assertEqual(ex.safe_state(rpc, BLOCK), pin()['safe'])

    def test_safe_rejects_guard(self):
        stack, rpc = self.safe_context({'eth_getStorageAt': '0x'+'01'*32})
        with stack:
            self.fails('safe_guard', ex.safe_state, rpc, BLOCK)

    def test_safe_rejects_module(self):
        stack, rpc = self.safe_context({'getModulesPaginated(address,uint256)': a.cast('abi-encode', 'c(address[],address)', '['+HOLDER+']', ex.SENTINEL)})
        with stack:
            self.fails('safe_modules', ex.safe_state, rpc, BLOCK)

    def test_safe_rejects_pagination_cycle(self):
        stack, rpc = self.safe_context({'getModulesPaginated(address,uint256)': a.cast('abi-encode', 'c(address[],address)', '['+HOLDER+']', HOLDER)})
        with stack:
            self.fails('module_cursor_cycle', ex.safe_state, rpc, BLOCK)

    def test_safe_rejects_delegated_deployer(self):
        stack, base = self.safe_context()
        def rpc(method, params):
            return '0xef0100'+HOLDER[2:] if method == 'eth_getCode' and params[0] == ex.DEPLOYER else base(method, params)
        with stack:
            self.fails('undelegated_'+ex.DEPLOYER, ex.safe_state, rpc, BLOCK)

    def test_safe_rejects_delegation_designator(self):
        stack, base = self.safe_context()
        def rpc(method, params):
            return '0xef0100'+HOLDER[2:] if method == 'eth_getCode' and params[0] == ex.SAFE else base(method, params)
        with stack:
            self.fails('safe_runtime', ex.safe_state, rpc, BLOCK)

    def test_pre_restore_gate_requires_all_independent_checks(self):
        p = self.plan()
        with contextlib.ExitStack() as stack:
            frozen = stack.enter_context(patch.object(ex, 'assert_frozen'))
            upgrade = stack.enter_context(patch.object(ex, 'upgrade_readback'))
            inventory = stack.enter_context(patch.object(ex, 'check_inventory'))
            stack.enter_context(patch.object(ex, 'safe_state', return_value=p['pin']['safe']))
            gov = stack.enter_context(patch.object(ex, 'governance'))
            states = stack.enter_context(patch.object(ex, 'operation_state'))
            stack.enter_context(patch.object(ex, 'pending_operations', return_value=[]))
            stack.enter_context(patch.object(a, 'block_data', return_value={'number': BLOCK}))
            result = ex.final_gate(Mock(), p)
            self.assertEqual(result['service'], 'PAUSED')
            frozen.assert_called_once()
            upgrade.assert_called_once_with(unittest.mock.ANY, p, activated=True)
            inventory.assert_called_once()
            gov.assert_called_once()
            self.assertEqual(states.call_count, 2)

    def test_sign_send_refuse_without_rpc_or_build(self):
        for command in ('sign', 'send'):
            with self.subTest(command=command), tempfile.TemporaryDirectory() as d, patch.object(a, 'RPC') as rpc, contextlib.redirect_stderr(io.StringIO()):
                out = Path(d)/'refusal'
                self.assertEqual(ex.main([command, '--out', str(out)]), 3)
                self.assertEqual(json.loads((out/'FAILURE.json').read_text())['gate'], command+'_disabled')
                rpc.assert_not_called()

    def test_output_nonempty_refusal_does_not_overwrite(self):
        with tempfile.TemporaryDirectory() as d, contextlib.redirect_stderr(io.StringIO()):
            out = Path(d)
            (out/'keep').write_text('original')
            rc = ex.main(['plan', '--out', str(out), '--rpc-file', 'unused', '--rpc-file-secondary', 'unused', '--block', '256'])
            self.assertEqual(rc, 1)
            self.assertEqual(list(out.iterdir()), [out/'keep'])
            self.assertEqual((out/'keep').read_text(), 'original')

    def test_frozen_plan_digest_and_duplicate_keys(self):
        with tempfile.TemporaryDirectory() as d:
            out = Path(d)
            ex.save_plan(out, self.plan())
            self.assertEqual(a.load_plan(out/'plan.json'), self.plan())
            (out/'plan.json').write_text('{"schema":1,"schema":2}')
            self.fails('plan_hash', a.load_plan, out/'plan.json')
            (out/'plan.json.sha256').write_text(hashlib.sha256((out/'plan.json').read_bytes()).hexdigest())
            with self.assertRaises(a.Gate):
                a.load_plan(out/'plan.json')

    def test_same_fork_continuation_calls_a3a_before_upgrade(self):
        local = SimpleNamespace(local=True)
        p = pin()
        ap = {'pin': {'block': BLOCK, 'timelock': ex.TL}}
        order = []
        with tempfile.TemporaryDirectory() as d, contextlib.ExitStack() as stack:
            path = Path(d)/'a3a.json'
            path.write_text('{}')
            stack.enter_context(patch.object(a, 'load_plan', return_value=ap))
            stack.enter_context(patch.object(a, 'validate_plan'))
            stack.enter_context(patch.object(a, 'safe_hash_check'))
            stack.enter_context(patch.object(a, 'preflight', return_value=ap['pin']))
            stack.enter_context(patch.object(a, 'block_data', return_value={'number': BLOCK}))
            def collect(rpc, block, source):
                self.assertIs(rpc, local)
                order.append('collect_post_a3a')
                return p
            stack.enter_context(patch.object(ex, 'collect', side_effect=collect))
            def rehearse(remote, plan, out, after):
                order.append('a3a_rehearsal')
                after(local)
            stack.enter_context(patch.object(a, 'rehearse', side_effect=rehearse))
            def run(rpc, plan, out, **kwargs):
                self.assertTrue(kwargs["calibrate"])
                self.assertIs(rpc, local)
                order.append('upgrade')
                return {'status': 'PASS'}
            stack.enter_context(patch.object(ex, 'run_upgrade', side_effect=run))
            stack.enter_context(patch.object(a, 'relay_evidence'))
            self.assertEqual(ex.simulate_command(Mock(), path, Path(d)), {'status': 'PASS'})
            self.assertEqual(order, ['a3a_rehearsal', 'collect_post_a3a', 'upgrade'])
            self.assertEqual(json.loads((Path(d)/'combined-simulate.json').read_text())['phases'], ['a3a', 'upgrade'])

    def test_plan_calibrates_on_fork_and_keeps_remote_read_only(self):
        p = pin()
        with tempfile.TemporaryDirectory() as d, contextlib.ExitStack() as stack:
            out = Path(d)
            (out/'engine.stderr').write_text('')
            stack.enter_context(patch.object(a, 'git_state', return_value={}))
            collect = stack.enter_context(patch.object(ex, 'collect', side_effect=[p,p,p]))
            stack.enter_context(patch.object(a, 'relay_evidence'))
            local = SimpleNamespace(local=True)
            stack.enter_context(patch.object(a, 'fork', return_value=contextlib.nullcontext(local)))
            remote, secondary = Mock(), Mock()
            def calibrate(rpc, plan, output, **kwargs):
                self.assertIs(rpc, local)
                self.assertIs(kwargs['remote'], remote)
                self.assertTrue(kwargs['calibrate'])
                plan.update(measured_plan(p))
            stack.enter_context(patch.object(ex, 'run_upgrade', side_effect=calibrate))
            result = ex.plan_command(remote, secondary, BLOCK, out)
            self.assertEqual(result, self.plan())
            self.assertEqual(collect.call_args_list[0].args, (remote, BLOCK))
            self.assertEqual(collect.call_args_list[1].args, (secondary, BLOCK))
            remote.assert_not_called()
            secondary.assert_not_called()

    def test_plan_independent_pin_disagreement(self):
        p, other = pin(), pin()
        other['safeNonce'] += 1
        with tempfile.TemporaryDirectory() as d, patch.object(a, 'git_state', return_value={}), patch.object(ex, 'collect', side_effect=[p, other]):
            self.fails('independent_pin', ex.plan_command, Mock(), Mock(), BLOCK, Path(d))
            self.assertFalse((Path(d)/'plan.json').exists())

    def test_wait_never_moves_time_backwards(self):
        rpc = Mock()
        with patch.object(a, 'block_data', return_value={'timestamp': '0x64'}):
            ex.wait_until(rpc, 99)
            rpc.assert_not_called()
            ex.wait_until(rpc, 200)
            self.assertEqual(rpc.call_args_list[0].args, ('evm_setNextBlockTimestamp', [200]))
            self.assertEqual(rpc.call_args_list[1].args, ('evm_mine', []))

    def test_remote_cannot_run_fixture_transactions(self):
        rpc = SimpleNamespace(local=False)
        self.fails('fixture_local_only', ex.fixture_tx, rpc, ex.DEPLOYER, ex.SP, '0x')

    def test_remote_cannot_run_upgrade(self):
        self.fails('upgrade_local_only', ex.run_upgrade, SimpleNamespace(local=False), self.plan(), Path('/unused'))


    def pre_send_context(self, sid='transfer', changes=None):
        changes = changes or {}
        p = self.plan()
        step = next(s for s in p['steps'] if s['id'] == sid)
        stack = contextlib.ExitStack()
        stack.enter_context(patch.object(ex, 'safe_state', return_value=p['pin']['safe']))
        stack.enter_context(patch.object(ex, 'governance'))
        stack.enter_context(patch.object(ex, 'assert_frozen'))
        stack.enter_context(patch.object(ex, 'require_pauses'))
        stack.enter_context(patch.object(ex, 'check_inventory'))
        stack.enter_context(patch.object(ex, 'pending_operations', return_value=changes.get('pending', [])))
        stack.enter_context(patch.object(ex, 'check_op_hash'))
        stack.enter_context(patch.object(ex, 'operation_state'))
        stack.enter_context(patch.object(ex, 'upgrade_readback', return_value=[*ex.GAS, *ex.GAS, 1]))
        stack.enter_context(patch.object(ex, 'code', return_value=p['pin']['implementationCode']))
        stack.enter_context(patch.object(a, 'block_data', return_value={'number': BLOCK, 'timestamp': '0x1000', 'gasLimit': hex(changes.get('block_gas_limit', 200_000_000))}))
        stack.enter_context(patch.object(a, 'nonce', side_effect=lambda rpc, who, block='latest': changes.get('pending_nonce' if block == 'pending' else 'nonce', int(step['tx']['nonce'], 16))))
        def address(rpc, target, sig):
            if sig == 'pendingAPNTsToken()':
                return changes.get('token', p['pin']['capped'])
            if target == p['pin']['capped']:
                return ex.TL
            if sig == 'owner()':
                return changes.get('sp_owner', ex.DEPLOYER if sid == 'transfer' or sid.startswith('pause_') or sid in ('deploy', 'freeze') else ex.TL)
            raise AssertionError((target, sig))
        stack.enter_context(patch.object(a, 'address', side_effect=address))
        def word(rpc, target, sig, *args):
            if sig == 'nonce()': return changes.get('safe_nonce', step['safeNonce'])
            if sig == 'pendingAPNTsTokenEta()': return p['pin']['pendingAPNTsTokenEta']
            if sig == 'approvedHashes(address,bytes32)': return changes.get('approved', 1)
            raise AssertionError(sig)
        stack.enter_context(patch.object(a, 'word', side_effect=word))
        stack.enter_context(patch.object(a, 'call', side_effect=lambda rpc, target, sig, *args: p['pin']['roleConfig'] if sig == 'getRoleConfig(bytes32)' else changes.get('safe_hash', step.get('safeHash', a.ZERO32))))
        def rpc(method, params):
            if method == 'eth_chainId': return hex(a.CHAIN)
            if method == 'eth_getStorageAt': return '0x'+p['pin']['implementation'][2:].zfill(64)
            if method == 'eth_estimateGas': return hex(changes.get('gas', 100000))
            if method == 'eth_getBalance': return hex(changes.get('balance', 100*10**18))
            raise AssertionError((method, params))
        return stack, rpc, p, step

    def test_pre_send_returns_exact_transaction_after_reads(self):
        stack, rpc, plan, step = self.pre_send_context()
        with stack:
            self.assertEqual(ex.pre_send(step, rpc, plan), step['tx'])

    def test_pre_send_rejects_gas_above_block_gas_limit(self):
        stack, rpc, plan, step = self.pre_send_context(changes={'block_gas_limit': 1000})
        with stack:
            self.fails('pre_send_block_gas_limit', ex.pre_send, step, rpc, plan)

    def test_pre_send_rejects_pending_nonce_drift(self):
        stack, rpc, plan, step = self.pre_send_context(changes={'pending_nonce': 999})
        with stack:
            self.fails('pre_send_pending_nonce', ex.pre_send, step, rpc, plan)

    def test_pre_send_rejects_safe_nonce_drift(self):
        stack, rpc, plan, step = self.pre_send_context(changes={'safe_nonce': 999})
        with stack:
            self.fails('pre_send_safe_nonce', ex.pre_send, step, rpc, plan)

    def test_pre_send_rejects_s7_pointer_drift(self):
        stack, rpc, plan, step = self.pre_send_context(changes={'token': HOLDER})
        with stack:
            self.fails('pre_send_s7_preserved', ex.pre_send, step, rpc, plan)

    def test_pre_send_rejects_conflicting_pending_batch(self):
        stack, rpc, plan, step = self.pre_send_context(changes={'pending': [{'id': HASH}]})
        with stack:
            self.fails('pending_operation_exclusion', ex.pre_send, step, rpc, plan)

    def test_pre_send_rejects_estimate_exceeding_limit(self):
        stack, rpc, plan, step = self.pre_send_context(changes={'gas': a.GAS_CAP})
        with stack:
            self.fails('pre_send_gas', ex.pre_send, step, rpc, plan)

    def test_pre_send_low_estimate_cannot_hide_higher_mined_minimum(self):
        stack, rpc, plan, step = self.pre_send_context('deploy', {'gas': 100000})
        step['minedGasMinimum'] = 20000000
        step['rrRequired'] = True
        with stack:
            self.fails('pre_send_mined_minimum', ex.pre_send, step, rpc, plan)

    def test_pre_send_rejects_insufficient_balance(self):
        stack, rpc, plan, step = self.pre_send_context(changes={'balance': 1})
        with stack:
            self.fails('pre_send_balance', ex.pre_send, step, rpc, plan)

    def test_pre_send_rejects_onchain_safe_hash_mismatch(self):
        stack, rpc, plan, step = self.pre_send_context('upgrade_schedule_exec', {'safe_hash': a.ZERO32})
        with stack:
            self.fails('onchain_safe_hash', ex.pre_send, step, rpc, plan)

    def test_pre_send_requires_approve_hash(self):
        stack, rpc, plan, step = self.pre_send_context('upgrade_schedule_exec', {'approved': 0})
        with stack:
            self.fails('safe_hash_approved', ex.pre_send, step, rpc, plan)

    def test_activation_pre_send_waits_for_internal_eta(self):
        stack, rpc, plan, step = self.pre_send_context('activation_schedule_approve')
        with stack, patch.object(ex, 'upgrade_readback', return_value=[*ex.GAS, *ex.GAS, 0x2000]):
            self.fails('internal_gas_wait', ex.pre_send, step, rpc, plan)

    def test_every_post_freeze_step_rereads_both_authorities(self):
        for sid in [s['id'] for s in self.plan()['steps'] if s['id'] not in ('deploy', 'freeze')]:
            with self.subTest(sid=sid):
                stack, rpc, plan, step = self.pre_send_context(sid)
                with stack, patch.object(ex, 'assert_frozen', side_effect=a.Gate('authorities', 'changed', 'same')) as gate:
                    self.fails('authorities', ex.pre_send, step, rpc, plan)
                    gate.assert_called_once_with(rpc, plan['pin'])

    def readback_context(self, changes=None, activated=False):
        changes = changes or {}
        p = self.plan()
        stack = contextlib.ExitStack()
        stack.enter_context(patch.object(ex, 'runtime'))
        stack.enter_context(patch.object(ex, 'require_pauses'))
        stack.enter_context(patch.object(a, 'word', return_value=changes.get('paused', 1)))
        gas = [*ex.GAS, *([0]*5 if activated else [*ex.GAS, 12345])]
        def call(rpc, target, sig, *args):
            if sig == 'version()': return a.cast('abi-encode', 'c(string)', 'SuperPaymaster-5.5.0')
            self.assertEqual(sig, 'gasParams()')
            return a.cast('abi-encode', 'c(uint32,uint32,uint32,uint32,uint32,uint32,uint32,uint32,uint64)', *changes.get('gas', gas))
        stack.enter_context(patch.object(a, 'call', side_effect=call))
        def address(rpc, target, sig):
            if sig == 'owner()': return changes.get('owner', ex.TL)
            if sig == 'guardian()': return changes.get('guardian', a.ZERO)
            if sig == 'EXTENSION()': return p['extension']
            return p['pin']['immutables'][sig[:-2]]
        stack.enter_context(patch.object(a, 'address', side_effect=address))
        rpc = lambda method, params: '0x'+changes.get('impl', p['implementation'])[2:].zfill(64)
        return stack, rpc, p

    def test_upgrade_readback_uses_actual_gas_params_getter(self):
        stack, rpc, p = self.readback_context(activated=True)
        with stack:
            self.assertEqual(ex.upgrade_readback(rpc, p, True), [*ex.GAS, *([0]*5)])

    def test_readback_rejects_global_unpause(self):
        stack, rpc, p = self.readback_context({'paused': 0})
        with stack:
            self.fails('global_pause', ex.upgrade_readback, rpc, p)

    def test_readback_rejects_owner(self):
        stack, rpc, p = self.readback_context({'owner': ex.DEPLOYER})
        with stack:
            self.fails('sp_owner', ex.upgrade_readback, rpc, p)

    def test_readback_rejects_guardian(self):
        stack, rpc, p = self.readback_context({'guardian': HOLDER})
        with stack:
            self.fails('guardian', ex.upgrade_readback, rpc, p)

    def test_readback_rejects_implementation_slot(self):
        stack, rpc, p = self.readback_context({'impl': HOLDER})
        with stack:
            self.fails('implementation_slot', ex.upgrade_readback, rpc, p)

    def test_readback_rejects_wrong_activated_tuple(self):
        stack, rpc, p = self.readback_context({'gas': [200000,160000,5000,175000,*([0]*5)]}, True)
        with stack:
            self.fails('active_gas', ex.upgrade_readback, rpc, p, True)

    def test_readback_rejects_uncleared_queue(self):
        stack, rpc, p = self.readback_context({'gas': [*ex.GAS, *ex.GAS, 999]}, True)
        with stack:
            self.fails('pending_gas_cleared', ex.upgrade_readback, rpc, p, True)

    def test_generic_sp_immutable_masks_value_check_every_occurrence(self):
        identity = {'artifactRuntime': '0x60'+'00'*64, 'ranges': [
            {'id': '1', 'name': 'REGISTRY', 'start': 1, 'length': 32},
            {'id': '1', 'name': 'REGISTRY', 'start': 33, 'length': 32}]}
        value = int(ex.REG,16).to_bytes(32,'big')
        runtime = '0x60'+value.hex()*2
        result = a.verify_runtime(Mock(), {}, runtime, 'SuperPaymaster', identity, {'REGISTRY': value})
        self.assertTrue(result['unmaskedBytesEqual'])
        self.fails('immutable_value_REGISTRY', a.verify_runtime, Mock(), {},
            runtime[:-2]+'00', 'SuperPaymaster', identity, {'REGISTRY': value})

    def test_mint_controls_restore_and_check_exact_negative(self):
        rpc = Mock(return_value=True)
        tx = {'data': '0x1234'}
        p = self.plan()
        with patch.object(ex, 'mint_state', return_value={'state':'unchanged'}), patch.object(a, 'nonce', return_value=123), patch.object(a, 'word', side_effect=[17,0,17]), patch.object(ex, 'mint_fixture', return_value=tx), patch.object(a, 'negative', return_value={'control':'safeMint_negative'}) as negative:
            record = ex.mint_control(rpc, p, False)
            self.assertEqual(record['calldata'], tx['data'])
            self.assertEqual(negative.call_args.args[2], a.calldata('RoleNotConfigured(bytes32,bool)', ex.role(), 'false'))
            self.assertIn(unittest.mock.call('evm_revert', [True]), rpc.call_args_list)

    def test_mint_positive_requires_real_role_membership(self):
        rpc = Mock(return_value=True)
        with patch.object(ex, 'mint_state', return_value={'state':'unchanged'}), patch.object(a, 'nonce', return_value=123), patch.object(a, 'word', side_effect=[17,0]), patch.object(ex, 'mint_fixture', return_value={'data':'0x1234'}), patch.object(a, 'receipt', return_value={'status':'0x1'}):
            self.fails('safe_mint_positive_membership', ex.mint_control, rpc, self.plan(), True)
            self.assertEqual(rpc.call_args.args[0], 'evm_revert')

    def test_fresh_guardian_slot_is_read_from_compiler_layout(self):
        art = copy.deepcopy(ART)
        art['contracts']['SuperPaymaster']['storageLayout'] = {'storage':[{'label':'guardian','slot':'38','offset':0}]}
        with patch.object(ex, 'build', return_value=art):
            rpc = Mock(return_value=a.ZERO32)
            self.assertEqual(ex.initial_guardian(rpc, BLOCK), a.ZERO)
            rpc.assert_called_once_with('eth_getStorageAt', [ex.SP, '0x26', BLOCK])
            rpc.return_value = HASH
            self.fails('initial_guardian_pause_slot', ex.initial_guardian, rpc, BLOCK)


    def trace_fixture(self):
        p = self.plan()
        step = next(s for s in p['steps'] if s['id'] == 'upgrade_execute_exec')
        pause = a.calldata('setGlobalPaused(bool)', 'true')
        delegates = [dict(type='DELEGATECALL', to=target, input=pause) for target in (p['implementation'], p['extension'])]
        calls = [dict(type='CALL', to=ex.SP, **{'from':ex.TL}, input=data,
                      calls=delegates if i == 0 else []) for i, data in enumerate(p['operations']['upgrade']['data'])]
        trace = dict(type='CALL', to=ex.SAFE, **{'from':a.EXECUTOR}, input=step['tx']['data'],
                     calls=[dict(type='CALL', to=ex.TL, **{'from':ex.SAFE}, input=step['inner'], calls=calls)])
        return p, step, trace

    def test_success_trace_binds_top_level_safe_timelock_upgrade_pause_queue(self):
        p, step, trace = self.trace_fixture()
        result = ex.safe_trace(Mock(return_value=trace), p, step, {'transactionHash':HASH})
        self.assertEqual(result, {'topLevelSafe':True,'entryPointExcluded':True})

    def test_trace_rejects_bundled_governance(self):
        p, step, trace = self.trace_fixture()
        trace['calls'].append(dict(to=p['pin']['immutables']['entryPoint']))
        self.fails('no_entrypoint_in_governance', ex.safe_trace, Mock(return_value=trace), p, step, {'transactionHash':HASH})

    def test_trace_rejects_wrong_root_sender(self):
        p, step, trace = self.trace_fixture()
        trace['from'] = HOLDER
        self.fails('safe_trace_top_from', ex.safe_trace, Mock(return_value=trace), p, step, {'transactionHash':HASH})

    def test_trace_rejects_wrong_timelock_caller(self):
        p, step, trace = self.trace_fixture()
        trace['calls'][0]['from'] = HOLDER
        self.fails('safe_timelock_caller', ex.safe_trace, Mock(return_value=trace), p, step, {'transactionHash':HASH})

    def test_trace_rejects_missing_atomic_pause(self):
        p, step, trace = self.trace_fixture()
        trace['calls'][0]['calls'][0]['calls'] = []
        self.fails('atomic_pause_delegatecall_'+p['implementation'], ex.safe_trace, Mock(return_value=trace), p, step, {'transactionHash':HASH})

    def test_trace_rejects_unexpected_sp_write(self):
        p, step, trace = self.trace_fixture()
        trace['calls'][0]['calls'].append(dict(type='CALL',to=ex.SP,**{'from':ex.TL},input='0xdeadbeef'))
        self.fails('timelock_sp_call_inputs', ex.safe_trace, Mock(return_value=trace), p, step, {'transactionHash':HASH})

    def test_timelock_creation_input_binds_exact_constructor(self):
        init = ART['contracts']['TimelockController']['bytecode']+a.cast('abi-encode', 'c(uint256,address[],address[],address)',
            ex.DELAY, '['+ex.SAFE+']', '['+ex.SAFE+']', a.ZERO)[2:]
        tx = {'from':ex.DEPLOYER,'nonce':hex(12132),'to':None,'input':init,'hash':HASH}
        def rpc(method, params):
            if method == 'eth_getBlockByNumber': return {'transactions':[tx]}
            return {'status':'0x1','contractAddress':ex.TL,'blockNumber':'0x3'}
        ex.timelock_creation(rpc,3)
        tx['input'] = init+'00'
        self.fails('a3a_timelock_creation_input', ex.timelock_creation,rpc,3)


    def rr_step(self, minimum=20000000, estimate=100000, used=18000000):
        step = self.plan()['steps'][0]
        limit = ex.margin_limit(minimum,estimate,used)
        step.update(estimateGas=estimate,localEstimateGas=estimate,forkGasUsed=used,
                    minedGasMinimum=minimum,rrRequired=True,
                    rrWitness=dict(engineCommit=a.COMMIT,transactionHash=HASH,gasLimit=limit,
                    stepIndex=0,pc=0,depth=1,gas=a.GAS_CAP-100000,stateGasReservoir=limit-a.GAS_CAP))
        step['tx']['gas'] = hex(limit)
        return step

    def test_rr_create_with_mined_minimum_and_first_step_witness_is_allowed(self):
        step = self.rr_step()
        ex.validate_gas(step)
        self.assertGreater(int(step['tx']['gas'],16),a.GAS_CAP)

    def test_non_create_above_regular_cap_fails(self):
        step = self.rr_step()
        step['tx']['to'] = ex.SP
        step['minedGasMinimum'] = None
        self.fails('rr_create_only',ex.validate_gas,step)

    def test_rr_create_requires_actual_mined_need(self):
        step = self.rr_step(minimum=10000000,estimate=20000000)
        self.fails('rr_mined_need',ex.validate_gas,step)

    def test_rr_threshold_is_strict_and_uses_the_13_over_10_headroom(self):
        self.assertEqual(ex.RR_THRESHOLD,a.GAS_CAP*10//13)
        step = self.rr_step(minimum=ex.RR_THRESHOLD,estimate=20000000)
        self.fails('rr_mined_need',ex.validate_gas,step)

    def test_rr_create_without_witness_fails(self):
        step = self.rr_step()
        step['rrWitness'] = None
        self.fails('rr_witness_keys',ex.validate_gas,step)

    def test_rr_create_zero_reservoir_fails(self):
        step = self.rr_step()
        step['rrWitness']['stateGasReservoir'] = 0
        self.fails('rr_witness_stateGasReservoir',ex.validate_gas,step)

    def test_rr_create_witness_from_later_step_fails(self):
        step = self.rr_step()
        step['rrWitness']['stepIndex'] = 1
        self.fails('rr_first_step',ex.validate_gas,step)

    def test_rr_create_witness_from_old_engine_fails(self):
        step = self.rr_step()
        step['rrWitness']['engineCommit'] = '926eb1d087523f1de437e3c0c49ea6d26407e827'
        self.fails('rr_witness_engine',ex.validate_gas,step)

    def test_safe_exec_events_match_live_indexed_shape(self):
        success = a.keccak('ExecutionSuccess(bytes32,uint256)')
        failure = a.keccak('ExecutionFailure(bytes32,uint256)')
        h = '0x' + '65' * 32
        live = dict(address=ex.SAFE, topics=[success, h], data='0x' + '00' * 32)
        ex.safe_exec_events([live], h)
        cases = [
            ([dict(address=ex.SAFE, topics=[success], data='0x' + h[2:] + '00' * 32)], 'safe_success_event'),  # 1.3.0 shape
            ([dict(live, topics=[success, '0x' + '66' * 32])], 'safe_success_event'),                     # other tx
            ([dict(live, address='0x' + '12' * 20)], 'safe_success_event'),                                # other emitter
            ([live, dict(address=ex.SAFE, topics=[failure, h], data='0x' + '00' * 32)], 'safe_no_failure_event'),
        ]
        for logs, gate in cases:
            with self.subTest(gate=gate):
                self.fails(gate, ex.safe_exec_events, logs, h)

    def test_rr_create_above_100m_fails(self):
        step = self.rr_step()
        step['tx']['gas'] = hex(100000001)
        self.fails('create_gas_ceiling',ex.validate_gas,step)

    def test_rr_create_just_under_100m_is_allowed_with_matching_measurements(self):
        # ceil(76,923,076 x 1.3) = 99,999,999; no integer minimum lands exactly on 100M with the 13/10 margin.
        step = self.rr_step(minimum=76923076,estimate=100000,used=30000000)
        self.assertEqual(step['tx']['gas'],hex(99999999))
        ex.validate_gas(step)

    def test_a3a_default_cap_still_rejects_rr_create(self):
        tx = self.rr_step()['tx']
        self.fails('gas_cap',a.tx_rpc,tx)

    def test_mined_search_ignores_low_estimate_and_finds_exact_success_boundary(self):
        rpc = GasFork()
        tx = ex.build_plan(pin())['steps'][0]['tx']
        original = copy.deepcopy(rpc.state)
        minimum,trials = ex.mined_minimum(rpc,tx,2000)
        self.assertEqual(minimum,20000000)
        self.assertEqual(rpc.state,original)
        statuses = {r['gasLimit']:r['status'] for r in trials}
        self.assertEqual(statuses[minimum],'0x1')
        self.assertEqual(statuses[minimum-1],'0x0')
        self.assertLessEqual(len(trials),28)
        self.assertFalse(any(method == 'eth_estimateGas' for method,params in rpc.requests))

    def test_mined_search_all_trials_roll_back_nonces_and_pending_timestamp(self):
        rpc = GasFork(minimum=16000000,used=15000000)
        before = copy.deepcopy(rpc.state)
        minimum,_ = ex.mined_minimum(rpc,ex.build_plan(pin())['steps'][0]['tx'],2000)
        self.assertEqual(minimum,16000000)
        self.assertEqual(rpc.state,before)
        self.assertEqual(rpc.snapshots,{})

    def test_mined_search_no_success_at_ceiling_fails_closed(self):
        rpc = GasFork(minimum=100000001)
        before = copy.deepcopy(rpc.state)
        self.fails('mined_search_high_success',ex.mined_minimum,rpc,ex.build_plan(pin())['steps'][0]['tx'],2000)
        self.assertEqual(rpc.state,before)

    def test_mined_search_is_only_for_create(self):
        self.fails('mined_search_create_only',ex.mined_minimum,GasFork(),self.plan()['steps'][1]['tx'],2000)

    def test_probe_refuses_remote(self):
        self.fails('probe_local',ex.probe,SimpleNamespace(local=False),self.plan()['steps'][0]['tx'],20000000,2000)

    def test_probe_restores_state_when_rr_trace_is_unavailable(self):
        rpc = GasFork()
        rpc.fail_trace = True
        before = copy.deepcopy(rpc.state)
        with self.assertRaises(RuntimeError):
            ex.probe(rpc,self.plan()['steps'][0]['tx'],26000000,2000,witness=True)
        self.assertEqual(rpc.state,before)

    def test_probe_rejects_zero_reservoir_on_pinned_engine(self):
        rpc = GasFork()
        rpc.reservoir = False
        self.fails('rr_nonzero_reservoir',ex.probe,rpc,self.plan()['steps'][0]['tx'],26000000,2000,True)
        self.assertEqual(rpc.state['nonce'],13000)

    def test_rr_create_above_block_gas_limit_fails(self):
        p = ex.build_plan(pin())
        step = p['steps'][0]
        rpc = GasFork(20000000,18000000,90000)
        rpc.block_gas_limit = 25_000_000  # below the 1.3x margin of the 20M mined minimum (26M)
        remote = Mock(return_value=hex(100000))
        self.fails('block_gas_limit', ex.measure_step, remote, rpc, p, step, {}, 2000, True)

    def test_calibrate_create_records_all_measurements_and_uses_mined_minimum(self):
        p = ex.build_plan(pin())
        step = p['steps'][0]
        rpc = GasFork(20000000,18000000,90000)
        remote = Mock(return_value=hex(100000))
        overrides = {ex.SP:{'nonce':'0x2','stateDiff':{a.ZERO32:HASH}}}
        evidence = ex.measure_step(remote,rpc,p,step,overrides,2000,True)
        self.assertEqual(step['estimateGas'],100000)
        self.assertEqual(step['localEstimateGas'],90000)
        self.assertEqual(step['forkGasUsed'],18000000)
        self.assertEqual(step['minedGasMinimum'],20000000)
        self.assertEqual(step['tx']['gas'],hex(26000000))
        self.assertTrue(step['rrRequired'])
        self.assertGreater(step['rrWitness']['stateGasReservoir'],0)
        self.assertEqual(evidence['estimateContext']['stateOverrides'],overrides)
        sent = remote.call_args.args[1]
        self.assertNotIn('gas',sent[0])
        self.assertEqual(sent[1:],[p['pin']['block'],overrides,{'time':hex(2000)}])
        self.assertEqual(rpc.state['nonce'],13000)

    def test_calibrate_regular_step_measures_receipt_gas_used_with_13_over_10(self):
        p = ex.build_plan(pin())
        step = p['steps'][1]
        step['tx']['nonce'] = hex(13000)
        rpc = GasFork(100000,130000,110000)
        ex.measure_step(Mock(return_value=hex(120000)),rpc,p,step,{},2000,True)
        self.assertEqual(step['tx']['gas'],hex(169000))
        self.assertEqual([step[k] for k in ('estimateGas','localEstimateGas','forkGasUsed')],[120000,110000,130000])
        self.assertIsNone(step['minedGasMinimum'])
        self.assertFalse(step['rrRequired'])
        self.assertIsNone(step['rrWitness'])

    def test_frozen_replay_rechecks_mined_minimum_even_if_estimate_is_low(self):
        p = ex.build_plan(pin())
        step = p['steps'][0]
        rpc = GasFork(20000000,18000000,90000)
        remote = Mock(return_value=hex(100000))
        ex.measure_step(remote,rpc,p,step,{},2000,True)
        rpc.minimum = 28000000
        self.assertLess(int(step['tx']['gas'],16),rpc.minimum)
        self.fails('replay_minedGasMinimum',ex.measure_step,remote,rpc,p,step,{},2000,False)
        self.assertEqual(rpc.state['nonce'],13000)

    def test_frozen_replay_rechecks_both_estimates(self):
        p = ex.build_plan(pin())
        step = p['steps'][0]
        rpc = GasFork(20000000,18000000,90000)
        remote = Mock(return_value=hex(100000))
        ex.measure_step(remote,rpc,p,step,{},2000,True)
        remote.return_value = hex(100001)
        self.fails('replay_estimateGas',ex.measure_step,remote,rpc,p,step,{},2000,False)
        remote.return_value = hex(100000)
        rpc.estimate = 90001
        self.fails('replay_localEstimateGas',ex.measure_step,remote,rpc,p,step,{},2000,False)

    def test_unmeasured_plan_has_no_invented_gas_limits(self):
        p = ex.build_plan(pin())
        self.assertNotIn('budgetsWei',p)
        for step in p['steps']:
            self.assertNotIn('gas',step['tx'])
        ex.validate_plan(p,frozen=False)
        with self.assertRaises(a.Gate): ex.validate_plan(p,frozen=True)

    def test_frozen_plan_gas_fields_are_exact_and_recomputed(self):
        p = self.plan()
        p['steps'][1]['tx']['gas'] = hex(143001)
        self.fails('measured_gas_limit',ex.validate_plan,p)

    def test_measurement_booleans_are_not_gas_numbers(self):
        p = self.plan()
        p['steps'][1]['forkGasUsed'] = True
        self.fails('measurement_forkGasUsed',ex.validate_plan,p)


    def test_frozen_measurement_replay_does_not_rewrite_plan(self):
        p = ex.build_plan(pin())
        rpc = GasFork(20000000,18000000,90000)
        remote = Mock(return_value=hex(100000))
        ex.measure_step(remote,rpc,p,p['steps'][0],{},2000,True)
        before = copy.deepcopy(p)
        ex.measure_step(remote,rpc,p,p['steps'][0],{},2000,False)
        self.assertEqual(p,before)

    def test_rr_budget_uses_measured_limit_instead_of_old_15m(self):
        p = self.plan()
        p['steps'][0] = self.rr_step()
        ex.budget(p)
        expected = sum(int(s['tx']['gas'],16)*a.MAX_FEE for s in p['steps'] if s['tx']['from'] == ex.DEPLOYER)
        self.assertEqual(p['budgetsWei']['deployer'],expected)
        p['pin']['senders']['deployer']['balance'] = expected-1
        self.fails('budget_deployer',ex.budget,p)

    def test_probe_non_create_above_cap_never_sends(self):
        rpc = GasFork()
        self.fails('gas_cap',ex.probe,rpc,self.plan()['steps'][1]['tx'],a.GAS_CAP+1,2000)
        self.assertEqual(rpc.requests,[])

    def test_rr_witness_requires_first_struct_log(self):
        rpc = Mock(return_value={'structLogs':[]})
        self.fails('rr_struct_logs',ex.reservoir_witness,rpc,self.rr_step()['tx'],{'status':'0x1','transactionHash':HASH})

    def test_upgrade_replay_stops_before_persisting_create_if_minimum_has_increased(self):
        p = self.plan()
        p['steps'][0] = self.rr_step()
        p['steps'][0]['executionTimestamp'] = 1001
        ex.budget(p)
        rpc = GasFork(28000000,18000000,100000)
        rpc.engine_process = object()
        remote = Mock(return_value=hex(100000))
        with tempfile.TemporaryDirectory() as d, contextlib.ExitStack() as stack:
            stack.enter_context(patch.object(ex,'mint_control',return_value={'control':'safeMint_positive','calldata':'0x1234'}))
            stack.enter_context(patch.object(ex,'pre_send',side_effect=lambda step,*args,**kwargs:step['tx']))
            stack.enter_context(patch.object(a,'process_alive'))
            stack.enter_context(patch.object(a,'block_data',return_value={'number':BLOCK,'timestamp':hex(1000)}))
            traces = stack.enter_context(patch.object(a,'trace_overrides'))
            self.fails('replay_minedGasMinimum',ex.run_upgrade,rpc,p,Path(d),remote,False)
            self.assertEqual(rpc.state['nonce'],13000)
            self.assertFalse((Path(d)/'upgrade-simulate.json').exists())
            traces.assert_not_called()


def mutation_test(change):
    def test(self):
        p = self.plan()
        change(p)
        with self.assertRaises(a.Gate):
            ex.validate_plan(p)
    return test


MUTATIONS = {
    'unknown_plan_key': lambda p: p.update(unknown=True),
    'schema_bool': lambda p: p.update(schema=True),
    'route': lambda p: p.update(route='EOA-first'),
    'new_impl': lambda p: p.update(implementation=HOLDER),
    'extension': lambda p: p.update(extension=HOLDER),
    'unknown_step_key': lambda p: p['steps'][0].update(unknown=True),
    'unknown_tx_key': lambda p: p['steps'][0]['tx'].update(authorizationList=[]),
    'wrong_sender_nonce': lambda p: p['steps'][1]['tx'].update(nonce='0x1'),
    'wrong_safe_nonce': lambda p: p['steps'][-1].update(safeNonce=999),
    'unsafe_gas_tuple': lambda p: p.update(gasParams=[200000, 160000, 5000, 175000]),
    'wrong_predecessor': lambda p: p['operations']['activation'].update(predecessor=a.ZERO32),
    'wrong_salt': lambda p: p['operations']['upgrade'].update(salt=a.ZERO32),
    'missing_pause_step': lambda p: p['steps'].pop(2),
    'skip_control': lambda p: p['controls'].pop(),
    'budget_forgery': lambda p: p['budgetsWei'].update(deployer=1),
    'runtime_forgery': lambda p: p['rebuild']['contracts']['SuperPaymaster']['runtime'].update(artifactRuntime='0xdead'),
    'owner_drift': lambda p: p['pin'].update(registryOwner=HOLDER),
    'missing_union_member': lambda p: p['pin']['pauseList'].pop(),
    'module': lambda p: p['pin']['safe']['modules'].append(HOLDER),
    'guard': lambda p: p['pin']['safe'].update(guard=HASH),
    'deployer_delegation': lambda p: p['pin']['safe']['codes'].update({ex.DEPLOYER: '0xef0100'+HOLDER[2:]}),
    'pending_operation': lambda p: p['pin']['pendingOperations'].append({'id': HASH}),
    'float_nonce': lambda p: p['pin']['senders']['deployer'].update(nonce=13000.0),
    'boolean_timestamp': lambda p: p['pin'].update(timestamp=True),
    'float_safe_nonce': lambda p: p['pin'].update(safeNonce=17.0),
    'role_config_owner': lambda p: p['pin'].update(roleConfig=cfg(owner=HOLDER)),
    'inactive_at_start': lambda p: p['pin'].update(roleConfig=cfg(False)),
    'unknown_pin_key': lambda p: p['pin'].update(extra=True),
    'unknown_sender_key': lambda p: p['pin']['senders']['deployer'].update(extra=True),
}
for name, change in MUTATIONS.items():
    setattr(ExecutorTests, 'test_reject_'+name, mutation_test(change))


if __name__ == '__main__':
    unittest.main(verbosity=2)
