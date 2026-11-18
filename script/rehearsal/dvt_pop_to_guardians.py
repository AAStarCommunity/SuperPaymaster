#!/usr/bin/env python3
"""Offline DVT export gate. stdout is exclusively abi.encode(GuardianInput[])."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys

SOURCE = 'contracts/src/modules/monitoring/BLSAggregator.sol'
SIGNATURE = 'registerBLSPublicKey(address,(bytes32,bytes32,bytes32,bytes32),uint8,(bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,bytes32))'
CONTEXT = {'dvt', 'aggregator', 'registry', 'chainId', 'deployerAddress', 'deployerNonce', 'pinBlock', 'pinBlockHash', 'spCommit', 'spAggregatorSourceSha256', 'popDigests'}
ENTRY = {'validator', 'slot', 'calldata', 'aggregator', 'pinBlockHash', 'domainSeparator'}

class Stop(ValueError):
    pass

def check(ok, gate):
    if not ok:
        raise Stop('STOP ' + gate)

def exact(obj, keys, gate):
    check(isinstance(obj, dict) and set(obj) == set(keys), gate)

def command(args, gate, cwd=None):
    if args[0] == 'cast' and shutil.which('cast') is None:
        raise Stop('STOP cast_not_found: install foundry or add it to PATH')
    try:
        return subprocess.check_output(args, cwd=cwd, stderr=subprocess.PIPE).strip()
    except (OSError, subprocess.CalledProcessError) as exc:
        raise Stop('STOP ' + gate) from exc

def hex_bytes(value, size, gate):
    check(isinstance(value, str) and re.fullmatch(r'0x[0-9a-fA-F]{' + str(size * 2) + '}', value) is not None, gate)
    return bytes.fromhex(value[2:])

def same_hex(a, b, size, gate):
    check(hex_bytes(a, size, gate) == hex_bytes(b, size, gate), gate)

def word(n):
    return n.to_bytes(32, 'big')

def keccak(data):
    return bytes.fromhex(command(['cast', 'keccak', '0x' + data.hex()], 'cast_keccak').decode()[2:])

def source_version(data):
    versions = re.findall(rb'return\s+"(BLSAggregator-\d+\.\d+\.\d+)"\s*;', data)
    check(len(versions) == 1, 'source_version')
    return versions[0].decode()

def convert(export, request, root):
    if shutil.which('cast') is None:
        raise Stop('STOP cast_not_found: install foundry or add it to PATH')
    exact(export, {'pop', 'aggregatorSourceVersion', 'popContext'}, 'export_keys')
    check(isinstance(request, dict) and request.get('schema') == 'deploylive-pop-request/1', 'request_schema')
    try:
        addresses = request['addresses']
        pin = request['pin']
        sender = pin['senders']['deployer']
        commit = request['spCommit']
        count = request['guardianCount']
        chain = request['chainId']
    except (KeyError, TypeError) as exc:
        raise Stop('STOP request_fields') from exc
    check(type(count) is int and 1 <= count <= 64, 'request_count')
    check(type(chain) is int and 0 <= chain < 2**256, 'request_chain')
    check(isinstance(commit, str) and re.fullmatch('[0-9a-f]{40}', commit), 'request_commit')
    context = export['popContext']
    exact(context, CONTEXT, 'context_keys')
    try:
        bindings = {'dvt': addresses['DVTValidator'], 'aggregator': addresses['BLSAggregator'],
                    'registry': addresses['Registry'], 'deployerAddress': sender['address'],
                    'pinBlockHash': pin['blockHash']}
        for key, value in bindings.items():
            same_hex(context[key], value, 32 if key == 'pinBlockHash' else 20, 'context_' + key)
        for key, value in {'chainId': chain, 'deployerNonce': sender['nonce'], 'pinBlock': pin['block'], 'spCommit': commit}.items():
            check(type(context[key]) is type(value) and context[key] == value, 'context_' + key)
            if key != 'spCommit':
                check(type(value) is int and 0 <= value < 2**256, 'context_' + key)
    except (KeyError, TypeError) as exc:
        raise Stop('STOP request_fields') from exc
    # Preserve the exact blob bytes, including its final newline.
    try:
        source = subprocess.check_output(['git', 'show', f'{commit}:{SOURCE}'], cwd=root, stderr=subprocess.PIPE)
    except (OSError, subprocess.CalledProcessError) as exc:
        raise Stop('STOP source_commit') from exc
    try:
        current = (Path(root) / SOURCE).read_bytes()
    except OSError as exc:
        raise Stop('STOP source_file') from exc
    RELEASE_VERSIONS = {'BLSAggregator': source_version(current)}
    check(export['aggregatorSourceVersion'] == RELEASE_VERSIONS['BLSAggregator'] == source_version(source), 'version')
    digest = hashlib.sha256(source).hexdigest()
    claimed = context['spAggregatorSourceSha256']
    check(isinstance(claimed, str) and re.fullmatch(r'(0x)?[0-9a-fA-F]{64}', claimed) is not None, 'source_hash_format')
    # Compare normalized: DVT copies strings verbatim, so case and an optional 0x must not matter.
    check(claimed.lower().removeprefix('0x') == digest, 'source_hash')
    head = command(['git', 'rev-parse', 'HEAD'], 'source_head', root).decode()
    if commit == head:
        check(hashlib.sha256(current).hexdigest() == digest, 'source_worktree')
    entries = export['pop']
    check(isinstance(entries, list) and len(entries) == count, 'pop_count')
    check(isinstance(context['popDigests'], list) and len(context['popDigests']) == count, 'pop_digests')
    domain = keccak(keccak(b'SuperPaymaster.BLSConsensus.v1') + word(chain)
                    + bytes(12) + hex_bytes(bindings['aggregator'], 20, 'context_aggregator')
                    + bytes(12) + hex_bytes(bindings['registry'], 20, 'context_registry'))
    selector = keccak(SIGNATURE.encode())[:4]
    seen = set()
    tuples = []
    for index, entry in enumerate(entries, 1):
        exact(entry, ENTRY, 'pop_keys')
        same_hex(entry['aggregator'], bindings['aggregator'], 20, 'pop_aggregator')
        same_hex(entry['pinBlockHash'], bindings['pinBlockHash'], 32, 'pop_pinBlockHash')
        check(hex_bytes(entry['domainSeparator'], 32, 'pop_domainSeparator') == domain, 'pop_domainSeparator')
        calldata = hex_bytes(entry['calldata'], 4 + 14 * 32, 'calldata_length')
        check(calldata[:4] == selector, 'calldata_selector')
        words = [calldata[i:i+32] for i in range(4, len(calldata), 32)]
        validator = hex_bytes(entry['validator'], 20, 'calldata_validator')
        check(words[0] == bytes(12) + validator, 'calldata_validator')
        check(type(entry['slot']) is int and 0 <= entry['slot'] <= 255 and int.from_bytes(words[5], 'big') == entry['slot'], 'calldata_slot')
        check(entry['slot'] == index, 'slot_order')
        check(validator not in seen, 'validator_distinct')
        seen.add(validator)
        tuples.append(words[0] + b''.join(words[1:5]) + b''.join(words[6:]))
    return '0x' + (word(32) + word(count) + b''.join(tuples)).hex()

class Parser(argparse.ArgumentParser):
    def error(self, message):
        raise Stop('STOP arguments: ' + message)

def main():
    parser = Parser(description=__doc__)
    parser.add_argument('export', type=Path)
    parser.add_argument('request', type=Path)
    parser.add_argument('--sp-root', type=Path, required=True)
    try:
        args = parser.parse_args()
        inputs = []
        for path in (args.export, args.request):
            data = path.read_bytes()
            print(f'sha256 {path}: {hashlib.sha256(data).hexdigest()}', file=sys.stderr)
            inputs.append(json.loads(data))
        print(convert(*inputs, args.sp_root))
    except (Stop, OSError, ValueError, TypeError, KeyError) as exc:
        print(str(exc) if isinstance(exc, Stop) else 'STOP input_read: ' + str(exc), file=sys.stderr)
        return 3
    return 0

if __name__ == '__main__':
    sys.exit(main())
