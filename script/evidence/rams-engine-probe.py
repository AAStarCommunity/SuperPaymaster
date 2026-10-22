#!/usr/bin/env python3
"""R-AMS-1: does a local engine reproduce the live Sepolia (Amsterdam) gas rules? Read-only.

Usage:
  RPC_A=<archive rpc> RPC_B=<second rpc> ENGINE=<local fork rpc, e.g. anvil --fork-block-number N> BLOCK=<N> \
    python3 script/evidence/rams-engine-probe.py docs/release/a3a-precheck-v4/a3a-precheck.json > out.json

For each probe transaction (the A3a S1/S2/S3 calldata, plus synthetic constructor-only probes that
exercise CREATE, code deposit, new-slot SSTORE, warm re-SSTORE, cold account access, cold CALL and a
plain value transfer to a fresh account) this script finds, on every endpoint at the same pinned
block, the MINIMUM gas limit for which eth_call succeeds (binary search) and also records
eth_estimateGas. The engine matches the live chain for a probe only if its minimum equals the live
minimum on both live endpoints. Nothing is signed or sent; RPC URLs never reach stdout/stderr.
"""
import json, os, re, sys, urllib.request

DEPLOYER = "0xb5600060e6de5E11D3636731964218E53caadf0E"   # funded sender used only as eth_call `from`
SP = "0x09DF0d2e3722EC0e401fE3819E64278a42ae4DE9"          # an existing, cold-at-tx-start account
FRESH = "0x" + "a3" * 20                                   # an account that does not exist on Sepolia
HI = 30_000_000


class Fail(Exception):
    pass


def rpc(url, method, params):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    try:
        req = urllib.request.Request(url, body, {"Content-Type": "application/json", "User-Agent": "rams-probe"})
        with urllib.request.urlopen(req, timeout=120) as r:
            d = json.load(r)
    except Exception as e:
        raise Fail(f"{method}: transport error ({type(e).__name__})") from None
    if not isinstance(d, dict) or d.get("jsonrpc") != "2.0" or type(d.get("id")) is not int or d["id"] != 1:
        raise Fail(f"{method}: malformed envelope")
    return d


def ok_at(url, tx, gas, blk):
    d = rpc(url, "eth_call", [dict(tx, gas=hex(gas)), blk])
    return "result" in d


def min_gas(url, tx, blk):
    # Lower bound 0, not 21,000: EIP-2780 lowers intrinsic costs, so sub-21k thresholds are real.
    lo, hi = 0, HI
    if not ok_at(url, tx, hi, blk):
        return None
    while lo < hi:
        mid = (lo + hi) // 2
        if ok_at(url, tx, mid, blk):
            hi = mid
        else:
            lo = mid + 1
    return lo


def estimate(url, tx, blk):
    d = rpc(url, "eth_estimateGas", [tx, blk])
    return int(d["result"], 16) if "result" in d else None


def a20(a):
    return a.lower().removeprefix("0x")


# Synthetic constructor probes: initcode runs once, then returns (or not) runtime code.
PROBES = {
    # STOP: creates an empty account (CREATE base + new-account state cost).
    "create-empty": "0x00",
    # Return 256 zero bytes as runtime code (code deposit cost for 256 bytes).
    "create-deposit-256": "0x6101006000f3",
    # SSTORE 1 into slot 0 (zero -> nonzero: new storage slot), then STOP.
    "create-sstore-new-slot": "0x600160005500",
    # Two SSTOREs to the same slot (second one is warm and nonzero -> nonzero).
    "create-sstore-new-then-warm": "0x6001600055600260005500",
    # BALANCE of an existing cold account (cold account access), then STOP.
    "create-cold-balance": "0x73" + a20(SP) + "315000",
    # CALL to an existing cold account with 0 value, no data; pop result; STOP.
    "create-cold-call": "0x6000600060006000600073" + a20(SP) + "61fffff15000",
}


def main():
    pk = json.load(open(sys.argv[1]))
    blk = hex(int(os.environ["BLOCK"]))
    eps = {"A": os.environ["RPC_A"], "B": os.environ["RPC_B"], "ENGINE": os.environ["ENGINE"]}
    if len({u.rstrip("/") for u in eps.values()}) != 3:
        raise Fail("endpoints must be distinct")
    txs = {}
    for s in pk["steps"]:
        if s["id"] in ("S1", "S2", "S3"):
            t = {"from": s["from"], "data": s["calldata"]}
            if s["to"]:
                t["to"] = s["to"]
            txs[s["label"]] = t
    for name, code in PROBES.items():
        txs[name] = {"from": DEPLOYER, "data": code}
    txs["transfer-1wei-to-fresh"] = {"from": DEPLOYER, "to": FRESH, "value": "0x1"}
    # Calls into existing contracts: cold account + cold SLOADs under EIP-8038 repricing.
    EP = "0x0000000071727De22E5E9d8BAf0edAc6f37da032"
    SAFE = "0x51eDf11fDb0A4F66220eFb8efA54Eca77232E114"
    txs["call-sp-owner"] = {"from": DEPLOYER, "to": SP, "data": "0x8da5cb5b"}
    txs["call-sp-version"] = {"from": DEPLOYER, "to": SP, "data": "0x54fd4d50"}
    txs["call-safe-getOwners"] = {"from": DEPLOYER, "to": SAFE, "data": "0xa0e67e2b"}
    txs["call-entrypoint-balanceOf-sp"] = {"from": DEPLOYER, "to": EP, "data": "0x70a08231" + "0" * 24 + a20(SP)}

    out = {"note": "read-only; RPC URLs omitted", "block": int(blk, 16), "chainIds": {}, "probes": {}}
    for k, u in eps.items():
        out["chainIds"][k] = int(rpc(u, "eth_chainId", [])["result"], 16)
        out.setdefault("blockHashes", {})[k] = rpc(u, "eth_getBlockByNumber", [blk, False])["result"]["hash"]
    for name, tx in txs.items():
        row = {}
        for k, u in eps.items():
            row[k] = {"minGas": min_gas(u, tx, blk), "estimate": estimate(u, tx, blk)}
        # A probe that cannot be measured on any endpoint (None) is a FAILURE, never a match.
        row["measurable"] = all(isinstance(row[k]["minGas"], int) for k in eps)
        row["liveAgree"] = row["measurable"] and row["A"]["minGas"] == row["B"]["minGas"]
        row["engineMatchesLive"] = row["liveAgree"] and row["ENGINE"]["minGas"] == row["A"]["minGas"]
        out["probes"][name] = row
        print(f"{name}: live {row['A']['minGas']}/{row['B']['minGas']} engine {row['ENGINE']['minGas']} "
              f"match={row['engineMatchesLive']}", file=sys.stderr)
    out["allMatch"] = all(r["engineMatchesLive"] for r in out["probes"].values())
    out["sameChainAndBlock"] = (len(set(out["chainIds"].values())) == 1
                                and len(set(out["blockHashes"].values())) == 1)
    json.dump(out, sys.stdout, indent=1)
    print()
    sys.exit(0 if out["allMatch"] and out["sameChainAndBlock"] else 1)


if __name__ == "__main__":
    try:
        main()
    except Fail as e:
        print(f"rams-engine-probe: {e}", file=sys.stderr)
        sys.exit(2)
    except Exception as e:
        print(f"rams-engine-probe: unexpected {type(e).__name__}", file=sys.stderr)
        sys.exit(3)
