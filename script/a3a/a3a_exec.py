#!/usr/bin/env python3
"""Unsigned A3a planning and isolated Amsterdam rehearsal. No signing implementation."""
import sys
# The git-clean gate would otherwise fail on the __pycache__ this very import creates.
sys.dont_write_bytecode = True
import argparse
import contextlib
import copy
from dataclasses import dataclass
import hashlib
from functools import lru_cache
import http.server
import json
import os
import tarfile
import tempfile
import tomllib
from pathlib import Path
import socket
import shutil
import subprocess
import sys
import threading
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'script/evidence/lib'))
from rpc_strict import HEXDATA, QTY, HASH32, classify
import re
ADDRESS_RX = re.compile(r"0x[0-9a-fA-F]{40}", re.ASCII)

# Engine root is configurable (A3A_ENGINE_DIR); the binary is still verified against COMMIT before use.
# Pinned to nightly 4e8874b: it keeps the EIP-8037 state-gas reservoir (foundry #17719). 926eb1d does not (uncapped frame
# gas, stateGasReservoir 0) and matched real RR txs on receipt gasUsed only — 0/10 at frame level vs 10/10 here.
ENGINE = Path(os.environ.get('A3A_ENGINE_DIR', '/Users/jason/Dev/aastar/tools/foundry-rams/nightly-4e8874b'))
COMMIT = '4e8874b2bdc840929585ca73e170993c50a4a531'
PACKET = ROOT / 'docs/release/a3a-precheck-v4/a3a-precheck.json'
CHAIN = 11155111
ACTIVATION = 1791294816
FORK_ID = '0x6c1d9423'
MARGIN_NUM, MARGIN_DEN = 13, 10
GAS_CAP = 2**24
REBUILD_FORGE = Path.home()/'.foundry/bin/forge'
CONTRACT_NAMES = ('APNTsCapped', 'TimelockController')
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


def same_value(observed, expected):
    # JSON booleans/floats must not alias canonical integer fields (True == 1 in Python).
    if type(observed) is not type(expected):
        return False
    if isinstance(expected, dict):
        return observed.keys() == expected.keys() and all(same_value(observed[k], v) for k, v in expected.items())
    if isinstance(expected, (list, tuple)):
        return len(observed) == len(expected) and all(same_value(a, b) for a, b in zip(observed, expected))
    return observed == expected


def need(name, observed, expected):
    if not same_value(observed, expected):
        raise Gate(name, observed, expected)


def typed(value, rx, gate='rpc_result'):
    if not isinstance(value, str) or not rx.fullmatch(value):
        raise Gate(gate, 'malformed typed result', rx.pattern)
    return value


def qty(value):
    number = int(typed(value, QTY), 16)
    need('canonical_quantity', value, hex(number))
    return number


class RPC:
    def __init__(self, url, local=False):
        self.url, self.local, self.serial = url, local, 0
        self.serial_lock = threading.Lock()

    def _post_with_deadline(self, q):
        box = {}
        def work():
            try:
                with urllib.request.urlopen(urllib.request.Request(
                        self.url, json.dumps(q).encode(), {'Content-Type': 'application/json'}), timeout=45) as r:
                    box['body'] = r.read()
            except Exception as e:
                box['error'] = e
        worker = threading.Thread(target=work, daemon=True)
        worker.start()
        worker.join(RPC_TOTAL_DEADLINE_SECONDS)
        if worker.is_alive():
            raise TimeoutError('total RPC deadline exceeded')
        if 'error' in box:
            raise box['error']
        return json.loads(box['body'])

    def __call__(self, method, params, error_ok=False):
        if not self.local and not (method.startswith('eth_get') or method in
                                  ('eth_chainId', 'eth_config', 'eth_call', 'eth_estimateGas', 'web3_sha3')):
            raise Gate('remote_read_only', method, 'read-only RPC')
        with self.serial_lock:
            self.serial += 1
            rid = self.serial
        q = dict(jsonrpc='2.0', id=rid, method=method, params=params)
        try:
            # timeout=45 bounds each socket operation only; a server that trickles bytes (in headers, chunk framing
            # or body) can hold a request open indefinitely (observed 2026-10-24: one archive request hung > 8 min),
            # and DNS has no timeout at all. So the whole request (resolve, connect, headers, body) runs in a daemon
            # thread and the caller stops waiting after RPC_TOTAL_DEADLINE_SECONDS wall-clock. An abandoned thread
            # may linger until its socket closes; nothing reads its result (the only caller that retries on Gate is
            # the local engine-start probe, whose attempts end at once on connection refused).
            d = self._post_with_deadline(q)
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


def _rlp_bytes(b):
    if len(b) == 1 and b[0] < 0x80:
        return b
    if len(b) <= 55:
        return bytes([0x80 + len(b)]) + b
    n = len(b).to_bytes((len(b).bit_length() + 7) // 8, 'big')
    return bytes([0xb7 + len(n)]) + n + b


def create_address(sender, nonce):
    """CREATE address = keccak256(rlp([sender, nonce]))[12:], derived here rather than parsed from
    `cast compute-address --json`, whose output shape differs between foundry 1.7.1 and the nightly."""
    if type(nonce) is not int or nonce < 0:
        raise Gate('create_nonce', nonce, 'non-negative int')
    s = bytes.fromhex(typed(sender, ADDRESS_RX, 'create_sender')[2:])
    body = _rlp_bytes(s) + _rlp_bytes(nonce.to_bytes((nonce.bit_length() + 7) // 8, 'big') if nonce else b'')
    if len(body) > 55:
        raise Gate('create_rlp', len(body), 'short list')
    return '0x' + keccak('0x' + (bytes([0xc0 + len(body)]) + body).hex())[-40:]


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


def immutable_identity(a, build_info=None, contract_name='APNTsCapped', allowed_names=None):
    """Resolve IDs only within compilation units containing this exact runtime/artifact.

    IDs are compilation-local. Never combine AST IDs from unrelated builds.
    Minimal Foundry build-info without output ASTs is insufficient evidence.
    """
    deployed = a['deployedBytecode']
    runtime = typed(deployed['object'], HEXDATA, 'artifact_bytecode').lower()
    refs = deployed.get('immutableReferences', {})
    if not isinstance(refs, dict):
        raise Gate('immutable_references', 'malformed', 'reference id -> ranges')
    allowed = allowed_names if allowed_names is not None else (
        EIP712_IMMUTABLES if contract_name == 'APNTsCapped' else frozenset(('_minDelay',)))
    if not refs and contract_name == 'TimelockController':
        return dict(artifactRuntime=runtime, ranges=[])
    candidates = []
    for path in sorted((build_info or ROOT/'out/build-info').glob('*.json')):
        info = json.loads(path.read_text())
        output = info.get('output', {})
        matching = any(
            contract.get('evm', {}).get('deployedBytecode', {}).get('object', '').removeprefix('0x').lower()
            == runtime[2:] and
            contract.get('evm', {}).get('deployedBytecode', {}).get('immutableReferences', {}) == refs
            for contracts in output.get('contracts', {}).values()
            for name, contract in contracts.items() if name == contract_name)
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
        if name not in allowed:
            raise Gate('immutable_unknown_id', {'id': key, 'name': name}, sorted(allowed))
    if contract_name == 'APNTsCapped':
        need('immutable_named_set', sorted(names.values()), sorted(EIP712_IMMUTABLES))
    else:
        need('immutable_named_unique', len(set(names.values())), len(names))
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


def verify_runtime(rpc, plan, code, contract_name='APNTsCapped', identity=None, values=None):
    identity = identity if identity is not None else plan[
        'runtimeIdentity' if contract_name == 'APNTsCapped' else 'timelockRuntimeIdentity']
    expected = bytearray.fromhex(typed(identity['artifactRuntime'], HEXDATA)[2:])
    actual = bytearray.fromhex(typed(code, HEXDATA)[2:])
    need('runtime_length', len(actual), len(expected))
    if values is not None:
        cases = {}
    elif contract_name == 'APNTsCapped':
        values, cases = immutable_values(rpc, plan)
    else:
        values, cases = {'_minDelay': (172800).to_bytes(32, 'big')}, {}
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
    if contract_name == 'APNTsCapped':
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


def committed_bytes(repo, path, ref='HEAD'):
    """Read bytes from the root commit, following pinned gitlinks (never a child HEAD)."""
    result = subprocess.run(['git', 'show', ref+':'+path], cwd=repo, capture_output=True)
    if result.returncode == 0:
        return result.stdout
    parts = Path(path).parts
    for i in range(1, len(parts)):
        prefix = Path(*parts[:i]).as_posix()
        tree = subprocess.run(['git', 'ls-tree', '-z', ref, '--', prefix], cwd=repo, capture_output=True)
        if tree.returncode == 0 and tree.stdout:
            entry = tree.stdout.split(b'\0')[0].split(b'\t')[0].split()
            if len(entry) == 3 and entry[0] == b'160000':
                return committed_bytes(repo/prefix, Path(*parts[i:]).as_posix(), entry[2].decode('ascii'))
    raise Gate('artifact_source_uncommitted', path, 'file bytes reachable from HEAD (including pinned gitlinks)')


def source_path(source, remappings):
    if not isinstance(source, str) or Path(source).is_absolute():
        raise Gate('artifact_source_unresolved', 'invalid source path', 'repository-relative source')
    choices = [source]
    mappings = []
    for mapping in remappings:
        left, sep, right = mapping.partition('=')
        if not sep:
            raise Gate('artifact_remapping', mapping, 'prefix=repository path')
        prefix = left.rsplit(':', 1)[-1]
        if source.startswith(prefix):
            mappings.append((len(prefix), right+source[len(prefix):]))
    if mappings:
        longest = max(n for n, _ in mappings)
        choices = sorted(set(value for n, value in mappings if n == longest))
        need('artifact_remapping_ambiguous', len(choices), 1)
    resolved = (ROOT/choices[0]).resolve()
    if not resolved.is_relative_to(ROOT) or not resolved.is_file():
        raise Gate('artifact_source_unresolved', source, 'existing source inside repository')
    return resolved.relative_to(ROOT).as_posix()


def artifact_sources(metadata):
    need('artifact_keccak_vector', keccak('0x'), EMPTY_KECCAK)
    sources = metadata.get('sources')
    if not isinstance(sources, dict) or not sources:
        raise Gate('artifact_sources', 'missing sources', 'complete metadata source hashes')
    hashes = {}
    for source, info in sources.items():
        path = source_path(source, metadata['settings'].get('remappings', []))
        committed = committed_bytes(ROOT, path)
        expected = keccak('0x'+committed.hex())
        need('artifact_source_metadata', typed(info.get('keccak256'), HASH32).lower(), expected)
        need('artifact_source_worktree', keccak('0x'+(ROOT/path).read_bytes().hex()), expected)
        hashes[source] = dict(path=path, keccak256=expected)
    return hashes


def reject_duplicate_pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise Gate('duplicate_json_key', key, 'unique object keys')
        result[key] = value
    return result


def plan_json(raw):
    return json.loads(raw, object_pairs_hook=reject_duplicate_pairs)


def cbor_tail(code):
    raw = bytes.fromhex(typed(code, HEXDATA)[2:])
    if len(raw) < 3:
        raise Gate('metadata_cbor', 'short runtime', 'length-delimited CBOR trailer')
    size = int.from_bytes(raw[-2:], 'big')
    if not 0 < size <= len(raw)-2:
        raise Gate('metadata_cbor', 'invalid trailer length', 'CBOR inside runtime')
    data = raw[-size-2:-2]
    def decode(pos, depth=0):
        if depth > 4 or pos >= len(data):
            raise Gate('metadata_cbor', 'truncated/deep CBOR', 'definite map/text/bytes/integer')
        tag = data[pos]; pos += 1
        major, length = tag >> 5, tag & 31
        if length >= 24:
            if length not in (24, 25, 26, 27):
                raise Gate('metadata_cbor', 'indefinite CBOR', 'definite length')
            width = 1 << (length-24)
            if pos+width > len(data):
                raise Gate('metadata_cbor', 'truncated length', 'complete CBOR')
            length = int.from_bytes(data[pos:pos+width], 'big'); pos += width
        if major == 0:
            return length, pos
        if major in (2, 3):
            if pos+length > len(data):
                raise Gate('metadata_cbor', 'truncated value', 'complete CBOR')
            value = data[pos:pos+length]
            return (value.decode('utf-8') if major == 3 else value), pos+length
        if major == 5:
            values = {}
            for _ in range(length):
                key, pos = decode(pos, depth+1)
                if not isinstance(key, str) or key in values:
                    raise Gate('metadata_cbor', 'duplicate/nontext key', 'unique text keys')
                values[key], pos = decode(pos, depth+1)
            return values, pos
        raise Gate('metadata_cbor', major, 'map/text/bytes/unsigned integer')
    decoded, end = decode(0)
    need('metadata_cbor_consumed', end, len(data))
    if not isinstance(decoded, dict):
        raise Gate('metadata_cbor', 'not a map', 'metadata map')
    return decoded


def protobuf_varint(n):
    out = bytearray()
    while n >= 128:
        out.append((n & 127) | 128); n >>= 7
    out.append(n)
    return bytes(out)


def metadata_ipfs_hash(raw):
    # Solidity's default IPFS identifier is SHA-256 of the UnixFS file DAG node,
    # not plain SHA-256 of the JSON bytes. Metadata normally fits in one chunk.
    if len(raw) > 262144:
        raise Gate('metadata_ipfs_size', len(raw), 'single UnixFS chunk <= 262144 bytes')
    unixfs = b'\x08\x02'+b'\x12'+protobuf_varint(len(raw))+raw+b'\x18'+protobuf_varint(len(raw))
    node = b'\x0a'+protobuf_varint(len(unixfs))+unixfs
    return b'\x12\x20'+hashlib.sha256(node).digest()


def metadata_identity(art, config):
    profile = config.get('profile', {}).get('default', {})
    mode = profile.get('bytecode_hash', 'ipfs')
    tail = cbor_tail(art['deployedBytecode']['object'])
    need('metadata_solc', tail.get('solc'), bytes((0, 8, 33)))
    raw = art.get('rawMetadata')
    if not isinstance(raw, str):
        raise Gate('metadata_raw', 'missing/nontext', 'exact rawMetadata JSON bytes')
    if mode == 'none':
        exact_keys('metadata_no_hash_keys', tail, ('solc',))
    elif mode == 'ipfs':
        exact_keys('metadata_hash_keys', tail, ('solc', 'ipfs'))
        need('metadata_ipfs_hash', tail['ipfs'].hex(), metadata_ipfs_hash(raw.encode()).hex())
    else:
        raise Gate('metadata_hash_scheme', mode, 'verified IPFS hash or explicit HEAD profile.default none')
    return dict(mode=mode, compiler='0.8.33', rawMetadataSha256=hashlib.sha256(raw.encode()).hexdigest())


def archive_commit(repo, commit, destination):
    """Materialize HEAD and recursively pinned submodules using only local git objects."""
    destination.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryFile() as stream:
        r = subprocess.run(['git', 'archive', '--format=tar', commit], cwd=repo,
                           stdout=stream, stderr=subprocess.PIPE)
        if r.returncode:
            raise Gate('rebuild_archive_unavailable', {'commit': commit, 'exit': r.returncode},
                       'commit and all dependencies available in local object stores; no fetch allowed')
        stream.seek(0)
        try:
            with tarfile.open(fileobj=stream) as archive:
                archive.extractall(destination, filter='data')
        except (tarfile.TarError, OSError) as error:
            raise Gate('rebuild_archive_extract', type(error).__name__, 'safe HEAD archive') from None
    tree = subprocess.run(['git', 'ls-tree', '-r', '-z', commit], cwd=repo, capture_output=True)
    need('rebuild_tree', tree.returncode, 0)
    for entry in tree.stdout.split(b'\0'):
        if not entry: continue
        header, path = entry.split(b'\t', 1)
        mode, kind, sha = header.split()
        if mode != b'160000': continue
        path = path.decode(); target = (destination/path).resolve()
        if not target.is_relative_to(destination.resolve()):
            raise Gate('rebuild_submodule_path', path, 'path inside archive')
        child = repo/path
        top = subprocess.run(['git', 'rev-parse', '--show-toplevel'], cwd=child if child.exists() else repo,
                             capture_output=True, text=True)
        if top.returncode or Path(top.stdout.strip()).resolve() != child.resolve():
            # A locally retained bare submodule object store is sufficient too.
            module = subprocess.run(['git', 'rev-parse', '--git-path', 'modules/'+path], cwd=repo,
                                    capture_output=True, text=True)
            store = Path(module.stdout.strip())
            if not store.is_absolute(): store = repo/store
            if module.returncode or not store.is_dir():
                raise Gate('rebuild_submodule_unavailable', path, 'local initialized submodule or object store; no network fallback')
            child = store
        archive_commit(child, sha.decode(), target)


def raw_artifact(root, name):
    base = root/'out'/(name+'.sol')
    path = base/(name+'.default.json')
    if not path.exists(): path = base/(name+'.json')
    if not path.is_file():
        raise Gate('rebuild_artifact_missing', name, 'fresh default-profile artifact')
    return json.loads(path.read_text())


@lru_cache(maxsize=1)
def compile_commit(commit, forge_version, contract_names=CONTRACT_NAMES, identity_names=()):
    # Cache only independently rebuilt outputs, never the mutable ignored out/ files.
    # Every verification below re-compares current artifacts to these committed bytes.
    with tempfile.TemporaryDirectory(prefix='a3a-head-rebuild-') as directory:
        tree = Path(directory)/'tree'
        archive_commit(ROOT, commit, tree)
        config = tomllib.loads((tree/'foundry.toml').read_text())
        # Compiler execution needs no wallet/RPC credentials or user build overrides.
        allowed_env = ('HOME', 'PATH', 'TMPDIR', 'USER', 'LOGNAME', 'LANG', 'LC_ALL', 'SVM_HOME')
        env = {k: os.environ[k] for k in allowed_env if k in os.environ}
        env['FOUNDRY_PROFILE'] = 'default'
        try:
            flags = ['--ast', '--build-info'] if identity_names else []
            r = subprocess.run([str(REBUILD_FORGE), 'build', '--offline', *flags], cwd=tree, env=env,
                               capture_output=True)
        except OSError as error:
            raise Gate('rebuild_forge_unavailable', type(error).__name__, 'local forge 1.7.1') from None
        if r.returncode:
            raise Gate('rebuild_offline_build', r.returncode,
                       'forge 1.7.1 build --offline with locally installed compiler and archived dependencies')
        artifacts = {name: raw_artifact(tree, name) for name in contract_names}
        for name, allowed in identity_names:
            artifacts[name]['runtimeIdentity'] = immutable_identity(
                artifacts[name], tree/'out/build-info', name, frozenset(allowed))
        return artifacts, config


def rebuild_artifacts(artifacts):
    head = subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=ROOT, capture_output=True, text=True)
    need('rebuild_head', head.returncode, 0)
    commit = head.stdout.strip()
    try:
        version = subprocess.run([str(REBUILD_FORGE), '--version'], capture_output=True, text=True)
    except OSError as error:
        raise Gate('rebuild_forge_unavailable', type(error).__name__, 'local forge 1.7.1') from None
    need('rebuild_forge_status', version.returncode, 0)
    need('rebuild_forge_version', version.stdout.splitlines()[0], 'forge Version: 1.7.1')
    rebuilt, config = compile_commit(commit, version.stdout)
    # The no-hash exception must be authorized by the committed profile, not a
    # working-tree foundry.toml or an artifact's self-reported settings.
    committed_config = tomllib.loads(committed_bytes(ROOT, 'foundry.toml', commit).decode())
    need('rebuild_config', config, committed_config)
    evidence = {}
    for name in CONTRACT_NAMES:
        current, fresh = artifacts[name], rebuilt[name]
        fields = {}
        for field in ('bytecode', 'deployedBytecode'):
            left = bytes.fromhex(typed(current[field]['object'], HEXDATA)[2:])
            right = bytes.fromhex(typed(fresh[field]['object'], HEXDATA)[2:])
            need('rebuild_'+name+'_'+field, left == right, True)
            fields[field+'Sha256'] = hashlib.sha256(right).hexdigest()
        need('rebuild_'+name+'_immutableReferences', current['deployedBytecode'].get('immutableReferences', {}),
             fresh['deployedBytecode'].get('immutableReferences', {}))
        need('rebuild_'+name+'_creationReferences', current['bytecode'].get('immutableReferences', {}),
             fresh['bytecode'].get('immutableReferences', {}))
        refs = json.dumps(fresh['deployedBytecode'].get('immutableReferences', {}), sort_keys=True, separators=(',', ':'))
        fields['immutableReferencesSha256'] = hashlib.sha256(refs.encode()).hexdigest()
        fields['metadata'] = metadata_identity(current, committed_config)
        metadata_identity(fresh, committed_config)
        evidence[name] = fields
    return dict(commit=commit, tempTreeCommit=commit, forgeVersion=version.stdout.strip(),
                profile='default', contracts=evidence)


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
    a['sourceHashes'] = artifact_sources(metadata)
    a['runtimeIdentity'] = immutable_identity(a, contract_name=name)
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
    predicted = [create_address(DEPLOYER, n+i)
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


def execution_timestamps(pin):
    # Six sequential blocks through S5b; S6b follows a maturity mine, then S7.
    offsets = (1, 2, 3, 4, 5, 6, 7, 172807, 172808)
    return {sid: pin['timestamp']+offset for sid, offset in zip(STEP_IDS, offsets)}


def build_plan(state):
    for label, who in SENDERS.items():
        need('plan_sender_'+label, state['senders'][label]['address'], who)
    n = state['senders']['deployer']['nonce']
    need('plan_deployer_nonce', state['deployerNonce'], n)
    tl, token = [create_address(DEPLOYER, n+i)
                 for i in (1, 2)]
    need('plan_predicted_timelock', state['timelock'], tl)
    need('plan_predicted_capped', state['capped'], token)
    a, t = artifact('APNTsCapped'), artifact('TimelockController')
    rebuild = rebuild_artifacts({'APNTsCapped': a, 'TimelockController': t})
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
    times = execution_timestamps(state)
    for sid, sender, to, data in rows:
        steps.append(dict(id=sid, executionTimestamp=times[sid], tx=dict(to=to, data=data, value='0x0', nonce=hex(counters[sender]),
                     **{'from': sender}, chainId=hex(CHAIN), maxFeePerGas=hex(MAX_FEE),
                     maxPriorityFeePerGas=hex(PRIORITY))))
        if sid == 'S5b':
            steps[-1]['plannedETA'] = times[sid]+172800
        counters[sender] += 1
    return dict(schema=4, rebuild=rebuild, chainId=CHAIN, pin=state, operationId=op, salt=salt, safeTxHashes=hashes,
                runtimeIdentity=a['runtimeIdentity'], timelockRuntimeIdentity=t['runtimeIdentity'],
                artifactSources={name: art['sourceHashes'] for name, art in
                                 (('APNTsCapped', a), ('TimelockController', t))}, constructorArgs=constructor_args,
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


RPC_TOTAL_DEADLINE_SECONDS = 60
TEARDOWN_MARK = '--- teardown: engine terminating ---'
ANVIL_FORK_TIMEOUT_MS = 120000
ABANDON_MAX_SECONDS = ANVIL_FORK_TIMEOUT_MS / 1000 / 2


def request_key(q):
    """Content hash of a JSON-RPC request or batch without its ids (no URL, no secrets)."""
    strip = (lambda x: {k: v for k, v in x.items() if k != 'id'}) 
    body = [strip(x) for x in q] if isinstance(q, list) else strip(q)
    return hashlib.sha256(json.dumps(body, sort_keys=True, separators=(',', ':')).encode()).hexdigest()[:16]


def relay_evidence(out, live=False):
    # Only the operating window counts. Killing anvil interrupts its in-flight prefetches, and the relay then
    # logs e.g. 'failed handler BrokenPipeError'. Those lines stay in the log, after the teardown marker, but do
    # not fail the run. Any failure BEFORE the marker still fails it, and a missing marker fails it as well.
    # live=True: checked while the engine still runs (bootstrap continuation); every line counts, no marker yet.
    lines = (out/'relay.log').read_text().splitlines()
    if live:
        need('relay_teardown_marker_premature', TEARDOWN_MARK in lines, False)
    elif TEARDOWN_MARK in lines:
        lines = lines[:lines.index(TEARDOWN_MARK)]
    else:
        need('relay_teardown_marker', False, True)
    # What this gate protects against: anvil receiving an ERROR for a fork read and silently treating the data as
    # absent (e.g. an empty account). That is 'failed handler ... upstreamServed=False' (the relay returned 502):
    # always fatal. An 'abandoned' line means the upstream answered and anvil hung up on its own - it never received
    # an error, so it cannot substitute defaults. Observed: eth_getBalance / eth_getCode abandoned 0.2 s after the
    # upstream answered, never re-requested (anvil cancels prefetches of finished eth_estimateGas probes). The one
    # risky variant is anvil giving up on its own timeout (120 s), so an abandon is accepted only well below it.
    def allowed(x):
        if x == 'refused eth_gasPrice' or x.startswith('redelivered key='):
            return True
        if x.startswith(('abandoned ', 'abandoned-duplicate ')):
            parts = dict(p.split('=', 1) for p in x.split() if '=' in p)
            elapsed = float(parts.get('elapsed', '999s').rstrip('s'))
            return (x.split()[1] in ('BrokenPipeError', 'ConnectionResetError') and parts.get('upstreamServed') == 'True'
                    and elapsed < ABANDON_MAX_SECONDS)
        return False
    need('relay_evidence', all(allowed(x) for x in lines), True)


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


def authenticate_engine(local, relay_url, pin_block):
    """Prove the reused local port is OUR engine. web3_clientVersion carries no commit ("anvil/v1.8.7") and the
    local eth_config reports the engine's own chain config, not Sepolia's, so neither can authenticate it.
    anvil_nodeInfo can: the fork URL is our loopback relay on a random port, which another process would not have."""
    info = local('anvil_nodeInfo', [])
    if not isinstance(info, dict) or not isinstance(info.get('forkConfig'), dict) or not isinstance(info.get('environment'), dict):
        raise Gate('local_engine_info', 'malformed anvil_nodeInfo', 'hardFork, transactionOrder, environment, forkConfig')
    url = info['forkConfig'].get('forkUrl')
    # anvil normalizes the URL with a trailing slash; everything else must match exactly.
    need('local_engine_fork_url', url[:-1] if isinstance(url, str) and url.endswith('/') else url, relay_url)
    need('local_engine_fork_block', info['forkConfig'].get('forkBlockNumber'), int(pin_block, 16))
    need('local_engine_hardfork', info.get('hardFork'), 'Amsterdam')
    need('local_engine_order', info.get('transactionOrder'), 'fifo')
    need('local_chain', info['environment'].get('chainId'), CHAIN)
    need('local_chain_rpc', qty(local('eth_chainId', [])), CHAIN)
    # anvil returns a hex quantity here ("0xb6d072"), unlike forkBlockNumber (an integer).
    need('local_engine_current_block', qty(info.get('currentBlockNumber')), int(pin_block, 16))


def process_alive(proc):
    need('engine_process_alive', proc.poll(), None)


def process_owns_port(proc, port):
    process_alive(proc)
    lsof = shutil.which('lsof')
    if lsof is None:
        raise Gate('engine_lsof', 'unavailable', 'lsof required for listener PID verification')
    result = subprocess.run([lsof, '-nP', '-iTCP:'+str(port), '-sTCP:LISTEN', '-t'],
                            capture_output=True, text=True, timeout=10)
    need('engine_lsof_status', result.returncode, 0)
    need('engine_listener_pid', sorted(set(result.stdout.split())), [str(proc.pid)])
    process_alive(proc)


@contextlib.contextmanager
def fork(remote, pin, out):
    """Archive credentials stay in memory; authenticate the reused local port."""
    class Relay(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_POST(self):
            started, methods, served, key = time.monotonic(), '?', False, None
            try:
                q = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                methods = ','.join(sorted({str(x.get('method')) for x in q})) if isinstance(q, list) else str(q.get('method'))
                key = request_key(q)
                body = json.dumps(filter_rpc.dispatch(q)).encode()
                served = True  # upstream answered (errors come back as JSON-RPC errors, not exceptions)
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(body)
                with key_lock:
                    delivered.add(key)
                    if key in pending_abandoned:
                        pending_abandoned.discard(key)
                        relay_log.write('redelivered key=' + key + '\n')
            except Exception as e:
                # Type name, method names, elapsed time and a request hash only: messages may embed the archive URL.
                detail = (type(e).__name__ + ' methods=' + methods + ' upstreamServed=' + str(served) +
                          ' elapsed=%.1fs' % (time.monotonic() - started))
                if served and isinstance(e, (BrokenPipeError, ConnectionResetError)) and key is not None:
                    # anvil hung up after the upstream answered. Harmless only if the identical request
                    # (same method and params) reaches anvil successfully; relay_evidence enforces that.
                    with key_lock:
                        if key in delivered:
                            relay_log.write('abandoned-duplicate ' + detail + ' key=' + key + '\n')
                        else:
                            pending_abandoned.add(key)
                            relay_log.write('abandoned ' + detail + ' key=' + key + '\n')
                else:
                    relay_log.write('failed handler ' + detail + '\n')
                if not served:
                    self.send_error(502, 'archive relay failed')
    clean = git_state(out)
    delivered, pending_abandoned, key_lock = set(), set(), threading.Lock()
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
                                 '--chain-id', str(CHAIN), '--no-fork-node-info', '--no-bal', '--steps-tracing', '--no-storage-caching', '--silent',
                                 # Wait longer than the relay's 45 s upstream timeout, so an upstream timeout comes back to
                                 # anvil as a JSON-RPC error instead of anvil hanging up first (BrokenPipe in the relay).
                                 '--timeout', str(ANVIL_FORK_TIMEOUT_MS), '--retries', '0'],
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
        authenticate_engine(local, 'http://127.0.0.1:'+str(server.server_port), pin['block'])
        process_owns_port(proc, port)
        local.engine_process = proc
        need('fork_block_hash', block_data(local, pin['block'])['hash'], pin['blockHash'])
        for who in (DEPLOYER, EXECUTOR, APPROVER):
            local('anvil_impersonateAccount', [who])
        yield local
    finally:
        if not relay_log.closed:
            relay_log.write(TEARDOWN_MARK + '\n')
        if proc is not None:
            proc.terminate()
            proc.wait(timeout=10)
        server.shutdown()
        server.server_close()
        engine_err.close()
        relay_log.close()


TX_KEYS = frozenset(('to', 'data', 'value', 'nonce', 'from', 'chainId', 'maxFeePerGas', 'maxPriorityFeePerGas', 'gas'))


def tx_rpc(tx, gas_cap=GAS_CAP):
    need('tx_rpc_keys', sorted(set(tx)-TX_KEYS), [])
    tx_quantities(tx, gas_cap=gas_cap)
    return {k: v for k, v in tx.items() if k in TX_KEYS and v is not None}


def mined_identity(mined, tx, label):
    for key in ('from', 'to', 'nonce', 'value', 'chainId', 'maxFeePerGas', 'maxPriorityFeePerGas'):
        need(label+'_mined_'+key, mined.get(key), tx.get(key))
    need(label+'_mined_type', mined.get('type'), '0x2')
    need(label+'_mined_authorizations', mined.get('authorizationList') in (None, []), True)
    need(label+'_mined_access_list', mined.get('accessList', []), [])
    need(label+'_mined_input', mined.get('input'), tx['data'])
    if 'data' in mined:
        need(label+'_mined_data_alias', mined['data'], tx['data'])
    if 'gas' in tx:
        need(label+'_mined_gas', mined.get('gas'), tx['gas'])


def receipt(rpc, tx, status='0x1', gas_cap=GAS_CAP):
    h = typed(rpc('eth_sendTransaction', [tx_rpc(tx, gas_cap=gas_cap)]), HASH32)
    # Heavy txs under --steps-tracing can be mined well after eth_sendTransaction returns: allow 60 s.
    for _ in range(1200):
        r = rpc('eth_getTransactionReceipt', [h])
        if r is not None:
            need('receipt_status_valid', r.get('status') in ('0x0', '0x1'), True)
            if status is not None:
                need('receipt_status', r.get('status'), status)
            qty(r['gasUsed'])
            return r
        time.sleep(.05)
    raise Gate('receipt_timeout', h, 'mined receipt')


def trace_nodes(trace):
    yield trace
    for child in trace.get('calls', []):
        if not isinstance(child, dict):
            raise Gate('negative_trace', 'malformed child', 'complete callTracer nodes')
        yield from trace_nodes(child)


def negative(rpc, tx, expected, name, inner=None):
    sender = tx['from']
    before = [nonce(rpc, sender), word(rpc, SAFE, 'nonce()')]
    snap = rpc('evm_snapshot', [])
    try:
        bad = dict(tx, nonce=hex(before[0]), gas=tx.get('gas', hex(GAS_CAP)))
        r = receipt(rpc, bad, status='0x0')
        trace = rpc('debug_traceTransaction', [r['transactionHash'], {'tracer': 'callTracer'}])
        if not isinstance(trace, dict):
            raise Gate('negative_trace', 'unavailable/malformed callTracer', 'complete transaction call trace')
        need('negative_'+name+'_reason', trace.get('output'), expected)
        if inner is not None:
            target, data, output = inner
            matches = [node for node in trace_nodes(trace) if node.get('to', '').lower() == target
                       and node.get('input') == data]
            need('negative_'+name+'_inner_count', len(matches), 1)
            need('negative_'+name+'_inner_revert', bool(matches[0].get('error')), True)
            need('negative_'+name+'_inner_reason', matches[0].get('output'), output)
        # A mined reverted EOA transaction necessarily consumes one nonce. The Safe nonce must not move.
        need('negative_'+name+'_mined_nonces', [nonce(rpc, sender), word(rpc, SAFE, 'nonce()')],
             [before[0]+1, before[1]])
    finally:
        need('negative_'+name+'_restore', rpc('evm_revert', [snap]), True)
    need('negative_'+name+'_restored_nonces', [nonce(rpc, sender), word(rpc, SAFE, 'nonce()')], before)
    result = dict(control=name, kind='reverted_transaction', revert=expected, receipt=r,
                  beforeNonces=before, minedNonces=[before[0]+1, before[1]], restoredNonces=before)
    if inner is not None:
        result['innerRevert'] = dict(to=inner[0], input=inner[1], output=inner[2])
    return result


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
        got['timelockRuntimeIdentity'] = verify_runtime(rpc, plan, rpc('eth_getCode', [tl, 'latest']), 'TimelockController')
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
        context['eta'] = ts + word(rpc, tl, 'getMinDelay()')
        got['informationalPlannedETA'] = step['plannedETA']
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


def exact_keys(gate, value, keys):
    if not isinstance(value, dict):
        raise Gate(gate, 'not an object', sorted(keys))
    need(gate, sorted(value), sorted(keys))


def pin_integer(value, name):
    need('pin_integer_'+name, type(value) is int and 0 <= value < 2**256, True)


def validate_pin(pin):
    exact_keys('pin_keys', pin, ('block', 'blockHash', 'timestamp', 'deployerNonce', 'safeNonce',
                               'owners', 'sp', 'timelock', 'capped', 'balance', 'senders'))
    for name in ('timestamp', 'deployerNonce', 'safeNonce', 'balance'):
        pin_integer(pin[name], name)
    exact_keys('pin_senders', pin['senders'], SENDERS)
    for label in SENDERS:
        exact_keys('pin_sender_'+label, pin['senders'][label], ('address', 'nonce', 'balance'))
        for key in ('nonce', 'balance'):
            pin_integer(pin['senders'][label][key], label+'_'+key)
    exact_keys('pin_sp', pin['sp'], ('owner', 'APNTS_TOKEN', 'pendingAPNTsToken',
                                   'pendingAPNTsTokenEta', 'APNTS_TOKEN_TIMELOCK'))
    for name in ('pendingAPNTsTokenEta', 'APNTS_TOKEN_TIMELOCK'):
        pin_integer(pin['sp'][name], name)
    need('pin_balance', pin['balance'], pin['senders']['deployer']['balance'])
    qty(pin['block'])
    typed(pin['blockHash'], HASH32)
    need('pin_timestamp', pin['timestamp'] >= ACTIVATION, True)


def tx_quantities(tx, gas_cap=GAS_CAP):
    for field in ('value', 'nonce', 'chainId', 'maxFeePerGas', 'maxPriorityFeePerGas', 'gas'):
        if field in tx: qty(tx[field])
    if 'gas' in tx:
        need('gas_cap', qty(tx['gas']) <= gas_cap, True)


def validate_plan(plan, frozen=False):
    validate_pin(plan['pin'])
    need('plan_step_ids', [s['id'] for s in plan['steps']], list(STEP_IDS))
    rebuilt = build_plan(plan['pin'])
    exact_keys('plan_keys', plan, set(rebuilt) | ({'budgetsWei', 'budgetWei'} if frozen else set()))
    for key in set(rebuilt)-{'steps'}:
        need('plan_identity_'+key, plan[key], rebuilt[key])
    for step, expected in zip(plan['steps'], rebuilt['steps']):
        sid = step['id']
        measured = {'estimateGas', 'localEstimateGas', 'forkGasUsed'} if frozen else set()
        exact_keys('plan_step_keys_'+sid, step, set(expected) | measured)
        exact_keys('plan_tx_keys_'+sid, step['tx'], set(expected['tx']) | ({'gas'} if frozen else set()))
        tx_quantities(step['tx'])
        for key in set(expected)-{'tx'}:
            need('plan_derived_'+sid+'_'+key, step[key], expected[key])
        for key, value in expected['tx'].items():
            need('plan_step_'+sid+'_'+key, step['tx'][key], value)
        if frozen:
            for key in measured:
                need('plan_measurement_'+sid+'_'+key, type(step[key]) is int and step[key] > 0, True)
            limit = (max(step[key] for key in measured)*MARGIN_NUM+MARGIN_DEN-1)//MARGIN_DEN
            need('plan_gas_'+sid, qty(step['tx']['gas']), limit)
    if frozen:
        checked = copy.deepcopy(plan)
        budget(checked)
        need('plan_budgets', plan['budgetsWei'], checked['budgetsWei'])
        need('plan_budget', plan['budgetWei'], checked['budgetWei'])


def find_step_receipt(remote, plan, step_index):
    # Locate by sender+planned nonce in mined blocks; never trust a plan-supplied tx hash.
    expected = plan['steps'][step_index]['tx']
    head = qty(block_data(remote, 'latest')['number'])
    for number in range(int(plan['pin']['block'], 16)+1, head+1):
        block = remote('eth_getBlockByNumber', [hex(number), True])
        for tx in block['transactions']:
            if tx.get('from', '').lower() == expected['from'] and tx.get('nonce') == expected['nonce']:
                mined_identity(tx, expected, 'schedule')
                r = remote('eth_getTransactionReceipt', [typed(tx['hash'], HASH32)])
                need('schedule_receipt_status', r['status'], '0x1')
                need('schedule_receipt_block', r['blockNumber'], hex(number))
                return r
    raise Gate('schedule_receipt_missing', 'no matching mined S5b', 'planned sender, nonce and full identity')


def scheduled_eta(remote, plan, done=False):
    tl, op = plan['pin']['timelock'], plan['operationId']
    topic = keccak('CallScheduled(bytes32,uint256,address,uint256,bytes,bytes32,uint256)')
    r = find_step_receipt(remote, plan, 5)
    logs = remote('eth_getLogs', [dict(address=tl, fromBlock=r['blockNumber'],
                  toBlock=r['blockNumber'], topics=[topic, op, ZERO32])])
    need('schedule_log_count', len(logs), 1)
    log = logs[0]
    need('schedule_log_removed', log.get('removed', False), False)
    need('schedule_log_topics', log['topics'], [topic, op, ZERO32])
    need('schedule_log_address', log['address'].lower(), tl)
    delay = word(remote, tl, 'getMinDelay()')
    need('schedule_delay', delay, 172800)
    data = cast('abi-encode', 'c(address,uint256,bytes,bytes32,uint256)',
                plan['pin']['capped'], 0, calldata('acceptOwnership()'), ZERO32, delay)
    need('schedule_log_data', typed(log['data'], HEXDATA).lower(), data.lower())
    need('schedule_log_tx', log['transactionHash'], r['transactionHash'])
    need('schedule_receipt_block', r['blockNumber'], log['blockNumber'])
    need('schedule_receipt_log', any(x.get('address', '').lower() == tl and x.get('topics') == log['topics']
                                   and x.get('data') == log['data'] for x in r['logs']), True)
    mined = remote('eth_getTransactionByHash', [r['transactionHash']])
    mined_identity(mined, plan['steps'][5]['tx'], 'schedule')
    eta = qty(block_data(remote, r['blockNumber'])['timestamp'])+delay
    need('schedule_chain_eta', word(remote, tl, 'getTimestamp(bytes32)', op), 1 if done else eta)
    return eta


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
            context['eta'] = scheduled_eta(remote, plan, done=index == 8)
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


def signing_transaction(plan_path, reviewed_sha256, sid, remote):
    """Future signer entry: the reviewed digest must come out-of-band, never from a sidecar."""
    raw = Path(plan_path).read_bytes()
    need('reviewed_plan_hash', hashlib.sha256(raw).hexdigest(), reviewed_sha256)
    plan = plan_json(raw)
    validate_plan(plan, frozen=True)
    if sid in ('S5a', 'S5b', 'S6a', 'S6b'):
        safe_hash_check(remote, plan)
    return pre_send(ExecutionStep(plan, sid), remote)


def completion(records, controls):
    need('completed_steps', [r['step'] for r in records], list(STEP_IDS))
    need('completed_controls', [c['control'] for c in controls], list(CONTROL_IDS))


def rehearse(remote, plan, out, calibrate=False, after=None):
    records, controls, context, overrides = [], [], {}, {}
    pin = plan['pin']
    validate_plan(plan, frozen=not calibrate)
    frozen_plan = copy.deepcopy(plan) if not calibrate else None
    with fork(remote, pin, out) as local:
        if after is not None:
            with (out/'simulate.log').open('a') as log:
                log.write(json.dumps(dict(phase='a3a', status='START'))+'\n')
        expected_safe = pin['safeNonce']
        for step in plan['steps']:
            process_alive(local.engine_process)
            sid = step['id']
            tx = copy.deepcopy(step['tx'])
            if sid == 'S6b':
                inner_reason = calldata('TimelockUnexpectedOperationState(bytes32,bytes32)', plan['operationId'],
                                        '0x'+format(1 << 2, '064x'))
                controls.append(negative(local, tx, error_string('GS013'), 'early_execute',
                    inner=(pin['timelock'], plan['safeInnerData'][1], inner_reason)))
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
            need(sid+'_execution_timestamp', execution_ts, step['executionTimestamp'])
            local('evm_setNextBlockTimestamp', [execution_ts])
            estimate_tx = {k: v for k, v in tx_rpc(tx).items() if k != 'gas'}
            estimate_context = dict(block=pin['block'], stateOverrides=json.loads(json.dumps(overrides)),
                                    blockOverrides={'time': hex(execution_ts)})
            params = [estimate_tx, pin['block'], overrides, {'time': hex(execution_ts)}]
            est = qty(remote('eth_estimateGas', params))
            local_est = qty(local('eth_estimateGas', [estimate_tx, 'latest']))
            if calibrate:
                tx['gas'] = hex((max(est, local_est)*MARGIN_NUM+MARGIN_DEN-1)//MARGIN_DEN)
                tx_quantities(tx)
                step['estimateGas'] = est
                step['localEstimateGas'] = local_est
                # Pilot execution supplies gasUsed, then roll back and rerun at the final exact limit.
                snap = local('evm_snapshot', [])
                pilot = receipt(local, tx)
                used = qty(pilot['gasUsed'])
                need('pilot_restore', local('evm_revert', [snap]), True)
                local('evm_setNextBlockTimestamp', [execution_ts])
                tx['gas'] = hex((max(est, local_est, used)*MARGIN_NUM+MARGIN_DEN-1)//MARGIN_DEN)
                step['forkGasUsed'] = used
            else:
                need(sid+'_archive_estimate', est, step['estimateGas'])
                need(sid+'_local_estimate', local_est, step['localEstimateGas'])
            tx_quantities(tx)
            step['tx'] = tx
            r = receipt(local, tx)
            need(sid+'_post_sender_nonce', nonce(local, tx['from']), qty(tx['nonce'])+1)
            expected_safe += int(sid in ('S5b', 'S6b'))
            need(sid+'_post_safe_nonce', word(local, SAFE, 'nonce()'), expected_safe)
            need(sid+'_gas_crosscheck', qty(r['gasUsed']), step['forkGasUsed'])
            need(sid+'_mined_timestamp', qty(block_data(local, r['blockNumber'])['timestamp']),
                 step['executionTimestamp'])
            observed = readback(local, plan, step, r, context)
            need(sid+'_gas_limit', qty(r['gasUsed']) <= qty(tx['gas']), True)
            mined = local('eth_getTransactionByHash', [r['transactionHash']])
            mined_identity(mined, tx, sid)
            records.append(dict(step=sid, gasUsed=qty(r['gasUsed']), receipt=r, readback=observed))
            records[-1]['estimateContext'] = estimate_context
            with (out/'simulate.log').open('a') as log:
                log.write(json.dumps(records[-1])+'\n')
            write_json(out/'simulate.json', dict(status='IN_PROGRESS', steps=records, negativeControls=controls))
            trace_overrides(local, r, overrides)
        # Keep the authenticated engine and read-only relay alive for a dependent package.
        # Existing callers retain the original standalone rehearsal behavior.
        completion(records, controls)
        if after is not None:
            validate_plan(plan, frozen=True)
            need('frozen_plan_unchanged', plan, frozen_plan)
            checked = copy.deepcopy(plan)
            budget(checked)
            need('frozen_budgets', checked['budgetsWei'], plan['budgetsWei'])
            relay_evidence(out, live=True)
            need('engine_stderr', (out/'engine.stderr').stat().st_size, 0)
            local.archive_overrides = copy.deepcopy(overrides)
            after(local)
    completion(records, controls)
    relay_evidence(out)
    need('engine_stderr', (out/'engine.stderr').stat().st_size, 0)
    if calibrate:
        budget(plan)
    validate_plan(plan, frozen=True)
    if not calibrate:
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
    return plan_json(raw)


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
        p.add_argument('--reviewed-plan-sha256')
        p.add_argument('--out', type=Path, default=None)  # refusal is recorded on disk only when asked
    args = parser.parse_args(argv)
    try:
        if args.out is not None:
            if args.out.exists():
                need('output_empty', args.out.is_dir() and not any(args.out.iterdir()), True)
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
            if e.record['gate'] == 'output_empty':
                print(json.dumps(e.record), file=sys.stderr)
            else:
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
