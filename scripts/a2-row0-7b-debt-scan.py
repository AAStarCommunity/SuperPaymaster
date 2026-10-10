#!/usr/bin/env python3
"""A2 evidence: spec 03-final-spec.md §6 row 0 (DebtRecordFailed / pendingDebts / operator inventory)
and row 7b (legacy debt inside the OLD xPNTs tokens) on Sepolia.

READ-ONLY. Only eth_chainId / eth_blockNumber / eth_getBlockByNumber / eth_getCode / eth_getStorageAt /
eth_call (incl. eth_call state override, which is a local simulation) / eth_getLogs are issued.
Nothing is signed or sent.

Two independently operated ARCHIVE endpoints are queried for every read and every result is compared;
any difference, any failed positive control, any unverified topic/selector and any reconciliation
mismatch makes the script exit 1 (fail-closed). RPC URLs / keys are never written to the output;
every written file is scanned for the URL secrets before the script declares success.

Endpoints:
  A: $RPC_A, else SEPOLIA_RPC from ~/Dev/.env (Alchemy, archive, unrestricted eth_getLogs range)
  B: $RPC_B, else https://sepolia.gateway.tenderly.co (Tenderly, archive)

Usage: python3 scripts/a2-row0-7b-debt-scan.py [--block N] [--row0 DIR] [--legacy DIR]
Deps: python3 stdlib only (keccak-256 is implemented below and self-tested). Must run inside the repo
(the event declarations are read from the git tags v5.4.2 and v5.5.0-rc.2).
"""
import argparse, collections, json, os, re, subprocess, sys, urllib.error, urllib.request

# ---------------------------------------------------------------- keccak-256 (pure python) ----------
_RC = [0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000, 0x000000000000808B,
       0x0000000080000001, 0x8000000080008081, 0x8000000000008009, 0x000000000000008A, 0x0000000000000088,
       0x0000000080008009, 0x000000008000000A, 0x000000008000808B, 0x800000000000008B, 0x8000000000008089,
       0x8000000000008003, 0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
       0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008]
_ROT = [[0, 36, 3, 41, 18], [1, 44, 10, 45, 2], [62, 6, 43, 15, 61], [28, 55, 25, 21, 56], [27, 20, 39, 8, 14]]
_M = (1 << 64) - 1


def _rol(x, n):
    return ((x << n) | (x >> (64 - n))) & _M if n else x


def _f(A):
    for rc in _RC:
        C = [A[x][0] ^ A[x][1] ^ A[x][2] ^ A[x][3] ^ A[x][4] for x in range(5)]
        D = [C[(x - 1) % 5] ^ _rol(C[(x + 1) % 5], 1) for x in range(5)]
        A = [[A[x][y] ^ D[x] for y in range(5)] for x in range(5)]
        B = [[0] * 5 for _ in range(5)]
        for x in range(5):
            for y in range(5):
                B[y][(2 * x + 3 * y) % 5] = _rol(A[x][y], _ROT[x][y])
        A = [[B[x][y] ^ ((~B[(x + 1) % 5][y]) & B[(x + 2) % 5][y]) for y in range(5)] for x in range(5)]
        A[0][0] ^= rc
    return A


def keccak(data: bytes) -> bytes:
    rate = 136
    p = bytearray(data) + b'\x01'
    while len(p) % rate:
        p.append(0)
    p[-1] |= 0x80
    A = [[0] * 5 for _ in range(5)]
    for off in range(0, len(p), rate):
        blk = p[off:off + rate]
        for i in range(rate // 8):
            x, y = i % 5, i // 5
            A[x][y] ^= int.from_bytes(blk[8 * i:8 * i + 8], 'little')
        A = _f(A)
    out = b''
    for i in range(4):
        out += A[i % 5][i // 5].to_bytes(8, 'little')
    return out


def k(s: str) -> str:
    return '0x' + keccak(s.encode()).hex()


def sel(s: str) -> str:
    return k(s)[:10]


# keccak self-test against fixed vectors (empty string, ERC-20 Transfer topic)
assert k('') == '0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470', 'keccak self-test 1'
assert k('Transfer(address,address,uint256)') == \
    '0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef', 'keccak self-test 2'

# ---------------------------------------------------------------- constants -------------------------
CHAIN_ID = 11155111
SP = '0x09DF0d2e3722EC0e401fE3819E64278a42ae4DE9'
REGISTRY = '0xf5Bf37ca83AfdAab73691bA7eCcDfA69b8708E71'
EXPECTED_SP_IMPL = '0xe25f88dbeafc64200270a948df8e9dd2f9b22c27'
EXPECTED_SP_VERSION = 'SuperPaymaster-5.4.2'
# Tokens named in the CC-124 / DSR request; the full token set is derived on-chain below.
NAMED_TOKENS = {
    '0x696a73701b104c6ccbbaaddd2216788ea08eab89': 'aPNTs (current SP.APNTS_TOKEN; AAStar operator token)',
    '0xbb46321545a91db2f3b5c3e694f2f23abe259883': 'aPNTs v3.5 (SP.pendingAPNTsToken, to be cancelled)',
    '0xe6579a90dc498a710008de12119812d0fb7aa224': 'PNTs (Mycelium / ANNI operator token)',
}
# xPNTs factories whose tokens are in scope: every factory SP.xpntsFactory ever pointed at
# (derived from XPNTsFactoryUpdated) plus these known Sepolia factories (config.sepolia.json,
# FACTORY() of 0xBb46).
EXTRA_FACTORIES = ['0x0e54b9e2c2032dce6ce14e12ea70b4e6eff2a244', '0x9f426568f16e81144f3ebf6f07e497fb9f160d11']
ROLE_PAYMASTER_SUPER = k('PAYMASTER_SUPER')
ROLE_COMMUNITY = k('COMMUNITY')
REGISTRY_ROLE_MEMBERS_SLOT = 9  # storage-layout/Registry.json "roleMembers"; verified on-chain below
EIP1967_IMPL_SLOT = '0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc'
FINALITY_MARGIN = 64

SIG = {
    'DebtRecordFailed': 'DebtRecordFailed(address,address,uint256)',
    'PendingDebtRetried': 'PendingDebtRetried(address,address,uint256)',
    'PendingDebtCleared': 'PendingDebtCleared(address,address,uint256)',
    'Upgraded': 'Upgraded(address)',
    'TransactionSponsored': 'TransactionSponsored(address,address,uint256,uint256)',
    'OperatorConfigured': 'OperatorConfigured(address,address,address)',
    'XPNTsFactoryUpdated': 'XPNTsFactoryUpdated(address,address)',
    'APNTsTokenChangeQueued': 'APNTsTokenChangeQueued(address,uint256)',
    'DebtRecorded': 'DebtRecorded(address,uint256)',
    'DebtRepaid': 'DebtRepaid(address,uint256,uint256)',
    'Transfer': 'Transfer(address,address,uint256)',
    'xPNTsTokenDeployed': 'xPNTsTokenDeployed(address,address,string,string)',
    'RoleRegistered': 'RoleRegistered(bytes32,address,uint256,uint256)',
    'RoleGranted': 'RoleGranted(bytes32,address,address)',
    'RoleExited': 'RoleExited(bytes32,address,uint256,uint256)',
    'RoleRevoked': 'RoleRevoked(bytes32,address,address)',
}
T = {n: k(s) for n, s in SIG.items()}
# SP events whose topic1 is the operator (5.4.2 source; ISuperPaymaster + SuperPaymaster.sol).
OPERATOR_TOPIC1_EVENTS = [
    'OperatorConfigured(address,address,address)', 'OperatorDeposited(address,uint256)',
    'OperatorWithdrawn(address,uint256)', 'TransactionSponsored(address,address,uint256,uint256)',
    'OperatorSlashed(address,uint256,uint8)', 'ReputationUpdated(address,uint256)', 'OperatorPaused(address)',
    'OperatorUnpaused(address)', 'OperatorMinTxIntervalUpdated(address,uint48)',
    'UserBlockedStatusUpdated(address,address,bool)', 'SlashQueued(address)', 'SlashCancelled(address)',
    'SlashExecutedWithProof(address,uint8,uint256,bytes32,uint256)',
    'ProtocolRevenueUnderflow(address,uint256,uint256)']
# Source declarations that must exist verbatim (whitespace-normalised) in the tagged sources.
SOURCE_DECLS = [
    ('v5.4.2', 'contracts/src/paymasters/superpaymaster/v3/SuperPaymaster.sol',
     'event DebtRecordFailed(address indexed token, address indexed user, uint256 amount);'),
    ('v5.4.2', 'contracts/src/paymasters/superpaymaster/v3/SuperPaymaster.sol',
     'mapping(address => mapping(address => uint256)) public pendingDebts;'),
    ('v5.5.0-rc.2', 'contracts/src/paymasters/superpaymaster/v3/SuperPaymasterStorage.sol',
     'event DebtRecordFailed(address indexed token, address indexed user, uint256 amount);'),
    ('v5.4.2', 'contracts/src/tokens/xPNTsToken.sol', 'event DebtRecorded(address indexed user, uint256 amount);'),
    ('v5.4.2', 'contracts/src/tokens/xPNTsToken.sol',
     'event DebtRepaid(address indexed user, uint256 amountRepaid, uint256 remainingDebt);'),
    ('v5.4.2', 'contracts/src/tokens/xPNTsToken.sol', 'function getDebt(address user) external view returns (uint256)'),
    # XPNTs-3.4.0 (the version of the aPNTs 0x696A / PNTs 0xE657 clone implementation): last commit
    # before d8893493 bumped it to 3.5.0.
    ('d04b83cf6423cc874185366209195aa2ed4552e6', 'contracts/src/tokens/xPNTsToken.sol', 'return "XPNTs-3.4.0";'),
    ('d04b83cf6423cc874185366209195aa2ed4552e6', 'contracts/src/tokens/xPNTsToken.sol',
     'event DebtRecorded(address indexed user, uint256 amount);'),
    ('d04b83cf6423cc874185366209195aa2ed4552e6', 'contracts/src/tokens/xPNTsToken.sol',
     'event DebtRepaid(address indexed user, uint256 amountRepaid, uint256 remainingDebt);'),
    ('d04b83cf6423cc874185366209195aa2ed4552e6', 'contracts/src/tokens/xPNTsToken.sol',
     'function getDebt(address user) external view returns (uint256)'),
]
EXPECTED_TAGS = {'v5.4.2': '78364b12f42f1d3043ae992472ab6bdb6de82377',
                 'v5.5.0-rc.2': '1ac0e1c595dc84e684b540ca6a936168e922194f'}

# ---------------------------------------------------------------- plumbing --------------------------
FAIL = []
LOG = []


def log(*a):
    s = ' '.join(str(x) for x in a)
    LOG.append(s)
    print(s, flush=True)


def check(cond, what):
    log(('CHECK OK   ' if cond else 'CHECK FAIL ') + what)
    if not cond:
        FAIL.append(what)
    return cond


def load_env(p):
    d = {}
    try:
        for line in open(os.path.expanduser(p)):
            m = re.match(r'^\s*([A-Za-z_0-9]+)=(.*)$', line.strip())
            if m:
                d[m.group(1)] = m.group(2).strip().strip('"').strip("'")
    except FileNotFoundError:
        pass
    return d


class EP:
    def __init__(self, label, url):
        self.label, self.url = label, url
        self.host = url.split('/')[2]
        self.n = 0

    def call(self, method, params, allow_revert=False):
        self.n += 1
        body = json.dumps({'jsonrpc': '2.0', 'id': self.n, 'method': method, 'params': params}).encode()
        for attempt in range(6):
            req = urllib.request.Request(self.url, data=body,
                                         headers={'content-type': 'application/json', 'user-agent': 'a2-debt-scan/1'})
            try:
                r = json.load(urllib.request.urlopen(req, timeout=180))
                break
            except urllib.error.HTTPError as e:
                txt = e.read()[:300].decode(errors='replace')
                if e.code in (429, 502, 503, 504) and attempt < 5:
                    import time; time.sleep(2 * (attempt + 1)); continue
                raise RuntimeError('%s HTTP %s %s' % (self.label, e.code, txt.replace(self.url, '<url>')))
            except (urllib.error.URLError, TimeoutError) as e:
                if attempt < 5:
                    import time; time.sleep(2 * (attempt + 1)); continue
                raise RuntimeError('%s network error %s' % (self.label, type(e).__name__))
        if 'error' in r:
            if allow_revert:
                return {'__error__': r['error']}
            raise RuntimeError('%s rpc error %s' % (self.label, json.dumps(r['error'])[:300]))
        return r['result']


def pad32(a):
    return '0' * 24 + a[2:].lower()


def addr_of_topic(t):
    return '0x' + t[-40:].lower()


def u(h):
    """Hex -> int for values that are NOT getter answers (block numbers, log data slices already length-checked).
    Getter answers must go through word()."""
    return int(h, 16) if h not in ('0x', '') else 0


WORD_RE = re.compile(r'0x[0-9a-fA-F]{64}')


def word(r):
    """Strict decoding of a uint/bool getter answer: EXACTLY one 32-byte ABI word ('0x' + 64 hex chars).
    '0x', '', a revert object, a short/long/multi-word answer or non-hex all raise ValueError -> FAIL.
    (An empty '0x' answer must never be read as zero: that is what a missing function or a lying endpoint
    returns.)"""
    if not isinstance(r, str) or not WORD_RE.fullmatch(r):
        raise ValueError('not exactly one 32-byte ABI word: %r' % (r if not isinstance(r, str) else r[:80]))
    return int(r, 16)


def ord_key(l):
    """Execution order of logs: (blockNumber, logIndex). logIndex is block-global, so the transaction hash
    must NOT take part in ordering (sorting by hash reorders same-block events)."""
    return (int(l['blockNumber'], 16), int(l['logIndex'], 16))


def replay_token_debt(logs, t_recorded, t_repaid):
    """Replay DebtRecorded / DebtRepaid logs of ONE token in execution order.
    Returns (balance_by_user, results) where results is a list of (ok, message): one length check per log
    (DebtRecorded data = 1 word, DebtRepaid data = 2 words) and, per DebtRepaid, remainingDebt == the running
    replayed balance of that user at that point."""
    run = collections.defaultdict(int)
    results = []
    for l in sorted(logs, key=ord_key):
        usr = addr_of_topic(l['topics'][1])
        t0, data = l['topics'][0].lower(), l['data'].lower()
        where = 'block %d logIndex %d' % ord_key(l)
        if t0 == t_recorded:
            ok = bool(re.fullmatch(r'0x[0-9a-f]{64}', data))
            results.append((ok, 'DebtRecorded@%s data is exactly 1 word' % where))
            if ok:
                run[usr] += int(data[2:66], 16)
        elif t0 == t_repaid:
            ok = bool(re.fullmatch(r'0x[0-9a-f]{128}', data))
            results.append((ok, 'DebtRepaid@%s data is exactly 2 words' % where))
            if ok:
                run[usr] -= int(data[2:66], 16)
                rem = int(data[66:130], 16)
                results.append((rem == run[usr], 'user %s DebtRepaid@%s remainingDebt %d == replayed balance %d'
                                % (usr, where, rem, run[usr])))
        else:
            results.append((False, 'unexpected topic0 %s at %s' % (t0, where)))
    return dict(run), results


class Raw:
    """Writes every raw response (per endpoint) under <dir>/raw/<label>/<name>.json."""

    def __init__(self, base):
        self.base = base

    def put(self, ep, name, request, response):
        d = os.path.join(self.base, 'raw', ep.label)
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, name + '.json'), 'w') as f:
            json.dump({'endpoint': '%s (%s)' % (ep.label, ep.host), 'request': request, 'response': response},
                      f, indent=1, sort_keys=True)
            f.write('\n')


def get_logs(ep, raw, name, flt, lo, hi, span=100000):
    """eth_getLogs over [lo,hi] in chunks (bisects on provider errors / 10k caps). Raw chunk responses kept."""
    out, chunks, stack = [], [], [(lo, min(hi, lo + span - 1))]
    nxt = lo + span
    while stack or nxt <= hi:
        if not stack:
            stack.append((nxt, min(hi, nxt + span - 1)))
            nxt += span
        a, b = stack.pop(0)
        q = dict(flt, fromBlock=hex(a), toBlock=hex(b))
        try:
            res = ep.call('eth_getLogs', [q])
            if len(res) >= 10000 and b > a:
                raise RuntimeError('cap')
        except RuntimeError:
            if b == a:
                raise
            m = (a + b) // 2
            stack[0:0] = [(a, m), (m + 1, b)]
            continue
        chunks.append({'fromBlock': a, 'toBlock': b, 'count': len(res), 'logs': res})
        out.extend(res)
    raw.put(ep, name, dict(flt, fromBlock=lo, toBlock=hi), {'chunks': chunks, 'total': len(out)})
    return out


def log_key(l):
    return (int(l['blockNumber'], 16), l['transactionHash'].lower(), int(l['logIndex'], 16))


def canon_log(l):
    return (log_key(l), l['address'].lower(), tuple(t.lower() for t in l['topics']), l['data'].lower(),
            l['blockHash'].lower())


def both_logs(eps, raw, name, flt, lo, hi):
    res = [get_logs(ep, raw, name, flt, lo, hi) for ep in eps]
    a, b = (sorted(canon_log(l) for l in r) for r in res)
    check(a == b, '%s: endpoint A and B return identical (block,tx,logIndex,topics,data,blockHash) sets '
                  '(A=%d B=%d) over [%d,%d]' % (name, len(res[0]), len(res[1]), lo, hi))
    return sorted(res[0], key=ord_key), [len(r) for r in res]


def both_call(eps, raw, name, to, data, block, override=None, allow_revert=False):
    out = []
    for ep in eps:
        params = [{'to': to, 'data': data}, hex(block)] + ([override] if override else [])
        r = ep.call('eth_call', params, allow_revert=allow_revert)
        raw.put(ep, name, {'method': 'eth_call', 'to': to, 'data': data, 'block': block,
                           'stateOverride': bool(override)}, r)
        out.append(r)
    check(json.dumps(out[0], sort_keys=True) == json.dumps(out[1], sort_keys=True),
          '%s: identical on A and B' % name)
    return out[0]


def both_uint(eps, raw, name, to, data, block, override=None):
    """eth_call on both endpoints; EACH answer must be exactly one 32-byte ABI word (word()), else FAIL;
    then the two values must be equal. Returns the int."""
    vals = []
    for ep in eps:
        params = [{'to': to, 'data': data}, hex(block)] + ([override] if override else [])
        r = ep.call('eth_call', params)
        raw.put(ep, name, {'method': 'eth_call', 'to': to, 'data': data, 'block': block,
                           'stateOverride': bool(override)}, r)
        try:
            vals.append(word(r))
        except ValueError as e:
            check(False, '%s: %s answer is exactly one 32-byte ABI word (%s)' % (name, ep.label, e))
            raise
    check(vals[0] == vals[1], '%s: identical on A and B (strict 1-word answers)' % name)
    return vals[0]


def both(eps, raw, name, method, params):
    out = []
    for ep in eps:
        r = ep.call(method, params)
        raw.put(ep, name, {'method': method, 'params': params}, r)
        out.append(r)
    check(out[0] == out[1], '%s: identical on A and B' % name)
    return out[0]


def creation_block(eps, raw, name, addr, hi):
    """Independent binary search of the first block with code, per endpoint; also proves state depth."""
    found = []
    for ep in eps:
        lo, h = 0, hi
        if ep.call('eth_getCode', [addr, hex(hi)]) == '0x':
            raise RuntimeError('%s no code at %s' % (addr, hi))
        while lo < h:
            m = (lo + h) // 2
            if ep.call('eth_getCode', [addr, hex(m)]) == '0x':
                lo = m + 1
            else:
                h = m
        before = ep.call('eth_getCode', [addr, hex(lo - 1)])
        at = ep.call('eth_getCode', [addr, hex(lo)])
        raw.put(ep, name, {'method': 'eth_getCode boundary', 'address': addr, 'blocks': [lo - 1, lo]},
                {'codeAtCreationMinus1': before, 'codeAtCreation_len': (len(at) - 2) // 2,
                 'codeAtCreation_keccak': '0x' + keccak(bytes.fromhex(at[2:])).hex()})
        found.append(lo)
        check(before == '0x' and at != '0x', '%s: %s state served at creation boundary (code empty @%d, '
                                             'present @%d)' % (name, ep.label, lo - 1, lo))
    check(found[0] == found[1], '%s: creation block identical on A and B (%s)' % (name, found))
    return found[0]


def dec_string(h):
    b = bytes.fromhex(h[2:])
    if len(b) < 64:
        return None
    off = int.from_bytes(b[:32], 'big')
    n = int.from_bytes(b[off:off + 32], 'big')
    return b[off + 32:off + 32 + n].decode(errors='replace')


def git(*a):
    return subprocess.run(['git'] + list(a), capture_output=True, text=True, check=True).stdout


def event_sigs_from_tags(tags):
    """Every event declared in contracts/src at the given tags -> {topic0: canonical signature}."""
    types = {'ISuperPaymaster.SlashLevel': 'uint8', 'SlashLevel': 'uint8'}
    out = {}
    for tag in tags:
        for f in git('ls-tree', '-r', '--name-only', tag, '--', 'contracts/src').split():
            if not f.endswith('.sol'):
                continue
            txt = git('show', '%s:%s' % (tag, f))
            for m in re.finditer(r'\bevent\s+(\w+)\s*\(([^;]*?)\)\s*;', txt, re.S):
                params = re.sub(r'//[^\n]*', '', m.group(2))
                ts = []
                for p in [p for p in params.split(',') if p.strip()]:
                    t = p.strip().split()[0]
                    t = types.get(t, t)
                    if t.startswith('contract') or t[:1].isupper():
                        t = 'address' if t[:1] == 'I' and t not in types else t
                    ts.append({'uint': 'uint256', 'int': 'int256'}.get(t, t))
                s = '%s(%s)' % (m.group(1), ','.join(ts))
                out[k(s)] = s
    for s in ['Upgraded(address)', 'Initialized(uint64)', 'OwnershipTransferred(address,address)',
              'Approval(address,address,uint256)', 'Transfer(address,address,uint256)']:
        out[k(s)] = s
    return out


def impl_of_clone(code):
    c = code[2:].lower()
    if len(c) == 90 and c.startswith('363d3d373d3d3d363d73') and c.endswith('5af43d82803e903d91602b57fd5bf3'):
        return '0x' + c[20:60]
    return None


def mapping_slot_discovery(eps, raw, name, target, calldata, slot_fn, maxslot=300):
    """Positive control for a mapping getter: plant value (1000+s) at the slot computed for every candidate
    declaration slot s via eth_call state override, call the getter and require it returns a planted value.
    Proves the selector dispatches to a storage read of exactly that mapping entry."""
    diff = {}
    for s in range(maxslot):
        diff['0x' + slot_fn(s).hex()] = '0x' + (1000 + s).to_bytes(32, 'big').hex()
    v = both_uint(eps, raw, name, target, calldata, BLOCK, override={target: {'stateDiff': diff}}) - 1000
    check(0 <= v < maxslot, '%s: getter returns a planted value -> mapping declared at slot %d' % (name, v))
    return v


# ---------------------------------------------------------------- main ------------------------------
def main():
    global BLOCK
    ap = argparse.ArgumentParser()
    ap.add_argument('--block', type=int, default=11881000)
    ap.add_argument('--row0', default='docs/design/aoa-balance-mode/data/d5b/debt-scan-row0')
    ap.add_argument('--legacy', default='docs/design/aoa-balance-mode/data/d5b/legacy-debt-7b')
    args = ap.parse_args()
    BLOCK = args.block

    url_a = os.environ.get('RPC_A') or load_env('~/Dev/.env').get('SEPOLIA_RPC')
    url_b = os.environ.get('RPC_B') or 'https://sepolia.gateway.tenderly.co'
    if not url_a:
        sys.exit('endpoint A missing: set RPC_A or SEPOLIA_RPC in ~/Dev/.env')
    EPS = [EP('A', url_a), EP('B', url_b)]
    # the path/key part of each URL is what must never be written
    SECRET_PARTS = [p for x in (url_a, url_b) for p in x.split('/')[3:] if len(p) >= 12]

    os.makedirs(args.row0, exist_ok=True)
    os.makedirs(args.legacy, exist_ok=True)
    R0, R7 = Raw(args.row0), Raw(args.legacy)
    log('A2 row0/7b debt scan; fixed block', BLOCK, '; endpoints:', ', '.join('%s=%s' % (e.label, e.host) for e in EPS))
    _me = os.path.relpath(os.path.abspath(__file__), git('rev-parse', '--show-toplevel').strip())
    log('script', _me, 'sha256', __import__('hashlib').sha256(open(__file__, 'rb').read()).hexdigest(),
        '; repo HEAD', git('rev-parse', 'HEAD').strip(),
        '; script differs from HEAD:', 'yes' if git('status', '--porcelain', '--', _me).strip() else 'no')

    try:
        # ---- 0. endpoints, fixed block ----------------------------------------------------------------
        for ep in EPS:
            cid = u(ep.call('eth_chainId', []))
            head = u(ep.call('eth_blockNumber', []))
            check(cid == CHAIN_ID, '%s chainId == %d' % (ep.label, CHAIN_ID))
            check(BLOCK <= head - FINALITY_MARGIN, '%s fixed block %d <= head %d - %d' % (ep.label, BLOCK, head,
                                                                                             FINALITY_MARGIN))
        blk = [ep.call('eth_getBlockByNumber', [hex(BLOCK), False]) for ep in EPS]
        for ep, b in zip(EPS, blk):
            R0.put(ep, 'block-fixed', {'method': 'eth_getBlockByNumber', 'block': BLOCK},
                   {'number': b['number'], 'hash': b['hash'], 'timestamp': b['timestamp']})
        check(blk[0]['hash'] == blk[1]['hash'], 'fixed block hash identical on A and B (%s)' % blk[0]['hash'])
        FIXED = {'number': BLOCK, 'hash': blk[0]['hash'], 'timestamp': u(blk[0]['timestamp'])}

        # ---- 1. source: tags + exact declarations; topics -------------------------------------------
        src = {}
        for tag, sha in EXPECTED_TAGS.items():
            got = git('rev-parse', tag + '^{commit}').strip()
            check(got == sha, 'tag %s -> %s' % (tag, got))
        for tag, path, decl in SOURCE_DECLS:
            txt = re.sub(r'\s+', ' ', git('show', '%s:%s' % (tag, path)))
            ok = decl in txt
            check(ok, 'source %s:%s declares `%s`' % (tag, path, decl))
            src.setdefault(tag, []).append({'path': path, 'declaration': decl})
        topics = {n: {'signature': s, 'topic0': T[n]} for n, s in SIG.items()}
        log('topic0 DebtRecordFailed(address,address,uint256) =', T['DebtRecordFailed'])
        log('topic0 DebtRecorded(address,uint256)            =', T['DebtRecorded'])
        SIGDB = event_sigs_from_tags(['v5.4.2', 'v5.5.0-rc.2'])
        for s in OPERATOR_TOPIC1_EVENTS:
            check(k(s) in SIGDB, 'operator event %s is declared in tagged source' % s)

        # ---- 2. SP: creation block, live impl, full log dump ---------------------------------------
        C_SP = creation_block(EPS, R0, 'sp-creation', SP, BLOCK)
        impl_now = '0x' + both(EPS, R0, 'sp-impl-slot-at-fixed', 'eth_getStorageAt', [SP, EIP1967_IMPL_SLOT, hex(BLOCK)])[-40:]
        check(impl_now == EXPECTED_SP_IMPL, 'SP ERC-1967 impl at fixed block == %s' % EXPECTED_SP_IMPL)
        v = dec_string(both_call(EPS, R0, 'sp-version-at-fixed', SP, sel('version()'), BLOCK))
        check(v == EXPECTED_SP_VERSION, 'SP.version() at fixed block == %s (got %s)' % (EXPECTED_SP_VERSION, v))

        sp_all, sp_all_n = both_logs(EPS, R0, 'sp-all-logs', {'address': SP}, C_SP, BLOCK)
        by_t0 = collections.Counter(l['topics'][0].lower() for l in sp_all)
        unknown = [t for t in by_t0 if t not in SIGDB]
        check(not unknown, 'every topic0 emitted by SP over [creation, fixed] decodes to an event declared in the '
                           'tagged sources (unknown: %s)' % unknown)
        sp_topic_counts = {SIGDB.get(t, t): n for t, n in by_t0.most_common()}
        log('SP unfiltered log count A=%d B=%d; per event: %s' % (sp_all_n[0], sp_all_n[1], json.dumps(sp_topic_counts)))

        # impl history (Upgraded) + bytecode instrument checks
        upgrades = [(int(l['blockNumber'], 16), addr_of_topic(l['topics'][1])) for l in sp_all if l['topics'][0] == T['Upgraded']]
        check(upgrades and upgrades[0][0] == C_SP, 'first Upgraded log is in the SP creation block %d' % C_SP)
        check(upgrades[-1][1] == impl_now, 'last Upgraded impl == ERC-1967 slot at fixed block')
        impls = []
        for b, impl in upgrades:
            code = both(EPS, R0, 'sp-impl-code-%s' % impl[:10], 'eth_getCode', [impl, hex(BLOCK)])
            c = code[2:].lower()
            ver = dec_string(both_call(EPS, R0, 'sp-impl-version-%s' % impl[:10], impl, sel('version()'), BLOCK))
            row = {'upgradedAtBlock': b, 'impl': impl, 'version': ver, 'runtimeBytes': len(c) // 2,
                   'runtimeKeccak': '0x' + keccak(bytes.fromhex(c)).hex()}
            for n in ['DebtRecordFailed', 'PendingDebtRetried', 'PendingDebtCleared', 'OperatorConfigured',
                      'TransactionSponsored']:
                row['PUSH32_' + n] = ('7f' + T[n][2:]) in c
                check(row['PUSH32_' + n], 'impl %s (%s) bytecode contains PUSH32 topic0 of %s' % (impl, ver, n))
            row['PUSH4_pendingDebts'] = ('63' + sel('pendingDebts(address,address)')[2:]) in c
            check(row['PUSH4_pendingDebts'], 'impl %s dispatcher contains PUSH4 pendingDebts(address,address)' % impl)
            # discrimination (negative control of the bytecode instrument): token-only topic must be absent
            row['PUSH32_DebtRecorded_absent'] = ('7f' + T['DebtRecorded'][2:]) not in c
            check(row['PUSH32_DebtRecorded_absent'], 'negative control: impl %s does NOT contain the token-only '
                                                     'DebtRecorded topic' % impl)
            impls.append(row)

        # filtered DebtRecordFailed scan + same-shaped positive controls
        q = {}
        for n in ['DebtRecordFailed', 'PendingDebtRetried', 'PendingDebtCleared', 'Upgraded', 'TransactionSponsored']:
            logs, ns = both_logs(EPS, R0, 'sp-logs-%s' % n, {'address': SP, 'topics': [T[n]]}, C_SP, BLOCK)
            dump_n = by_t0.get(T[n], 0)
            check(ns[0] == dump_n, '%s: topic-filtered count %d == count inside the unfiltered dump %d' % (n, ns[0], dump_n))
            q[n] = {'topic0': T[n], 'countA': ns[0], 'countB': ns[1],
                    'logs': [{'block': log_key(l)[0], 'tx': log_key(l)[1], 'logIndex': log_key(l)[2],
                              'topics': l['topics'], 'data': l['data']} for l in logs]}
        check(q['Upgraded']['countA'] > 0 and q['Upgraded']['logs'][0]['block'] == C_SP,
              'POSITIVE CONTROL 1 (same shape: address=SP, topics=[Upgraded], same range): >0 logs and the first one '
              'is in the range START block %d -> the endpoints serve logs from the beginning of the range' % C_SP)
        check(q['TransactionSponsored']['countA'] > 0,
              'POSITIVE CONTROL 2 (same shape: address=SP, topics=[TransactionSponsored]): %d > 0'
              % q['TransactionSponsored']['countA'])
        log('DebtRecordFailed count: A=%d B=%d' % (q['DebtRecordFailed']['countA'], q['DebtRecordFailed']['countB']))

        # ---- 3. operator full set -----------------------------------------------------------------
        op_src = collections.defaultdict(set)
        op_t0 = {k(s): s.split('(')[0] for s in OPERATOR_TOPIC1_EVENTS}
        for l in sp_all:
            t0 = l['topics'][0].lower()
            if t0 in op_t0:
                op_src[addr_of_topic(l['topics'][1])].add('SP.' + op_t0[t0])
        C_REG = creation_block(EPS, R0, 'registry-creation', REGISTRY, BLOCK)
        role_logs = {}
        for n in ['RoleRegistered', 'RoleGranted', 'RoleExited', 'RoleRevoked']:
            for rn, rid in [('PAYMASTER_SUPER', ROLE_PAYMASTER_SUPER), ('COMMUNITY', ROLE_COMMUNITY)]:
                logs, ns = both_logs(EPS, R0, 'registry-%s-%s' % (n, rn), {'address': REGISTRY, 'topics': [T[n], rid]},
                                     C_REG, BLOCK)
                role_logs['%s/%s' % (n, rn)] = {'countA': ns[0], 'countB': ns[1],
                                                 'accounts': sorted({addr_of_topic(l['topics'][2]) for l in logs})}
                if rn == 'PAYMASTER_SUPER':
                    for l in logs:
                        op_src[addr_of_topic(l['topics'][2])].add('Registry.%s(PAYMASTER_SUPER)' % n)
        check(role_logs['RoleRegistered/PAYMASTER_SUPER']['countA'] > 0,
              'POSITIVE CONTROL 3 (same shape: address=Registry, topics=[RoleRegistered, PAYMASTER_SUPER]): >0')
        # state-based enumeration: roleMembers[PAYMASTER_SUPER] array read from storage at the fixed block
        cnt = both_uint(EPS, R0, 'registry-getRoleUserCount-PAYMASTER_SUPER', REGISTRY,
                        sel('getRoleUserCount(bytes32)') + ROLE_PAYMASTER_SUPER[2:], BLOCK)
        base = keccak(bytes.fromhex(ROLE_PAYMASTER_SUPER[2:]) + REGISTRY_ROLE_MEMBERS_SLOT.to_bytes(32, 'big'))
        ln = word(both(EPS, R0, 'registry-roleMembers-len', 'eth_getStorageAt', [REGISTRY, '0x' + base.hex(), hex(BLOCK)]))
        check(cnt > 0 and ln == cnt, 'POSITIVE CONTROL 4: roleMembers[PAYMASTER_SUPER].length read from raw storage '
                                     '(slot %d) == getRoleUserCount == %d' % (REGISTRY_ROLE_MEMBERS_SLOT, cnt))
        data0 = int.from_bytes(keccak(base), 'big')
        members = []
        for i in range(ln):
            w = both(EPS, R0, 'registry-roleMembers-%d' % i, 'eth_getStorageAt', [REGISTRY, hex(data0 + i), hex(BLOCK)])
            m = '0x' + ('%064x' % word(w))[-40:]
            hr = both_uint(EPS, R0, 'registry-hasRole-PAYMASTER_SUPER-%d' % i, REGISTRY,
                           sel('hasRole(bytes32,address)') + ROLE_PAYMASTER_SUPER[2:] + pad32(m), BLOCK)
            check(hr == 1, 'roleMembers[PAYMASTER_SUPER][%d] = %s has hasRole == true' % (i, m))
            members.append(m)
            op_src[m].add('Registry.roleMembers[PAYMASTER_SUPER]@fixed')

        operators = []
        for op in sorted(op_src):
            r = both_call(EPS, R0, 'sp-operators-%s' % op[:10], SP, sel('operators(address)') + pad32(op), BLOCK)
            w = [r[2 + 64 * i: 2 + 64 * (i + 1)] for i in range((len(r) - 2) // 64)]
            check(len(w) == 9, 'operators(%s) returns the 9-word 5.4.2 OperatorConfig tuple' % op)
            hasrole = both_uint(EPS, R0, 'registry-hasRole-op-%s' % op[:10], REGISTRY,
                                sel('hasRole(bytes32,address)') + ROLE_PAYMASTER_SUPER[2:] + pad32(op), BLOCK)
            operators.append({'operator': op, 'basis': sorted(op_src[op]), 'aPNTsBalance': str(int(w[0], 16)),
                              'isConfigured': bool(int(w[1], 16)), 'isPaused': bool(int(w[2], 16)),
                              'xPNTsToken': '0x' + w[3][-40:], 'reputation': int(w[4], 16), 'minTxInterval': int(w[5], 16),
                              'treasury': '0x' + w[6][-40:], 'totalSpent': str(int(w[7], 16)),
                              'totalTxSponsored': int(w[8], 16), 'hasRole_PAYMASTER_SUPER': bool(hasrole)})
        configured = [o['operator'] for o in operators if o['isConfigured']]
        oc_emitters = {addr_of_topic(l['topics'][1]) for l in sp_all if l['topics'][0] == T['OperatorConfigured']}
        check(set(configured) <= oc_emitters, 'every operator with isConfigured==true at the fixed block emitted '
                                              'OperatorConfigured (completeness cross-check)')
        log('operator set:', json.dumps([(o['operator'], o['isConfigured'], o['xPNTsToken']) for o in operators]))

        # ---- 4. token set (row 7b scope) ----------------------------------------------------------
        tokens = dict((a, [d]) for a, d in NAMED_TOKENS.items())
        for o in operators:
            if int(o['xPNTsToken'], 16):
                tokens.setdefault(o['xPNTsToken'], []).append('SP.operators(%s).xPNTsToken' % o['operator'])
        for l in sp_all:
            t0 = l['topics'][0]
            if t0 == T['OperatorConfigured']:
                tokens.setdefault('0x' + l['data'][26:66].lower(), []).append('SP.OperatorConfigured data')
            if t0 == T['APNTsTokenChangeQueued']:
                tokens.setdefault(addr_of_topic(l['topics'][1]), []).append('SP.APNTsTokenChangeQueued')
            if t0 == T['DebtRecordFailed']:
                tokens.setdefault(addr_of_topic(l['topics'][1]), []).append('SP.DebtRecordFailed topic1')
        factories = set(EXTRA_FACTORIES)
        for l in sp_all:
            if l['topics'][0] == T['XPNTsFactoryUpdated']:
                factories.add(addr_of_topic(l['topics'][2]))
        factory_rows = []
        for fac in sorted(factories):
            cf = creation_block(EPS, R7, 'factory-creation-%s' % fac[:10], fac, BLOCK)
            logs, ns = both_logs(EPS, R7, 'factory-%s-xPNTsTokenDeployed' % fac[:10],
                                 {'address': fac, 'topics': [T['xPNTsTokenDeployed']]}, cf, BLOCK)
            check(ns[0] > 0, 'POSITIVE CONTROL (factory %s): xPNTsTokenDeployed count %d > 0' % (fac, ns[0]))
            for l in logs:
                tokens.setdefault(addr_of_topic(l['topics'][2]), []).append('factory %s xPNTsTokenDeployed' % fac)
            factory_rows.append({'factory': fac, 'creationBlock': cf, 'deployedCountA': ns[0], 'deployedCountB': ns[1],
                                 'tokens': [addr_of_topic(l['topics'][2]) for l in logs]})

        # ---- 5. pendingDebts reconciliation -------------------------------------------------------
        pd_slot = mapping_slot_discovery(
            EPS, R0, 'pc-pendingDebts-override', SP,
            sel('pendingDebts(address,address)') + pad32('0x696a73701b104c6ccbbaaddd2216788ea08eab89')
            + pad32('0x00000000000000000000000000000000000000aa'),
            lambda s: keccak(bytes.fromhex(pad32('0x00000000000000000000000000000000000000aa')) +
                             keccak(bytes.fromhex(pad32('0x696a73701b104c6ccbbaaddd2216788ea08eab89')) + s.to_bytes(32, 'big'))))
        neg = both_call(EPS, R0, 'nc-sp-unknown-selector', SP, '0xdeadbeef', BLOCK, allow_revert=True)
        check(isinstance(neg, dict) and '__error__' in neg, 'NEGATIVE CONTROL: unknown selector 0xdeadbeef on SP reverts '
                                                            '(a 32-byte answer therefore means the selector dispatched)')
        expected = collections.defaultdict(int)
        for n, sign in [('DebtRecordFailed', 1), ('PendingDebtRetried', -1), ('PendingDebtCleared', -1)]:
            for l in q[n]['logs']:
                check(bool(WORD_RE.fullmatch(l['data'])), '%s@%d data is exactly 1 word' % (n, l['block']))
                expected[(addr_of_topic(l['topics'][1]), addr_of_topic(l['topics'][2]))] += sign * word(l['data'])
        users = set()
        for l in sp_all:
            if l['topics'][0] in (T['TransactionSponsored'],) and len(l['topics']) > 2:
                users.add(addr_of_topic(l['topics'][2]))
        pairs = set(expected)
        # (filled after the token debt scan adds DebtRecorded users)

        # ---- 6. legacy token debt scan ------------------------------------------------------------
        token_rows = []
        debt_users = set()
        token_logs = {}
        for tok in sorted(tokens):
            ct = creation_block(EPS, R7, 'token-creation-%s' % tok[:10], tok, BLOCK)
            code = both(EPS, R7, 'token-code-%s' % tok[:10], 'eth_getCode', [tok, hex(BLOCK)])
            impl = impl_of_clone(code)
            icode = both(EPS, R7, 'token-impl-code-%s' % tok[:10], 'eth_getCode', [impl or tok, hex(BLOCK)])[2:].lower()
            ver = dec_string(both_call(EPS, R7, 'token-version-%s' % tok[:10], tok, sel('version()'), BLOCK))
            sym = dec_string(both_call(EPS, R7, 'token-symbol-%s' % tok[:10], tok, sel('symbol()'), BLOCK))
            ins = {'PUSH32_DebtRecorded': ('7f' + T['DebtRecorded'][2:]) in icode,
                   'PUSH32_DebtRepaid': ('7f' + T['DebtRepaid'][2:]) in icode,
                   'PUSH4_getDebt': ('63' + sel('getDebt(address)')[2:]) in icode,
                   'PUSH32_DebtRecordFailed_absent': ('7f' + T['DebtRecordFailed'][2:]) not in icode}
            for kk, vv in ins.items():
                check(vv, 'token %s impl %s: %s' % (tok, impl, kk))
            allt, alln = both_logs(EPS, R7, 'token-%s-all-logs' % tok[:10], {'address': tok}, ct, BLOCK)
            tc = collections.Counter(l['topics'][0].lower() for l in allt)
            rows = {}
            for n in ['DebtRecorded', 'DebtRepaid', 'Transfer']:
                logs, ns = both_logs(EPS, R7, 'token-%s-%s' % (tok[:10], n), {'address': tok, 'topics': [T[n]]}, ct, BLOCK)
                check(ns[0] == tc.get(T[n], 0), 'token %s %s filtered count %d == unfiltered dump count %d'
                      % (tok, n, ns[0], tc.get(T[n], 0)))
                rows[n] = (logs, ns)
            check(rows['Transfer'][1][0] > 0, 'POSITIVE CONTROL (token %s, same shape: address=token, topics=[Transfer], '
                                              'same range): %d > 0' % (tok, rows['Transfer'][1][0]))
            # Replay in EXECUTION order (block, logIndex): every DebtRepaid.remainingDebt must equal the running
            # event-derived balance (cross-checks that no debt was written without an event between two logged points).
            exp, results = replay_token_debt(rows['DebtRecorded'][0] + rows['DebtRepaid'][0],
                                             T['DebtRecorded'], T['DebtRepaid'])
            for ok, msg in results:
                check(ok, 'token %s %s' % (tok, msg))
            exp = collections.defaultdict(int, exp)
            slot = mapping_slot_discovery(
                EPS, R7, 'pc-getDebt-override-%s' % tok[:10], tok,
                sel('getDebt(address)') + pad32('0x00000000000000000000000000000000000000aa'),
                lambda s: keccak(bytes.fromhex(pad32('0x00000000000000000000000000000000000000aa')) + s.to_bytes(32, 'big')))
            per_user = []
            total_onchain = 0
            for usr in sorted(exp):
                debt = both_uint(EPS, R7, 'token-%s-getDebt-%s' % (tok[:10], usr[:10]), tok,
                                 sel('getDebt(address)') + pad32(usr), BLOCK)
                check(debt == exp[usr], 'token %s user %s: getDebt@fixed %d == sum(DebtRecorded) - sum(DebtRepaid) %d'
                      % (tok, usr, debt, exp[usr]))
                per_user.append({'user': usr, 'getDebtAtFixed': str(debt), 'eventDerived': str(exp[usr]),
                                 'recorded': [{'block': log_key(l)[0], 'tx': log_key(l)[1], 'logIndex': log_key(l)[2],
                                               'amount': str(u(l['data'][:66]))} for l in rows['DebtRecorded'][0]
                                              if addr_of_topic(l['topics'][1]) == usr],
                                 'repaid': [{'block': log_key(l)[0], 'tx': log_key(l)[1], 'logIndex': log_key(l)[2],
                                             'amountRepaid': str(u(l['data'][2:66])), 'remainingDebt': str(u(l['data'][66:130]))}
                                            for l in rows['DebtRepaid'][0] if addr_of_topic(l['topics'][1]) == usr]})
                total_onchain += debt
                debt_users.add(usr)
            token_rows.append({'token': tok, 'symbol': sym, 'version': ver, 'implementation': impl, 'why_in_scope': sorted(set(tokens[tok])),
                               'creationBlock': ct, 'range': [ct, BLOCK], 'instrument': ins, 'debtsMappingSlot': slot,
                               'unfilteredLogCountA': alln[0], 'unfilteredLogCountB': alln[1],
                               'unfilteredPerEvent': {SIGDB.get(t, t): n for t, n in tc.most_common()},
                               'DebtRecorded': {'countA': rows['DebtRecorded'][1][0], 'countB': rows['DebtRecorded'][1][1]},
                               'DebtRepaid': {'countA': rows['DebtRepaid'][1][0], 'countB': rows['DebtRepaid'][1][1]},
                               'Transfer_positiveControl': {'countA': rows['Transfer'][1][0], 'countB': rows['Transfer'][1][1]},
                               'users': per_user, 'totalOutstandingDebt_aPNTsWei': str(total_onchain)})
            log('token %s %s %s: DebtRecorded A=%d B=%d, DebtRepaid A=%d B=%d, Transfer(PC) A=%d B=%d, outstanding=%d'
                % (tok, sym, ver, rows['DebtRecorded'][1][0], rows['DebtRecorded'][1][1], rows['DebtRepaid'][1][0],
                   rows['DebtRepaid'][1][1], rows['Transfer'][1][0], rows['Transfer'][1][1], total_onchain))

        # pendingDebts: event-revealed pairs + cross product (tokens x every user seen anywhere)
        users |= debt_users
        users |= {u2 for (_, u2) in expected}
        for tok in tokens:
            for usr in users:
                pairs.add((tok, usr))
        pd_rows = []
        for tok, usr in sorted(pairs):
            val = both_uint(EPS, R0, 'sp-pendingDebts-%s-%s' % (tok[:10], usr[:10]), SP,
                            sel('pendingDebts(address,address)') + pad32(tok) + pad32(usr), BLOCK)
            check(val == expected.get((tok, usr), 0), 'pendingDebts(%s,%s)@fixed %d == event-derived %d'
                  % (tok, usr, val, expected.get((tok, usr), 0)))
            pd_rows.append({'token': tok, 'user': usr, 'pendingDebtsAtFixed': str(val),
                            'eventDerived': str(expected.get((tok, usr), 0)),
                            'source': 'DebtRecordFailed' if (tok, usr) in expected else 'cross-product (tokens x users)'})

        inv = {
            'schema': 'a2-row0-debt-scan/1', 'fixedBlock': FIXED,
            'endpoints': [{'label': e.label, 'host': e.host, 'requests': e.n} for e in EPS],
            'sources': {'tags': EXPECTED_TAGS, 'declarations': src}, 'topics': topics,
            'superPaymaster': {'proxy': SP, 'creationBlock': C_SP, 'range': [C_SP, BLOCK], 'implAtFixed': impl_now,
                               'versionAtFixed': v, 'implHistory': impls,
                               'unfilteredLogCount': {'A': sp_all_n[0], 'B': sp_all_n[1]}, 'unfilteredPerEvent': sp_topic_counts},
            'scans': q,
            'positiveControls': {
                'PC1_Upgraded_at_range_start': {'countA': q['Upgraded']['countA'], 'countB': q['Upgraded']['countB'],
                                                'firstBlock': q['Upgraded']['logs'][0]['block']},
                'PC2_TransactionSponsored': {'countA': q['TransactionSponsored']['countA'],
                                             'countB': q['TransactionSponsored']['countB']},
                'PC3_Registry_RoleRegistered_PAYMASTER_SUPER': role_logs['RoleRegistered/PAYMASTER_SUPER'],
                'PC4_roleMembers_storage_len_eq_getRoleUserCount': cnt,
                'PC5_pendingDebts_getter_state_override_slot': pd_slot,
                'NC_unknown_selector_reverts': True},
            'registry': {'proxy': REGISTRY, 'creationBlock': C_REG, 'roleLogs': role_logs,
                         'roleMembers_PAYMASTER_SUPER_atFixed': members},
            'operators': operators,
            'pendingDebts': {'pairsChecked': len(pd_rows), 'nonZero': [r for r in pd_rows if r['pendingDebtsAtFixed'] != '0'],
                             'rows': pd_rows},
        }
        leg = {'schema': 'a2-7b-legacy-debt/1', 'fixedBlock': FIXED,
               'endpoints': [{'label': e.label, 'host': e.host} for e in EPS],
               'factories': factory_rows, 'tokens': token_rows,
               'grandTotalOutstanding_aPNTsWei': str(sum(int(t['totalOutstandingDebt_aPNTsWei']) for t in token_rows))}
    except Exception as e:  # any RPC / parse failure is a failure, never a silent zero
        FAIL.append('exception: %s: %s' % (type(e).__name__, str(e)[:300]))
        log('EXCEPTION', type(e).__name__, str(e)[:300])
        inv, leg = None, None

    if inv:
        with open(os.path.join(args.row0, 'inventory.json'), 'w') as f:
            json.dump(inv, f, indent=1, sort_keys=True); f.write('\n')
        with open(os.path.join(args.legacy, 'legacy-debt.json'), 'w') as f:
            json.dump(leg, f, indent=1, sort_keys=True); f.write('\n')
    log('CHECK totals: OK=%d FAIL=%d' % (sum(1 for x in LOG if x.startswith('CHECK OK')), len(FAIL)))
    log('RESULT', 'FAIL (%d)' % len(FAIL) if FAIL else 'OK', *(['\n  - ' + x for x in FAIL]))
    with open(os.path.join(args.row0, 'scan.log'), 'w') as f:
        f.write('\n'.join(LOG) + '\n')

    # secret scan of everything written (fail-closed)
    leak = []
    for d in (args.row0, args.legacy):
        for root, _, files in os.walk(d):
            for fn in files:
                p = os.path.join(root, fn)
                txt = open(p, errors='replace').read()
                if any(s in txt for s in SECRET_PARTS):
                    leak.append(p)
    if leak:
        print('SECRET LEAK in', leak)
        sys.exit(1)
    sys.exit(1 if FAIL else 0)


if __name__ == '__main__':
    main()
