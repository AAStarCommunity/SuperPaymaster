#!/usr/bin/env python3
"""Unsigned A3a planning and isolated Amsterdam rehearsal. No signing implementation."""
import argparse
import contextlib
import copy
from dataclasses import dataclass
import hashlib
from functools import lru_cache
import http.server
import json
from pathlib import Path
import socket
import subprocess
import sys
import threading
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'script/evidence/lib'))
from rpc_strict import HEXDATA, QTY, HASH32, classify

ENGINE = Path('/Users/jason/Dev/aastar/tools/foundry-rams/nightly-926eb1d')
COMMIT = '926eb1d087523f1de437e3c0c49ea6d26407e827'
PACKET = ROOT / 'docs/release/a3a-precheck-v4/a3a-precheck.json'
CHAIN = 11155111
ACTIVATION = 1791294816
FORK_ID = '0x6c1d9423'
MARGIN_NUM, MARGIN_DEN = 13, 10
MAX_FEE, PRIORITY = 20_000_000_000, 100_000_000
ZERO = '0x' + '00' * 20
ZERO32 = '0x' + '00' * 32
DEPLOYER = '0xb5600060e6de5e11d3636731964218e53caadf0e'
SAFE = '0x51edf11fdb0a4f66220efb8efa54eca77232e114'
SP = '0x09df0d2e3722ec0e401fe3819e64278a42ae4de9'
EXECUTOR = '0x871608cba092105b91e91295a1d79ffc539bfb48'
APPROVER = '0x8c3499252232105a1615767c459db9bbbf1273d6'
REFUSAL = "not authorized: requires a reviewed plan hash and the author's separate go"
EIP712_IMMUTABLES = frozenset(('_cachedDomainSeparator', '_cachedChainId', '_cachedThis',
                             '_hashedName', '_hashedVersion', '_name', '_version'))
STEP_IDS = ('S1', 'S2', 'S3', 'S4', 'S5a', 'S5b', 'S6a', 'S6b', 'S7')
CONTROL_IDS = ('S4_before_S3', 'wrong_safe_nonce', 'early_execute', 'non_owner_queue')
SENDERS = {'deployer': DEPLOYER, 'approver': APPROVER, 'executor': EXECUTOR}
EMPTY_KECCAK = '0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470'


class Gate(Exception):
    def __init__(self, name, observed, expected):
        self.record = dict(status='FAILURE', gate=name, observed=observed, expected=expected)
        super().__init__(name)


def need(name, observed, expected):
    if observed != expected:
        raise Gate(name, observed, expected)


def typed(value, rx, gate='rpc_result'):
    if not isinstance(value, str) or not rx.fullmatch(value):
        raise Gate(gate, 'malformed typed result', rx.pattern)
    return value


def qty(value):
    return int(typed(value, QTY), 16)


class RPC:
    def __init__(self, url, local=False):
        self.url, self.local, self.serial = url, local, 0

    def __call__(self, method, params, error_ok=False):
        if not self.local and not (method.startswith('eth_get') or method in
                                  ('eth_chainId', 'eth_config', 'eth_call', 'eth_estimateGas', 'web3_sha3')):
            raise Gate('remote_read_only', method, 'read-only RPC')
        self.serial += 1
        rid = self.serial
        q = dict(jsonrpc='2.0', id=rid, method=method, params=params)
        try:
            with urllib.request.urlopen(urllib.request.Request(
                    self.url, json.dumps(q).encode(), {'Content-Type': 'application/json'}), timeout=45) as r:
                d = json.load(r)
        except Exception as e:
            raise Gate('rpc_transport', type(e).__name__, 'valid response (URL redacted)') from None
        if (not isinstance(d, dict) or d.get('jsonrpc') != '2.0' or
                type(d.get('id')) is not int or d['id'] != rid or
                (('result' in d) == ('error' in d))):
            raise Gate('rpc_envelope', 'malformed envelope', 'JSON-RPC 2.0 matching integer id; result XOR error')
        if 'error' in d:
            e = d['error']
            if not isinstance(e, dict) or type(e.get('code')) is not int or not isinstance(e.get('message'), str):
                raise Gate('rpc_envelope', 'malformed error', 'integer code and string message')
            if method == 'eth_config' and e['code'] == -32601:
                raise Gate('fork_config_missing', 'unsupported', 'eth_config required')
            if error_ok and classify(e, method) == 'evm-failure':
                # Do not persist provider messages, which can contain credentials or URLs.
                return {'revert': e.get('data')}
            raise Gate('rpc_fault', {'method': method, 'code': e['code']}, 'successful RPC')
        return d['result']


@lru_cache(maxsize=4096)
def cast(*args):
    r = subprocess.run([str(ENGINE / 'cast'), *map(str, args)], capture_output=True, text=True)
    if r.returncode:
        raise Gate('local_encoding', 'cast failed', 'successful offline ABI/hash operation')
    return r.stdout.strip()


def keccak(data):
    return typed(cast('keccak', data), HASH32)


def rpc_keccak(rpc, data):
    return typed(rpc('web3_sha3', [typed(data, HEXDATA)]), HASH32).lower()


def check_keccak(rpc):
    need('keccak_vector', rpc_keccak(rpc, '0x'), EMPTY_KECCAK)


def ast_nodes(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from ast_nodes(child)
    elif isinstance(value, list):
        for child in value:
            yield from ast_nodes(child)


def immutable_identity(a, build_info=None):
    """Resolve IDs only within compilation units containing this exact runtime/artifact.

    IDs are compilation-local. Never combine AST IDs from unrelated builds.
    Minimal Foundry build-info without output ASTs is insufficient evidence.
    """
    deployed = a['deployedBytecode']
    runtime = typed(deployed['object'], HEXDATA, 'artifact_bytecode').lower()
    refs = deployed.get('immutableReferences', {})
    if not isinstance(refs, dict):
        raise Gate('immutable_references', 'malformed', 'reference id -> ranges')
    candidates = []
    for path in sorted((build_info or ROOT/'out/build-info').glob('*.json')):
        info = json.loads(path.read_text())
        output = info.get('output', {})
        matching = any(
            contract.get('evm', {}).get('deployedBytecode', {}).get('object', '').removeprefix('0x').lower()
            == runtime[2:] and
            contract.get('evm', {}).get('deployedBytecode', {}).get('immutableReferences', {}) == refs
            for contracts in output.get('contracts', {}).values()
            for name, contract in contracts.items() if name == 'APNTsCapped')
        if not matching:
            continue
        names = {}
        for node in ast_nodes(output.get('sources', {})):
            if (node.get('nodeType') == 'VariableDeclaration' and node.get('stateVariable') is True
                    and node.get('mutability') == 'immutable'):
                key = str(node.get('id'))
                if key in names:
                    need('immutable_id_ambiguous', names[key], node.get('name'))
                names[key] = node.get('name')
        if names:
            candidates.append(names)
    if not candidates:
        raise Gate('immutable_build_info', 'no matching full compiler output with ASTs',
                   'out/build-info/*.json with output.contracts runtime and output.sources ASTs')
    resolved = []
    for names in candidates:
        resolved.append({key: names.get(key) for key in refs})
    for names in resolved[1:]:
        need('immutable_build_ambiguous', names, resolved[0])
    names = resolved[0]
    for key, name in names.items():
        if name not in EIP712_IMMUTABLES:
            raise Gate('immutable_unknown_id', {'id': key, 'name': name}, sorted(EIP712_IMMUTABLES))
    need('immutable_named_set', sorted(names.values()), sorted(EIP712_IMMUTABLES))
    ranges, occupied = [], set()
    size = len(bytes.fromhex(runtime[2:]))
    for key, entries in refs.items():
        if not isinstance(entries, list) or not entries:
            raise Gate('immutable_ranges', key, 'nonempty list of 32-byte ranges')
        for entry in entries:
            start, length = entry.get('start'), entry.get('length')
            if (type(start) is not int or type(length) is not int or start < 0 or
                    length != 32 or start + length > size):
                raise Gate('immutable_range_bounds', entry, '32 bytes wholly inside runtime')
            span = set(range(start, start+length))
            need('immutable_range_overlap', bool(span & occupied), False)
            occupied.update(span)
            ranges.append(dict(id=key, name=names[key], start=start, length=length))
    return dict(artifactRuntime=runtime, ranges=ranges)


def short_string(value):
    raw = value.encode('utf-8')
    if len(raw) <= 31:
        return raw.ljust(31, b'\0') + bytes([len(raw)]), 'inline'
    return bytes(31) + b'\xff', 'fallback'


def immutable_values(rpc, plan):
    check_keccak(rpc)
    args = plan['constructorArgs']
    if not isinstance(args, list) or len(args) != 6 or not isinstance(args[0], str):
        raise Gate('immutable_constructor_args', 'malformed', 'six APNTsCapped constructor arguments')
    # ERC20Permit(name_) fixes EIP712's version to "1".
    name, version = args[0], '1'
    need('immutable_chain_id', plan['chainId'], CHAIN)
    def hash_bytes(raw):
        return bytes.fromhex(rpc_keccak(rpc, '0x'+raw.hex())[2:])
    hashed_name, hashed_version = hash_bytes(name.encode('utf-8')), hash_bytes(version.encode('utf-8'))
    chain = plan['chainId'].to_bytes(32, 'big')
    target = bytes.fromhex(plan['pin']['capped'][2:])
    need('immutable_address_length', len(target), 20)
    target = bytes(12) + target
    domain_type = hash_bytes(b'EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)')
    short_name, name_case = short_string(name)
    short_version, version_case = short_string(version)
    values = dict(_hashedName=hashed_name, _hashedVersion=hashed_version, _cachedChainId=chain,
                  _cachedThis=target,
                  _cachedDomainSeparator=hash_bytes(domain_type+hashed_name+hashed_version+chain+target),
                  _name=short_name, _version=short_version)
    need('immutable_expected_set', sorted(values), sorted(EIP712_IMMUTABLES))
    return values, dict(_name=name_case, _version=version_case)


def verify_runtime(rpc, plan, code):
    identity = plan['runtimeIdentity']
    expected = bytearray.fromhex(typed(identity['artifactRuntime'], HEXDATA)[2:])
    actual = bytearray.fromhex(typed(code, HEXDATA)[2:])
    need('runtime_length', len(actual), len(expected))
    values, cases = immutable_values(rpc, plan)
    seen, occupied, observed = {}, set(), {}
    for entry in identity['ranges']:
        key, name, start, length = entry['id'], entry['name'], entry['start'], entry['length']
        if name not in values:
            raise Gate('immutable_expected_unknown', name, sorted(values))
        if type(start) is not int or type(length) is not int or start < 0 or length != 32 or start+length > len(actual):
            raise Gate('immutable_range_bounds', entry, '32 bytes wholly inside runtime')
        span = set(range(start, start+length))
        need('immutable_range_overlap', bool(span & occupied), False)
        occupied.update(span)
        if key in seen:
            need('immutable_repeated_name', name, seen[key])
        seen[key] = name
        value = bytes(actual[start:start+length])
        need('immutable_value_'+name, '0x'+value.hex(), '0x'+values[name].hex())
        observed.setdefault(name, []).append(dict(id=key, start=start, value='0x'+value.hex()))
        actual[start:start+length] = expected[start:start+length] = bytes(length)
    need('immutable_runtime_set', sorted(seen.values()), sorted(EIP712_IMMUTABLES))
    need('runtime_unmasked_bytes', actual == expected, True)
    return dict(immutables=observed, shortStringCases=cases, unmaskedBytesEqual=True)


def calldata(signature, *args):
    return typed(cast('calldata', signature, *args), HEXDATA)


def call(rpc, address, signature, *args, block='latest'):
    return typed(rpc('eth_call', [{'to': address, 'data': calldata(signature, *args)}, block]), HEXDATA)


def word(rpc, address, signature, *args, block='latest'):
    w = call(rpc, address, signature, *args, block=block)
    need('abi_word_length', len(w), 66)
    return int(w, 16)


def address(rpc, target, signature, block='latest'):
    n = word(rpc, target, signature, block=block)
    need('abi_address_padding', n >> 160, 0)
    return f'0x{n:040x}'


def nonce(rpc, who, block='latest'):
    return qty(rpc('eth_getTransactionCount', [who, block]))


def block_data(rpc, block):
    b = rpc('eth_getBlockByNumber', [block, False])
    if not isinstance(b, dict):
        raise Gate('pinned_block', 'missing block', block)
    typed(b.get('hash'), HASH32)
    qty(b.get('number'))
    qty(b.get('timestamp'))
    return b


def artifact(name):
    base = ROOT / 'out' / (name + '.sol')
    path = base / (name + '.default.json')
    if not path.exists():
        path = base / (name + '.json')
    if not path.exists():
        raise Gate('build_artifact', name + ' missing', 'local default build artifact')
    a = json.loads(path.read_text())
    metadata = a['metadata']
    if isinstance(metadata, str):
        metadata = json.loads(metadata)
    need('artifact_evm', metadata['settings']['evmVersion'], 'cancun')
    need('artifact_optimizer', metadata['settings']['optimizer']['runs'], 500)
    for field in ('bytecode', 'deployedBytecode'):
        typed(a[field]['object'], HEXDATA, 'artifact_bytecode')
    if name == 'APNTsCapped':
        a['runtimeIdentity'] = immutable_identity(a)
    else:
        need('artifact_immutables', a['deployedBytecode'].get('immutableReferences', {}), {})
    return a


def preflight(rpc, block):
    need('chain_id', qty(rpc('eth_chainId', [])), CHAIN)
    config = rpc('eth_config', [])
    if not isinstance(config, dict) or not isinstance(config.get('current'), dict):
        raise Gate('fork_config_missing', 'missing current', 'current Amsterdam config')
    current = config['current']
    need('fork_activation', current.get('activationTime'), ACTIVATION)
    need('fork_id', current.get('forkId'), FORK_ID)
    need('fork_next', config.get('next', 'missing'), None)
    b = block_data(rpc, block)
    need('pinned_block', b['number'], block)
    if qty(b['timestamp']) < ACTIVATION:
        raise Gate('pinned_fork_time', qty(b['timestamp']), '>= Amsterdam activation')
    n = nonce(rpc, DEPLOYER, block)
    need('deployer_nonce_pending', nonce(rpc, DEPLOYER, 'pending'), n)
    safe_n = word(rpc, SAFE, 'nonce()', block=block)
    owners_raw = call(rpc, SAFE, 'getOwners()', block=block)
    raw = bytes.fromhex(owners_raw[2:])
    need('safe_owners_encoding', len(raw), 160)
    need('safe_owners_offset', int.from_bytes(raw[:32], 'big'), 32)
    need('safe_owners_count', int.from_bytes(raw[32:64], 'big'), 3)
    for i in range(64, len(raw), 32):
        need('safe_owner_padding', raw[i:i+12].hex(), '00'*12)
    owners = ['0x' + raw[i:i+32].hex()[-40:] for i in range(64, len(raw), 32)]
    snapshot = json.loads((PACKET.parent / 'snapshot.json').read_text())['snapshot']
    need('safe_owners', sorted(owners), sorted(x.lower() for x in snapshot['multisig']['owners']))
    need('safe_threshold', word(rpc, SAFE, 'getThreshold()', block=block), 2)
    sp = {}
    for name in ('owner', 'APNTS_TOKEN', 'pendingAPNTsToken'):
        sp[name] = address(rpc, SP, name + '()', block)
        need('sp_' + name, sp[name], snapshot['sp'][name].lower())
    for name in ('pendingAPNTsTokenEta', 'APNTS_TOKEN_TIMELOCK'):
        sp[name] = word(rpc, SP, name + '()', block=block)
        need('sp_' + name, sp[name], int(snapshot['sp'][name]))
    predicted = [json.loads(cast('compute-address', DEPLOYER, '--nonce', n+i, '--json'))['data'].lower()
                 for i in (1, 2)]
    for a in predicted:
        need('create_address_empty', typed(rpc('eth_getCode', [a, block]), HEXDATA), '0x')
    senders = {}
    for label, who in SENDERS.items():
        at_pin = nonce(rpc, who, block)
        need(label+'_nonce_pending', nonce(rpc, who, 'pending'), at_pin)
        senders[label] = dict(address=who, nonce=at_pin, balance=qty(rpc('eth_getBalance', [who, block])))
    balance = senders['deployer']['balance']
    return dict(block=block, blockHash=b['hash'], timestamp=qty(b['timestamp']),
                deployerNonce=n, safeNonce=safe_n, owners=owners, sp=sp,
                timelock=predicted[0], capped=predicted[1], balance=balance, senders=senders)


def build_plan(state):
    for label, who in SENDERS.items():
        need('plan_sender_'+label, state['senders'][label]['address'], who)
    n = state['senders']['deployer']['nonce']
    need('plan_deployer_nonce', state['deployerNonce'], n)
    tl, token = [json.loads(cast('compute-address', DEPLOYER, '--nonce', n+i, '--json'))['data'].lower()
                 for i in (1, 2)]
    need('plan_predicted_timelock', state['timelock'], tl)
    need('plan_predicted_capped', state['capped'], token)
    a, t = artifact('APNTsCapped'), artifact('TimelockController')
    init_t = t['bytecode']['object'] + cast('abi-encode', 'c(uint256,address[],address[],address)',
                                          172800, '['+SAFE+']', '['+SAFE+']', ZERO)[2:]
    constructor_args = ['AAStar PNTs', 'aPNTs', 10_000_000*10**18, DEPLOYER, SAFE, SAFE]
    init_a = a['bytecode']['object'] + cast('abi-encode', 'c(string,string,uint256,address,address,address)',
                                          *constructor_args)[2:]
    accept = calldata('acceptOwnership()')
    salt = keccak('APNTsCapped-1.0.0/acceptOwnership')
    op = keccak(cast('abi-encode', 'c(address,uint256,bytes,bytes32,bytes32)', token, 0, accept, ZERO32, salt))
    sigs = '0x' + ''.join(x[2:].zfill(64) + '0'*64 + '01' for x in sorted((EXECUTOR, APPROVER)))
    inner = [calldata('schedule(address,uint256,bytes,bytes32,bytes32,uint256)', token, 0, accept, ZERO32, salt, 172800),
             calldata('execute(address,uint256,bytes,bytes32,bytes32)', token, 0, accept, ZERO32, salt)]
    hashes = []
    # Safe 1.4.1 EIP-712, independently derived from its current nonce.
    domain = keccak(cast('abi-encode', 'c(bytes32,uint256,address)',
                        keccak('EIP712Domain(uint256 chainId,address verifyingContract)'), CHAIN, SAFE))
    typehash = keccak('SafeTx(address to,uint256 value,bytes data,uint8 operation,uint256 safeTxGas,uint256 baseGas,uint256 gasPrice,address gasToken,address refundReceiver,uint256 nonce)')
    for i, data in enumerate(inner):
        h = keccak(cast('abi-encode', 'c(bytes32,address,uint256,bytes32,uint8,uint256,uint256,uint256,address,address,uint256)',
                       typehash, tl, 0, keccak(data), 0, 0, 0, 0, ZERO, ZERO, state['safeNonce']+i))
        hashes.append(keccak('0x1901'+domain[2:]+h[2:]))
    rows = [('S1', DEPLOYER, SP, calldata('cancelAPNTsTokenChange()')),
            ('S2', DEPLOYER, None, init_t), ('S3', DEPLOYER, None, init_a),
            ('S4', DEPLOYER, token, calldata('transferOwnership(address)', tl))]
    for i in range(2):
        rows += [('S'+str(5+i)+'a', APPROVER, SAFE, calldata('approveHash(bytes32)', hashes[i])),
                 ('S'+str(5+i)+'b', EXECUTOR, SAFE,
                  calldata('execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)',
                           tl, 0, inner[i], 0, 0, 0, 0, ZERO, ZERO, sigs))]
    rows += [('S7', DEPLOYER, SP, calldata('setAPNTsToken(address)', token))]
    counters = {v['address']: v['nonce'] for v in state['senders'].values()}
    steps = []
    for sid, sender, to, data in rows:
        steps.append(dict(id=sid, tx=dict(to=to, data=data, value='0x0', nonce=hex(counters[sender]),
                     **{'from': sender}, chainId=hex(CHAIN), maxFeePerGas=hex(MAX_FEE),
                     maxPriorityFeePerGas=hex(PRIORITY))))
        counters[sender] += 1
    return dict(schema=2, chainId=CHAIN, pin=state, operationId=op, salt=salt, safeTxHashes=hashes,
                runtimeIdentity=a['runtimeIdentity'], constructorArgs=constructor_args,
                # No external admin; OZ retains the timelock's self-admin role.
                roles={'DEFAULT_ADMIN': [tl], 'PROPOSER': [SAFE], 'EXECUTOR': [SAFE], 'CANCELLER': [SAFE]},
                margin=[MARGIN_NUM, MARGIN_DEN], safeInnerData=inner, steps=steps)


class RelayFilter:
    def __init__(self, remote, pin, log):
        self.remote, self.pin, self.log = remote, pin, log

    def one(self, q):
        if not isinstance(q, dict):
            self.log.write('refused malformed\n')
            return dict(jsonrpc='2.0', id=None, error=dict(code=-32600, message='invalid request'))
        m = q.get('method')
        extras = {'eth_blockNumber': self.pin['block'], 'net_version': str(CHAIN),
                  'web3_clientVersion': 'a3a-relay'}
        if (m not in extras and not (isinstance(m, str) and m.startswith('eth_get')) and
                m not in ('eth_chainId', 'eth_call', 'eth_estimateGas')):
            # Log only recognized method names; arbitrary request strings can contain secrets.
            name = m if isinstance(m, str) and m.replace('_', '').isalnum() else 'malformed'
            self.log.write('refused '+name+'\n')
            return dict(jsonrpc='2.0', id=q.get('id'), error=dict(code=-32601, message='relay: method refused'))
        try:
            result = extras[m] if m in extras else self.remote(m, q.get('params', []))
            return dict(jsonrpc='2.0', id=q.get('id'), result=result)
        except Exception:
            self.log.write('failed '+str(m)+'\n')
            return dict(jsonrpc='2.0', id=q.get('id'), error=dict(code=-32000, message='relay: upstream failed'))

    def dispatch(self, q):
        return [self.one(x) for x in q] if isinstance(q, list) else self.one(q)


def relay_evidence(out):
    lines = (out/'relay.log').read_text().splitlines()
    need('relay_evidence', all(x == 'refused eth_gasPrice' for x in lines), True)


def git_state(out):
    # Exclude exactly the task output; all other tracked and untracked changes fail.
    resolved = out.resolve()
    excludes = []
    if resolved.is_relative_to(ROOT):
        relative = resolved.relative_to(ROOT).as_posix()
        need('output_repo_root', relative == '.', False)
        excludes = [':(exclude,literal)'+relative]
    r = subprocess.run(['git', 'status', '--porcelain', '--untracked-files=all', '--', '.', *excludes],
                       cwd=ROOT, capture_output=True, text=True)
    need('git_status', r.returncode, 0)
    need('git_clean', r.stdout, '')
    return dict(dirtyCount=0, excludedOutput=str(resolved) if excludes else None,
                gitPolicy='exclude exactly output path; require all other status empty')


def authenticate_engine(local):
    version = local('web3_clientVersion', [])
    need('local_engine_commit', isinstance(version, str) and COMMIT in version, True)
    need('local_chain', qty(local('eth_chainId', [])), CHAIN)
    config = local('eth_config', [])
    if not isinstance(config, dict) or not isinstance(config.get('current'), dict):
        raise Gate('local_fork_config', 'missing current', 'Amsterdam')
    need('local_fork_activation', config['current'].get('activationTime'), ACTIVATION)
    need('local_fork_id', config['current'].get('forkId'), FORK_ID)
    need('local_fork_next', config.get('next', 'missing'), None)


@contextlib.contextmanager
def fork(remote, pin, out):
    """Archive credentials stay in memory; authenticate the reused local port."""
    class Relay(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_POST(self):
            try:
                q = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                body = json.dumps(filter_rpc.dispatch(q)).encode()
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(body)
            except Exception:
                relay_log.write('failed handler\n')
                self.send_error(502, 'archive relay failed')
    clean = git_state(out)
    relay_log = open(out/'relay.log', 'w', buffering=1)
    filter_rpc = RelayFilter(remote, pin, relay_log)
    version = subprocess.run([str(ENGINE/'anvil'), '--version'], capture_output=True, text=True).stdout
    need('engine_commit', COMMIT in version, True)
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Relay)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        port = s.getsockname()[1]
    head = subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=ROOT, capture_output=True, text=True).stdout.strip()
    header = dict(engine=version.strip(), engineCommit=COMMIT, repoCommit=head, **clean,
                  pinnedBlock=pin['block'], rpc='REDACTED')
    (out/'simulate.log').write_text(json.dumps(header)+'\n')
    proc = None
    # Engine stderr is evidence on failure; it only ever sees the local relay URL, never the archive URL.
    engine_err = open(out/'engine.stderr', 'w')
    try:
        proc = subprocess.Popen([str(ENGINE/'anvil'), '--hardfork', 'amsterdam', '--order', 'fifo',
                                 '--accounts', '0', '--host', '127.0.0.1', '--port', str(port),
                                 '--fork-url', 'http://127.0.0.1:'+str(server.server_port),
                                 '--fork-block-number', str(int(pin['block'], 16)),
                                 '--chain-id', str(CHAIN), '--no-fork-node-info', '--no-bal', '--steps-tracing', '--no-storage-caching', '--silent'],
                                stdout=subprocess.DEVNULL, stderr=engine_err)
        local = RPC('http://127.0.0.1:'+str(port), local=True)
        for _ in range(100):
            if proc.poll() is not None:
                raise Gate('engine_start', 'anvil exited', 'Amsterdam engine running')
            try:
                local('eth_chainId', [])
                break
            except Gate:
                time.sleep(.1)
        else:
            raise Gate('engine_start', 'timeout', 'listening local anvil')
        authenticate_engine(local)
        need('fork_block_hash', block_data(local, pin['block'])['hash'], pin['blockHash'])
        for who in (DEPLOYER, EXECUTOR, APPROVER):
            local('anvil_impersonateAccount', [who])
        yield local
    finally:
        if proc is not None:
            proc.terminate()
            proc.wait(timeout=10)
        server.shutdown()
        server.server_close()
        engine_err.close()
        relay_log.close()


def tx_rpc(tx):
    return {k: v for k, v in tx.items() if v is not None}


def receipt(rpc, tx, status='0x1'):
    h = typed(rpc('eth_sendTransaction', [tx_rpc(tx)]), HASH32)
    for _ in range(100):
        r = rpc('eth_getTransactionReceipt', [h])
        if r is not None:
            need('receipt_status', r.get('status'), status)
            qty(r['gasUsed'])
            return r
        time.sleep(.05)
    raise Gate('receipt_timeout', h, 'mined receipt')


def negative(rpc, tx, expected, name):
    sender = tx['from']
    before = [nonce(rpc, sender), word(rpc, SAFE, 'nonce()')]
    snap = rpc('evm_snapshot', [])
    try:
        bad = dict(tx, nonce=hex(before[0]), gas=tx.get('gas', hex(30_000_000)))
        r = receipt(rpc, bad, status='0x0')
        trace = rpc('debug_traceTransaction', [r['transactionHash'], {'tracer': 'callTracer'}])
        need('negative_'+name+'_reason', trace.get('output'), expected)
        # A mined reverted EOA transaction necessarily consumes one nonce. The Safe nonce must not move.
        need('negative_'+name+'_mined_nonces', [nonce(rpc, sender), word(rpc, SAFE, 'nonce()')],
             [before[0]+1, before[1]])
    finally:
        need('negative_'+name+'_restore', rpc('evm_revert', [snap]), True)
    need('negative_'+name+'_restored_nonces', [nonce(rpc, sender), word(rpc, SAFE, 'nonce()')], before)
    return dict(control=name, kind='reverted_transaction', revert=expected, receipt=r,
                beforeNonces=before, minedNonces=[before[0]+1, before[1]], restoredNonces=before)


def error_string(s):
    return '0x08c379a0'+cast('abi-encode', 'c(string)', s)[2:]


def roles_readback(rpc, plan, start):
    tl = plan['pin']['timelock']
    need('role_history_start', rpc('eth_getCode', [tl, hex(int(start, 16)-1)]), '0x')
    granted, revoked = keccak('RoleGranted(bytes32,address,address)'), keccak('RoleRevoked(bytes32,address,address)')
    admin_changed = keccak('RoleAdminChanged(bytes32,bytes32,bytes32)')
    logs = rpc('eth_getLogs', [dict(address=tl, fromBlock=start, toBlock='latest', topics=[[granted, revoked, admin_changed]])])
    members = {ZERO32: set(), **{keccak(x+'_ROLE'): set() for x in ('PROPOSER', 'EXECUTOR', 'CANCELLER')}}
    admins = {role: ZERO32 for role in members}
    if not isinstance(logs, list) or not logs:
        raise Gate('role_logs', 'empty/malformed', 'complete role event history')
    for log in sorted(logs, key=lambda x: (qty(x['blockNumber']), qty(x['transactionIndex']), qty(x['logIndex']))):
        need('role_emitter', log['address'].lower(), tl)
        need('role_log_removed', log.get('removed', False), False)
        topics = log['topics']
        need('role_topics', len(topics), 4)
        need('role_event_topic', topics[0] in (granted, revoked, admin_changed), True)
        role, account = typed(topics[1], HASH32), '0x'+typed(topics[2], HASH32)[-40:].lower()
        if role not in members:
            raise Gate('role_unknown', role, list(members))
        if topics[0] == admin_changed:
            need('role_previous_admin', topics[2], admins[role])
            admins[role] = typed(topics[3], HASH32)
            continue
        if topics[0] == granted:
            members[role].add(account)
        else:
            members[role].discard(account)
    observed = {'DEFAULT_ADMIN': sorted(members[ZERO32])}
    observed.update({x: sorted(members[keccak(x+'_ROLE')]) for x in ('PROPOSER', 'EXECUTOR', 'CANCELLER')})
    need('timelock_role_admins', admins, {role: ZERO32 for role in members})
    for role in members:
        need('timelock_live_role_admin', word(rpc, tl, 'getRoleAdmin(bytes32)', role), int(admins[role], 16))
    need('timelock_role_sets', observed, plan['roles'])
    return observed


def readback(rpc, plan, step, r, context, predecessor=False):
    pin, sid = plan['pin'], step['id']
    tl, token = pin['timelock'], pin['capped']
    ts = qty(block_data(rpc, r['blockNumber'])['timestamp'])
    got = dict(timestamp=ts)
    need(sid+'_apnts_unchanged', address(rpc, SP, 'APNTS_TOKEN()'), pin['sp']['APNTS_TOKEN'])
    if sid in ('S2', 'S3') and not predecessor:
        need(sid+'_created_address', r.get('contractAddress', '').lower(), tl if sid == 'S2' else token)
    if sid != 'S7':
        need(sid+'_sp_pending_cleared', address(rpc, SP, 'pendingAPNTsToken()'), ZERO)
        need(sid+'_sp_eta_cleared', word(rpc, SP, 'pendingAPNTsTokenEta()'), 0)
    if sid == 'S1':
        need('S1_pending', address(rpc, SP, 'pendingAPNTsToken()'), ZERO)
        need('S1_eta', word(rpc, SP, 'pendingAPNTsTokenEta()'), 0)
    if sid == 'S2' and not predecessor:
        context['tlBlock'] = r['blockNumber']
    if 'tlBlock' in context:
        need(sid+'_min_delay', word(rpc, tl, 'getMinDelay()'), 172800)
        got['roles'] = roles_readback(rpc, plan, context['tlBlock'])
    if sid not in ('S1', 'S2'):
        got['runtimeIdentity'] = verify_runtime(rpc, plan, rpc('eth_getCode', [token, 'latest']))
        for sig, expected in [('cap()', 10_000_000*10**18), ('totalSupply()', 0)]:
            need(sid+'_'+sig, word(rpc, token, sig), expected)
        for sig, expected in [('minter()', SAFE), ('capGuardian()', SAFE)]:
            need(sid+'_'+sig, address(rpc, token, sig), expected)
        owned = tl if sid in ('S6b', 'S7') else DEPLOYER
        need(sid+'_owner', address(rpc, token, 'owner()'), owned)
        pending = tl if sid in ('S4', 'S5a', 'S5b', 'S6a') else ZERO
        need(sid+'_pending_owner', address(rpc, token, 'pendingOwner()'), pending)
    if sid in ('S5b', 'S6b') and not predecessor:
        expected_hash = plan['safeTxHashes'][0 if sid == 'S5b' else 1]
        success = keccak('ExecutionSuccess(bytes32,uint256)')
        need(sid+'_safe_execution_success', any(
            l['address'].lower() == SAFE and l['topics'] and l['topics'][0] == success and
            ((len(l['topics']) > 1 and l['topics'][1] == expected_hash) or
             l['data'][2:66] == expected_hash[2:]) for l in r['logs']), True)
    if sid in ('S5a', 'S6a'):
        i = 0 if sid == 'S5a' else 1
        need(sid+'_approved_hash', word(rpc, SAFE, 'approvedHashes(address,bytes32)', APPROVER, plan['safeTxHashes'][i]), 1)
    if sid == 'S5b' and not predecessor:
        context['eta'] = ts + 172800
        if 'plannedETA' not in step:
            step['plannedETA'] = context['eta']
        need('S5b_planned_eta', context['eta'], step['plannedETA'])
    if sid in ('S5b', 'S6a', 'S6b', 'S7'):
        done = sid in ('S6b', 'S7')
        need(sid+'_operation_state', word(rpc, tl, 'getOperationState(bytes32)', plan['operationId']), 3 if done else (2 if predecessor and qty(block_data(rpc, 'latest')['timestamp']) >= context['eta'] else 1))
        need(sid+'_operation_eta', word(rpc, tl, 'getTimestamp(bytes32)', plan['operationId']), 1 if done else context['eta'])
        got['operationETA'] = context['eta']
    if sid == 'S7':
        delay = word(rpc, SP, 'APNTS_TOKEN_TIMELOCK()')
        need('S7_delay', delay, pin['sp']['APNTS_TOKEN_TIMELOCK'])
        need('S7_pending_token', address(rpc, SP, 'pendingAPNTsToken()'), token)
        need('S7_eta_relation', word(rpc, SP, 'pendingAPNTsTokenEta()'), ts+delay)
        got['spDelay'] = delay
    return got


def trace_overrides(rpc, r, overrides):
    """Cumulative stateDiff preserves untouched archive storage; cleared slots become zero."""
    diff = rpc('debug_traceTransaction', [r['transactionHash'], dict(tracer='prestateTracer', tracerConfig={'diffMode': True})])
    if not isinstance(diff, dict) or not all(isinstance(diff.get(k), dict) for k in ('pre', 'post')):
        raise Gate('state_diff', 'unsupported trace shape', 'prestateTracer diffMode pre/post')
    for addr in diff['pre'].keys() | diff['post'].keys():
        pre, post = diff['pre'].get(addr, {}), diff['post'].get(addr, {})
        target = overrides.setdefault(addr, {})
        for field in ('balance', 'nonce', 'code'):
            if field in post:
                target[field] = hex(post[field]) if type(post[field]) is int else post[field]
        slots = target.setdefault('stateDiff', {})
        for key in pre.get('storage', {}).keys() | post.get('storage', {}).keys():
            slots[key] = post.get('storage', {}).get(key, ZERO32)
    return overrides


@dataclass(frozen=True)
class ExecutionStep:
    plan: dict
    id: str


def validate_plan(plan, frozen=False):
    need('plan_step_ids', [s['id'] for s in plan['steps']], list(STEP_IDS))
    rebuilt = build_plan(plan['pin'])
    for key in ('schema', 'chainId', 'runtimeIdentity', 'constructorArgs', 'roles', 'safeTxHashes',
                'safeInnerData', 'operationId', 'salt', 'margin'):
        need('plan_identity_'+key, plan[key], rebuilt[key])
    for step, expected in zip(plan['steps'], rebuilt['steps']):
        if frozen:
            for key in ('estimateGas', 'localEstimateGas', 'forkGasUsed', 'executionTimestamp'):
                value = step.get(key)
                need('plan_frozen_'+step['id']+'_'+key, type(value) is int and value > 0, True)
            typed(step['tx'].get('gas'), QTY, 'plan_frozen_'+step['id']+'_gas')
            if step['id'] == 'S5b':
                need('plan_frozen_eta', step.get('plannedETA'), step['executionTimestamp']+172800)
        for key in ('to', 'data', 'from', 'value', 'nonce', 'chainId', 'maxFeePerGas', 'maxPriorityFeePerGas'):
            need('plan_step_'+step['id']+'_'+key, step['tx'].get(key), expected['tx'][key])
        if 'gas' in step['tx']:
            limit = (max(step['estimateGas'], step['localEstimateGas'], step['forkGasUsed'])*MARGIN_NUM+MARGIN_DEN-1)//MARGIN_DEN
            need('plan_gas_'+step['id'], qty(step['tx']['gas']), limit)


def safe_hash_check(remote, plan):
    for i, data in enumerate(plan['safeInnerData']):
        actual = call(remote, SAFE,
                      'getTransactionHash(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,uint256)',
                      plan['pin']['timelock'], 0, data, 0, 0, 0, 0, ZERO, ZERO,
                      plan['pin']['safeNonce']+i, block=plan['pin']['block'])
        need('safe_hash_'+str(i+5), actual.lower(), plan['safeTxHashes'][i])


def pre_send(step, remote):
    """The sole transaction preparation boundary, including for any future signer.

    Every predicate is re-read from chain; no completed-step process state is trusted.
    """
    plan, sid = step.plan, step.id
    index = STEP_IDS.index(sid)
    tx = copy.deepcopy(plan['steps'][index]['tx'])
    need('pre_send_chain', qty(remote('eth_chainId', [])), CHAIN)
    dependencies = [SAFE, SP] + ([tx['to']] if tx['to'] else [])
    if index >= 2:
        dependencies.append(plan['pin']['timelock'])
    if index >= 3:
        dependencies.append(plan['pin']['capped'])
    for target in set(dependencies):
        if typed(remote('eth_getCode', [target, 'latest']), HEXDATA) == '0x':
            raise Gate('pre_send_code_'+sid, target, 'deployed contract code')
    latest = nonce(remote, tx['from'], 'latest')
    need('pre_send_pending_'+sid, nonce(remote, tx['from'], 'pending'), latest)
    need('pre_send_nonce_'+sid, latest, qty(tx['nonce']))
    safe_expected = plan['pin']['safeNonce'] + int(index > 5) + int(index > 7)
    need('pre_send_safe_nonce_'+sid, word(remote, SAFE, 'nonce()'), safe_expected)
    if index:
        prior = plan['steps'][index-1]
        context = {}
        if index >= 2:
            context['tlBlock'] = hex(int(plan['pin']['block'], 16)+1)
        if index >= 6:
            context['eta'] = plan['steps'][5]['plannedETA']
        readback(remote, plan, prior, {'blockNumber': 'latest'}, context, predecessor=True)
    else:
        for key in ('owner', 'APNTS_TOKEN', 'pendingAPNTsToken'):
            need('pre_send_initial_'+key, address(remote, SP, key+'()'), plan['pin']['sp'][key])
        need('pre_send_initial_eta', word(remote, SP, 'pendingAPNTsTokenEta()'), plan['pin']['sp']['pendingAPNTsTokenEta'])
    # A real send must re-estimate at current state, even for a previously reviewed frozen plan.
    probe = {k: v for k, v in tx_rpc(tx).items() if k != 'gas'}
    fresh = qty(remote('eth_estimateGas', [probe, 'latest']))
    if 'gas' in tx:
        need('pre_send_gas_'+sid, fresh <= qty(tx['gas']), True)
    return tx


def signing_transaction(plan, sid, remote):
    """Future signer input must come through this boundary; no signing is implemented."""
    validate_plan(plan, frozen=True)
    return pre_send(ExecutionStep(plan, sid), remote)


def completion(records, controls):
    need('completed_steps', [r['step'] for r in records], list(STEP_IDS))
    need('completed_controls', [c['control'] for c in controls], list(CONTROL_IDS))


def rehearse(remote, plan, out, calibrate=False):
    records, controls, context, overrides = [], [], {}, {}
    pin = plan['pin']
    validate_plan(plan, frozen=not calibrate)
    frozen_plan = copy.deepcopy(plan) if not calibrate else None
    with fork(remote, pin, out) as local:
        expected_safe = pin['safeNonce']
        for step in plan['steps']:
            sid = step['id']
            tx = copy.deepcopy(step['tx'])
            if sid == 'S6b':
                controls.append(negative(local, tx, error_string('GS013'), 'early_execute'))
                local('evm_setNextBlockTimestamp', [context['eta']])
                local('evm_mine', [])
            need(sid+'_sender_nonce', nonce(local, tx['from']), qty(tx['nonce']))
            need(sid+'_safe_nonce', word(local, SAFE, 'nonce()'), expected_safe)
            if sid == 'S3':
                before = [nonce(local, DEPLOYER), word(local, SAFE, 'nonce()')]
                try:
                    pre_send(ExecutionStep(plan, 'S4'), local)
                except Gate as e:
                    need('negative_order_reason', e.record['gate'], 'pre_send_code_S4')
                else:
                    raise Gate('negative_order_reason', 'accepted', 'pre_send_code_S4')
                need('negative_order_nonces', [nonce(local, DEPLOYER), word(local, SAFE, 'nonce()')], before)
                controls.append(dict(control='S4_before_S3', kind='executor_refusal',
                                     gate='pre_send_code_S4', nonces=before))
            if sid == 'S4':
                require_deployed(local, pin['capped'])
            if sid == 'S5b':
                snap = local('evm_snapshot', [])
                local('anvil_setStorageAt', [SAFE, '0x'+'00'*31+'05', '0x'+f'{expected_safe+1:064x}'])
                try:
                    need('wrong_safe_nonce_setup', word(local, SAFE, 'nonce()'), expected_safe+1)
                    controls.append(negative(local, tx, error_string('GS025'), 'wrong_safe_nonce'))
                finally:
                    need('negative_snapshot_restore', local('evm_revert', [snap]), True)
            if sid == 'S7':
                bad = dict(tx, **{'from': EXECUTOR})
                bad.pop('nonce', None)
                reason = calldata('OwnableUnauthorizedAccount(address)', EXECUTOR)
                controls.append(negative(local, bad, reason, 'non_owner_queue'))
            tx = pre_send(ExecutionStep(plan, sid), local)
            execution_ts = max(qty(block_data(local, 'latest')['timestamp'])+1,
                               context.get('eta', 0) if sid in ('S6b', 'S7') else 0)
            if calibrate:
                step['executionTimestamp'] = execution_ts
            need(sid+'_execution_timestamp', execution_ts, step['executionTimestamp'])
            local('evm_setNextBlockTimestamp', [execution_ts])
            if calibrate:
                timestamp = execution_ts
                # Estimate at the archive pin with this rehearsal's explicit state and time.
                params = [tx_rpc(tx), pin['block'], overrides, {'time': hex(timestamp)}]
                # Providers lacking state/block override support fail, never fall back to latest.
                est = qty(remote('eth_estimateGas', params))
                local_est = qty(local('eth_estimateGas', [tx_rpc(tx), 'latest']))
                tx['gas'] = hex((max(est, local_est)*MARGIN_NUM+MARGIN_DEN-1)//MARGIN_DEN)
                step['estimateGas'] = est
                step['localEstimateGas'] = local_est
                step['estimateContext'] = dict(block=pin['block'], stateOverrides=json.loads(json.dumps(overrides)),
                                               blockOverrides={'time': hex(timestamp)})
                # Pilot execution supplies gasUsed, then roll back and rerun at the final exact limit.
                snap = local('evm_snapshot', [])
                pilot = receipt(local, tx)
                used = qty(pilot['gasUsed'])
                need('pilot_restore', local('evm_revert', [snap]), True)
                local('evm_setNextBlockTimestamp', [execution_ts])
                tx['gas'] = hex((max(est, local_est, used)*MARGIN_NUM+MARGIN_DEN-1)//MARGIN_DEN)
                step['forkGasUsed'] = used
            step['tx'] = tx
            r = receipt(local, tx)
            need(sid+'_post_sender_nonce', nonce(local, tx['from']), qty(tx['nonce'])+1)
            expected_safe += int(sid in ('S5b', 'S6b'))
            need(sid+'_post_safe_nonce', word(local, SAFE, 'nonce()'), expected_safe)
            if calibrate:
                need(sid+'_gas_crosscheck', qty(r['gasUsed']), step['forkGasUsed'])
            need(sid+'_mined_timestamp', qty(block_data(local, r['blockNumber'])['timestamp']),
                 step['executionTimestamp'])
            observed = readback(local, plan, step, r, context)
            need(sid+'_gas_limit', qty(r['gasUsed']) <= qty(tx['gas']), True)
            mined = local('eth_getTransactionByHash', [r['transactionHash']])
            for key in ('from', 'to', 'nonce', 'value', 'chainId'):
                need(sid+'_mined_'+key, mined.get(key), tx.get(key))
            need(sid+'_mined_data', mined.get('input'), tx['data'])
            need(sid+'_mined_gas', mined.get('gas'), tx['gas'])
            records.append(dict(step=sid, gasUsed=qty(r['gasUsed']), receipt=r, readback=observed))
            with (out/'simulate.log').open('a') as log:
                log.write(json.dumps(records[-1])+'\n')
            write_json(out/'simulate.json', dict(status='IN_PROGRESS', steps=records, negativeControls=controls))
            if calibrate:
                trace_overrides(local, r, overrides)
    completion(records, controls)
    relay_evidence(out)
    validate_plan(plan, frozen=True)
    if calibrate:
        budget(plan)
    else:
        need('frozen_plan_unchanged', plan, frozen_plan)
        checked = copy.deepcopy(plan)
        budget(checked)
        need('frozen_budgets', checked['budgetsWei'], plan['budgetsWei'])
    result = dict(status='PASS', pinnedBlock=pin['block'], steps=records, negativeControls=controls)
    write_json(out/'simulate.json', result)
    return result


def require_deployed(rpc, token):
    if typed(rpc('eth_getCode', [token, 'latest']), HEXDATA) == '0x':
        raise Gate('S4_requires_S3', 'empty code', 'S3 deployment completed')


def write_json(path, data):
    path.write_text(json.dumps(data, indent=2, sort_keys=True)+'\n')


def budget(plan):
    budgets = {}
    for label, who in SENDERS.items():
        total = sum(qty(s['tx']['gas'])*qty(s['tx']['maxFeePerGas'])
                    for s in plan['steps'] if s['tx']['from'] == who)
        balance = plan['pin']['senders'][label]['balance']
        if balance < total:
            raise Gate(label+'_budget', balance, {'minimumWei': total})
        budgets[label] = total
    plan['budgetsWei'] = budgets
    plan['budgetWei'] = budgets['deployer']


def plan_command(remote, block, out):
    state = preflight(remote, block)
    check_keccak(remote)
    # Early conservative gate before starting an engine; final budget uses measured limits.
    if state['balance'] < 21_000*5*MAX_FEE:
        raise Gate('deployer_budget', state['balance'], {'minimumWei': 21_000*5*MAX_FEE})
    plan = build_plan(state)
    safe_hash_check(remote, plan)
    rehearse(remote, plan, out, calibrate=True)
    budget(plan)
    # Recheck archive identity and live pending nonce after the rehearsal.
    need('pin_recheck', preflight(remote, block), state)
    write_json(out/'plan.json', plan)
    digest = hashlib.sha256((out/'plan.json').read_bytes()).hexdigest()
    (out/'plan.json.sha256').write_text(digest+'  plan.json\n')
    return plan


def load_plan(path):
    raw = path.read_bytes()
    expected = path.with_name(path.name+'.sha256').read_text().split()[0]
    need('plan_hash', hashlib.sha256(raw).hexdigest(), expected)
    return json.loads(raw)


def failure_record(out, record):
    if out is None:
        return
    try:
        out.mkdir(parents=True, exist_ok=True)
        write_json(out/'FAILURE.json', record)
    except OSError:
        # If --out itself is unwritable, retain machine-readable failure evidence on stderr.
        print(json.dumps(record), file=sys.stderr)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    for name in ('plan', 'simulate'):
        p = sub.add_parser(name)
        p.add_argument('--rpc-file', type=Path, required=True)
        p.add_argument('--out', type=Path, required=True)
        if name == 'plan':
            p.add_argument('--block', required=True, type=lambda s: hex(int(s, 0) if s.startswith('0x') else int(s)))
        else:
            p.add_argument('--plan', type=Path, required=True)
    for name in ('sign', 'send'):
        p = sub.add_parser(name)
        p.add_argument('--out', type=Path, default=None)  # refusal is recorded on disk only when asked
    args = parser.parse_args(argv)
    try:
        if args.out is not None:
            args.out.mkdir(parents=True, exist_ok=True)
        if args.command in ('sign', 'send'):
            raise Gate('sign_disabled' if args.command == 'sign' else 'send_disabled', REFUSAL, 'separate authorization and implemented reviewed signer')
        plan = load_plan(args.plan) if args.command == 'simulate' else None
        remote = RPC(args.rpc_file.read_text().strip())
        if plan is None:
            plan_command(remote, args.block, args.out)
        else:
            validate_plan(plan, frozen=True)
            safe_hash_check(remote, plan)
            need('simulation_pin', preflight(remote, plan['pin']['block']), plan['pin'])
            frozen = copy.deepcopy(plan)
            rehearse(remote, plan, args.out)
            need('frozen_plan_unchanged', plan, frozen)
        if args.out is not None:
            (args.out/'FAILURE.json').unlink(missing_ok=True)
        return 0
    except Gate as e:
        if args.out is not None:
            failure_record(args.out, e.record)
        print(REFUSAL if args.command in ('sign', 'send') else 'STOP: '+e.record['gate'], file=sys.stderr)
        return 3 if args.command in ('sign', 'send') else 1
    except Exception as e:
        if args.out is not None:
            failure_record(args.out, dict(status='FAILURE', gate='executor_error', observed=type(e).__name__, expected='successful gated execution; RPC redacted'))
        print('STOP: executor_error ('+type(e).__name__+')', file=sys.stderr)
        return 1
    except BaseException as e:
        failure_record(args.out, dict(status='FAILURE', gate='interrupted', observed=type(e).__name__, expected='uninterrupted execution'))
        print('STOP: interrupted', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
