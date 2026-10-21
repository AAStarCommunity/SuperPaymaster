#!/usr/bin/env python3
"""Read-only dual-endpoint re-read for the A3a v4 packet (DSR CC-125 dc77b160).

Usage:
  RPC_A=<archive rpc> RPC_B=<second independent archive rpc> BLOCK=<n> \
    python3 script/evidence/a3a-v4-reread.py docs/release/a3a-precheck-v4/cap-budget-evidence.json > out.json

Reads, at the same block on both endpoints (eth_call / eth_getCode / eth_getTransactionCount /
eth_getTransactionReceipt only; nothing is sent):
  - deployer EOA nonce at BLOCK, plus the endpoint's current `pending` nonce (labelled as such,
    it is not pinned to BLOCK), Safe nonce, SP owner, SP pendingAPNTsToken;
  - codesize at the two predicted A3a addresses (must be 0 = not yet occupied);
  - old-aPNTs balanceOf for every mint recipient. Recipients come from the receipts of the mint
    log ids already recorded in cap-budget-evidence.json (Transfer from 0x0 emitted by the token).
Exits 1 if the two endpoints disagree on any pinned value or any check is false. RPC URLs are
never written to stdout.
"""
import json, os, sys, urllib.request

DEPLOYER = "0xb5600060e6de5E11D3636731964218E53caadf0E"
SAFE = "0x51eDf11fDb0A4F66220eFb8efA54Eca77232E114"
SP = "0x09DF0d2e3722EC0e401fE3819E64278a42ae4DE9"
TOKEN = "0x696A73701b104c6cCBbAadDD2216788ea08EaB89"
PREDICTED = {"newTimelock": "0xCCdF8e0D29Fb2c3061910D79484a2b653757C34B",
             "apntsCapped": "0x9Eb17FAc022557F64924aA2F9E018dB3A330e1E7"}
TRANSFER = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
ZERO32 = "0x" + "0" * 64
# Fixed 4-byte selectors (cast sig): no keccak dependency.
SEL = {"nonce()": "0xaffed0e0", "owner()": "0x8da5cb5b",
       "pendingAPNTsToken()": "0x60a9139b", "balanceOf(address)": "0x70a08231"}


def rpc(url, method, params):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    req = urllib.request.Request(url, body, {"Content-Type": "application/json", "User-Agent": "a3a-v4-reread"})
    with urllib.request.urlopen(req, timeout=60) as r:
        d = json.load(r)
    if "error" in d:
        raise RuntimeError(f"{method}: {d['error']}")
    return d["result"]


def call(url, to, data, blk):
    return rpc(url, "eth_call", [{"to": to, "data": data}, hex(blk)])


def addr_word(a):
    return a.lower().removeprefix("0x").rjust(64, "0")


def main():
    ev = json.load(open(sys.argv[1]))
    blk = int(os.environ["BLOCK"])
    urls = {"A": os.environ["RPC_A"], "B": os.environ["RPC_B"]}
    mint_txs = sorted({i.split(":")[1] for i in ev["logIds"]["mints"]})

    # Mint recipients from receipts (read once per endpoint; must agree).
    recips = {}
    for k, u in urls.items():
        s = set()
        for tx in mint_txs:
            rc = rpc(u, "eth_getTransactionReceipt", [tx])
            for lg in rc["logs"]:
                t = lg["topics"]
                if lg["address"].lower() == TOKEN.lower() and t[0] == TRANSFER and t[1] == ZERO32:
                    s.add("0x" + t[2][-40:])
        recips[k] = sorted(s)

    out = {"note": "read-only; RPC URLs omitted", "block": blk, "reads": {}}
    for k, u in urls.items():
        r = {"blockHash": rpc(u, "eth_getBlockByNumber", [hex(blk), False])["hash"],
             "deployerNonceAtBlock": int(rpc(u, "eth_getTransactionCount", [DEPLOYER, hex(blk)]), 16),
             "deployerNoncePendingNow(unpinned)": int(rpc(u, "eth_getTransactionCount", [DEPLOYER, "pending"]), 16),
             "safeNonce": int(call(u, SAFE, SEL["nonce()"], blk), 16),
             "spOwner": "0x" + call(u, SP, SEL["owner()"], blk)[-40:],
             "spPendingAPNTsToken": "0x" + call(u, SP, SEL["pendingAPNTsToken()"], blk)[-40:],
             "codesize": {n: (len(rpc(u, "eth_getCode", [a, hex(blk)])) - 2) // 2 for n, a in PREDICTED.items()},
             "mintRecipientBalances": {a: str(int(call(u, TOKEN, SEL["balanceOf(address)"] + addr_word(a), blk), 16))
                                       for a in recips["A"]}}
        out["reads"][k] = r

    pinned = lambda r: {x: y for x, y in r.items() if x != "deployerNoncePendingNow(unpinned)"}
    a, b = out["reads"]["A"], out["reads"]["B"]
    out["checks"] = {
        "mintRecipientsIdentical": recips["A"] == recips["B"],
        "mintRecipientsNonEmpty": len(recips["A"]) > 0,
        "pinnedReadsIdentical": pinned(a) == pinned(b),
        "predictedAddressesEmpty": all(v == 0 for r in (a, b) for v in r["codesize"].values()),
        "deployerNonce12131": a["deployerNonceAtBlock"] == 12131,
        "safeNonce1": a["safeNonce"] == 1,
        "spOwnerIsDeployer": a["spOwner"].lower() == DEPLOYER.lower(),
        "pendingStillOldBb46": a["spPendingAPNTsToken"].lower() == "0xbb46321545a91db2f3b5c3e694f2f23abe259883",
    }
    json.dump(out, sys.stdout, indent=1)
    print()
    sys.exit(0 if all(out["checks"].values()) else 1)


if __name__ == "__main__":
    main()
