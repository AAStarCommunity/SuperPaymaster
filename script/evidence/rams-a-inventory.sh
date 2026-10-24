#!/usr/bin/env bash
# Read-only archive scan. URLs are accepted only from environment and never logged.
# Usage: RAMS_RPC_A=... RAMS_RPC_C=... bash script/evidence/rams-a-inventory.sh [output.json]
set -euo pipefail
python3 - "${1:-docs/design/aoa-balance-mode/data/rams-a/operator-inventory-11974561.json}" <<'PY'
import json, os, sys, time, urllib.request
from datetime import datetime, timezone
from pathlib import Path
SP = '0x09DF0d2e3722EC0e401fE3819E64278a42ae4DE9'
TOPIC = '0x823c9466affb5a8646bc5f7e6304f72a4622cc01af819ec2f51b1130a725c6d1'
first, last = int(os.environ.get('FROM_BLOCK', '11151016')), int(os.environ.get('FORK_BLOCK', '11974561'))
try:
    labels = {key: os.environ.get('RAMS_LABEL_' + key, key) for key in ('A', 'C')}
    if any('://' in value for value in labels.values()):
        raise ValueError('Endpoint labels must be names, never URLs')
    endpoints, before, creation, retries = {}, {}, {}, {}
    for label in ('A', 'C'):
        endpoint = os.environ['RAMS_RPC_' + label]
        def rpc(method, params):
            request = urllib.request.Request(endpoint, json.dumps(dict(jsonrpc='2.0', id=1, method=method, params=params)).encode(), {'Content-Type':'application/json'})
            with urllib.request.urlopen(request, timeout=90) as response:
                body = json.load(response)
            if 'error' in body: raise RuntimeError('RPC request failed')
            return body['result']
        before[label] = rpc('eth_getCode', [SP, hex(first-1)])
        creation[label] = rpc('eth_getCode', [SP, hex(first)])
        if before[label] != '0x' or creation[label] == '0x':
            raise RuntimeError('Creation boundary control failed')
        logs = []
        for lo in range(first, last+1, 2000):
            # Bounded retries per chunk (#529 N2). Any chunk still failing after 3 attempts aborts the scan;
            # the cross-endpoint agreement check stays the completeness argument.
            for attempt in range(3):
                try:
                    logs.extend(rpc('eth_getLogs', [dict(address=SP, topics=[TOPIC], fromBlock=hex(lo), toBlock=hex(min(lo+1999,last))) ]))
                    break
                except Exception:
                    if attempt == 2:
                        raise
                    retries[label] = retries.get(label, 0) + 1
                    time.sleep(2 ** attempt)
        logs.sort(key=lambda x:(int(x['blockNumber'],16), int(x['logIndex'],16)))
        operators = sorted(set('0x'+x['topics'][1][-40:].lower() for x in logs))
        configured = {}
        for operator in operators:
            result = rpc('eth_call', [dict(to=SP, data='0x13e7c9d8'+operator[2:].zfill(64)),hex(last)])
            configured[operator] = bool(int(result[66:130],16))
        endpoints[label] = dict(count=len(logs), ids=[f"{int(x['blockNumber'],16)}:{x['transactionHash']}:{int(x['logIndex'],16)}" for x in logs], operators=[o for o in operators if configured[o]], isConfigured=configured)
    if endpoints['A'] != endpoints['C']: raise RuntimeError('Endpoint disagreement')
    out = dict(generatedUTC=datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'), endpointLabels=labels, note='Read-only; endpoint labels A/C correspond to RAMS_RPC_A/C, provider identities not inferred; URLs omitted',sp=SP,topic=TOPIC,event='OperatorConfigured(address,address,address)',fromBlock=first,toBlock=last,endpoints=endpoints,codeAtFromMinus1=before,codeAtCreation=creation,getLogsRetries=retries,agree=True)
    path = Path(sys.argv[1]); path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(out,indent=2)+'\n')
    print('Inventory written; two endpoints agree; creation positive control passed')
except Exception:
    # Neither transport errors nor RPC responses may disclose endpoint credentials.
    print('Inventory scan failed (details suppressed to protect RPC endpoints)',file=sys.stderr)
    sys.exit(1)
PY
