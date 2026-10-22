#!/usr/bin/env python3
"""R-AMS-0: archive the live-chain facts that stopped A3a v4 (read-only).

Usage:
  RPC_A=<archive rpc> RPC_B=<second rpc> RPC_C=<third rpc, optional> BLOCK=<n> \
    python3 script/evidence/rams-capture.py docs/release/a3a-precheck-v4/a3a-precheck.json > out.json

Records at one pinned block, per endpoint: chainId, block hash/timestamp, clientVersion, the raw
eth_config response (current/next/last) where the endpoint serves it, the deployer EOA nonce
(at BLOCK and `pending` now) and Safe nonce (proof that nothing from A3a was broadcast), and for
A3a S1/S2/S3: eth_estimateGas plus the eth_call outcome at the v4 packet's suggestedGasLimit.
Nothing is signed or sent; RPC URLs are never written out.
"""
import json, os, sys, urllib.request

DEPLOYER = "0xb5600060e6de5E11D3636731964218E53caadf0E"
SAFE = "0x51eDf11fDb0A4F66220eFb8efA54Eca77232E114"


def rpc(url, method, params):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    try:
        req = urllib.request.Request(url, body, {"Content-Type": "application/json", "User-Agent": "rams-capture"})
        with urllib.request.urlopen(req, timeout=120) as r:
            d = json.load(r)
    except Exception as e:
        return {"transportError": type(e).__name__}
    if not isinstance(d, dict) or d.get("jsonrpc") != "2.0" or d.get("id") != 1:
        return {"malformedEnvelope": True}
    if "error" in d:
        e = d["error"]
        return {"error": {"code": e.get("code") if isinstance(e, dict) else None,
                          "message": (e.get("message", "") if isinstance(e, dict) else "")[:160]}}
    return {"result": d.get("result")}


def main():
    pk = json.load(open(sys.argv[1]))
    blk = hex(int(os.environ["BLOCK"]))
    eps = {k: os.environ[f"RPC_{k}"] for k in "ABC" if os.environ.get(f"RPC_{k}")}
    steps = [s for s in pk["steps"] if s["id"] in ("S1", "S2", "S3")]
    out = {"note": "read-only; RPC URLs omitted", "block": int(blk, 16), "endpoints": {}}
    for k, u in eps.items():
        e = {}
        e["chainId"] = rpc(u, "eth_chainId", [])
        b = rpc(u, "eth_getBlockByNumber", [blk, False])
        e["block"] = ({"hash": b["result"]["hash"], "timestamp": int(b["result"]["timestamp"], 16)}
                      if isinstance(b.get("result"), dict) else b)
        e["clientVersion"] = rpc(u, "web3_clientVersion", [])
        e["eth_config"] = rpc(u, "eth_config", [])
        e["deployerNonceAtBlock"] = rpc(u, "eth_getTransactionCount", [DEPLOYER, blk])
        e["deployerNoncePendingNow"] = rpc(u, "eth_getTransactionCount", [DEPLOYER, "pending"])
        e["safeNonceAtBlock"] = rpc(u, "eth_call", [{"to": SAFE, "data": "0xaffed0e0"}, blk])
        e["steps"] = {}
        for s in steps:
            tx = {"from": s["from"], "data": s["calldata"]}
            if s["to"]:
                tx["to"] = s["to"]
            e["steps"][s["id"]] = {
                "packetSuggestedGasLimit": int(s["suggestedGasLimit"]),
                "forkGasUsedInV4": int(s["gasUsedInFork"]),
                "estimateGas": rpc(u, "eth_estimateGas", [tx, blk]),
                "ethCallAtPacketLimit": rpc(u, "eth_call", [dict(tx, gas=hex(int(s["suggestedGasLimit"]))), blk]),
            }
        out["endpoints"][k] = e
    json.dump(out, sys.stdout, indent=1)
    print()
    # Exit non-zero unless every endpoint answered chainId and the pinned block, so a run in which
    # all endpoints failed cannot look like a successful archive.
    ok = all("result" in e["chainId"] and isinstance(e["block"], dict) and "hash" in e["block"]
             for e in out["endpoints"].values())
    sys.exit(0 if ok and out["endpoints"] else 1)


if __name__ == "__main__":
    main()
