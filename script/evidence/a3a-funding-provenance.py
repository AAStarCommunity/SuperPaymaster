#!/usr/bin/env python3
"""Read-only dual-endpoint provenance of the deployer funding before the A3a pin (DSR M1 gap IG-04).

Usage:
  RPC_A=<archive rpc> RPC_B=<second independent archive rpc> \
    python3 script/evidence/a3a-funding-provenance.py docs/release/a3a-newpin-11995523/a3a-plan/plan.json \
    0x1bf66ae42dcb55c7b4fa37f2ed39604faf1b31dd1d52e5395971dc78a3417495 > out.json

On both endpoints: chain id and the pin block hash (bound to the plan), the transaction and its receipt
(hash and block identity must agree with each other and with the requested hash), the deployer's balance and nonce in the blocks just before and
at the funding block, and the deployer's balance at the plan pin. Checks that the funding is a successful plain
value transfer to the deployer, mined before the pin, whose only log is the EIP-7708 Transfer for that value; that the deployer's balance rose by exactly that value with no
nonce change; and that nothing else moved the deployer's balance or nonce between the funding block and the pin.
Methods used: eth_chainId, eth_getTransactionByHash, eth_getTransactionReceipt, eth_getBlockByNumber, eth_getBalance,
eth_getTransactionCount, eth_getCode. Nothing is signed or sent. Exits 1 on any endpoint disagreement or false check.
"""
import json, os, sys, urllib.request


# Amsterdam (EIP-7708): a value transfer emits ERC-20-shaped Transfer(from, to, value) from this system address.
EIP7708_SYSTEM = "0xfffffffffffffffffffffffffffffffffffffffe"
TRANSFER = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"


def word(addr):
    return "0x" + addr.lower().removeprefix("0x").rjust(64, "0")


class RpcFailure(Exception):
    pass


def rpc(url, method, params):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    try:
        req = urllib.request.Request(url, body, {"Content-Type": "application/json", "User-Agent": "a3a-funding"})
        with urllib.request.urlopen(req, timeout=60) as r:
            d = json.load(r)
    except Exception as e:  # never echo the exception text: it can carry the URL
        raise RpcFailure(f"{method}: transport error ({type(e).__name__})") from None
    if not isinstance(d, dict) or d.get("id") != 1 or "error" in d or d.get("result") is None:
        raise RpcFailure(f"{method}: rpc error or malformed envelope")
    return d["result"]


def read(url, deployer, txh, pin_blk):
    tx = rpc(url, "eth_getTransactionByHash", [txh])
    rc = rpc(url, "eth_getTransactionReceipt", [txh])
    blk = int(rc["blockNumber"], 16)
    bal = lambda b: int(rpc(url, "eth_getBalance", [deployer, hex(b)]), 16)
    nonce = lambda b: int(rpc(url, "eth_getTransactionCount", [deployer, hex(b)]), 16)
    return {
        "chainId": int(rpc(url, "eth_chainId", []), 16),
        "pinBlockHash": rpc(url, "eth_getBlockByNumber", [hex(pin_blk), False])["hash"].lower(),
        "tx": {"hash": tx["hash"].lower(), "from": tx["from"].lower(), "to": (tx["to"] or "").lower(),
               "nonce": int(tx["nonce"], 16), "valueWei": int(tx["value"], 16), "input": tx["input"],
               "blockNumber": int(tx["blockNumber"], 16), "blockHash": tx["blockHash"].lower()},
        "receipt": {"transactionHash": rc["transactionHash"].lower(), "status": rc["status"],
                    "blockNumber": blk, "blockHash": rc["blockHash"].lower(),
                    "gasUsed": int(rc["gasUsed"], 16),
                    "logs": [{"address": x["address"].lower(), "topics": [y.lower() for y in x["topics"]],
                              "data": x["data"].lower()} for x in rc["logs"]]},
        "canonicalBlockHash": rpc(url, "eth_getBlockByNumber", [hex(blk), False])["hash"].lower(),
        "deployer": {"balanceBefore": bal(blk - 1), "nonceBefore": nonce(blk - 1),
                     "balanceAt": bal(blk), "nonceAt": nonce(blk),
                     "balanceAtPin": bal(pin_blk), "nonceAtPin": nonce(pin_blk),
                     "codeAtPin": rpc(url, "eth_getCode", [deployer, hex(pin_blk)]).lower()},
    }


def main():
    plan = json.load(open(sys.argv[1]))
    txh = sys.argv[2].lower()
    a_url, b_url = os.environ["RPC_A"], os.environ["RPC_B"]
    if a_url.strip().rstrip("/") == b_url.strip().rstrip("/"):
        print("config: RPC_A and RPC_B must be different endpoints", file=sys.stderr)
        sys.exit(1)
    pin = plan["pin"]
    deployer = pin["senders"]["deployer"]["address"].lower()
    pin_blk = int(pin["block"], 16)
    try:
        A, B = read(a_url, deployer, txh, pin_blk), read(b_url, deployer, txh, pin_blk)
    except RpcFailure as e:
        print(f"RPC failure: {e}", file=sys.stderr)
        sys.exit(1)
    d, t = A["deployer"], A["tx"]
    checks = {
        "readsIdentical": A == B,
        "chainMatchesPlan": A["chainId"] == plan["chainId"],
        "pinBlockHashMatchesPlan": A["pinBlockHash"] == pin["blockHash"].lower(),
        "txIdentity": t["hash"] == A["receipt"]["transactionHash"] == txh
                      and (t["blockNumber"], t["blockHash"]) == (A["receipt"]["blockNumber"], A["receipt"]["blockHash"]),
        "receiptSuccess": A["receipt"]["status"] == "0x1",
        "receiptBlockCanonical": A["receipt"]["blockHash"] == A["canonicalBlockHash"],
        "plainValueTransferToDeployer": t["to"] == deployer and t["input"] in ("0x", ""),
        "onlyLogIsEip7708EthTransfer": A["receipt"]["logs"] == [{
            "address": EIP7708_SYSTEM, "topics": [TRANSFER, word(t["from"]), word(deployer)],
            "data": "0x" + format(t["valueWei"], "064x")}],
        "minedBeforePin": A["receipt"]["blockNumber"] < pin_blk,
        "balanceRoseByExactlyValue": d["balanceAt"] - d["balanceBefore"] == t["valueWei"] > 0,
        "deployerNonceUnchanged": d["nonceBefore"] == d["nonceAt"] == d["nonceAtPin"] == pin["senders"]["deployer"]["nonce"],
        # Compares the two ends only. Combined with no code and an unchanged nonce, the balance cannot have fallen
        # in between (an EOA without code loses ETH only through its own transactions), so equal ends mean it did
        # not change at all.
        "noOtherBalanceChangeUntilPin": d["balanceAtPin"] == d["balanceAt"] == pin["senders"]["deployer"]["balance"],
        "deployerHasNoCodeAtPin": d["codeAtPin"] == "0x",
    }
    print(json.dumps({"note": "read-only; RPC URLs omitted", "plan": sys.argv[1], "pinBlock": pin_blk,
                      "reads": {"A": A, "B": B}, "checks": checks}, indent=1))
    sys.exit(0 if all(checks.values()) else 1)


if __name__ == "__main__":
    main()
