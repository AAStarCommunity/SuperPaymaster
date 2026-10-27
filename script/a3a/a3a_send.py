#!/usr/bin/env python3
"""A3a live sender: one reviewed step per invocation, signed with a Foundry keystore (DSR M1 gap IG-07).

NOT AUTHORISED TO RUN until DSR has reviewed this file and the author has given a separate go for the specific
plan sha256. `a3a_exec.py sign|send` stay disabled; this module is the only broadcast path, kept apart so that
a3a_exec.py itself still cannot broadcast.

Usage (run by the operator in a terminal: cast asks for the keystore password, and the confirmation is typed):
  python3 -B script/a3a/a3a_send.py --plan <plan.json> --reviewed-plan-sha256 <sha256 from the review> \
    --step S1 --rpc-file <file holding the RPC URL> --accounts <json: {"deployer": "<keystore name>", ...}> \
    --out <new empty dir>

Order of operations, each a hard stop on failure (nothing leaves this process unless every step before it passed):
  0. Read the plan once; its sha256 must equal the reviewed digest given out-of-band; a snapshot of those bytes
     is what every later step reads. A machine-wide lock keeps a second sender run from overlapping.
  1. a3a_exec.signing_transaction on the snapshot: frozen-plan validation, Safe hash recheck for S5/S6, and
     pre_send (chain, code, predecessor readback, latest == pending == planned nonce, Safe nonce, fresh
     estimateGas <= planned gas).
  2. `cast mktx --account <name>` offline: the signer's environment is a whitelist with no RPC variable, and
     argv carries no URL; every field comes from the plan (type 2, chain, nonce, gas, both fee caps, value,
     to or --create, data).
  3. Local verification: `cast decode-transaction` fields and signer equal the plan, no access list or
     authorization list, and a local keccak of the raw bytes equals the decoded hash. Nothing is sent to any
     provider here.
  4. The operator types `SEND <step> <first 12 hex of the plan sha256>`.
  5. After the confirmation, immediately before broadcast: pre_send again (it must return the identical
     transaction) and the latest base fee plus the planned priority fee must fit under the planned max fee.
  6. eth_sendRawTransaction; the returned hash must equal the signed hash. Then wait for the receipt (no
     resend, no replacement: a stuck transaction is reported, not repriced). Status must be 0x1 and gasUsed
     <= planned gas; eth_getTransactionByHash must equal the plan. After S7 the final readback runs.
Artefacts go to --out (0700): unsigned tx, decoded fields without the signature, the allowlisted receipt, and
signed.raw only after broadcast. The RPC URL and provider-supplied text are never written or printed.
"""
import argparse, contextlib, fcntl, hashlib, json, os, re, subprocess, sys, time, urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import a3a_exec as ex  # noqa: E402

CAST = os.environ.get('A3A_CAST', str(Path.home()/'.foundry/bin/cast'))
RECEIPT_WAIT_SECONDS = 600
SIGNER_ENV_KEYS = ('HOME', 'PATH', 'TERM', 'LANG', 'USER')
LOCK_PATH = Path.home()/'.a3a_send.lock'  # one sender at a time on this machine; other machines are out of reach


def signer_env():
    """Built at call time from a whitelist: nothing RPC-related (ETH_RPC_URL, RPC_*) can reach cast."""
    return {k: v for k, v in os.environ.items() if k in SIGNER_ENV_KEYS}


@contextlib.contextmanager
def sender_lock():
    with open(LOCK_PATH, 'a') as f:
        try:
            fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ex.Gate('send_lock_busy', str(LOCK_PATH), 'no other a3a_send run on this machine') from None
        try:
            yield
        finally:
            fcntl.flock(f, fcntl.LOCK_UN)


def role_of(plan, address):
    roles = [r for r, s in plan['pin']['senders'].items() if s['address'].lower() == address.lower()]
    ex.need('send_sender_role', len(roles), 1)
    return roles[0]


def sign(tx, account):
    """Offline signature by cast with a keystore; the password prompt goes to the operator's terminal."""
    cmd = [CAST, 'mktx', '--account', account, '--chain', str(ex.CHAIN),
           '--nonce', str(ex.qty(tx['nonce'])), '--gas-limit', str(ex.qty(tx['gas'])),
           '--gas-price', str(ex.qty(tx['maxFeePerGas'])), '--priority-gas-price', str(ex.qty(tx['maxPriorityFeePerGas'])),
           '--value', str(ex.qty(tx['value']))]
    cmd += ['--create', tx['data']] if tx.get('to') is None else [tx['to'], tx['data']]
    r = subprocess.run(cmd, env=signer_env(), stdout=subprocess.PIPE, text=True)  # stdin/stderr: the terminal
    ex.need('send_sign_exit', r.returncode, 0)
    raw = r.stdout.strip()
    ex.need('send_sign_output', raw.startswith('0x02') and all(c in '0123456789abcdef' for c in raw[2:].lower()), True)
    return raw


def decode(raw):
    # The signed bytes go through stdin, never argv (argv is visible to other local users).
    r = subprocess.run([CAST, 'decode-transaction'], input=raw, env=signer_env(), capture_output=True, text=True)
    ex.need('send_decode_exit', r.returncode, 0)
    out = json.loads(r.stdout)
    return json.loads(out) if isinstance(out, str) else out


def local_keccak(raw):
    r = subprocess.run([CAST, 'keccak'], input=raw, env=signer_env(), capture_output=True, text=True)
    ex.need('send_keccak_exit', r.returncode, 0)
    return ex.typed(r.stdout.strip(), ex.HASH32).lower()


def check_signed(decoded, tx):
    expected = {'type': '0x2', 'chainId': hex(ex.CHAIN), 'nonce': hex(ex.qty(tx['nonce'])),
                'gas': hex(ex.qty(tx['gas'])), 'maxFeePerGas': hex(ex.qty(tx['maxFeePerGas'])),
                'maxPriorityFeePerGas': hex(ex.qty(tx['maxPriorityFeePerGas'])), 'value': hex(ex.qty(tx['value'])),
                'to': None if tx.get('to') is None else tx['to'].lower(), 'input': tx['data'].lower(),
                'accessList': [], 'signer': tx['from'].lower()}
    seen = {k: (decoded.get(k).lower() if isinstance(decoded.get(k), str) else decoded.get(k)) for k in expected}
    for k in expected:
        ex.need('send_signed_'+k, seen[k], expected[k])
    ex.need('send_signed_no_authorizations', decoded.get('authorizationList') in (None, []), True)
    return ex.typed(decoded.get('hash'), ex.HASH32).lower()


def fee_fits(remote, tx):
    base = ex.qty(remote('eth_getBlockByNumber', ['latest', False])['baseFeePerGas'])
    ex.need('send_fee_cap', base + ex.qty(tx['maxPriorityFeePerGas']) <= ex.qty(tx['maxFeePerGas']), True)


def broadcast(url, raw):
    """The one write call. Kept outside ex.RPC, which refuses every non-read method."""
    q = json.dumps({'jsonrpc': '2.0', 'id': 1, 'method': 'eth_sendRawTransaction', 'params': [raw]}).encode()
    try:
        with urllib.request.urlopen(urllib.request.Request(url, q, {'Content-Type': 'application/json'}), timeout=45) as r:
            d = json.loads(r.read())
    except Exception as e:  # never echo the exception text: it can carry the URL
        raise ex.Gate('send_broadcast_transport', type(e).__name__, 'JSON-RPC response') from None
    # Nothing the provider returns is recorded verbatim: an integer error code, or a validated hash.
    if not isinstance(d, dict) or 'error' in d:
        err = d.get('error') if isinstance(d, dict) else None
        code = err.get('code') if isinstance(err, dict) else None
        raise ex.Gate('send_broadcast_rejected', code if type(code) is int else 'non-integer', 'transaction hash')
    result = d.get('result')
    if not isinstance(result, str) or not ex.HASH32.fullmatch(result):
        raise ex.Gate('send_broadcast_result', 'malformed', 'transaction hash')
    return result.lower()


def wait_receipt(remote, h, tx):
    deadline = time.monotonic() + RECEIPT_WAIT_SECONDS
    while time.monotonic() < deadline:
        r = remote('eth_getTransactionReceipt', [h])
        if r is not None:
            r = clean_receipt(r)
            ex.need('send_receipt_hash', r['transactionHash'], h)
            ex.need('send_receipt_status', r['status'], '0x1')
            ex.need('send_receipt_gas', ex.qty(r['gasUsed']) <= ex.qty(tx['gas']), True)
            return r
        time.sleep(4)
    raise ex.Gate('send_receipt_timeout', h, 'mined within %ds; do not resend or reprice without review' % RECEIPT_WAIT_SECONDS)


def field(value, rx, name):
    """Validate a provider value before it is compared or recorded; a failure records no provider text."""
    if not isinstance(value, str) or not rx.fullmatch(value):
        raise ex.Gate('send_provider_'+name, 'malformed', rx.pattern)
    return value.lower()


def clean_receipt(r):
    """Allowlisted, validated receipt: the only receipt form that is compared, persisted or read back."""
    if not isinstance(r, dict) or not isinstance(r.get('logs'), list):
        raise ex.Gate('send_provider_receipt', 'malformed', 'receipt object')
    if r.get('status') not in ('0x0', '0x1'):
        raise ex.Gate('send_provider_status', 'malformed', '0x0 | 0x1')
    out = {'transactionHash': field(r.get('transactionHash'), ex.HASH32, 'transactionHash'),
           'blockHash': field(r.get('blockHash'), ex.HASH32, 'blockHash'),
           'blockNumber': field(r.get('blockNumber'), ex.QTY, 'blockNumber'),
           'gasUsed': field(r.get('gasUsed'), ex.QTY, 'gasUsed'), 'status': r['status'],
           'contractAddress': None if r.get('contractAddress') is None
           else field(r.get('contractAddress'), ex.ADDRESS_RX, 'contractAddress'),
           'logs': []}
    for log in r['logs']:
        if not isinstance(log, dict) or not isinstance(log.get('topics'), list):
            raise ex.Gate('send_provider_log', 'malformed', 'log object')
        entry = {'address': field(log.get('address'), ex.ADDRESS_RX, 'logAddress'),
                 'topics': [field(x, ex.HASH32, 'logTopic') for x in log['topics']],
                 'data': field(log.get('data'), ex.HEXDATA, 'logData')}
        for k in ('blockNumber', 'transactionIndex', 'logIndex'):
            if k in log:
                entry[k] = field(log[k], ex.QTY, 'log'+k)
        out['logs'].append(entry)
    return out


def check_mined(remote, h, tx):
    m = remote('eth_getTransactionByHash', [h])
    if not isinstance(m, dict):
        raise ex.Gate('send_provider_tx', 'malformed', 'transaction object')
    for k in ('nonce', 'gas', 'maxFeePerGas', 'maxPriorityFeePerGas', 'value'):
        field(m.get(k), ex.QTY, k)
    m = dict(m, **{'from': field(m.get('from'), ex.ADDRESS_RX, 'from'), 'input': field(m.get('input'), ex.HEXDATA, 'input'),
                   'to': None if m.get('to') is None else field(m.get('to'), ex.ADDRESS_RX, 'to')})
    for k in ('nonce', 'gas', 'maxFeePerGas', 'maxPriorityFeePerGas', 'value'):
        ex.need('send_mined_'+k, ex.qty(m[k]), ex.qty(tx[k]))
    ex.need('send_mined_from', m['from'].lower(), tx['from'].lower())
    ex.need('send_mined_to', m['to'], tx.get('to') and tx['to'].lower())
    ex.need('send_mined_input', m['input'].lower(), tx['data'].lower())


def signed(tx, account):
    """Sign and verify locally. The signed bytes leave this process only in broadcast()."""
    raw = sign(tx, account)
    decoded = decode(raw)
    h = check_signed(decoded, tx)
    ex.need('send_signed_hash', local_keccak(raw), h)  # local keccak over the raw bytes, not cast's decoder
    return raw, h, decoded


def run(args, remote, url, confirm=None):
    """The caller holds sender_lock() and owns args.out (see main)."""
    # One read of the plan; every later consumer uses these bytes or the snapshot written from them.
    raw_plan = args.plan.read_bytes()
    ex.need('reviewed_plan_hash', hashlib.sha256(raw_plan).hexdigest(), args.reviewed_plan_sha256)
    snapshot = args.out/'plan.reviewed.json'
    snapshot.write_bytes(raw_plan)
    plan = ex.plan_json(raw_plan)
    tx = ex.signing_transaction(snapshot, args.reviewed_plan_sha256, args.step, remote)
    role = role_of(plan, tx['from'])
    accounts = json.loads(args.accounts.read_text())
    ex.need('send_account_named', isinstance(accounts.get(role), str) and accounts[role] != '', True)
    ex.write_json(args.out/'unsigned.json', tx)
    raw, h, decoded = signed(tx, accounts[role])  # held in memory only until broadcast
    ex.write_json(args.out/'decoded.json', {k: v for k, v in decoded.items() if k not in ('r', 's', 'v', 'yParity')})
    phrase = 'SEND %s %s' % (args.step, args.reviewed_plan_sha256[:12])
    typed = (confirm or input)('Type "%s" to broadcast %s from %s (%s): ' % (phrase, h, tx['from'], role)).strip()
    ex.need('send_operator_confirmation', typed, phrase)
    # Every live check again after the (unbounded) confirmation pause, immediately before broadcast.
    again = ex.signing_transaction(snapshot, args.reviewed_plan_sha256, args.step, remote)
    ex.need('send_tx_stable', again, tx)
    fee_fits(remote, tx)
    sent = broadcast(url, raw)
    (args.out/'signed.raw').write_text(raw+'\n')  # public once broadcast; never on disk before
    ex.need('send_returned_hash', sent, h)
    r = wait_receipt(remote, h, tx)
    check_mined(remote, h, tx)
    ex.write_json(args.out/'receipt.json', r)
    if args.step == ex.STEP_IDS[-1]:
        context = {'tlBlock': hex(int(plan['pin']['block'], 16)+1), 'eta': ex.scheduled_eta(remote, plan, done=True)}
        ex.readback(remote, plan, plan['steps'][-1], r, context)
    result = dict(status='SENT', step=args.step, role=role, hash=h, block=r['blockNumber'],
                  gasUsed=ex.qty(r['gasUsed']), planSha256=hashlib.sha256(raw_plan).hexdigest())
    ex.write_json(args.out/'result.json', result)
    return result


SAFE_TEXT_MAX = 130  # a 64-byte hex word; longer hex (bytecode, calldata) is redacted to its length


def scrub(value, url):
    """FAILURE.json `observed`: gate records from a3a_exec can carry raw provider results there.

    Kept: integers, booleans, None, and short 0x-hex strings (hashes, addresses, quantities, words), which cannot
    carry a URL or key unless the provider's own hex output is the secret. Everything else, and anything containing
    the RPC URL or one of its path/query tokens, becomes a length-only placeholder.
    """
    tokens = {s for s in re.split(r'[/?&=:#@.]+', url) if len(s) >= 6}
    def clean(v):
        if v is None or isinstance(v, (bool, int)):
            return v
        if isinstance(v, (list, tuple)):
            return [clean(x) for x in v]
        if isinstance(v, dict):
            return {str(k) if re.fullmatch(r'[A-Za-z0-9_]{1,64}', str(k)) else '<key>': clean(x) for k, x in v.items()}
        s = str(v)
        if len(s) <= SAFE_TEXT_MAX and re.fullmatch(r'0x[0-9a-fA-F]*', s) and not any(tok in s for tok in tokens):
            return s
        return '<redacted %d chars>' % len(s)
    return clean(value)


def main(argv=None):
    p = argparse.ArgumentParser()
    p.add_argument('--plan', type=Path, required=True)
    p.add_argument('--reviewed-plan-sha256', required=True)
    p.add_argument('--step', required=True, choices=ex.STEP_IDS)
    p.add_argument('--rpc-file', type=Path, required=True)
    p.add_argument('--accounts', type=Path, required=True)
    p.add_argument('--out', type=Path, required=True)
    args = p.parse_args(argv)
    os.umask(0o077)  # every artefact, and the output directory, private to the operator
    try:
        with sender_lock():  # held from before the output directory is claimed until FAILURE.json is written
            if args.out.exists():
                ex.need('output_empty', args.out.is_dir() and not any(args.out.iterdir()), True)
            args.out.mkdir(parents=True, exist_ok=True)
            os.chmod(args.out, 0o700)
            url = args.rpc_file.read_text().strip()
            try:
                print(json.dumps(run(args, ex.RPC(url), url), indent=2))
            except ex.Gate as e:
                # Only into the directory this run verified empty, never over earlier evidence; still locked.
                # gate/status/expected come from code and the reviewed plan; only `observed` can hold provider data.
                ex.write_json(args.out/'FAILURE.json', dict(e.record, step=args.step, observed=scrub(e.record.get('observed'), url)))
                raise
        return 0
    except ex.Gate as e:
        print('FAILURE: '+e.record['gate'], file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
