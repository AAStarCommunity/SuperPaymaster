#!/usr/bin/env python3
"""R2-F3: find real Sepolia transactions whose gasUsed exceeds 2^24 in a pinned block range.

Under Amsterdam (EIP-7825 cap 2^24, EIP-8037 state-gas reservoir) gas used above 2^24 can only come from the
reservoir, so these are real RR transactions. Read-only. Usage:
  RPC_FILE=<file holding the archive URL> python3 rams-rr-scan.py <from> <to_exclusive> <out.json> [pick=10]
"""
import concurrent.futures as cf, json, os, sys, urllib.request

url = open(os.environ["RPC_FILE"]).read().strip()
lo, hi, out = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
pick_n = int(sys.argv[4]) if len(sys.argv) > 4 else 10
CAP = 1 << 24


def rpc(m, p):
    q = json.dumps({"jsonrpc": "2.0", "id": 1, "method": m, "params": p}).encode()
    r = json.loads(urllib.request.urlopen(urllib.request.Request(url, q, {"Content-Type": "application/json"}), timeout=60).read())
    if "error" in r:
        raise RuntimeError(f"{m}: {r['error'].get('code')}")
    return r["result"]


def block(n):
    b = rpc("eth_getBlockByNumber", [hex(n), True])
    if b is None or int(b["number"], 16) != n:
        raise RuntimeError(f"block {n} missing or mismatched")
    return n, [(t["hash"], int(t["gas"], 16), t.get("to")) for t in b["transactions"]]


with cf.ThreadPoolExecutor(8) as ex:
    blocks = list(ex.map(block, range(lo, hi)))
txs = sum(len(t) for _, t in blocks)
over_limit = [(n, h, g, to) for n, t in blocks for h, g, to in t if g > CAP]


def receipt(x):
    n, h, g, to = x
    r = rpc("eth_getTransactionReceipt", [h])
    return {"block": n, "tx": h, "gasLimit": g, "gasUsed": int(r["gasUsed"], 16), "status": r["status"], "to": to}


with cf.ThreadPoolExecutor(8) as ex:
    rs = list(ex.map(receipt, over_limit))
rr = [r for r in rs if r["gasUsed"] > CAP]
seen, picks = set(), []
for r in rr:  # deterministic: block order; first 4 regardless, then distinct `to`
    if len(picks) < 4 or r["to"] not in seen:
        picks.append(r["tx"])
        seen.add(r["to"])
    if len(picks) >= pick_n:
        break
res = {"range": [lo, hi], "blocks": len(blocks), "txs": txs, "gasLimit_over_2^24": len(over_limit),
       "gasUsed_over_2^24": len(rr), "max_gasUsed": max((r["gasUsed"] for r in rr), default=None),
       "picked": picks, "rr": rr}
json.dump(res, open(out, "w"), indent=1)
print(json.dumps({k: res[k] for k in ("range", "blocks", "txs", "gasLimit_over_2^24", "gasUsed_over_2^24", "max_gasUsed")}))
