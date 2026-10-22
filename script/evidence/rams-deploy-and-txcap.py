#!/usr/bin/env python3
"""R-AMS-0 addendum (read-only): can our large contracts still be deployed on Sepolia under Amsterdam?

Usage (after `forge build` with the repo's profile.default; reads out/<C>.sol/<C>.json):
  RPC_A=<archive rpc> RPC_B=<second rpc> SCAN_BLOCKS=3000 \
    python3 script/evidence/rams-deploy-and-txcap.py > out.json

Part 1 (deployment-specific): for Registry (no ctor args) and SuperPaymaster (EntryPoint, Sepolia
Registry proxy, Chainlink ETH/USD feed as ctor args), on both endpoints at `latest`:
eth_estimateGas; eth_call at gas 2^24 and 60M; and eth_simulateV1 with `validation: true` (the node
applies transaction-validity rules, including gas caps, nonce and fee checks) with the deployer's
real nonce at gasLimit 40M/60M and at 2^24.
Part 2 (context only): scan the last SCAN_BLOCKS blocks on RPC_B for included transactions whose
gas limit exceeds 2^24, counting blocks actually read; receipts for a few of them.
Nothing is signed or sent. RPC URLs are never written out and provider error text is redacted.
"""
import concurrent.futures as cf, json, os, re, sys, urllib.request

CAP = 1 << 24
DEPLOYER = "0xb5600060e6de5E11D3636731964218E53caadf0E"
EP = "0x0000000071727De22E5E9d8BAf0edAc6f37da032"
REG = "0xf5Bf37ca83AfdAab73691bA7eCcDfA69b8708E71"
FEED = "0x694AA1769357215DE4FAC081bf1f309aDC325306"
HEX = re.compile(r"0x([0-9a-fA-F]{2})*")


def redact(msg):
    msg = re.sub(r"[a-zA-Z][a-zA-Z0-9+.-]*://\S+", "<url>", str(msg))
    return re.sub(r"[A-Za-z0-9_-]{24,}", "<redacted>", msg)[:160]


def rpc(url, method, params):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    try:
        req = urllib.request.Request(url, body, {"Content-Type": "application/json", "User-Agent": "rams-txcap"})
        with urllib.request.urlopen(req, timeout=180) as r:
            d = json.load(r)
    except Exception as e:
        return {"transportError": type(e).__name__}
    if not isinstance(d, dict) or d.get("jsonrpc") != "2.0" or type(d.get("id")) is not int or d["id"] != 1:
        return {"malformedEnvelope": True}
    if "error" in d:
        e = d["error"]
        return {"error": {"code": e.get("code") if isinstance(e, dict) and isinstance(e.get("code"), int) else None,
                          "message": redact(e.get("message", "") if isinstance(e, dict) else "")}}
    if "result" not in d:
        return {"malformedEnvelope": True}
    return {"result": d["result"]}


def initcode(c, args=()):
    code = json.load(open(f"out/{c}.sol/{c}.json"))["bytecode"]["object"]
    return code + "".join("0" * 24 + a.lower()[2:] for a in args)


def call_outcome(r):
    if "result" in r:
        v = r["result"]
        if isinstance(v, str) and HEX.fullmatch(v):
            return {"ok": True, "returnBytes": (len(v) - 2) // 2}
        return {"malformedResult": True}
    return r


def qty(v):
    return int(v, 16) if isinstance(v, str) and re.fullmatch(r"0x[0-9a-fA-F]+", v) else None


def simulate(u, code, gas, nonce):
    call = {"from": DEPLOYER, "data": code, "gas": hex(gas), "nonce": nonce,
            "maxFeePerGas": hex(2 * 10**9), "maxPriorityFeePerGas": hex(10**8)}
    r = rpc(u, "eth_simulateV1", [{"blockStateCalls": [{"calls": [call]}], "validation": True}, "latest"])
    if "result" not in r:
        return r
    try:
        c0 = r["result"][0]["calls"][0]
    except (KeyError, IndexError, TypeError):
        return {"malformedResult": True}
    err = c0.get("error")
    return {"status": c0.get("status"), "gasUsed": qty(c0.get("gasUsed")),
            "error": ({"code": err.get("code"), "message": redact(err.get("message", ""))} if isinstance(err, dict) else None)}


def main():
    eps = {"A": os.environ["RPC_A"], "B": os.environ["RPC_B"]}
    out = {"note": "read-only; RPC URLs omitted; provider messages redacted", "deploy": {}, "txcap": {}}
    out["latestAtStart"] = {k: qty(rpc(u, "eth_blockNumber", []).get("result")) for k, u in eps.items()}
    nonces = {k: rpc(u, "eth_getTransactionCount", [DEPLOYER, "latest"]).get("result") for k, u in eps.items()}
    for name, code, big in (("Registry", initcode("Registry"), 40_000_000),
                            ("SuperPaymaster", initcode("SuperPaymaster", (EP, REG, FEED)), 60_000_000)):
        row = {"initcodeBytes": (len(code) - 2) // 2}
        for k, u in eps.items():
            tx = {"from": DEPLOYER, "data": code}
            est = rpc(u, "eth_estimateGas", [tx])
            row[k] = {"estimateGas": qty(est["result"]) if "result" in est else est,
                      "ethCallAt2pow24": call_outcome(rpc(u, "eth_call", [dict(tx, gas=hex(CAP)), "latest"])),
                      "ethCallAt60M": call_outcome(rpc(u, "eth_call", [dict(tx, gas=hex(60_000_000)), "latest"])),
                      f"simulateV1Validation@{big}": simulate(u, code, big, nonces[k]),
                      "simulateV1Validation@2pow24": simulate(u, code, CAP, nonces[k])}
        out["deploy"][name] = row

    n = int(os.environ.get("SCAN_BLOCKS", "3000"))
    head = out["latestAtStart"]["B"]
    over, ntx, maxg, read = [], 0, 0, 0

    def blk(i):
        r = rpc(eps["B"], "eth_getBlockByNumber", [hex(i), True]).get("result")
        return r if isinstance(r, dict) and isinstance(r.get("transactions"), list) else None

    with cf.ThreadPoolExecutor(8) as ex:
        for b in ex.map(blk, range(head - n, head)):
            if b is None:
                continue
            read += 1
            for t in b["transactions"]:
                g = qty(t.get("gas"))
                if g is None:
                    continue
                ntx += 1
                maxg = max(maxg, g)
                if g > CAP:
                    over.append({"block": qty(b["number"]), "tx": t["hash"], "gasLimit": g})
    samples = []
    for o in sorted(over, key=lambda x: -x["gasLimit"])[:5] + over[:3]:
        r = rpc(eps["B"], "eth_getTransactionReceipt", [o["tx"]]).get("result") or {}
        samples.append(dict(o, status=r.get("status"), gasUsed=qty(r.get("gasUsed"))))
    out["txcap"] = {"requestedBlocks": [head - n, head - 1], "blocksRead": read, "blocksMissing": n - read,
                    "transactions": ntx, "maxGasLimit": maxg, "countGasLimitOver2pow24": len(over), "samples": samples}
    json.dump(out, sys.stdout, indent=1)
    print()
    sys.exit(0 if read == n else 1)


if __name__ == "__main__":
    main()
