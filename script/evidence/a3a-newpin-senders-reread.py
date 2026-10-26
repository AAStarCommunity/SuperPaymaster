#!/usr/bin/env python3
"""Read-only dual-endpoint re-read of every A3a sender and the Safe against a frozen A3a plan.

Usage:
  RPC_A=<archive rpc> RPC_B=<second independent rpc> BLOCK=<n> \
    python3 script/evidence/a3a-newpin-senders-reread.py docs/release/a3a-newpin-11995523/a3a-plan/plan.json

Complements script/evidence/a3a-v4-reread.py (deployer nonce, Safe nonce, SP owner, predicted addresses,
old-aPNTs exposure). This one covers what that script does not: for each plan sender (deployer, approver,
executor) the nonce and balance at the plan pin and at BLOCK, the `latest` and `pending` nonce now, and the
balance at BLOCK against the plan budget; plus the Safe owners at BLOCK against the plan and its threshold against 2 (the executor preflight value).
Methods used: eth_chainId, eth_getBlockByNumber, eth_getTransactionCount, eth_getBalance, eth_call.
Nothing is signed or sent. Exits 1 if the endpoints disagree on a pinned value or any check is false.
RPC URLs never reach stdout or stderr.
"""
import json, os, re, sys, urllib.request

SAFE = "0x51edf11fdb0a4f66220efb8efa54eca77232e114"
SEL = {"nonce()": "0xaffed0e0", "getOwners()": "0xa0e67e2b", "getThreshold()": "0xe75235b8"}
SEPOLIA_CHAIN_ID = 11155111
SAFE_THRESHOLD = 2  # the plan does not record it; same constant as preflight's safe_threshold gate


class RpcFailure(Exception):
    pass


def rpc(url, method, params):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    try:
        req = urllib.request.Request(url, body, {"Content-Type": "application/json", "User-Agent": "a3a-newpin-reread"})
        with urllib.request.urlopen(req, timeout=60) as r:
            d = json.load(r)
    except Exception as e:  # never echo the exception text: it can carry the URL
        raise RpcFailure(f"{method}: transport error ({type(e).__name__})") from None
    if not isinstance(d, dict) or d.get("id") != 1 or "error" in d or d.get("result") is None:
        raise RpcFailure(f"{method}: rpc error or malformed envelope")
    return d["result"]


HEX = re.compile(r"0x[0-9a-fA-F]+")


def qty(method, v):
    if not isinstance(v, str) or not HEX.fullmatch(v):
        raise RpcFailure(f"{method}: malformed quantity")
    return int(v, 16)


def read(url, plan, blk):
    pin = plan["pin"]
    pin_blk = pin["block"]
    out = {"chainId": qty("eth_chainId", rpc(url, "eth_chainId", []))}
    b = rpc(url, "eth_getBlockByNumber", [hex(blk), False])
    out["blockHash"] = b["hash"]
    out["pinBlockHash"] = rpc(url, "eth_getBlockByNumber", [pin_blk, False])["hash"]
    senders = {}
    for name, s in pin["senders"].items():
        a = s["address"]
        senders[name] = {
            "address": a,
            "nonceAtPin": qty("eth_getTransactionCount", rpc(url, "eth_getTransactionCount", [a, pin_blk])),
            "balanceAtPin": qty("eth_getBalance", rpc(url, "eth_getBalance", [a, pin_blk])),
            "nonceAtBlock": qty("eth_getTransactionCount", rpc(url, "eth_getTransactionCount", [a, hex(blk)])),
            "balanceAtBlock": qty("eth_getBalance", rpc(url, "eth_getBalance", [a, hex(blk)])),
            "nonceLatestNow(unpinned)": qty("eth_getTransactionCount", rpc(url, "eth_getTransactionCount", [a, "latest"])),
            "noncePendingNow(unpinned)": qty("eth_getTransactionCount", rpc(url, "eth_getTransactionCount", [a, "pending"])),
        }
    out["senders"] = senders
    call = lambda sel, tag: rpc(url, "eth_call", [{"to": SAFE, "data": SEL[sel]}, tag])
    out["safeNonceAtBlock"] = qty("eth_call", call("nonce()", hex(blk)))
    out["safeNonceLatestNow(unpinned)"] = qty("eth_call", call("nonce()", "latest"))
    out["safeThreshold"] = qty("eth_call", call("getThreshold()", hex(blk)))
    out["safeOwners"] = owners(call("getOwners()", hex(blk)))
    return out


def owners(result):
    """Decode address[] only in its canonical form (offset 32, exact length, zero padding), as preflight does."""
    if not isinstance(result, str) or not HEX.fullmatch(result) or len(result) % 2:
        raise RpcFailure("getOwners: malformed hex result")
    raw = bytes.fromhex(result[2:])
    if len(raw) < 64 or int.from_bytes(raw[:32], "big") != 32:
        raise RpcFailure("getOwners: non-canonical offset")
    n = int.from_bytes(raw[32:64], "big")
    if len(raw) != 64 + 32 * n or any(raw[i:i + 12] != bytes(12) for i in range(64, len(raw), 32)):
        raise RpcFailure("getOwners: non-canonical length or padding")
    return sorted("0x" + raw[i + 12:i + 32].hex() for i in range(64, len(raw), 32))


def main():
    plan_path = sys.argv[1]
    plan = json.load(open(plan_path))
    blk = int(os.environ["BLOCK"])
    if os.environ["RPC_A"].strip().rstrip("/") == os.environ["RPC_B"].strip().rstrip("/"):
        print("config: RPC_A and RPC_B must be different endpoints", file=sys.stderr)
        sys.exit(1)
    try:
        A = read(os.environ["RPC_A"], plan, blk)
        B = read(os.environ["RPC_B"], plan, blk)
    except RpcFailure as e:
        print(f"RPC failure: {e}", file=sys.stderr)
        sys.exit(1)
    pinned = lambda r: {k: v for k, v in r.items() if k != "senders" and "(unpinned)" not in k} | {
        "senders": {n: {k: v for k, v in s.items() if "(unpinned)" not in k} for n, s in r["senders"].items()}}
    pin = plan["pin"]
    budgets = plan["budgetsWei"]
    planned_first = {}
    for st in plan["steps"]:
        frm = st["tx"]["from"].lower()
        nm = next(n for n, s in pin["senders"].items() if s["address"].lower() == frm)
        planned_first.setdefault(nm, int(st["tx"]["nonce"], 16))
    checks = {
        "chainIdSepoliaBothEndpoints": A["chainId"] == B["chainId"] == SEPOLIA_CHAIN_ID,
        "pinnedReadsIdentical": pinned(A) == pinned(B),
        "pinBlockHashMatchesPlan": A["pinBlockHash"] == pin["blockHash"],
        "safeOwnersMatchPlan": A["safeOwners"] == sorted(o.lower() for o in pin["owners"]),
        "safeThreshold2": A["safeThreshold"] == SAFE_THRESHOLD,
        "safeNonceAtBlockMatchesPlan": A["safeNonceAtBlock"] == pin["safeNonce"],
        "safeNonceLatestNowMatchesPlanBothEndpoints": A["safeNonceLatestNow(unpinned)"] == B["safeNonceLatestNow(unpinned)"] == pin["safeNonce"],
    }
    for nm, s in pin["senders"].items():
        a, b = A["senders"][nm], B["senders"][nm]
        checks[f"{nm}_pinNonceBalanceMatchPlan"] = a["nonceAtPin"] == s["nonce"] and a["balanceAtPin"] == s["balance"]
        checks[f"{nm}_nonceUnchangedSincePin"] = a["nonceAtBlock"] == s["nonce"]
        checks[f"{nm}_firstPlannedNonceEqualsPin"] = planned_first[nm] == s["nonce"]
        checks[f"{nm}_latestEqPendingEqPlanBothEndpoints"] = (
            a["nonceLatestNow(unpinned)"] == a["noncePendingNow(unpinned)"] == b["nonceLatestNow(unpinned)"]
            == b["noncePendingNow(unpinned)"] == s["nonce"])
        checks[f"{nm}_balanceAtBlockCoversBudget"] = a["balanceAtBlock"] >= budgets[nm]
    out = {"note": "read-only; RPC URLs omitted", "plan": plan_path, "block": blk,
           "budgetsWei": budgets, "reads": {"A": A, "B": B}, "checks": checks}
    print(json.dumps(out, indent=1))
    sys.exit(0 if all(checks.values()) else 1)


if __name__ == "__main__":
    main()
