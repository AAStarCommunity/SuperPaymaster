#!/usr/bin/env python3
"""Offline positive and negative controls for w2-op-mainnet-exposure.py (no network).

Fake endpoints ABI-encode the values recorded in the committed exposure listing; each control changes one.
"""
import contextlib, copy, importlib.util, io, json, os, unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("w2", ROOT / "script/evidence/w2-op-mainnet-exposure.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
RECORDED = json.loads((ROOT / "docs/design/aoa-balance-mode/data/aoa-sp02/w2-op-mainnet-exposure-158749238.json").read_text())
OBS = RECORDED["observation"]


def enc_string(s):
    raw = s.encode().hex()
    return "0x" + m.word(32) + m.word(len(s)) + raw.ljust((len(raw) + 63) // 64 * 64, "0")


class Endpoint:
    def __init__(self, obs):
        self.o = copy.deepcopy(obs)
        self.list_len = None    # override the length word getPaymasterList returns
        self.extra_v4 = []      # complete extra array entries beyond getPaymasterCount
        self.dirty_owner = False
        self.offset = 32        # head offset of dynamic returns
        self.raw = {}           # selector -> raw eth_call result override

    def pm(self, a):
        for p in [self.o["legacySuperPaymaster"]] + self.o["v4Paymasters"]:
            if p["address"] == a.lower():
                return p
        raise AssertionError(a)

    def __call__(self, method, params):
        o = self.o
        if method == "eth_chainId":
            return hex(o["chainId"])
        if method == "eth_blockNumber":
            return hex(RECORDED["block"] + 64)
        if method == "eth_getBlockByNumber":
            return {"hash": o["blockHash"]}
        if method == "eth_getCode":
            return "0x6000" if any(p["ownerHasCode"] and p["owner"] == params[0]
                                   for p in [o["legacySuperPaymaster"]] + o["v4Paymasters"]) else "0x"
        to, data = params[0]["to"], params[0]["data"]
        sel = data[:10]
        if sel in self.raw:
            return self.raw[sel]
        if sel == m.SEL["getDepositInfo"]:
            d = self.pm("0x" + data[-40:])["depositInfo"]
            return "0x" + "".join(m.word(v) for v in (int(d["depositWei"]), int(d["staked"]), int(d["stakeWei"]),
                                                        d["unstakeDelaySec"], d["withdrawTime"]))
        if sel == m.SEL["owner"]:
            w = m.word(self.pm(to)["owner"])
            return "0x" + ("1" + w[1:] if self.dirty_owner else w)
        if sel == m.SEL["version"]:
            return "0x" + m.word(self.offset) + enc_string(self.pm(to)["version"])[66:]
        if sel == m.SEL["getPaymasterCount"]:
            return "0x" + m.word(o["factory"]["paymasterCount"])
        if sel == m.SEL["getPaymasterList"]:
            v4 = [p["address"] for p in o["v4Paymasters"]] + self.extra_v4
            n = len(v4) if self.list_len is None else self.list_len
            return "0x" + m.word(self.offset) + m.word(n) + "".join(m.word(a) for a in v4)
        raise AssertionError(sel)


def run(a, b, argv=(str(RECORDED["block"]),)):
    eps = {"A": a, "B": b}
    out, err = io.StringIO(), io.StringIO()
    with mock.patch.dict(os.environ, {"RPC_A": "A", "RPC_B": "B"}), \
         mock.patch.object(m, "rpc", lambda url, meth, p: eps[url](meth, p)), \
         mock.patch("sys.argv", ["w2", *argv]), \
         contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        try:
            m.main()
            code = 0
        except SystemExit as e:
            code = e.code if isinstance(e.code, int) else 1
            if not isinstance(e.code, int):
                err.write(str(e.code))
    return code, (json.loads(out.getvalue()) if out.getvalue() else None), err.getvalue()


class Controls(unittest.TestCase):
    def test_positive_reproduces_recorded_listing(self):
        code, out, _ = run(Endpoint(OBS), Endpoint(OBS))
        self.assertEqual(code, 0)
        self.assertEqual(out["observation"], OBS)
        self.assertEqual(out["totals"], RECORDED["totals"])

    def test_b_deposit_differs(self):
        b = Endpoint(OBS)
        b.o["v4Paymasters"][0]["depositInfo"]["depositWei"] = "1"
        code, out, _ = run(Endpoint(OBS), b)
        self.assertEqual(code, 1)
        self.assertFalse(out["checks"]["endpointsAgree"])
        self.assertTrue(out["checks"]["chainIdIsOpMainnet"])

    def test_b_block_hash_differs(self):
        b = Endpoint(OBS)
        b.o["blockHash"] = "0x" + "11" * 32
        code, out, _ = run(Endpoint(OBS), b)
        self.assertEqual((code, out["checks"]["endpointsAgree"]), (1, False))

    def test_both_on_wrong_chain(self):
        o = copy.deepcopy(OBS)
        o["chainId"] = 11155111
        code, out, _ = run(Endpoint(o), Endpoint(o))
        self.assertEqual(code, 1)
        self.assertTrue(out["checks"]["endpointsAgree"])
        self.assertFalse(out["checks"]["chainIdIsOpMainnet"])

    def test_list_longer_than_count(self):
        a = Endpoint(OBS)
        a.extra_v4 = ["0x" + "77" * 20]    # a complete, well-formed array of count + 1 entries
        code, out, err = run(a, Endpoint(OBS))
        self.assertEqual((code, out), (1, None))
        self.assertIn("getPaymasterCount", err)

    def test_list_truncated(self):
        a = Endpoint(OBS)
        a.list_len = OBS["factory"]["paymasterCount"] + 1    # length word says more than the data holds
        code, out, err = run(a, Endpoint(OBS))
        self.assertEqual((code, out), (1, None))
        self.assertIn("shorter than its length", err)

    def test_non_canonical_offset(self):
        for off in (33, 64, 10**6):
            a = Endpoint(OBS)
            a.offset = off
            code, out, err = run(a, Endpoint(OBS))
            self.assertEqual((code, out), (1, None), off)
            self.assertIn("non-canonical", err)

    def test_dirty_bool_and_uint_overflow(self):
        di = OBS["legacySuperPaymaster"]["depositInfo"]
        good = [int(di["depositWei"]), 1, int(di["stakeWei"]), di["unstakeDelaySec"], di["withdrawTime"]]
        for i, bad, msg in ((1, 2, "dirty bool"), (2, 2**112, "uint112"), (3, 2**32, "uint32"), (4, 2**48, "uint48")):
            a = Endpoint(OBS)
            vals = list(good)
            vals[i] = bad
            a.raw[m.SEL["getDepositInfo"]] = "0x" + "".join(m.word(v) for v in vals)
            code, out, err = run(a, Endpoint(OBS))
            self.assertEqual((code, out), (1, None), msg)
            self.assertIn(msg, err)

    def test_malformed_answer_does_not_echo(self):
        secret = "https://op.example/v2/SECRETKEY123456"
        for raw in (secret, "0x" + secret.encode().hex()[:62].ljust(64, "z")):
            a = Endpoint(OBS)
            a.raw[m.SEL["getPaymasterCount"]] = raw
            code, out, err = run(a, Endpoint(OBS))
            self.assertEqual((code, out), (1, None))
            self.assertNotIn("SECRETKEY", err)
        a = Endpoint(OBS)
        a.o["chainId"] = None
        a.__class__ = type("E", (Endpoint,), {"__call__": lambda self, meth, p: secret if meth == "eth_chainId" else Endpoint.__call__(self, meth, p)})
        code, out, err = run(a, Endpoint(OBS))
        self.assertEqual((code, out), (1, None))
        self.assertNotIn("SECRETKEY", err)

    def test_dirty_address_word(self):
        a = Endpoint(OBS)
        a.dirty_owner = True
        code, out, err = run(a, Endpoint(OBS))
        self.assertEqual((code, out), (1, None))
        self.assertIn("dirty address", err)

    def test_owner_with_code_is_reported(self):
        o = copy.deepcopy(OBS)
        o["legacySuperPaymaster"]["ownerHasCode"] = True
        code, out, _ = run(Endpoint(o), Endpoint(o))
        self.assertEqual(code, 0)
        self.assertTrue(out["observation"]["legacySuperPaymaster"]["ownerHasCode"])

    def test_malformed_code_result(self):
        for bad in ({"invalid": "code"}, "0x0", "60", "0xzz"):
            e = type("E", (Endpoint,), {"__call__": lambda self, meth, p, bad=bad: bad if meth == "eth_getCode" else Endpoint.__call__(self, meth, p)})
            code, out, err = run(e(OBS), e(OBS))
            self.assertEqual((code, out), (1, None), bad)

    def test_eth_call_without_0x(self):
        e = type("E", (Endpoint,), {"__call__": lambda self, meth, p: (lambda r: r[2:] if meth == "eth_call" else r)(Endpoint.__call__(self, meth, p))})
        code, out, err = run(e(OBS), e(OBS))
        self.assertEqual((code, out), (1, None))
        self.assertIn("malformed hex", err)

    def test_malformed_quantities(self):
        for meth, argv in (("eth_chainId", (str(RECORDED["block"]),)), ("eth_blockNumber", ())):
            for bad in ("a", "0x", 10, "0xg", "0x00a", "0x09765276"):
                e = type("E", (Endpoint,), {"__call__": lambda self, m_, p, meth=meth, bad=bad: bad if m_ == meth else Endpoint.__call__(self, m_, p)})
                code, out, err = run(e(OBS), e(OBS), argv)
                self.assertEqual((code, out), (1, None), (meth, bad))
                self.assertIn("malformed quantity", err)

    def test_malformed_block_hash(self):
        for bad in ("not-a-block-hash", "0x" + "ab" * 31, None):
            o = copy.deepcopy(OBS)
            o["blockHash"] = bad
            code, out, err = run(Endpoint(o), Endpoint(o))
            self.assertEqual((code, out), (1, None), bad)

    def test_same_endpoint_refused(self):
        with mock.patch.dict(os.environ, {"RPC_A": "X", "RPC_B": "X"}), mock.patch("sys.argv", ["w2"]):
            with self.assertRaises(SystemExit) as c:
                m.main()
        self.assertIn("differ", str(c.exception.code))


if __name__ == "__main__":
    unittest.main()
