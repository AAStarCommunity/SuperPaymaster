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
EXPECTED_CHAIN = int(os.environ.get("EXPECTED_CHAIN_ID", "11155111"))  # Sepolia; a fork keeps it


class Fail(Exception):
    pass


HEXDATA = re.compile(r"0x([0-9a-fA-F]{2})*")
QTY = re.compile(r"0x(0|[1-9a-fA-F][0-9a-fA-F]*)")
HASH32 = re.compile(r"0x[0-9a-fA-F]{64}")
# Deterministic EVM outcomes of "this gas limit is not enough / execution failed". Anything else
# (rate limit, internal error, transport, unknown codes) is an RPC fault and aborts the run: it must
# never be read as a gas boundary.
EVM_FAILURE = re.compile(r"out of gas|outofgas|\b\w*oog\b|gas required exceeds|gas exhausted|intrinsic gas too (?:low|high)|"
                         r"callgascostmorethangaslimit|gasfloormorethangaslimit|execution reverted|reentrancy\s*sentry", re.I)
_next_id = 0


def rpc(url, method, params):
    """Strict JSON-RPC: returns ("ok", result) or ("evm-failure", error); raises Fail otherwise."""
    global _next_id
    _next_id += 1
    rid = _next_id
    body = json.dumps({"jsonrpc": "2.0", "id": rid, "method": method, "params": params}).encode()
    try:
        req = urllib.request.Request(url, body, {"Content-Type": "application/json", "User-Agent": "rams-probe"})
        with urllib.request.urlopen(req, timeout=120) as r:
            d = json.load(r)
    except Exception as e:
        raise Fail(f"{method}: transport error ({type(e).__name__})") from None
    if (not isinstance(d, dict) or d.get("jsonrpc") != "2.0" or type(d.get("id")) is not int
            or d["id"] != rid or (("result" in d) == ("error" in d))):
        raise Fail(f"{method}: malformed envelope")
    if "error" in d:
        e = d["error"]
        if not isinstance(e, dict) or type(e.get("code")) is not int or not isinstance(e.get("message"), str):
            raise Fail(f"{method}: malformed error object")
        if EVM_FAILURE.search(e["message"]):
            return "evm-failure", {"code": e["code"], "message": e["message"][:120]}
        raise Fail(f"{method}: RPC fault code={e['code']} (not an EVM gas/execution failure)")
    return "ok", d["result"]


def result_of(url, method, params, check):
    kind, v = rpc(url, method, params)
    if kind != "ok":
        raise Fail(f"{method}: unexpected EVM failure")
    if not check(v):
        raise Fail(f"{method}: malformed result")
    return v


def call_outcome(url, tx, gas, blk):
    """True / False for a well-formed eth_call outcome; raises on any RPC fault or malformed data."""
    kind, v = rpc(url, "eth_call", [dict(tx, gas=hex(gas)), blk])
    if kind == "evm-failure":
        return False, v
    if not (isinstance(v, str) and HEXDATA.fullmatch(v)):
        raise Fail("eth_call: malformed result")
    return True, {"returnBytes": (len(v) - 2) // 2}


def min_gas(url, tx, blk):
    """Minimum gas for which eth_call succeeds; also returns the raw outcomes at min-1 and min."""
    # Lower bound 0, not 21,000: EIP-2780 lowers intrinsic costs, so sub-21k thresholds are real.
    lo, hi = 0, HI
    if not call_outcome(url, tx, hi, blk)[0]:
        return None, None
    while lo < hi:
        mid = (lo + hi) // 2
        if call_outcome(url, tx, mid, blk)[0]:
            hi = mid
        else:
            lo = mid + 1
    below = call_outcome(url, tx, lo - 1, blk) if lo > 0 else (False, {"note": "gas 0"})
    at = call_outcome(url, tx, lo, blk)
    if below[0] or not at[0]:
        raise Fail("eth_call: threshold not reproducible (min-1 succeeded or min failed)")
    return lo, {"minMinus1": below[1], "min": at[1]}


def estimate(url, tx, blk):
    kind, v = rpc(url, "eth_estimateGas", [tx, blk])
    if kind == "evm-failure":
        return None
    if not (isinstance(v, str) and QTY.fullmatch(v)):
        raise Fail("eth_estimateGas: malformed result")
    return int(v, 16)


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
        cid = int(result_of(u, "eth_chainId", [], lambda v: isinstance(v, str) and QTY.fullmatch(v)), 16)
        if cid != EXPECTED_CHAIN:
            raise Fail(f"endpoint {k}: chain id {cid} != expected {EXPECTED_CHAIN}")
        out["chainIds"][k] = cid
        b = result_of(u, "eth_getBlockByNumber", [blk, False], lambda v: isinstance(v, dict))
        if not (isinstance(b.get("hash"), str) and HASH32.fullmatch(b["hash"])) or b.get("number") != blk:
            raise Fail(f"endpoint {k}: missing or wrong block")
        out.setdefault("blockHashes", {})[k] = b["hash"]
    for name, tx in txs.items():
        row = {}
        for k, u in eps.items():
            m, sides = min_gas(u, tx, blk)
            row[k] = {"minGas": m, "thresholdSides": sides, "estimate": estimate(u, tx, blk)}
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
