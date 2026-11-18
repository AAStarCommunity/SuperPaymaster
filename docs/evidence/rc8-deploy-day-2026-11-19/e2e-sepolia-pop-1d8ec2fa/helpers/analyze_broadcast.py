#!/usr/bin/env python3
# usage: analyze_broadcast.py RPC BROADCAST_JSON REPLAY_JSON  — receipts vs. replay measurement, PoP rows, H headroom
import json, sys, urllib.request
url, bj, rj = sys.argv[1:4]; CAP = 16_777_216
def rpc(m, p):
    return json.load(urllib.request.urlopen(urllib.request.Request(url, json.dumps({"jsonrpc":"2.0","id":1,"method":m,"params":p}).encode(), {"content-type":"application/json"})))["result"]
b = json.load(open(bj)); txs = b["transactions"]; rcs = b["receipts"]; rep = json.load(open(rj))
print("broadcast txs", len(txs), "receipts", len(rcs))
rows = []
for i, (x, r) in enumerate(zip(txs, rcs), 1):
    rc = rpc("eth_getTransactionReceipt", [r["transactionHash"]])
    gl = int(x["transaction"].get("gas") or rpc("eth_getTransactionByHash", [r["transactionHash"]])["gas"], 16); gu = int(rc["gasUsed"], 16)
    rows.append((i, x.get("contractName") or "", x.get("function") or "", gl, gu, rc["status"], rep[i-1]["gasUsed"]))
bad = [r for r in rows if r[5] != "0x1"]
print("all status 1:", not bad, bad[:3])
mism = [(r[0], r[1], r[4], r[6]) for r in rows if r[4] != r[6]]
print("gasUsed == replay measurement for", len(rows) - len(mism), "of", len(rows), "; differing:", mism[:10])
mx = max(rows, key=lambda r: r[4]); print("max gasUsed", mx[0], mx[1], f"{mx[4]:,}", "total-gas headroom to 2^24", f"{CAP - mx[4]:,}")
over = [(r[0], r[1].replace('.default',''), r[4]) for r in rows if r[4] > CAP]; print("total gasUsed > 2^24:", over)
minlim = min(rows, key=lambda r: r[3] / r[4]); print("min gasLimit/gasUsed ratio", minlim[0], minlim[1], round(minlim[3] / minlim[4], 4))
for r in rows:
    if r[1].startswith(("Registry", "SuperPaymaster", "BLSAggregator", "TimelockHandoverBootstrap")) and not r[2] or "registerBLSPublicKey" in r[2]:
        print(f"  #{r[0]} {r[1]} {r[2].split('(')[0]} gasLimit {r[3]:,} gasUsed {r[4]:,} status {r[5]} headroom-to-cap {CAP - r[4]:,} limit-headroom {r[3]-r[4]:,}")
print("total gasUsed", f"{sum(r[4] for r in rows):,}")
