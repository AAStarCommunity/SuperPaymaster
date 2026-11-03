#!/usr/bin/env python3
"""Offline realistic ABI/RPC controls for all nine state assertions."""
import copy
import io
import json
import unittest
from pathlib import Path
from unittest.mock import patch
import a4_state_check as m
import test_a4_credit_logscan as fixture

T, U, H = fixture.TOKEN, fixture.USER, fixture.OP
F, I, E, SP, D = ['0x'+v*40 for v in '56789']
RUNTIME = '0x363d3d373d3d3d363d73'+I[2:]+'5af43d82803e903d91602b57fd5bf3'

def abi(*values):
    return '0x'+''.join(f'{int(v,16) if isinstance(v,str) else v:064x}' for v in values)


def config():
    return dict(token=T,user=U,sp=SP,community=D,block=8,deployBlock=2,
                inflightStart=dict(block=2, blockHash=fixture.bh(2), source="sp-proxy-deploy"),
                pins=dict(factory=F,implementation=I,extension=E,
                          factoryCodehash=m.cast('keccak','0x6000'),
                          implementationCodehash=m.cast('keccak','0x6001'),extensionCodehash=m.cast('keccak','0x6002')),
                knownOperations=dict(source='reviewed pre-window inventory',opHashes=[H]))


class Provider(fixture.Endpoint):
    def __init__(self, events=()):
        super().__init__(events)
        self.cfg=config()
        self.values={
            'entryPoint()':abi(m.ENTRY_POINT_V07),'FACTORY()':abi(F),'EXTENSION()':abi(E),'implementation()':abi(I),
            'implementationCodehash()':abi(self.cfg['pins']['implementationCodehash']),
            'extensionCodehash()':abi(self.cfg['pins']['extensionCodehash']),
            'getTokenAddress(address)':abi(T),'isXPNTs(address)':abi(1),
            'creditPolicy()':abi(0),'hasPendingPolicy()':abi(0),
            'creditReservedOf(address)':abi(0),'creditReservationOf(bytes32,address)':abi(0,0),
            'debts(address)':abi(0),'inflightOf(bytes32)':abi(0,0)}
        self.runtime=RUNTIME
        self.sp_runtime='0x63'+m.cast('sig', 'inflightOf(bytes32)')[2:]+'00'
        self.sp_implementation=abi(0)
        self.fail=None
    def __call__(self, method, params):
        if method=='eth_call':
            historical_ep = params[0]['data'] == m.cast('sig', 'entryPoint()')
            if not historical_ep and params[1] != {'blockHash':fixture.bh(8),'requireCanonical':True}:
                raise AssertionError('not hash pinned')
            sig=next(s for s in self.values if m.cast('sig',s)==params[0]['data'][:10])
            if self.fail==sig:
                raise m.logs.RpcFailure('unavailable')
            return self.values[sig]
        if method=='eth_getStorageAt':
            if params[2] != {'blockHash':fixture.bh(8),'requireCanonical':True}:
                raise AssertionError('storage not hash pinned')
            return self.sp_implementation
        if method=='eth_getCode' and isinstance(params[1],dict):
            return {SP:self.sp_runtime,T:self.runtime,F:'0x6000',I:'0x6001',E:'0x6002'}[params[0]]
        try:
            return super().__call__(method,params)
        except fixture.m.RpcFailure:
            raise m.logs.RpcFailure("unavailable") from None


def run(events=(), a=None, b=None):
    a=a or Provider(events); b=b or Provider(events)
    with patch.object(m.logs,'rpc',lambda url,method,params: {'A':a,'B':b}[url](method,params)):
        return m.check(['A','B'],config())


class StateControls(unittest.TestCase):
    def negative(self, c, sig, value):
        a,b=Provider(),Provider()
        a.values[sig]=b.values[sig]=value
        self.assertEqual(run(a=a,b=b)['controls'][c]['result'],'fail')
    def test_all_positive(self):
        out=run([fixture.event('R'),fixture.event('L',n=4)])
        self.assertEqual(out['controls']['C6']['result'],'pass')
        self.assertEqual(out['controls']['C9']['result'],'pass')
        self.assertEqual(out['subject'],dict(blockNumber=8,blockHash=fixture.bh(8)))
        self.assertEqual(out['opHashSet']['opHashes'],[H])
    def inventory_run(self, events=(), inventory=None, include=True, a=None, b=None):
        cfg = config()
        if include:
            cfg['knownOperations']['opHashes'] = [] if inventory is None else inventory
        else:
            del cfg['knownOperations']
        a, b = a or Provider(events), b or Provider(events)
        with patch.object(m.logs, 'rpc', lambda url, method, params: {'A': a, 'B': b}[url](method, params)):
            return m.check(['A', 'B'], cfg)

    def discovery_event(self, name, op=H):
        # Independent ABI signatures, checked against the actual Solidity declarations.
        signatures = {
            'LockCreated': ('LockCreated(address,bytes32,address,uint256,uint256)', 4, 2),
            'LockSettled': ('LockSettled(address,bytes32,uint256,uint256)', 3, 2),
            'LockReleased': ('LockReleased(address,bytes32,uint256)', 3, 1),
            'SponsorshipReleased': ('SponsorshipReleased(bytes32,address,uint256)', 3, 1),
            'ValidationFailed': ('ValidationFailed(bytes32,bytes32)', 2, 1),
        }
        sig, nt, words = signatures[name]
        row = fixture.event('R')
        token = name.startswith('Lock')
        row['address'] = T if token else SP
        row['topics'] = [m.cast('keccak', sig)] + (['0x'+m.word(U), op] if token else [op])
        if len(row['topics']) < nt: row['topics'].append('0x'+m.word(SP))
        row['data'] = abi(*([0]*words))
        return row

    def test_inventory_omissions_stop(self):
        for name in ('credit', 'LockCreated', 'LockSettled', 'LockReleased', 'SponsorshipReleased', 'ValidationFailed'):
            row = fixture.event('R') if name == 'credit' else self.discovery_event(name)
            for supplied in ([], ['0x'+'aa'*32]):
                with self.subTest(event=name, supplied=supplied):
                    out = self.inventory_run([row], supplied)
                    self.assertIn(H, out['opHashSet']['discovered'])
                    self.assertEqual(out['controls']['C6']['result'], 'unverified')
                    self.assertIn('STOP', out['controls']['C9']['reason'])

    def test_inventory_chain_only_and_additions(self):
        row = self.discovery_event('LockCreated')
        for include in (False, True):
            out = self.inventory_run([row], [H, '0x'+'aa'*32], include=include)
            self.assertEqual(out['controls']['C6']['result'], 'pass')
            self.assertIn(H, out['opHashSet']['opHashes'])
            self.assertEqual(out['discovery']['locks']['eventCounts']['LockCreated'], 1)
            self.assertTrue(out['discovery']['complete'])

    def test_inventory_empty_full_range(self):
        out = self.inventory_run()
        self.assertEqual(out['controls']['C6']['result'], 'pass')
        for kind in ('credit', 'locks', 'sp'):
            scan = out['discovery'][kind]
            self.assertEqual((scan['fromBlock'], scan['toBlock'], scan['complete']), (2, 8, True))
            self.assertEqual(sum(scan['eventCounts'].values()), 0)

    def test_inventory_partial_scan_blocks(self):
        class Missing(Provider):
            def __call__(self, method, params):
                if method == 'eth_getLogs' and (params[0]['address'] == SP or
                        m.cast('keccak', 'LockCreated(address,bytes32,address,uint256,uint256)') in params[0]['topics'][0]):
                    raise m.logs.RpcFailure('missing discovery')
                return super().__call__(method, params)
        out = self.inventory_run(a=Missing())
        self.assertEqual(out['controls']['C6']['result'], 'unverified')
        self.assertFalse(out['discovery']['complete'])

    def ep_event(self, paymaster=SP, op=H, ep=m.ENTRY_POINT_V07):
        row = fixture.event('R', token=ep)
        row['topics'] = [m.cast('keccak', 'UserOperationEvent(bytes32,address,address,uint256,bool,uint256,uint256)'),
                         op, '0x'+m.word(U), '0x'+m.word(paymaster)]
        row['data'] = abi(0, 1, 0, 0)
        return row

    def test_expected_entrypoint_hits(self):
        expected = [H] + ['0x'+f'{i:064x}' for i in range(1, 9)]
        extra = '0x'+'cd'*32
        rows = [dict(self.ep_event(op=h), logIndex=hex(i)) for i, h in enumerate(expected + [extra])]
        cfg = config()
        cfg['expectedEntryPointHits'] = dict(head=8, opHashes=expected)
        out = self.configured_run(cfg, Provider(rows), Provider(rows))
        evidence = out['discovery']['entryPoint']
        self.assertEqual(out['controls']['C9']['result'], 'pass')
        self.assertEqual(evidence['positiveControl']['missing'], [])
        self.assertEqual(evidence['newHits'], [dict(opHash=extra, blockNumber=3)])
        self.assertEqual(evidence['scan']['chunkSize'], 50000)
        self.assertIn('per-block coverage is NOT claimed', out['coverage'])
        for missing in expected:
            remaining = [r for r in rows if r['topics'][1] != missing]
            out = self.configured_run(cfg, Provider(remaining), Provider(remaining))
            self.assertEqual(out['controls']['C9']['result'], 'fail')
            self.assertEqual(out['discovery']['entryPoint']['positiveControl']['missing'], [missing])

    def test_expected_entrypoint_head(self):
        for head in (1, 9, '8', True):
            cfg = config(); cfg['expectedEntryPointHits'] = dict(head=head, opHashes=[H])
            self.assertEqual(self.configured_run(cfg)['controls']['C9']['result'], 'unverified')
        cfg = config(); cfg['expectedEntryPointHits'] = dict(head=2, opHashes=[H])
        row = self.ep_event()
        self.assertEqual(self.configured_run(cfg, Provider([row]), Provider([row]))['controls']['C9']['result'], 'fail')

    def sepolia_entrypoint_fixture(self):
        path = Path(__file__).with_name('fixtures') / 'c9-entrypoint-hits-sepolia.json'
        expected = json.loads(path.read_text())
        self.assertEqual(len(expected['hits']), 9)
        cfg = dict(block=expected['head'], entryPoint=expected['entryPoint'],
                   expectedEntryPointHits=dict(head=expected['head'],
                                              opHashes=[h['opHash'] for h in expected['hits']]))
        rows = []
        for hit in expected['hits']:
            row = self.ep_event(paymaster=expected['paymaster'].lower(), op=hit['opHash'],
                                ep=expected['entryPoint'].lower())
            row.update(blockNumber=hex(hit['block']), blockHash=fixture.bh(hit['block']),
                       transactionHash='0x'+fixture.word(hit['block'] * 100))
            rows.append(row)
        return expected, cfg, rows

    def sepolia_entrypoint_scan(self, expected, cfg, rows):
        providers = {'A': Provider(rows), 'B': Provider(rows)}
        for provider in providers.values():
            provider.finalized = expected['head']
            provider.chain = hex(expected['chainId'])
            provider.max_range = 50000
        with patch.object(m.logs, 'rpc', lambda url, method, params: providers[url](method, params)):
            evidence, found = m.discover_inflight(
                ['A', 'B'], cfg, expected['paymaster'].lower(),
                fixture.bh(expected['head']), expected['fromBlock'])
        self.assertTrue(evidence['complete'], evidence.get('reason'))
        for provider in providers.values():
            self.assertTrue(any(method == 'eth_getLogs' and
                                params[0]['address'] == expected['entryPoint'].lower()
                                for method, params in provider.calls))
        return evidence, found

    def test_sepolia_expected_entrypoint_hits_pass(self):
        expected, cfg, rows = self.sepolia_entrypoint_fixture()
        evidence, found = self.sepolia_entrypoint_scan(expected, cfg, rows)
        self.assertEqual(evidence['positiveControl']['result'], 'pass')
        self.assertEqual(evidence['positiveControl']['missing'], [])
        self.assertEqual(evidence['newHits'], [])
        self.assertEqual(found, set(cfg['expectedEntryPointHits']['opHashes']))
        self.assertCountEqual(
            [(row['topics'][1], row['blockNumber']) for row in evidence['scan']['logs']],
            [(hit['opHash'], hit['block']) for hit in expected['hits']])

    def test_sepolia_expected_entrypoint_hit_missing(self):
        expected, cfg, rows = self.sepolia_entrypoint_fixture()
        evidence, found = self.sepolia_entrypoint_scan(expected, cfg, rows[:-1])
        self.assertEqual(len(found), 8)
        self.assertEqual(evidence['positiveControl']['result'], 'fail')
        self.assertEqual(evidence['positiveControl']['missing'], [expected['hits'][-1]['opHash']])
        self.assertEqual(evidence['newHits'], [])

    def test_sepolia_expected_entrypoint_new_hit(self):
        expected, cfg, rows = self.sepolia_entrypoint_fixture()
        extra = '0x'+'cd'*32
        rows.append(dict(rows[-1], topics=[rows[-1]['topics'][0], extra, *rows[-1]['topics'][2:]],
                         blockNumber=hex(expected['head']), blockHash=fixture.bh(expected['head']),
                         transactionHash='0x'+fixture.word(expected['head'] * 100)))
        evidence, found = self.sepolia_entrypoint_scan(expected, cfg, rows)
        self.assertEqual(len(found), 10)
        self.assertEqual(evidence['positiveControl']['result'], 'pass')
        self.assertEqual(evidence['positiveControl']['missing'], [])
        self.assertEqual(evidence['newHits'], [dict(opHash=extra, blockNumber=expected['head'])])

    def test_inflight_implementation_absent(self):
        for with_hits in (False, True):
            for mode in ('absent', 'revert', 'proxy_old'):
                a, b = Provider([self.ep_event()] if with_hits else []), Provider([self.ep_event()] if with_hits else [])
                for provider in (a, b):
                    if mode == 'absent': provider.sp_runtime = '0x6000'
                    if mode == 'revert': provider.fail = 'inflightOf(bytes32)'
                    if mode == 'proxy_old': provider.sp_implementation = abi(I)
                cfg = config(); cfg.pop('knownOperations')
                out = self.configured_run(cfg, a, b)
                self.assertEqual(out['controls']['C9']['result'], 'unverified', mode)

    def test_state_rpc_recording(self):
        cfg = config(); cfg.update(rpcMinInterval=0, rpcMaxRetries=1)
        hashes = [H, '0x'+'ab'*32]
        rows = [dict(self.ep_event(op=h), logIndex=hex(i)) for i,h in enumerate(hashes)]
        providers = {'https://a': Provider(rows), 'https://b': Provider(rows)}
        def transport(req, timeout):
            request = json.loads(req.data)
            result = providers[req.full_url](request['method'], request['params'])
            return io.StringIO(json.dumps(dict(jsonrpc='2.0', id=1, result=result)))
        with patch.object(m.logs.urllib.request, 'urlopen', side_effect=transport):
            out = m.check(list(providers), cfg)
        self.assertEqual(out['result'], 'PASS')
        self.assertEqual(out['rpcPolicy'], dict(minInterval=0, maxRetries=1))
        self.assertTrue(out['rpcCalls'])
        self.assertTrue(out['discovery']['entryPoint']['scan']['rpcCalls'])
        reads = [r for r in out['reads'] if r['method'] == 'eth_call' and
                 r['params'][0]['data'].startswith(m.cast('sig','inflightOf(bytes32)'))]
        self.assertEqual({r['params'][0]['data'][10:] for r in reads}, {h[2:] for h in hashes})
        self.assertNotIn('https://', json.dumps(out))

    def test_inflight_proxy_supported(self):
        class Proxy(Provider):
            def __call__(self, method, params):
                if method == 'eth_getCode' and params[0] == D and isinstance(params[1], dict):
                    return self.sp_runtime
                return super().__call__(method, params)
        a, b = Proxy([self.ep_event()]), Proxy([self.ep_event()])
        a.sp_implementation = b.sp_implementation = abi(D)
        out = self.configured_run(config(), a, b)
        self.assertEqual(out['controls']['C9']['result'], 'pass')
        calls = [r for r in out['reads'] if r['method'] == 'eth_call' and
                 r['params'][0]['data'].startswith(m.cast('sig', 'inflightOf(bytes32)'))]
        self.assertTrue(calls)
        self.assertTrue(all(r['params'][1]['blockHash'] == fixture.bh(8) for r in calls))

    def test_ep_discovered_nonzero(self):
        row = self.ep_event(op='0x'+'ab'*32)
        a, b = Provider([row]), Provider([row])
        a.values['inflightOf(bytes32)'] = b.values['inflightOf(bytes32)'] = abi(SP, 1)
        out = self.inventory_run(include=False, a=a, b=b)
        self.assertEqual(out['controls']['C9']['result'], 'fail')
        self.assertEqual(out['inflightHashSet']['entryPointDiscovered'], [row['topics'][1]])

    def test_ep_empty_pass(self):
        out = self.inventory_run()
        self.assertEqual(out['controls']['C9']['result'], 'pass')
        self.assertEqual(out['inflightHashSet']['opHashes'], [])
        self.assertTrue(out['discovery']['entryPoint']['complete'])

    def test_ep_incomplete(self):
        class Missing(Provider):
            def __call__(self, method, params):
                if method == 'eth_getLogs' and params[0]['address'] == m.ENTRY_POINT_V07:
                    raise m.logs.RpcFailure('missing EntryPoint history')
                return super().__call__(method, params)
        for endpoint in ('a', 'b'):
            with self.subTest(endpoint=endpoint):
                out = self.inventory_run(**{endpoint: Missing()})
                self.assertEqual(out['controls']['C9']['result'], 'unverified')

    def test_ep_foreign_paymaster(self):
        row = self.ep_event(paymaster=E)
        a, b = Provider([row]), Provider([row])
        a.values['inflightOf(bytes32)'] = b.values['inflightOf(bytes32)'] = abi(SP, 1)
        out = self.inventory_run(a=a, b=b)
        self.assertEqual(out['controls']['C9']['result'], 'pass')
        self.assertEqual(out['inflightHashSet']['entryPointDiscovered'], [])

    def test_ep_start_pin(self):
        for start in (None, {}, {'block': 2, 'source': 'inflight-upgrade'},
                      {'block': 2, 'source': 'unknown', 'blockHash': fixture.bh(2)},
                      {'block': 2, 'source': 'inflight-upgrade', 'blockHash': fixture.bh(99)}):
            cfg = config(); cfg['inflightStart'] = start
            with self.subTest(start=start):
                # Adapt the endpoint fixture to the public RPC signature.
                provider = Provider()
                with patch.object(m.logs, 'rpc', lambda url, method, params: provider(method, params)):
                    out = m.check(['A', 'B'], cfg)
            self.assertEqual(out['controls']['C9']['result'], 'unverified')

    def test_ep_configured_range_and_address(self):
        cfg = config()
        cfg['entryPoint'] = E
        cfg['inflightStart'] = dict(block=1, blockHash=fixture.bh(1), source='inflight-upgrade')
        row = self.ep_event(ep=E)
        row.update(blockNumber='0x1', blockHash=fixture.bh(1))
        a, b = Provider([row]), Provider([row])
        a.values['entryPoint()'] = b.values['entryPoint()'] = abi(E)
        a.max_range = b.max_range = 2
        with patch.object(m.logs, 'rpc', lambda url, method, params: {'A': a, 'B': b}[url](method, params)):
            out = m.check(['A', 'B'], cfg)
        scan = out['discovery']['entryPoint']['scan']
        self.assertEqual(out['controls']['C9']['result'], 'pass')
        self.assertEqual(out['inflightHashSet']['entryPointDiscovered'], [H])
        self.assertEqual((scan['fromBlock'], scan['toBlock']), (1, 8))
        self.assertTrue(any(c['status'] == 'rpc error; shrinking' for c in scan['chunks']))

    def test_ep_caller_additions(self):
        extra = '0x'+'ab'*32
        out = self.inventory_run([self.ep_event()], [extra])
        self.assertEqual(out['controls']['C9']['result'], 'pass')
        self.assertEqual(set(out['inflightHashSet']['opHashes']), {H, extra})

    def test_ep_receipt_omission(self):
        # The empty-block sample for [2, 8] with B=bh(8) is block 2.
        row = dict(self.ep_event(), blockNumber='0x2', blockHash=fixture.bh(2))
        class Truncated(Provider):
            def __call__(self, method, params):
                if method == 'eth_getLogs' and params[0]['address'] == m.ENTRY_POINT_V07:
                    return []
                return super().__call__(method, params)
        out = self.inventory_run(a=Truncated([row]), b=Truncated([row]))
        self.assertEqual(out['controls']['C9']['result'], 'unverified')

    def configured_run(self, cfg, a=None, b=None):
        a, b = a or Provider(), b or Provider()
        with patch.object(m.logs, 'rpc', lambda url, method, params: {'A': a, 'B': b}[url](method, params)):
            return m.check(['A', 'B'], cfg)

    def test_late_sp_start(self):
        cfg = config(); cfg.pop('knownOperations')
        cfg['inflightStart'].update(block=4, blockHash=fixture.bh(4))
        a, b = Provider([self.ep_event()]), Provider([self.ep_event()])
        a.values['inflightOf(bytes32)'] = b.values['inflightOf(bytes32)'] = abi(SP, 1)
        self.assertEqual(self.configured_run(cfg, a, b)['controls']['C9']['result'], 'unverified')

    def test_late_token_start(self):
        cfg = config(); cfg.pop('knownOperations'); cfg['deployBlock'] = 4
        for row in (fixture.event('R'), self.discovery_event('LockCreated')):
            a, b = Provider([row]), Provider([row])
            a.values['creditReservationOf(bytes32,address)'] = b.values['creditReservationOf(bytes32,address)'] = abi(0, SP)
            self.assertEqual(self.configured_run(cfg, a, b)['controls']['C6']['result'], 'unverified')

    def test_creation_evidence(self):
        cfg = config(); cfg.pop('inflightStart'); cfg.pop('deployBlock')
        out = self.configured_run(cfg)
        self.assertEqual(out['result'], 'PASS')
        self.assertEqual(out['derivedBlocks'], {'token': 2, 'sp': 2})
        cfg.update(tokenCreationLowerBound=1, spCreationLowerBound=2, deployBlock=1)
        self.assertEqual(self.configured_run(cfg)['result'], 'PASS')

    def test_independent_creation_blocks(self):
        class LaterToken(Provider):
            def __call__(self, method, params):
                if method == 'eth_getCode' and params[0] == T and isinstance(params[1], str):
                    return '0x6000' if int(params[1], 16) >= 5 else '0x'
                return super().__call__(method, params)
        cfg = config(); cfg['deployBlock'] = 5; cfg.pop('knownOperations')
        row = self.discovery_event('SponsorshipReleased')
        a, b = LaterToken([row]), LaterToken([row])
        a.values['inflightOf(bytes32)'] = b.values['inflightOf(bytes32)'] = abi(SP, 1)
        out = self.configured_run(cfg, a, b)
        self.assertEqual(out['derivedBlocks'], {'token': 5, 'sp': 2})
        self.assertEqual(out['controls']['C9']['result'], 'fail')
        self.assertEqual(out['opHashSet']['discovered'], [H])

    def test_creation_archive_and_disagreement(self):
        for address in (T, SP):
            for mode in ('gap', 'disagree', 'both_gap'):
                class Broken(Provider):
                    def __call__(self, method, params):
                        if method == 'eth_getCode' and params == [address, '0x4']:
                            if mode != 'disagree': raise m.logs.RpcFailure('archive gap')
                            return '0x6001'
                        return super().__call__(method, params)
                out = self.configured_run(config(), Broken() if mode == 'both_gap' else Provider(), Broken())
                self.assertEqual(out['controls']['C9']['result'], 'unverified')
                self.assertEqual(out['controls']['C6']['result'], 'unverified')

    def test_creation_boundary(self):
        cfg = config(); cfg['spCreationLowerBound'] = 3
        self.assertEqual(self.configured_run(cfg)['controls']['C9']['result'], 'unverified')

    def test_ep_substitution(self):
        cfg = config(); cfg['entryPoint'] = E; cfg.pop('knownOperations')
        self.assertEqual(self.configured_run(cfg, Provider([self.ep_event()]), Provider([self.ep_event()]))['controls']['C9']['result'], 'unverified')

    def upgrade_event(self):
        row = fixture.event('R', n=4, token=SP)
        row.update(topics=[m.cast('keccak', 'Upgraded(address)'), abi(I)], data='0x')
        return row

    def test_ep_binding_history(self):
        for n in (2, 4, 8):
            for endpoints in ('A', 'B', 'AB'):
                class Changed(Provider):
                    def __call__(self, method, params):
                        if method == 'eth_call' and params[0]['data'] == m.cast('sig', 'entryPoint()') and params[1]['blockHash'] == fixture.bh(n):
                            return abi(E)
                        return super().__call__(method, params)
                a = Changed([self.upgrade_event()]) if 'A' in endpoints else Provider([self.upgrade_event()])
                b = Changed([self.upgrade_event()]) if 'B' in endpoints else Provider([self.upgrade_event()])
                self.assertEqual(self.configured_run(config(), a, b)['controls']['C9']['result'], 'unverified')

    def test_ep_upgrade_positive(self):
        a, b = Provider([self.upgrade_event()]), Provider([self.upgrade_event()])
        a.max_range = b.max_range = 2
        out = self.configured_run(config(), a, b)
        self.assertEqual(out['result'], 'PASS')
        self.assertEqual([v['block'] for v in out['discovery']['entryPoint']['bindings']], [2, 4, 8])

    def test_upgrade_receipt_omission(self):
        row = dict(self.upgrade_event(), blockNumber='0x2', blockHash=fixture.bh(2))
        class Missing(Provider):
            def __call__(self, method, params):
                if method == 'eth_getLogs' and params[0]['address'] == SP: return []
                return super().__call__(method, params)
        self.assertEqual(self.configured_run(config(), Missing([row]), Missing([row]))['controls']['C9']['result'], 'unverified')

    def test_ep_hex_case(self):
        for row in (self.ep_event(op='0x'+'ab'*32), self.upgrade_event()):
            row = dict(row, blockNumber='0x2', blockHash=fixture.bh(2))
            for omitted in (False, True):
                class Upper(Provider):
                    def __call__(self, method, params):
                        if omitted and method == 'eth_getLogs': return []
                        result = super().__call__(method, params)
                        if method == 'eth_getBlockReceipts':
                            for receipt in result:
                                for log in receipt['logs']:
                                    for key in ('address', 'data'): log[key] = '0x'+log[key][2:].upper()
                                    log['topics'] = ['0x'+t[2:].upper() for t in log['topics']]
                        return result
                out = self.configured_run(config(), Upper([row]), Upper([row]))
                self.assertEqual(out['controls']['C9']['result'], 'unverified' if omitted else 'pass')

    def test_lock_discovers_nonzero_state(self):
        row = self.discovery_event('LockCreated')
        a, b = Provider([row]), Provider([row])
        a.values['creditReservationOf(bytes32,address)'] = b.values['creditReservationOf(bytes32,address)'] = abi(0, SP)
        a.values['inflightOf(bytes32)'] = b.values['inflightOf(bytes32)'] = abi(SP, 1)
        out = self.inventory_run(include=False, a=a, b=b)
        self.assertEqual(out['controls']['C6']['result'], 'fail')
        self.assertEqual(out['controls']['C9']['result'], 'fail')

    def test_c1_wrong_implementation(self):
        a,b=Provider(),Provider(); a.runtime=b.runtime=RUNTIME.replace(I[2:],E[2:])
        self.assertEqual(run(a=a,b=b)['controls']['C1']['result'],'fail')
    def test_c1_factory_binding(self):
        self.negative('C1','getTokenAddress(address)',abi(E))
    def test_c2_policy_on(self):
        self.negative('C2','creditPolicy()',abi(2))
    def test_c3_queued(self):
        self.negative('C3','hasPendingPolicy()',abi(1))
    def test_c4_ever_on(self):
        self.assertEqual(run([fixture.event('P',value=2)])['controls']['C4']['result'],'fail')
    def test_c5_reserved(self):
        self.negative('C5','creditReservedOf(address)',abi(1))
    def test_c6_zero_amount_record(self):
        self.negative('C6','creditReservationOf(bytes32,address)',abi(0,SP))
    def test_c7_reopened(self):
        self.assertEqual(run([fixture.event(k,n=i+3) for i,k in enumerate('RLR')])['controls']['C7']['result'],'fail')
    def test_c8_debt(self):
        self.negative('C8','debts(address)',abi(1))
    def test_c8_other_user(self):
        other='0x'+'aa'*20
        a,b=Provider([fixture.event('R',user=other),fixture.event('L',n=4,user=other)]),Provider([fixture.event('R',user=other),fixture.event('L',n=4,user=other)])
        calls=[]
        def rpc(url,method,params):
            if method=='eth_call' and params[0]['data']==m.cast('sig','debts(address)')+m.word(other):
                calls.append(url); return abi(1)
            return {'A':a,'B':b}[url](method,params)
        with patch.object(m.logs,'rpc',rpc): out=m.check(['A','B'],config())
        self.assertEqual((out['controls']['C8']['result'],calls),('fail',['A','B']))
    def test_c9_inflight(self):
        self.negative('C9','inflightOf(bytes32)',abi(SP,0))
        self.negative('C9','inflightOf(bytes32)',abi(0,1))
    def test_each_getter_unavailable(self):
        for sig in Provider().values:
            a=Provider(); a.fail=sig
            with self.subTest(sig=sig): self.assertEqual(run(a=a)['result'],'FAIL')
    def test_each_getter_disagreement(self):
        for sig in Provider().values:
            b=Provider(); b.values[sig]='0x'
            with self.subTest(sig=sig): self.assertEqual(run(b=b)['result'],'FAIL')
    def test_fixed_block_disagreement(self):
        b=Provider(); b.bad_hash=8
        self.assertTrue(all(v['result']=='unverified' for v in run(b=b)['controls'].values()))
    def test_fixed_block_drift(self):
        class Drifting(Provider):
            def __call__(self,method,params):
                result=super().__call__(method,params)
                if method=='eth_getBlockByNumber' and params[0]=='0x8':
                    count=sum(k==method and p[0]=='0x8' for k,p in self.calls)
                    if count>=3: result['hash']=fixture.bh(999)
                return result
        self.assertEqual(run(a=Drifting(),b=Drifting())['result'],'FAIL')

    def test_read_bytes_must_agree(self):
        b=Provider()
        b.values['FACTORY()']=b.values['FACTORY()'].replace('0x','0X')
        self.assertEqual(run(b=b)['controls']['C1']['result'],'unverified')

    def test_history_unavailable(self):
        b=Provider(); b.archive=False
        out=run(b=b)
        self.assertTrue(all(out['controls'][c]['result']=='unverified' for c in ('C4','C6','C7','C8','C9')))
    def test_malformed_abi(self):
        for sig,value,c in [('creditPolicy()',abi(256),'C2'),('hasPendingPolicy()',abi(2),'C3'),('creditReservationOf(bytes32,address)',abi(0),'C6')]:
            a,b=Provider(),Provider(); a.values[sig]=b.values[sig]=value
            self.assertEqual(run(a=a,b=b)['controls'][c]['result'],'unverified')

if __name__=='__main__': unittest.main()
