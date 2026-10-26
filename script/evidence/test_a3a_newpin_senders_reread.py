#!/usr/bin/env python3
"""Offline positive and negative controls for a3a-newpin-senders-reread.py (no network).

The fake endpoints serve the values recorded in the committed 11,998,826 re-read, so the positive control
reproduces that run's 22/22 and each negative control changes one served value.
"""
import contextlib, copy, importlib.util, io, json, os, unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("reread", ROOT / "script/evidence/a3a-newpin-senders-reread.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
PLAN = ROOT / "docs/release/a3a-newpin-11995523/a3a-plan/plan.json"
RECORDED = json.loads((ROOT / "docs/release/a3a-newpin-11995523/sp01-reread-11998826/senders-11998826.json").read_text())
BLOCK = RECORDED["block"]


def word(v):
    return "0x" + format(v, "064x")


def owners_abi(owners, offset=32):
    body = format(len(owners), "064x") + "".join(o[2:].rjust(64, "0") for o in owners)
    return "0x" + format(offset, "064x") + "0" * (2 * (offset - 32)) + body


class Endpoint:
    def __init__(self, reads):
        self.r = copy.deepcopy(reads)
        self.owners_raw = owners_abi(self.r["safeOwners"])

    def __call__(self, method, params):
        r, pin_blk = self.r, json.loads(PLAN.read_text())["pin"]["block"]
        if method == "eth_chainId":
            return hex(r["chainId"])
        if method == "eth_getBlockByNumber":
            return {"hash": r["pinBlockHash"] if params[0] == pin_blk else r["blockHash"]}
        if method in ("eth_getTransactionCount", "eth_getBalance"):
            addr, tag = params[0].lower(), params[1]
            s = next(s for s in r["senders"].values() if s["address"].lower() == addr)
            kind = "nonce" if method == "eth_getTransactionCount" else "balance"
            key = {pin_blk: f"{kind}AtPin", hex(BLOCK): f"{kind}AtBlock",
                   "latest": "nonceLatestNow(unpinned)", "pending": "noncePendingNow(unpinned)"}[tag]
            return hex(s[key])
        if method == "eth_call":
            data, tag = params[0]["data"], params[1]
            if data == m.SEL["nonce()"]:
                return word(r["safeNonceAtBlock"] if tag == hex(BLOCK) else r["safeNonceLatestNow(unpinned)"])
            if data == m.SEL["getThreshold()"]:
                return word(r["safeThreshold"])
            if data == m.SEL["getOwners()"]:
                return self.owners_raw
        raise AssertionError(f"unexpected {method}")


class RereadControls(unittest.TestCase):
    def run_script(self, a, b, urls=("https://a.invalid", "https://b.invalid")):
        eps = dict(zip(urls, (a, b)))
        out, err = io.StringIO(), io.StringIO()
        env = {"RPC_A": urls[0], "RPC_B": urls[1], "BLOCK": str(BLOCK)}
        with mock.patch.dict(os.environ, env), mock.patch.object(m, "rpc", lambda u, meth, p: eps[u](meth, p)), \
                mock.patch("sys.argv", ["x", str(PLAN)]), contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            with self.assertRaises(SystemExit) as c:
                m.main()
        result = json.loads(out.getvalue()) if out.getvalue() else None
        false = sorted(k for k, v in result["checks"].items() if not v) if result else None
        return c.exception.code, false, err.getvalue()

    def recorded(self):
        return Endpoint(RECORDED["reads"]["A"]), Endpoint(RECORDED["reads"]["B"])

    def test_positive_recorded_state(self):
        code, false, _ = self.run_script(*self.recorded())
        self.assertEqual((code, false), (0, []))

    def test_threshold_drift_on_both_endpoints(self):
        a, b = self.recorded()
        a.r["safeThreshold"] = b.r["safeThreshold"] = 3
        self.assertEqual(self.run_script(a, b)[:2], (1, ["safeThreshold2"]))

    def test_noncanonical_owner_encoding_is_refused(self):
        a, b = self.recorded()
        # Expected owners at the naive positions, real array elsewhere: must not decode.
        good = owners_abi(b.r["safeOwners"])[2:]
        b.owners_raw = "0x" + format(192, "064x") + good[64:] + owners_abi(["0x" + "11" * 20] * 3)[2 + 64:]
        code, false, err = self.run_script(a, b)
        self.assertEqual((code, false), (1, None))
        self.assertIn("getOwners: non-canonical", err)

    def test_same_endpoint_twice_is_refused(self):
        a, _ = self.recorded()
        code, false, err = self.run_script(a, a, urls=("https://a.invalid/", "https://a.invalid"))
        self.assertEqual((code, false), (1, None))
        self.assertIn("must be different endpoints", err)

    def test_endpoint_divergence(self):
        a, b = self.recorded()
        b.r["senders"]["executor"]["balanceAtBlock"] += 1
        self.assertEqual(self.run_script(a, b)[:2], (1, ["pinnedReadsIdentical"]))

    def test_sender_nonce_moved_since_pin(self):
        a, b = self.recorded()
        for e in (a, b):
            s = e.r["senders"]["approver"]
            s["nonceAtBlock"] = s["nonceLatestNow(unpinned)"] = s["noncePendingNow(unpinned)"] = 8
        self.assertEqual(self.run_script(a, b)[:2],
                         (1, ["approver_latestEqPendingEqPlanBothEndpoints", "approver_nonceUnchangedSincePin"]))

    def test_pending_ahead_of_latest(self):
        a, b = self.recorded()
        b.r["senders"]["deployer"]["noncePendingNow(unpinned)"] += 1
        self.assertEqual(self.run_script(a, b)[:2], (1, ["deployer_latestEqPendingEqPlanBothEndpoints"]))

    def test_safe_nonce_advanced(self):
        a, b = self.recorded()
        for e in (a, b):
            e.r["safeNonceAtBlock"] = e.r["safeNonceLatestNow(unpinned)"] = 2
        self.assertEqual(self.run_script(a, b)[:2],
                         (1, ["safeNonceAtBlockMatchesPlan", "safeNonceLatestNowMatchesPlanBothEndpoints"]))

    def test_balance_below_budget(self):
        a, b = self.recorded()
        for e in (a, b):
            e.r["senders"]["approver"]["balanceAtBlock"] = 1
        self.assertEqual(self.run_script(a, b)[:2], (1, ["approver_balanceAtBlockCoversBudget"]))


if __name__ == "__main__":
    unittest.main()
