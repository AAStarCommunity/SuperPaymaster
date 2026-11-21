#!/usr/bin/env python3
"""REHEARSAL probe: gas of plan 0's exact C14 TokenPaymaster creation under several fork rule sets.

For each (upstream file, block, anvil, extra flags, hardfork) it starts a LOCAL anvil fork on 127.0.0.1,
places plan 0's C13 Q / oracle runtimes (the plan's own `code` readback expectations) at their planned
addresses with anvil_setCode, funds the experiment, and sends the byte-identical C14 creation from
the impersonated experiment with a 30M gas limit. Records gasUsed, the callTracer frame gasUsed, the
deployed runtime keccak and the intrinsic part computed from the calldata. URLs are never printed;
anvil output is redacted before it is written.
"""
import sys
sys.dont_write_bytecode = True
import argparse
import hashlib
import json
import re
import subprocess
import threading
import time
import urllib.request
from pathlib import Path
from calibrate import fork_parameters


def rpc_factory(url):
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    def rpc(method, params):
        body = json.dumps(dict(jsonrpc='2.0', id=1, method=method, params=params)).encode()
        with opener.open(urllib.request.Request(url, body, {'Content-Type': 'application/json'}), timeout=300) as r:
            v = json.load(r)
        if 'error' in v: raise RuntimeError(f"{method}: {re.sub(r'(?i)https?://[^ ]+', '<redacted-url>', str(v['error']))}")
        return v['result']
    return rpc


def intrinsic(data_hex):
    data = bytes.fromhex(data_hex[2:])
    zero = data.count(0); nonzero = len(data) - zero
    standard = 21000 + 32000 + 4*zero + 16*nonzero + 2*((len(data)+31)//32)
    floor = 21000 + 10*(zero + 4*nonzero)          # EIP-7623 floor (applies to gasUsed if larger)
    return dict(bytes=len(data), zero=zero, nonZero=nonzero, standardIntrinsic=standard, eip7623Floor=floor)


def case_parameters(case, chain):
    parameters = fork_parameters(chain)
    if case.get('hardfork', parameters['hardfork']) != parameters['hardfork']:
        raise SystemExit('STOP hardfork conflicts with chain mapping')
    flags = case.get('flags', [])
    if any(flag.split('=')[0] in ('--chain-id', '--hardfork', '--optimism', '--no-optimism', '--fork-url', '--host', '--port') for flag in flags):
        raise SystemExit('STOP fork identity flags must come from chain mapping')
    parameters['flags'] += flags
    return parameters


def run_case(case, plan0, log_dir, port):
    expected_chain = plan0['chainId']
    parameters = case_parameters(case, expected_chain)
    upstream = Path(case['upstream']).read_text().strip()
    cmd = [case['anvil'], '--fork-url', upstream, '--port', str(port), '--host', '127.0.0.1', '--no-rate-limit',
           *(['--fork-block-number', str(case['block'])] if case.get('block') else []), *parameters['flags'], '--chain-id', str(expected_chain), '--hardfork', parameters['hardfork']]
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    log = Path(log_dir)/f"anvil.{case['name']}.log"
    def pump():
        with open(log, 'ab') as sink:
            for line in proc.stdout: sink.write(re.sub(rb'(?i)(?:https?|wss?)://\S+', b'<redacted-url>', line))
    threading.Thread(target=pump, daemon=True).start()
    rpc = rpc_factory(f'http://127.0.0.1:{port}')
    try:
        for _ in range(300):
            if proc.poll() is not None: return dict(case=case['name'], error='anvil exited (see redacted log)')
            try: chain = int(rpc('eth_chainId', []), 16); break
            except Exception: time.sleep(0.2)
        else: return dict(case=case['name'], error='anvil did not start')
        if chain != expected_chain: raise SystemExit('STOP fork chainId mismatch')
        head = rpc('eth_getBlockByNumber', ['latest', False])
        step = next(s for s in plan0['steps'] if s['id'] == 'C14')
        for dep in ('C13.token', 'C13.oracle'):
            prior = next(s for s in plan0['steps'] if s['id'] == dep)
            code = next(p for p in prior['target'] if p['kind'] == 'code')
            rpc('anvil_setCode', [code['target'], code['expected']])
        sender = step['tx']['from']
        rpc('anvil_setBalance', [sender, hex(10**21)])
        rpc('anvil_impersonateAccount', [sender])
        tx = {'from': sender, 'data': step['tx']['data'], 'gas': hex(30_000_000)}
        try: estimate = int(rpc('eth_estimateGas', [{'from': sender, 'data': step['tx']['data']}]), 16)
        except RuntimeError as e: estimate = str(e)
        h = rpc('eth_sendTransaction', [tx])
        receipt = None
        for _ in range(600):
            receipt = rpc('eth_getTransactionReceipt', [h])
            if receipt: break
            time.sleep(0.1)
        trace = rpc('debug_traceTransaction', [h, {'tracer': 'callTracer'}])
        created = receipt.get('contractAddress')
        runtime = rpc('eth_getCode', [created, 'latest']) if created else '0x'
        size = (len(runtime) - 2)//2
        res = dict(case=case['name'], chainId=chain, forkBlock=int(head['number'], 16), forkBlockHash=head['hash'],
                   hardfork=parameters['hardfork'], flags=parameters['flags'], anvil=case['anvil'],
                   blockGasLimit=int(head['gasLimit'], 16), status=receipt['status'], gasUsed=int(receipt['gasUsed'], 16),
                   estimate=estimate, frameGasUsed=int(trace.get('gasUsed', '0x0'), 16), frameGas=int(trace.get('gas', '0x0'), 16),
                   runtimeBytes=size, legacyCodeDeposit=200*size,
                   runtimeKeccak=None, intrinsic=intrinsic(step['tx']['data']), forkTx=h)
        if runtime != '0x':
            out = subprocess.run([str(Path.home()/'.foundry/versions/v1.7.1/cast'), 'keccak', runtime], capture_output=True, text=True)
            res['runtimeKeccak'] = out.stdout.strip()
        return res
    finally:
        proc.terminate()
        try: proc.wait(10)
        except subprocess.TimeoutExpired: proc.kill()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--plan', required=True); ap.add_argument('--cases', required=True); ap.add_argument('--out', required=True)
    ap.add_argument('--port', type=int, default=18565)
    args = ap.parse_args()
    bundle = json.loads(Path(args.plan).read_text())
    plan0 = next(p for p in bundle['plans'].values() if p['planIndex'] == 0)
    cases = json.loads(Path(args.cases).read_text())
    results = [run_case(c, plan0, Path(args.out).parent, args.port) for c in cases]
    record = dict(label=f"REHEARSAL ONLY / fork measurement; chainId={plan0['chainId']}; config sha256={plan0['configSha256']}; not for reuse", plan=args.plan,
                  planSha256=hashlib.sha256(Path(args.plan).read_bytes()).hexdigest(), results=results)
    raw = json.dumps(record, indent=2) + '\n'
    if re.search(r'(?i)(?:https?|wss?)://', raw): raise SystemExit('STOP URL in output')
    Path(args.out).write_text(raw)
    for r in results: print(json.dumps({k: r.get(k) for k in ('case', 'status', 'gasUsed', 'estimate', 'frameGasUsed', 'runtimeBytes', 'blockGasLimit', 'runtimeKeccak', 'error')}))


if __name__ == '__main__':
    main()
