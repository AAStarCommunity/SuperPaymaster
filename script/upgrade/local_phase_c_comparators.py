#!/usr/bin/env python3
"""Local-anvil check of Phase C comparator rows with real bytecode (no fork, no public chain).

Builds the unit-fixture plan with the real rebuild_baselines() output, installs a locally
compiled v0.7 EntryPoint runtime at the fixture EntryPoint address, then sends the plan's own
C10-C18.mint transactions from the impersonated deployer at their planned nonces (so CREATE
addresses equal the plan's predictions) and evaluates the plan's read-back predicates.
`code` read-backs (runtime derived offline with the MINTER immutable) are enforced exactly;
`codeHash` read-backs depend on the fixture's synthetic runtime pins, so the observed hash is
reported instead. Usage: local_phase_c_comparators.py BASELINES.json ENTRYPOINT_ARTIFACT.json OUT.json
"""
import sys
sys.dont_write_bytecode = True
import json
import subprocess
import time
import urllib.request
from pathlib import Path
from unittest.mock import patch
import test_manifest_exec as t

m, a, u = t.m, t.a, t.u
ROWS = ('C10', 'C11.S', 'C11.R', 'C12', 'C13.token', 'C13.oracle', 'C14', 'C15', 'C16.vpm', 'C16.tpm',
        'C17.vpm', 'C17.tpm', 'C18.mint')
PORT = 8599


def rpc_factory(url):
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    def rpc(method, params):
        body = json.dumps(dict(jsonrpc='2.0', id=1, method=method, params=params)).encode()
        req = urllib.request.Request(url, body, {'Content-Type': 'application/json'})
        reply = json.loads(opener.open(req, timeout=30).read())
        a.need('local_rpc_error', reply.get('error'), None)
        return reply['result']
    rpc.local = True
    return rpc


def mined(rpc, txhash):
    for _ in range(200):
        r = rpc('eth_getTransactionReceipt', [txhash])
        if r is not None:
            return r
        time.sleep(0.05)
    raise a.Gate('local_receipt_timeout', txhash, 'mined receipt')


def main(baselines, entrypoint, out):
    real = json.loads(Path(baselines).read_text())
    commits = {k: v['commit'] for k, v in real.items()}
    # The fixture release commit is synthetic; the real archive commit is recorded below.
    t.BASELINES = {k: dict(v, commit=t.ART['commit']) for k, v in real.items()}
    case = t.ManifestTests('test_determinism')
    case.setUp()
    plan = case.plan
    ep = plan['pin']['immutables']['entryPoint']
    engine = subprocess.Popen([str(a.ENGINE/'anvil'), '--port', str(PORT), '--silent'])
    try:
        rpc = rpc_factory('http://127.0.0.1:%d' % PORT)
        for _ in range(100):
            try:
                ready = int(rpc('eth_chainId', []), 16) > 0
                break
            except OSError:
                # Only a refused/reset connection while anvil starts is retried.
                ready = False
                time.sleep(0.1)
        a.need('local_engine_ready', ready, True)
        anvil0 = rpc('eth_accounts', [])[0]
        art = json.loads(Path(entrypoint).read_text())
        h = rpc('eth_sendTransaction', [dict(**{'from': anvil0}, data=art['bytecode']['object'], gas=hex(30_000_000))])
        deployed = mined(rpc, h)['contractAddress']
        rpc('anvil_setCode', [ep, rpc('eth_getCode', [deployed, 'latest'])])
        D = u.DEPLOYER
        rpc('anvil_impersonateAccount', [D])
        rpc('anvil_setBalance', [D, hex(10**24)])
        records = []
        for sid in ROWS:
            step = next(s for s in plan['steps'] if s['id'] == sid)
            tx = step['tx']
            rpc('anvil_setNonce', [D, tx['nonce']])
            send = {k: v for k, v in tx.items() if k in ('from', 'data', 'value', 'nonce')}
            if tx['to'] is not None:
                send['to'] = tx['to']
            send['gas'] = hex(15_000_000)
            r = mined(rpc, rpc('eth_sendTransaction', [send]))
            a.need('local_status_'+sid, r['status'], '0x1')
            if step['tx']['to'] is None:
                a.need('local_create_address_'+sid, r['contractAddress'].lower(), step['creates'])
            stamp = int(rpc('eth_getBlockByNumber', [r['blockNumber'], False])['timestamp'], 16)
            observed = []
            for pred in step['readbacks']:
                if pred['kind'] == 'codeHash':
                    observed.append(dict(kind='codeHash', target=pred['target'],
                        observed=a.keccak(rpc('eth_getCode', [pred['target'], 'latest'])), enforced=False))
                else:
                    observed.append(dict(pred=pred.get('signature', pred['kind']), value=m.check_predicate(rpc, pred, stamp), enforced=True))
            records.append(dict(step=sid, gasUsed=int(r['gasUsed'], 16), readbacks=observed))
        result = dict(status='PASS', baselineCommits=commits, scope='local anvil, no fork; comparator rows C10-C18.mint', rows=list(ROWS),
                      baselines={k: {x: v[x] for x in v if x not in ('bytecode', 'runtimeIdentity')} for k, v in t.BASELINES.items()},
                      steps=records)
        Path(out).write_text(json.dumps(result, indent=1, default=str)+'\n')
        print('LOCAL_PHASE_C_COMPARATORS PASS', len(records))
    finally:
        engine.terminate()
        engine.wait()


if __name__ == '__main__':
    main(*sys.argv[1:4])
