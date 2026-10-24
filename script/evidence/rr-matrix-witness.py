#!/usr/bin/env python3
"""CC-125 witness gate. Python 3.11, stdlib, isolated local Amsterdam anvil only."""
import gzip
import hashlib
import json
from pathlib import Path
import shlex
import subprocess
import sys
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
import os
# nightly 926eb1d does NOT keep the EIP-8037 reservoir (frame gas uncapped, stateGasReservoir always 0);
# foundry #17719 (in nightly 4e8874b) fixes it. Override with RR_ANVIL.
ENGINE = Path(os.environ.get('RR_ANVIL', Path.home() / 'Dev/aastar/tools/foundry-rams/nightly-4e8874b/anvil'))
OUT = ROOT / 'docs/design/aoa-balance-mode/data/rams-rr-matrix'
URL = 'http://127.0.0.1:18951'
CAP = 2**24


def rpc(method, params):
    body = json.dumps(dict(jsonrpc='2.0', id=1, method=method, params=params)).encode()
    with urllib.request.urlopen(urllib.request.Request(URL, body, {'Content-Type': 'application/json'}), timeout=120) as response:
        value = json.load(response)
    if 'error' in value:
        raise RuntimeError(f'{method}: {value["error"]}')
    return value['result']


def git(*args):
    return subprocess.check_output(['git', *args], cwd=ROOT, text=True).strip()


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    header = dict(engine=subprocess.check_output([str(ENGINE), '--version'], text=True).strip(),
                  repoCommit=git('rev-parse', 'HEAD'), dirtyCount=len(git('status', '--porcelain', '--untracked-files=all').splitlines()),
                  command=shlex.join(['python3.11', 'script/evidence/rr-matrix-witness.py']),
                  scriptSha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest())
    for name in ('witness-results.json', 'witness-failure.json', 'witness-traces.jsonl.gz'):
        (OUT / name).unlink(missing_ok=True)
    command = [str(ENGINE), '--host', '127.0.0.1', '--port', '18951', '--hardfork', 'amsterdam',
               '--gas-limit', '100000000', '--steps-tracing', '--silent']  # without --steps-tracing structLogs are empty
    header['anvilCommand'] = shlex.join(command)
    with (OUT / 'witness-run.log').open('w') as log, (OUT / 'anvil.log').open('w') as engine_log:
        for stream in (log, engine_log):
            stream.write(json.dumps(header) + '\n')
            stream.flush()
        proc = subprocess.Popen(command, stdout=engine_log, stderr=subprocess.STDOUT)
        try:
            for _ in range(100):
                if proc.poll() is not None:
                    raise RuntimeError('anvil exited; see anvil.log')
                try:
                    accounts = rpc('eth_accounts', [])
                    break
                except OSError:
                    time.sleep(0.1)
            else:
                raise RuntimeError('anvil startup timeout')
            rows = []
            # Unroll 1000 fresh SSTOREs. PUSH1 1; PUSH2 slot; SSTORE. No loop ambiguity.
            # Unrolled N fresh SSTOREs (PUSH1 1; PUSH2 slot; SSTORE), swept to find N where R0 fails and RR succeeds.
            def fresh(n):
                return '0x' + (b''.join(bytes.fromhex('600161') + i.to_bytes(2, 'big') + bytes.fromhex('55') for i in range(n)) + b'\x00').hex()
            controls = {'stop': '0x00', **{f'fresh{n}': fresh(n) for n in (50, 200, 500, 1000)}}
            address = '0x' + '0' * 35 + 'cc125'
            # Use exactly 20 bytes (five hex digits in suffix).
            if len(address) != 42:
                raise RuntimeError('bad address')
            with gzip.open(OUT / 'witness-traces.jsonl.gz', 'wt') as traces:
                for name, code in controls.items():
                    rpc('anvil_setCode', [address, code])
                    for regime, limit in [('R0', CAP), ('RR', 30_000_000)]:
                        snapshot = rpc('evm_snapshot', [])
                        try:
                            tx = dict(from_=accounts[0], to=address, gas=hex(limit), gasPrice=hex(2_000_000_000))
                            tx['from'] = tx.pop('from_')
                            tx_hash = rpc('eth_sendTransaction', [tx])
                            # Heavy txs with --steps-tracing are mined after eth_sendTransaction returns: poll.
                            receipt = None
                            for _ in range(240):
                                receipt = rpc('eth_getTransactionReceipt', [tx_hash])
                                if receipt:
                                    break
                                time.sleep(0.25)
                            if not receipt or receipt['transactionHash'] != tx_hash:
                                raise RuntimeError(f'no receipt for {name}-{regime} within 60 s')
                            trace = rpc('debug_traceTransaction', [tx_hash, {'disableMemory': True, 'disableStack': True, 'disableStorage': True}])
                            call = rpc('debug_traceTransaction', [tx_hash, {'tracer': 'callTracer'}])
                            traces.write(json.dumps(dict(cell=f'{name}-{regime}', receipt=receipt, structLogger=trace, callTracer=call)) + '\n')
                            steps = trace.get('structLogs', [])
                            n_slots = int(name[5:]) if name.startswith('fresh') else 1
                            slots = [rpc('eth_getStorageAt', [address, hex(i), 'latest']) for i in [0, n_slots - 1]]
                            row = dict(cell=f'{name}-{regime}', txGasLimit=limit, receipt=receipt,
                                       traceKeys=list(trace), stepKeys=list(steps[0]) if steps else [], callTracer=call,
                                       firstSteps=steps[:4], lastSteps=steps[-4:],
                                       sstoreCount=sum(s.get('op') == 'SSTORE' for s in steps), boundarySlots=slots,
                                       sstoreGasCosts=sorted({s.get('gasCost') for s in steps if s.get('op') == 'SSTORE'}),
                                       callFrameGas=call.get('gas'), callFrameGasUsed=call.get('gasUsed'), callError=call.get('error'))
                            rows.append(row)
                            log.write(json.dumps(row) + '\n')
                            log.flush()
                            print(row['cell'], receipt['status'], int(receipt['gasUsed'], 16), row['traceKeys'], flush=True)
                        finally:
                            if not rpc('evm_revert', [snapshot]):
                                raise RuntimeError('evm_revert failed')
            (OUT / 'witness-results.json').write_text(json.dumps(dict(header=header, rows=rows), indent=2) + '\n')
        except Exception as error:
            failure = dict(header=header, stage='witness gate', completed=False, error=str(error),
                           consumptionWitness='UNDETERMINED', matrixExecuted=False)
            (OUT / 'witness-failure.json').write_text(json.dumps(failure, indent=2) + '\n')
            log.write(json.dumps(failure) + '\n')
            print(str(error), file=sys.stderr)
        finally:
            if proc.poll() is None:
                proc.terminate()
            proc.wait(timeout=10)
    files = sorted(p for p in OUT.rglob('*') if p.is_file() and p.name != 'SHA256SUMS')
    (OUT / 'SHA256SUMS').write_text(''.join(f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.relative_to(OUT)}\n' for p in files))
    return 2 if (OUT / 'witness-failure.json').exists() else 0


if __name__ == '__main__':
    sys.exit(main())
