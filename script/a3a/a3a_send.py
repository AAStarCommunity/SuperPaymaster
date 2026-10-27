#!/usr/bin/env python3
"""A3a live sender: one reviewed step per invocation, signed with a Foundry keystore (DSR M1 gap IG-07).

NOT AUTHORISED TO RUN until DSR has reviewed this file and the author has given a separate go for the specific
plan sha256. `a3a_exec.py sign|send` stay disabled; this module is the only broadcast path, kept apart so that
a3a_exec.py itself still cannot broadcast.

Usage (run by the operator in a terminal: cast asks for the keystore password, and the confirmation is typed):
  python3 -B script/a3a/a3a_send.py --plan <plan.json> --reviewed-plan-sha256 <sha256 from the review> \
    --step S1 --rpc-file <file holding the RPC URL> --accounts <json: {"deployer": "<keystore name>", ...}> \
    --out <new empty dir>

Order of operations, each a hard stop on failure (nothing is broadcast unless every step before it passed):
  1. a3a_exec.signing_transaction: reviewed sha256 (out-of-band, not the sidecar), frozen-plan validation,
     Safe hash recheck for S5/S6, and pre_send (chain, code, predecessor readback, latest == pending == planned
     nonce, Safe nonce, fresh estimateGas <= planned gas).
  2. `cast mktx --account <name>` offline: no RPC in the signer's environment or argv; every field is given
     explicitly from the plan (type 2, chain, nonce, gas, both fee caps, value, to or --create, data).
  3. `cast decode-transaction` of the signed bytes: every field and the signer must equal the plan; empty
     access list; no authorization list; the hash must equal web3_sha3(raw) computed by the node.
  4. pre_send again (the password prompt takes time), and it must return the same transaction; the latest
     base fee plus the planned priority fee must fit under the planned max fee.
  5. The operator types `SEND <step> <first 12 hex of the plan sha256>`.
  6. eth_sendRawTransaction; the returned hash must equal the decoded hash. Then wait for the receipt (no
     resend, no replacement: a stuck transaction is reported, not repriced). Status must be 0x1 and gasUsed
     <= planned gas; eth_getTransactionByHash must equal the plan. After S7 the final readback runs.
Every artefact (unsigned tx, signed raw, decoded fields, receipt) is written to --out. The RPC URL is never
written or printed.
"""
import argparse, hashlib, json, os, subprocess, sys, time, urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import a3a_exec as ex  # noqa: E402

CAST = os.environ.get('A3A_CAST', str(Path.home()/'.foundry/bin/cast'))
RECEIPT_WAIT_SECONDS = 600
SIGNER_ENV = {k: v for k, v in os.environ.items() if k in ('HOME', 'PATH', 'TERM', 'LANG', 'USER')}


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
    r = subprocess.run(cmd, env=SIGNER_ENV, stdout=subprocess.PIPE, text=True)  # stdin/stderr: the terminal
    ex.need('send_sign_exit', r.returncode, 0)
    raw = r.stdout.strip()
    ex.need('send_sign_output', raw.startswith('0x02') and all(c in '0123456789abcdef' for c in raw[2:].lower()), True)
    return raw


def decode(raw):
    r = subprocess.run([CAST, 'decode-transaction', raw], env=SIGNER_ENV, capture_output=True, text=True)
    ex.need('send_decode_exit', r.returncode, 0)
    out = json.loads(r.stdout)
    return json.loads(out) if isinstance(out, str) else out


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
    if not isinstance(d, dict) or 'error' in d or not isinstance(d.get('result'), str):
        code = d.get('error', {}).get('code') if isinstance(d, dict) and isinstance(d.get('error'), dict) else None
        raise ex.Gate('send_broadcast_rejected', code, 'transaction hash')
    return d['result'].lower()


def wait_receipt(remote, h, tx):
    deadline = time.monotonic() + RECEIPT_WAIT_SECONDS
    while time.monotonic() < deadline:
        r = remote('eth_getTransactionReceipt', [h])
        if r is not None:
            ex.need('send_receipt_status', r.get('status'), '0x1')
            ex.need('send_receipt_gas', ex.qty(r['gasUsed']) <= ex.qty(tx['gas']), True)
            return r
        time.sleep(4)
    raise ex.Gate('send_receipt_timeout', h, 'mined within %ds; do not resend or reprice without review' % RECEIPT_WAIT_SECONDS)


def check_mined(remote, h, tx):
    m = remote('eth_getTransactionByHash', [h])
    for k in ('nonce', 'gas', 'maxFeePerGas', 'maxPriorityFeePerGas', 'value'):
        ex.need('send_mined_'+k, ex.qty(m[k]), ex.qty(tx[k]))
    ex.need('send_mined_from', m['from'].lower(), tx['from'].lower())
    ex.need('send_mined_to', (m.get('to') or None) and m['to'].lower(), tx.get('to') and tx['to'].lower())
    ex.need('send_mined_input', m['input'].lower(), tx['data'].lower())


def run(args, remote, url, confirm=input):
    raw_plan = args.plan.read_bytes()
    tx = ex.signing_transaction(args.plan, args.reviewed_plan_sha256, args.step, remote)
    plan = ex.plan_json(raw_plan)
    role = role_of(plan, tx['from'])
    accounts = json.loads(args.accounts.read_text())
    ex.need('send_account_named', isinstance(accounts.get(role), str) and accounts[role] != '', True)
    ex.write_json(args.out/'unsigned.json', tx)
    raw = sign(tx, accounts[role])
    decoded = decode(raw)
    h = check_signed(decoded, tx)
    # The hash is recomputed by the node, not taken from cast's decoder alone.
    ex.need('send_signed_hash', ex.rpc_keccak(remote, raw), h)
    (args.out/'signed.raw').write_text(raw+'\n')
    ex.write_json(args.out/'decoded.json', decoded)
    again = ex.signing_transaction(args.plan, args.reviewed_plan_sha256, args.step, remote)
    ex.need('send_tx_stable', again, tx)
    fee_fits(remote, tx)
    phrase = 'SEND %s %s' % (args.step, args.reviewed_plan_sha256[:12])
    ex.need('send_operator_confirmation', confirm('Type "%s" to broadcast %s from %s (%s): ' % (phrase, h, tx['from'], role)).strip(), phrase)
    sent = broadcast(url, raw)
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


def main(argv=None):
    p = argparse.ArgumentParser()
    p.add_argument('--plan', type=Path, required=True)
    p.add_argument('--reviewed-plan-sha256', required=True)
    p.add_argument('--step', required=True, choices=ex.STEP_IDS)
    p.add_argument('--rpc-file', type=Path, required=True)
    p.add_argument('--accounts', type=Path, required=True)
    p.add_argument('--out', type=Path, required=True)
    args = p.parse_args(argv)
    owned = False  # FAILURE.json goes only into a directory this run verified empty (never over earlier evidence)
    try:
        if args.out.exists():
            ex.need('output_empty', args.out.is_dir() and not any(args.out.iterdir()), True)
        args.out.mkdir(parents=True, exist_ok=True)
        owned = True
        url = args.rpc_file.read_text().strip()
        print(json.dumps(run(args, ex.RPC(url), url), indent=2))
        return 0
    except ex.Gate as e:
        if owned:
            ex.write_json(args.out/'FAILURE.json', dict(e.record, step=args.step))
        print('FAILURE: '+e.record['gate'], file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
