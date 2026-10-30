#!/usr/bin/env python3
"""Offline two-endpoint controls. --mutations runs one targeted mutant per assertion.

Fixture selectors are independent literals: never derive injected logs from m.TOPICS.
The fake provider applies the requested topic filter, so wrong selectors hide the
positive control and make its test fail. No live transport is used by this suite.
"""
import copy, hashlib, importlib.util, io, json, re, sys, tempfile, types, unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SCANNER = Path(__file__).with_name("a4-credit-logscan.py")
spec = importlib.util.spec_from_file_location("a4", SCANNER)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
TOKEN = "0x" + "11" * 20
USER = "0x" + "22" * 20
OP = "0x" + "33" * 32
LOCKER = "0x" + "44" * 20
SELECTORS = {
    "P": "0x4a53aec9f255b2d5bcb9ce63ec2e9263cd6094537eec19973e8708c1b1e35f02",
    "R": "0xe7f1ceee255e2908b896f5fa254cb3bac9e538bdac389f75de2fc3446d2a7b69",
    "S": "0xe24e7f4be2a6dcf7000d9d67421687e27dcf1f62554dbdeec78adb103aae6323",
    "L": "0xdad6678c895f98939e7284e161055630849182add6c69672f905c25a73369269",
}


def word(v):
    return f"{v:064x}" if isinstance(v, int) else v[2:].rjust(64, "0")


def bh(n):
    return "0x" + word(n + 1000)


def event(kind, n=3, index=0, tx=0, user=USER, token=TOKEN, value=0):
    topics = [SELECTORS[kind]]
    if kind != "P":
        topics += ["0x" + word(user), OP]
    if kind == "R":
        topics += ["0x" + word(LOCKER)]
    return {"address": token, "blockNumber": hex(n), "blockHash": bh(n),
            "transactionHash": "0x" + word(n * 100 + tx), "transactionIndex": hex(tx),
            "logIndex": hex(index), "topics": topics, "data": "0x" + word(value) + (word(1) if kind == "P" else ""),
            "removed": False}


class Endpoint:
    def __init__(self, logs=()):
        self.logs = copy.deepcopy(list(logs))
        self.deploy, self.finalized, self.chain = 2, 8, "0xa"
        self.max_range, self.archive, self.bad_hash = 999, True, None
        self.raw, self.calls = {}, []

    def __call__(self, method, params):
        self.calls.append((method, copy.deepcopy(params)))
        if method in self.raw:
            return self.raw[method]
        if method == "eth_chainId":
            return self.chain
        if method == "eth_getBlockByNumber":
            n = self.finalized if params[0] == "finalized" else int(params[0], 16)
            return {"number": hex(n), "hash": bh(n) if n != self.bad_hash else bh(999)}
        if method == "eth_getCode":
            if not self.archive:
                raise m.RpcFailure("archive unavailable")
            return "0x6000" if int(params[1], 16) >= self.deploy else "0x"
        if method == "eth_getLogs":
            f = params[0]
            lo, hi = int(f["fromBlock"], 16), int(f["toBlock"], 16)
            if hi - lo + 1 > self.max_range:
                raise m.RpcFailure("range too large")
            return [copy.deepcopy(v) for v in reversed(self.logs)
                    if lo <= int(v["blockNumber"], 16) <= hi and v["address"] == f["address"]
                    and v["topics"][0] in f["topics"][0]]
        raise AssertionError(method)


def run(logs=(), a=None, b=None, start=1, end=8, tokens=None):
    a, b = a or Endpoint(logs), b or Endpoint(logs)
    with mock.patch.object(m, "rpc", lambda u, method, params: {"A": a, "B": b}[u](method, params)):
        return m.scan(["A", "B"], tokens or [TOKEN], start, end, 4)


def verdicts(out):
    return out["C4"]["verdict"], out["C7"]["verdict"]


class Controls(unittest.TestCase):
    # Each test has one assertion, killed by its named targeted mutation below.
    def test_policy_positive(self):
        out = run([event("P", value=2)])
        self.assertEqual((verdicts(out), [e["policy"] for e in out["C4"]["events"]]), (("fail", "pass"), [2]))

    def test_off_policy_reported(self):
        out = run([event("P", value=0)])
        self.assertEqual((verdicts(out), len(out["C4"]["events"])), (("pass", "pass"), 1))

    def test_open_zero_amount(self):
        out = run([event("R")])
        self.assertEqual((verdicts(out), out["C7"]["openCount"]), (("pass", "fail"), 1))

    def test_reuse_chronological(self):
        logs = [event(k, n=3, index=i, tx=i) for i, k in enumerate("RSRL")]
        out = run(logs)
        self.assertEqual((verdicts(out), out["C7"]["counts"], out["C7"]["openCount"], out["C7"]["anomalyCount"]),
                         (("pass", "pass"), {"CreditReserved": 2, "CreditSettled": 1, "CreditReleased": 1}, 0, 0))

    def test_reuse_left_open(self):
        out = run([event(k, n=i + 3) for i, k in enumerate("RLR")])
        self.assertEqual((out["C7"]["verdict"], out["C7"]["openCount"]), ("fail", 1))

    def test_duplicate_reserve(self):
        out = run([event("R", n=3), event("R", n=4), event("L", n=5)])
        self.assertEqual((out["C7"]["verdict"], out["C7"]["anomalyCount"]), ("fail", 1))

    def test_orphan_closes(self):
        out = run([event("S", n=3), event("L", n=4)])
        self.assertEqual((out["C7"]["verdict"], out["C7"]["anomalyCount"]), ("fail", 2))

    def test_user_and_token_key(self):
        other = "0x" + "55" * 20
        logs = [event("R", n=3), event("L", n=4, user=other), event("L", n=5, token=other)]
        out = run(logs, tokens=[TOKEN, other])
        self.assertEqual((out["C7"]["openCount"], out["C7"]["anomalyCount"]), (1, 2))

    def test_missing_chunk_log(self):
        out = run(a=Endpoint([event("P", n=6, value=2)]), b=Endpoint())
        self.assertEqual(verdicts(out), ("未能验证", "未能验证"))

    def test_shrink_completes(self):
        b = Endpoint([event("P", n=6, value=2)])
        b.max_range = 2
        out = run(b.logs, b=b)
        spans = [(c["fromBlock"], c["toBlock"]) for c in out["chunks"] if c["status"] == "agreed"]
        self.assertEqual((verdicts(out), spans, out["chunks"][0]["status"]),
                         (("fail", "pass"), [(1, 2), (3, 4), (5, 6), (7, 8)], "rpc error; shrinking"))

    def test_permanent_error(self):
        b = Endpoint()
        b.max_range = 0
        out = run(b=b)
        self.assertEqual((verdicts(out), out["chunks"][-1]["toBlock"], len(out["chunks"])),
                         (("未能验证", "未能验证"), 1, 3))

    def test_archive_both_required(self):
        results = []
        for which in ("a", "b"):
            bad = Endpoint()
            bad.archive = False
            results.append(verdicts(run(**{which: bad})))
        self.assertEqual(results, [("未能验证", "未能验证")] * 2)

    def test_start_after_deploy(self):
        self.assertEqual(verdicts(run(start=3)), ("未能验证", "未能验证"))

    def test_bisection_and_evidence(self):
        out = run()
        expected_hash = hashlib.sha256(b"[]").hexdigest()
        self.assertEqual((verdicts(out), out["deployBlocks"], out["chainId"], out["complete"],
                          out["blockHashes"], out["canonicalLogsSha256"], out["archiveProbes"]),
                         (("pass", "pass"), {TOKEN: 2}, 10, True,
                          {"from": {"A": bh(1), "B": bh(1)}, "to": {"A": bh(8), "B": bh(8)}}, expected_hash,
                          [{"token": TOKEN, "blocks": [0, 1], "bothSucceeded": True}]))

    def test_no_code(self):
        a, b = Endpoint(), Endpoint()
        a.deploy = b.deploy = 9
        self.assertEqual(verdicts(run(a=a, b=b)), ("未能验证", "未能验证"))

    def test_finalized_both(self):
        b = Endpoint()
        b.finalized = 7
        self.assertEqual(verdicts(run(b=b)), ("未能验证", "未能验证"))

    def test_chain_mismatch(self):
        b = Endpoint()
        b.chain = "0xb"
        self.assertEqual(verdicts(run(b=b)), ("未能验证", "未能验证"))

    def test_boundary_hash(self):
        b = Endpoint()
        b.bad_hash = 4
        self.assertEqual(verdicts(run(b=b)), ("未能验证", "未能验证"))

    def test_log_hash(self):
        v = event("P")
        v["blockHash"] = bh(999)
        self.assertEqual(verdicts(run([v])), ("未能验证", "未能验证"))

    def test_removed_log(self):
        v = event("P")
        v["removed"] = True
        self.assertEqual(verdicts(run([v])), ("未能验证", "未能验证"))

    def test_duplicate_log(self):
        v = event("P")
        self.assertEqual(verdicts(run([v, v])), ("未能验证", "未能验证"))

    def test_malformed_hex_no_echo(self):
        a = Endpoint()
        a.raw["eth_getCode"] = "0xSECRETKEY"
        out = run(a=a)
        self.assertEqual((verdicts(out), "SECRETKEY" in json.dumps(out)), (("未能验证", "未能验证"), False))

    def test_malformed_quantity_no_echo(self):
        results = []
        for bad in ("0x00a", "0x", 10, "https://host/SECRETKEY"):
            a = Endpoint()
            a.chain = bad
            out = run(a=a)
            results.append((verdicts(out), "SECRETKEY" in json.dumps(out)))
        self.assertEqual(results, [(("未能验证", "未能验证"), False)] * 4)

    def test_bad_event_encoding(self):
        logs = []
        for field, val in (("data", "0x"), ("data", "0x" + word(256) + word(1)), ("topics", [SELECTORS["P"], OP])):
            v = event("P")
            v[field] = val
            logs.append(verdicts(run([v])))
        v = event("R")
        v["topics"][1] = "0x1" + "0" * 63
        logs.append(verdicts(run([v])))
        self.assertEqual(logs, [("未能验证", "未能验证")] * 4)

    def test_wrong_selector_load_bearing(self):
        with mock.patch.dict(m.TOPICS, {"CreditPolicyExecuted": "0x" + "00" * 32}):
            out = run([event("P", value=2)])
        # This is the deliberately broken instrument: its positive-control expectation fails.
        self.assertEqual((out["C4"]["verdict"] == "fail", out["C4"]["events"]), (False, []))

    def test_rpc_envelope_no_echo(self):
        results = []
        for envelope in ({"jsonrpc": "2.0", "id": 1, "error": {"message": "SECRETKEY"}},
                         {"jsonrpc": "2.0", "id": True, "result": "0xa"},
                         {"jsonrpc": "1.0", "id": 1, "result": "0xa"},
                         {"jsonrpc": "2.0", "id": 2, "result": "0xa"}):
            with mock.patch.object(m.urllib.request, "urlopen", return_value=io.StringIO(json.dumps(envelope))):
                try:
                    m.rpc("https://host/SECRETKEY", "eth_chainId", [])
                    results.append("accepted")
                except m.RpcFailure as e:
                    results.append("safe" if "SECRETKEY" not in str(e) else "leaked")
        self.assertEqual(results, ["safe"] * 4)

    def test_cli_redaction(self):
        with tempfile.TemporaryDirectory() as d:
            a, b, out = [Path(d) / n for n in ("a", "b", "out")]
            a.write_text("https://alice:SECRETKEY@a.example/v2/SECRETKEY?q=SECRETKEY")
            b.write_text("https://b.example/SECRETKEY")
            argv = ["a4", "--rpc-a-file", str(a), "--rpc-b-file", str(b), "--token", TOKEN,
                    "--from-block", "1", "--to-block", "8", "--out", str(out)]
            with mock.patch.object(sys, "argv", argv), mock.patch.object(m, "rpc", lambda u, method, p: Endpoint()(method, p)):
                status = m.main()
            result = json.loads(out.read_text())
            self.assertEqual((status, result["endpoints"], "SECRETKEY" in out.read_text()),
                             (0, {"A": "a.example", "B": "b.example"}, False))

    def test_same_endpoint(self):
        out = m.scan(["A", "A"], [TOKEN], 1, 8)
        self.assertEqual(verdicts(out), ("未能验证", "未能验证"))

    def test_transaction_index_disagreement(self):
        a, b = Endpoint([event("R")]), Endpoint([event("R", tx=1)])
        b.logs[0]["transactionHash"] = a.logs[0]["transactionHash"]
        self.assertEqual(verdicts(run(a=a, b=b)), ("未能验证", "未能验证"))

    def test_nonempty_canonical_digest(self):
        raw = event("P", value=2)
        out = run([raw])
        normalized = dict(raw, blockNumber=3, transactionIndex=0, logIndex=0)
        expected = hashlib.sha256(json.dumps([normalized], sort_keys=True, separators=(",", ":")).encode()).hexdigest()
        self.assertEqual((out["logs"], out["canonicalLogsSha256"]), ([normalized], expected))

    def test_outside_filter(self):
        a = Endpoint()
        a.raw["eth_getLogs"] = [event("P", n=8)]
        self.assertEqual(verdicts(run(a=a, b=a)), ("未能验证", "未能验证"))

    def test_code_disagreement(self):
        b = Endpoint()
        b.raw["eth_getCode"] = "0x6001"
        self.assertEqual(verdicts(run(b=b)), ("未能验证", "未能验证"))

    def test_pinned_hash_changes(self):
        class Drifting(Endpoint):
            def __call__(self, method, params):
                result = super().__call__(method, params)
                if method == "eth_getBlockByNumber" and params[0] == "0x8":
                    hits = sum(meth == method and p[0] == "0x8" for meth, p in self.calls)
                    if hits >= 3:
                        result["hash"] = bh(999)
                return result
        self.assertEqual(verdicts(run(a=Drifting(), b=Drifting())), ("未能验证", "未能验证"))

    def test_source_abi_selectors(self):
        source = (ROOT / "contracts/src/tokens/v2/xPNTsV2Base.sol").read_text()
        expected = {}
        for name, sig in m.SIGNATURES.items():
            args = re.search(r"event " + name + r"\(([^;]+)\);", source)[1].split(",")
            expected[name] = [(p.split()[0], "indexed" in p.split(), p.split()[-1]) for p in args]
        actual = []
        for filename in ("xPNTsTokenV2.json", "xPNTsTokenV2Ext.json", "xPNTsTokenV2.full.json"):
            abi = json.loads((ROOT / "abis" / filename).read_text())
            abi = abi["abi"] if isinstance(abi, dict) else abi
            actual.append({e["name"]: [(v["type"], v["indexed"], v["name"]) for v in e["inputs"]]
                           for e in abi if e.get("type") == "event" and e["name"] in expected and not e["anonymous"]})
        signatures = {name: name + "(" + ",".join(v[0] for v in fields) + ")" for name, fields in expected.items()}
        self.assertEqual((actual, signatures, list(m.TOPICS.values())),
                         ([expected] * 3, m.SIGNATURES, list(SELECTORS.values())))


# Executed against in-memory source copies: never edit the scanner on disk.
MUTATIONS = {
    "policy_positive": ('any(e["policy"] != 0 for e in policies)', 'False'),
    "off_policy_reported": ('policies.append(e)', 'policies.extend([e] if e["policy"] else [])'),
    "open_zero_amount": ('"fail" if opened or anomalies else "pass"', '"fail" if anomalies else "pass"'),
    "reuse_chronological": ('sorted(logs, key=order):', 'sorted(logs, key=order, reverse=True):'),
    "duplicate_reserve": ('anomalies.append({"reason": "reservation already open", "event": e})', 'pass'),
    "orphan_closes": ('anomalies.append({"reason": "close without open reservation", "event": e})', 'pass'),
    "user_and_token_key": ('key = (e["address"], e["user"], e["opHash"])', 'key = e["opHash"]'),
    "missing_chunk_log": ('if pair[0] != pair[1]:\n                    raise RpcFailure("endpoint log disagreement")', 'if False:\n                    raise RpcFailure("endpoint log disagreement")'),
    "shrink_completes": ('size = max(1, (hi - lo + 1) // 2)', 'raise RpcFailure("no retry")'),
    "permanent_error": ('if hi == lo:\n                        raise', 'if hi - lo <= 1:\n                        raise'),
    "start_after_deploy": ('raise RpcFailure("from-block is after deployment; history incomplete")', 'return dict(out, C4={"verdict": "pass"}, C7={"verdict": "pass"})'),
    "bisection_and_evidence": ('out["deployBlocks"][token] = deploy', 'out["deployBlocks"][token] = start'),
    "no_code": ('raise RpcFailure("token has no code at to-block")', 'return dict(out, C4={"verdict": "pass"}, C7={"verdict": "pass"})'),
    "finalized_both": ('if any(end > f["number"] for f in finals):', 'if False:'),
    "chain_mismatch": ('if ids[0] != ids[1]:', 'if False:'),
    "boundary_hash": ('if pair[0] != pair[1]:\n                raise RpcFailure("block hash disagreement")', 'if False:\n                raise RpcFailure("block hash disagreement")'),
    "log_hash": ('v["blockHash"] != hashes[v["blockNumber"]]', 'False'),
    "removed_log": ('d.get("removed") is not False', 'False'),
    "duplicate_log": ('if key in seen:', 'if False:'),
    "malformed_hex_no_echo": ('raise RpcFailure("malformed hex result")', 'raise RpcFailure("malformed hex result: " + str(v))'),
    "malformed_quantity_no_echo": ('raise RpcFailure("malformed quantity result")', 'raise RpcFailure("malformed quantity result: " + str(v))'),
    "bad_event_encoding": ('if policy >> 8 or epoch >> 32:', 'if False:'),
    "wrong_selector_load_bearing": ('"fail" if any(e["policy"] != 0 for e in policies) else "pass"', '"fail"'),
    "rpc_envelope_no_echo": ('d.get("jsonrpc") != "2.0"', 'False'),
    "cli_redaction": ('return url, p.hostname', 'return url, url'),
    "same_endpoint": ('raise RpcFailure("two distinct endpoints required")', 'return dict(out, C4={"verdict": "pass"}, C7={"verdict": "pass"})'),
    "source_abi_selectors": ('CreditPolicyExecuted(uint8,uint32)', 'CreditPolicyExecuted(uint256,uint32)'),
}
# A historical-set mutant ignores any re-reservation after the first close.
MUTATIONS["reuse_left_open"] = ('else:\n                opened[key] = e',
                              'else:\n                if counts["CreditReserved"] == 1:\n                    opened[key] = e')
# Suppress all code probes, including the deployment-boundary check.
MUTATIONS["archive_both_required"] = ('pair = [hexstr(rpc(u, "eth_getCode", [token, hex(n)])) for u in urls]',
                                     'pair = ["0x6000" if n >= 2 else "0x"] * 2')


MUTATIONS.update({
    "transaction_index_disagreement": ('v.update(topics=', 'v["transactionIndex"] = 0\n        v.update(topics='),
    "nonempty_canonical_digest": ('hashlib.sha256(canonical(out["logs"])).hexdigest()', 'hashlib.sha256(b"[]").hexdigest()'),
    "outside_filter": ('raise RpcFailure("log outside requested filter")', 'return []'),
    "code_disagreement": ('raise RpcFailure("historical code disagreement")', 'return n >= 2'),
    "pinned_hash_changes": ('if agreed_block(n) != out["blockHashes"][label]["A"]:', 'if False:'),
})

# Wrong selectors must independently kill the known-event positive controls.
SELECTOR_MUTANTS = {
    "wrong_policy_selector": ("P", "policy_positive"),
    "wrong_reserve_selector": ("R", "open_zero_amount"),
    "wrong_settle_selector": ("S", "reuse_chronological"),
    "wrong_release_selector": ("L", "reuse_chronological"),
}
for name, (kind, _) in SELECTOR_MUTANTS.items():
    MUTATIONS[name] = (SELECTORS[kind], "0x" + "00" * 32)


def mutations():
    global m
    original, source = m, SCANNER.read_text()
    killed = 0
    for name, (old, new) in MUTATIONS.items():
        if old not in source:
            raise RuntimeError("mutation anchor missing: " + name)
        mutant = types.ModuleType("a4_mutant")
        exec(compile(source.replace(old, new, 1), str(SCANNER), "exec"), mutant.__dict__)
        m = mutant
        result = unittest.TestResult()
        # Even a same-endpoint guard mutant must never reach live transport.
        with mock.patch.object(m.urllib.request, "urlopen", side_effect=RuntimeError("offline only")):
            target = SELECTOR_MUTANTS[name][1] if name in SELECTOR_MUTANTS else name
            Controls("test_" + target).run(result)
        m = original
        red = bool(result.failures) and not result.errors
        print(f'{"KILLED" if red else "SURVIVED/ERROR"} {name}: test_{target}')
        if not red:
            for _, detail in result.errors:
                print(detail)
        killed += red
    print(f"{killed}/{len(MUTATIONS)} targeted mutations killed by assertion failures")
    return 0 if killed == len(MUTATIONS) else 1


if __name__ == "__main__":
    if sys.argv[1:] == ["--mutations"]:
        sys.exit(mutations())
    unittest.main()
