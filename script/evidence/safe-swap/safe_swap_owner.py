#!/usr/bin/env python3
"""Build and fork-rehearse the test-Safe owner swap (third owner 0x92a3… -> new owner).

Read-only against the live chain: it reads state, then rehearses both transactions on a local anvil fork
with impersonation. It never signs or broadcasts. Output: packet.json + packet.json.sha256.

    python3 safe_swap_owner.py --rpc-file RPC --out DIR
"""
import argparse, hashlib, json, subprocess, time, urllib.request, socket, os
from pathlib import Path

CAST = str(Path.home() / '.foundry/bin/cast')
# Sepolia runs Amsterdam: rehearse only on the pinned Amsterdam engine (default anvil underestimates gas).
ANVIL = os.environ.get('SAFE_SWAP_ANVIL', str(Path.home() / 'Dev/aastar/tools/foundry-rams/nightly-4e8874b/anvil'))
SAFE = '0x16df788ed4ed1fc384e52dc832a6a6c3a23bdebf'
APPROVER = '0xe3d28aa77c95d5c098170698e5ba68824bfc008d'   # A
EXECUTOR = '0xf7bf79acb7f3702b9dbd397d8140ac9de6ce642c'   # E
OLD = '0x92a30ef64b0b750220b2b3bafe4f3121263d45b3'
NEW = '0xd6e95a852d68f99759bf47e77d84fcc8d6f93494'
CHAIN = 11155111
MAX_FEE = 20 * 10**9          # same cap as A3a S6a/S6b
PRIORITY = 10**8              # 0.1 gwei, as A3a


def cast(*args):
    return subprocess.run([CAST, *args], check=True, capture_output=True, text=True).stdout.strip()


def rpc(url, method, params):
    body = json.dumps({'jsonrpc': '2.0', 'id': 1, 'method': method, 'params': params}).encode()
    with urllib.request.urlopen(urllib.request.Request(url, body, {'Content-Type': 'application/json'}), timeout=60) as r:
        d = json.load(r)
    if 'error' in d:
        raise RuntimeError(f'{method}: {d["error"]}')
    return d['result']


def call(url, to, sig, *args, block='latest'):
    data = cast('calldata', sig, *args)
    return rpc(url, 'eth_call', [{'to': to, 'data': data}, block])


def owners(url, block='latest'):
    return [a.lower() for a in json.loads(cast('decode-abi', 'f()(address[])', call(url, SAFE, 'getOwners()', block=block)).replace("'", '"'))] \
        if False else [x.lower() for x in cast('abi-decode', 'f()(address[])', call(url, SAFE, 'getOwners()', block=block)).strip('[]').split(', ')]


def uint(url, sig, *args, block='latest'):
    return int(call(url, SAFE, sig, *args, block=block), 16)


def need(cond, msg):
    if not cond:
        raise SystemExit('STOP: ' + msg)


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--rpc-file', required=True)
    p.add_argument('--out', required=True)
    args = p.parse_args()
    url = Path(args.rpc_file).read_text().strip()
    out = Path(args.out); out.mkdir(parents=True, exist_ok=True)

    need(int(rpc(url, 'eth_chainId', []), 16) == CHAIN, 'chain')
    block = rpc(url, 'eth_getBlockByNumber', ['finalized', False])
    pin = dict(number=int(block['number'], 16), hash=block['hash'])
    tag = block['number']
    cur = owners(url, tag)
    need(cur == [EXECUTOR, APPROVER, OLD], f'unexpected owners {cur}')
    need(uint(url, 'getThreshold()', block=tag) == 2, 'threshold')
    safe_nonce = uint(url, 'nonce()', block=tag)
    for who in (APPROVER, EXECUTOR, NEW):
        need(rpc(url, 'eth_getCode', [who, tag]) == '0x', f'{who} must be an undelegated EOA')
    prev = APPROVER                       # owners list order E -> A -> OLD, so prev(OLD) = A
    data = cast('calldata', 'swapOwner(address,address,address)', prev, OLD, NEW)
    zero = '0x' + '00' * 20
    safe_hash = call(url, SAFE, 'getTransactionHash(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,uint256)',
                     SAFE, '0', data, '0', '0', '0', '0', zero, zero, str(safe_nonce), block=tag)
    approve_data = cast('calldata', 'approveHash(bytes32)', safe_hash)
    # Approved-hash signatures (v=1, r=owner, s=0), sorted by owner address ascending.
    sigs = ''.join(('00' * 12 + o[2:]) + '00' * 32 + '01' for o in sorted([APPROVER, EXECUTOR]))
    exec_data = cast('calldata', 'execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)',
                     SAFE, '0', data, '0', '0', '0', '0', zero, zero, '0x' + sigs)
    nonces = {w: int(rpc(url, 'eth_getTransactionCount', [w, tag]), 16) for w in (APPROVER, EXECUTOR)}

    # Fork rehearsal at the pinned block with impersonation (local only).
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0)); port = s.getsockname()[1]
    local = f'http://127.0.0.1:{port}'
    try:
        live_config = rpc(url, 'eth_config', [])
    except Exception as error:
        live_config = {'unavailable': str(error)[:120]}
    proc = subprocess.Popen([ANVIL, '--hardfork', 'amsterdam', '--order', 'fifo', '--fork-url', url,
                             '--fork-block-number', str(pin['number']), '--port', str(port), '--chain-id', str(CHAIN), '--silent'])
    try:
        for _ in range(200):
            try:
                rpc(local, 'eth_chainId', []); break
            except Exception:
                time.sleep(0.1)
        info = rpc(local, 'anvil_nodeInfo', [])
        need(info.get('hardFork') == 'Amsterdam', f"fork engine hardfork {info.get('hardFork')} (need Amsterdam)")
        rehearsal = []
        txs = []
        for who, payload, label in ((APPROVER, approve_data, 'approveHash'), (EXECUTOR, exec_data, 'execTransaction')):
            rpc(local, 'anvil_impersonateAccount', [who])
            probe = {'from': who, 'to': SAFE, 'data': payload, 'value': '0x0'}
            gas_est = int(rpc(local, 'eth_estimateGas', [probe]), 16)
            # Real-chain estimate at the pin (DSR 2026-11-04). tx2 depends on tx1's approval: override
            # approvedHashes[A][safeTxHash] (Safe storage slot 8, nested mapping) to 1.
            override = None
            if label == 'execTransaction':
                inner = cast('keccak', '0x' + ('00' * 12 + APPROVER[2:]) + format(8, '064x'))
                slot = cast('keccak', '0x' + safe_hash[2:] + inner[2:])
                override = {SAFE: {'stateDiff': {slot: '0x' + format(1, '064x')}}}
            chain_params = [probe, tag] + ([override] if override else [])
            chain_est = int(rpc(url, 'eth_estimateGas', chain_params), 16)
            gas = max(gas_est, chain_est) * 13 // 10
            h = rpc(local, 'eth_sendTransaction', [dict(probe, gas=hex(gas), maxFeePerGas=hex(MAX_FEE), maxPriorityFeePerGas=hex(PRIORITY))])
            for _ in range(200):
                r = rpc(local, 'eth_getTransactionReceipt', [h])
                if r: break
                time.sleep(0.05)
            need(r and r['status'] == '0x1', f'{label} reverted on fork')
            used = int(r['gasUsed'], 16)
            need(gas >= used * 12 // 10, f'{label} gas limit {gas} < 1.2 x Amsterdam gasUsed {used}')
            rehearsal.append(dict(step=label, gasEstimate=gas_est, chainEstimate=chain_est, chainOverrideSlot=(slot if override else None), gasUsed=used, engine='nightly-4e8874b', hardFork=info.get('hardFork')))
            txs.append(dict(step=label, chainId=CHAIN, **{'from': who}, to=SAFE, value=0, data=payload,
                            nonce=nonces[who], gas=gas, maxFeePerGas=MAX_FEE, maxPriorityFeePerGas=PRIORITY))
        after = owners(local)
        readback = dict(owners=after, threshold=uint(local, 'getThreshold()'), nonce=uint(local, 'nonce()'),
                        isOwnerOld=uint(local, 'isOwner(address)', OLD), isOwnerNew=uint(local, 'isOwner(address)', NEW))
        need(after == [EXECUTOR, APPROVER, NEW], f'post owners {after}')
        need(readback['threshold'] == 2 and readback['nonce'] == safe_nonce + 1, 'post threshold/nonce')
        need(readback['isOwnerOld'] == 0 and readback['isOwnerNew'] == 1, 'post isOwner')
    finally:
        proc.terminate(); proc.wait(timeout=10)

    packet = dict(purpose='Test Safe third-owner swap (7702-delegated 0x92a3… -> fresh EOA)', chainId=CHAIN, safe=SAFE,
                  pin=pin, safeNonce=safe_nonce, swapOwner=dict(prev=prev, old=OLD, new=NEW, data=data),
                  safeTxHash=safe_hash, transactions=txs,
                  expectedReadback=dict(owners=[EXECUTOR, APPROVER, NEW], threshold=2, nonce=safe_nonce + 1,
                                        isOwnerOld=0, isOwnerNew=1),
                  forkRehearsal=dict(block=pin['number'], engine='nightly-4e8874b', hardFork='Amsterdam', liveEthConfig=live_config, steps=rehearsal, readback=readback))
    raw = json.dumps(packet, indent=2, sort_keys=True).encode() + b'\n'
    (out / 'packet.json').write_bytes(raw)
    digest = hashlib.sha256(raw).hexdigest()
    (out / 'packet.json.sha256').write_text(digest + '  packet.json\n')
    print(json.dumps(dict(sha256=digest, safeTxHash=safe_hash, rehearsal=rehearsal, readback=readback), indent=2))


if __name__ == '__main__':
    main()
