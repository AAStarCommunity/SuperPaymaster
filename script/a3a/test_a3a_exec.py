#!/usr/bin/env python3
"""Offline JSON-RPC adversarial controls; no archive connection or local listener needed."""
import contextlib
import copy
import hashlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
import a3a_exec as ex

PACKET = json.loads(ex.PACKET.read_text())
SNAPSHOT = json.loads((ex.PACKET.parent/'snapshot.json').read_text())['snapshot']
BLOCK = hex(11969744)


def abi_word(value):
    number = int(value, 16) if isinstance(value, str) and value.startswith("0x") else int(value)
    return "0x" + format(number, "064x")


def immutable_fixture():
    names = sorted(ex.EIP712_IMMUTABLES)
    runtime = '0x60' + '00'*(8*32) + '00'
    refs = {str(241548+i): [{'start': 1+i*32, 'length': 32}] for i in range(7)}
    # The same ID occurs twice; both copies must be validated.
    refs['241548'].append({'start': 225, 'length': 32})
    artifact = dict(bytecode={'object': '0x60006000f3'},
                    deployedBytecode={'object': runtime, 'immutableReferences': refs})
    nodes = [dict(nodeType='VariableDeclaration', stateVariable=True, mutability='immutable',
                  id=241548+i, name=name) for i, name in enumerate(names)]
    output = dict(contracts={'contracts/src/tokens/APNTsCapped.sol': {
        'APNTsCapped': {'evm': {'deployedBytecode': artifact['deployedBytecode']}}}},
        sources={'OZ/EIP712.sol': {'ast': {'nodes': nodes}},
                 'contracts/src/tokens/APNTsCapped.sol': {'ast': {'nodes': []}}})
    return artifact, {'output': output}


def fixture_identity():
    artifact, info = immutable_fixture()
    with tempfile.TemporaryDirectory() as d:
        (Path(d)/'build.json').write_text(json.dumps(info))
        return ex.immutable_identity(artifact, Path(d))


def mock_hash_rpc(method, params):
    if method != 'web3_sha3':
        raise AssertionError('unexpected hash RPC '+method)
    return ex.keccak(params[0])  # offline oracle; no URL is opened


def runtime_plan():
    return dict(chainId=ex.CHAIN, pin={'capped': '0x'+'34'*20},
                constructorArgs=['AAStar PNTs', 'aPNTs', 10_000_000*10**18,
                                 ex.DEPLOYER, ex.SAFE, ex.SAFE],
                runtimeIdentity=fixture_identity())


def deployed_runtime(plan):
    values, _ = ex.immutable_values(mock_hash_rpc, plan)
    code = bytearray.fromhex(plan['runtimeIdentity']['artifactRuntime'][2:])
    for entry in plan['runtimeIdentity']['ranges']:
        code[entry['start']:entry['start']+32] = values[entry['name']]
    return '0x'+code.hex()

RELAY_URL = 'http://127.0.0.1:65000'


class FakeChain:
    """Deterministic offline EVM boundary; the real executor orchestration stays in use."""
    def __init__(self, pin):
        self.plan = ex.build_plan(pin)
        self.pin = pin
        self.state = dict(head=int(pin['block'], 16), time=pin['timestamp'], next=None,
                          nonces={v['address']: v['nonce'] for v in pin['senders'].values()},
                          safe=pin['safeNonce'], deployed=set((ex.SP, ex.SAFE)),
                          pending=pin['sp']['pendingAPNTsToken'], pendingEta=pin['sp']['pendingAPNTsTokenEta'],
                          tokenOwner=ex.DEPLOYER, pendingOwner=ex.ZERO, approved=set(), eta=0, done=False,
                          receipts={}, txs={}, blocks={}, logs=[], deployBlocks={})
        self.snapshots = {}
        self.sent = []
        self.count = 0
        self.selectors = {ex.calldata(sig): sig for sig in (
            'nonce()', 'owner()', 'pendingOwner()', 'APNTS_TOKEN()', 'pendingAPNTsToken()',
            'pendingAPNTsTokenEta()', 'APNTS_TOKEN_TIMELOCK()', 'getMinDelay()', 'cap()',
            'totalSupply()', 'minter()', 'capGuardian()')}
        self.state['blocks'][pin['block']] = self.block()

    def block(self):
        s = self.state
        return dict(number=hex(s['head']), timestamp=hex(s['time']), hash=self.pin['blockHash'], transactions=[])

    def mine(self):
        s = self.state
        s['head'] += 1
        s['time'] = s['next'] if s['next'] is not None else s['time']+1
        s['next'] = None
        s['blocks'][hex(s['head'])] = self.block()

    def __call__(self, method, params, error_ok=False):
        s = self.state
        if method == 'eth_chainId': return hex(ex.CHAIN)
        if method == 'web3_clientVersion': return 'anvil/'+ex.COMMIT
        if method == 'anvil_nodeInfo':
            return dict(hardFork='Amsterdam', transactionOrder='fifo', environment=dict(chainId=ex.CHAIN),
                        forkConfig=dict(forkUrl=RELAY_URL, forkBlockNumber=int(self.pin['block'], 16)))
        if method == 'eth_config':
            return dict(current=dict(activationTime=ex.ACTIVATION, forkId=ex.FORK_ID), next=None)
        if method == 'web3_sha3': return mock_hash_rpc(method, params)
        if method == 'eth_getTransactionCount': return hex(s['nonces'][params[0]])
        if method == 'eth_getBalance': return hex(10**20)
        if method == 'eth_estimateGas': return hex(200000)
        if method == 'eth_getCode':
            target, block = params
            if target in (self.pin['timelock'], self.pin['capped']) and block != 'latest' and int(block, 16) < s['deployBlocks'].get(target, 10**20):
                return '0x'
            if target not in s['deployed']: return '0x'
            return deployed_runtime(self.plan) if target == self.pin['capped'] else '0x6000'
        if method == 'eth_getBlockByNumber': return self.block() if params[0] == 'latest' else s['blocks'][params[0]]
        if method == 'eth_getLogs': return copy.deepcopy(s['logs'])
        if method == 'evm_snapshot':
            key = str(len(self.snapshots)+1)
            self.snapshots[key] = copy.deepcopy(s)
            return key
        if method == 'evm_revert':
            self.state = copy.deepcopy(self.snapshots[params[0]])
            return True
        if method == 'evm_setNextBlockTimestamp': s['next'] = params[0]; return None
        if method == 'evm_mine': self.mine(); return '0x0'
        if method == 'anvil_setStorageAt': s['safe'] = int(params[2], 16); return True
        if method == 'eth_sendTransaction':
            tx = copy.deepcopy(params[0])
            assert int(tx['nonce'], 16) == s['nonces'][tx['from']]
            step = next(x for x in self.plan['steps'] if x['tx']['data'] == tx['data'])
            sid = step['id']
            reason = None
            if sid == 'S5b' and s['safe'] != self.pin['safeNonce']: reason = ex.error_string('GS025')
            if sid == 'S6b' and s['time'] < s['eta']: reason = ex.error_string('GS013')
            if sid == 'S7' and tx['from'] != ex.DEPLOYER:
                reason = ex.calldata('OwnableUnauthorizedAccount(address)', tx['from'])
            self.sent.append((sid, tx['gas'], reason is not None))
            self.mine()
            s['nonces'][tx['from']] += 1
            logs = []
            if reason is None:
                if sid == 'S1': s['pending'], s['pendingEta'] = ex.ZERO, 0
                if sid == 'S2':
                    s['deployed'].add(self.pin['timelock'])
                    s['deployBlocks'][self.pin['timelock']] = s['head']
                    for i, name in enumerate(('DEFAULT_ADMIN', 'PROPOSER', 'EXECUTOR', 'CANCELLER')):
                        role = ex.ZERO32 if name == 'DEFAULT_ADMIN' else ex.keccak(name+'_ROLE')
                        account = self.pin['timelock'] if name == 'DEFAULT_ADMIN' else ex.SAFE
                        s['logs'].append(dict(address=self.pin['timelock'], blockNumber=hex(s['head']),
                            transactionIndex='0x0', logIndex=hex(i),
                            topics=[ex.keccak('RoleGranted(bytes32,address,address)'), role, abi_word(account), abi_word(ex.DEPLOYER)]))
                if sid == 'S3':
                    s['deployed'].add(self.pin['capped'])
                    s['deployBlocks'][self.pin['capped']] = s['head']
                if sid == 'S4': s['pendingOwner'] = self.pin['timelock']
                if sid in ('S5a', 'S6a'): s['approved'].add(self.plan['safeTxHashes'][0 if sid == 'S5a' else 1])
                if sid in ('S5b', 'S6b'):
                    s['safe'] += 1
                    logs = [dict(address=ex.SAFE, topics=[ex.keccak('ExecutionSuccess(bytes32,uint256)'),
                            self.plan['safeTxHashes'][0 if sid == 'S5b' else 1]], data='0x')]
                if sid == 'S5b': s['eta'] = s['time']+172800
                if sid == 'S6b': s['tokenOwner'], s['pendingOwner'], s['done'] = self.pin['timelock'], ex.ZERO, True
                if sid == 'S7': s['pending'], s['pendingEta'] = self.pin['capped'], s['time']+self.pin['sp']['APNTS_TOKEN_TIMELOCK']
            self.count += 1
            h = abi_word(self.count)
            s['txs'][h] = dict(tx, input=tx['data'])
            s['receipts'][h] = dict(transactionHash=h, blockNumber=hex(s['head']), gasUsed=hex(110000),
                status='0x0' if reason else '0x1', logs=logs,
                contractAddress=self.pin['timelock'] if sid == 'S2' else self.pin['capped'] if sid == 'S3' else None,
                revertOutput=reason)
            return h
        if method == 'eth_getTransactionReceipt': return s['receipts'][params[0]]
        if method == 'eth_getTransactionByHash': return s['txs'][params[0]]
        if method == 'debug_traceTransaction':
            return {'pre': {}, 'post': {}} if params[1]['tracer'] == 'prestateTracer' else {'output': s['receipts'][params[0]]['revertOutput']}
        if method == 'eth_call':
            target, data = params[0]['to'], params[0]['data']
            if data.startswith(ex.calldata('getRoleAdmin(bytes32)', ex.ZERO32)[:10]): return abi_word(0)
            if data.startswith(ex.calldata('approvedHashes(address,bytes32)', ex.APPROVER, ex.ZERO32)[:10]):
                return abi_word(int('0x'+data[-64:] in s['approved']))
            if data.startswith(ex.calldata('getOperationState(bytes32)', ex.ZERO32)[:10]):
                return abi_word(3 if s['done'] else 0 if not s['eta'] else 2 if s['time'] >= s['eta'] else 1)
            if data.startswith(ex.calldata('getTimestamp(bytes32)', ex.ZERO32)[:10]): return abi_word(1 if s['done'] else s['eta'])
            sig = self.selectors[data]
            if sig == 'owner()': return abi_word(ex.DEPLOYER if target == ex.SP else s['tokenOwner'])
            values = {'nonce()': s['safe'], 'pendingOwner()': s['pendingOwner'],
                'APNTS_TOKEN()': self.pin['sp']['APNTS_TOKEN'], 'pendingAPNTsToken()': s['pending'],
                'pendingAPNTsTokenEta()': s['pendingEta'], 'APNTS_TOKEN_TIMELOCK()': self.pin['sp']['APNTS_TOKEN_TIMELOCK'],
                'getMinDelay()': 172800, 'cap()': 10_000_000*10**18, 'totalSupply()': 0,
                'minter()': ex.SAFE, 'capGuardian()': ex.SAFE}
            return abi_word(values[sig])
        raise AssertionError('unexpected local RPC '+method)


@contextlib.contextmanager
def fake_fork(remote, pin, out):
    (out/'relay.log').write_text('')
    (out/'simulate.log').write_text('offline engine boundary\n')
    chain = FakeChain(pin)
    ex.authenticate_engine(chain, RELAY_URL, pin['block'])
    yield chain


class ExecutorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.selectors = {ex.calldata(sig): sig for sig in (
            'nonce()', 'getOwners()', 'getThreshold()', 'owner()', 'APNTS_TOKEN()',
            'pendingAPNTsToken()', 'pendingAPNTsTokenEta()', 'APNTS_TOKEN_TIMELOCK()')}

    def mock_urlopen(self, case):
        def urlopen(request, timeout=None):
            q = json.loads(request.data)
            m, p = q['method'], q['params']
            r = dict(jsonrpc='2.0', id=q['id'])
            if case == 'envelope':
                return io.BytesIO(json.dumps(dict(jsonrpc='2.0', id=True, result='0x1')).encode())
            if m == 'web3_sha3':
                v = mock_hash_rpc(m, p)
            elif m == 'eth_chainId':
                v = '0x1' if case == 'chain' else hex(ex.CHAIN)
            elif m == 'eth_config':
                if case == 'missing':
                    r['error'] = dict(code=-32601, message='method not found')
                    return io.BytesIO(json.dumps(r).encode())
                v = dict(current=dict(activationTime=ex.ACTIVATION, forkId=ex.FORK_ID), next=None)
                if case == 'next': v['next'] = {'activationTime': ex.ACTIVATION+100}
                if case == 'activation':
                    v['current']['activationTime'] += 1
                if case == 'fork':
                    v['current']['forkId'] = '0x00000000'
            elif m == 'eth_getBlockByNumber':
                v = dict(number=p[0], hash='0x'+'ab'*32, timestamp=hex(ex.ACTIVATION+1))
            elif m == 'eth_getTransactionCount':
                base = {ex.DEPLOYER: 12131, ex.APPROVER: 7, ex.EXECUTOR: 28}[p[0]]
                v = hex(base+1 if case == 'nonce' and p[1] == 'pending' else base)
                if case in ('approver_nonce', 'executor_nonce') and p[0] == ex.SENDERS[case[:-6]] and p[1] == 'pending':
                    v = hex(base+1)
            elif m == 'eth_getCode':
                v = '0x6000' if case == 'code' else '0x'
            elif m == 'eth_getBalance':
                v = '0x0' if case == 'balance' else hex(10**20)
            elif m == 'eth_estimateGas':
                v = hex(100000)
            elif m == 'eth_call':
                if p[0]['data'].startswith(ex.calldata('getTransactionHash(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,uint256)', ex.ZERO, 0, '0x', 0, 0, 0, 0, ex.ZERO, ex.ZERO, 0)[:10]):
                    safe_nonce = int(p[0]['data'][10+9*64:10+10*64], 16)
                    v = PACKET['simulatedAddresses']['safeTxHashS5' if safe_nonce == 1 else 'safeTxHashS6']
                    if case == 'safe_hash': v = ex.ZERO32
                    r['result'] = v
                    return io.BytesIO(json.dumps(r).encode())
                sig = self.selectors[p[0]['data']]
                if sig == 'nonce()':
                    v = abi_word(1)
                elif sig == 'getThreshold()':
                    v = abi_word(3 if case == 'threshold' else 2)
                elif sig == 'getOwners()':
                    owners = SNAPSHOT['multisig']['owners']
                    if case == 'owners':
                        owners = [ex.ZERO]*3
                    v = '0x'+abi_word(32)[2:]+abi_word(3)[2:]+''.join(abi_word(x)[2:] for x in owners)
                else:
                    v = abi_word(SNAPSHOT['sp'][sig[:-2]])
            else:
                self.fail('unexpected RPC method: '+m)
            r['result'] = v
            return io.BytesIO(json.dumps(r).encode())
        return urlopen

    @staticmethod
    def artifact(name):
        # Build artifacts are a separate local boundary. The positive plan test uses
        # tiny deterministic bytecode rather than invoking a compiler or downloading solc.
        a = dict(bytecode={'object': '0x60006000f3'}, deployedBytecode={'object': '0x00'})
        if name == 'APNTsCapped':
            a, _ = immutable_fixture()
            a['runtimeIdentity'] = fixture_identity()
        return a

    def run_plan(self, case='valid'):
        with tempfile.TemporaryDirectory() as d:
            out = Path(d)/'output'
            rpc_file = Path(d)/'rpc'
            rpc_file.write_text('https://secret.invalid/NEVER_PRINT_THIS')
            stdout, stderr = io.StringIO(), io.StringIO()
            with patch.object(ex.urllib.request, 'urlopen', self.mock_urlopen(case)), \
                    patch.object(ex, 'artifact', self.artifact), \
                    patch.object(ex, 'fork', fake_fork), \
                    contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                code = ex.main(['plan', '--rpc-file', str(rpc_file), '--block', BLOCK, '--out', str(out)])
            failure = json.loads((out/'FAILURE.json').read_text()) if (out/'FAILURE.json').exists() else None
            self.assertNotIn('NEVER_PRINT_THIS', stdout.getvalue()+stderr.getvalue()+str(failure))
            if code == 0:
                raw_plan = (out/'plan.json').read_text()
                self.assertNotIn('https://', raw_plan)
                self.assertNotIn('NEVER_PRINT_THIS', raw_plan)
                p = ex.load_plan(out/'plan.json')
                self.assertEqual([x['tx']['gas'] for x in p['steps']], [hex(260000)]*9)
                self.assertEqual([x['localEstimateGas'] for x in p['steps']], [200000]*9)
                result = json.loads((out/'simulate.json').read_text())
                self.assertEqual(result['status'], 'PASS')
                ex.completion(result['steps'], result['negativeControls'])
                self.assertEqual(len(p['steps']), 9)
                self.assertEqual(p['roles']['DEFAULT_ADMIN'], [p['pin']['timelock']])
                self.assertEqual(p['pin']['timelock'], PACKET['simulatedAddresses']['newTimelock'].lower())
                self.assertEqual(p['pin']['capped'], PACKET['simulatedAddresses']['apntsCapped'].lower())
                self.assertEqual(p['safeTxHashes'], [PACKET['simulatedAddresses']['safeTxHashS5'], PACKET['simulatedAddresses']['safeTxHashS6']])
                self.assertEqual(p['operationId'], PACKET['simulatedAddresses']['acceptOperationId'])
                for s, reference in zip(p['steps'], PACKET['steps']):
                    if s['id'] not in ('S2', 'S3'):
                        self.assertEqual(s['tx']['data'], reference['calldata'])
                return code, None
            self.assertFalse((out/'plan.json').exists())
            self.assertEqual(failure['status'], 'FAILURE')
            self.assertIn('observed', failure)
            self.assertIn('expected', failure)
            return code, failure['gate']

    def test_valid_plan(self):
        self.assertEqual(self.run_plan(), (0, None))

    def test_distinct_preflight_gates(self):
        cases = {'chain': 'chain_id', 'missing': 'fork_config_missing',
                 'activation': 'fork_activation', 'fork': 'fork_id',
                 'nonce': 'deployer_nonce_pending', 'code': 'create_address_empty',
                 'balance': 'deployer_budget', 'envelope': 'rpc_envelope',
                 'threshold': 'safe_threshold', 'owners': 'safe_owners', 'next': 'fork_next',
                 'approver_nonce': 'approver_nonce_pending', 'executor_nonce': 'executor_nonce_pending',
                 'safe_hash': 'safe_hash_5'}
        self.assertEqual(len(set(cases.values())), len(cases))
        for case, gate in cases.items():
            with self.subTest(case=case):
                self.assertEqual(self.run_plan(case), (1, gate))

    def test_tampered_plan_cli(self):
        with tempfile.TemporaryDirectory() as d:
            path, out = Path(d)/'plan.json', Path(d)/'out'
            path.write_text('{}')
            path.with_name('plan.json.sha256').write_text(hashlib.sha256(path.read_bytes()).hexdigest())
            path.write_text('{"tampered":true}')
            with patch.object(ex.urllib.request, 'urlopen', side_effect=AssertionError('no RPC before hash gate')), \
                    contextlib.redirect_stderr(io.StringIO()):
                code = ex.main(['simulate', '--rpc-file', '/unused', '--plan', str(path), '--out', str(out)])
            self.assertEqual(code, 1)
            self.assertEqual(json.loads((out/'FAILURE.json').read_text())['gate'], 'plan_hash')

    def test_sign_send_refuse(self):
        for command in ('sign', 'send'):
            with self.subTest(command=command), tempfile.TemporaryDirectory() as d:
                stderr = io.StringIO()
                with patch.object(ex.urllib.request, 'urlopen', side_effect=AssertionError('no RPC')), \
                        patch.object(ex.subprocess, 'run', side_effect=AssertionError('no signer')), \
                        contextlib.redirect_stderr(stderr):
                    self.assertEqual(ex.main([command, '--out', d]), 3)
                self.assertEqual(stderr.getvalue().strip(), ex.REFUSAL)
                self.assertEqual(json.loads((Path(d)/'FAILURE.json').read_text())['gate'], command+'_disabled')

    def test_archive_refuses_mutations(self):
        with patch.object(ex.urllib.request, 'urlopen', side_effect=AssertionError('must not connect')):
            for method in ('eth_sendTransaction', 'eth_sendRawTransaction', 'anvil_setBalance'):
                with self.assertRaises(ex.Gate) as caught:
                    ex.RPC('https://unused')(method, [])
                self.assertEqual(caught.exception.record['gate'], 'remote_read_only')

    def test_exact_admin_set(self):
        tl = PACKET['simulatedAddresses']['newTimelock'].lower()
        ids = {'DEFAULT_ADMIN': ex.ZERO32, **{x: ex.keccak(x+'_ROLE') for x in ('PROPOSER', 'EXECUTOR', 'CANCELLER')}}
        granted = ex.keccak('RoleGranted(bytes32,address,address)')
        logs = [dict(address=tl, blockNumber='0x2', transactionIndex='0x0', logIndex=hex(i),
                     topics=[granted, role, abi_word(tl if name == 'DEFAULT_ADMIN' else ex.SAFE), abi_word(ex.DEPLOYER)])
                for i, (name, role) in enumerate(ids.items())]
        plan = dict(pin={'timelock': tl}, roles={x: [tl if x == 'DEFAULT_ADMIN' else ex.SAFE] for x in ids})
        def rpc(method, params):
            return '0x' if method == 'eth_getCode' else logs
        with patch.object(ex, 'word', return_value=0):
            self.assertEqual(ex.roles_readback(rpc, plan, '0x2'), plan['roles'])
        logs.append(dict(logs[0], logIndex='0x4', topics=[granted, ex.ZERO32, abi_word(ex.DEPLOYER), abi_word(ex.DEPLOYER)]))
        with patch.object(ex, 'word', return_value=0), self.assertRaises(ex.Gate) as caught:
            ex.roles_readback(rpc, plan, '0x2')
        self.assertEqual(caught.exception.record['gate'], 'timelock_role_sets')

    def test_s7_eta_uses_contract_delay(self):
        tl, token = '0x'+'12'*20, '0x'+'34'*20
        pin = dict(timelock=tl, capped=token, sp={'APNTS_TOKEN': ex.ZERO, 'APNTS_TOKEN_TIMELOCK': 12345})
        plan = runtime_plan()
        plan.update(pin=pin, operationId=ex.ZERO32)
        code = deployed_runtime(plan)
        values = {'cap()': 10_000_000*10**18, 'totalSupply()': 0,
                  'getOperationState(bytes32)': 3, 'getTimestamp(bytes32)': 1,
                  'APNTS_TOKEN_TIMELOCK()': 12345, 'pendingAPNTsTokenEta()': 100+12345}
        def word(rpc, target, sig, *args, **kwargs):
            return values[sig]
        def address(rpc, target, sig, *args):
            if target == ex.SP:
                return token if sig == 'pendingAPNTsToken()' else ex.ZERO
            return {'minter()': ex.SAFE, 'capGuardian()': ex.SAFE,
                    'owner()': tl, 'pendingOwner()': ex.ZERO}[sig]
        with patch.object(ex, 'word', word), patch.object(ex, 'address', address), \
                patch.object(ex, 'block_data', return_value={'timestamp': '0x64'}):
            result = ex.readback(lambda m, p: code if m == 'eth_getCode' else mock_hash_rpc(m, p), plan, {'id': 'S7'},
                                 {'blockNumber': '0x1'}, {'eta': 99})
            self.assertEqual(result['spDelay'], 12345)
            values['pendingAPNTsTokenEta()'] += 1
            with self.assertRaises(ex.Gate) as caught:
                ex.readback(lambda m, p: code if m == 'eth_getCode' else mock_hash_rpc(m, p), plan, {'id': 'S7'},
                            {'blockNumber': '0x1'}, {'eta': 99})
            self.assertEqual(caught.exception.record['gate'], 'S7_eta_relation')

    def test_storage_diff_preserves_cleared_slots_and_prior_changes(self):
        a, first, second = '0x'+'ab'*20, ex.ZERO32, '0x'+'01'*32
        overrides = {a: {'stateDiff': {second: '0x'+'02'*32}}}
        diff = {'pre': {a: {'storage': {first: '0x'+'03'*32}}},
                'post': {a: {'nonce': 5, 'balance': '0x10'}}}
        result = ex.trace_overrides(lambda *_: diff, {'transactionHash': ex.ZERO32}, overrides)
        self.assertEqual(result[a]['stateDiff'], {first: ex.ZERO32, second: '0x'+'02'*32})
        self.assertEqual(result[a]['nonce'], '0x5')
        self.assertEqual(result[a]['balance'], '0x10')

    def test_final_budget_uses_planned_limits_and_fee_caps(self):
        plan = {'pin': {'senders': {label: {'balance': 100} for label in ex.SENDERS}}, 'steps': [
            {'tx': {'from': ex.DEPLOYER, 'gas': '0xa', 'maxFeePerGas': '0xb'}},
            {'tx': {'from': ex.EXECUTOR, 'gas': '0xff', 'maxFeePerGas': '0xff'}}]}
        with self.assertRaises(ex.Gate) as caught:
            ex.budget(plan)
        self.assertEqual(caught.exception.record['gate'], 'deployer_budget')
        plan['pin']['senders']['deployer']['balance'] = 110
        plan['pin']['senders']['executor']['balance'] = 10**10
        ex.budget(plan)
        self.assertEqual(plan['budgetWei'], 110)

    def test_immutable_unknown_id(self):
        a, info = immutable_fixture()
        refs = a['deployedBytecode']['immutableReferences']
        refs['999999'] = refs.pop('241548')
        with tempfile.TemporaryDirectory() as d:
            (Path(d)/'build.json').write_text(json.dumps(info))
            with self.assertRaises(ex.Gate) as caught:
                ex.immutable_identity(a, Path(d))
        self.assertEqual(caught.exception.record['gate'], 'immutable_unknown_id')

    def test_immutable_wrong_cached_this(self):
        plan = runtime_plan()
        code = bytearray.fromhex(deployed_runtime(plan)[2:])
        entry = next(e for e in plan['runtimeIdentity']['ranges'] if e['name'] == '_cachedThis')
        code[entry['start']+31] ^= 1
        with self.assertRaises(ex.Gate) as caught:
            ex.verify_runtime(mock_hash_rpc, plan, '0x'+code.hex())
        self.assertEqual(caught.exception.record['gate'], 'immutable_value__cachedThis')

    def test_runtime_change_outside_masks(self):
        plan = runtime_plan()
        code = bytearray.fromhex(deployed_runtime(plan)[2:])
        code[0] ^= 1
        with self.assertRaises(ex.Gate) as caught:
            ex.verify_runtime(mock_hash_rpc, plan, '0x'+code.hex())
        self.assertEqual(caught.exception.record['gate'], 'runtime_unmasked_bytes')

    def test_immutable_runtime_positive(self):
        plan = runtime_plan()
        result = ex.verify_runtime(mock_hash_rpc, plan, deployed_runtime(plan))
        self.assertTrue(result['unmaskedBytesEqual'])
        self.assertEqual(set(result['immutables']), ex.EIP712_IMMUTABLES)
        self.assertEqual(result['shortStringCases'], {'_name': 'inline', '_version': 'inline'})
        # Independent known Keccak and ShortString expectations.
        self.assertEqual(mock_hash_rpc('web3_sha3', ['0x']), ex.EMPTY_KECCAK)
        self.assertEqual(result['immutables']['_cachedChainId'][0]['value'], abi_word(ex.CHAIN))
        self.assertEqual(result['immutables']['_cachedThis'][0]['value'], abi_word(plan['pin']['capped']))
        self.assertEqual(result['immutables']['_name'][0]['value'],
                         '0x41415374617220504e5473' + '00'*20 + '0b')
        # Cross-check the domain hash against a separate ABI encoder.
        name_hash, version_hash = ex.keccak('AAStar PNTs'), ex.keccak('1')
        type_hash = ex.keccak('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)')
        domain = ex.keccak(ex.cast('abi-encode', 'c(bytes32,bytes32,bytes32,uint256,address)',
                                  type_hash, name_hash, version_hash, ex.CHAIN, plan['pin']['capped']))
        self.assertEqual(result['immutables']['_cachedDomainSeparator'][0]['value'], domain)

    def test_repeated_immutable_offset_checked(self):
        plan = runtime_plan()
        code = bytearray.fromhex(deployed_runtime(plan)[2:])
        repeated = next(e for e in plan['runtimeIdentity']['ranges'] if e['start'] == 225)
        code[225] ^= 1
        with self.assertRaises(ex.Gate) as caught:
            ex.verify_runtime(mock_hash_rpc, plan, '0x'+code.hex())
        self.assertEqual(caught.exception.record['gate'], 'immutable_value_'+repeated['name'])

    def test_short_string_boundaries_and_fallback(self):
        for text in ('', 'a'*31, 'a'*32, 'é'*16):
            with self.subTest(text=text):
                value, case = ex.short_string(text)
                if len(text.encode()) <= 31:
                    self.assertEqual(case, 'inline')
                    self.assertEqual(value[-1], len(text.encode()))
                    self.assertEqual(value[:len(text.encode())], text.encode())
                else:
                    self.assertEqual(case, 'fallback')
                    self.assertEqual(value, bytes(31)+b'\xff')
        plan = runtime_plan()
        plan['constructorArgs'][0] = 'a'*32
        result = ex.verify_runtime(mock_hash_rpc, plan, deployed_runtime(plan))
        self.assertEqual(result['shortStringCases']['_name'], 'fallback')

    def test_bad_keccak_provider(self):
        with self.assertRaises(ex.Gate) as caught:
            ex.immutable_values(lambda *_: ex.ZERO32, runtime_plan())
        self.assertEqual(caught.exception.record['gate'], 'keccak_vector')

    def test_minimal_build_info_is_insufficient(self):
        a, _ = immutable_fixture()
        with tempfile.TemporaryDirectory() as d:
            (Path(d)/'build.json').write_text(json.dumps({'id': 'minimal', 'source_id_to_path': {}}))
            with self.assertRaises(ex.Gate) as caught:
                ex.immutable_identity(a, Path(d))
        self.assertEqual(caught.exception.record['gate'], 'immutable_build_info')

    def chain_and_plan(self):
        with patch.object(ex.urllib.request, 'urlopen', self.mock_urlopen('valid')):
            pin = ex.preflight(ex.RPC('https://unused'), BLOCK)
        with patch.object(ex, 'artifact', self.artifact):
            chain = FakeChain(pin)
        return chain, chain.plan

    def send_prefix(self, chain, plan, ids):
        for sid in ids:
            tx = dict(next(s['tx'] for s in plan['steps'] if s['id'] == sid), gas=hex(260000))
            ex.receipt(chain, tx)

    def test_pre_send_s4_requires_chain_predecessor_readback(self):
        chain, plan = self.chain_and_plan()
        step = ex.ExecutionStep(plan, 'S4')
        with self.assertRaises(ex.Gate) as caught:
            ex.pre_send(step, chain)
        self.assertEqual(caught.exception.record['gate'], 'pre_send_code_S4')
        self.send_prefix(chain, plan, ('S1', 'S2', 'S3'))
        chain.state['nonces'][ex.DEPLOYER] += 1
        with self.assertRaises(ex.Gate) as caught:
            ex.pre_send(step, chain)
        self.assertEqual(caught.exception.record['gate'], 'pre_send_nonce_S4')
        chain.state['nonces'][ex.DEPLOYER] -= 1
        chain.state['pendingOwner'] = ex.EXECUTOR
        with self.assertRaises(ex.Gate) as caught:
            ex.pre_send(step, chain)
        self.assertEqual(caught.exception.record['gate'], 'S3_pending_owner')
        chain.state['pendingOwner'] = ex.ZERO
        self.assertEqual(ex.pre_send(step, chain), plan['steps'][3]['tx'])
        # Code and a matching nonce alone are insufficient: corrupt the predecessor's supply.
        def corrupt(method, params):
            if method == 'eth_call' and params[0]['data'] == ex.calldata('totalSupply()'):
                return abi_word(1)
            return chain(method, params)
        with self.assertRaises(ex.Gate) as caught:
            ex.pre_send(step, corrupt)
        self.assertEqual(caught.exception.record['gate'], 'S3_totalSupply()')

    def test_pre_send_pending_nonce_and_fresh_gas(self):
        chain, plan = self.chain_and_plan()
        def pending(method, params):
            if method == 'eth_getTransactionCount' and params[1] == 'pending':
                return hex(chain.state['nonces'][params[0]]+1)
            return chain(method, params)
        with self.assertRaises(ex.Gate) as caught:
            ex.pre_send(ex.ExecutionStep(plan, 'S1'), pending)
        self.assertEqual(caught.exception.record['gate'], 'pre_send_pending_S1')
        plan['steps'][0]['tx']['gas'] = hex(100000)
        with self.assertRaises(ex.Gate) as caught:
            ex.pre_send(ex.ExecutionStep(plan, 'S1'), chain)
        self.assertEqual(caught.exception.record['gate'], 'pre_send_gas_S1')

    def test_signing_input_always_uses_pre_send(self):
        chain, plan = self.chain_and_plan()
        with patch.object(ex, 'validate_plan') as validate, patch.object(ex, 'pre_send', side_effect=ex.Gate('sentinel', 0, 1)) as gate:
            with self.assertRaises(ex.Gate) as caught:
                ex.signing_transaction(plan, 'S4', chain)
        self.assertEqual(caught.exception.record['gate'], 'sentinel')
        gate.assert_called_once()
        validate.assert_called_once_with(plan, frozen=True)

    def test_negative_is_mined_and_snapshot_restores_sender_nonce(self):
        chain, plan = self.chain_and_plan()
        self.send_prefix(chain, plan, ('S1', 'S2', 'S3', 'S4', 'S5a'))
        chain.state['safe'] += 1
        tx = plan['steps'][5]['tx']
        before = copy.deepcopy(chain.state)
        result = ex.negative(chain, tx, ex.error_string('GS025'), 'test')
        self.assertEqual(result['receipt']['status'], '0x0')
        self.assertEqual(result['minedNonces'], [before['nonces'][ex.EXECUTOR]+1, before['safe']])
        self.assertEqual(result['restoredNonces'], [before['nonces'][ex.EXECUTOR], before['safe']])
        self.assertEqual(chain.state, before)
        with self.assertRaises(ex.Gate) as caught:
            ex.negative(chain, tx, ex.error_string('GS013'), 'test')
        self.assertEqual(caught.exception.record['gate'], 'negative_test_reason')
        self.assertEqual(chain.state, before)

    def test_completion_rejects_missing_or_reordered_items(self):
        records = [{'step': x} for x in ex.STEP_IDS]
        controls = [{'control': x} for x in ex.CONTROL_IDS]
        ex.completion(records, controls)
        for broken in (records[:-1], list(reversed(records))):
            with self.assertRaises(ex.Gate) as caught:
                ex.completion(broken, controls)
            self.assertEqual(caught.exception.record['gate'], 'completed_steps')
        with self.assertRaises(ex.Gate) as caught:
            ex.completion(records, controls[:-1])
        self.assertEqual(caught.exception.record['gate'], 'completed_controls')

    def test_self_attested_plan_cannot_change_identity(self):
        chain, plan = self.chain_and_plan()
        with patch.object(ex, 'artifact', self.artifact):
            ex.validate_plan(plan)
            for field, value in (('data', '0x00'), ('nonce', '0x1'), ('from', ex.APPROVER), ('to', ex.ZERO), ('value', '0x1')):
                edited = copy.deepcopy(plan)
                edited['steps'][3]['tx'][field] = value
                with self.assertRaises(ex.Gate) as caught:
                    ex.validate_plan(edited)
                self.assertEqual(caught.exception.record['gate'], 'plan_step_S4_'+field)
            plan['steps'].pop()
            with self.assertRaises(ex.Gate) as caught:
                ex.validate_plan(plan)
            self.assertEqual(caught.exception.record['gate'], 'plan_step_ids')

    def test_frozen_simulation_is_independent_and_clears_stale_failure(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            rpc_file, out, sim = root/'rpc', root/'plan-out', root/'sim-out'
            rpc_file.write_text('https://secret.invalid/NEVER_PRINT_THIS')
            with patch.object(ex.urllib.request, 'urlopen', self.mock_urlopen('valid')), \
                    patch.object(ex, 'artifact', self.artifact), patch.object(ex, 'fork', fake_fork):
                self.assertEqual(ex.main(['plan', '--rpc-file', str(rpc_file), '--block', BLOCK, '--out', str(out)]), 0)
                frozen_bytes = (out/'plan.json').read_bytes()
                sim.mkdir()
                (sim/'FAILURE.json').write_text('{}')
                with patch.object(ex, 'plan_command', side_effect=AssertionError('no re-planning')):
                    self.assertEqual(ex.main(['simulate', '--rpc-file', str(rpc_file), '--plan', str(out/'plan.json'), '--out', str(sim)]), 0)
                self.assertEqual((out/'plan.json').read_bytes(), frozen_bytes)
                self.assertFalse((sim/'FAILURE.json').exists())
                result = json.loads((sim/'simulate.json').read_text())
                self.assertEqual(result['status'], 'PASS')
                for r in result['steps']:
                    self.assertLessEqual(r['gasUsed'], 260000)
                edited = json.loads(frozen_bytes)
                edited['steps'][3]['tx']['nonce'] = '0x1'
                ex.write_json(out/'plan.json', edited)
                (out/'plan.json.sha256').write_text(hashlib.sha256((out/'plan.json').read_bytes()).hexdigest())
                with contextlib.redirect_stderr(io.StringIO()):
                    self.assertEqual(ex.main(['simulate', '--rpc-file', str(rpc_file), '--plan', str(out/'plan.json'), '--out', str(sim)]), 1)
                self.assertEqual(json.loads((sim/'FAILURE.json').read_text())['gate'], 'plan_step_S4_nonce')

    def test_relay_batch_refusals_and_pinned_extras(self):
        log = io.StringIO()
        calls = []
        def remote(m, p):
            calls.append(m)
            return '0xaa36a7'
        relay = ex.RelayFilter(remote, {'block': BLOCK}, log)
        methods = ('eth_blockNumber', 'net_version', 'web3_clientVersion', 'eth_chainId',
                   'eth_sendRawTransaction', 'eth_sendTransaction', 'anvil_setBalance')
        results = relay.dispatch([dict(jsonrpc='2.0', id=i, method=m, params=[]) for i, m in enumerate(methods)])
        self.assertEqual([x['id'] for x in results], list(range(7)))
        self.assertEqual([x['result'] for x in results[:3]], [BLOCK, str(ex.CHAIN), 'a3a-relay'])
        self.assertEqual(calls, ['eth_chainId'])
        self.assertTrue(all('error' in x for x in results[4:]))
        self.assertIn('refused anvil_setBalance', log.getvalue())
        with patch.object(relay, 'remote', side_effect=ex.Gate('upstream', 0, 1)):
            self.assertIn('error', relay.one(dict(id=9, method='eth_getCode', params=[])))
        self.assertIn('failed eth_getCode', log.getvalue())

    def test_relay_evidence_whitelist(self):
        with tempfile.TemporaryDirectory() as d:
            out = Path(d)
            for text in ('', 'refused eth_gasPrice\n'):
                (out/'relay.log').write_text(text)
                ex.relay_evidence(out)
            for text in ('failed eth_getCode\n', 'refused eth_sendTransaction\n', 'relay error\n'):
                (out/'relay.log').write_text(text)
                with self.assertRaises(ex.Gate) as caught:
                    ex.relay_evidence(out)
                self.assertEqual(caught.exception.record['gate'], 'relay_evidence')

    def test_local_engine_authentication(self):
        chain, _ = self.chain_and_plan()
        block = chain.pin['block']
        ex.authenticate_engine(chain, RELAY_URL, block)
        good = chain('anvil_nodeInfo', [])
        def variant(**kw):
            info = copy.deepcopy(good)
            for k, v in kw.items():
                if k in ('forkUrl', 'forkBlockNumber'):
                    info['forkConfig'][k] = v
                elif k == 'chainId':
                    info['environment'][k] = v
                else:
                    info[k] = v
            return info
        cases = [(variant(forkUrl='http://127.0.0.1:1'), 'local_engine_fork_url'),
                 (variant(forkBlockNumber=1), 'local_engine_fork_block'),
                 (variant(hardFork='Prague'), 'local_engine_hardfork'),
                 (variant(transactionOrder='fees'), 'local_engine_order'),
                 (variant(chainId=31337), 'local_chain'),
                 ('garbage', 'local_engine_info')]
        for value, gate in cases:
            with self.subTest(gate=gate):
                def wrong(m, p, value=value):
                    return value if m == 'anvil_nodeInfo' else chain(m, p)
                with self.assertRaises(ex.Gate) as caught:
                    ex.authenticate_engine(wrong, RELAY_URL, block)
                self.assertEqual(caught.exception.record['gate'], gate)

    def test_git_clean_gate_excludes_only_output(self):
        from types import SimpleNamespace
        out = ex.ROOT/'docs/release/a3a-test-output'
        with patch.object(ex.subprocess, 'run', return_value=SimpleNamespace(returncode=0, stdout='')) as run:
            header = ex.git_state(out)
        self.assertEqual(header['dirtyCount'], 0)
        self.assertEqual(header['excludedOutput'], str(out))
        self.assertEqual(run.call_args.args[0][-1], ':(exclude,literal)docs/release/a3a-test-output')
        with patch.object(ex.subprocess, 'run', return_value=SimpleNamespace(returncode=0, stdout=' M script/a3a/a3a_exec.py\n')):
            with self.assertRaises(ex.Gate) as caught:
                ex.git_state(out)
        self.assertEqual(caught.exception.record['gate'], 'git_clean')

    def test_interruptions_and_mkdir_failures_record_evidence(self):
        class Stop(BaseException): pass
        for error in (KeyboardInterrupt(), Stop()):
            with tempfile.TemporaryDirectory() as d:
                out = Path(d)/'out'
                with patch.object(ex, 'RPC', side_effect=error), contextlib.redirect_stderr(io.StringIO()):
                    rpc_file = Path(d)/'rpc'; rpc_file.write_text('https://unused')
                    code = ex.main(['plan', '--rpc-file', str(rpc_file), '--block', BLOCK, '--out', str(out)])
                self.assertEqual(code, 1)
                self.assertEqual(json.loads((out/'FAILURE.json').read_text())['gate'], 'interrupted')
        with tempfile.TemporaryDirectory() as d:
            out = Path(d)/'not-a-directory'; out.write_text('existing file')
            stderr = io.StringIO()
            with contextlib.redirect_stderr(stderr):
                code = ex.main(['plan', '--rpc-file', '/unused', '--block', BLOCK, '--out', str(out)])
            self.assertEqual(code, 1)
            self.assertIn('executor_error', stderr.getvalue())

    def test_each_sender_has_its_own_budget(self):
        _, plan = self.chain_and_plan()
        for step in plan['steps']: step['tx']['gas'] = hex(260000)
        for label in ex.SENDERS:
            changed = copy.deepcopy(plan)
            changed['pin']['senders'][label]['balance'] = 0
            with self.assertRaises(ex.Gate) as caught:
                ex.budget(changed)
            self.assertEqual(caught.exception.record['gate'], label+'_budget')

    def test_role_grant_revoke_and_admin_change(self):
        chain, plan = self.chain_and_plan()
        self.send_prefix(chain, plan, ('S1', 'S2'))
        logs = chain.state['logs']
        base = dict(logs[0])
        grant = dict(base, logIndex='0x4', topics=[ex.keccak('RoleGranted(bytes32,address,address)'), ex.ZERO32, abi_word(ex.DEPLOYER), abi_word(ex.DEPLOYER)])
        revoke = dict(grant, logIndex='0x5', topics=[ex.keccak('RoleRevoked(bytes32,address,address)'), ex.ZERO32, abi_word(ex.DEPLOYER), abi_word(ex.DEPLOYER)])
        logs.extend([grant, revoke])
        self.assertEqual(ex.roles_readback(chain, plan, hex(int(BLOCK, 16)+1)), plan['roles'])
        logs.append(dict(revoke, logIndex='0x6', topics=[revoke['topics'][0], ex.keccak('PROPOSER_ROLE'), abi_word(ex.SAFE), abi_word(ex.DEPLOYER)]))
        with self.assertRaises(ex.Gate) as caught:
            ex.roles_readback(chain, plan, hex(int(BLOCK, 16)+1))
        self.assertEqual(caught.exception.record['gate'], 'timelock_role_sets')
        logs.pop()
        logs.append(dict(base, logIndex='0x6', topics=[ex.keccak('RoleAdminChanged(bytes32,bytes32,bytes32)'), ex.keccak('PROPOSER_ROLE'), ex.ZERO32, abi_word(123)]))
        with self.assertRaises(ex.Gate) as caught:
            ex.roles_readback(chain, plan, hex(int(BLOCK, 16)+1))
        self.assertEqual(caught.exception.record['gate'], 'timelock_role_admins')



if __name__ == '__main__':
    unittest.main(verbosity=2)
