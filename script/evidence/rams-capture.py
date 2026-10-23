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


import re

EVM_FAILURE = re.compile(r"out of gas|outofgas|\b\w*oog\b|gas required exceeds|gas exhausted|intrinsic gas too (?:low|high)|"
                         r"callgascostmorethangaslimit|gasfloormorethangaslimit|execution reverted|reentrancy\s*sentry", re.I)
_next_id = 0
FAULTS = []  # every RPC fault / malformed response seen; any entry makes the run exit 1


def rpc(url, method, params, allow_method_not_found=False):
    """Records one of: {"result"}, {"evmFailure"} (deterministic execution outcome), or a fault.
    Faults (transport, malformed envelope, non-EVM errors) are also appended to FAULTS."""
    global _next_id
    _next_id += 1
    rid = _next_id
    body = json.dumps({"jsonrpc": "2.0", "id": rid, "method": method, "params": params}).encode()
    try:
        req = urllib.request.Request(url, body, {"Content-Type": "application/json", "User-Agent": "rams-capture"})
        with urllib.request.urlopen(req, timeout=120) as r:
            d = json.load(r)
    except Exception as e:
        FAULTS.append(f"{method}: transport {type(e).__name__}")
        return {"transportError": type(e).__name__}
    if (not isinstance(d, dict) or d.get("jsonrpc") != "2.0" or type(d.get("id")) is not int
            or d["id"] != rid or (("result" in d) == ("error" in d))):
        FAULTS.append(f"{method}: malformed envelope")
        return {"malformedEnvelope": True}
    if "error" in d:
        e = d["error"]
        if not isinstance(e, dict) or type(e.get("code")) is not int or not isinstance(e.get("message"), str):
            FAULTS.append(f"{method}: malformed error")
            return {"malformedError": True}
        err = {"code": e["code"], "message": re.sub(r"https?://\S+", "<url>", e["message"])[:160]}
        if EVM_FAILURE.search(e["message"]):
            return {"evmFailure": err}
        if allow_method_not_found and e["code"] == -32601:
            return {"unsupported": err}
        FAULTS.append(f"{method}: RPC fault code={e['code']}")
        return {"rpcFault": err}
    return {"result": d["result"]}


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
        e["eth_config"] = rpc(u, "eth_config", [], allow_method_not_found=True)
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
    # Exit non-zero on any RPC fault / malformed response, or unless every endpoint answered a
    # well-formed chainId and the pinned block (so an all-failing run cannot look like an archive).
    ok = not FAULTS and all(
        isinstance(e["chainId"].get("result"), str) and isinstance(e["block"], dict)
        and isinstance(e["block"].get("hash"), str) and len(e["block"]["hash"]) == 66
        for e in out["endpoints"].values())
    if FAULTS:
        print("rams-capture: faults: " + "; ".join(FAULTS[:10]), file=sys.stderr)
    sys.exit(0 if ok and out["endpoints"] else 1)


if __name__ == "__main__":
    main()
