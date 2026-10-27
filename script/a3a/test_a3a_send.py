#!/usr/bin/env python3
"""Offline tests for a3a_send.py. Nothing reaches a network.

Signing and decoding are real: a wrapper stands in for `cast`, rewrites `--account <name>` into the public anvil
test key #0 and records argv and environment, so the exact command a3a_send builds is executed and its signed
bytes are decoded by the real `cast decode-transaction`. The plan gate (signing_transaction), the RPC and the
broadcast are fakes.
"""
import copy, json, os, shutil, stat, subprocess, sys, tempfile, unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import a3a_exec as ex  # noqa: E402
import a3a_send as sd  # noqa: E402

REAL_CAST = shutil.which('cast') or str(Path.home()/'.foundry/bin/cast')
REAL_RUN = subprocess.run
ANVIL_KEY = '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80'  # public anvil test key #0
ANVIL_ADDR = '0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266'
SHA = 'ab' * 32
TX = {'chainId': '0xaa36a7', 'from': ANVIL_ADDR, 'to': '0x51edf11fdb0a4f66220efb8efa54eca77232e114',
      'data': '0xd4d9bdcd65f033abab61bfd4b3dd915e34a5a5aee635c6c90c6add2d2b58d6b48c6cd2a0', 'nonce': '0x7',
      'gas': '0x2b974', 'maxFeePerGas': '0x4a817c800', 'maxPriorityFeePerGas': '0x5f5e100', 'value': '0x0'}
PLAN = {'pin': {'block': '0xb70983', 'senders': {'approver': {'address': ANVIL_ADDR}, 'deployer': {'address': '0x' + '11' * 20},
                                                 'executor': {'address': '0x' + '22' * 20}}},
        'steps': [{'id': s} for s in ex.STEP_IDS]}

WRAPPER = r'''#!/usr/bin/env python3
import json, os, sys
argv = sys.argv[1:]
with open(os.environ['A3A_TEST_LOG'], 'a') as f:
    f.write(json.dumps({'argv': argv, 'env': sorted(os.environ)}) + '\n')
if '--account' in argv:
    i = argv.index('--account')
    argv[i:i + 2] = ['--private-key', os.environ['A3A_TEST_KEY']]
os.execv(os.environ['A3A_TEST_CAST'], [os.environ['A3A_TEST_CAST']] + argv)
'''


def keccak(data):
    return subprocess.run([REAL_CAST, 'keccak', data], capture_output=True, text=True, check=True).stdout.strip()


class Chain:
    def __init__(self, base_fee=10**9):
        self.base_fee, self.mined, self.receipt = base_fee, None, None

    def __call__(self, method, params):
        if method == 'web3_sha3':
            return keccak(params[0])
        if method == 'eth_getBlockByNumber':
            return {'baseFeePerGas': hex(self.base_fee)}
        if method == 'eth_getTransactionReceipt':
            return self.receipt
        if method == 'eth_getTransactionByHash':
            return self.mined
        raise AssertionError('unexpected RPC ' + method)


class SenderTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        d = Path(self.tmp.name)
        wrapper = d / 'cast'
        wrapper.write_text(WRAPPER)
        wrapper.chmod(wrapper.stat().st_mode | stat.S_IEXEC)
        self.log = d / 'cast.log'
        (d / 'plan.json').write_text('{}')
        (d / 'accounts.json').write_text(json.dumps({'approver': 'aastar-approver'}))
        self.args = mock.Mock(plan=d / 'plan.json', reviewed_plan_sha256=SHA, step='S5a',
                              accounts=d / 'accounts.json', out=d / 'out')
        self.args.out.mkdir()
        self.patches = [
            mock.patch.object(sd, 'CAST', str(wrapper)),
            mock.patch.dict(os.environ, {'A3A_TEST_LOG': str(self.log), 'A3A_TEST_KEY': ANVIL_KEY,
                                         'A3A_TEST_CAST': REAL_CAST, 'ETH_RPC_URL': 'https://secret.invalid/KEY'}),
            mock.patch.object(sd, 'SIGNER_ENV', None),  # replaced per test below
            mock.patch.object(ex, 'plan_json', lambda raw: copy.deepcopy(PLAN)),
        ]
        for p in self.patches:
            p.start()
        # The signer env must carry the wrapper's test variables, but nothing RPC-related.
        sd.SIGNER_ENV = {k: v for k, v in os.environ.items() if k in ('HOME', 'PATH') or k.startswith('A3A_TEST_')}
        self.gate_calls, self.sent = [], []

    def tearDown(self):
        for p in reversed(self.patches):
            p.stop()
        self.tmp.cleanup()

    def gate(self, txs):
        seq = iter(txs)
        def signing_transaction(plan, sha, sid, remote):
            self.gate_calls.append(sid)
            nxt = next(seq)
            if isinstance(nxt, ex.Gate):
                raise nxt
            return copy.deepcopy(nxt)
        return mock.patch.object(ex, 'signing_transaction', signing_transaction)

    def broadcast(self, chain, returned=None, status='0x1', mined_edit=None, gas_used=135104):
        def fake(url, raw):
            self.sent.append(raw)
            h = keccak(raw)
            chain.receipt = {'status': status, 'gasUsed': hex(gas_used), 'blockNumber': hex(12000000), 'transactionHash': h}
            mined = {k: TX[k] for k in ('nonce', 'gas', 'maxFeePerGas', 'maxPriorityFeePerGas', 'value', 'from', 'to')}
            mined['input'] = TX['data']
            if mined_edit:
                mined_edit(mined)
            chain.mined = mined
            return returned or h
        return mock.patch.object(sd, 'broadcast', fake)

    def phrase(self):
        return 'SEND S5a ' + SHA[:12]

    def run_send(self, chain, txs=(TX, TX), confirm=None, **bk):
        with self.gate(txs), self.broadcast(chain, **bk):
            return sd.run(self.args, chain, 'https://secret.invalid/KEY', confirm=confirm or (lambda _: self.phrase()))

    def gate_name(self, fn):
        with self.assertRaises(ex.Gate) as c:
            fn()
        return c.exception.record['gate']

    def test_positive_sends_once_and_records(self):
        chain = Chain()
        result = self.run_send(chain)
        self.assertEqual(result['status'], 'SENT')
        self.assertEqual(len(self.sent), 1)
        self.assertEqual(self.gate_calls, ['S5a', 'S5a'])
        for f in ('unsigned.json', 'signed.raw', 'decoded.json', 'receipt.json', 'result.json'):
            self.assertTrue((self.args.out / f).exists(), f)
        calls = [json.loads(l) for l in self.log.read_text().splitlines()]
        mktx = next(c for c in calls if c['argv'][0] == 'mktx')
        self.assertIn('--account', mktx['argv'])
        self.assertEqual(mktx['argv'][mktx['argv'].index('--account') + 1], 'aastar-approver')
        self.assertFalse(any('secret.invalid' in a for c in calls for a in c['argv']))
        self.assertFalse(any(k in ('ETH_RPC_URL', 'RPC_URL') for c in calls for k in c['env']))
        self.assertNotIn('secret.invalid', ''.join(p.read_text() for p in self.args.out.iterdir()))

    def test_plan_gate_failure_signs_nothing(self):
        chain = Chain()
        self.assertEqual(self.gate_name(lambda: self.run_send(chain, txs=[ex.Gate('pre_send_nonce_S5a', 8, 7)])),
                         'pre_send_nonce_S5a')
        self.assertFalse(self.log.exists())
        self.assertEqual(self.sent, [])

    def test_signed_field_mismatch_is_refused(self):
        # The wrapper signs what it is told; corrupt one argv value at a time to stand in for a signer that
        # produced a different transaction than planned.
        for flag, value, gate in (('--nonce', '8', 'send_signed_nonce'), ('--gas-limit', '178549', 'send_signed_gas'),
                                  ('--gas-price', '20000000001', 'send_signed_maxFeePerGas'),
                                  ('--priority-gas-price', '100000001', 'send_signed_maxPriorityFeePerGas'),
                                  ('--value', '1', 'send_signed_value'), ('--chain', '1', 'send_signed_chainId')):
            with self.subTest(flag=flag):
                real = sd.sign
                def corrupt(tx, account, flag=flag, value=value):
                    with mock.patch.object(sd.subprocess, 'run', side_effect=lambda cmd, **kw: REAL_RUN(
                            [c if i == 0 or cmd[i - 1] != flag else value for i, c in enumerate(cmd)], **kw)):
                        return real(tx, account)
                with mock.patch.object(sd, 'sign', corrupt):
                    self.assertEqual(self.gate_name(lambda: self.run_send(Chain())), gate)
                self.assertEqual(self.sent, [])

    def test_wrong_key_is_refused(self):
        sd.SIGNER_ENV['A3A_TEST_KEY'] = '0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d'  # anvil #1
        self.assertEqual(self.gate_name(lambda: self.run_send(Chain())), 'send_signed_signer')
        self.assertEqual(self.sent, [])

    def test_hash_recomputed_by_node(self):
        class Lying(Chain):
            def __call__(self, method, params):
                return '0x' + '00' * 32 if method == 'web3_sha3' else super().__call__(method, params)
        self.assertEqual(self.gate_name(lambda: self.run_send(Lying())), 'send_signed_hash')
        self.assertEqual(self.sent, [])

    def test_state_change_between_checks_is_refused(self):
        moved = dict(TX, nonce='0x8')
        self.assertEqual(self.gate_name(lambda: self.run_send(Chain(), txs=[TX, moved])), 'send_tx_stable')
        self.assertEqual(self.sent, [])
        self.assertEqual(self.gate_name(lambda: self.run_send(Chain(), txs=[TX, ex.Gate('pre_send_pending_S5a', 9, 8)])),
                         'pre_send_pending_S5a')
        self.assertEqual(self.sent, [])

    def test_fee_cap_exceeded_is_refused(self):
        base = int(TX['maxFeePerGas'], 16) - int(TX['maxPriorityFeePerGas'], 16) + 1
        self.assertEqual(self.gate_name(lambda: self.run_send(Chain(base_fee=base))), 'send_fee_cap')
        self.assertEqual(self.sent, [])
        self.run_send(Chain(base_fee=base - 1))
        self.assertEqual(len(self.sent), 1)

    def test_operator_confirmation_must_be_exact(self):
        for typed in ('', 'SEND S5b ' + SHA[:12], 'SEND S5a ' + SHA[:11], 'yes'):
            with self.subTest(typed=typed):
                self.assertEqual(self.gate_name(lambda: self.run_send(Chain(), confirm=lambda _: typed)),
                                 'send_operator_confirmation')
                self.assertEqual(self.sent, [])

    def test_post_broadcast_checks(self):
        self.assertEqual(self.gate_name(lambda: self.run_send(Chain(), returned='0x' + '99' * 32)), 'send_returned_hash')
        self.assertEqual(self.gate_name(lambda: self.run_send(Chain(), status='0x0')), 'send_receipt_status')
        self.assertEqual(self.gate_name(lambda: self.run_send(Chain(), mined_edit=lambda m: m.__setitem__('input', '0x'))),
                         'send_mined_input')

    def test_role_needs_a_named_account(self):
        self.args.accounts.write_text(json.dumps({'deployer': 'x'}))
        self.assertEqual(self.gate_name(lambda: self.run_send(Chain())), 'send_account_named')
        self.assertFalse(self.log.exists())

    def test_sender_must_map_to_exactly_one_role(self):
        stranger = dict(TX, **{'from': '0x' + '33' * 20})
        self.assertEqual(self.gate_name(lambda: self.run_send(Chain(), txs=[stranger])), 'send_sender_role')
        twice = copy.deepcopy(PLAN)
        twice['pin']['senders']['deployer']['address'] = ANVIL_ADDR
        with mock.patch.object(ex, 'plan_json', lambda raw: copy.deepcopy(twice)):
            self.assertEqual(self.gate_name(lambda: self.run_send(Chain())), 'send_sender_role')
        self.assertFalse(self.log.exists())

    def test_signer_tool_failures(self):
        def fake_run(stdout, code, which):
            def run(cmd, **kw):
                if cmd[1] == which:
                    return subprocess.CompletedProcess(cmd, code, stdout=stdout, stderr='')
                return REAL_RUN(cmd, **kw)
            return run
        cases = (('mktx', '', 1, 'send_sign_exit'),
                 ('mktx', '0xf86c0785', 0, 'send_sign_output'),   # legacy (non type-2) encoding
                 ('mktx', '0x02zz', 0, 'send_sign_output'),
                 ('decode-transaction', '', 1, 'send_decode_exit'))
        for which, out, code, gate in cases:
            with self.subTest(gate=gate, out=out):
                with mock.patch.object(sd.subprocess, 'run', side_effect=fake_run(out, code, which)):
                    self.assertEqual(self.gate_name(lambda: self.run_send(Chain())), gate)
                self.assertEqual(self.sent, [])

    def test_authorization_list_is_refused(self):
        real = sd.decode
        def with_auth(raw):
            d = real(raw)
            d['authorizationList'] = [{'address': '0x' + '44' * 20}]
            return d
        with mock.patch.object(sd, 'decode', with_auth):
            self.assertEqual(self.gate_name(lambda: self.run_send(Chain())), 'send_signed_no_authorizations')
        self.assertEqual(self.sent, [])

    def test_receipt_gas_above_plan(self):
        self.assertEqual(self.gate_name(lambda: self.run_send(Chain(), gas_used=int(TX['gas'], 16) + 1)), 'send_receipt_gas')

    def test_mined_transaction_must_equal_plan(self):
        for k, v in (('nonce', '0x8'), ('gas', '0x1'), ('maxFeePerGas', '0x1'), ('maxPriorityFeePerGas', '0x1'),
                     ('value', '0x1'), ('from', '0x' + '55' * 20), ('to', '0x' + '66' * 20)):
            with self.subTest(field=k):
                self.assertEqual(self.gate_name(lambda: self.run_send(Chain(), mined_edit=lambda m: m.__setitem__(k, v))),
                                 'send_mined_' + k)

    def test_final_readback_only_after_s7(self):
        for step, expected in (('S5a', 0), ('S7', 1)):
            with self.subTest(step=step), mock.patch.object(ex, 'readback') as rb, \
                    mock.patch.object(ex, 'scheduled_eta', return_value=123) as eta:
                self.args.step = step
                self.sent.clear()
                for f in self.args.out.iterdir():
                    f.unlink()
                phrase = 'SEND %s %s' % (step, SHA[:12])
                self.run_send(Chain(), confirm=lambda _: phrase)
                self.assertEqual(rb.call_count, expected)
                if expected:
                    self.assertEqual(rb.call_args.args[2], PLAN['steps'][-1])
                    eta.assert_called_once()

    def test_receipt_timeout_does_not_resend(self):
        chain = Chain()
        with mock.patch.object(sd, 'RECEIPT_WAIT_SECONDS', 0.01), mock.patch.object(sd.time, 'sleep'), \
                self.gate([TX, TX]), mock.patch.object(sd, 'broadcast', lambda url, raw: (self.sent.append(raw), keccak(raw))[1]):
            with self.assertRaises(ex.Gate) as c:
                sd.run(self.args, chain, 'u', confirm=lambda _: self.phrase())
        self.assertEqual(c.exception.record['gate'], 'send_receipt_timeout')
        self.assertEqual(len(self.sent), 1)

    def test_broadcast_errors_never_print_the_url(self):
        url = 'https://secret.invalid/NEVER_PRINT_THIS'
        class Resp:
            def __init__(self, body): self.body = body
            def __enter__(self): return self
            def __exit__(self, *a): return False
            def read(self): return json.dumps(self.body).encode()
        cases = ((OSError('connect to ' + url), 'send_broadcast_transport'),
                 (Resp({'jsonrpc': '2.0', 'id': 1, 'error': {'code': -32000, 'message': url}}), 'send_broadcast_rejected'),
                 (Resp({'jsonrpc': '2.0', 'id': 1, 'result': None}), 'send_broadcast_rejected'))
        for outcome, gate in cases:
            with self.subTest(gate=gate):
                side = {'side_effect': outcome} if isinstance(outcome, Exception) else {'return_value': outcome}
                with mock.patch.object(sd.urllib.request, 'urlopen', **side):
                    with self.assertRaises(ex.Gate) as c:
                        sd.broadcast(url, '0x02')
                self.assertEqual(c.exception.record['gate'], gate)
                self.assertNotIn('NEVER_PRINT_THIS', json.dumps(c.exception.record))

    def test_cli_records_failure_and_refuses_nonempty_out(self):
        d = Path(self.tmp.name)
        rpc = d / 'rpc'
        rpc.write_text('https://secret.invalid/NEVER_PRINT_THIS')
        argv = ['--plan', str(self.args.plan), '--reviewed-plan-sha256', SHA, '--step', 'S1', '--rpc-file', str(rpc),
                '--accounts', str(self.args.accounts), '--out', str(d / 'cli')]
        with self.gate([ex.Gate('reviewed_plan_hash', 'x', SHA)]), mock.patch('sys.stdout'), mock.patch('sys.stderr'):
            self.assertEqual(sd.main(argv), 1)
            failure = json.loads((d / 'cli' / 'FAILURE.json').read_text())
            self.assertEqual((failure['gate'], failure['step']), ('reviewed_plan_hash', 'S1'))
            self.assertNotIn('NEVER_PRINT_THIS', json.dumps(failure))
        before = (d / 'cli' / 'FAILURE.json').read_bytes()
        with self.gate([TX]), mock.patch('sys.stdout'), mock.patch('sys.stderr'):
            self.assertEqual(sd.main(argv), 1)  # out now holds FAILURE.json: refused before any gate
        self.assertEqual(self.gate_calls, ['S1'])
        self.assertEqual((d / 'cli' / 'FAILURE.json').read_bytes(), before)


if __name__ == '__main__':
    unittest.main()
