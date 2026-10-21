#!/usr/bin/env python3
"""Offline tests for a3a-v4-reread.py (no network). Run: python3 script/evidence/test_a3a_v4_reread.py

A fake two-endpoint chain is served through a patched `rpc`. The healthy chain must exit 0 with
every check true (positive control); each mutation must make the script fail (exit 1, a false
check) or reject the response (exit 2).
"""
import copy, importlib.util, io, json, os, sys, tempfile, contextlib

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("reread", os.path.join(HERE, "a3a-v4-reread.py"))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

BLK = 1000
W = lambda a: "0x" + "0" * 24 + a.lower().removeprefix("0x")
Q = hex
BH = "0x" + "bb" * 32
TX1, TX2 = "0x" + "11" * 32, "0x" + "22" * 32
R1, R2 = "0x42ba82a015655f834b9bcb17959c48c02e873e22", "0x" + "ab" * 20
AMT1, AMT2 = 10_000_000 * 10**18, 5 * 10**18
EVIDENCE = {"logIds": {"mints": [f"900:{TX1}:3", f"901:{TX2}:0"]},
            "logs": {"A": {"mints": {"sum": str(AMT1 + AMT2)}}}}


def mint_log(blk, tx, idx, to, amt, bh):
    return {"address": m.TOKEN, "topics": [m.TRANSFER, m.ZERO32, W(to)], "data": "0x" + hex(amt)[2:].rjust(64, "0"),
            "blockNumber": Q(blk), "transactionHash": tx, "logIndex": Q(idx), "blockHash": bh, "removed": False}


def healthy():
    bh900, bh901 = "0x" + "90" * 32, "0x" + "91" * 32
    return {
        "chainId": Q(11155111),
        "safe_latest": "0x" + hex(1)[2:].rjust(64, "0"),
        "block": {"number": Q(BLK), "hash": BH},
        "nonce_at": Q(12131), "nonce_pending": Q(12131),
        "calls": {(m.SAFE.lower(), m.SEL["nonce()"]): "0x" + hex(1)[2:].rjust(64, "0"),
                  (m.SP.lower(), m.SEL["owner()"]): W(m.DEPLOYER),
                  (m.SP.lower(), m.SEL["pendingAPNTsToken()"]): W("0xBb46321545a91DB2F3B5c3e694F2f23aBe259883")},
        "balances": {R1.lower(): AMT1, R2.lower(): AMT2},
        "code": "0x",
        "receipts": {TX1: {"status": "0x1", "transactionHash": TX1, "blockNumber": Q(900), "blockHash": bh900,
                           "logs": [mint_log(900, TX1, 3, R1, AMT1, bh900)]},
                     TX2: {"status": "0x1", "transactionHash": TX2, "blockNumber": Q(901), "blockHash": bh901,
                           "logs": [mint_log(901, TX2, 0, R2, AMT2, bh901)]}},
    }


def make_rpc(chains):
    def rpc(url, method, params):
        c = chains[url]
        if method == "eth_chainId":
            return c["chainId"]
        if method == "eth_getBlockByNumber":
            return c["block"]
        if method == "eth_getTransactionCount":
            return c["nonce_pending"] if params[1] == "pending" else c["nonce_at"]
        if method == "eth_getCode":
            return c["code"]
        if method == "eth_getTransactionReceipt":
            return c["receipts"][params[0]]
        if method == "eth_call":
            to, data = params[0]["to"].lower(), params[0]["data"]
            if params[1] == "latest" and to == m.SAFE.lower():
                return c["safe_latest"]
            if data.startswith(m.SEL["balanceOf(address)"]):
                return "0x" + hex(c["balances"].get("0x" + data[-40:], 0))[2:].rjust(64, "0")
            return c["calls"][(to, data)]
        raise AssertionError(method)
    return rpc


def run(chain_a, chain_b, a_url="https://a.invalid", b_url="https://b.invalid", blk=BLK):
    m.rpc = make_rpc({a_url: chain_a, b_url: chain_b})
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        json.dump(EVIDENCE, f)
    os.environ.update(RPC_A=a_url, RPC_B=b_url, BLOCK=str(blk))
    sys.argv = ["x", f.name]
    out = io.StringIO()
    try:
        with contextlib.redirect_stdout(out):
            m.main()
        code = 0
    except SystemExit as e:
        code = e.code
    except m.RpcFailure:
        code = 2
    os.unlink(f.name)
    return code


def mutate(fn):
    a, b = healthy(), healthy()
    fn(a, b)
    return run(a, b)


CASES = {
    "pending nonce drift on A": lambda a, b: a.update(nonce_pending=Q(12132)),
    "pending nonce drift on B": lambda a, b: b.update(nonce_pending=Q(12132)),
    "pinned nonce drift": lambda a, b: (a.update(nonce_at=Q(12132)), b.update(nonce_at=Q(12132))),
    "predicted address occupied": lambda a, b: (a.update(code="0x60"), b.update(code="0x60")),
    "block hash disagrees": lambda a, b: b["block"].update(hash="0x" + "cc" * 32),
    "recipients rotated on B": lambda a, b: (b["receipts"][TX1]["logs"][0]["topics"].__setitem__(2, W(R2)),
                                             b["receipts"][TX2]["logs"][0]["topics"].__setitem__(2, W(R1))),
    "amount changed on B": lambda a, b: b["receipts"][TX2]["logs"][0].update(data="0x" + hex(AMT2 + 1)[2:].rjust(64, "0")),
    "mint missing on both": lambda a, b: [c["receipts"][TX2].update(logs=[]) for c in (a, b)],
    "duplicate mint log on A": lambda a, b: a["receipts"][TX1]["logs"].append(copy.deepcopy(a["receipts"][TX1]["logs"][0])),
    "removed log on A": lambda a, b: a["receipts"][TX1]["logs"][0].update(removed=True),
    "failed receipt on A": lambda a, b: a["receipts"][TX1].update(status="0x0"),
    "log blockHash != receipt on A": lambda a, b: a["receipts"][TX1]["logs"][0].update(blockHash="0x" + "ee" * 32),
    "malformed getCode on A": lambda a, b: a.update(code="0x0"),
    "address padding on A": lambda a, b: a["calls"].__setitem__((m.SP.lower(), m.SEL["owner()"]), "0x" + "11" * 12 + m.DEPLOYER[2:].lower()),
    "wrong chain id on both (fork)": lambda a, b: [c.update(chainId=Q(31337)) for c in (a, b)],
    "Safe nonce moved at BLOCK": lambda a, b: [c["calls"].__setitem__((m.SAFE.lower(), m.SEL["nonce()"]), "0x" + hex(2)[2:].rjust(64, "0")) for c in (a, b)],
    "Safe nonce moved since BLOCK on B": lambda a, b: b.update(safe_latest="0x" + hex(2)[2:].rjust(64, "0")),
    "SP owner changed": lambda a, b: [c["calls"].__setitem__((m.SP.lower(), m.SEL["owner()"]), W(m.SAFE)) for c in (a, b)],
    "pending token changed": lambda a, b: [c["calls"].__setitem__((m.SP.lower(), m.SEL["pendingAPNTsToken()"]), W("0x" + "cd" * 20)) for c in (a, b)],
    "mint sum differs from recorded": lambda a, b: [c["receipts"][TX2]["logs"][0].update(data="0x" + hex(AMT2 + 7)[2:].rjust(64, "0")) for c in (a, b)],
    # Same recipient and amount, different log identity on both endpoints: only the
    # recorded-set checks (mintLogSetMatchesRecordedA/B) can catch this.
    "mint logIndex shifted on both": lambda a, b: [c["receipts"][TX1]["logs"][0].update(logIndex=Q(4)) for c in (a, b)],
    "holder balance not 10M": lambda a, b: [c["balances"].__setitem__(R1.lower(), AMT1 - 1) for c in (a, b)],
}


def main():
    fails = 0
    code = run(healthy(), healthy())
    print(f"positive control (healthy chain): exit {code}")
    fails += code != 0
    code = run(healthy(), healthy(), "https://same.invalid", "https://same.invalid/")
    print(f"same endpoint twice: exit {code}")
    fails += code == 0
    # BLOCK pinned between the two recorded mints: the 901 mint is "in the future".
    early_a, early_b = healthy(), healthy()
    for c in (early_a, early_b):
        c["block"]["number"] = Q(900)
    code = run(early_a, early_b, blk=900)
    print(f"mint after BLOCK: exit {code}")
    fails += code == 0
    for name, fn in CASES.items():
        code = mutate(fn)
        print(f"{name}: exit {code}")
        fails += code == 0
    print("FAIL" if fails else "PASS", f"({fails} wrong)")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
