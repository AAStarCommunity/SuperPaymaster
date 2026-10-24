#!/usr/bin/env python3
"""Offline JSON-RPC adversarial controls; no archive connection or local listener needed."""
import contextlib
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
                v = dict(current=dict(activationTime=ex.ACTIVATION, forkId=ex.FORK_ID))
                if case == 'activation':
                    v['current']['activationTime'] += 1
                if case == 'fork':
                    v['current']['forkId'] = '0x00000000'
            elif m == 'eth_getBlockByNumber':
                v = dict(number=p[0], hash='0x'+'ab'*32, timestamp=hex(ex.ACTIVATION+1))
            elif m == 'eth_getTransactionCount':
                v = hex(12132 if case == 'nonce' and p[1] == 'pending' else 12131)
            elif m == 'eth_getCode':
                v = '0x6000' if case == 'code' else '0x'
            elif m == 'eth_getBalance':
                v = '0x0' if case == 'balance' else hex(10**20)
            elif m == 'eth_call':
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

    @staticmethod
    def calibration(remote, plan, out, calibrate=False):
        # Isolate the live rehearsal boundary; preflight/ABI/CREATE/EIP-712, CLI,
        # budget, serialization and hashing remain real in this test.
        counters = {ex.DEPLOYER: 12131, ex.APPROVER: 7, ex.EXECUTOR: 28}
        for step in plan['steps']:
            tx = step['tx']
            tx['nonce'] = hex(counters[tx['from']])
            counters[tx['from']] += 1
            step['estimateGas'], step['forkGasUsed'] = 100000, 110000
            tx['gas'] = hex(143000)
        return {'status': 'PASS'}

    def run_plan(self, case='valid'):
        with tempfile.TemporaryDirectory() as d:
            out = Path(d)/'output'
            rpc_file = Path(d)/'rpc'
            rpc_file.write_text('https://secret.invalid/NEVER_PRINT_THIS')
            stdout, stderr = io.StringIO(), io.StringIO()
            with patch.object(ex.urllib.request, 'urlopen', self.mock_urlopen(case)), \
                    patch.object(ex, 'artifact', self.artifact), \
                    patch.object(ex, 'rehearse', self.calibration), \
                    contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                code = ex.main(['plan', '--rpc-file', str(rpc_file), '--block', BLOCK, '--out', str(out)])
            failure = json.loads((out/'FAILURE.json').read_text()) if (out/'FAILURE.json').exists() else None
            self.assertNotIn('NEVER_PRINT_THIS', stdout.getvalue()+stderr.getvalue()+str(failure))
            if code == 0:
                p = ex.load_plan(out/'plan.json')
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
                 'threshold': 'safe_threshold', 'owners': 'safe_owners'}
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

    def test_predecessor_must_pass_readback(self):
        order = ex.StepOrder()
        step = {'id': 'S4', 'tx': {'data': '0xab'}}
        for completed in ([], ['S1'], ['S1', 'S2']):
            order.completed = completed
            with self.assertRaises(ex.Gate) as caught:
                order.prepare(step)
            self.assertEqual(caught.exception.record['gate'], 'step_predecessor_S4')
        order.completed = ['S1', 'S2', 'S3']
        self.assertEqual(order.prepare(step), step['tx'])
        self.assertEqual(order.completed, ['S1', 'S2', 'S3'])
        order.passed('S4')
        self.assertEqual(order.completed[-1], 'S4')
        with self.assertRaises(ex.Gate):
            order.prepare(step)  # replay also rejected

    def test_archive_refuses_mutations(self):
        with patch.object(ex.urllib.request, 'urlopen', side_effect=AssertionError('must not connect')):
            for method in ('eth_sendTransaction', 'eth_sendRawTransaction', 'anvil_setBalance'):
                with self.assertRaises(ex.Gate) as caught:
                    ex.RPC('https://unused')(method, [])
                self.assertEqual(caught.exception.record['gate'], 'remote_read_only')

    def test_revert_requires_exact_bytes_and_unchanged_nonces(self):
        tx = {'from': ex.DEPLOYER, 'to': ex.SAFE, 'data': '0x00'}
        def rpc(method, params, error_ok=False):
            self.assertEqual(method, 'eth_call')
            return {'revert': '0xabcd'}
        with patch.object(ex, 'nonce', return_value=7), patch.object(ex, 'word', return_value=1):
            self.assertEqual(ex.negative(rpc, tx, '0xabcd', 'test')['nonces'], [7, 1])
            with self.assertRaises(ex.Gate) as caught:
                ex.negative(rpc, tx, '0xab', 'test')
            self.assertEqual(caught.exception.record['gate'], 'negative_test_reason')
        with patch.object(ex, 'nonce', side_effect=[7, 8]), patch.object(ex, 'word', return_value=1):
            with self.assertRaises(ex.Gate) as caught:
                ex.negative(rpc, tx, '0xabcd', 'test')
            self.assertEqual(caught.exception.record['gate'], 'negative_test_nonces')

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
        self.assertEqual(ex.roles_readback(rpc, plan, '0x2'), plan['roles'])
        logs.append(dict(logs[0], logIndex='0x4', topics=[granted, ex.ZERO32, abi_word(ex.DEPLOYER), abi_word(ex.DEPLOYER)]))
        with self.assertRaises(ex.Gate) as caught:
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
        plan = {'pin': {'balance': 100}, 'steps': [
            {'tx': {'from': ex.DEPLOYER, 'gas': '0xa', 'maxFeePerGas': '0xb'}},
            {'tx': {'from': ex.EXECUTOR, 'gas': '0xff', 'maxFeePerGas': '0xff'}}]}
        with self.assertRaises(ex.Gate) as caught:
            ex.budget(plan)
        self.assertEqual(caught.exception.record['gate'], 'deployer_budget')
        plan['pin']['balance'] = 110
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


if __name__ == '__main__':
    unittest.main(verbosity=2)
