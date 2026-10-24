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
from unittest.mock import patch, Mock
from types import SimpleNamespace
from concurrent.futures import ThreadPoolExecutor

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
        self.engine_process = SimpleNamespace(pid=12345, poll=lambda: None)
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
            return dict(currentBlockNumber=hex(s['head']),  # real anvil shape: hex quantity
                         hardFork='Amsterdam', transactionOrder='fifo', environment=dict(chainId=ex.CHAIN),
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
            if target == self.pin['capped']: return deployed_runtime(self.plan)
            if target == self.pin['timelock']: return self.plan['timelockRuntimeIdentity']['artifactRuntime']
            return '0x6000'
        if method == 'eth_getBlockByNumber':
            block = copy.deepcopy(self.block() if params[0] == 'latest' else s['blocks'][params[0]])
            if params[1]:
                block['transactions'] = [dict(s['txs'][h], hash=h) for h, r in s['receipts'].items()
                                         if r['blockNumber'] == block['number']]
            return block
        if method == 'eth_getLogs':
            topics = params[0].get('topics', [])
            def matches(log):
                for i, wanted in enumerate(topics):
                    if i >= len(log['topics']): return False
                    if wanted is None: continue
                    if isinstance(wanted, list):
                        if log['topics'][i] not in wanted: return False
                    elif log['topics'][i] != wanted: return False
                return True
            return [copy.deepcopy(log) for log in s['logs'] if matches(log)]
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
            s['txs'][h] = dict(tx, input=tx['data'], type='0x2', accessList=[])
            if sid == 'S5b' and reason is None:
                scheduled = dict(address=self.pin['timelock'], blockNumber=hex(s['head']),
                    transactionHash=h, transactionIndex='0x0', logIndex='0x0',
                    topics=[ex.keccak('CallScheduled(bytes32,uint256,address,uint256,bytes,bytes32,uint256)'),
                            self.plan['operationId'], ex.ZERO32],
                    data=ex.cast('abi-encode', 'c(address,uint256,bytes,bytes32,uint256)',
                                 self.pin['capped'], 0, ex.calldata('acceptOwnership()'), ex.ZERO32, 172800))
                s['logs'].append(scheduled)
                logs.append(scheduled)
            s['receipts'][h] = dict(transactionHash=h, blockNumber=hex(s['head']), gasUsed=hex(110000),
                status='0x0' if reason else '0x1', logs=logs,
                contractAddress=self.pin['timelock'] if sid == 'S2' else self.pin['capped'] if sid == 'S3' else None,
                revertOutput=reason)
            return h
        if method == 'eth_getTransactionReceipt': return s['receipts'][params[0]]
        if method == 'eth_getTransactionByHash': return s['txs'][params[0]]
        if method == 'debug_traceTransaction':
            if params[1]['tracer'] == 'prestateTracer': return {'pre': {}, 'post': {}}
            trace = {'output': s['receipts'][params[0]]['revertOutput']}
            if trace['output'] == ex.error_string('GS013'):
                trace['calls'] = [dict(to=self.pin['timelock'], input=self.plan['safeInnerData'][1],
                    error='execution reverted', output=ex.calldata('TimelockUnexpectedOperationState(bytes32,bytes32)',
                    self.plan['operationId'], abi_word(4)))]
            return trace
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
    (out/'engine.stderr').write_text('')
    chain = FakeChain(pin)
    ex.authenticate_engine(chain, RELAY_URL, pin['block'])
    try:
        yield chain
    finally:
        with open(out/'relay.log', 'a') as f:
            f.write(ex.TEARDOWN_MARK + '\n')


class ExecutorTests(unittest.TestCase):
    def setUp(self):
        # The archive/compiler boundary has its own offline adversarial tests below;
        # the orchestration tests never invoke a real build or access the network.
        self.real_rebuild = ex.rebuild_artifacts
        patcher = patch.object(ex, 'rebuild_artifacts', return_value={
            'commit': 'a'*40, 'tempTreeCommit': 'a'*40, 'forgeVersion': 'forge Version: 1.7.1',
            'profile': 'default', 'contracts': {}})
        patcher.start()
        self.addCleanup(patcher.stop)

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
        else:
            a['runtimeIdentity'] = {'artifactRuntime': a['deployedBytecode']['object'], 'ranges': []}
        a['sourceHashes'] = {'fixture.sol': {'path': 'fixture.sol', 'keccak256': ex.EMPTY_KECCAK}}
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
        with tempfile.TemporaryDirectory() as d:
            path = Path(d)/'plan.json'
            ex.write_json(path, plan)
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            with patch.object(ex, 'validate_plan') as validate, patch.object(ex, 'pre_send', side_effect=ex.Gate('sentinel', 0, 1)) as gate:
                with self.assertRaises(ex.Gate) as caught:
                    ex.signing_transaction(path, digest, 'S4', chain)
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

    def test_frozen_simulation_is_independent(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            rpc_file, out, sim = root/'rpc', root/'plan-out', root/'sim-out'
            rpc_file.write_text('https://secret.invalid/NEVER_PRINT_THIS')
            with patch.object(ex.urllib.request, 'urlopen', self.mock_urlopen('valid')), \
                    patch.object(ex, 'artifact', self.artifact), patch.object(ex, 'fork', fake_fork):
                self.assertEqual(ex.main(['plan', '--rpc-file', str(rpc_file), '--block', BLOCK, '--out', str(out)]), 0)
                frozen_bytes = (out/'plan.json').read_bytes()
                sim.mkdir()
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
                    self.assertEqual(ex.main(['simulate', '--rpc-file', str(rpc_file), '--plan', str(out/'plan.json'), '--out', str(root/'edited-out')]), 1)
                self.assertEqual(json.loads((root/'edited-out'/'FAILURE.json').read_text())['gate'], 'plan_step_S4_nonce')

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
            mark = ex.TEARDOWN_MARK + '\n'
            for text in ('', 'refused eth_gasPrice\n'):
                (out/'relay.log').write_text(text + mark)
                ex.relay_evidence(out)
            for text in ('failed eth_getCode\n', 'refused eth_sendTransaction\n', 'relay error\n',
                         'failed handler BrokenPipeError methods=eth_getStorageAt upstreamServed=True elapsed=3.2s\n'):
                (out/'relay.log').write_text(text + mark)
                with self.assertRaises(ex.Gate) as caught:
                    ex.relay_evidence(out)
                self.assertEqual(caught.exception.record['gate'], 'relay_evidence')

    def test_relay_abandoned_requests(self):
        with tempfile.TemporaryDirectory() as d:
            out = Path(d)
            mark = ex.TEARDOWN_MARK + '\n'
            ab = 'abandoned BrokenPipeError methods=eth_getBalance upstreamServed=True elapsed=0.2s key=%s\n'
            # The identical request was already delivered: harmless duplicate.
            (out/'relay.log').write_text('abandoned-duplicate BrokenPipeError methods=eth_getBalance upstreamServed=True elapsed=0.2s key=aa\n' + mark)
            ex.relay_evidence(out)
            # Abandoned first, redelivered later in the window: passes.
            (out/'relay.log').write_text(ab % 'bb' + 'redelivered key=bb\n' + mark)
            ex.relay_evidence(out)
            # Abandoned after the upstream answered, well below anvil's timeout, never re-requested: harmless.
            (out/'relay.log').write_text(ab % 'cc' + mark)
            ex.relay_evidence(out)
            # Fatal: upstream failure (anvil got a 502); abandon near anvil's own timeout; abandon before upstream answered.
            for text in ('failed handler URLError methods=eth_getCode upstreamServed=False elapsed=45.0s\n',
                         'abandoned BrokenPipeError methods=eth_getCode upstreamServed=True elapsed=61.0s key=ee\n',
                         'abandoned BrokenPipeError methods=eth_getCode upstreamServed=False elapsed=0.1s key=ff\n',
                         'abandoned ValueError methods=eth_getCode upstreamServed=True elapsed=0.1s key=gg\n'):
                (out/'relay.log').write_text(text + mark)
                with self.assertRaises(ex.Gate) as caught:
                    ex.relay_evidence(out)
                self.assertEqual(caught.exception.record['gate'], 'relay_evidence')

    def test_request_key_ignores_id_only(self):
        a = {'jsonrpc': '2.0', 'id': 1, 'method': 'eth_getBalance', 'params': ['0x' + '11' * 20, '0x1']}
        b = dict(a, id=99)
        c = dict(a, params=['0x' + '22' * 20, '0x1'])
        self.assertEqual(ex.request_key(a), ex.request_key(b))
        self.assertNotEqual(ex.request_key(a), ex.request_key(c))
        self.assertEqual(ex.request_key([a, c]), ex.request_key([b, dict(c, id=7)]))

    def test_relay_teardown_window(self):
        with tempfile.TemporaryDirectory() as d:
            out = Path(d)
            mark = ex.TEARDOWN_MARK + '\n'
            # Interrupted prefetches after the engine is killed do not count...
            (out/'relay.log').write_text('refused eth_gasPrice\n' + mark + 'failed handler BrokenPipeError methods=eth_getStorageAt upstreamServed=True elapsed=3.2s\n')
            ex.relay_evidence(out)
            # ...but the same line before the marker fails, and a log without the marker fails.
            (out/'relay.log').write_text('failed handler BrokenPipeError methods=eth_getStorageAt upstreamServed=True elapsed=3.2s\n' + mark)
            with self.assertRaises(ex.Gate) as caught:
                ex.relay_evidence(out)
            self.assertEqual(caught.exception.record['gate'], 'relay_evidence')
            (out/'relay.log').write_text('refused eth_gasPrice\n')
            with self.assertRaises(ex.Gate) as caught:
                ex.relay_evidence(out)
            self.assertEqual(caught.exception.record['gate'], 'relay_teardown_marker')
            # Mid-run (live) check: everything counts, and a marker must not exist yet.
            (out/'relay.log').write_text('refused eth_gasPrice\n')
            ex.relay_evidence(out, live=True)
            (out/'relay.log').write_text('failed handler BrokenPipeError methods=eth_getStorageAt upstreamServed=True elapsed=3.2s\n')
            with self.assertRaises(ex.Gate):
                ex.relay_evidence(out, live=True)

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
            self.assertIn('output_empty', stderr.getvalue())

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


    def measured_plan(self):
        _, plan = self.chain_and_plan()
        for step in plan['steps']:
            step.update(estimateGas=100000, localEstimateGas=200000, forkGasUsed=110000)
            step['tx']['gas'] = hex(260000)
        ex.budget(plan)
        return plan

    def assert_injected_tx_fails(self, key, value):
        plan = self.measured_plan()
        plan['steps'][0]['tx'][key] = value
        with patch.object(ex, 'artifact', self.artifact), self.assertRaises(ex.Gate) as caught:
            ex.validate_plan(plan, frozen=True)
        self.assertEqual(caught.exception.record['gate'], 'plan_tx_keys_S1')
        with self.assertRaises(ex.Gate) as caught:
            ex.tx_rpc(plan['steps'][0]['tx'])
        self.assertEqual(caught.exception.record['gate'], 'tx_rpc_keys')

    def test_injected_type_rejected(self):
        self.assert_injected_tx_fails('type', '0x4')

    def test_injected_authorization_list_rejected(self):
        self.assert_injected_tx_fails('authorizationList', [{'address': ex.DEPLOYER}])

    def test_injected_access_list_rejected(self):
        self.assert_injected_tx_fails('accessList', [])

    def test_injected_input_rejected(self):
        self.assert_injected_tx_fails('input', '0x00')

    def test_reviewer_combined_tamper_rejected(self):
        plan = self.measured_plan()
        plan['steps'][0]['tx'].update(type='0x4', authorizationList=[], accessList=[], input='0x00')
        plan['budgetsWei'] = 1
        plan['steps'][0]['executionTimestamp'] = 5
        with patch.object(ex, 'artifact', self.artifact), self.assertRaises(ex.Gate):
            ex.validate_plan(plan, frozen=True)

    def test_exact_plan_and_step_key_sets(self):
        plan = self.measured_plan()
        with patch.object(ex, 'artifact', self.artifact):
            ex.validate_plan(plan, frozen=True)
            for location, gate in (('top', 'plan_keys'), ('step', 'plan_step_keys_S1'), ('pin', 'pin_keys')):
                changed = copy.deepcopy(plan)
                target = changed if location == 'top' else changed['steps'][0] if location == 'step' else changed['pin']
                target['unexpected'] = 1
                with self.assertRaises(ex.Gate) as caught:
                    ex.validate_plan(changed, frozen=True)
                self.assertEqual(caught.exception.record['gate'], gate)
            changed = copy.deepcopy(plan)
            changed['steps'][0]['estimateContext'] = {'block': 'latest'}
            with self.assertRaises(ex.Gate) as caught:
                ex.validate_plan(changed, frozen=True)
            self.assertEqual(caught.exception.record['gate'], 'plan_step_keys_S1')
            changed = copy.deepcopy(plan)
            del changed['steps'][0]['tx']['value']
            with self.assertRaises(ex.Gate) as caught:
                ex.validate_plan(changed, frozen=True)
            self.assertEqual(caught.exception.record['gate'], 'plan_tx_keys_S1')

    def test_every_execution_timestamp_is_recomputed(self):
        plan = self.measured_plan()
        with patch.object(ex, 'artifact', self.artifact):
            for i, sid in enumerate(ex.STEP_IDS):
                changed = copy.deepcopy(plan)
                changed['steps'][i]['executionTimestamp'] += 1
                with self.subTest(sid=sid), self.assertRaises(ex.Gate) as caught:
                    ex.validate_plan(changed, frozen=True)
                self.assertEqual(caught.exception.record['gate'], 'plan_derived_'+sid+'_executionTimestamp')
            changed = copy.deepcopy(plan)
            changed['steps'][5]['plannedETA'] += 1
            with self.assertRaises(ex.Gate) as caught:
                ex.validate_plan(changed, frozen=True)
            self.assertEqual(caught.exception.record['gate'], 'plan_derived_S5b_plannedETA')

    def test_both_budget_fields_recomputed(self):
        plan = self.measured_plan()
        with patch.object(ex, 'artifact', self.artifact):
            for key, gate in (('budgetsWei', 'plan_budgets'), ('budgetWei', 'plan_budget')):
                changed = copy.deepcopy(plan)
                changed[key] = 1
                with self.subTest(key=key), self.assertRaises(ex.Gate) as caught:
                    ex.validate_plan(changed, frozen=True)
                self.assertEqual(caught.exception.record['gate'], gate)

    def test_mined_extended_fields_and_aliases_checked(self):
        tx = self.measured_plan()['steps'][0]['tx']
        mined = dict(tx, type='0x2', authorizationList=[], accessList=[], input=tx['data'])
        ex.mined_identity(mined, tx, 'S1')
        cases = [('type', '0x4', 'type'), ('authorizationList', [{}], 'authorizations'),
                 ('accessList', [{}], 'access_list'), ('input', '0xab', 'input'),
                 ('data', '0xab', 'data_alias'), ('value', '0x1', 'value')]
        for key, value, gate in cases:
            with self.subTest(key=key):
                changed = dict(mined, **{key: value})
                with self.assertRaises(ex.Gate) as caught:
                    ex.mined_identity(changed, tx, 'S1')
                self.assertEqual(caught.exception.record['gate'], 'S1_mined_'+gate)

    def test_pre_send_eta_comes_from_actual_schedule_receipt(self):
        chain, plan = self.chain_and_plan()
        for step in plan['steps']: step['tx']['gas'] = hex(260000)
        self.send_prefix(chain, plan, ('S1', 'S2', 'S3', 'S4', 'S5a'))
        chain.state['next'] = chain.state['time']+3600
        self.send_prefix(chain, plan, ('S5b',))
        self.assertNotEqual(chain.state['eta'], plan['steps'][5]['plannedETA'])
        self.assertEqual(ex.pre_send(ex.ExecutionStep(plan, 'S6a'), chain), plan['steps'][6]['tx'])
        self.send_prefix(chain, plan, ('S6a',))
        chain('evm_setNextBlockTimestamp', [chain.state['eta']])
        chain('evm_mine', [])
        self.assertEqual(ex.pre_send(ex.ExecutionStep(plan, 'S6b'), chain), plan['steps'][7]['tx'])
        chain.state['eta'] += 1
        with self.assertRaises(ex.Gate) as caught:
            ex.pre_send(ex.ExecutionStep(plan, 'S6b'), chain)
        self.assertEqual(caught.exception.record['gate'], 'schedule_chain_eta')

    def test_signing_requires_out_of_band_file_hash(self):
        plan = self.measured_plan()
        with tempfile.TemporaryDirectory() as d:
            path = Path(d)/'plan.json'
            ex.write_json(path, plan)
            reviewed = hashlib.sha256(path.read_bytes()).hexdigest()
            # Replacing the plan and its sidecar must never replace the review digest.
            path.write_text(path.read_text()+' ')
            path.with_name('plan.json.sha256').write_text(hashlib.sha256(path.read_bytes()).hexdigest())
            with patch.object(ex, 'validate_plan', side_effect=AssertionError('hash first')):
                with self.assertRaises(ex.Gate) as caught:
                    ex.signing_transaction(path, reviewed, 'S1', None)
            self.assertEqual(caught.exception.record['gate'], 'reviewed_plan_hash')

    def test_future_signer_checks_safe_hashes_for_s5_and_s6(self):
        plan = self.measured_plan()
        with tempfile.TemporaryDirectory() as d:
            path = Path(d)/'plan.json'; ex.write_json(path, plan)
            reviewed = hashlib.sha256(path.read_bytes()).hexdigest()
            remote = Mock()
            with patch.object(ex, 'artifact', self.artifact):
                for sid in ('S5a', 'S5b', 'S6a', 'S6b'):
                    with self.subTest(sid=sid), patch.object(ex, 'safe_hash_check') as safe, patch.object(ex, 'pre_send', return_value={}) as pre:
                        ex.signing_transaction(path, reviewed, sid, remote)
                        safe.assert_called_once_with(remote, plan)
                        pre.assert_called_once()
                with patch.object(ex, 'safe_hash_check', side_effect=ex.Gate('safe_hash_5', 0, 1)), patch.object(ex, 'pre_send') as pre:
                    with self.assertRaises(ex.Gate):
                        ex.signing_transaction(path, reviewed, 'S5b', remote)
                    pre.assert_not_called()

    def test_engine_port_requires_own_pid_and_live_child(self):
        proc = SimpleNamespace(pid=12345, poll=Mock(return_value=None))
        with patch.object(ex.shutil, 'which', return_value='/usr/sbin/lsof'), patch.object(ex.subprocess, 'run', return_value=SimpleNamespace(returncode=0, stdout='12345\n')) as run:
            ex.process_owns_port(proc, 65000)
            self.assertEqual(run.call_args.args[0], ['/usr/sbin/lsof', '-nP', '-iTCP:65000', '-sTCP:LISTEN', '-t'])
        with patch.object(ex.shutil, 'which', return_value=None):
            with self.assertRaises(ex.Gate) as caught: ex.process_owns_port(proc, 65000)
            self.assertEqual(caught.exception.record['gate'], 'engine_lsof')
        for stdout in ('999\n', '12345\n999\n', ''):
            with patch.object(ex.shutil, 'which', return_value='/usr/sbin/lsof'), patch.object(ex.subprocess, 'run', return_value=SimpleNamespace(returncode=0, stdout=stdout)):
                with self.assertRaises(ex.Gate) as caught: ex.process_owns_port(proc, 65000)
                self.assertEqual(caught.exception.record['gate'], 'engine_listener_pid')
        proc.poll = Mock(return_value=1)
        with self.assertRaises(ex.Gate) as caught: ex.process_owns_port(proc, 65000)
        self.assertEqual(caught.exception.record['gate'], 'engine_process_alive')

    def test_engine_dies_between_steps(self):
        chain, plan = self.chain_and_plan()
        chain.engine_process.poll = Mock(side_effect=[None, 9])
        @contextlib.contextmanager
        def stopped(*args): yield chain
        with tempfile.TemporaryDirectory() as d, patch.object(ex, 'artifact', self.artifact), patch.object(ex, 'fork', stopped):
            (Path(d)/'simulate.log').write_text('')
            with self.assertRaises(ex.Gate) as caught:
                ex.rehearse(lambda *_: hex(100000), plan, Path(d), calibrate=True)
        self.assertEqual(caught.exception.record['gate'], 'engine_process_alive')
        self.assertEqual([sid for sid, _, _ in chain.sent], ['S1', 'S1'])  # pilot and exact replay only

    def test_node_info_current_head_and_trailing_slash(self):
        chain, _ = self.chain_and_plan()
        info = chain('anvil_nodeInfo', [])
        info['forkConfig']['forkUrl'] += '/'
        def rpc(method, params): return info if method == 'anvil_nodeInfo' else chain(method, params)
        ex.authenticate_engine(rpc, RELAY_URL, chain.pin['block'])
        info['currentBlockNumber'] = hex(int(info['currentBlockNumber'], 16) + 1)
        with self.assertRaises(ex.Gate) as caught:
            ex.authenticate_engine(rpc, RELAY_URL, chain.pin['block'])
        self.assertEqual(caught.exception.record['gate'], 'local_engine_current_block')

    def test_artifact_source_hashes_include_remapped_committed_bytes(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d).resolve(); (root/'vendor').mkdir(); source = root/'vendor/Source.sol'
            committed = b'pragma solidity 0.8.33;\n'; source.write_bytes(committed)
            metadata = {'sources': {'@pkg/Source.sol': {'keccak256': ex.keccak('0x'+committed.hex())}},
                        'settings': {'remappings': ['@pkg/=vendor/']}}
            with patch.object(ex, 'ROOT', root), patch.object(ex, 'committed_bytes', return_value=committed) as read:
                result = ex.artifact_sources(metadata)
                self.assertEqual(result['@pkg/Source.sol']['path'], 'vendor/Source.sol')
                read.assert_called_once_with(root, 'vendor/Source.sol')
                source.write_bytes(committed+b'// uncommitted\n')
                with self.assertRaises(ex.Gate) as caught: ex.artifact_sources(metadata)
                self.assertEqual(caught.exception.record['gate'], 'artifact_source_worktree')
                source.write_bytes(committed)
                metadata['sources']['@pkg/Source.sol']['keccak256'] = ex.ZERO32
                with self.assertRaises(ex.Gate) as caught: ex.artifact_sources(metadata)
                self.assertEqual(caught.exception.record['gate'], 'artifact_source_metadata')
                source.unlink()
                with self.assertRaises(ex.Gate) as caught: ex.artifact_sources(metadata)
                self.assertEqual(caught.exception.record['gate'], 'artifact_source_unresolved')

    def test_committed_sources_follow_pinned_gitlinks(self):
        root = Path('/offline-repo'); commit = 'ab'*20
        calls = []
        def run(args, **kwargs):
            calls.append((args, kwargs['cwd']))
            if args == ['git', 'show', 'HEAD:vendor/Source.sol']:
                return SimpleNamespace(returncode=1, stdout=b'')
            if args == ['git', 'ls-tree', '-z', 'HEAD', '--', 'vendor']:
                return SimpleNamespace(returncode=0, stdout=('160000 commit '+commit+'\tvendor\0').encode())
            if args == ['git', 'show', commit+':Source.sol']:
                return SimpleNamespace(returncode=0, stdout=b'committed')
            raise AssertionError(args)
        with patch.object(ex.subprocess, 'run', side_effect=run):
            self.assertEqual(ex.committed_bytes(root, 'vendor/Source.sol'), b'committed')
        self.assertEqual(calls[-1][1], root/'vendor')
        with patch.object(ex.subprocess, 'run', return_value=SimpleNamespace(returncode=1, stdout=b'')):
            with self.assertRaises(ex.Gate) as caught: ex.committed_bytes(root, 'missing.sol')
        self.assertEqual(caught.exception.record['gate'], 'artifact_source_uncommitted')

    def test_nonempty_output_rejected_without_overwriting_prior_evidence(self):
        with tempfile.TemporaryDirectory() as d:
            out = Path(d)/'out'; out.mkdir()
            prior = out/'FAILURE.json'; prior.write_text('prior evidence')
            with patch.object(ex, 'RPC', side_effect=AssertionError('output gate first')), contextlib.redirect_stderr(io.StringIO()) as stderr:
                self.assertEqual(ex.main(['plan', '--rpc-file', '/unused', '--block', BLOCK, '--out', str(out)]), 1)
            self.assertIn('output_empty', stderr.getvalue())
            self.assertEqual(prior.read_text(), 'prior evidence')

    def test_engine_stderr_prevents_pass(self):
        chain, plan = self.chain_and_plan()
        @contextlib.contextmanager
        def noisy(remote, pin, out):
            (out/'simulate.log').write_text('')
            (out/'relay.log').write_text('')
            (out/'engine.stderr').write_text('unexpected engine warning\n')
            try:
                yield chain
            finally:
                with open(out/'relay.log', 'a') as f:
                    f.write(ex.TEARDOWN_MARK + '\n')
        with tempfile.TemporaryDirectory() as d, patch.object(ex, 'artifact', self.artifact), patch.object(ex, 'fork', noisy):
            with self.assertRaises(ex.Gate) as caught:
                ex.rehearse(lambda *_: hex(100000), plan, Path(d), calibrate=True)
            self.assertEqual(caught.exception.record['gate'], 'engine_stderr')
            self.assertNotEqual(json.loads((Path(d)/'simulate.json').read_text())['status'], 'PASS')

    def test_create_address_vectors(self):
        # Reference values from `cast compute-address` (same on 1.7.1 and nightly 926eb1d), including the RLP
        # single-byte / short-string boundaries and the two v4-packet CREATE targets (nonce 12132 / 12133).
        vectors = {0: '0x851571543ad6d749cc765fabc99cd8f1b193e920', 1: '0xa1a0e154d96c2c0413cdcefa4e32d68d3f0af377',
                   127: '0xa181de9140d91d7e16f4102db162a435cc0790e2', 128: '0x4accffab0765bd21c5da628dfc0a75741c386237',
                   255: '0x1509bdc5ec966d564d45eadc549b838d5e35b443', 256: '0xcf6011ac55cd7e4de6e3212783aed38147f252e8',
                   12132: '0xccdf8e0d29fb2c3061910d79484a2b653757c34b', 12133: '0x9eb17fac022557f64924aa2f9e018db3a330e1e7'}
        for nonce, want in vectors.items():
            with self.subTest(nonce=nonce):
                self.assertEqual(ex.create_address(ex.DEPLOYER, nonce), want)
        for bad in (-1, True, 1.0):
            with self.assertRaises(ex.Gate):
                ex.create_address(ex.DEPLOYER, bad)

    def test_rpc_ids_are_thread_safe(self):
        observed = []
        def urlopen(request, timeout=None):
            q = json.loads(request.data)
            observed.append(q['id'])
            ex.time.sleep(.001)
            return io.BytesIO(json.dumps(dict(jsonrpc='2.0', id=q['id'], result=hex(ex.CHAIN))).encode())
        rpc = ex.RPC('https://never-contacted.invalid')
        with patch.object(ex.urllib.request, 'urlopen', urlopen), ThreadPoolExecutor(max_workers=8) as pool:
            results = list(pool.map(lambda _: rpc('eth_chainId', []), range(64)))
        self.assertEqual(results, [hex(ex.CHAIN)]*64)
        self.assertEqual(sorted(observed), list(range(1, 65)))

    def test_rpc_total_deadline_against_trickling_server(self):
        # Real sockets. Each server keeps every recv well inside the 45 s socket timeout by sending one byte every
        # 20 ms, at a different stage: status/header line, chunk trailers (chunked framing), and body. Only the
        # wall-clock deadline can end these requests, and the failure must be that deadline (TimeoutError).
        import socketserver, threading, time as _time
        stages = {
            'headers': (b'HTTP/1.1 200 OK\r\nX-Slow: ', b'a'),
            'chunk_trailers': (b'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n1\r\n{\r\n0\r\n', b'X: y\r\n'),
            'body': (b'HTTP/1.0 200 OK\r\nContent-Type: application/json\r\n\r\n', b' '),
        }
        for stage, (prefix, drip) in stages.items():
            stop = threading.Event()
            class Trickle(socketserver.BaseRequestHandler):
                def handle(self):
                    self.request.recv(65536)
                    try:
                        self.request.sendall(prefix)
                        while not stop.is_set():
                            self.request.sendall(drip); _time.sleep(.02)
                    except OSError:
                        pass
            server = socketserver.ThreadingTCPServer(('127.0.0.1', 0), Trickle)
            server.daemon_threads = True
            threading.Thread(target=server.serve_forever, daemon=True).start()
            try:
                with self.subTest(stage=stage):
                    started = _time.monotonic()
                    with patch.object(ex, 'RPC_TOTAL_DEADLINE_SECONDS', .3), self.assertRaises(ex.Gate) as caught:
                        ex.RPC(f'http://127.0.0.1:{server.server_address[1]}')('eth_chainId', [])
                    elapsed = _time.monotonic() - started
                    self.assertEqual(caught.exception.record['gate'], 'rpc_transport')
                    self.assertEqual(caught.exception.record['observed'], 'TimeoutError')
                    self.assertGreaterEqual(elapsed, .3)
                    self.assertLess(elapsed, 5)
            finally:
                stop.set(); server.shutdown(); server.server_close()

    def test_rpc_deadline_refuses_a_result_decoded_after_it(self):
        # The body arrives at once but decoding it outlasts the deadline (json.loads holds the GIL, so join()
        # cannot wake early): the late result must be refused as a timeout, not returned.
        body = ('{"jsonrpc":"2.0","id":1,"result":[' + ','.join(['1']*3000000) + ']}').encode()
        with patch.object(ex.urllib.request, 'urlopen', lambda request, timeout=None: io.BytesIO(body)), \
                patch.object(ex, 'RPC_TOTAL_DEADLINE_SECONDS', .01), self.assertRaises(ex.Gate) as caught:
            ex.RPC('https://never-contacted.invalid')('eth_chainId', [])
        self.assertEqual(caught.exception.record['observed'], 'TimeoutError')

    def test_timelock_runtime_bytes_and_immutable_values(self):
        plan = {'timelockRuntimeIdentity': {'artifactRuntime': '0x6000', 'ranges': []}}
        self.assertTrue(ex.verify_runtime(None, plan, '0x6000', 'TimelockController')['unmaskedBytesEqual'])
        with self.assertRaises(ex.Gate) as caught: ex.verify_runtime(None, plan, '0x6001', 'TimelockController')
        self.assertEqual(caught.exception.record['gate'], 'runtime_unmasked_bytes')
        plan['timelockRuntimeIdentity'] = {'artifactRuntime': '0x60'+'00'*64+'00', 'ranges': [
            {'id': '1', 'name': '_minDelay', 'start': 1, 'length': 32},
            {'id': '1', 'name': '_minDelay', 'start': 33, 'length': 32}]}
        code = '0x60'+format(172800, '064x')*2+'00'
        result = ex.verify_runtime(None, plan, code, 'TimelockController')
        self.assertEqual(len(result['immutables']['_minDelay']), 2)
        with self.assertRaises(ex.Gate) as caught:
            ex.verify_runtime(None, plan, '0x60'+format(172800, '064x')+format(1, '064x')+'00', 'TimelockController')
        self.assertEqual(caught.exception.record['gate'], 'immutable_value__minDelay')
        plan['timelockRuntimeIdentity']['ranges'][0]['name'] = 'cannotCompute'
        with self.assertRaises(ex.Gate) as caught: ex.verify_runtime(None, plan, code, 'TimelockController')
        self.assertEqual(caught.exception.record['gate'], 'immutable_expected_unknown')


    def test_numeric_aliases_do_not_bypass_exact_plan_values(self):
        plan = self.measured_plan()
        with patch.object(ex, 'artifact', self.artifact):
            for field in ('schema', 'budgetWei', 'margin', 'budgetsWei'):
                changed = copy.deepcopy(plan)
                if field == 'margin': changed[field] = [float(x) for x in changed[field]]
                elif field == 'budgetsWei': changed[field] = {k: float(v) for k, v in changed[field].items()}
                else: changed[field] = float(changed[field])
                with self.subTest(field=field), self.assertRaises(ex.Gate):
                    ex.validate_plan(changed, frozen=True)

    def test_frozen_replay_rechecks_recorded_gas_used(self):
        plan = self.measured_plan()
        with patch.object(ex, 'artifact', self.artifact):
            chain = FakeChain(plan['pin'])
        def changed(method, params, error_ok=False):
            value = chain(method, params, error_ok=error_ok)
            if method == 'eth_getTransactionReceipt':
                value = dict(value, gasUsed=hex(110001))
            return value
        changed.engine_process = chain.engine_process
        @contextlib.contextmanager
        def different(*args): yield changed
        with tempfile.TemporaryDirectory() as d, patch.object(ex, 'artifact', self.artifact), patch.object(ex, 'fork', different):
            with self.assertRaises(ex.Gate) as caught:
                ex.rehearse(lambda *_: hex(100000), plan, Path(d))
        self.assertEqual(caught.exception.record['gate'], 'S1_gas_crosscheck')

    def test_duplicate_keys_rejected_by_both_plan_readers(self):
        for raw in (b'{"steps":[],"steps":[]}', b'{"tx":{"value":"0x0","value":"0x1"}}'):
            with self.subTest(raw=raw), tempfile.TemporaryDirectory() as d:
                path = Path(d)/'plan.json'; path.write_bytes(raw)
                digest = hashlib.sha256(raw).hexdigest()
                path.with_name('plan.json.sha256').write_text(digest)
                with self.assertRaises(ex.Gate) as caught: ex.load_plan(path)
                self.assertEqual(caught.exception.record['gate'], 'duplicate_json_key')
                with self.assertRaises(ex.Gate) as caught: ex.signing_transaction(path, digest, 'S1', None)
                self.assertEqual(caught.exception.record['gate'], 'duplicate_json_key')

    def test_all_pin_integers_reject_bool_float_and_negative(self):
        plan = self.measured_plan()
        paths = [('timestamp',), ('deployerNonce',), ('safeNonce',), ('balance',),
                 ('sp', 'pendingAPNTsTokenEta'), ('sp', 'APNTS_TOKEN_TIMELOCK')]
        paths += [('senders', sender, field) for sender in ex.SENDERS for field in ('nonce', 'balance')]
        for path in paths:
            for value in (True, 1.0, -1, '1'):
                changed = copy.deepcopy(plan['pin']); target = changed
                for part in path[:-1]: target = target[part]
                target[path[-1]] = value
                with self.subTest(path=path, value=value), self.assertRaises(ex.Gate):
                    ex.validate_pin(changed)

    def test_pin_and_tx_quantities_are_canonical(self):
        pin = self.measured_plan()['pin']
        for block in ('0xAb', '0x00', '0x01', '0X1', True, 1):
            changed = dict(pin, block=block)
            with self.subTest(block=block), self.assertRaises(ex.Gate): ex.validate_pin(changed)
        for field in ('value', 'nonce', 'chainId', 'maxFeePerGas', 'maxPriorityFeePerGas', 'gas'):
            for value in ('0xAb', '0x00', '0x01', '0X1', True, 1):
                with self.subTest(field=field, value=value), self.assertRaises(ex.Gate):
                    ex.tx_rpc({field: value})
        self.assertEqual(ex.qty('0x0'), 0)
        self.assertEqual(ex.qty('0xab'), 171)

    def test_explicit_per_step_gas_cap(self):
        self.assertEqual(ex.tx_rpc({'gas': hex(2**24)}), {'gas': hex(2**24)})
        with self.assertRaises(ex.Gate) as caught: ex.tx_rpc({'gas': hex(2**24+1)})
        self.assertEqual(caught.exception.record['gate'], 'gas_cap')
        plan = self.measured_plan()
        plan['steps'][0]['localEstimateGas'] = 2**24
        plan['steps'][0]['tx']['gas'] = hex((2**24*13+9)//10)
        ex.budget(plan)
        with patch.object(ex, 'artifact', self.artifact), self.assertRaises(ex.Gate) as caught:
            ex.validate_plan(plan, frozen=True)
        self.assertEqual(caught.exception.record['gate'], 'gas_cap')

    def test_frozen_replay_rechecks_both_gas_estimates(self):
        for which in ('archive', 'local'):
            plan = self.measured_plan()
            with patch.object(ex, 'artifact', self.artifact): chain = FakeChain(plan['pin'])
            def local(method, params, error_ok=False):
                if which == 'local' and method == 'eth_estimateGas': return hex(200001)
                return chain(method, params, error_ok=error_ok)
            local.engine_process = chain.engine_process
            @contextlib.contextmanager
            def isolated(*args): yield local
            remote = lambda *_: hex(100001 if which == 'archive' else 100000)
            with self.subTest(which=which), tempfile.TemporaryDirectory() as d, patch.object(ex, 'artifact', self.artifact), patch.object(ex, 'fork', isolated):
                with self.assertRaises(ex.Gate) as caught: ex.rehearse(remote, plan, Path(d))
                self.assertEqual(caught.exception.record['gate'], 'S1_'+which+'_estimate')
                self.assertEqual(chain.sent, [])

    def early_negative_fixture(self):
        chain, plan = self.chain_and_plan()
        for step in plan['steps']: step['tx']['gas'] = hex(260000)
        self.send_prefix(chain, plan, ('S1', 'S2', 'S3', 'S4', 'S5a', 'S5b', 'S6a'))
        inner = (plan['pin']['timelock'], plan['safeInnerData'][1],
                 ex.calldata('TimelockUnexpectedOperationState(bytes32,bytes32)', plan['operationId'], abi_word(4)))
        return chain, plan, inner

    def test_early_execute_requires_exact_inner_timelock_revert(self):
        chain, plan, inner = self.early_negative_fixture()
        result = ex.negative(chain, plan['steps'][7]['tx'], ex.error_string('GS013'), 'early_execute', inner=inner)
        self.assertEqual(result['innerRevert']['output'], inner[2])
        before = copy.deepcopy(chain.state)
        for alteration in ('missing', 'wrong_reason', 'no_error', 'unavailable'):
            def rpc(method, params, error_ok=False):
                value = chain(method, params, error_ok=error_ok)
                if method == 'debug_traceTransaction':
                    if alteration == 'unavailable': return None
                    value = copy.deepcopy(value)
                    if alteration == 'missing': value['calls'] = []
                    if alteration == 'wrong_reason': value['calls'][0]['output'] = '0x'
                    if alteration == 'no_error': value['calls'][0].pop('error')
                return value
            with self.subTest(alteration=alteration), self.assertRaises(ex.Gate):
                ex.negative(rpc, plan['steps'][7]['tx'], ex.error_string('GS013'), 'early_execute', inner=inner)
            self.assertEqual(chain.state, before)

    def test_schedule_logs_query_uses_exact_receipt_block(self):
        chain, plan, _ = self.early_negative_fixture()
        calls = []
        def rpc(method, params):
            if method == 'eth_getLogs': calls.append(params[0])
            return chain(method, params)
        self.assertEqual(ex.scheduled_eta(rpc, plan), chain.state['eta'])
        self.assertEqual(len(calls), 1)
        receipt = next(r for r in chain.state['receipts'].values() if any(
            l['topics'][0] == ex.keccak('CallScheduled(bytes32,uint256,address,uint256,bytes,bytes32,uint256)') for l in r['logs']))
        self.assertEqual(calls[0]['fromBlock'], receipt['blockNumber'])
        self.assertEqual(calls[0]['toBlock'], receipt['blockNumber'])

    @staticmethod
    def metadata_artifact(mode='none', raw='{}'):
        solc = b'\x64solc\x43\x00\x08\x21'
        if mode == 'none': tail = b'\xa1'+solc
        else: tail = b'\xa2\x64ipfs\x58\x22'+ex.metadata_ipfs_hash(raw.encode())+solc
        code = '0x60'+tail.hex()+len(tail).to_bytes(2, 'big').hex()
        return {'rawMetadata': raw, 'bytecode': {'object': '0x60006000f3'},
                'deployedBytecode': {'object': code, 'immutableReferences': {}}}

    def test_metadata_no_hash_requires_explicit_head_policy_and_exact_tail(self):
        art = self.metadata_artifact()
        config = {'profile': {'default': {'bytecode_hash': 'none'}}}
        self.assertEqual(ex.metadata_identity(art, config)['mode'], 'none')
        for changed_config in ({}, {'profile': {'default': {'bytecode_hash': 'ipfs'}}}):
            with self.assertRaises(ex.Gate): ex.metadata_identity(art, changed_config)
        extra = self.metadata_artifact('ipfs')
        with self.assertRaises(ex.Gate) as caught: ex.metadata_identity(extra, config)
        self.assertEqual(caught.exception.record['gate'], 'metadata_no_hash_keys')
        bad = copy.deepcopy(art)
        bad['deployedBytecode']['object'] = bad['deployedBytecode']['object'].replace('000821', '000820')
        with self.assertRaises(ex.Gate) as caught: ex.metadata_identity(bad, config)
        self.assertEqual(caught.exception.record['gate'], 'metadata_solc')

    def test_metadata_hash_must_match_raw_metadata_when_enabled(self):
        art = self.metadata_artifact('ipfs', '{"metadata":"fixture"}')
        config = {'profile': {'default': {'bytecode_hash': 'ipfs'}}}
        self.assertEqual(ex.metadata_identity(art, config)['mode'], 'ipfs')
        art['rawMetadata'] += ' '
        with self.assertRaises(ex.Gate) as caught: ex.metadata_identity(art, config)
        self.assertEqual(caught.exception.record['gate'], 'metadata_ipfs_hash')

    def test_rebuild_compares_all_bytecode_and_reference_fields(self):
        originals = {name: self.metadata_artifact() for name in ex.CONTRACT_NAMES}
        config = {'profile': {'default': {'bytecode_hash': 'none'}}}
        commit = 'b'*40
        def run(args, **kwargs):
            return SimpleNamespace(returncode=0, stdout=commit+'\n' if args[0] == 'git' else 'forge Version: 1.7.1\n')
        with patch.object(ex.subprocess, 'run', side_effect=run), patch.object(ex, 'compile_commit', return_value=(originals, config)), patch.object(ex, 'committed_bytes', return_value=b'[profile.default]\nbytecode_hash="none"\n'):
            proof = self.real_rebuild(copy.deepcopy(originals))
            self.assertEqual(proof['tempTreeCommit'], commit)
            self.assertEqual(proof['forgeVersion'], 'forge Version: 1.7.1')
            for name in ex.CONTRACT_NAMES:
                for field in ('bytecode', 'deployedBytecode'):
                    changed = copy.deepcopy(originals)
                    changed[name][field]['object'] += '00'
                    with self.subTest(name=name, field=field), self.assertRaises(ex.Gate) as caught:
                        self.real_rebuild(changed)
                    self.assertEqual(caught.exception.record['gate'], 'rebuild_'+name+'_'+field)
                changed = copy.deepcopy(originals)
                changed[name]['deployedBytecode']['immutableReferences'] = {'1': [{'start': 1, 'length': 32}]}
                with self.assertRaises(ex.Gate) as caught: self.real_rebuild(changed)
                self.assertEqual(caught.exception.record['gate'], 'rebuild_'+name+'_immutableReferences')
            with patch.object(ex, 'committed_bytes', return_value=b'[profile.default]\nbytecode_hash="ipfs"\n'):
                with self.assertRaises(ex.Gate) as caught: self.real_rebuild(originals)
                self.assertEqual(caught.exception.record['gate'], 'rebuild_config')

    def test_compile_uses_offline_forge_default_profile_and_cleans_temp(self):
        locations = []
        def archive(repo, commit, tree):
            locations.append(tree); tree.mkdir(parents=True)
            (tree/'foundry.toml').write_text('[profile.default]\nbytecode_hash="none"\n')
        def run(args, **kwargs):
            self.assertEqual(args, [str(ex.REBUILD_FORGE), 'build', '--offline'])
            self.assertEqual(kwargs['env']['FOUNDRY_PROFILE'], 'default')
            self.assertNotIn('PRIVATE_KEY', kwargs['env'])
            self.assertNotIn('FOUNDRY_OPTIMIZER_RUNS', kwargs['env'])
            return SimpleNamespace(returncode=0)
        ex.compile_commit.cache_clear()
        try:
            with patch.object(ex, 'archive_commit', side_effect=archive), patch.object(ex.subprocess, 'run', side_effect=run), patch.object(ex, 'raw_artifact', return_value=self.metadata_artifact()), patch.dict(ex.os.environ, {'PRIVATE_KEY': 'must-not-be-copied', 'FOUNDRY_OPTIMIZER_RUNS': '1'}):
                artifacts, config = ex.compile_commit('a'*40, 'forge Version: 1.7.1')
            self.assertEqual(set(artifacts), set(ex.CONTRACT_NAMES))
            self.assertEqual(config['profile']['default']['bytecode_hash'], 'none')
            self.assertFalse(locations[0].exists())
            ex.compile_commit.cache_clear()
            with patch.object(ex, 'archive_commit', side_effect=archive), patch.object(ex.subprocess, 'run', return_value=SimpleNamespace(returncode=1)):
                with self.assertRaises(ex.Gate) as caught: ex.compile_commit('a'*40, 'forge Version: 1.7.1')
            self.assertEqual(caught.exception.record['gate'], 'rebuild_offline_build')
        finally: ex.compile_commit.cache_clear()

    def test_archive_includes_pinned_submodule_and_fails_without_local_objects(self):
        import tarfile
        def tar_bytes(filename):
            stream = io.BytesIO()
            with tarfile.open(fileobj=stream, mode='w') as archive:
                info = tarfile.TarInfo(filename); info.size = 1
                archive.addfile(info, io.BytesIO(b'x'))
            return stream.getvalue()
        with tempfile.TemporaryDirectory() as d:
            root, tree = Path(d)/'repo', Path(d)/'tree'
            (root/'vendor').mkdir(parents=True)
            commands = []
            def run(args, **kwargs):
                commands.append(args)
                if args[:2] == ['git', 'archive']:
                    kwargs['stdout'].write(tar_bytes('root.txt' if args[-1] == 'HEAD' else 'child.txt'))
                    return SimpleNamespace(returncode=0)
                if args[:2] == ['git', 'ls-tree']:
                    body = b'160000 commit '+b'c'*40+b'\tvendor\0' if args[-1] == 'HEAD' else b''
                    return SimpleNamespace(returncode=0, stdout=body)
                if args[:2] == ['git', 'rev-parse']:
                    return SimpleNamespace(returncode=0, stdout=str((root/'vendor').resolve())+'\n')
                raise AssertionError(args)
            with patch.object(ex.subprocess, 'run', side_effect=run): ex.archive_commit(root, 'HEAD', tree)
            self.assertTrue((tree/'root.txt').is_file())
            self.assertTrue((tree/'vendor/child.txt').is_file())
            self.assertIn(['git', 'archive', '--format=tar', 'c'*40], commands)
            def unavailable(args, **kwargs):
                if args[:2] == ['git', 'rev-parse']:
                    return SimpleNamespace(returncode=0, stdout=str(root if args[-1] == '--show-toplevel' else root/'.git/modules/missing')+'\n')
                return run(args, **kwargs)
            with patch.object(ex.subprocess, 'run', side_effect=unavailable):
                with self.assertRaises(ex.Gate) as caught: ex.archive_commit(root, 'HEAD', Path(d)/'unavailable')
            self.assertEqual(caught.exception.record['gate'], 'rebuild_submodule_unavailable')
            with patch.object(ex.subprocess, 'run', return_value=SimpleNamespace(returncode=1)):
                with self.assertRaises(ex.Gate) as caught: ex.archive_commit(root, 'missing', Path(d)/'missing')
            self.assertEqual(caught.exception.record['gate'], 'rebuild_archive_unavailable')

    def test_ipfs_hash_against_local_solc_0833_fixture(self):
        # Produced offline by solc 0.8.33 --standard-json, with bytecodeHash=ipfs.
        raw = '{"compiler":{"version":"0.8.33+commit.64118f21"},"language":"Solidity","output":{"abi":[],"devdoc":{"kind":"dev","methods":{},"version":1},"userdoc":{"kind":"user","methods":{},"version":1}},"settings":{"compilationTarget":{"M.sol":"M"},"evmVersion":"osaka","libraries":{},"metadata":{"bytecodeHash":"ipfs"},"optimizer":{"enabled":false,"runs":200},"remappings":[]},"sources":{"M.sol":{"keccak256":"0x4aca627d5b2516cfd8f06ee4ac9cfc1717b39f8f0224580c97218c77964e91e6","license":"MIT","urls":["bzz-raw://26e78cca05948211a4d461586c485876ec2d07405a7e795ea969f9628cae46dc","dweb:/ipfs/QmdVexbdM3n83tavFHjs6ADkqcBKUcZGDWGSnJLD7axX6d"]}},"version":1}'
        code = '0x60806040525f5ffdfea26469706673582212209d3673dbc408ad40801133549f64e2dc83a27f054695d6db3e6324818e8a81e464736f6c63430008210033'
        result = ex.metadata_identity({'rawMetadata': raw, 'deployedBytecode': {'object': code}},
                                      {'profile': {'default': {'bytecode_hash': 'ipfs'}}})
        self.assertEqual(result['mode'], 'ipfs')

    def test_rebuild_rejects_any_forge_version_other_than_171(self):
        def run(args, **kwargs):
            return SimpleNamespace(returncode=0, stdout='a'*40+'\n' if args[0] == 'git' else 'forge Version: 1.8.7-nightly\n')
        with patch.object(ex.subprocess, 'run', side_effect=run), patch.object(ex, 'compile_commit', side_effect=AssertionError('version gate first')):
            with self.assertRaises(ex.Gate) as caught: self.real_rebuild({})
        self.assertEqual(caught.exception.record['gate'], 'rebuild_forge_version')


if __name__ == '__main__':
    unittest.main(verbosity=2)
