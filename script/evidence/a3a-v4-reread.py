#!/usr/bin/env python3
"""Read-only dual-endpoint re-read for the A3a v4 packet (DSR CC-125 dc77b160).

Usage:
  RPC_A=<archive rpc> RPC_B=<second independent archive rpc> BLOCK=<n> \
    python3 script/evidence/a3a-v4-reread.py docs/release/a3a-precheck-v4/cap-budget-evidence.json > out.json

Reads, at the same block on both endpoints (eth_call / eth_getCode / eth_getTransactionCount /
eth_getTransactionReceipt / eth_getBlockByNumber only; nothing is signed or sent):
  - deployer EOA nonce at BLOCK, plus the endpoint's current `pending` nonce (labelled as such,
    it is not pinned to BLOCK), Safe nonce, SP owner, SP pendingAPNTsToken;
  - codesize at the two predicted A3a addresses (must be 0 = not yet occupied);
  - old-aPNTs balanceOf for every mint recipient. Recipients come from the receipts of the mint
    log ids already recorded in cap-budget-evidence.json (Transfer from 0x0 emitted by the token);
    the (block, tx, logIndex) set found in the receipts must equal the recorded set exactly and
    every mint must be at or before BLOCK.
Exits 1 if the two endpoints disagree on any pinned value or any check is false. RPC URLs are
never written to stdout or stderr (RPC errors are reported by method name only).

Trust scope: every RPC result is shape-validated and the two endpoints must agree on every
pinned value. Two colluding providers returning the same well-formed but false data are out
of scope; that is what the second, independent archive endpoint is for.
"""
import json, os, re, sys, urllib.request

DEPLOYER = "0xb5600060e6de5E11D3636731964218E53caadf0E"
SAFE = "0x51eDf11fDb0A4F66220eFb8efA54Eca77232E114"
SP = "0x09DF0d2e3722EC0e401fE3819E64278a42ae4DE9"
TOKEN = "0x696A73701b104c6cCBbAadDD2216788ea08EaB89"
PREDICTED = {"newTimelock": "0xCCdF8e0D29Fb2c3061910D79484a2b653757C34B",
             "apntsCapped": "0x9Eb17FAc022557F64924aA2F9E018dB3A330e1E7"}
TRANSFER = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
ZERO32 = "0x" + "0" * 64
HOLDER_10M = "0x42ba82a015655f834b9bcb17959c48c02e873e22"  # CAP-BUDGET.md section 2 note
EXPECT_NONCE, EXPECT_SAFE_NONCE = 12131, 1


class RpcFailure(Exception):
    pass
# Fixed 4-byte selectors (cast sig): no keccak dependency.
SEL = {"nonce()": "0xaffed0e0", "owner()": "0x8da5cb5b",
       "pendingAPNTsToken()": "0x60a9139b", "balanceOf(address)": "0x70a08231"}


def rpc(url, method, params):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    try:
        req = urllib.request.Request(url, body, {"Content-Type": "application/json", "User-Agent": "a3a-v4-reread"})
        with urllib.request.urlopen(req, timeout=60) as r:
            d = json.load(r)
    except Exception as e:  # never echo the exception text: it can carry the URL
        raise RpcFailure(f"{method}: transport error ({type(e).__name__})") from None
    if not isinstance(d, dict) or d.get("jsonrpc") != "2.0" or d.get("id") != 1:
        raise RpcFailure(f"{method}: malformed JSON-RPC envelope")
    if "error" in d or d.get("result") is None:
        err = d.get("error")
        code = err.get("code") if isinstance(err, dict) else None
        code = code if isinstance(code, int) and not isinstance(code, bool) else "non-integer"
        raise RpcFailure(f"{method}: rpc error code={code}")
    return d["result"]


HEX = re.compile(r"0x[0-9a-fA-F]*")


def hexdata(method, v, nbytes=None, min_bytes=0):
    """Reject anything that is not well-formed 0x-hex of even length (and the expected size)."""
    if not isinstance(v, str) or not HEX.fullmatch(v) or len(v) % 2:
        raise RpcFailure(f"{method}: malformed hex result")
    n = (len(v) - 2) // 2
    if (nbytes is not None and n != nbytes) or n < min_bytes:
        raise RpcFailure(f"{method}: unexpected result length {n}")
    return v


def quantity(method, v):
    if not isinstance(v, str) or not re.fullmatch(r"0x(0|[1-9a-fA-F][0-9a-fA-F]*)", v):
        raise RpcFailure(f"{method}: malformed quantity")
    return int(v, 16)


def word_addr(method, w):
    """ABI address word: 12 zero bytes then 20 address bytes."""
    w = hexdata(method, w, nbytes=32)
    if w[2:26] != "0" * 24:
        raise RpcFailure(f"{method}: non-zero address padding")
    return "0x" + w[-40:].lower()


def call(url, to, data, blk):
    return hexdata("eth_call", rpc(url, "eth_call", [{"to": to, "data": data}, hex(blk)]), nbytes=32)


def addr_word(a):
    return a.lower().removeprefix("0x").rjust(64, "0")


def main():
    ev = json.load(open(sys.argv[1]))
    blk = int(os.environ["BLOCK"])
    urls = {"A": os.environ["RPC_A"], "B": os.environ["RPC_B"]}
    if urls["A"].strip().rstrip("/") == urls["B"].strip().rstrip("/"):
        raise RpcFailure("config: RPC_A and RPC_B must be different endpoints")
    recorded = {(int(b), tx.lower(), int(li)) for b, tx, li in (i.split(":") for i in ev["logIds"]["mints"])}
    mint_txs = sorted({tx for _, tx, _ in recorded})

    # Mint recipients from receipts (read once per endpoint; must agree). Every recorded
    # (block, tx, logIndex) must be found, nothing else may be found, and all must be <= BLOCK.
    recips, found = {}, {}
    for k, u in urls.items():
        s, f = set(), {}
        for tx in mint_txs:
            rc = rpc(u, "eth_getTransactionReceipt", [tx])
            M = "eth_getTransactionReceipt"
            if not isinstance(rc, dict) or not isinstance(rc.get("logs"), list):
                raise RpcFailure(f"{M}: malformed receipt")
            if quantity(M, rc.get("status")) != 1:
                raise RpcFailure(f"{M}: receipt status is not success")
            if hexdata(M, rc.get("transactionHash"), nbytes=32).lower() != tx:
                raise RpcFailure(f"{M}: receipt for a different transaction")
            rc_blk = quantity(M, rc.get("blockNumber"))
            hexdata(M, rc.get("blockHash"), nbytes=32)
            for lg in rc["logs"]:
                if not isinstance(lg, dict) or lg.get("removed") is not False or not isinstance(lg.get("topics"), list):
                    raise RpcFailure(f"{M}: malformed or removed log")
                t = [hexdata(M, x, nbytes=32).lower() for x in lg["topics"]]
                # Every log in the receipt is validated, not only the mint logs.
                l_addr = hexdata(M, lg.get("address"), nbytes=20).lower()
                l_data = hexdata(M, lg.get("data")).lower()
                l_id = (quantity(M, lg.get("blockNumber")), hexdata(M, lg.get("transactionHash"), nbytes=32).lower(),
                        quantity(M, lg.get("logIndex")))
                hexdata(M, lg.get("blockHash"), nbytes=32)
                if l_id[0] != rc_blk or l_id[1] != tx:
                    raise RpcFailure(f"{M}: log does not belong to its receipt")
                if l_addr == TOKEN.lower() and t and t[0] == TRANSFER and len(t) == 3 and t[1] == ZERO32:
                    rec = word_addr(M, t[2])
                    amt = int(hexdata(M, l_data, nbytes=32), 16)
                    if l_id in f:
                        raise RpcFailure(f"{M}: duplicate mint log")
                    s.add(rec)
                    f[l_id] = (rec, str(amt))
        recips[k], found[k] = sorted(s), f

    out = {"note": "read-only; RPC URLs omitted", "block": blk, "reads": {}}
    for k, u in urls.items():
        bh = rpc(u, "eth_getBlockByNumber", [hex(blk), False])
        if not isinstance(bh, dict) or quantity("eth_getBlockByNumber", bh.get("number")) != blk:
            raise RpcFailure("eth_getBlockByNumber: wrong or missing block")
        r = {"blockHash": hexdata("eth_getBlockByNumber", bh.get("hash"), nbytes=32),
             "deployerNonceAtBlock": quantity("eth_getTransactionCount", rpc(u, "eth_getTransactionCount", [DEPLOYER, hex(blk)])),
             "deployerNoncePendingNow(unpinned)": quantity("eth_getTransactionCount", rpc(u, "eth_getTransactionCount", [DEPLOYER, "pending"])),
             "safeNonce": int(call(u, SAFE, SEL["nonce()"], blk), 16),
             "spOwner": word_addr("eth_call", call(u, SP, SEL["owner()"], blk)),
             "spPendingAPNTsToken": word_addr("eth_call", call(u, SP, SEL["pendingAPNTsToken()"], blk)),
             "codesize": {n: (len(hexdata("eth_getCode", rpc(u, "eth_getCode", [a, hex(blk)]))) - 2) // 2 for n, a in PREDICTED.items()},
             "mintRecipientBalances": {a: str(int(call(u, TOKEN, SEL["balanceOf(address)"] + addr_word(a), blk), 16))
                                       for a in recips["A"]}}
        out["reads"][k] = r

    pinned = lambda r: {x: y for x, y in r.items() if x != "deployerNoncePendingNow(unpinned)"}
    a, b = out["reads"]["A"], out["reads"]["B"]
    out["checks"] = {
        "mintRecipientsIdentical": recips["A"] == recips["B"],
        "mintRecipientsNonEmpty": len(recips["A"]) > 0,
        "mintLogSetMatchesRecordedA": set(found["A"]) == recorded,
        "mintLogSetMatchesRecordedB": set(found["B"]) == recorded,
        # Per-log agreement: same recipient and amount for every (block, tx, logIndex).
        "mintLogsIdenticalPerLog": found["A"] == found["B"],
        "mintSumMatchesRecorded": sum(int(v[1]) for v in found["A"].values()) == int(ev["logs"]["A"]["mints"]["sum"]),
        "mintsAtOrBeforeBlock": all(bn <= blk for bn, _, _ in recorded),
        "pinnedReadsIdentical": pinned(a) == pinned(b),
        "predictedAddressesEmpty": all(v == 0 for r in (a, b) for v in r["codesize"].values()),
        "deployerNonce12131": a["deployerNonceAtBlock"] == EXPECT_NONCE,
        "deployerPendingNow12131BothEndpoints": a["deployerNoncePendingNow(unpinned)"] == EXPECT_NONCE
                                                and b["deployerNoncePendingNow(unpinned)"] == EXPECT_NONCE,
        "safeNonce1": a["safeNonce"] == EXPECT_SAFE_NONCE,
        "holder42ba10M": a["mintRecipientBalances"].get(HOLDER_10M) == str(10_000_000 * 10**18),
        "spOwnerIsDeployer": a["spOwner"].lower() == DEPLOYER.lower(),
        "pendingStillOldBb46": a["spPendingAPNTsToken"].lower() == "0xbb46321545a91db2f3b5c3e694f2f23abe259883",
    }
    json.dump(out, sys.stdout, indent=1)
    print()
    sys.exit(0 if all(out["checks"].values()) else 1)


if __name__ == "__main__":
    try:
        main()
    except RpcFailure as e:
        print(f"a3a-v4-reread: {e}", file=sys.stderr)
        sys.exit(2)
    except Exception as e:  # anything else: type only, never the message (may carry provider text)
        print(f"a3a-v4-reread: unexpected {type(e).__name__}", file=sys.stderr)
        sys.exit(3)
