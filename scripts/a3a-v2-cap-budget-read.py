#!/usr/bin/env python3
"""Read-only inputs for docs/release/a3a-precheck-v2/CAP-BUDGET.md.

Calls only eth_call / eth_getCode / eth_getBlockByNumber / eth_getLogs, at one fixed block, on two
endpoints, and prints JSON with RPC URLs omitted. Never signs or sends anything.

  RPC_A=<archive rpc> RPC_B=<second, independent archive rpc> BLOCK=<n> \
    python3 scripts/a3a-v2-cap-budget-read.py > docs/release/a3a-precheck-v2/cap-budget-evidence.json

Completeness of the Transfer(from=0)/Transfer(to=0) scan cannot be inferred from the logs alone; the
script therefore also checks  sum(mints) - sum(burns) == totalSupply()  at the same block (a token
with no code before `creationBlock` starts at supply 0), and that both endpoints return the
identical (block, tx, logIndex) sets.
"""
import hashlib, json, os, sys, urllib.request

TOKEN = '0x696A73701b104c6cCBbAadDD2216788ea08EaB89'  # current Sepolia APNTS_TOKEN (XPNTs-3.4.0)
SP = '0x09DF0d2e3722EC0e401fE3819E64278a42ae4DE9'
OPS = {'OWNER': '0xb5600060e6de5E11D3636731964218E53caadf0E', 'ANNI': '0xEcAACb915f7D92e9916f449F7ad42BD0408733c9'}
TRANSFER = '0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef'
ZERO32 = '0x' + '0' * 64
SEL = {  # 4-byte selectors (cast sig)
    'totalSupply()': '0x18160ddd', 'decimals()': '0x313ce567', 'balanceOf(address)': '0x70a08231',
    'APNTS_TOKEN()': None, 'totalTrackedBalance()': None, 'protocolRevenue()': None, 'protocolFeeBPS()': None,
    'aPNTsPriceUSD()': None, 'cachedPrice()': None, 'operators(address)': None,
}


def keccak_sel(sig):
    # Avoid a dependency: fall back to `cast sig` only for the selectors not hard-coded above.
    import subprocess
    cast = os.path.expanduser('~/.foundry/bin/cast')
    return subprocess.check_output([cast if os.path.exists(cast) else 'cast', 'sig', sig]).decode().strip()


for k, v in list(SEL.items()):
    if v is None:
        SEL[k] = keccak_sel(k)


def rpc(url, method, params):
    req = urllib.request.Request(url, data=json.dumps({'jsonrpc': '2.0', 'id': 1, 'method': method, 'params': params}).encode(),
                                 headers={'Content-Type': 'application/json', 'User-Agent': 'curl/8'})
    r = json.load(urllib.request.urlopen(req, timeout=90))
    if 'error' in r:
        raise RuntimeError(str(r['error'])[:200])
    return r['result']


def arg(a):
    return a.lower()[2:].rjust(64, '0')


def words(h):
    h = h[2:]
    return [str(int(h[i:i + 64], 16)) for i in range(0, len(h), 64)]


def reads(url, blk):
    B = hex(blk)
    q = {
        'token.totalSupply': (TOKEN, SEL['totalSupply()']),
        'token.decimals': (TOKEN, SEL['decimals()']),
        'token.balanceOf(SP)': (TOKEN, SEL['balanceOf(address)'] + arg(SP)),
        'sp.APNTS_TOKEN': (SP, SEL['APNTS_TOKEN()']),
        'sp.totalTrackedBalance': (SP, SEL['totalTrackedBalance()']),
        'sp.protocolRevenue': (SP, SEL['protocolRevenue()']),
        'sp.protocolFeeBPS': (SP, SEL['protocolFeeBPS()']),
        'sp.aPNTsPriceUSD': (SP, SEL['aPNTsPriceUSD()']),
        'sp.cachedPrice': (SP, SEL['cachedPrice()']),
    }
    for n, a in OPS.items():
        q[f'sp.operators({n})'] = (SP, SEL['operators(address)'] + arg(a))
    blkobj = rpc(url, 'eth_getBlockByNumber', [B, False])
    out = {'blockHash': blkobj['hash'], 'blockTimestamp': int(blkobj['timestamp'], 16)}
    for k, (to, data) in q.items():
        out[k] = words(rpc(url, 'eth_call', [{'to': to, 'data': data}, B]))
    return out


def creation_block(url, hi):
    has = lambda b: len(rpc(url, 'eth_getCode', [TOKEN, hex(b)])) > 2
    assert has(hi), 'token has no code at the fixed block'
    lo = 0
    while hi - lo > 1:
        m = (lo + hi) // 2
        hi, lo = (m, lo) if has(m) else (hi, m)
    return hi


def scan(url, start, end, topics, chunk=50_000):
    logs, b = [], start
    while b <= end:
        e = min(end, b + chunk - 1)
        try:
            logs += rpc(url, 'eth_getLogs', [{'address': TOKEN, 'fromBlock': hex(b), 'toBlock': hex(e), 'topics': topics}])
            b = e + 1
        except Exception:
            if chunk == 1:
                raise
            chunk = max(1, chunk // 2)
    return logs


def summarize(logs):
    amts = [int(l['data'], 16) for l in logs]
    return {'count': len(logs), 'sum': str(sum(amts)),
            'firstBlock': int(logs[0]['blockNumber'], 16) if logs else None,
            'lastBlock': int(logs[-1]['blockNumber'], 16) if logs else None,
            'ids': [f'{b}:{t}:{i}' for b, t, i in sorted((int(l['blockNumber'], 16), l['transactionHash'], int(l['logIndex'], 16)) for l in logs)]}


def main():
    urls = {'A': os.environ['RPC_A'], 'B': os.environ['RPC_B']}
    blk = int(os.environ['BLOCK'])
    out = {'note': 'read-only; RPC URLs omitted', 'block': blk, 'token': TOKEN, 'sp': SP, 'operators': OPS, 'reads': {}, 'logs': {}}
    for k, u in urls.items():
        out['reads'][k] = reads(u, blk)
        cb = creation_block(u, blk)
        out['logs'][k] = {'creationBlock': cb, 'scanRange': [cb, blk],
                          'mints': summarize(scan(u, cb, blk, [TRANSFER, ZERO32])),
                          'burns': summarize(scan(u, cb, blk, [TRANSFER, None, ZERO32]))}
    ra, rb = out['reads']['A'], out['reads']['B']
    la, lb = out['logs']['A'], out['logs']['B']
    supply = int(ra['token.totalSupply'][0])
    out['checks'] = {
        'readsIdentical': ra == rb,
        'logIdsIdentical': la == lb,
        'mintsMinusBurnsEqualsTotalSupply': int(la['mints']['sum']) - int(la['burns']['sum']) == supply,
        'trackedEqualsOperatorsPlusRevenue': int(ra['sp.totalTrackedBalance'][0]) == sum(int(ra[f'sp.operators({n})'][0]) for n in OPS) + int(ra['sp.protocolRevenue'][0]),
        'spTokenBalanceEqualsTracked': int(ra['token.balanceOf(SP)'][0]) == int(ra['sp.totalTrackedBalance'][0]),
        'apntsTokenIsScannedToken': int(ra['sp.APNTS_TOKEN'][0]) == int(TOKEN, 16),
    }
    # Store the (identical) id lists once; each endpoint keeps a sha256 of its own list.
    out['logIds'] = {kind: la[kind]['ids'] for kind in ('mints', 'burns')}
    for k in urls:
        for kind in ('mints', 'burns'):
            ids = out['logs'][k][kind].pop('ids')
            out['logs'][k][kind]['idsSha256'] = hashlib.sha256('\n'.join(ids).encode()).hexdigest()
    print(json.dumps(out, indent=1))
    if not all(out['checks'].values()):
        sys.exit(1)


if __name__ == '__main__':
    main()
