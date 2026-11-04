#!/usr/bin/env python3
"""Send the reviewed test-Safe owner-swap packet: exactly its two transactions, in order, once each.

Gates (any failure => STOP before signing or before the next send):
- packet.json sha256 equals the author-approved hash;
- both endpoints agree, and sender nonces (latest == pending), Safe nonce and owners equal the packet;
- the signed transaction, decoded locally, matches the packet fields exactly;
- each receipt has status 1 before the next step; final readback equals expectedReadback on both endpoints.
Signing uses the existing Foundry keystores (a3a-approver / a3a-executor). Raw signed bytes are never logged.
"""
import hashlib, json, subprocess, sys, time, urllib.request
from pathlib import Path

APPROVED = '460e024407694772a511b283f62442f2521b297bddfad2b823ddc2dee80654d1'
CAST = str(Path.home() / '.foundry/bin/cast')
HERE = Path(__file__).resolve().parent
KEYSTORE = {'0xe3d28aa77c95d5c098170698e5ba68824bfc008d': 'a3a-approver',
            '0xf7bf79acb7f3702b9dbd397d8140ac9de6ce642c': 'a3a-executor'}
PW = str(Path.home() / '.a3a/pw')


def stop(msg):
    print('STOP: ' + msg, flush=True); sys.exit(1)


def rpc(url, method, params):
    body = json.dumps({'jsonrpc': '2.0', 'id': 1, 'method': method, 'params': params}).encode()
    with urllib.request.urlopen(urllib.request.Request(url, body, {'Content-Type': 'application/json'}), timeout=60) as r:
        d = json.load(r)
    if 'error' in d:
        raise RuntimeError(method + ': ' + str(d['error'].get('message', ''))[:200])
    return d['result']


def cast(*a):
    return subprocess.run([CAST, *a], check=True, capture_output=True, text=True).stdout.strip()


def state(url, packet):
    safe = packet['safe']
    def c(sig, *args):
        return rpc(url, 'eth_call', [{'to': safe, 'data': cast('calldata', sig, *args)}, 'latest'])
    owners = [x.lower() for x in cast('abi-decode', 'f()(address[])', c('getOwners()')).strip('[]').split(', ')]
    nonces = {}
    for t in packet['transactions']:
        w = t['from']
        nonces[w] = (int(rpc(url, 'eth_getTransactionCount', [w, 'latest']), 16), int(rpc(url, 'eth_getTransactionCount', [w, 'pending']), 16))
    return dict(owners=owners, safeNonce=int(c('nonce()'), 16), threshold=int(c('getThreshold()'), 16), nonces=nonces,
                isOwnerOld=int(c('isOwner(address)', packet['swapOwner']['old']), 16),
                isOwnerNew=int(c('isOwner(address)', packet['swapOwner']['new']), 16))


def main():
    urls = [Path(p).read_text().strip() for p in sys.argv[1:3]]
    raw = (HERE / 'out/packet.json').read_bytes()
    if hashlib.sha256(raw).hexdigest() != APPROVED:
        stop('packet hash differs from the approved hash')
    packet = json.loads(raw)
    pre = [state(u, packet) for u in urls]
    if pre[0] != pre[1]:
        stop('endpoints disagree before sending')
    s = pre[0]
    if s['owners'] != [packet['transactions'][1]['from'], packet['transactions'][0]['from'], packet['swapOwner']['old']] \
            or s['safeNonce'] != packet['safeNonce'] or s['threshold'] != 2:
        stop('Safe state differs from the packet: ' + json.dumps(s))
    for t in packet['transactions']:
        latest, pending = s['nonces'][t['from']]
        if latest != t['nonce'] or pending != t['nonce']:
            stop(f"{t['step']} sender nonce latest={latest} pending={pending}, packet={t['nonce']}")
    receipts = []
    for i, t in enumerate(packet['transactions']):
        if i:  # re-check the next sender right before signing it
            latest = int(rpc(urls[0], 'eth_getTransactionCount', [t['from'], 'pending']), 16)
            if latest != t['nonce']:
                stop(f"{t['step']} sender nonce moved to {latest}")
        signed = cast('mktx', '--account', KEYSTORE[t['from']], '--password-file', PW, '--chain', str(t['chainId']),
                      '--nonce', str(t['nonce']), '--gas-limit', str(t['gas']), '--gas-price', str(t['maxFeePerGas']),
                      '--priority-gas-price', str(t['maxPriorityFeePerGas']), '--value', '0', '--rpc-url', urls[0],
                      t['to'], t['data'])
        d = json.loads(cast('decode-transaction', signed, '--json'))
        if isinstance(d, str):  # cast 1.7 prints the decoded object as a JSON string
            d = json.loads(d)
        def q(k): return int(str(d.get(k)), 16) if str(d.get(k)).startswith('0x') else int(d.get(k))
        checks = dict(to=d.get('to', '').lower() == t['to'], nonce=q('nonce') == t['nonce'], gas=q('gas') == t['gas'],
                      maxFee=q('maxFeePerGas') == t['maxFeePerGas'], priority=q('maxPriorityFeePerGas') == t['maxPriorityFeePerGas'],
                      value=q('value') == 0, data=d.get('input', d.get('data', '')).lower() == t['data'].lower(),
                      chain=q('chainId') == t['chainId'], signer=str(d.get('signer', '')).lower() == t['from'])
        if not all(checks.values()):
            stop(f"{t['step']} signed tx differs from packet: {checks}")
        h = rpc(urls[0], 'eth_sendRawTransaction', [signed])
        signed = None
        print(f"{t['step']} broadcast {h}", flush=True)
        deadline = time.time() + 600
        r = None
        while time.time() < deadline:
            r = rpc(urls[0], 'eth_getTransactionReceipt', [h])
            if r: break
            time.sleep(4)
        if not r:
            stop(f"{t['step']} not mined within 600 s; do not resend: {h}")
        if r['status'] != '0x1':
            stop(f"{t['step']} reverted: {h}")
        receipts.append(dict(step=t['step'], hash=h, block=int(r['blockNumber'], 16), gasUsed=int(r['gasUsed'], 16)))
        print(json.dumps(receipts[-1]), flush=True)
    time.sleep(8)
    post = [state(u, packet) for u in urls]
    exp = packet['expectedReadback']
    for p in post:
        got = dict(owners=p['owners'], threshold=p['threshold'], nonce=p['safeNonce'], isOwnerOld=p['isOwnerOld'], isOwnerNew=p['isOwnerNew'])
        if got != exp:
            stop('post readback differs: ' + json.dumps(got))
    result = dict(packetSha256=APPROVED, receipts=receipts, readback=post)
    (HERE / 'out/result.json').write_text(json.dumps(result, indent=2) + '\n')
    print('DONE ' + json.dumps(dict(receipts=receipts, owners=post[0]['owners'], nonce=post[0]['safeNonce'])), flush=True)


if __name__ == '__main__':
    main()
