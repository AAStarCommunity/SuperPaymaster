#!/usr/bin/env python3
"""Read-only C1–C9 at an EIP-1898 block hash with receipt-verified discovery.

C9 blocks when source-level inflight coverage cannot be established.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
from functools import lru_cache

spec = importlib.util.spec_from_file_location('a4_logscan', Path(__file__).with_name('a4-credit-logscan.py'))
logs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(logs)

@lru_cache(None)
def cast(*args):
    return subprocess.check_output([os.environ.get('A4_CAST', str(Path.home()/'.foundry/bin/cast')), *args], text=True).strip()


def word(value):
    return value[2:].rjust(64, '0')


ENTRY_POINT_V07 = '0x0000000071727de22e5e9d8baf0edac6f37da032'
USER_OPERATION_EVENT = 'UserOperationEvent(bytes32,address,address,uint256,bool,uint256,uint256)'


def creation_block(urls, address, end, lower=0):
    """Bisect persistent contract code, comparing both archives at every probe."""
    if type(lower) is not int or not 0 <= lower <= end:
        raise logs.RpcFailure('invalid creation lower bound')
    def code(n):
        pair = [logs.hexstr(logs.rpc(u, 'eth_getCode', [address, hex(n)])) for u in urls]
        if pair[0] != pair[1]:
            raise logs.RpcFailure('creation code disagreement')
        return pair[0] != '0x'
    if not code(end):
        raise logs.RpcFailure('no code at fixed block')
    if code(lower):
        start = lower
    else:
        lo, hi = lower, end
        while hi - lo > 1:
            mid = (lo + hi) // 2
            if code(mid):
                hi = mid
            else:
                lo = mid
        start = hi
    # Genesis code cannot supply the required empty predecessor proof.
    if start == 0 or code(start - 1) or not code(start):
        raise logs.RpcFailure('creation boundary unverified')
    return start


def discover_inflight(urls, config, sp, end_hash, created):
    """Bind EntryPoint over the proxy lifetime before enumerating operations."""
    evidence = {'complete': False, 'reason': 'EntryPoint start block unknown or unpinned'}
    try:
        start = config.get('inflightStart', {'block': created, 'source': 'sp-proxy-deploy'})
        evidence['start'] = start
        if (type(start['block']) is not int or not 1 <= start['block'] <= created
                or start['source'] not in ('inflight-upgrade', 'sp-proxy-deploy')):
            return evidence, set()
        if 'inflightStart' in config and 'blockHash' not in start:
            return evidence, set()
        start_pair = [logs.block(u, hex(start['block'])) for u in urls]
        if start_pair[0] != start_pair[1]:
            raise logs.RpcFailure('start block disagreement')
        start_hash = start_pair[0]['hash']
        if 'blockHash' in start and logs.hexstr(start['blockHash'], 32) != start_hash:
            raise logs.RpcFailure('start pin differs')
        ep = logs.hexstr(config.get('entryPoint', ENTRY_POINT_V07), 20)
        upgrades, _ = discover(urls, sp, created, config['block'],
                                {'Upgraded': ('Upgraded(address)', 2, 0)}, False)
        evidence['upgrades'] = upgrades
        if not upgrades['complete'] or upgrades['blockHashes']['to']['A'] != end_hash:
            raise logs.RpcFailure('upgrade history incomplete')
        bindings = []
        evidence['bindings'] = bindings
        for n in sorted({created, config['block']} | {v['blockNumber'] for v in upgrades['logs']}):
            blocks = [logs.block(u, hex(n)) for u in urls]
            if blocks[0] != blocks[1]:
                raise logs.RpcFailure('binding block disagreement')
            pin = {'blockHash': blocks[0]['hash'], 'requireCanonical': True}
            values = [logs.hexstr(logs.rpc(u, 'eth_call',
                      [{'to': sp, 'data': cast('sig', 'entryPoint()')}, pin]), 32) for u in urls]
            bindings.append({'block': n, 'blockHash': blocks[0]['hash'], 'values': values})
            if values != ['0x'+word(ep)] * 2:
                raise logs.RpcFailure('EntryPoint binding differs')
        topic = logs.hexstr(cast('keccak', USER_OPERATION_EVENT), 32)
        def decode(v):
            if len(v['topics']) != 4 or v['topics'][0] != topic:
                raise logs.RpcFailure('invalid UserOperationEvent topics')
            data = logs.hexstr(v['data'], 128)
            if any(int(t[2:26], 16) for t in v['topics'][2:]) or int(data[66:130], 16) > 1:
                raise logs.RpcFailure('invalid UserOperationEvent ABI')
            return {'opHash': v['topics'][1]}
        scan = logs.scan(urls, [ep], start['block'], config['block'],
                         event_topics={'UserOperationEvent': topic}, decoder=decode,
                         deployment_check=False, indexed_topics={3: '0x'+word(sp)})
        complete = scan['complete'] and all(
            scan['blockHashes'][label][endpoint] == expected
            for label, expected in (('from', start_hash), ('to', end_hash))
            for endpoint in ('A', 'B'))
        evidence.update(entryPoint=ep, scan=scan, complete=complete,
                        reason=None if complete else 'EntryPoint scan incomplete or block pin differs')
        found = {decode(v)['opHash'] for v in scan['logs']}
        expected = config.get('expectedEntryPointHits')
        if expected is not None:
            if (not isinstance(expected, dict) or type(expected.get('head')) is not int
                    or not start['block'] <= expected['head'] <= config['block']
                    or not isinstance(expected.get('opHashes'), list)):
                raise logs.RpcFailure('invalid expectedEntryPointHits')
            hashes = {logs.hexstr(h, 32) for h in expected['opHashes']}
            at_head = {decode(v)['opHash'] for v in scan['logs'] if v['blockNumber'] <= expected['head']}
            missing = sorted(hashes - at_head)
            evidence['positiveControl'] = dict(head=expected['head'], opHashes=sorted(hashes),
                                               missing=missing, result='fail' if missing else 'pass')
            evidence['newHits'] = [dict(opHash=decode(v)['opHash'], blockNumber=v['blockNumber'])
                                   for v in scan['logs'] if decode(v)['opHash'] not in hashes]
        return evidence, found
    except (logs.RpcFailure, ValueError, KeyError, TypeError):
        evidence.update(complete=False, reason='EntryPoint history or positive control could not be verified')
        return evidence, set()


LOCK_EVENTS = {
    'LockCreated': ('LockCreated(address,bytes32,address,uint256,uint256)', 4, 64),
    'LockSettled': ('LockSettled(address,bytes32,uint256,uint256)', 3, 64),
    'LockReleased': ('LockReleased(address,bytes32,uint256)', 3, 32),
}
SP_EVENTS = {
    'SponsorshipReleased': ('SponsorshipReleased(bytes32,address,uint256)', 3, 32),
    'ValidationFailed': ('ValidationFailed(bytes32,bytes32)', 2, 32),
}


def discover(urls, address, start, end, definitions, token):
    topics = {name: logs.hexstr(cast('keccak', sig), 32) for name, (sig, _, _) in definitions.items()}
    def decode(v):
        name = next((k for k, topic in topics.items() if v['topics'] and v['topics'][0] == topic), None)
        if name is None or len(v['topics']) != definitions[name][1]:
            raise logs.RpcFailure('unexpected discovery event')
        logs.hexstr(v['data'], definitions[name][2])
        if name == 'Upgraded' and int(v['topics'][1][2:26], 16):
            raise logs.RpcFailure('invalid upgrade address')
        return {'event': name, 'opHash': v['topics'][2 if token else 1]}
    scan = logs.scan(urls, [address], start, end, event_topics=topics,
                     decoder=decode, deployment_check=token)
    scan['eventCounts'] = {name: sum(v['topics'][0] == topic for v in scan['logs'])
                           for name, topic in topics.items()}
    return scan, {decode(v)['opHash'] for v in scan['logs']}


@logs.rpc_recorded
def check(urls, config):
    out = {'scope': 'fixed-block-state', 'subject': {'blockNumber': config['block']},
           'controls': {}, 'reads': [], 'opHashSet': None}
    controls = out['controls']
    def unverified(c, reason):
        controls[c] = {'result': 'unverified', 'reason': reason}
    def item(c, fn):
        try:
            controls[c] = {'result': 'pass' if fn() else 'fail'}
        except (logs.RpcFailure, ValueError, KeyError, TypeError, OSError, subprocess.SubprocessError):
            unverified(c, 'required read or history could not be verified')
    try:
        if len(urls) != 2 or urls[0] == urls[1]:
            raise logs.RpcFailure('two endpoints required')
        raw_blocks = [logs.rpc(u, 'eth_getBlockByNumber', [hex(config['block']), False]) for u in urls]
        if raw_blocks[0] != raw_blocks[1]:
            raise logs.RpcFailure('block disagreement')
        b = [{'number': logs.quantity(v['number']), 'hash': logs.hexstr(v['hash'], 32)} for v in raw_blocks]
        if b[0]['number'] != config['block']:
            raise logs.RpcFailure('block number disagreement')
        out['subject']['blockHash'] = b[0]['hash']
        pin = {'blockHash': b[0]['hash'], 'requireCanonical': True}
        def read(method, params):
            pair = [logs.rpc(u, method, params) for u in urls]
            if pair[0] != pair[1]:
                raise logs.RpcFailure('byte-for-byte disagreement')
            out['reads'].append({'method': method, 'params': params, 'result': pair[0]})
            return pair[0]
        def call(address, signature, *args, widths=(256,)):
            data = cast('sig', signature) + ''.join(word(v) for v in args)
            raw = logs.hexstr(read('eth_call', [{'to': address, 'data': data}, pin]), 32*len(widths))
            values = tuple(int(raw[2+i*64:66+i*64], 16) for i in range(len(widths)))
            if any(v >= 1 << w for v, w in zip(values, widths)):
                raise logs.RpcFailure('ABI overflow')
            return values
        def code(address):
            value = logs.hexstr(read('eth_getCode', [address, pin]))
            if value == '0x':
                raise logs.RpcFailure('empty code')
            return value
        t, u, sp = (logs.hexstr(config[k], 20) for k in ('token', 'user', 'sp'))
        p = config['pins']
        def identity():
            factory, impl, ext = (logs.hexstr(p[k], 20) for k in ('factory', 'implementation', 'extension'))
            checks = [code(t) == '0x363d3d373d3d3d363d73'+impl[2:]+'5af43d82803e903d91602b57fd5bf3',
                cast('keccak', code(factory)) == p['factoryCodehash'],
                cast('keccak', code(impl)) == p['implementationCodehash'],
                cast('keccak', code(ext)) == p['extensionCodehash'],
                call(t, 'FACTORY()', widths=(160,)) == (int(factory,16),),
                call(impl, 'EXTENSION()', widths=(160,)) == (int(ext,16),),
                call(factory, 'implementation()', widths=(160,)) == (int(impl,16),),
                call(factory, 'implementationCodehash()') == (int(p['implementationCodehash'],16),),
                call(factory, 'extensionCodehash()') == (int(p['extensionCodehash'],16),),
                call(factory, 'getTokenAddress(address)', config['community'], widths=(160,)) == (int(t,16),),
                call(factory, 'isXPNTs(address)', t, widths=(1,)) == (1,)]
            return all(checks)
        item('C1', identity)
        item('C2', lambda: call(t, 'creditPolicy()', widths=(8,)) == (0,))
        item('C3', lambda: call(t, 'hasPendingPolicy()', widths=(1,)) == (0,))
        created_t = creation_block(urls, t, config['block'], config.get('tokenCreationLowerBound', 0))
        created_sp = creation_block(urls, sp, config['block'], config.get('spCreationLowerBound', 0))
        out['derivedBlocks'] = {'token': created_t, 'sp': created_sp}
        token_start = config.get('deployBlock', created_t)
        if type(token_start) is not int or not 1 <= token_start <= created_t:
            raise logs.RpcFailure('token start after creation')
        scan = logs.scan(urls, [t], token_start, config['block'])
        out['logscan'] = scan
        history = scan['complete'] and scan['blockHashes']['to']['A'] == pin['blockHash']
        for c in ('C4', 'C7'):
            if history:
                controls[c] = {'result': scan[c]['verdict']}
            else:
                unverified(c, 'history incomplete or fixed block differs')
        item('C5', lambda: call(t, 'creditReservedOf(address)', u) == (0,))
        inventory = config.get('knownOperations', {'source': 'chain discovery', 'opHashes': []})
        if not isinstance(inventory['source'], str) or not inventory['source'].strip():
            raise logs.RpcFailure('operation source required')
        if not isinstance(inventory['opHashes'], list):
            raise logs.RpcFailure('operation inventory must be an array')
        known = {logs.hexstr(h, 32) for h in inventory['opHashes']}
        events = [logs.decode(v) for v in scan['logs']] if history else []
        touched = {e['user'] for e in events if 'user' in e}
        discovered = {e['opHash'] for e in events if 'opHash' in e}
        lock_scan, lock_ops = discover(urls, t, token_start, config['block'], LOCK_EVENTS, True)
        sp_scan, sp_ops = discover(urls, sp, created_sp, config['block'], SP_EVENTS, False)
        discovered |= lock_ops | sp_ops
        discovery_complete = history and all(
            v['complete'] and v['blockHashes']['to']['A'] == pin['blockHash']
            for v in (lock_scan, sp_scan))
        out['discovery'] = {'credit': scan, 'locks': lock_scan, 'sp': sp_scan,
                            'complete': discovery_complete}
        scan['eventCounts'] = {name: sum(e['event'] == name for e in events) for name in logs.SIGNATURES}
        ep_evidence, ep_ops = discover_inflight(urls, config, sp, pin['blockHash'], created_sp)
        out['discovery']['entryPoint'] = ep_evidence
        inflight_ops = sorted(known | discovered | ep_ops)
        out['inflightHashSet'] = {'opHashes': inflight_ops, 'entryPointDiscovered': sorted(ep_ops),
                                  'supplied': sorted(known)}
        ops = sorted(known | discovered)
        out['opHashSet'] = {'opHashes': ops, 'supplied': sorted(known), 'discovered': sorted(discovered),
                            'source': inventory['source'], 'discoverySource': 'receipt-verified credit, lock and SP logs from verified creation boundaries through fixed block'}
        out['debtUsers'] = sorted(touched | {u})
        item('C8', lambda: all([call(t, 'debts(address)', user) == (0,) for user in out['debtUsers']]))
        def inflight_supported():
            runtime = code(sp)
            slot = '0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc'
            implementation = logs.hexstr(read('eth_getStorageAt', [sp, slot, pin]), 32)
            if int(implementation, 16):
                if int(implementation[2:26], 16):
                    raise logs.RpcFailure('invalid implementation slot')
                runtime = code('0x' + implementation[-40:])
            if cast('sig', 'inflightOf(bytes32)')[2:].lower() not in runtime[2:]:
                raise logs.RpcFailure('inflightOf selector absent at fixed block')
            # Empty discovery must still prove that the getter is callable.
            if not inflight_ops:
                call(sp, 'inflightOf(bytes32)', '0x'+'00'*32, widths=(160,256))
            return True
        if 'knownOperations' in config and not discovered <= known:
            for c in ('C6', 'C9'):
                unverified(c, 'STOP: supplied inventory omits chain-derived opHashes')
        else:
            item('C6', lambda: all([call(t, 'creditReservationOf(bytes32,address)', h, u, widths=(128,160))[1] == 0 for h in ops]))
            item('C9', lambda: inflight_supported() and all([call(sp, 'inflightOf(bytes32)', h, widths=(160,256)) == (0,0) for h in inflight_ops]))
        if not ep_evidence['complete']:
            unverified('C9', ep_evidence['reason'])
        if not discovery_complete:
            for c in ('C6', 'C8', 'C9'):
                unverified(c, 'operation/user discovery incomplete')
        if ep_evidence.get('positiveControl', {}).get('result') == 'fail':
            controls['C9'] = {'result': 'fail', 'reason': 'expected EntryPoint opHashes missing'}
        if any(logs.rpc(endpoint, 'eth_getBlockByNumber', [hex(config['block']), False]) != raw_blocks[0] for endpoint in urls):
            raise logs.RpcFailure('fixed block changed')
    except (logs.RpcFailure, ValueError, KeyError, TypeError):
        for i in range(1,10):
            unverified(f'C{i}', 'fixed block or inputs could not be verified')
    out['result'] = 'PASS' if len(controls) == 9 and all(v['result'] == 'pass' for v in controls.values()) else 'FAIL'
    return out


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('rpc-a-file', 'rpc-b-file', 'config', 'out'):
        parser.add_argument('--'+name, required=True)
    args = parser.parse_args()
    urls = [logs.endpoint_file(p)[0] for p in (args.rpc_a_file, args.rpc_b_file)]
    result = check(urls, json.loads(Path(args.config).read_text()))
    Path(args.out).write_text(json.dumps(result, indent=2)+'\n')
    return 0 if result['result'] == 'PASS' else 1

if __name__ == '__main__':
    raise SystemExit(main())
