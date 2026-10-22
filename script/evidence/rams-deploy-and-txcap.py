#!/usr/bin/env python3
"""R-AMS-0 addendum (read-only): can our large contracts still be deployed on Sepolia under Amsterdam?

Usage (after `forge build` with the repo's profile.default; reads out/<C>.sol/<C>.json):
  RPC_A=<archive rpc> RPC_B=<second rpc> SCAN_BLOCKS=3000 \
    python3 script/evidence/rams-deploy-and-txcap.py > out.json

Part 1: for Registry (no ctor args) and SuperPaymaster (EntryPoint, Sepolia Registry proxy, Chainlink
ETH/USD feed as ctor args), on both endpoints at `latest`: eth_estimateGas, and eth_call with gas
2^24 and 60M. Part 2: scan the last SCAN_BLOCKS blocks on RPC_B for included transactions whose
gas limit exceeds 2^24 (EIP-7825's cap), with receipts for the first few (status, gasUsed).
If such transactions are included and succeed, a >2^24-gas deployment is admissible on Sepolia.
Nothing is signed or sent; RPC URLs are never written out.
"""
import concurrent.futures as cf, json, os, sys, urllib.request

CAP = 1 << 24
DEPLOYER = "0xb5600060e6de5E11D3636731964218E53caadf0E"
EP = "0x0000000071727De22E5E9d8BAf0edAc6f37da032"
REG = "0xf5Bf37ca83AfdAab73691bA7eCcDfA69b8708E71"
FEED = "0x694AA1769357215DE4FAC081bf1f309aDC325306"


def rpc(url, method, params):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    try:
        req = urllib.request.Request(url, body, {"Content-Type": "application/json", "User-Agent": "rams-txcap"})
        with urllib.request.urlopen(req, timeout=180) as r:
            d = json.load(r)
    except Exception as e:
        return {"transportError": type(e).__name__}
    if "error" in d:
        e = d["error"]
        return {"error": (e.get("message", "") if isinstance(e, dict) else "")[:160]}
    return {"result": d.get("result")}


def initcode(c, args=()):
    code = json.load(open(f"out/{c}.sol/{c}.json"))["bytecode"]["object"]
    return code + "".join("0" * 24 + a.lower()[2:] for a in args)


def summarize(r):
    if "result" in r:
        v = r["result"]
        return {"ok": True, "len": len(v) if isinstance(v, str) else None}
    return r


def main():
    eps = {"A": os.environ["RPC_A"], "B": os.environ["RPC_B"]}
    out = {"note": "read-only; RPC URLs omitted", "deploy": {}, "txcap": {}}
    blocks = {k: rpc(u, "eth_blockNumber", []) for k, u in eps.items()}
    out["latestAtStart"] = {k: int(v["result"], 16) for k, v in blocks.items() if "result" in v}
    for name, code in (("Registry", initcode("Registry")), ("SuperPaymaster", initcode("SuperPaymaster", (EP, REG, FEED)))):
        row = {"initcodeBytes": len(code) // 2 - 1}
        for k, u in eps.items():
            tx = {"from": DEPLOYER, "data": code}
            est = rpc(u, "eth_estimateGas", [tx])
            row[k] = {"estimateGas": int(est["result"], 16) if "result" in est else est,
                      "ethCallAt2pow24": summarize(rpc(u, "eth_call", [dict(tx, gas=hex(CAP)), "latest"])),
                      "ethCallAt60M": summarize(rpc(u, "eth_call", [dict(tx, gas=hex(60_000_000)), "latest"]))}
        out["deploy"][name] = row
    n = int(os.environ.get("SCAN_BLOCKS", "3000"))
    head = out["latestAtStart"]["B"]
    over, ntx, maxg = [], 0, 0

    def blk(i):
        r = rpc(eps["B"], "eth_getBlockByNumber", [hex(i), True])
        return r.get("result")

    with cf.ThreadPoolExecutor(8) as ex:
        for b in ex.map(blk, range(head - n, head)):
            if not b:
                continue
            for t in b["transactions"]:
                ntx += 1
                g = int(t["gas"], 16)
                maxg = max(maxg, g)
                if g > CAP:
                    over.append({"block": int(b["number"], 16), "tx": t["hash"], "gasLimit": g})
    samples = []
    for o in sorted(over, key=lambda x: -x["gasLimit"])[:5] + over[:3]:
        r = rpc(eps["B"], "eth_getTransactionReceipt", [o["tx"]]).get("result") or {}
        samples.append(dict(o, status=r.get("status"), gasUsed=int(r["gasUsed"], 16) if r.get("gasUsed") else None))
    out["txcap"] = {"scannedBlocks": [head - n, head - 1], "transactions": ntx, "maxGasLimit": maxg,
                    "countGasLimitOver2pow24": len(over), "samples": samples,
                    "anyIncludedSuccessOver2pow24": any(s["status"] == "0x1" and s["gasUsed"] and s["gasUsed"] > CAP for s in samples)}
    json.dump(out, sys.stdout, indent=1)
    print()


if __name__ == "__main__":
    main()
