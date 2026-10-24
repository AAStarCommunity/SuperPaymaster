#!/usr/bin/env python3
"""Read-only: the archive node's debug_traceTransaction of a real Sepolia RR tx (first steps + top-level fields).
Usage: RPC_FILE=<file> python3 rr-chain-trace.py <txhash> <out.json>. The URL is never printed."""
import json, os, sys, urllib.request
url = open(os.environ["RPC_FILE"]).read().strip()
def rpc(m, p):
    r = json.loads(urllib.request.urlopen(urllib.request.Request(url, json.dumps({"jsonrpc": "2.0", "id": 1, "method": m, "params": p}).encode(), {"Content-Type": "application/json"}), timeout=300).read())
    if "error" in r: raise SystemExit(f"{m}: {r['error'].get('code')}")
    return r["result"]
h, out = sys.argv[1], sys.argv[2]
tx = rpc("eth_getTransactionByHash", [h]); rc = rpc("eth_getTransactionReceipt", [h])
sl = rpc("debug_traceTransaction", [h, {"disableMemory": True, "disableStack": True, "disableStorage": True, "limit": 5}])
ct = rpc("debug_traceTransaction", [h, {"tracer": "callTracer"}])
res = {"tx": h, "block": int(tx["blockNumber"], 16), "txGas": int(tx["gas"], 16), "receiptGasUsed": int(rc["gasUsed"], 16),
       "structLogger": {k: v for k, v in sl.items() if k != "structLogs"}, "firstSteps": sl.get("structLogs", [])[:5],
       "callTracer": {k: ct.get(k) for k in ("type", "gas", "gasUsed", "error")}}
json.dump(res, open(out, "w"), indent=1); print(json.dumps({k: res[k] for k in ("txGas", "receiptGasUsed")}), res["firstSteps"][:1])
