#!/usr/bin/env python3
"""Offline tests for manifest_send.py. Nothing leaves this machine.

The packet is the frozen full-stage manifest built from test_manifest_exec's fixtures. Packet-gate tests run the
real manifest_exec.validate_plan(frozen=True) with those fixtures. The send tests re-target the same packet to the
public anvil test accounts and run against a local anvil (--chain-id 11155111): signing is real `cast mktx` through
a wrapper that maps keystore names to the public anvil keys, decoding/keccak are real, the broadcast is a real
eth_sendRawTransaction to anvil, live estimates come from anvil, and receipts, mined fields and post-state
read-backs are read from anvil through two endpoint objects (127.0.0.1 and localhost). The packet prefix is mined
by impersonation and proven through the sender's real prior-record check. Only validate_plan (the packet no longer
matches its deterministic rebuild once re-targeted) and manifest_exec.pre_send_reads (it needs the Sepolia contract
set) are replaced in the send tests; the second endpoint can be tampered with to model endpoint disagreement.
"""
import sys
sys.dont_write_bytecode = True
import contextlib, copy, hashlib, io, json, os, re, shutil, socket, stat, subprocess, tempfile, time, unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import test_manifest_exec as tm  # noqa: E402
import manifest_send as ms  # noqa: E402

m, u, a, sd = ms.m, ms.u, ms.a, ms.sd
REAL_CAST = shutil.which('cast') or str(Path.home()/'.foundry/bin/cast')
REAL_RUN = subprocess.run
ANVIL = shutil.which('anvil') or str(Path.home()/'.foundry/bin/anvil')
# Public anvil test accounts #0-#3 (well-known keys, never funded on any public chain by this repo).
KEYS = {'deployer': '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80',
        'approver': '0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d',
        'executor': '0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a',
        'anni': '0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6'}
TEST_ADDR = {'deployer': '0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266',
             'approver': '0x70997970c51812dc3a010c7d01b50e0d17dc79c8',
             'executor': '0x3c44cdddb6a900fa2b585dd299e03d12fa4293bc',
             'anni': '0x90f79bf6eb2c4f870365e785982e1f101e93b906'}
ACCOUNTS = {label: 'test-'+label for label in KEYS}
OTHER_KEY = '0x47e179ec197488593b187f80a68eb5da4be7e3e4e0a3e7f2b4b5f1c2e9c7a2d1'  # arbitrary, not a packet sender

WRAPPER = r'''#!/usr/bin/env python3
import json, os, sys
cfg = json.load(open(%r))
argv = sys.argv[1:]
with open(cfg['log'], 'a') as f:
    f.write(json.dumps({'argv': argv, 'env': dict(os.environ)}) + '\n')
if argv and argv[0] == 'mktx':
    if cfg.get('exit'):
        sys.exit(cfg['exit'])
    i = argv.index('--account')
    argv[i:i + 2] = ['--private-key', cfg.get('key') or cfg['keys'][argv[i + 1]]]
    i = argv.index('--password-file')
    del argv[i:i + 2]  # metadata is checked by the sender; no keystore or password exists in tests
    for flag, value in cfg.get('tamper', {}).items():
        if flag == 'data':
            argv[-1] = value
        elif flag == 'to':
            argv[-2] = value
        else:
            argv[argv.index(flag) + 1] = value
os.execv(cfg['cast'], [cfg['cast']] + argv)
'''

# Generic contract runtime used at the packet targets on anvil:
#   revert if sload(REVERT_SLOT) == selector + 1; burn sload(BURN_SLOT) loop iterations (40 gas each);
#   transferOwnership(x): require caller == sload(owner()), sstore(owner(), x); any other call returns sload(selector).
REVERT_SLOT, BURN_SLOT = 0x100000000, 0x100000001
SEL = dict(owner=0x8da5cb5b, transfer=0xf2fde38b, nonce=0xaffed0e0, verifier=0x3c396ea4, pending=0x37abe80b,
           ready=0xd9a010e4, apply=0x585d5bc0)


def assemble(items):
    """Two-pass assembler for the generic runtime: ints are opcodes, ('push', n, value), ('label', x), ('ref', x)."""
    def size(item):
        return 3 if item[0] == 'ref' else (1+item[1]) if item[0] == 'push' else 1
    labels, pc = {}, 0
    for item in items:
        item = item if isinstance(item, tuple) else ('op', item)
        if item[0] == 'label':
            labels[item[1]] = pc
        pc += size(item)
    out = ''
    for item in items:
        if isinstance(item, int):
            out += '%02x' % item
        elif item[0] == 'push':
            out += '%02x' % (0x5f+item[1]) + format(item[2], '0%dx' % (2*item[1]))
        elif item[0] == 'ref':
            out += '61' + format(labels[item[1]], '04x')
        elif item[0] == 'label':
            out += '5b'
    return '0x'+out


def generic_runtime():
    P = lambda n, v: ('push', n, v)
    L, R = (lambda x: ('label', x)), (lambda x: ('ref', x))
    CALLDATALOAD, SHR, DUP1, ADD, SLOAD, EQ, JUMPI, ISZERO, SWAP1, SUB, JUMP, POP = (
        0x35, 0x1c, 0x80, 0x01, 0x54, 0x14, 0x57, 0x15, 0x90, 0x03, 0x56, 0x50)
    MSTORE, RETURN, CALLER, REVERT, SSTORE, STOP = 0x52, 0xf3, 0x33, 0xfd, 0x55, 0x00
    return assemble([
        P(1, 0), CALLDATALOAD, P(1, 0xe0), SHR,
        DUP1, P(1, 1), ADD, P(5, REVERT_SLOT), SLOAD, EQ, R('rev'), JUMPI,
        P(5, BURN_SLOT), SLOAD,
        L('loop'), DUP1, ISZERO, R('done'), JUMPI, P(1, 1), SWAP1, SUB, R('loop'), JUMP,
        L('done'), POP,
        DUP1, P(4, SEL['transfer']), EQ, R('xfer'), JUMPI,
        SLOAD, P(1, 0), MSTORE, P(1, 0x20), P(1, 0), RETURN,
        L('xfer'), P(4, SEL['owner']), SLOAD, CALLER, EQ, R('ok'), JUMPI,
        L('rev'), P(1, 0), DUP1, REVERT,
        L('ok'), P(1, 4), CALLDATALOAD, P(4, SEL['owner']), SSTORE, STOP])


GENERIC = generic_runtime()


@contextlib.contextmanager
def captured_fds():
    """Capture file descriptors 1 and 2 (this process and every child, e.g. cast's prompts and errors)."""
    streams = []
    saved = [os.dup(1), os.dup(2)]
    files = [tempfile.TemporaryFile(), tempfile.TemporaryFile()]
    sys.stdout.flush(); sys.stderr.flush()
    try:
        for fd, f in zip((1, 2), files):
            os.dup2(f.fileno(), fd)
        yield streams
    finally:
        sys.stdout.flush(); sys.stderr.flush()
        for fd, s in zip((1, 2), saved):
            os.dup2(s, fd)
            os.close(s)
        for f in files:
            f.seek(0)
            streams.append(f.read().decode(errors='replace'))
            f.close()


def word(v):
    return '0x'+format(v, '064x')


def free_port():
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        return s.getsockname()[1]


def frozen_packet():
    """The frozen full-stage packet from test_manifest_exec's fixtures; the case keeps its patches active."""
    case = tm.ManifestTests('test_determinism')
    case.setUp()
    plan = case.plan
    for step in plan['steps']:
        tm.freeze_gas(plan, step)
    m.budget(plan)
    m.validate_plan(plan, case.inputs, frozen=True)
    return case, plan


def retarget(plan):
    """Same packet, signed by the public anvil accounts instead of the Sepolia senders."""
    text = json.dumps(plan)
    for label, sender in plan['pin']['senders'].items():
        text = text.replace(sender['address'][2:].lower(), TEST_ADDR[label][2:])
    plan = json.loads(text)
    # The fixture's uniform 130000 limit cannot deposit the real verifier runtime; this step is only replayed.
    next(s for s in plan['steps'] if s['id'] == 'A12a')['tx']['gas'] = hex(3_000_000)
    return plan


class Endpoint:
    """Wraps a real a3a_exec.RPC to anvil: records every call and lets one test rewrite results (disagreement)."""
    def __init__(self, rpc, name):
        self.rpc, self.name, self.calls, self.tamper = rpc, name, [], {}

    def __call__(self, method, params, *rest):
        self.calls.append((method, json.dumps(params)))
        fn = self.tamper.get(method)
        if fn is not None and getattr(fn, 'replace', False):
            return fn(params)
        result = self.rpc(method, params, *rest)
        return fn(params, result) if fn else result


def replace(fn):
    fn.replace = True
    return fn


class AnvilCase(unittest.TestCase):
    """One anvil per class; the packet prefix before FIRST is mined once, every test reverts to that snapshot."""
    FIRST, LAST = 'D.protocol.transfer', 'D.factory.transfer'

    @classmethod
    def setUpClass(cls):
        case, plan = frozen_packet()
        cls.real_plan = plan
        case.doCleanups()
        cls.plan = retarget(plan)
        cls.port = free_port()
        cls.proc = subprocess.Popen([ANVIL, '--chain-id', '11155111', '--port', str(cls.port), '--hardfork', 'cancun',
                                     '--silent'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        cls.urls = ('http://127.0.0.1:%d' % cls.port, 'http://localhost:%d' % cls.port)
        cls.local = a.RPC(cls.urls[0], local=True)
        for _ in range(200):
            try:
                cls.local('eth_chainId', [])
                break
            except a.Gate:
                time.sleep(.05)
        cls.addr = cls.plan['addresses']
        cls.setup_chain()
        cls.base_snapshot = cls.local('evm_snapshot', [])

    @classmethod
    def tearDownClass(cls):
        cls.proc.terminate()
        cls.proc.wait(10)

    @classmethod
    def set_slot(cls, target, slot, value):
        cls.local('anvil_setStorageAt', [target, word(slot), word(value)])

    @classmethod
    def generic(cls, target, slots):
        cls.local('anvil_setCode', [target, GENERIC])
        for slot, value in slots.items():
            cls.set_slot(target, slot, value)

    @classmethod
    def setup_chain(cls):
        first = next(i for i, s in enumerate(cls.plan['steps']) if s['id'] == cls.FIRST)
        cls.first_index = first
        for label, sender in cls.plan['pin']['senders'].items():
            cls.local('anvil_setNonce', [sender['address'], hex(sender['nonce'])])
        sent = []
        for step in cls.plan['steps'][:first]:
            tx = step['tx']
            h = cls.local('eth_sendTransaction', [a.tx_rpc(tx)])
            r = None
            for _ in range(400):
                r = cls.local('eth_getTransactionReceipt', [h])
                if r is not None:
                    break
                time.sleep(.01)
            assert r and r['status'] == '0x1', (step['id'], r)
            sent.append(dict(step=step['id'], variant='apply' if 'variants' in step else None, hash=h,
                             blockNumber=r['blockNumber'], blockHash=r['blockHash']))
        cls.prior_records = sent
        cls.prepare_targets()

    @classmethod
    def prepare_targets(cls):
        deployer = TEST_ADDR['deployer']
        cls.generic(cls.addr['AOAProtocolRegistry'], {SEL['owner']: int(deployer, 16)})
        cls.generic(cls.addr['xPNTsFactoryV2'], {SEL['owner']: int(deployer, 16)})
        step = cls.plan['steps'][cls.first_index]
        cls.generic(u.SAFE, {SEL['nonce']: step['safeNonce']})

    def setUp(self):
        self.local('evm_revert', [self.base_snapshot])
        self.__class__.base_snapshot = self.local('evm_snapshot', [])
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        d = self.d = Path(self.tmp.name)
        self.packet_plan = copy.deepcopy(self.plan)
        self.write_packet()
        self.cfg = d/'wrapper.json'
        self.log = d/'cast.log'
        self.wrapper_cfg()
        wrapper = d/'cast'
        wrapper.write_text(WRAPPER % str(self.cfg))
        wrapper.chmod(wrapper.stat().st_mode | stat.S_IEXEC)
        (d/'accounts.json').write_text(json.dumps(ACCOUNTS))
        pw = d/'pw'
        pw.mkdir(mode=0o700)
        (pw/'password').touch()
        (pw/'password').chmod(0o600)
        prior = d/'prior.json'
        prior.write_text(json.dumps(dict(packetSha256=self.sha, sent=self.prior_records)))
        self.out = d/'out'
        self.out.mkdir()
        self.args = SimpleNamespace(packet=d/'plan.json', approved_sha256=self.sha, first=self.FIRST, last=self.LAST,
                                    prior=[prior], accounts=d/'accounts.json', password_file=pw/'password',
                                    out=self.out, confirm=None, current=None, dry_run=False)
        self.endpoints = (('primary', Endpoint(a.RPC(self.urls[0]), 'primary')),
                          ('secondary', Endpoint(a.RPC(self.urls[1]), 'secondary')))
        self.broadcasts, self.validated, self.reads, self.gate_log = [], [], [], []
        self.read_failure = None
        self.after_sign = None
        self.before_broadcast = None
        real_broadcast, real_signed = sd.broadcast, ms.signed
        def broadcast(url, raw):
            for _, ep in self.endpoints:
                for method, params in ep.calls:
                    self.assertNotIn(raw[2:].lower(), params.lower(), 'signed bytes reached an endpoint before broadcast')
            self.assertEqual(sorted(p.name for p in self.out.glob('signed.*')), sorted('signed.%s.raw' % x['step']
                             for x in json.loads((self.out/'sent.json').read_text())['sent']))
            self.broadcasts.append((url, raw))
            self.gate_log.append('<broadcast>')
            if self.before_broadcast:
                self.before_broadcast()
            return real_broadcast(url, raw)
        def signed(tx, account, password_file=None):
            result = real_signed(tx, account, password_file)
            if self.after_sign:
                self.after_sign()
            return result
        def reads(rpc, plan, step, context):
            self.reads.append((getattr(rpc, 'name', 'cli'), step['id'], copy.deepcopy({k: v for k, v in context.items() if k != 'B2'})))
            if self.read_failure and self.read_failure[0] == getattr(rpc, 'name', 'cli') and self.read_failure[1] == step['id']:
                raise a.Gate(self.read_failure[2], 'injected', 'state re-read')
            return step['tx']
        def validate(plan, inputs, frozen=False):
            self.validated.append((frozen, hashlib.sha256(json.dumps(plan, sort_keys=True).encode()).hexdigest()))
        for p in (mock.patch.object(sd, 'CAST', str(wrapper)), mock.patch.object(sd, 'LOCK_PATH', d/'send.lock'),
                  mock.patch.object(sd, 'broadcast', broadcast), mock.patch.object(ms, 'signed', signed),
                  mock.patch.object(m, 'pre_send_reads', reads), mock.patch.object(m, 'validate_plan', validate),
                  mock.patch.object(ms, 'POLL_SECONDS', 0.05), mock.patch.object(ms, 'SECONDARY_WAIT_SECONDS', 1),
                  mock.patch.dict(os.environ, {'ETH_RPC_URL': self.urls[0], 'RPC_SECONDARY': self.urls[1]})):
            p.start()
            self.addCleanup(p.stop)

    def write_packet(self):
        raw = json.dumps(self.packet_plan, indent=2, sort_keys=True).encode()
        (self.d/'plan.json').write_bytes(raw)
        self.sha = hashlib.sha256(raw).hexdigest()
        if hasattr(self, 'args'):
            self.args.approved_sha256 = self.sha
            prior = json.loads(self.args.prior[0].read_text())
            prior['packetSha256'] = self.sha
            self.args.prior[0].write_text(json.dumps(prior))

    def wrapper_cfg(self, **extra):
        cfg = {'log': str(self.log), 'cast': REAL_CAST, 'keys': {ACCOUNTS[k]: v for k, v in KEYS.items()}}
        cfg.update(extra)
        self.cfg.write_text(json.dumps(cfg))

    def phrase(self):
        return '%s %s..%s %s' % ('DRY-RUN' if self.args.dry_run else 'SEND', self.args.first, self.args.last or self.args.first, self.args.approved_sha256[:12])

    def send(self, typed=None):
        return ms.run(self.args, self.endpoints, self.urls, confirm=lambda _: self.phrase() if typed is None else typed)

    def step(self, sid):
        return next(s for s in self.packet_plan['steps'] if s['id'] == sid)

    def nonce(self, label='deployer'):
        return a.nonce(self.local, TEST_ADDR[label])

    def mktx_calls(self):
        if not self.log.exists():
            return []
        return [json.loads(l) for l in self.log.read_text().splitlines() if json.loads(l)['argv'][0] == 'mktx']

    def stop(self, gate, fn=None, broadcast=False):
        """Assert the named gate (for a failure after broadcast: its cause) and what was or was not sent."""
        start = self.nonce()
        with self.assertRaises(a.Gate) as caught:
            (fn or self.send)()
        rec = caught.exception.record
        if broadcast:
            self.assertEqual(rec['gate'], 'send_after_broadcast')
            self.assertEqual(rec['observed']['cause'], gate, rec)
            self.assertTrue(a.HASH32.fullmatch(rec['observed']['hash']))
            self.assertEqual(len(self.broadcasts), 1, 'exactly one broadcast, never a retry')
            self.assertEqual(len(self.mktx_calls()), 1, 'never re-signed')
        else:
            self.assertEqual(rec['gate'], gate, rec)
            self.assertEqual(self.broadcasts, [])
            self.assertEqual(self.nonce(), start, 'nothing reached the chain')
            self.assertEqual(list(self.out.glob('signed.*')), [])
        return rec

    def comparisons(self):
        return json.loads((self.out/'gas-comparisons.json').read_text())['comparisons']

    def burn_to(self, target, estimate):
        """Set the generic contract's burn loop so the live estimate of FIRST lands at `estimate` (+-40 gas)."""
        step = self.step(self.FIRST)
        probe = {k: v for k, v in a.tx_rpc(step['tx']).items() if k != 'gas'}
        self.set_slot(target, BURN_SLOT, 0)
        base = a.qty(self.local('eth_estimateGas', [probe, 'latest']))
        self.set_slot(target, BURN_SLOT, max(0, (estimate-base)//40))
        got = a.qty(self.local('eth_estimateGas', [probe, 'latest']))
        self.assertLess(abs(got-estimate), 400)
        return got


class SendTests(AnvilCase):
    def test_two_steps_sent_and_read_back_on_both_endpoints(self):
        result = self.send()
        self.assertEqual(result['steps'], [self.FIRST, self.LAST])
        for target in (self.addr['AOAProtocolRegistry'], self.addr['xPNTsFactoryV2']):
            self.assertEqual(a.address(self.local, target, 'owner()'), u.TL)
        self.assertEqual(len(self.broadcasts), 2)
        self.assertTrue(all(url == self.urls[0] for url, _ in self.broadcasts), 'broadcast to the primary only')
        for _, ep in self.endpoints:
            self.assertNotIn('eth_sendRawTransaction', [c[0] for c in ep.calls])
        # Every comparison records endpoint, block numbers, estimate and limit.
        rows = self.comparisons()
        self.assertEqual([(r['step'], r['endpoint']) for r in rows],
                         [(s, e) for s in (self.FIRST, self.LAST) for e in ('primary', 'secondary')])
        for r in rows:
            self.assertEqual(r['result'], 'pass')
            self.assertEqual(r['limit'], 130000)
            self.assertEqual(r['repinThreshold'], 130000*10//11)
            self.assertTrue(21000 < r['estimate'] <= r['repinThreshold'])
            self.assertIsInstance(r['blockNumber'], int)
            self.assertGreaterEqual(r['blockNumberAfter'], r['blockNumber'])
        # State re-reads ran on both endpoints before each signature, with the context derived from the prefix.
        self.assertEqual([(n, s) for n, s, _ in self.reads],
                         [(e, s) for s in (self.FIRST, self.LAST) for e in ('primary', 'secondary')])
        ctx = self.reads[0][2]
        self.assertTrue(ctx['transferred'] and ctx['frozen'] and ctx['activated'])
        self.assertEqual(ctx['passed'], {s['id'] for s in self.plan['steps'][:self.first_index]})
        self.assertEqual(ctx['upgradeBlock'], next(x['blockNumber'] for x in self.prior_records if x['step'] == 'upgrade_execute_exec'))
        self.assertIn(self.FIRST, self.reads[2][2]['passed'])
        self.assertEqual(self.validated, [(True, self.validated[0][1])])
        sent = json.loads((self.out/'sent.json').read_text())
        self.assertEqual([x['step'] for x in sent['sent']], [self.FIRST, self.LAST])
        # Signing used the keystore name and password file only; no RPC variable reached cast.
        for call in self.mktx_calls():
            self.assertIn('--account', call['argv'])
            self.assertIn('--password-file', call['argv'])
            self.assertFalse(any(x.startswith('0x') and len(x) == 66 for x in call['argv']), 'no raw key in argv')
            self.assertFalse(any(k.startswith(('ETH_RPC', 'RPC_')) for k in call['env']))
            self.assertFalse(any(url in json.dumps(call) for url in self.urls))
        for f in self.out.iterdir():
            self.assertFalse(any(url in f.read_text() for url in self.urls), f.name)

    def test_sent_record_is_a_valid_prior_for_the_next_run(self):
        self.args.last = self.FIRST
        self.send()
        nxt = self.d/'out2'
        nxt.mkdir()
        self.args = SimpleNamespace(**dict(vars(self.args), first=self.LAST, last=None, out=nxt,
                                           prior=[self.args.prior[0], self.out/'sent.json']))
        self.out = nxt
        self.assertEqual(self.send()['steps'], [self.LAST])

    def test_operator_confirmation(self):
        self.stop('send_operator_confirmation', lambda: self.send('SEND yes'))
        self.assertEqual(self.mktx_calls(), [])

    def test_missing_account(self):
        (self.d/'accounts.json').write_text(json.dumps({'approver': 'test-approver'}))
        self.stop('send_account_named')

    def test_password_file_mode(self):
        self.args.password_file.chmod(0o644)
        self.stop('send_password_mode')

    def test_first_step_unknown(self):
        self.args.first = 'Z9'
        self.stop('send_first_step')

    def test_last_step_unknown(self):
        self.args.last = 'Z9'
        self.stop('send_last_step')

    def test_step_order(self):
        self.args.first, self.args.last = self.LAST, self.FIRST
        self.stop('send_step_order')

    def test_endpoint_roles(self):
        self.endpoints = tuple(reversed(self.endpoints))
        self.stop('send_endpoints')

    def fresh_out(self, name):
        self.out = self.d/name
        self.out.mkdir()
        self.args.out = self.out

    def logged(self, fn):
        """Every need() gate name, in order, with the broadcast point marked."""
        self.gate_log = []
        original = a.need
        def need(name, *args, **kw):
            self.gate_log.append(name)
            return original(name, *args, **kw)
        with mock.patch.object(a, 'need', need):
            result = fn()
        return result, list(self.gate_log)

    def test_dry_run_shares_the_live_gate_sequence(self):
        self.args.last = self.FIRST
        snap = self.local('evm_snapshot', [])
        live, live_gates = self.logged(self.send)
        self.assertEqual(live['steps'], [self.FIRST])
        self.local('evm_revert', [snap])
        self.broadcasts.clear()
        self.log.unlink()
        self.fresh_out('dry')
        self.args.dry_run = True
        start = self.nonce()
        dry, dry_gates = self.logged(self.send)
        cut = live_gates.index('<broadcast>')
        self.assertGreater(cut, 50)
        self.assertEqual(dry_gates, live_gates[:cut])
        self.assertEqual((dry['status'], dry['step'], dry['broadcast']), ('DRY_RUN', self.FIRST, False))
        self.assertEqual(self.broadcasts, [])
        self.assertEqual(self.nonce(), start)
        self.assertEqual(len(self.mktx_calls()), 1, 'signed in memory exactly like a live run')
        self.assertEqual(sorted(p.name for p in self.out.iterdir()), sorted([
            'packet.approved.json', 'sent.json', 'gas-comparisons.json', 'result.json',
            'unsigned.%s.json' % self.FIRST, 'decoded.%s.json' % self.FIRST]))
        self.assertEqual(json.loads((self.out/('decoded.%s.json' % self.FIRST)).read_text())['hash'], dry['hash'])
        self.assertEqual(len(self.comparisons()), 2)

    def test_dry_run_stops_before_the_first_broadcast_of_a_range(self):
        self.args.dry_run = True
        result = self.send()
        self.assertEqual(result['step'], self.FIRST)
        self.assertEqual(self.broadcasts, [])
        self.assertEqual([r['step'] for r in self.comparisons()], [self.FIRST, self.FIRST])

    def test_dry_run_confirmation_phrase(self):
        self.args.dry_run = True
        self.stop('send_operator_confirmation', lambda: self.send('SEND %s..%s %s' % (self.FIRST, self.LAST, self.sha[:12])))

    def test_dry_run_with_real_keystore_leaks_no_secret(self):
        """A real `cast wallet` keystore and password file; nothing secret may reach any output or exception."""
        home = self.d/'home'
        keystores = home/'.foundry'/'keystores'
        keystores.mkdir(parents=True)
        password = 'pw-' + hashlib.sha256(b'manifest-send-leak-test').hexdigest()[:24]
        imported = REAL_RUN([REAL_CAST, 'wallet', 'import', ACCOUNTS['deployer'], '--private-key', KEYS['deployer'],
                             '--unsafe-password', password, '--keystore-dir', str(keystores)],
                            capture_output=True, text=True)
        self.assertEqual(imported.returncode, 0, imported.stderr)
        keystore_text = (keystores/ACCOUNTS['deployer']).read_text()
        crypto = json.loads(keystore_text)['crypto']
        secrets = [KEYS['deployer'], KEYS['deployer'][2:], password, keystore_text, crypto['ciphertext'], crypto['kdfparams']['salt'],
                   crypto['mac'], crypto['cipherparams']['iv']]
        pwdir = self.d/'secret'
        pwdir.mkdir(mode=0o700)
        pwfile = pwdir/'password'
        pwfile.write_text(password)
        pwfile.chmod(0o600)
        for name, url in zip(('a', 'b'), self.urls):
            (self.d/name).write_text(url)
        def argv(out, phrase):
            return ['--packet', str(self.args.packet), '--approved-sha256', self.sha, '--first', self.FIRST,
                    '--prior', str(self.args.prior[0]), '--rpc-file', str(self.d/'a'), '--rpc-file-secondary', str(self.d/'b'),
                    '--accounts', str(self.args.accounts), '--password-file', str(pwfile), '--out', str(out),
                    '--dry-run', '--confirm', phrase]
        phrase = 'DRY-RUN %s..%s %s' % (self.FIRST, self.FIRST, self.sha[:12])
        old = os.umask(0o022)
        self.addCleanup(os.umask, old)
        outputs = []
        with mock.patch.object(sd, 'CAST', REAL_CAST), mock.patch.dict(os.environ, {'HOME': str(home), ms.ENABLE_ENV: self.sha}):
            for out, expect in ((self.d/'ks-ok', 0), (self.d/'ks-bad', 1)):
                if expect:
                    pwfile.write_text('wrong-' + password)  # cast must refuse; its error text is checked too
                self.out = out
                with captured_fds() as streams:
                    rc = ms.main(argv(out, phrase))
                self.assertEqual(rc, expect, streams)
                outputs += streams
                outputs += [f.read_text() for f in out.rglob('*') if f.is_file()]
            pwfile.write_text('wrong-' + password)
            self.out = self.d/'ks-exc'
            self.fresh_out('ks-exc')
            self.args.password_file, self.args.dry_run = pwfile, True
            with captured_fds() as streams:
                with self.assertRaises(a.Gate) as caught:
                    self.send()
            outputs += streams + [str(caught.exception), json.dumps(caught.exception.record)]
        result = json.loads((self.d/'ks-ok'/'result.json').read_text())
        self.assertEqual(result['status'], 'DRY_RUN')
        self.assertEqual(json.loads((self.d/'ks-bad'/'FAILURE.json').read_text())['gate'], 'send_sign_exit')
        self.assertEqual(caught.exception.record['gate'], 'send_sign_exit')
        self.assertEqual(self.broadcasts, [])
        blob = '\n'.join(outputs).lower()
        self.assertIn(result['hash'], blob)  # the outputs were really collected
        for secret in secrets:
            self.assertNotIn(secret.lower(), blob)
        self.assertIsNone(re.search(r'02f8[0-9a-f]{120,}', blob), 'no signed transaction bytes in any output')

    def test_cli_end_to_end(self):
        for name, url in zip(('a', 'b'), self.urls):
            (self.d/name).write_text(url)
        argv = ['--packet', str(self.args.packet), '--approved-sha256', self.sha, '--first', self.FIRST,
                '--last', self.LAST, '--prior', str(self.args.prior[0]), '--rpc-file', str(self.d/'a'),
                '--rpc-file-secondary', str(self.d/'b'), '--accounts', str(self.args.accounts),
                '--password-file', str(self.args.password_file), '--out', str(self.d/'cli')]
        self.out = self.d/'cli'  # where the broadcast hook looks for signed bytes
        old = os.umask(0o022)
        self.addCleanup(os.umask, old)
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.dict(os.environ, {ms.ENABLE_ENV: self.sha}), contextlib.redirect_stdout(out), \
                contextlib.redirect_stderr(err):
            self.assertEqual(ms.main(argv+['--confirm', 'SEND %s..%s %s' % (self.FIRST, self.LAST, self.sha[:12])]), 0)
            self.assertEqual(json.loads(out.getvalue())['steps'], [self.FIRST, self.LAST])
            self.assertEqual(stat.S_IMODE((self.d/'cli').stat().st_mode), 0o700)
            argv[-1] = str(self.d/'cli2')
            self.out = self.d/'cli2'
            self.assertEqual(ms.main(argv+['--confirm', 'SEND']), 1)
        record = json.loads((self.d/'cli2'/'FAILURE.json').read_text())
        self.assertEqual((record['gate'], record['step']), ('send_operator_confirmation', None))
        self.assertEqual(self.nonce(), a.qty(self.step(self.LAST)['tx']['nonce'])+1)
        for f in list((self.d/'cli').iterdir())+list((self.d/'cli2').iterdir()):
            self.assertFalse(any(url in f.read_text() for url in self.urls), f.name)

    def test_packet_hash(self):
        self.args.approved_sha256 = '0'*64
        self.stop('packet_approved_sha256')
        self.assertEqual(self.validated, [])

    def test_packet_chain(self):
        for s in self.packet_plan['steps'][self.first_index:]:
            s['tx']['chainId'] = '0x7a69'
        self.write_packet()
        self.stop('send_packet_chain')

    def test_sender_binding(self):
        self.packet_plan['pin']['senders']['deployer']['address'] = TEST_ADDR['anni']
        self.write_packet()
        self.stop('send_sender_binding')

    # --- prefix proof (the executor context comes only from receipts re-read on both endpoints)
    def prior(self, edit):
        data = json.loads(self.args.prior[0].read_text())
        edit(data['sent'])
        self.args.prior[0].write_text(json.dumps(data))

    def test_prior_missing_step(self):
        self.prior(lambda s: s.pop(3))
        self.stop('prior_prefix')

    def test_prior_other_packet(self):
        data = json.loads(self.args.prior[0].read_text())
        data['packetSha256'] = 'f'*64
        self.args.prior[0].write_text(json.dumps(data))
        self.stop('prior_packet')

    def test_prior_wrong_block(self):
        self.prior(lambda s: s[5].update(blockHash='0x'+'ab'*32))
        self.stop('prior_receipt_block')

    def test_prior_unknown_hash(self):
        self.prior(lambda s: s[5].update(hash='0x'+'cd'*32))
        self.stop('prior_receipt_missing')

    def test_prior_hash_of_another_step(self):
        def swap(s):
            s[1].update(hash=s[2]['hash'], blockNumber=s[2]['blockNumber'], blockHash=s[2]['blockHash'])
        self.prior(swap)
        self.stop('prior_mined_nonce')

    def test_prior_records_not_objects(self):
        self.prior(lambda s: s.__setitem__(0, 'A1'))
        self.stop('prior_records')

    def test_prior_record_keys(self):
        self.prior(lambda s: s[0].update(extra=1))
        self.stop('prior_record_keys')

    def test_prior_variant(self):
        self.prior(lambda s: s[0].update(variant='apply'))
        self.stop('prior_variant')

    def test_prior_receipt_hash_on_secondary(self):
        self.endpoints[1][1].tamper['eth_getTransactionReceipt'] = lambda p, r: r and dict(r, transactionHash='0x'+'ef'*32)
        self.stop('prior_receipt_hash')

    def test_prior_block_not_canonical_on_secondary(self):
        self.endpoints[1][1].tamper['eth_getBlockByNumber'] = lambda p, r: dict(r, hash='0x'+'cc'*32) if p[0] != 'latest' else r
        self.stop('prior_block_canonical')

    def test_prior_timestamp_on_secondary(self):
        self.endpoints[1][1].tamper['eth_getBlockByNumber'] = lambda p, r: (
            dict(r, timestamp=hex(int(r['timestamp'], 16)+1)) if p[0] != 'latest' else r)
        self.stop('prior_timestamp_agree')

    def test_prior_receipt_on_secondary(self):
        hidden = self.prior_records[4]['hash']
        self.endpoints[1][1].tamper['eth_getTransactionReceipt'] = lambda p, r: None if p[0] == hidden else r
        self.stop('prior_receipt_missing')

    # --- before each signature, both endpoints
    def test_secondary_chain_id(self):
        self.endpoints[1][1].tamper['eth_chainId'] = replace(lambda p: '0x7a69')
        self.stop('send_chain_id')

    def test_primary_nonce_latest(self):
        self.local('anvil_setNonce', [TEST_ADDR['deployer'], hex(a.qty(self.step(self.FIRST)['tx']['nonce'])+1)])
        with self.assertRaises(a.Gate) as c:
            self.send()
        self.assertEqual(c.exception.record['gate'], 'send_nonce_latest')
        self.assertEqual(self.broadcasts, [])
        self.assertEqual(self.mktx_calls(), [])

    def test_secondary_nonce_latest(self):
        self.endpoints[1][1].tamper['eth_getTransactionCount'] = lambda p, r: hex(int(r, 16)+1) if p[1] == 'latest' else r
        self.stop('send_nonce_latest')

    def test_secondary_nonce_pending(self):
        self.endpoints[1][1].tamper['eth_getTransactionCount'] = lambda p, r: hex(int(r, 16)+1) if p[1] == 'pending' else r
        self.stop('send_nonce_pending')

    def test_secondary_state_reads(self):
        self.read_failure = ('secondary', self.FIRST, 'safe_state')
        rec = self.stop('safe_state')
        self.assertEqual(rec['step'], self.FIRST+'@secondary')
        self.assertEqual(self.mktx_calls(), [])

    def test_state_reads_on_second_step(self):
        self.read_failure = ('primary', self.LAST, 'handover_dependencies')
        with self.assertRaises(a.Gate) as c:
            self.send()
        self.assertEqual(c.exception.record['gate'], 'handover_dependencies')
        self.assertEqual(len(self.broadcasts), 1)  # the first step completed; the second was never signed
        self.assertEqual(len(self.mktx_calls()), 1)
        self.assertEqual([x['step'] for x in json.loads((self.out/'sent.json').read_text())['sent']], [self.FIRST])

    def test_secondary_fee_cap(self):
        def high(p, r):
            return dict(r, baseFeePerGas=hex(10**12)) if p[0] == 'latest' else r
        self.endpoints[1][1].tamper['eth_getBlockByNumber'] = high
        self.stop('send_fee_cap')

    def test_secondary_balance(self):
        self.endpoints[1][1].tamper['eth_getBalance'] = replace(lambda p: '0x1')
        self.stop('send_balance')

    # --- DSR #599: live estimate vs the frozen limit and the 1.1x re-pin rule
    def test_live_estimate_over_limit(self):
        est = self.burn_to(self.addr['AOAProtocolRegistry'], 140000)
        self.stop('send_live_gas_over_limit')
        rows = self.comparisons()
        self.assertEqual(len(rows), 1)
        self.assertEqual((rows[0]['endpoint'], rows[0]['result'], rows[0]['limit']), ('primary', 'over_limit', 130000))
        self.assertEqual(rows[0]['estimate'], est)
        self.assertIsInstance(rows[0]['blockNumber'], int)

    def test_live_estimate_requires_repin(self):
        est = self.burn_to(self.addr['AOAProtocolRegistry'], 124000)
        self.assertTrue(130000*10//11 < est <= 130000)
        self.stop('send_live_gas_repin')
        self.assertEqual(self.comparisons()[0]['result'], 'repin')
        self.assertEqual(self.comparisons()[0]['estimate'], est)

    def test_live_estimate_below_repin_threshold_passes(self):
        est = self.burn_to(self.addr['AOAProtocolRegistry'], 112000)
        self.args.last = self.FIRST
        self.send()
        self.assertEqual([r['estimate'] for r in self.comparisons()], [est, est])

    def test_repin_boundary_on_secondary(self):
        threshold = 130000*10//11
        self.args.last = self.FIRST
        self.endpoints[1][1].tamper['eth_estimateGas'] = replace(lambda p: hex(threshold))
        self.send()
        self.assertEqual(self.comparisons()[1]['estimate'], threshold)
        self.tearDown_partial()
        self.endpoints[1][1].tamper['eth_estimateGas'] = replace(lambda p: hex(threshold+1))
        self.stop('send_live_gas_repin')
        self.assertEqual([(r['endpoint'], r['result']) for r in self.comparisons()], [('primary', 'pass'), ('secondary', 'repin')])

    def tearDown_partial(self):
        """Fresh output directory and chain state inside one test."""
        self.local('evm_revert', [self.base_snapshot])
        self.__class__.base_snapshot = self.local('evm_snapshot', [])
        self.out = self.d/('out-%d' % len(list(self.d.glob('out*'))))
        self.out.mkdir()
        self.args.out = self.out
        self.broadcasts.clear()
        if self.log.exists():
            self.log.unlink()

    def test_secondary_estimate_over_limit(self):
        self.endpoints[1][1].tamper['eth_estimateGas'] = replace(lambda p: hex(130001))
        self.stop('send_live_gas_over_limit')
        self.assertEqual([(r['endpoint'], r['result']) for r in self.comparisons()], [('primary', 'pass'), ('secondary', 'over_limit')])

    def test_secondary_estimate_unavailable(self):
        def fail(p):
            raise a.Gate('rpc_fault', {'method': 'eth_estimateGas', 'code': -32000}, 'successful RPC')
        self.endpoints[1][1].tamper['eth_estimateGas'] = replace(fail)
        self.stop('remote_fresh_estimate_unavailable')
        self.assertEqual(self.comparisons()[1]['result'], 'unavailable')

    def test_block_gas_limit(self):
        self.endpoints[1][1].tamper['eth_getBlockByNumber'] = lambda p, r: dict(r, gasLimit=hex(100000)) if p[0] == 'latest' else r
        self.stop('block_gas_limit')
        self.assertEqual(self.comparisons()[1]['result'], 'other_gate')

    def test_live_estimate_uses_latest_without_overrides(self):
        self.args.last = self.FIRST
        self.send()
        for _, ep in self.endpoints:
            params = [json.loads(p) for meth, p in ep.calls if meth == 'eth_estimateGas']
            self.assertEqual(len(params), 1)
            self.assertEqual(params[0][1], 'latest')
            self.assertEqual(len(params[0]), 2)
            self.assertNotIn('gas', params[0][0])

    # --- the signed transaction is decoded locally and must equal the packet
    def signed_field(self, flag, gate, value):
        self.wrapper_cfg(tamper={flag: value})
        self.stop(gate)
        self.assertEqual(list(self.out.glob('broadcast.*')), [])

    def test_signed_by_another_key(self):
        self.wrapper_cfg(key=OTHER_KEY)
        self.stop('send_signed_signer')

    def test_sign_failure(self):
        self.wrapper_cfg(exit=1)
        self.stop('send_sign_exit')

    def test_final_nonce_pending(self):
        self.after_sign = lambda: self.endpoints[1][1].tamper.__setitem__(
            'eth_getTransactionCount', lambda p, r: hex(int(r, 16)+1) if p[1] == 'pending' else r)
        self.stop('send_final_nonce_pending')

    def test_nonce_moved_after_signing(self):
        self.after_sign = lambda: self.local('anvil_setNonce', [TEST_ADDR['deployer'],
                                                                 hex(a.qty(self.step(self.FIRST)['tx']['nonce'])+1)])
        with self.assertRaises(a.Gate) as c:
            self.send()
        self.assertEqual(c.exception.record['gate'], 'send_final_nonce_latest')
        self.assertEqual(self.broadcasts, [])

    # --- after the broadcast: receipt, status, mined fields and post-state on both endpoints; never a retry
    def test_reverted_step(self):
        self.before_broadcast = lambda: self.set_slot(self.addr['AOAProtocolRegistry'], REVERT_SLOT, SEL['transfer']+1)
        self.stop('send_receipt_status', broadcast=True)

    def test_receipt_gas(self):
        known, limit = self.known(), a.qty(self.step(self.FIRST)['tx']['gas'])
        def over(p, r):
            return r if p[0] in known or r is None else dict(r, gasUsed=hex(limit+1))
        def both():
            for _, ep in self.endpoints:
                ep.tamper['eth_getTransactionReceipt'] = over
        self.before_broadcast = both
        self.stop('send_receipt_gas', broadcast=True)

    def test_receipt_hash(self):
        known = self.known()
        self.endpoints[0][1].tamper['eth_getTransactionReceipt'] = lambda p, r: (
            r if p[0] in known or r is None else dict(r, transactionHash='0x'+'ef'*32))
        self.stop('send_receipt_hash', broadcast=True)

    def test_block_not_canonical_on_secondary(self):
        def fork(p, r):
            return dict(r, hash='0x'+'cc'*32) if p[0] != 'latest' else r
        self.before_broadcast = lambda: self.endpoints[1][1].tamper.__setitem__('eth_getBlockByNumber', fork)
        self.stop('send_block_canonical', broadcast=True)

    def test_post_safe_nonce(self):
        self.before_broadcast = lambda: self.set_slot(u.SAFE, SEL['nonce'], self.step(self.FIRST)['safeNonce']+5)
        self.stop('send_post_safe_nonce', broadcast=True)

    def known(self):
        return {x['hash'] for x in self.prior_records}

    def test_secondary_never_sees_receipt(self):
        known = self.known()
        self.endpoints[1][1].tamper['eth_getTransactionReceipt'] = lambda p, r: r if p[0] in known else None
        self.stop('send_secondary_receipt_timeout', broadcast=True)

    def test_secondary_receipt_differs(self):
        known = self.known()
        self.endpoints[1][1].tamper['eth_getTransactionReceipt'] = lambda p, r: (
            r if p[0] in known or r is None else dict(r, gasUsed=hex(int(r['gasUsed'], 16)+1)))
        self.stop('send_secondary_receipt_agree', broadcast=True)

    def test_secondary_readback(self):
        target = self.addr['AOAProtocolRegistry']
        def owner(p, r):
            return '0x'+'00'*31+'01' if p[0].get('to') == target and p[0]['data'] == '0x8da5cb5b' else r
        self.before_broadcast = lambda: self.endpoints[1][1].tamper.__setitem__('eth_call', owner)
        rec = self.stop('readback_owner()', broadcast=True)
        self.assertEqual(rec['observed']['step'], self.FIRST)

    def test_secondary_post_nonce(self):
        def bump(p, r):
            return hex(int(r, 16)+1)
        self.before_broadcast = lambda: self.endpoints[1][1].tamper.__setitem__('eth_getTransactionCount', bump)
        self.stop('send_post_nonce', broadcast=True)

    def test_secondary_mined_fields(self):
        def mined(p, r):
            return dict(r, input='0x00') if r and r.get('to') == self.addr['AOAProtocolRegistry'] else r
        self.before_broadcast = lambda: self.endpoints[1][1].tamper.__setitem__('eth_getTransactionByHash', mined)
        self.stop('send_mined_input', broadcast=True)

    def test_secondary_block_timestamp(self):
        def ts(p, r):
            return dict(r, timestamp=hex(int(r['timestamp'], 16)+1)) if p[0] != 'latest' else r
        self.before_broadcast = lambda: self.endpoints[1][1].tamper.__setitem__('eth_getBlockByNumber', ts)
        self.stop('send_timestamp_agree', broadcast=True)

    def test_returned_hash_mismatch(self):
        real = sd.broadcast
        with mock.patch.object(sd, 'broadcast', lambda url, raw: (real(url, raw), '0x'+'ee'*32)[1]):
            self.stop('send_returned_hash', broadcast=True)

    def test_broadcast_error_is_monitored_not_retried(self):
        def rejected(url, raw):
            self.broadcasts.append((url, raw))
            raise a.Gate('send_broadcast_rejected', -32000, 'transaction hash')
        with mock.patch.object(sd, 'broadcast', rejected), mock.patch.object(ms, 'RECEIPT_WAIT_SECONDS', 0.3):
            rec = self.stop('send_receipt_timeout', broadcast=True)
        self.assertEqual(rec['observed']['broadcast'], 'unknown')


SIGNED_FIELDS = {'nonce': ('--nonce', 'send_signed_nonce', '99'), 'gas': ('--gas-limit', 'send_signed_gas', '130001'),
                 'max_fee': ('--gas-price', 'send_signed_maxFeePerGas', '20000000001'),
                 'priority_fee': ('--priority-gas-price', 'send_signed_maxPriorityFeePerGas', '100000001'),
                 'value': ('--value', 'send_signed_value', '1'), 'chain': ('--chain', 'send_signed_chainId', '31337'),
                 'to': ('to', 'send_signed_to', '0x'+'12'*20), 'input': ('data', 'send_signed_input', '0x00')}
for _name, (_flag, _gate, _value) in SIGNED_FIELDS.items():
    setattr(SendTests, 'test_signed_'+_name, lambda self, f=_flag, g=_gate, v=_value: self.signed_field(f, g, v))


class B4Tests(AnvilCase):
    FIRST, LAST = 'B4', 'B4'

    @classmethod
    def prepare_targets(cls):
        step = cls.plan['steps'][cls.first_index]
        cls.generic(u.SAFE, {SEL['nonce']: step['safeNonce']})
        cls.generic(cls.addr['BLSAggregator'], {SEL['ready']: 1})

    def verifier(self):
        return int(self.addr['OverIssueFraudProofVerifier'], 16)

    def test_placeholder_when_already_applied(self):
        self.generic(self.addr['BLSAggregator'], {SEL['verifier']: self.verifier(), SEL['ready']: 0})
        self.send()
        sent = json.loads((self.out/'sent.json').read_text())['sent'][0]
        self.assertEqual(sent['variant'], 'placeholder')
        mined = self.local('eth_getTransactionByHash', [sent['hash']])
        self.assertEqual((mined['to'], mined['input']), (TEST_ADDR['deployer'], '0x'))
        self.assertEqual(self.nonce(), a.qty(self.step('B4')['tx']['nonce'])+1)

    def test_frontrun_apply_status_zero_with_post_state_continues(self):
        agg = self.addr['BLSAggregator']
        def frontrun():
            self.set_slot(agg, REVERT_SLOT, SEL['apply']+1)
            self.set_slot(agg, SEL['verifier'], self.verifier())
            self.set_slot(agg, SEL['ready'], 0)
        self.before_broadcast = frontrun
        self.send()
        sent = json.loads((self.out/'sent.json').read_text())['sent'][0]
        self.assertEqual(sent['variant'], 'apply')
        self.assertEqual(self.local('eth_getTransactionReceipt', [sent['hash']])['status'], '0x0')
        readback = json.loads((self.out/'readback.B4.json').read_text())
        self.assertEqual(readback['status'], '0x0')

    def test_apply_status_zero_without_post_state_stops(self):
        agg = self.addr['BLSAggregator']
        def wrong():
            self.set_slot(agg, REVERT_SLOT, SEL['apply']+1)
            self.set_slot(agg, SEL['verifier'], 0x1234)
            self.set_slot(agg, SEL['ready'], 0)
        self.before_broadcast = wrong
        self.stop('readback_fraudProofVerifier()', broadcast=True)

    def test_placeholder_status_zero_is_never_allowed(self):
        receipt = dict(status='0x0', gasUsed='0x5208')
        with self.assertRaises(a.Gate) as c:
            ms.check_status(self.step('B4'), 'placeholder', receipt, self.step('B4')['variants']['placeholder'])
        self.assertEqual(c.exception.record['gate'], 'send_receipt_status')
        ms.check_status(self.step('B4'), 'apply', receipt, self.step('B4')['tx'])

    def test_endpoints_disagree_on_variant(self):
        self.endpoints[1][1].tamper['eth_call'] = lambda p, r: (word(self.verifier()) if p[0]['data'] == '0x3c396ea4' else r)
        self.stop('send_b4_variant_agree')

    def test_apply_not_ready(self):
        self.set_slot(self.addr['BLSAggregator'], SEL['ready'], 2**40)
        self.stop('send_b4_ready')


class FinalTests(AnvilCase):
    """The packet's last step: its read-back plus the final state, read live on both endpoints."""
    FIRST = LAST = 'D.old_aggregator.transfer'

    @classmethod
    def prepare_targets(cls):
        step = cls.plan['steps'][cls.first_index]
        cls.generic(u.SAFE, {SEL['nonce']: step['safeNonce']})
        admin = int(a.calldata('slashPolicyAdmin()')[:10], 16)
        pending = int(a.calldata('pendingOwner()')[:10], 16)
        for name, target, owner in m.handover_contracts(cls.addr):
            slots = {SEL['owner']: int(owner, 16), admin: int(u.SAFE, 16)}
            if name == 'old_aggregator':
                slots[SEL['owner']] = int(TEST_ADDR['deployer'], 16)
            cls.generic(target, slots)
        cls.generic(u.SP, {SEL['owner']: int(u.TL, 16)})
        cls.generic(cls.plan['pin']['capped'], {int(a.calldata('balanceOf(address)', u.SP)[:10], 16): m.BUFFER})
        cls.set_slot(u.REG, pending, 0)

    def setUp(self):
        super().setUp()
        self.frozen = []
        accounting = dict(totalTrackedBalance=m.BUFFER, protocolRevenue=m.BUFFER, operatorBalances={})
        self.accounting = accounting
        # Registry role configuration and the 9-word operator tuples are not modelled by the generic contract.
        for p in (mock.patch.object(m, 'assert_manifest_frozen', lambda rpc, pin, handed: self.frozen.append((rpc.name, handed))),
                  mock.patch.object(m, 'balances', lambda rpc, ops: copy.deepcopy(self.accounting))):
            p.start()
            self.addCleanup(p.stop)

    def test_last_step_runs_final_readback_on_both_endpoints(self):
        self.send()
        self.assertEqual(self.frozen, [('primary', True), ('secondary', True)])
        readback = json.loads((self.out/('readback.%s.json' % self.FIRST)).read_text())['readbacks']
        self.assertEqual(sorted(readback), ['primary', 'secondary'])
        self.assertEqual(readback['secondary']['final']['protocolRevenue'], m.BUFFER)
        self.assertEqual(a.address(self.local, m.OLD_AGGREGATOR, 'owner()'), u.SAFE)

    def test_final_owner_differs_on_secondary(self):
        target = self.addr['xPNTsFactoryV2']
        def owner(p, r):
            return word(int(TEST_ADDR['deployer'], 16)) if p[0].get('to') == target and p[0]['data'] == '0x8da5cb5b' else r
        self.before_broadcast = lambda: self.endpoints[1][1].tamper.__setitem__('eth_call', owner)
        self.stop('readback_owner()', broadcast=True)

    def test_final_accounting(self):
        self.accounting['protocolRevenue'] = m.BUFFER+1
        self.stop('post_swap_revenue', broadcast=True)


class TimingTests(unittest.TestCase):
    """Readiness gates the fork rehearsal satisfies by warping; live they STOP until the time has come."""
    def setUp(self):
        case, self.plan = frozen_packet()
        case.doCleanups()

    def rpc(self, now, values):
        def call(method, params):
            if method == 'eth_getBlockByNumber':
                return {'hash': '0x'+'11'*32, 'number': '0x10', 'timestamp': hex(now), 'baseFeePerGas': '0x1'}
            if method == 'eth_call':
                return values[params[0]['data'][:10]]
            raise AssertionError(method)
        return call

    def step(self, sid):
        return next(s for s in self.plan['steps'] if s['id'] == sid)

    def timelock(self, ready):
        step = self.step('upgrade_execute_exec')
        return step, {a.calldata('getTimestamp(bytes32)', self.plan['operations']['upgrade']['id'])[:10]: word(ready)}

    def test_timelock_ready(self):
        step, values = self.timelock(1000)
        ms.timing_gate(self.rpc(1000, values), self.plan, step, None)
        with self.assertRaises(a.Gate) as c:
            ms.timing_gate(self.rpc(999, values), self.plan, step, None)
        self.assertEqual(c.exception.record['gate'], 'send_timelock_ready')

    def test_timelock_unscheduled_or_done(self):
        for ready in (0, 1):
            step, values = self.timelock(ready)
            with self.subTest(ready=ready), self.assertRaises(a.Gate) as c:
                ms.timing_gate(self.rpc(10**10, values), self.plan, step, None)
            self.assertEqual(c.exception.record['gate'], 'send_timelock_scheduled')

    def test_activation_schedule_floor(self):
        step = self.step('activation_schedule_approve')
        floor = self.plan['activationScheduleNotBefore']
        gas = '0x'+''.join(format(v, '064x') for v in [0]*8+[floor-5]+[0])
        values = {a.calldata('gasParams()')[:10]: gas}
        ms.timing_gate(self.rpc(floor, values), self.plan, step, None)
        with self.assertRaises(a.Gate) as c:
            ms.timing_gate(self.rpc(floor-1, values), self.plan, step, None)
        self.assertEqual(c.exception.record['gate'], 'send_activation_schedule_floor')

    def test_receipt_core_ignores_optional_log_positions_only(self):
        log = {'address': u.SAFE, 'topics': ['0x'+'01'*32], 'data': '0x'}
        r = {'transactionHash': '0x'+'02'*32, 'blockHash': '0x'+'03'*32, 'blockNumber': '0x5', 'gasUsed': '0x5208',
             'status': '0x1', 'contractAddress': None, 'logs': [dict(log, logIndex='0x0', transactionIndex='0x0')]}
        self.assertEqual(ms.receipt_core(dict(r, logs=[log])), ms.receipt_core(r))
        self.assertNotEqual(ms.receipt_core(dict(r, logs=[dict(log, data='0x00')])), ms.receipt_core(r))
        self.assertNotEqual(ms.receipt_core(dict(r, gasUsed='0x5209')), ms.receipt_core(r))

    def test_repin_threshold_is_floor_of_limit_over_1_1(self):
        for limit in (130000, 130001, 21000, 1, 11, 10, 16777216):
            self.assertEqual(ms.repin_threshold(limit), int(limit*10)//11)
            self.assertLessEqual(ms.repin_threshold(limit)*1.1, limit+1e-9)


class PasswordFileTests(unittest.TestCase):
    """Outside the repository; mode 0600 or stricter; private directory; metadata only."""
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name)/'pw'
        self.dir.mkdir(mode=0o700)
        self.file = self.dir/'password'
        self.file.write_text('never read by the sender')
        self.file.chmod(0o600)

    def gate(self, path=None):
        with self.assertRaises(a.Gate) as c:
            ms.password_file_check(path or self.file)
        return c.exception.record['gate']

    def test_owner_only_modes_accepted(self):
        for mode in (0o600, 0o400):
            self.file.chmod(mode)
            ms.password_file_check(self.file)

    def test_mode_too_open(self):
        for mode in (0o644, 0o640, 0o604, 0o700, 0o200, 0o000):
            with self.subTest(mode=oct(mode)):
                self.file.chmod(mode)
                self.assertEqual(self.gate(), 'send_password_mode')

    def test_inside_repository(self):
        with tempfile.TemporaryDirectory(dir=str(ms.ROOT)) as inside:
            d = Path(inside)
            d.chmod(0o700)
            f = d/'password'
            f.write_text('x')
            f.chmod(0o600)
            self.assertEqual(self.gate(f), 'send_password_outside_repo')

    def test_symlink(self):
        link = self.dir/'link'
        link.symlink_to(self.file)
        self.assertEqual(self.gate(link), 'send_password_symlink')

    def test_directory_open_to_others(self):
        self.dir.chmod(0o755)
        self.addCleanup(self.dir.chmod, 0o700)
        self.assertEqual(self.gate(), 'send_password_dir_mode')

    def test_not_a_regular_file(self):
        self.assertEqual(self.gate(self.dir/'missing'), 'send_password_file')
        sub = self.dir/'sub'
        sub.mkdir(mode=0o700)
        self.assertEqual(self.gate(sub), 'send_password_regular')


class PacketTests(unittest.TestCase):
    """The real manifest_exec.validate_plan(frozen=True) against the fixture packet; nothing is signed."""
    def setUp(self):
        self.case, plan = frozen_packet()
        self.addCleanup(self.case.doCleanups)
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.d = Path(self.tmp.name)
        self.plan = plan

    def load(self, plan, sha=None):
        raw = json.dumps(plan, indent=2, sort_keys=True).encode()
        (self.d/'plan.json').write_bytes(raw)
        out = self.d/('out%d' % len(list(self.d.glob('out*'))))
        out.mkdir()
        args = SimpleNamespace(packet=self.d/'plan.json', approved_sha256=sha or hashlib.sha256(raw).hexdigest(), out=out)
        return ms.load_packet(args), out

    def gate(self, plan, sha=None):
        with self.assertRaises(a.Gate) as c:
            self.load(plan, sha)
        return c.exception.record['gate']

    def test_frozen_fixture_packet_accepted(self):
        plan, out = self.load(self.plan)
        self.assertEqual(plan, self.plan)
        self.assertEqual((out/'packet.approved.json').read_bytes(), (self.d/'plan.json').read_bytes())

    def test_approved_sha256(self):
        self.assertEqual(self.gate(self.plan, 'a'*64), 'packet_approved_sha256')

    def test_tampered_packet_rejected_by_validate_plan(self):
        bad = copy.deepcopy(self.plan)
        bad['steps'][3]['tx']['data'] = bad['steps'][3]['tx']['data'][:-2]+'00'
        self.assertEqual(self.gate(bad), 'manifest_tx_data')

    def test_stage_artifact_rejected(self):
        bad = copy.deepcopy(self.plan)
        bad['stage'] = 'a7'
        self.assertEqual(self.gate(bad), 'final_artifact')

    def test_stage_missing(self):
        bad = copy.deepcopy(self.plan)
        bad.pop('stage')
        self.assertEqual(self.gate(bad), 'packet_stage')

    def test_unfrozen_packet_rejected(self):
        bad = copy.deepcopy(self.plan)
        bad.pop('budgetsWei')
        self.assertEqual(self.gate(bad), 'manifest_keys')


class CliTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.d = Path(self.tmp.name)
        for name in ('a', 'b'):
            (self.d/name).write_text('http://127.0.0.1:1/'+name)
        self.argv = ['--packet', str(self.d/'missing.json'), '--approved-sha256', 'a'*64, '--first', 'A1',
                     '--rpc-file', str(self.d/'a'), '--rpc-file-secondary', str(self.d/'b'),
                     '--accounts', str(self.d/'acc'), '--password-file', str(self.d/'pw'), '--out', str(self.d/'out')]

    def main(self, env, argv=None):
        err = io.StringIO()
        with mock.patch.dict(os.environ, env, clear=False), contextlib.redirect_stderr(err), \
                mock.patch.object(sd, 'LOCK_PATH', self.d/'lock'):
            if ms.ENABLE_ENV not in env:
                os.environ.pop(ms.ENABLE_ENV, None)
            return ms.main(argv or self.argv), err.getvalue()

    def test_disabled_by_default(self):
        rc, err = self.main({})
        self.assertEqual(rc, 3)
        self.assertIn('disabled', err)
        self.assertFalse((self.d/'out').exists())

    def test_enable_names_another_packet(self):
        rc, err = self.main({ms.ENABLE_ENV: 'b'*64})
        self.assertEqual(rc, 3)
        self.assertIn('does not name the approved packet', err)
        self.assertFalse((self.d/'out').exists())

    def test_endpoints_must_differ(self):
        (self.d/'b').write_text((self.d/'a').read_text())
        rc, err = self.main({ms.ENABLE_ENV: 'a'*64})
        self.assertEqual(rc, 1)
        record = json.loads((self.d/'out'/'FAILURE.json').read_text())
        self.assertEqual(record['gate'], 'send_independent_endpoints')
        self.assertNotIn('127.0.0.1:1/a', json.dumps(record))

    def test_manifest_exec_refusal_unchanged(self):
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            self.assertEqual(m.main(['send']), 3)
            self.assertEqual(m.main(['sign']), 3)
        self.assertIn('not implemented', err.getvalue())


if __name__ == '__main__':
    unittest.main()
