#!/usr/bin/env python3
"""Offline positive and negative controls for a3a-funding-provenance.py (no network).

Fake endpoints serve the values recorded in the committed funding-provenance.json; each control changes one.
"""
import contextlib, copy, importlib.util, io, json, os, tempfile, unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("funding", ROOT / "script/evidence/a3a-funding-provenance.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
PLAN = ROOT / "docs/release/a3a-newpin-11995523/a3a-plan/plan.json"
RECORDED = json.loads((ROOT / "docs/release/a3a-newpin-11995523/sp01-reread-11998826/funding-provenance.json").read_text())
TX = RECORDED["reads"]["A"]["tx"]["hash"]


class Endpoint:
    def __init__(self, reads, pin=None):
        self.r, self.pin = copy.deepcopy(reads), pin or RECORDED["pinBlock"]

    def __call__(self, method, params):
        r, d = self.r, self.r["deployer"]
        blk, pin = r["receipt"]["blockNumber"], self.pin
        if method == "eth_getTransactionByHash":
            t = r["tx"]
            return {"hash": t["hash"], "from": t["from"], "to": t["to"], "nonce": hex(t["nonce"]),
                    "value": hex(t["valueWei"]), "input": t["input"]}
        if method == "eth_getTransactionReceipt":
            rc = r["receipt"]
            return {"status": rc["status"], "blockNumber": hex(rc["blockNumber"]), "blockHash": rc["blockHash"],
                    "gasUsed": hex(rc["gasUsed"]), "logs": rc["logs"]}
        if method == "eth_getBlockByNumber":
            return {"hash": r["canonicalBlockHash"]}
        b = int(params[1], 16)
        if method == "eth_getBalance":
            return hex({blk - 1: d["balanceBefore"], blk: d["balanceAt"], pin: d["balanceAtPin"]}[b])
        if method == "eth_getTransactionCount":
            return hex({blk - 1: d["nonceBefore"], blk: d["nonceAt"], pin: d["nonceAtPin"]}[b])
        if method == "eth_getCode":
            return d["codeAtPin"]
        raise AssertionError(method)


class FundingControls(unittest.TestCase):
    def run_script(self, edit=None, urls=("https://a.invalid", "https://b.invalid"), plan_path=PLAN, pin=None):
        a, b = Endpoint(RECORDED["reads"]["A"], pin), Endpoint(RECORDED["reads"]["B"], pin)
        if edit:
            for e in (a, b):
                edit(e.r)
        eps = dict(zip(urls, (a, b)))
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.dict(os.environ, {"RPC_A": urls[0], "RPC_B": urls[1]}), \
                mock.patch.object(m, "rpc", lambda u, meth, p: eps[u](meth, p)), \
                mock.patch("sys.argv", ["x", str(plan_path), TX]), contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            with self.assertRaises(SystemExit) as c:
                m.main()
        res = json.loads(out.getvalue()) if out.getvalue() else None
        return c.exception.code, sorted(k for k, v in res["checks"].items() if not v) if res else None, err.getvalue()

    def test_positive_recorded(self):
        self.assertEqual(self.run_script()[:2], (0, []))

    def test_controls(self):
        def logs(f):
            return lambda r: f(r["receipt"]["logs"][0])
        cases = {
            "reverted": (lambda r: r["receipt"].__setitem__("status", "0x0"), ["receiptSuccess"]),
            "reorged": (lambda r: r.__setitem__("canonicalBlockHash", "0x" + "00" * 32), ["receiptBlockCanonical"]),
            "wrong recipient": (lambda r: r["tx"].__setitem__("to", "0x" + "11" * 20), ["plainValueTransferToDeployer"]),
            "log recipient": (logs(lambda x: x["topics"].__setitem__(2, "0x" + "00" * 12 + "11" * 20)),
                              ["onlyLogIsEip7708EthTransfer"]),
            "contract call": (lambda r: r["tx"].__setitem__("input", "0xabcdef01"), ["plainValueTransferToDeployer"]),
            "log value": (logs(lambda x: x.__setitem__("data", "0x" + "00" * 31 + "01")), ["onlyLogIsEip7708EthTransfer"]),
            "log emitter": (logs(lambda x: x.__setitem__("address", "0x" + "22" * 20)), ["onlyLogIsEip7708EthTransfer"]),
            "extra log": (lambda r: r["receipt"]["logs"].append(dict(r["receipt"]["logs"][0])), ["onlyLogIsEip7708EthTransfer"]),
            "balance delta": (lambda r: r["deployer"].__setitem__("balanceBefore", r["deployer"]["balanceBefore"] + 1),
                              ["balanceRoseByExactlyValue"]),
            "deployer sent": (lambda r: r["deployer"].__setitem__("nonceAtPin", r["deployer"]["nonceAtPin"] + 1),
                              ["deployerNonceUnchanged"]),
            "later change": (lambda r: r["deployer"].__setitem__("balanceAtPin", r["deployer"]["balanceAtPin"] + 1),
                             ["noOtherBalanceChangeUntilPin"]),
            "delegated": (lambda r: r["deployer"].__setitem__("codeAtPin", "0xef0100" + "33" * 20), ["deployerHasNoCodeAtPin"]),
        }
        for name, (edit, want) in cases.items():
            with self.subTest(name):
                code, false, _ = self.run_script(edit)
                self.assertEqual((code, false), (1, want))

    def test_mined_at_pin_block(self):
        # The funding must precede the pin: a plan pinned at the funding block itself must fail only that check.
        plan = json.loads(PLAN.read_text())
        plan["pin"]["block"] = hex(RECORDED["reads"]["A"]["receipt"]["blockNumber"])
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "plan.json"
            path.write_text(json.dumps(plan))
            code, false, _ = self.run_script(plan_path=path, pin=RECORDED["reads"]["A"]["receipt"]["blockNumber"])
        self.assertEqual((code, false), (1, ["minedBeforePin"]))

    def test_endpoint_divergence(self):
        a, b = Endpoint(RECORDED["reads"]["A"]), Endpoint(RECORDED["reads"]["B"])
        b.r["receipt"]["gasUsed"] += 1
        eps = {"https://a.invalid": a, "https://b.invalid": b}
        out = io.StringIO()
        with mock.patch.dict(os.environ, {"RPC_A": "https://a.invalid", "RPC_B": "https://b.invalid"}), \
                mock.patch.object(m, "rpc", lambda u, meth, p: eps[u](meth, p)), \
                mock.patch("sys.argv", ["x", str(PLAN), TX]), contextlib.redirect_stdout(out):
            with self.assertRaises(SystemExit) as c:
                m.main()
        self.assertEqual(c.exception.code, 1)
        self.assertEqual(sorted(k for k, v in json.loads(out.getvalue())["checks"].items() if not v), ["readsIdentical"])

    def test_same_endpoint_twice(self):
        code, false, err = self.run_script(urls=("https://a.invalid/", "https://a.invalid"))
        self.assertEqual((code, false), (1, None))
        self.assertIn("must be different endpoints", err)


if __name__ == "__main__":
    unittest.main()
