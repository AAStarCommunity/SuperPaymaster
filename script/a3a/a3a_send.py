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
  0. A per-user lock is taken before the output directory is claimed. Read the plan once; its sha256 must equal
     the reviewed digest given out-of-band; a snapshot of those bytes is what every later step reads.
  1. a3a_exec.signing_transaction on the snapshot: frozen-plan validation, Safe hash recheck for S5/S6, and
     pre_send (chain, code, predecessor readback, latest == pending == planned nonce, Safe nonce, fresh
     estimateGas <= planned gas).
  2. `cast mktx --account <name>` offline: the signer's environment is a whitelist with no RPC variable, and
     argv carries no URL; every field comes from the plan (type 2, chain, nonce, gas, both fee caps, value,
     to or --create, data).
  3. Local verification: `cast decode-transaction` fields and signer equal the plan, no access list or
     authorization list, and a local keccak of the raw bytes equals the decoded hash. Nothing is sent to any
     provider here.
  4. The operator types `SEND <step> <first 12 hex of the plan sha256>` at the terminal (/dev/tty; no terminal,
     no send).
  5. After the confirmation, immediately before broadcast: pre_send again (it must return the identical
     transaction) and the latest base fee plus the planned priority fee must fit under the planned max fee.
  6. broadcast.json ("attempting", hash) is written first; then eth_sendRawTransaction under a total deadline.
     Any reply other than the signed hash (timeout, malformed, error such as "already known") is outcome
     "unknown"; another hash is "accepted_hash_mismatch". In every case the run monitors the local hash
     (tolerating transient RPC failures), evidence writes are best effort, and any failure ends as
     send_after_broadcast with the hash. No resend, no replacement: a stuck transaction is reported, not repriced. Status must be 0x1 and gasUsed
     <= planned gas; eth_getTransactionByHash must equal the plan. After S7 the final readback runs.
Artefacts go to --out (0700): unsigned tx, decoded fields without the signature, the allowlisted receipt, and
signed.raw only after broadcast. The RPC URL and provider-supplied text are never written or printed.
"""
import argparse, contextlib, fcntl, hashlib, json, os, re, subprocess, sys, time, urllib.parse, urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import a3a_exec as ex  # noqa: E402

CAST = os.environ.get('A3A_CAST', str(Path.home()/'.foundry/bin/cast'))
RECEIPT_WAIT_SECONDS = 600
RECEIPT_TRANSIENT_MAX = 10  # consecutive RPC failures tolerated while waiting: the transaction may already be out
TRANSIENT_GATES = ('rpc_transport', 'rpc_envelope', 'rpc_fault')
DECODED_FIELDS = ('signer', 'type', 'chainId', 'nonce', 'gas', 'maxFeePerGas', 'maxPriorityFeePerGas', 'to', 'value',
                  'accessList', 'input', 'hash')  # what decoded.json keeps; never the signature
SIGNER_ENV_KEYS = ('HOME', 'PATH', 'TERM', 'LANG', 'USER')
TTY_PATH = '/dev/tty'
LOCK_PATH = Path.home()/'.a3a_send.lock'  # one sender at a time per user (HOME); other users or machines are out of reach


def signer_env():
    """Built at call time from a whitelist: nothing RPC-related (ETH_RPC_URL, RPC_*) can reach cast."""
    return {k: v for k, v in os.environ.items() if k in SIGNER_ENV_KEYS}


@contextlib.contextmanager
def sender_lock():
    with open(LOCK_PATH, 'a') as f:
        try:
            fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ex.Gate('send_lock_busy', str(LOCK_PATH), 'no other a3a_send run for this user') from None
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
    """The one write call: an explicit write transport. It reuses ex.RPC's wall-clock total-deadline poster
    (_post_with_deadline) but not ex.RPC.__call__, which refuses every non-read method; the envelope is checked
    here. Any failure is a Gate; run() treats every failure as "outcome unknown" and monitors by hash."""
    q = {'jsonrpc': '2.0', 'id': 1, 'method': 'eth_sendRawTransaction', 'params': [raw]}
    try:
        # Same wall-clock total deadline as every read (ex.RPC): a trickling server cannot hold the lock open.
        d = ex.RPC(url)._post_with_deadline(q)
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


def wait_receipt(remote, h, tx, tokens=frozenset()):
    deadline = time.monotonic() + RECEIPT_WAIT_SECONDS
    transient = 0
    while time.monotonic() < deadline:
        try:
            r = remote('eth_getTransactionReceipt', [h])
            transient = 0
        except ex.Gate as e:
            if e.record['gate'] not in TRANSIENT_GATES:
                raise
            transient += 1
            if transient > RECEIPT_TRANSIENT_MAX:
                raise ex.Gate('send_receipt_rpc', e.record['gate'], 'receipt reads recovering within %d tries' % RECEIPT_TRANSIENT_MAX) from None
            time.sleep(4)
            continue
        if r is not None:
            r = clean_receipt(r, tokens)
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


def clean_receipt(r, tokens=frozenset()):
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
    # Format validation alone lets a hex-encoded key through (e.g. as log data); refuse any URL token.
    if any(tok in json.dumps(out).lower() for tok in tokens):
        raise ex.Gate('send_provider_leak', 'redacted', 'no RPC URL token in provider data')
    return out


def check_mined(remote, h, tx, r):
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
    # Still in the block the receipt names: a reorg (or a pending answer) after the receipt is not success.
    ex.need('send_mined_blockHash', field(m.get('blockHash'), ex.HASH32, 'blockHash'), r['blockHash'])
    ex.need('send_mined_blockNumber', field(m.get('blockNumber'), ex.QTY, 'blockNumber'), r['blockNumber'].lower())


def signed(tx, account):
    """Sign and verify locally. The signed bytes leave this process only in broadcast()."""
    raw = sign(tx, account)
    decoded = decode(raw)
    h = check_signed(decoded, tx)
    ex.need('send_signed_hash', local_keccak(raw), h)  # local keccak over the raw bytes, not cast's decoder
    return raw, h, decoded


def tty_confirm(prompt):
    """The confirmation must come from the operator's terminal, not from piped or redirected input."""
    try:
        # Separate read and write streams: a buffered 'r+' text stream needs a seekable file, which a tty is not.
        with open(TTY_PATH, 'w') as out, open(TTY_PATH, 'r') as inp:
            out.write(prompt)
            out.flush()
            return inp.readline()
    except OSError:
        raise ex.Gate('send_no_tty', 'no controlling terminal', 'operator at a terminal') from None


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
    ex.write_json(args.out/'decoded.json', {k: decoded.get(k) for k in DECODED_FIELDS})
    phrase = 'SEND %s %s' % (args.step, args.reviewed_plan_sha256[:12])
    typed = (confirm or tty_confirm)('Type "%s" to broadcast %s from %s (%s): ' % (phrase, h, tx['from'], role)).strip()
    ex.need('send_operator_confirmation', typed, phrase)
    # Every live check again after the (unbounded) confirmation pause, immediately before broadcast.
    again = ex.signing_transaction(snapshot, args.reviewed_plan_sha256, args.step, remote)
    ex.need('send_tx_stable', again, tx)
    fee_fits(remote, tx)
    # The attempt is on disk before anything is transmitted: if this write fails, nothing has been sent.
    ex.write_json(args.out/'broadcast.json', dict(step=args.step, hash=h, outcome='attempting'))
    outcome, provider = 'unknown', None
    # From the broadcast attempt on, the transaction may be on its way. Every failure, including Ctrl-C, is
    # send_after_broadcast with the hash; evidence writes are best effort and never stop monitoring.
    try:
        try:
            sent = broadcast(url, raw)
            outcome = 'accepted' if sent == h else 'accepted_hash_mismatch'
        except ex.Gate as e:
            # No reply, a malformed reply, or an error reply ("already known", "nonce too low", ...) does not prove
            # the transaction is not in some mempool: outcome stays unknown and the local hash is monitored.
            provider = {'gate': e.record['gate'], 'observed': e.record['observed']}
        # provider carries the broadcast Gate's observed value (an integer code at most), scrubbed like FAILURE.json.
        evidence = dict(step=args.step, hash=h, outcome=outcome,
                        provider=None if provider is None else dict(gate=trusted_gate(provider['gate'], url),
                                                                    observed=scrub(provider['observed'], url)))
        note(args.out/'broadcast.json', lambda p: ex.write_json(p, guard(evidence, url, h)))
        note(args.out/'signed.raw', lambda p: p.write_text(raw+'\n'))  # public once broadcast; never on disk before
        r = wait_receipt(remote, h, tx, url_tokens(url))
        note(args.out/'receipt.json', lambda p: ex.write_json(p, guard(r, url, h)))  # kept even if a later read fails
        check_mined(remote, h, tx, r)
        if outcome == 'accepted_hash_mismatch':
            # Mined as signed, but the provider reported another hash: a provider fault the operator must see.
            raise ex.Gate('send_returned_hash', 'mismatch', h)
        if args.step == ex.STEP_IDS[-1]:
            context = {'tlBlock': hex(int(plan['pin']['block'], 16)+1), 'eta': ex.scheduled_eta(remote, plan, done=True)}
            ex.readback(remote, plan, plan['steps'][-1], r, context)
        result = dict(status='SENT', step=args.step, role=role, hash=h, block=r['blockNumber'], broadcast=outcome,
                      gasUsed=ex.qty(r['gasUsed']), planSha256=hashlib.sha256(raw_plan).hexdigest())
        result = guard(result, url, h)
        note(args.out/'result.json', lambda p: ex.write_json(p, result))
        return result
    except (Exception, KeyboardInterrupt) as e:
        if isinstance(e, KeyboardInterrupt):
            inner = {'gate': 'interrupted', 'observed': None}
        elif isinstance(e, ex.Gate):
            inner = e.record
        else:
            inner = {'gate': 'local_error', 'observed': type(e).__name__}
        raise ex.Gate('send_after_broadcast', {'hash': h, 'broadcast': outcome, 'provider': provider,
                                               'cause': inner.get('gate'), 'causeObserved': inner.get('observed')},
                      'reconcile by hash on chain; never resend or reprice without a new review') from None


def note(path, write):
    """Best-effort evidence write after broadcast: a full disk must not stop monitoring."""
    try:
        write(path)
    except OSError:
        report('WARNING: could not write %s' % path.name, sys.stderr)  # never raises, even if stderr is gone


KNOWN_KEYS = frozenset(('hash', 'broadcast', 'provider', 'cause', 'causeObserved', 'gate', 'observed', 'expected',
                        'method', 'code', 'step', 'status'))


QUANTITY_MAX = 66  # "0x" + 32 bytes: only a quantity this short can stand for a key in decimal form


def leak_free(obj, url):
    """Final check on what is about to be written or printed: no RPC URL token anywhere, in any key or string,
    nor in any integer written in decimal or hex, nor in the decimal form of a hex quantity (<= 32 bytes; longer
    hex such as log data is checked as text only). Iterative, so nesting depth cannot raise; and fail-closed:
    anything unexpected while checking counts as a leak."""
    tokens = url_tokens(url)
    def bad(s):
        return any(tok in s.lower() for tok in tokens)
    try:
        stack = [obj]
        while stack:
            v = stack.pop()
            if isinstance(v, bool) or v is None:
                continue
            if isinstance(v, int):
                if bad(str(v)) or bad(format(v, 'x')):
                    return False
            elif isinstance(v, (list, tuple)):
                stack.extend(v)
            elif isinstance(v, dict):
                for k, x in v.items():
                    if bad(str(k)):
                        return False
                    stack.append(x)
            else:
                s = str(v)
                if bad(s):
                    return False
                if len(s) <= QUANTITY_MAX and re.fullmatch(r'0x[0-9a-fA-F]+', s) and bad(str(int(s, 16))):
                    return False
        return True
    except Exception:
        return False


def guard(obj, url, h):
    """obj if it is leak-free, else a placeholder that keeps only the transaction hash."""
    return obj if leak_free(obj, url) else {'redacted': 'contained an RPC URL token', 'hash': h}


SAFE_TEXT_MAX = 130  # "0x" + up to 64 bytes (two 32-byte words); longer hex (bytecode, calldata) is redacted


def url_tokens(url):
    """Path/query fragments of the RPC URL long enough to be a key; any provider string containing one is refused.

    Fragments shorter than six characters are not protected: shorter thresholds collide with ordinary numbers
    (gas used, block numbers). Provider keys are far longer; a sub-six-character credential is out of scope."""
    # Both the raw and the percent-decoded URL, lowercased: provider values are compared lowercased too.
    forms = {url, urllib.parse.unquote(url)}
    raw = {s.lower() for f in forms for s in re.split(r'[/?&=:#@.]+', f)}
    # A 0x-prefixed hex key is also matched without its prefix, as it appears inside a hex value or an int's hex
    # form; only when what remains is hex (at least the 6-character threshold), so "0xstatus" does not turn into
    # "status" while "0xabcdef" still yields "abcdef".
    stripped = {t[2:] for t in raw if t.startswith('0x') and re.fullmatch(r'[0-9a-f]{6,}', t[2:])}
    return {s for s in raw | stripped if len(s) >= 6}


SCRUB_DEPTH = 64


def scrub(value, url):
    """FAILURE.json `observed`/`expected`: gate records from a3a_exec can carry raw provider results in either.

    Kept: booleans, None, short 0x-hex strings (hashes, addresses, quantities, words) and integers, only if they
    contain no path/query token of the RPC URL (an integer is checked in decimal and in hex). Every other string
    becomes a placeholder, whatever its shape: a provider value cannot be told apart from code text here. Trusted
    metadata (gate names, the broadcast outcome) is kept by failure_record(), not by this function.
    """
    tokens = url_tokens(url)
    def leaks(s):
        return any(tok in s.lower() for tok in tokens)
    def key(k, i):
        # Keys can be provider-controlled too (a dict inside an observed value): only known record keys survive.
        return k if k in KNOWN_KEYS else '<key %d>' % i
    def clean(v, depth=0):
        if v is None or isinstance(v, bool):
            return v
        if depth >= SCRUB_DEPTH:  # deeper provider nesting is dropped, so the recursion is bounded
            return '<redacted: nested deeper than %d>' % SCRUB_DEPTH
        if isinstance(v, int):
            return v if not leaks(str(v)) and not leaks(format(v, 'x')) else '<redacted int>'
        if isinstance(v, (list, tuple)):
            return [clean(x, depth + 1) for x in v]
        if isinstance(v, dict):
            return {key(k, i): clean(x, depth + 1) for i, (k, x) in enumerate(v.items())}
        s = str(v)
        if len(s) <= SAFE_TEXT_MAX and re.fullmatch(r'0x[0-9a-fA-F]*', s) and not leaks(s):
            return s
        return '<redacted %d chars>' % len(s)
    return clean(value)


OUTCOMES = ('attempting', 'accepted', 'accepted_hash_mismatch', 'unknown')
GATE_NAME = re.compile(r'[A-Za-z][A-Za-z0-9_()]{0,63}', re.ASCII)  # e.g. send_after_broadcast, S3_totalSupply()


def trusted_gate(name, url):
    """A gate name is built by code (ex.Gate(name, ...) from constants, step ids and field names), never from
    provider data; kept if it has that shape and no URL token, else redacted."""
    ok = isinstance(name, str) and GATE_NAME.fullmatch(name) and not any(tok in name.lower() for tok in url_tokens(url))
    return name if ok else '<redacted>'


def failure_record(record, step, url):
    """The persisted failure: provider-sourced values scrubbed; code-sourced metadata kept explicitly."""
    out = dict(record, step=step, gate=trusted_gate(record.get('gate'), url),
               observed=scrub(record.get('observed'), url), expected=scrub(record.get('expected'), url))
    obs = record.get('observed')
    if record.get('gate') == 'send_after_broadcast' and isinstance(obs, dict):
        # The wrapper's own fields: the outcome is one of OUTCOMES; cause and provider.gate are gate names.
        out['observed'] = dict(out['observed'],
                               broadcast=obs.get('broadcast') if obs.get('broadcast') in OUTCOMES else '<redacted>',
                               cause=trusted_gate(obs.get('cause'), url))
        if isinstance(obs.get('provider'), dict):
            out['observed']['provider'] = dict(out['observed']['provider'], gate=trusted_gate(obs['provider'].get('gate'), url))
    return out


def hash_only(record, step, url, reason):
    """Minimal failure record. Only send_after_broadcast's hash is ours (computed locally from the signed bytes);
    any other gate's observed hash may be provider data. Even ours is rechecked before it is kept."""
    obs = record.get('observed')
    mine = (record.get('gate') == 'send_after_broadcast' and isinstance(obs, dict)
            and isinstance(obs.get('hash'), str) and ex.HASH32.fullmatch(obs['hash']) and leak_free(obs['hash'], url))
    return {'status': 'FAILURE', 'gate': trusted_gate(record.get('gate'), url), 'step': step,
            'redacted': reason, 'hash': obs['hash'] if mine else None}


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
                try:
                    result = run(args, ex.RPC(url), url)
                except ex.Gate:
                    raise
                except Exception as e:  # nothing was broadcast (run() wraps everything after broadcast in a Gate)
                    raise ex.Gate('local_error', type(e).__name__, 'no local failure before broadcast') from None
            except ex.Gate as e:
                # Only into the directory this run verified empty, never over earlier evidence; still locked.
                # gate/status are code constants; observed and expected can both carry provider data (a3a_exec puts
                # e.g. a receipt's transactionHash into expected), so both are scrubbed.
                try:
                    record = failure_record(e.record, args.step, url)
                    if not leak_free(record, url):
                        record = hash_only(e.record, args.step, url, 'contained an RPC URL token')
                except Exception:
                    # Building the record must never cost the record: fall back to the hash-only form.
                    record = hash_only(e.record, args.step, url, 'failure record could not be built')
                try:
                    ex.write_json(args.out/'FAILURE.json', record)
                except OSError:
                    # Disk still failing: the terminal is the last place the hash can be reported.
                    report('FAILURE record (not written): ' + json.dumps(record), sys.stderr)
                raise
        # The send is complete; failing to print the result must not turn it into a failure.
        report(json.dumps(result, indent=2), sys.stdout)
        return 0
    except ex.Gate as e:
        report('FAILURE: '+e.record['gate'], sys.stderr)
        return 1


def report(text, stream):
    """Print and flush now; if the stream is gone (closed pipe), point its fd at /dev/null so that the flush at
    interpreter exit cannot fail and turn the exit status into 120."""
    try:
        print(text, file=stream, flush=True)
    except Exception:
        try:
            fd = stream.fileno()
            null = os.open(os.devnull, os.O_WRONLY)
            if null != fd:  # if fd itself was closed, os.open may return it: then it already is /dev/null
                os.dup2(null, fd)
                os.close(null)
        except Exception:
            pass


if __name__ == '__main__':
    sys.exit(main())
