#!/usr/bin/env python3
"""Offline tests for a3a_send.py. Nothing reaches a network.

Signing and decoding are real: a wrapper stands in for `cast`, rewrites `--account <name>` into the public anvil
test key #0 and records argv and environment. The wrapper's settings are baked into its own source, so the
production signer environment (a3a_send.signer_env) is used unmodified while the test environment carries RPC
secrets that must not reach it. The plan gate (signing_transaction), the RPC and the broadcast are fakes, except
in the S7 integration test, which runs the real gate and readback against test_a3a_exec.FakeChain.
"""
import copy, fcntl, hashlib, io, json, os, shutil, stat, subprocess, sys, tempfile, unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import a3a_exec as ex  # noqa: E402
import a3a_send as sd  # noqa: E402

REAL_CAST = shutil.which('cast') or str(Path.home()/'.foundry/bin/cast')
REAL_RUN = subprocess.run
ANVIL_KEY = '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80'  # public anvil test key #0
ANVIL_KEY_1 = '0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d'  # public anvil test key #1
ANVIL_ADDR = '0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266'
SECRET = 'https://secret.invalid/NEVER_PRINT_THIS'
TX = {'chainId': '0xaa36a7', 'from': ANVIL_ADDR, 'to': '0x51edf11fdb0a4f66220efb8efa54eca77232e114',
      'data': '0xd4d9bdcd65f033abab61bfd4b3dd915e34a5a5aee635c6c90c6add2d2b58d6b48c6cd2a0', 'nonce': '0x7',
      'gas': '0x2b974', 'maxFeePerGas': '0x4a817c800', 'maxPriorityFeePerGas': '0x5f5e100', 'value': '0x0'}
CREATE = dict(TX, to=None, data='0x6080604052348015600e575f80fd5b50', nonce='0x2f63', gas='0xb8a36e')
PLAN = {'pin': {'block': '0xb70983', 'senders': {'approver': {'address': ANVIL_ADDR}, 'deployer': {'address': '0x' + '11' * 20},
                                                 'executor': {'address': '0x' + '22' * 20}}},
        'steps': [{'id': s} for s in ex.STEP_IDS]}
PLAN_BYTES = json.dumps(PLAN, sort_keys=True).encode()
SHA = hashlib.sha256(PLAN_BYTES).hexdigest()

WRAPPER = r'''#!/usr/bin/env python3
import json, os, sys
cfg = json.load(open(%r))
argv = sys.argv[1:]
with open(cfg['log'], 'a') as f:
    f.write(json.dumps({'argv': argv, 'env': dict(os.environ)}) + '\n')
if '--account' in argv:
    i = argv.index('--account')
    argv[i:i + 2] = ['--private-key', cfg['key']]
os.execv(cfg['cast'], [cfg['cast']] + argv)
'''


def cause(e):
    """Gate name, or for send_after_broadcast its cause, after checking the wrapper names the hash."""
    rec = e.record
    if rec['gate'] != 'send_after_broadcast':
        return rec['gate']
    assert ex.HASH32.fullmatch(rec['observed']['hash']), rec
    assert rec['observed']['broadcast'] in ('accepted', 'accepted_hash_mismatch', 'unknown'), rec
    return rec['observed']['cause']


def keccak(data):
    return REAL_RUN([REAL_CAST, 'keccak', data], capture_output=True, text=True, check=True).stdout.strip()


class Chain:
    """Fake provider. Records every call so a test can prove signed bytes never reached it before broadcast."""
    def __init__(self, base_fee=10**9):
        self.base_fee, self.mined, self.receipt, self.calls = base_fee, None, None, []

    def __call__(self, method, params):
        self.calls.append((method, json.dumps(params)))
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
        d = self.d = Path(self.tmp.name)
        self.cfg = d / 'wrapper.json'
        self.log = d / 'cast.log'
        self.cfg.write_text(json.dumps({'log': str(self.log), 'key': ANVIL_KEY, 'cast': REAL_CAST}))
        wrapper = d / 'cast'
        wrapper.write_text(WRAPPER % str(self.cfg))
        wrapper.chmod(wrapper.stat().st_mode | stat.S_IEXEC)
        (d / 'plan.json').write_bytes(PLAN_BYTES)
        (d / 'accounts.json').write_text(json.dumps({'approver': 'aastar-approver', 'deployer': 'aastar-deployer'}))
        self.args = mock.Mock(plan=d / 'plan.json', reviewed_plan_sha256=SHA, step='S5a',
                              accounts=d / 'accounts.json', out=d / 'out')
        self.args.out.mkdir()
        self.patches = [
            mock.patch.object(sd, 'CAST', str(wrapper)),
            mock.patch.object(sd, 'LOCK_PATH', d / 'send.lock'),
            # Secrets present in the operator's environment must not reach cast.
            mock.patch.dict(os.environ, {'ETH_RPC_URL': SECRET, 'RPC_A': SECRET, 'SEPOLIA_RPC': SECRET}),
            mock.patch.object(ex, 'plan_json', lambda raw: json.loads(raw)),
        ]
        for p in self.patches:
            p.start()
        self.events, self.sent = [], []
        self.out_dir = self.args.out  # where the broadcast helper asserts that no signature is on disk yet

    def tearDown(self):
        for p in reversed(self.patches):
            p.stop()
        self.tmp.cleanup()

    def clear_out(self):
        for f in self.args.out.iterdir():
            f.unlink()
        self.sent.clear()
        self.events.clear()

    def set_key(self, key):
        cfg = json.loads(self.cfg.read_text())
        cfg['key'] = key
        self.cfg.write_text(json.dumps(cfg))

    def gate(self, txs):
        seq = iter(txs)
        def signing_transaction(plan, sha, sid, remote):
            self.events.append(('gate', sid, Path(plan).read_bytes()))
            nxt = next(seq)
            if isinstance(nxt, ex.Gate):
                raise nxt
            return copy.deepcopy(nxt)
        return mock.patch.object(ex, 'signing_transaction', signing_transaction)

    def broadcast(self, chain, tx, returned=None, status='0x1', mined_edit=None, gas_used=135104, receipt_edit=None):
        def fake(url, raw):
            self.assertFalse((self.out_dir / 'signed.raw').exists(), 'signed bytes on disk before broadcast')
            self.events.append(('broadcast',))
            self.sent.append(raw)
            h = keccak(raw)
            chain.receipt = {'status': status, 'gasUsed': hex(gas_used), 'blockNumber': hex(12000000), 'transactionHash': h,
                             'blockHash': '0x' + '12' * 32, 'contractAddress': None, 'logs': [], 'providerExtra': SECRET}
            mined = {k: tx[k] for k in ('nonce', 'gas', 'maxFeePerGas', 'maxPriorityFeePerGas', 'value', 'from', 'to')}
            mined['input'] = tx['data']
            if receipt_edit:
                receipt_edit(chain.receipt)
            if mined_edit:
                mined_edit(mined)
            chain.mined = mined
            return returned or h
        return mock.patch.object(sd, 'broadcast', fake)

    def phrase(self):
        return 'SEND %s %s' % (self.args.step, SHA[:12])

    def confirm(self, typed=None):
        def c(_):
            self.events.append(('confirm',))
            return self.phrase() if typed is None else typed
        return c

    def run_send(self, chain, txs=(TX, TX), confirm=None, tx=TX, **bk):
        with self.gate(txs), self.broadcast(chain, tx, **bk):
            return sd.run(self.args, chain, SECRET, confirm=confirm or self.confirm())

    def gate_name(self, fn):
        """The failing gate; for a failure after broadcast, the wrapped cause (the wrapper itself is checked too)."""
        with self.assertRaises(ex.Gate) as c:
            fn()
        return cause(c.exception)

    def calls(self):
        return [json.loads(l) for l in self.log.read_text().splitlines()] if self.log.exists() else []

    def test_positive_order_and_records(self):
        result = self.run_send(Chain())
        self.assertEqual(result['status'], 'SENT')
        self.assertEqual(result['planSha256'], SHA)
        self.assertEqual(len(self.sent), 1)
        # gate, confirm, gate again, then broadcast: the recheck follows the confirmation pause.
        self.assertEqual([e[0] for e in self.events], ['gate', 'confirm', 'gate', 'broadcast'])
        for f in ('plan.reviewed.json', 'unsigned.json', 'signed.raw', 'decoded.json', 'receipt.json', 'result.json'):
            self.assertTrue((self.args.out / f).exists(), f)
        mktx = next(c for c in self.calls() if c['argv'][0] == 'mktx')
        self.assertEqual(mktx['argv'][mktx['argv'].index('--account') + 1], 'aastar-approver')
        for c in self.calls():
            self.assertFalse(any('secret.invalid' in a for a in c['argv']))
            self.assertFalse(set(c['env']) & {'ETH_RPC_URL', 'RPC_A', 'SEPOLIA_RPC'})
            self.assertNotIn('secret.invalid', json.dumps(c['env']))
        self.assertNotIn('secret.invalid', ''.join(p.read_text() for p in self.args.out.iterdir()))
        raw = self.sent[0]
        self.assertFalse(any(raw[4:] in a for c in self.calls() for a in c['argv']), 'signed bytes in argv')
        self.assertNotIn('providerExtra', json.loads((self.args.out / 'receipt.json').read_text()))
        self.assertFalse({'r', 's', 'v', 'yParity'} & set(json.loads((self.args.out / 'decoded.json').read_text())))

    def test_signed_bytes_reach_no_provider_before_broadcast(self):
        chain = Chain()
        self.run_send(chain)
        raw = self.sent[0]
        self.assertTrue(chain.calls)
        self.assertFalse(any(raw[4:] in params for _, params in chain.calls))

    def test_contract_creation_step(self):
        self.args.step = 'S2'
        self.run_send(Chain(), txs=(CREATE, CREATE), tx=CREATE)
        mktx = next(c for c in self.calls() if c['argv'][0] == 'mktx')
        self.assertEqual(mktx['argv'][mktx['argv'].index('--create') + 1], CREATE['data'])
        self.assertIsNone(json.loads((self.args.out / 'decoded.json').read_text())['to'])
        # A creation signed as a call must be refused before broadcast.
        self.clear_out()
        real = sd.sign
        with mock.patch.object(sd, 'sign', lambda tx, account: real(dict(CREATE, to='0x' + '77' * 20), account)):
            self.assertEqual(self.gate_name(lambda: self.run_send(Chain(), txs=(CREATE, CREATE), tx=CREATE)), 'send_signed_to')
        self.assertEqual(self.sent, [])
        # And a creation that was mined as a call is caught after it.
        self.clear_out()
        self.assertEqual(self.gate_name(lambda: self.run_send(Chain(), txs=(CREATE, CREATE), tx=CREATE,
                                                              mined_edit=lambda m: m.__setitem__('to', '0x' + '77' * 20))),
                         'send_mined_to')

    def test_plan_is_read_once(self):
        swapped = json.dumps(dict(PLAN, swapped=True)).encode()
        real_write = ex.write_json
        def swap_after_snapshot(path, data):
            self.args.plan.write_bytes(swapped)  # the original file is replaced right after the single read
            return real_write(path, data)
        with mock.patch.object(ex, 'write_json', swap_after_snapshot):
            result = self.run_send(Chain())
        self.assertEqual(result['planSha256'], SHA)
        self.assertTrue(all(e[2] == PLAN_BYTES for e in self.events if e[0] == 'gate'))
        self.assertEqual((self.args.out / 'plan.reviewed.json').read_bytes(), PLAN_BYTES)
        self.clear_out()
        self.assertEqual(self.gate_name(lambda: self.run_send(Chain())), 'reviewed_plan_hash')
        self.assertEqual(self.events, [])

    def test_plan_swapped_right_after_the_snapshot(self):
        swapped = json.dumps(dict(PLAN, swapped=True)).encode()
        real = Path.write_bytes
        def write_bytes(path, data):
            n = real(path, data)
            if path.name == 'plan.reviewed.json':
                real(self.args.plan, swapped)  # replaced before the first gate reads anything
            return n
        with mock.patch.object(Path, 'write_bytes', write_bytes):
            self.run_send(Chain())
        gates = [e[2] for e in self.events if e[0] == 'gate']
        self.assertEqual(gates, [PLAN_BYTES, PLAN_BYTES])

    def test_plan_gate_failure_signs_nothing(self):
        self.assertEqual(self.gate_name(lambda: self.run_send(Chain(), txs=[ex.Gate('pre_send_nonce_S5a', 8, 7)])),
                         'pre_send_nonce_S5a')
        self.assertEqual(self.calls(), [])
        self.assertEqual(self.sent, [])

    def test_signed_field_mismatch_is_refused(self):
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
        self.set_key(ANVIL_KEY_1)
        self.assertEqual(self.gate_name(lambda: self.run_send(Chain())), 'send_signed_signer')
        self.assertEqual(self.sent, [])

    def test_decoded_hash_must_match_local_keccak(self):
        real = sd.decode
        with mock.patch.object(sd, 'decode', lambda raw: dict(real(raw), hash='0x' + '00' * 32)):
            self.assertEqual(self.gate_name(lambda: self.run_send(Chain())), 'send_signed_hash')
        self.assertEqual(self.sent, [])

    def test_recheck_after_confirmation(self):
        self.assertEqual(self.gate_name(lambda: self.run_send(Chain(), txs=[TX, dict(TX, nonce='0x8')])), 'send_tx_stable')
        self.assertEqual(self.sent, [])
        self.clear_out()
        self.assertEqual(self.gate_name(lambda: self.run_send(Chain(), txs=[TX, ex.Gate('pre_send_pending_S5a', 9, 8)])),
                         'pre_send_pending_S5a')
        self.assertEqual([e[0] for e in self.events], ['gate', 'confirm', 'gate'])
        self.assertEqual(self.sent, [])

    def test_fee_cap_checked_after_confirmation(self):
        base = int(TX['maxFeePerGas'], 16) - int(TX['maxPriorityFeePerGas'], 16) + 1
        self.assertEqual(self.gate_name(lambda: self.run_send(Chain(base_fee=base))), 'send_fee_cap')
        self.assertEqual(self.sent, [])
        self.assertEqual([e[0] for e in self.events], ['gate', 'confirm', 'gate'])
        self.clear_out()
        self.run_send(Chain(base_fee=base - 1))
        self.assertEqual(len(self.sent), 1)

    def test_operator_confirmation_must_be_exact(self):
        for typed in ('', 'SEND S5b ' + SHA[:12], 'SEND S5a ' + SHA[:11], 'yes'):
            with self.subTest(typed=typed):
                self.clear_out()
                self.assertEqual(self.gate_name(lambda: self.run_send(Chain(), confirm=self.confirm(typed))),
                                 'send_operator_confirmation')
                self.assertEqual(self.sent, [])
                self.assertEqual([e[0] for e in self.events], ['gate', 'confirm'])
                self.assertFalse((self.args.out / 'signed.raw').exists())

    def test_lock_is_taken_before_the_output_is_claimed(self):
        rpc = self.d / 'rpc'
        rpc.write_text(SECRET)
        out = self.d / 'locked'
        argv = ['--plan', str(self.args.plan), '--reviewed-plan-sha256', SHA, '--step', 'S5a', '--rpc-file', str(rpc),
                '--accounts', str(self.args.accounts), '--out', str(out)]
        with open(sd.LOCK_PATH, 'a') as held, mock.patch('sys.stdout'), mock.patch('sys.stderr'):
            fcntl.flock(held, fcntl.LOCK_EX)
            self.assertEqual(sd.main(argv), 1)
        self.assertFalse(out.exists())  # neither claimed nor written: no FAILURE.json in someone else's directory
        self.assertEqual(self.calls(), [])

    def test_cli_output_is_private(self):
        rpc = self.d / 'rpc'
        rpc.write_text(SECRET)
        out = self.d / 'private'
        out.mkdir(mode=0o755)  # a pre-existing empty directory must also end up private
        os.chmod(out, 0o755)
        self.out_dir = out
        argv = ['--plan', str(self.args.plan), '--reviewed-plan-sha256', SHA, '--step', 'S5a', '--rpc-file', str(rpc),
                '--accounts', str(self.args.accounts), '--out', str(out)]
        chain = Chain()
        old = os.umask(0o022)
        try:
            with self.gate([TX, TX]), self.broadcast(chain, TX), mock.patch.object(ex, 'RPC', lambda url: chain), \
                    mock.patch.object(sd, 'tty_confirm', lambda prompt: 'SEND S5a ' + SHA[:12]), mock.patch('sys.stdout'):
                self.assertEqual(sd.main(argv), 0)
        finally:
            os.umask(old)
        self.assertEqual(stat.S_IMODE(out.stat().st_mode), 0o700)
        for f in out.iterdir():
            self.assertEqual(stat.S_IMODE(f.stat().st_mode), 0o600, f.name)

    def test_provider_values_are_validated_before_use(self):
        receipt_cases = (('status', SECRET, 'send_provider_status'), ('transactionHash', SECRET, 'send_provider_transactionHash'),
                         ('gasUsed', SECRET, 'send_provider_gasUsed'), ('logs', [{'address': SECRET, 'topics': [], 'data': '0x'}],
                                                                         'send_provider_logAddress'))
        for k, v, gate in receipt_cases:
            with self.subTest(receipt=k):
                self.clear_out()
                with self.assertRaises(ex.Gate) as c:
                    self.run_send(Chain(), receipt_edit=lambda r, k=k, v=v: r.__setitem__(k, v))
                self.assertEqual(cause(c.exception), gate)
                self.assertNotIn('NEVER_PRINT_THIS', json.dumps(c.exception.record))
        for k, gate in (('from', 'send_provider_from'), ('to', 'send_provider_to'), ('input', 'send_provider_input'),
                        ('nonce', 'send_provider_nonce')):
            with self.subTest(mined=k):
                self.clear_out()
                with self.assertRaises(ex.Gate) as c:
                    self.run_send(Chain(), mined_edit=lambda m, k=k: m.__setitem__(k, SECRET))
                self.assertEqual(cause(c.exception), gate)
                self.assertNotIn('NEVER_PRINT_THIS', json.dumps(c.exception.record))
        self.clear_out()
        self.assertEqual(self.gate_name(lambda: self.run_send(Chain(), receipt_edit=lambda r: r.__setitem__('transactionHash', '0x' + '98' * 32))),
                         'send_receipt_hash')

    def test_post_broadcast_checks(self):
        chain = Chain()
        self.assertEqual(self.gate_name(lambda: self.run_send(chain, returned='0x' + '99' * 32)), 'send_returned_hash')
        # The provider reported another hash, but the signed transaction is still monitored and its receipt kept.
        self.assertIn('eth_getTransactionReceipt', [m for m, _ in chain.calls])
        self.assertTrue((self.args.out / 'receipt.json').exists())
        self.clear_out()
        self.assertEqual(self.gate_name(lambda: self.run_send(Chain(), status='0x0')), 'send_receipt_status')
        self.clear_out()
        self.assertEqual(self.gate_name(lambda: self.run_send(Chain(), gas_used=int(TX['gas'], 16) + 1)), 'send_receipt_gas')
        for k, v in (('nonce', '0x8'), ('gas', '0x1'), ('maxFeePerGas', '0x1'), ('maxPriorityFeePerGas', '0x1'),
                     ('value', '0x1'), ('from', '0x' + '55' * 20), ('to', '0x' + '66' * 20), ('input', '0x')):
            with self.subTest(field=k):
                self.clear_out()
                self.assertEqual(self.gate_name(lambda: self.run_send(Chain(), mined_edit=lambda m: m.__setitem__(k, v))),
                                 'send_mined_' + k)

    def test_sender_must_map_to_exactly_one_role(self):
        stranger = dict(TX, **{'from': '0x' + '33' * 20})
        self.assertEqual(self.gate_name(lambda: self.run_send(Chain(), txs=[stranger])), 'send_sender_role')
        twice = copy.deepcopy(PLAN)
        twice['pin']['senders']['deployer']['address'] = ANVIL_ADDR
        with mock.patch.object(ex, 'plan_json', lambda raw: copy.deepcopy(twice)):
            self.clear_out()
            self.assertEqual(self.gate_name(lambda: self.run_send(Chain())), 'send_sender_role')
        self.assertEqual(self.calls(), [])

    def test_role_needs_a_named_account(self):
        self.args.accounts.write_text(json.dumps({'deployer': 'x'}))
        self.assertEqual(self.gate_name(lambda: self.run_send(Chain())), 'send_account_named')
        self.assertEqual(self.calls(), [])

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
                 ('decode-transaction', '', 1, 'send_decode_exit'),
                 ('keccak', '', 1, 'send_keccak_exit'))
        for which, out, code, gate in cases:
            with self.subTest(gate=gate, out=out):
                self.clear_out()
                with mock.patch.object(sd.subprocess, 'run', side_effect=fake_run(out, code, which)):
                    self.assertEqual(self.gate_name(lambda: self.run_send(Chain())), gate)
                self.assertEqual(self.sent, [])

    def test_authorization_list_is_refused(self):
        real = sd.decode
        with mock.patch.object(sd, 'decode', lambda raw: dict(real(raw), authorizationList=[{'address': '0x' + '44' * 20}])):
            self.assertEqual(self.gate_name(lambda: self.run_send(Chain())), 'send_signed_no_authorizations')
        self.assertEqual(self.sent, [])

    def test_receipt_timeout_does_not_resend(self):
        with mock.patch.object(sd, 'RECEIPT_WAIT_SECONDS', 0.01), mock.patch.object(sd.time, 'sleep'), \
                self.gate([TX, TX]), mock.patch.object(sd, 'broadcast', lambda url, raw: (self.sent.append(raw), keccak(raw))[1]):
            with self.assertRaises(ex.Gate) as c:
                sd.run(self.args, Chain(), SECRET, confirm=self.confirm())
        self.assertEqual(cause(c.exception), 'send_receipt_timeout')
        self.assertEqual(len(self.sent), 1)

    def test_broadcast_records_nothing_the_provider_wrote(self):
        class Resp:
            def __init__(self, body): self.body = body
            def __enter__(self): return self
            def __exit__(self, *a): return False
            def read(self): return json.dumps(self.body).encode()
        cases = ((OSError('connect to ' + SECRET), 'send_broadcast_transport'),
                 (Resp({'jsonrpc': '2.0', 'id': 1, 'error': {'code': SECRET, 'message': SECRET}}), 'send_broadcast_rejected'),
                 (Resp({'jsonrpc': '2.0', 'id': 1, 'error': {'code': -32000, 'message': SECRET}}), 'send_broadcast_rejected'),
                 (Resp({'jsonrpc': '2.0', 'id': 1, 'result': SECRET}), 'send_broadcast_result'),
                 (Resp({'jsonrpc': '2.0', 'id': 1, 'result': None}), 'send_broadcast_result'))
        for outcome, gate in cases:
            with self.subTest(gate=gate, outcome=str(outcome)[:40]):
                side = {'side_effect': outcome} if isinstance(outcome, Exception) else {'return_value': outcome}
                with mock.patch.object(sd.urllib.request, 'urlopen', **side):
                    with self.assertRaises(ex.Gate) as c:
                        sd.broadcast(SECRET, '0x02')
                self.assertEqual(cause(c.exception), gate)
                self.assertNotIn('NEVER_PRINT_THIS', json.dumps(c.exception.record))

    def test_failure_record_carries_no_provider_text(self):
        rpc = self.d / 'rpc'
        rpc.write_text(SECRET)
        out = self.d / 'scrub'
        argv = ['--plan', str(self.args.plan), '--reviewed-plan-sha256', SHA, '--step', 'S5a', '--rpc-file', str(rpc),
                '--accounts', str(self.args.accounts), '--out', str(out)]
        # An inherited a3a_exec gate whose observed value is raw provider output (e.g. eth_getCode).
        leaks = [ex.Gate('pre_send_code_S5a', SECRET, 'deployed contract code'),
                 ex.Gate('pre_send_code_S5a', {'nested': [SECRET, 'NEVER_PRINT_THIS']}, 'x'),
                 ex.Gate('pre_send_code_S5a', '0x' + 'ab' * 200, 'x'),
                 ex.Gate('pre_send_code_S5a', 'NEVER_PRINT_THIS', 'x'),
                 ex.Gate('S5b_receipt_hash', '0x' + '12' * 32, SECRET),        # provider value in expected
                 ex.Gate('pre_send_code_S5a', {'NEVER_PRINT_THIS': 1}, {'NEVER_PRINT_THIS': None})]  # in dict keys
        for leak in leaks:
            with self.subTest(observed=str(leak.record['observed'])[:30]):
                shutil.rmtree(out, ignore_errors=True)
                with self.gate([leak]), mock.patch.object(ex, 'RPC', lambda url: Chain()), \
                        mock.patch('sys.stdout'), mock.patch('sys.stderr'):
                    self.assertEqual(sd.main(argv), 1)
                text = (out / 'FAILURE.json').read_text()
                self.assertNotIn('NEVER_PRINT_THIS', text)
                self.assertNotIn('secret.invalid', text)
                self.assertEqual(json.loads(text)['gate'], leak.record['gate'])
        # A key that is itself hex would pass the hex rule; the URL-token rule must still remove it.
        hex_key_url = 'https://eth-sepolia.example.invalid/v2/0a1b2c3d4e5f6a7b8c9d'
        self.assertEqual(sd.scrub('0x0a1b2c3d4e5f6a7b8c9d', hex_key_url), '<redacted 22 chars>')
        # Short hex (hashes, addresses, quantities) survives, so records stay useful.
        self.assertEqual(sd.scrub({'h': '0x' + 'cd' * 32, 'n': 7}, SECRET), {'h': '0x' + 'cd' * 32, 'n': 7})

    def test_failure_is_written_while_the_lock_is_held(self):
        rpc = self.d / 'rpc'
        rpc.write_text(SECRET)
        out = self.d / 'held'
        argv = ['--plan', str(self.args.plan), '--reviewed-plan-sha256', 'cd' * 32, '--step', 'S1', '--rpc-file', str(rpc),
                '--accounts', str(self.args.accounts), '--out', str(out)]
        real = ex.write_json
        def probe(path, data):
            with open(sd.LOCK_PATH, 'a') as other:
                with self.assertRaises(BlockingIOError):
                    fcntl.flock(other, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return real(path, data)
        with mock.patch.object(ex, 'write_json', probe), mock.patch('sys.stdout'), mock.patch('sys.stderr'):
            self.assertEqual(sd.main(argv), 1)
        self.assertTrue((out / 'FAILURE.json').exists())

    def test_cli_records_failure_and_refuses_nonempty_out(self):
        rpc = self.d / 'rpc'
        rpc.write_text(SECRET)
        out = self.d / 'cli'
        argv = ['--plan', str(self.args.plan), '--reviewed-plan-sha256', 'cd' * 32, '--step', 'S1', '--rpc-file', str(rpc),
                '--accounts', str(self.args.accounts), '--out', str(out)]
        with mock.patch('sys.stdout'), mock.patch('sys.stderr'):
            self.assertEqual(sd.main(argv), 1)
        failure = json.loads((out / 'FAILURE.json').read_text())
        self.assertEqual((failure['gate'], failure['step']), ('reviewed_plan_hash', 'S1'))
        self.assertNotIn('NEVER_PRINT_THIS', json.dumps(failure))
        before = (out / 'FAILURE.json').read_bytes()
        with mock.patch('sys.stdout'), mock.patch('sys.stderr'):
            self.assertEqual(sd.main(argv), 1)  # out now holds FAILURE.json: refused, and the record is kept
        self.assertEqual((out / 'FAILURE.json').read_bytes(), before)
        self.assertEqual(self.calls(), [])

    # --- review #546 follow-ups ---

    def test_after_broadcast_failures_name_the_hash(self):
        with self.assertRaises(ex.Gate) as c:
            self.run_send(Chain(), status='0x0')
        rec = c.exception.record
        self.assertEqual(rec['gate'], 'send_after_broadcast')
        self.assertEqual(rec['observed']['hash'], keccak(self.sent[0]))
        self.assertEqual(json.loads((self.args.out / 'broadcast.json').read_text()),
                         {'step': 'S5a', 'hash': keccak(self.sent[0]), 'outcome': 'accepted', 'provider': None})

    def test_local_error_after_broadcast_still_monitors_and_records(self):
        real = Path.write_text
        def write_text(path, data, *a, **kw):
            if path.name == 'signed.raw':
                raise OSError('disk full')
            return real(path, data, *a, **kw)
        with mock.patch.object(Path, 'write_text', write_text):
            result = self.run_send(Chain())
        self.assertEqual(result['status'], 'SENT')  # signed.raw is evidence only; monitoring went on
        self.assertTrue((self.args.out / 'receipt.json').exists())
        self.clear_out()
        with mock.patch.object(sd, 'check_mined', side_effect=KeyError('x')):
            with self.assertRaises(ex.Gate) as c:
                self.run_send(Chain())
        self.assertEqual((c.exception.record['gate'], cause(c.exception)), ('send_after_broadcast', 'local_error'))

    def test_broadcast_transport_failure_is_outcome_unknown_and_monitored(self):
        chain = Chain()
        def lost(url, raw):
            self.sent.append(raw)
            h = keccak(raw)  # the provider took it, but the reply never arrived
            chain.receipt = {'status': '0x1', 'gasUsed': hex(135104), 'blockNumber': hex(12000000), 'transactionHash': h,
                             'blockHash': '0x' + '12' * 32, 'contractAddress': None, 'logs': []}
            chain.mined = dict({k: TX[k] for k in ('nonce', 'gas', 'maxFeePerGas', 'maxPriorityFeePerGas', 'value', 'from', 'to')},
                               input=TX['data'])
            raise ex.Gate('send_broadcast_transport', 'TimeoutError', 'JSON-RPC response')
        with self.gate([TX, TX]), mock.patch.object(sd, 'broadcast', lost):
            result = sd.run(self.args, chain, SECRET, confirm=self.confirm())
        self.assertEqual((result['status'], result['broadcast']), ('SENT', 'unknown'))
        self.assertEqual(json.loads((self.args.out / 'broadcast.json').read_text())['outcome'], 'unknown')
        # Never mined: the failure says "unknown", with the hash to reconcile, not "not sent".
        self.clear_out()
        def lost_forever(url, raw):
            self.sent.append(raw)
            raise ex.Gate('send_broadcast_transport', 'TimeoutError', 'JSON-RPC response')
        with self.gate([TX, TX]), mock.patch.object(sd, 'broadcast', lost_forever), \
                mock.patch.object(sd, 'RECEIPT_WAIT_SECONDS', 0.01), mock.patch.object(sd.time, 'sleep'):
            with self.assertRaises(ex.Gate) as c:
                sd.run(self.args, Chain(), SECRET, confirm=self.confirm())
        obs = c.exception.record['observed']
        self.assertEqual((obs['broadcast'], obs['cause'], obs['hash']), ('unknown', 'send_receipt_timeout', keccak(self.sent[0])))
        # An error reply ("already known", ...) or a malformed reply does not prove the transaction was not taken:
        # it is outcome unknown too, monitored by hash, with the provider's code kept as the reason.
        for gate, observed in (('send_broadcast_rejected', -32000), ('send_broadcast_result', 'malformed')):
            with self.subTest(provider=gate):
                self.clear_out()
                chain = Chain()
                def refused(url, raw, gate=gate, observed=observed):
                    self.sent.append(raw)
                    raise ex.Gate(gate, observed, 'transaction hash')
                with self.gate([TX, TX]), mock.patch.object(sd, 'broadcast', refused), \
                        mock.patch.object(sd, 'RECEIPT_WAIT_SECONDS', 0.01), mock.patch.object(sd.time, 'sleep'):
                    with self.assertRaises(ex.Gate) as c:
                        sd.run(self.args, chain, SECRET, confirm=self.confirm())
                obs = c.exception.record['observed']
                self.assertEqual((obs['broadcast'], obs['provider'], obs['hash']),
                                 ('unknown', {'gate': gate, 'observed': observed}, keccak(self.sent[0])))
                self.assertIn('eth_getTransactionReceipt', [m for m, _ in chain.calls])

    def test_broadcast_has_a_total_deadline(self):
        import threading, time as _t
        release = threading.Event()
        def hang(*a, **kw):
            release.wait(5)
            raise OSError('late')
        try:
            with mock.patch.object(ex, 'RPC_TOTAL_DEADLINE_SECONDS', 0.2), \
                    mock.patch.object(sd.urllib.request, 'urlopen', side_effect=hang):
                t0 = _t.monotonic()
                with self.assertRaises(ex.Gate) as c:
                    sd.broadcast(SECRET, '0x02')
                elapsed = _t.monotonic() - t0
        finally:
            release.set()
        self.assertEqual(c.exception.record['gate'], 'send_broadcast_transport')
        self.assertLess(elapsed, 2)

    def test_receipt_polling_tolerates_transient_rpc_failures(self):
        class Flaky(Chain):
            def __init__(self, fails):
                super().__init__()
                self.fails = fails
            def __call__(self, method, params):
                if method == 'eth_getTransactionReceipt' and self.fails:
                    self.fails -= 1
                    raise ex.Gate('rpc_transport', 'TimeoutError', 'valid response (URL redacted)')
                return super().__call__(method, params)
        with mock.patch.object(sd.time, 'sleep'):
            self.assertEqual(self.run_send(Flaky(sd.RECEIPT_TRANSIENT_MAX))['status'], 'SENT')
            self.clear_out()
            self.assertEqual(self.gate_name(lambda: self.run_send(Flaky(sd.RECEIPT_TRANSIENT_MAX + 1))), 'send_receipt_rpc')

    def test_access_list_must_be_empty(self):
        real = sd.decode
        with mock.patch.object(sd, 'decode', lambda raw: dict(real(raw), accessList=[{'address': '0x' + '44' * 20, 'storageKeys': []}])):
            self.assertEqual(self.gate_name(lambda: self.run_send(Chain())), 'send_signed_accessList')
        self.assertEqual(self.sent, [])

    def test_log_topics_are_validated(self):
        bad = [{'address': '0x' + '55' * 20, 'topics': [SECRET], 'data': '0x'}]
        with self.assertRaises(ex.Gate) as c:
            self.run_send(Chain(), receipt_edit=lambda r: r.__setitem__('logs', bad))
        self.assertEqual(cause(c.exception), 'send_provider_logTopic')
        self.assertNotIn('NEVER_PRINT_THIS', json.dumps(c.exception.record))

    def test_decoded_json_is_an_allowlist(self):
        real = sd.decode
        with mock.patch.object(sd, 'decode', lambda raw: dict(real(raw), extra=SECRET)):
            self.run_send(Chain())
        decoded = json.loads((self.args.out / 'decoded.json').read_text())
        self.assertEqual(sorted(decoded), sorted(sd.DECODED_FIELDS))

    def test_confirmation_needs_a_terminal(self):
        with mock.patch('builtins.open', side_effect=OSError('no tty')):
            with self.assertRaises(ex.Gate) as c:
                sd.tty_confirm('x')
        self.assertEqual(c.exception.record['gate'], 'send_no_tty')
        # run() without an injected confirm uses the terminal reader.
        with mock.patch.object(sd, 'tty_confirm', side_effect=ex.Gate('send_no_tty', 'x', 'y')), \
                self.gate([TX, TX]), self.broadcast(Chain(), TX):
            with self.assertRaises(ex.Gate) as c:
                sd.run(self.args, Chain(), SECRET)
        self.assertEqual(c.exception.record['gate'], 'send_no_tty')
        self.assertEqual(self.sent, [])
    def test_attempt_record_precedes_transmission(self):
        real = ex.write_json
        def fail_attempt(path, data):
            if path.name == 'broadcast.json':
                raise OSError('disk full')
            return real(path, data)
        with mock.patch.object(ex, 'write_json', fail_attempt):
            with self.assertRaises(OSError):
                self.run_send(Chain())
        self.assertEqual(self.sent, [])  # the attempt could not be recorded, so nothing was transmitted

    def test_evidence_writes_after_broadcast_never_stop_monitoring(self):
        real = ex.write_json
        calls = []
        def fail_after(path, data):
            calls.append(path.name)
            if path.name == 'broadcast.json' and calls.count('broadcast.json') > 1:
                raise OSError('disk full')
            if path.name in ('receipt.json', 'result.json'):
                raise OSError('disk full')
            return real(path, data)
        chain = Chain()
        with mock.patch.object(ex, 'write_json', fail_after), mock.patch('sys.stderr'):
            result = self.run_send(chain)
        self.assertEqual(result['status'], 'SENT')
        self.assertIn('eth_getTransactionReceipt', [m for m, _ in chain.calls])

    def test_failure_record_falls_back_to_stderr(self):
        rpc = self.d / 'rpc'
        rpc.write_text(SECRET)
        out = self.d / 'fallback'
        argv = ['--plan', str(self.args.plan), '--reviewed-plan-sha256', SHA, '--step', 'S5a', '--rpc-file', str(rpc),
                '--accounts', str(self.args.accounts), '--out', str(out)]
        real = ex.write_json
        def no_failure_file(path, data):
            if path.name == 'FAILURE.json':
                raise OSError('disk full')
            return real(path, data)
        err = io.StringIO()
        chain = Chain()
        with self.gate([TX, TX]), self.broadcast(chain, TX, status='0x0'), mock.patch.object(ex, 'RPC', lambda url: chain), \
                mock.patch.object(sd, 'tty_confirm', lambda prompt: 'SEND S5a ' + SHA[:12]), \
                mock.patch.object(ex, 'write_json', no_failure_file), mock.patch('sys.stdout'), mock.patch('sys.stderr', err):
            self.assertEqual(sd.main(argv), 1)
        self.assertIn(keccak(self.sent[0]), err.getvalue())
        self.assertNotIn('NEVER_PRINT_THIS', err.getvalue())

    def test_tty_confirmation_on_a_real_pty(self):
        import pty, threading
        master, slave = pty.openpty()
        try:
            with mock.patch.object(sd, 'TTY_PATH', os.ttyname(slave)):
                got = {}
                t = threading.Thread(target=lambda: got.setdefault('line', sd.tty_confirm('Type it: ')), daemon=True)
                t.start()
                import select, time as _t
                prompt, deadline = b'', _t.monotonic() + 5
                while not prompt.endswith(b'Type it: ') and _t.monotonic() < deadline:
                    if select.select([master], [], [], 0.1)[0]:
                        prompt += os.read(master, 64)
                self.assertTrue(prompt.endswith(b'Type it: '), 'prompt never reached the terminal')
                os.write(master, b'SEND S5a abc\n')
                t.join(5)
            self.assertFalse(t.is_alive(), 'tty_confirm did not return')
            self.assertEqual(got['line'].strip(), 'SEND S5a abc')
        finally:
            os.close(master)
            os.close(slave)

class SenderS7Integration(unittest.TestCase):
    """S7 through the real signing_transaction / pre_send / scheduled_eta / readback on FakeChain.

    Replaced: signing (covered by SenderTests; FakeChain's deployer has no known key), the fee check (FakeChain
    blocks carry no base fee) and validate_plan (FakeChain's plan is the unrehearsed build_plan output; frozen-plan
    validation is covered by test_a3a_exec). The broadcast
    mines the planned transaction on FakeChain; the final readback must accept the resulting state and refuse
    a state where S7 did not take effect.
    """
    def setUp(self):
        import test_a3a_exec as te
        self.te = te
        te.ExecutorTests.setUpClass()
        t = self.t = te.ExecutorTests('test_valid_plan')
        t.setUp()
        chain, plan = t.chain_and_plan()
        for step in plan['steps']:
            step['tx']['gas'] = hex(260000)
        t.send_prefix(chain, plan, ('S1', 'S2', 'S3', 'S4', 'S5a', 'S5b', 'S6a'))
        chain('evm_setNextBlockTimestamp', [chain.state['eta']])
        chain('evm_mine', [])
        t.send_prefix(chain, plan, ('S6b',))
        self.chain, self.plan = chain, plan
        self.tmp = tempfile.TemporaryDirectory()
        d = Path(self.tmp.name)
        path = d / 'plan.json'
        ex.write_json(path, plan)
        self.sha = hashlib.sha256(path.read_bytes()).hexdigest()
        (d / 'accounts.json').write_text(json.dumps({'deployer': 'aastar-deployer'}))
        self.args = mock.Mock(plan=path, reviewed_plan_sha256=self.sha, step='S7', accounts=d / 'accounts.json', out=d / 'out')
        self.args.out.mkdir()
        self.lock = d / 'lock'

    def tearDown(self):
        self.t.doCleanups()
        self.tmp.cleanup()

    def send(self, after_mine=None):
        chain, plan, te = self.chain, self.plan, self.te
        def fake_signed(tx, account):
            self.assertEqual((account, tx), ('aastar-deployer', plan['steps'][-1]['tx']))
            return '0x02ab', te.abi_word(chain.count + 1), {}
        def fake_broadcast(url, raw):
            h = chain('eth_sendTransaction', [ex.tx_rpc(dict(plan['steps'][-1]['tx']))]).lower()
            if after_mine:
                after_mine(chain)
            return h
        readback = mock.Mock(wraps=ex.readback)
        def remote(method, params, error_ok=False):
            # FakeChain receipts omit blockHash, which every real receipt carries and the sender validates.
            value = chain(method, params, error_ok=error_ok)
            if method == 'eth_getTransactionReceipt' and isinstance(value, dict):
                value = dict(value, blockHash='0x' + '34' * 32)
            return value
        with mock.patch.object(sd, 'signed', fake_signed), mock.patch.object(sd, 'broadcast', fake_broadcast), \
                mock.patch.object(sd, 'LOCK_PATH', self.lock), mock.patch.object(ex, 'readback', readback), \
                mock.patch.object(sd, 'fee_fits', lambda remote, tx: None), \
                mock.patch.object(ex, 'artifact', self.t.artifact), \
                mock.patch.object(ex, 'validate_plan', lambda plan, frozen=False: None):
            result = sd.run(self.args, remote, 'unused', confirm=lambda _: 'SEND S7 ' + self.sha[:12])
        return result, readback

    def test_s7_real_gate_and_final_readback(self):
        result, readback = self.send()
        self.assertEqual(result['status'], 'SENT')
        self.assertEqual(self.chain.state['pending'], self.plan['pin']['capped'])
        final = [c for c in readback.call_args_list if c.args[2] == self.plan['steps'][-1]]
        self.assertEqual(len(final), 1)

    def test_s7_final_readback_refuses_a_state_without_the_effect(self):
        def undo(chain):
            chain.state['pending'] = self.plan['pin']['sp']['pendingAPNTsToken']
        with self.assertRaises(ex.Gate) as c:
            self.send(after_mine=undo)
        self.assertTrue(cause(c.exception).startswith('S7_'), c.exception.record)


if __name__ == '__main__':
    unittest.main()
