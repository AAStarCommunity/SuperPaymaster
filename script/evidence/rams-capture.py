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

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))
from rpc_strict import HEXDATA, QTY, HASH32, classify  # noqa: E402  (shared strict classifier, R2-F1)
EXPECTED_CHAIN = int(os.environ.get("EXPECTED_CHAIN_ID", "11155111"))
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
        if allow_method_not_found and e["code"] == -32601:
            return {"unsupported": err}
        if classify(e) == "evm-failure":
            return {"evmFailure": err}
        FAULTS.append(f"{method}: RPC fault code={e['code']}")
        return {"rpcFault": err}
    return {"result": d["result"]}


def main():
    pk = json.load(open(sys.argv[1]))
    blk = hex(int(os.environ["BLOCK"]))
    eps = {k: os.environ[f"RPC_{k}"] for k in "ABC" if os.environ.get(f"RPC_{k}")}
    steps = [s for s in pk["steps"] if s["id"] in ("S1", "S2", "S3")]
    out = {"note": "read-only; RPC URLs omitted", "block": int(blk, 16), "endpoints": {}}
    def need(cond, what):
        if not cond:
            FAULTS.append(what)

    for k, u in eps.items():
        e = {}
        e["chainId"] = rpc(u, "eth_chainId", [])
        cid = e["chainId"].get("result")
        need(isinstance(cid, str) and QTY.fullmatch(cid) and int(cid, 16) == EXPECTED_CHAIN, f"{k}: chainId wrong or malformed")
        b = rpc(u, "eth_getBlockByNumber", [blk, False])
        br = b.get("result")
        ok_block = (isinstance(br, dict) and isinstance(br.get("hash"), str) and HASH32.fullmatch(br["hash"])
                    and br.get("number") == blk and isinstance(br.get("timestamp"), str) and QTY.fullmatch(br["timestamp"]))
        need(ok_block, f"{k}: block missing, wrong number or malformed")
        e["block"] = {"hash": br["hash"], "timestamp": int(br["timestamp"], 16)} if ok_block else b
        e["clientVersion"] = rpc(u, "web3_clientVersion", [])
        e["eth_config"] = rpc(u, "eth_config", [], allow_method_not_found=True)
        for name, params in (("deployerNonceAtBlock", [DEPLOYER, blk]), ("deployerNoncePendingNow", [DEPLOYER, "pending"])):
            e[name] = rpc(u, "eth_getTransactionCount", params)
            v = e[name].get("result")
            need(isinstance(v, str) and QTY.fullmatch(v), f"{k}: {name} malformed")
        e["safeNonceAtBlock"] = rpc(u, "eth_call", [{"to": SAFE, "data": "0xaffed0e0"}, blk])
        v = e["safeNonceAtBlock"].get("result")
        need(isinstance(v, str) and HEXDATA.fullmatch(v) and len(v) == 66, f"{k}: safe nonce malformed")
        e["steps"] = {}
        for s in steps:
            tx = {"from": s["from"], "data": s["calldata"]}
            if s["to"]:
                tx["to"] = s["to"]
            est = rpc(u, "eth_estimateGas", [tx, blk])
            if "result" in est:
                need(isinstance(est["result"], str) and QTY.fullmatch(est["result"]), f"{k}: {s['id']} estimate malformed")
            call = rpc(u, "eth_call", [dict(tx, gas=hex(int(s["suggestedGasLimit"]))), blk])
            if "result" in call:
                need(isinstance(call["result"], str) and HEXDATA.fullmatch(call["result"]), f"{k}: {s['id']} eth_call malformed")
            e["steps"][s["id"]] = {
                "packetSuggestedGasLimit": int(s["suggestedGasLimit"]),
                "forkGasUsedInV4": int(s["gasUsedInFork"]),
                "estimateGas": est,
                "ethCallAtPacketLimit": call,
            }
        out["endpoints"][k] = e
    json.dump(out, sys.stdout, indent=1)
    print()
    # Exit non-zero on any RPC fault, malformed response, wrong chain or wrong block.
    if FAULTS:
        print("rams-capture: faults: " + "; ".join(FAULTS[:10]), file=sys.stderr)
    sys.exit(0 if not FAULTS and out["endpoints"] else 1)


if __name__ == "__main__":
    main()
