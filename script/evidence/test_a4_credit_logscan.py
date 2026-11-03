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
        self.final_hash = None  # hash reported for the "finalized" tag only
        self.raw, self.calls = {}, []

    def __call__(self, method, params):
        self.calls.append((method, copy.deepcopy(params)))
        if method in self.raw:
            return self.raw[method]
        if method == "eth_chainId":
            return self.chain
        if method == "eth_getBlockByNumber":
            n = self.finalized if params[0] == "finalized" else int(params[0], 16)
            if params[0] == "finalized" and self.final_hash:
                return {"number": hex(n), "hash": self.final_hash}
            return {"number": hex(n), "hash": bh(n) if n != self.bad_hash else bh(999)}
        if method == "eth_getCode":
            if not self.archive:
                raise m.RpcFailure("archive unavailable")
            return "0x6000" if int(params[1], 16) >= self.deploy else "0x"
        if method == "eth_getBlockReceipts":
            n = int(params[0], 16)
            return [{"logs": [copy.deepcopy(v) for v in self.logs if int(v["blockNumber"], 16) == n]}]
        if method == "eth_getLogs":
            f = params[0]
            lo, hi = int(f["fromBlock"], 16), int(f["toBlock"], 16)
            if hi - lo + 1 > self.max_range:
                raise m.RpcFailure("range too large")
            return [copy.deepcopy(v) for v in reversed(self.logs)
                    if lo <= int(v["blockNumber"], 16) <= hi and v["address"] == f["address"]
                    and v["topics"][0] in f["topics"][0]
                    and all(topic is None or (len(v["topics"]) > i and v["topics"][i] == topic)
                            for i, topic in enumerate(f["topics"][1:], 1))]
        raise AssertionError(method)


def run(logs=(), a=None, b=None, start=1, end=8, tokens=None):
    a, b = a or Endpoint(logs), b or Endpoint(logs)
    with mock.patch.object(m, "rpc", lambda u, method, params: {"A": a, "B": b}[u](method, params)):
        return m.scan(["A", "B"], tokens or [TOKEN], start, end, 4)


def verdicts(out):
    return out["C4"]["verdict"], out["C7"]["verdict"]


class Controls(unittest.TestCase):
    # Each test has one assertion, killed by its named targeted mutation below.
    def test_filtered_chunk_defaults(self):
        for indexed, explicit, expected in ((None, None, 2000), ({1: '0x'+USER[2:].rjust(64, '0')}, None, 50000),
                                             ({1: '0x'+USER[2:].rjust(64, '0')}, 100000, 50000)):
            a, b = Endpoint(), Endpoint()
            for endpoint in (a, b):
                endpoint.finalized = 100000
                endpoint.max_range = 100000
            with mock.patch.object(m, 'rpc', lambda u, method, p: {'A': a, 'B': b}[u](method, p)):
                out = m.scan(['A','B'], [TOKEN], 1, 100000, chunk_size=explicit,
                             indexed_topics=indexed, deployment_check=False)
            self.assertTrue(out['complete'])
            self.assertEqual(out['chunkSize'], expected)
            self.assertEqual(len(out['chunks']), 100000 // expected)
            self.assertTrue(all(c['toBlock']-c['fromBlock']+1 == expected for c in out['chunks']))

    def test_filtered_shrinks_without_growth(self):
        a, b = Endpoint(), Endpoint()
        for endpoint in (a, b):
            endpoint.finalized = 100000
            endpoint.max_range = 25000
        with mock.patch.object(m, 'rpc', lambda u, method, p: {'A':a,'B':b}[u](method,p)):
            out = m.scan(['A','B'], [TOKEN], 1, 100000, indexed_topics={1:'0x'+USER[2:].rjust(64,'0')}, deployment_check=False)
        self.assertTrue(out['complete'])
        self.assertEqual([c['toBlock']-c['fromBlock']+1 for c in out['chunks']], [50000,25000,25000,25000,25000])

    def test_all_hit_receipts_and_coverage(self):
        rows = [event('P', n=n) for n in range(2, 8)]
        a, b = Endpoint(rows), Endpoint(rows)
        with mock.patch.object(m, 'rpc', lambda u, method, p: {'A':a, 'B':b}[u](method,p)):
            out = m.scan(['A','B'], [TOKEN], 1, 8, 8)
        self.assertTrue(set(range(2,8)) <= set(out['chunks'][0]['receiptCountCheckedBlocks']))
        self.assertIn('dual-endpoint agreement + split consistency', out['coverage'])
        self.assertIn('per-block coverage is NOT claimed', out['coverage'])

    def test_rpc_pacing_backoff_and_records(self):
        now = [0.0]; starts = []; failures = [429, 503, 'timeout']
        def sleep(delay): now[0] += delay
        def transport(req, timeout):
            starts.append((req.full_url, now[0]))
            if failures:
                failure = failures.pop(0)
                if failure == 'timeout': raise TimeoutError('SECRET')
                raise m.urllib.error.HTTPError(req.full_url, failure, 'SECRET', {}, None)
            return io.StringIO(json.dumps(dict(jsonrpc='2.0', id=1, result='0x1')))
        @m.rpc_recorded
        def exercise(urls, **kwargs):
            for u in (urls[0], urls[0], urls[1]): m.rpc(u, 'eth_chainId', [])
            return {}
        with mock.patch.object(m.time, 'monotonic', side_effect=lambda: now[0]), \
             mock.patch.object(m.time, 'sleep', side_effect=sleep), \
             mock.patch.object(m.urllib.request, 'urlopen', side_effect=transport):
            out = exercise(['https://a/SECRET', 'https://b/SECRET'], min_interval=0.4)
        self.assertEqual([r['retryCount'] for r in out['rpcCalls']], [0,1,2,3,0,0])
        self.assertEqual([r.get('backoffSeconds') for r in out['rpcCalls'][:3]], [0.25,0.5,1.0])
        self.assertTrue(all(b[1]-a[1] >= 0.399 for a,b in zip(starts[:4], starts[1:5])))
        self.assertEqual(starts[-1][1], starts[-2][1])
        self.assertNotIn('SECRET', json.dumps(out))
        self.assertEqual(out['rpcCalls'][-1]['endpoint'], 'B')
        self.assertTrue(all(r['method'] == 'eth_chainId' and r['latencySeconds'] >= 0 for r in out['rpcCalls']))

    def test_rpc_exhaustion_stays_failure(self):
        a, b = Endpoint(), Endpoint()
        def transport(req, timeout):
            request = json.loads(req.data)
            if request['method'] == 'eth_getLogs':
                raise m.urllib.error.HTTPError(req.full_url, 429, 'SECRET', {}, None)
            result = {'https://a':a, 'https://b':b}[req.full_url](request['method'], request['params'])
            return io.StringIO(json.dumps(dict(jsonrpc='2.0', id=1, result=result)))
        with mock.patch.object(m.time, 'sleep'), mock.patch.object(m.urllib.request, 'urlopen', side_effect=transport):
            out = m.scan(['https://a','https://b'], [TOKEN], 1, 8, min_interval=0, max_retries=2)
        self.assertFalse(out['complete'])
        self.assertEqual(len(out['chunks']), 1)
        calls = [r for r in out['rpcCalls'] if r['method'] == 'eth_getLogs']
        self.assertEqual([r['retryCount'] for r in calls], [0,1,2])
        self.assertTrue(all(r['status'] == 'failure' for r in calls))

    def test_rpc_nonretryable(self):
        for error in (m.urllib.error.HTTPError('https://a/SECRET',400,'SECRET',{},None), ValueError('SECRET')):
            with mock.patch.object(m.urllib.request,'urlopen',side_effect=error) as transport, mock.patch.object(m.time,'sleep') as sleep:
                with self.assertRaises(m.RpcFailure): m.rpc('https://a', 'eth_chainId', [])
            self.assertEqual(transport.call_count, 1)
            sleep.assert_not_called()

    def test_empty_range_call_count(self):
        a, b = Endpoint(), Endpoint()
        for endpoint in (a, b):
            endpoint.finalized = 100000
            endpoint.max_range = 2000
        with mock.patch.object(m, "rpc", lambda u, method, p: {"A": a, "B": b}[u](method, p)):
            out = m.scan(["A", "B"], [TOKEN], 1, 100000, 2000, deployment_check=False)
        self.assertTrue(out["complete"])
        self.assertEqual(len(out["chunks"]), 50)
        for endpoint in (a, b):
            counts = {method: sum(call[0] == method for call in endpoint.calls)
                      for method in ("eth_chainId", "eth_getLogs", "eth_getBlockReceipts", "eth_getBlockByNumber")}
            self.assertEqual(counts, {"eth_chainId": 1, "eth_getLogs": 150,
                                     "eth_getBlockReceipts": 50, "eth_getBlockByNumber": 106})
            self.assertEqual(len(endpoint.calls), 6 * 50 + 7)
            self.assertLess(len(endpoint.calls), 10 * 50)
        self.assertTrue(all(c["halvesChecked"] and len(c["sampledBlocks"]) == 1 for c in out["chunks"]))

    def test_split_consistency(self):
        class Capped(Endpoint):
            def __call__(self, method, params):
                rows = super().__call__(method, params)
                return rows[:3] if method == "eth_getLogs" else rows
        rows = [event("P", n=n) for n in range(2, 9)]
        out = run(a=Capped(rows), b=Capped(rows))
        self.assertTrue(out["complete"])
        self.assertEqual(len(out["logs"]), 7)
        self.assertTrue(any(c["status"] == "split disagreement; shrinking" for c in out["chunks"]))

    def test_sampling_bound_and_seed(self):
        rows = [event("P", n=n) for n in (2, 3, 4, 5, 6, 7)]
        a, b = Endpoint(rows), Endpoint(rows)
        with mock.patch.object(m, "rpc", lambda u, method, p: {"A": a, "B": b}[u](method, p)):
            out = m.scan(["A", "B"], [TOKEN], 1, 8, 8, receipt_sample_size=2)
        self.assertTrue(out["complete"])
        chunk = out["chunks"][0]
        seed = hashlib.sha256(json.dumps([1, 8, bh(8)], separators=(",", ":")).encode()).hexdigest()
        self.assertEqual(chunk["sampleSeed"], seed)
        ranked = sorted(range(2, 8), key=lambda n: hashlib.sha256(f"{seed}:{n}".encode()).hexdigest())
        self.assertEqual(chunk["sampledLogBlocks"], sorted(ranked[:2]))
        self.assertEqual(len(chunk["sampledEmptyBlocks"]), 1)
        self.assertIn(chunk["sampledEmptyBlocks"][0], (1, 8))
        for endpoint in (a, b):
            self.assertEqual([int(p[0], 16) for method, p in endpoint.calls if method == "eth_getBlockReceipts"],
                             chunk["sampledBlocks"])

    def test_unsampled_omission_limit(self):
        # For [1, 4] with B=bh(8), block 3 is sampled; hidden block 4 is not.
        a, b = Endpoint([event("P", n=4, value=2)]), Endpoint([event("P", n=4, value=2)])
        a.raw["eth_getLogs"] = b.raw["eth_getLogs"] = []
        out = run(a=a, b=b)
        self.assertTrue(out["complete"])
        self.assertEqual(out["chunks"][0]["sampledEmptyBlocks"], [3])
        self.assertEqual(verdicts(out), ("pass", "pass"))

    def test_receipt_hex_case(self):
        token = '0x'+'ab'*20
        row = event('P', token=token, value=2)
        row['data'] = '0x'+word(2)+word(0xab)
        for omitted in (False, True):
            class Upper(Endpoint):
                def __call__(self, method, params):
                    if omitted and method == 'eth_getLogs': return []
                    result = super().__call__(method, params)
                    if method == 'eth_getBlockReceipts':
                        for receipt in result:
                            for log in receipt['logs']:
                                for key in ('address', 'data'): log[key] = '0x'+log[key][2:].upper()
                                log['topics'] = ['0x'+t[2:].upper() for t in log['topics']]
                    return result
            out = run(a=Upper([row]), b=Upper([row]), tokens=[token])
            self.assertEqual(out['complete'], not omitted)
            self.assertEqual(out['C4']['verdict'], m.UNVERIFIED if omitted else 'fail')

    def test_receipt_equal_count_disagreement(self):
        class Disagreeing(Endpoint):
            def __call__(self, method, params):
                if method == 'eth_getBlockReceipts' and params[0] == '0x3':
                    return [{'logs': [event('P', value=2)]}]
                return super().__call__(method, params)
        self.assertFalse(run(a=Endpoint([event('P')]), b=Disagreeing([event('P')]))['complete'])

    def test_receipt_shared_substitution(self):
        class Substituted(Endpoint):
            def __call__(self, method, params):
                if method == 'eth_getBlockReceipts' and params[0] == '0x3':
                    return [{'logs': [event('P', value=2)]}]
                return super().__call__(method, params)
        self.assertFalse(run(a=Substituted([event('P')]), b=Substituted([event('P')]))['complete'])

    def test_receipt_full_fields(self):
        for key, value in [('address', LOCKER), ('topics', [SELECTORS['L'], '0x'+word(USER), OP]),
                           ('data', '0x'+word(2)+word(1)), ('logIndex', '0x1'),
                           ('transactionHash', bh(123)), ('blockHash', bh(999))]:
            class Changed(Endpoint):
                def __call__(self, method, params):
                    rows = super().__call__(method, params)
                    if method == 'eth_getBlockReceipts' and params[0] == '0x3':
                        rows[0]['logs'][0][key] = value
                    return rows
            with self.subTest(field=key):
                self.assertFalse(run(a=Changed([event('P')]), b=Changed([event('P')]))['complete'])

    def test_receipt_filtered_sorted_positive(self):
        rows = [event('P', index=1), event('P', index=0), event('R', token=LOCKER)]
        out = run(rows)
        self.assertTrue(out['complete'])
        self.assertEqual(len(out['logs']), 2)

    def test_identical_truncation_receipts(self):
        a, b = Endpoint([event("P",value=2)]), Endpoint([event("P",value=2)])
        a.raw["eth_getLogs"] = b.raw["eth_getLogs"] = []
        self.assertEqual(verdicts(run(a=a,b=b)), (m.UNVERIFIED,m.UNVERIFIED))

    def test_receipts_required(self):
        a = Endpoint(); a.raw["eth_getBlockReceipts"] = None
        self.assertEqual(verdicts(run(a=a)), (m.UNVERIFIED,m.UNVERIFIED))

    def test_cap_shrinks(self):
        for cap in (1000,):
            rows = [event("P",n=3+i//(cap//2),index=i%(cap//2)) for i in range(cap)]
            out = run(rows)
            with self.subTest(cap=cap):
                self.assertEqual((verdicts(out),out["chunks"][0]["status"],len(out["logs"])),
                                 (("pass","pass"),"rpc error; shrinking",cap))

    def test_all_caps_block_minimum_chunk(self):
        for cap in (1000,5000,10000):
            a=Endpoint(); a.raw['eth_getLogs']=[event('P')]*cap
            with self.subTest(cap=cap):
                out=run(a=a,b=a)
                self.assertEqual((out['chunks'][-1]['fromBlock'],out['chunks'][-1]['toBlock'],verdicts(out)),
                                 (1,1,(m.UNVERIFIED,m.UNVERIFIED)))

    def test_configured_max_shrinks(self):
        rows = [event("P",n=3),event("P",n=4)]
        a,b = Endpoint(rows),Endpoint(rows)
        with mock.patch.object(m,"rpc",lambda u,method,p: {"A":a,"B":b}[u](method,p)):
            out=m.scan(["A","B"],[TOKEN],1,8,4,max_logs=1)
        self.assertEqual((out["complete"],out["chunks"][0]["status"]),(True,"rpc error; shrinking"))

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

    def test_finalized_checkpoint_in_numbered_view(self):
        b = Endpoint()
        b.final_hash = bh(999)
        self.assertEqual(verdicts(run(b=b)), ("未能验证", "未能验证"))

    def test_endpoint_file_rejected_without_echo(self):
        bad = []
        with tempfile.TemporaryDirectory() as d:
            for i, text in enumerate(["ftp://secret-host/key123", "http://secret-host/key123#frag", "not a url key123"]):
                f = Path(d) / str(i)
                f.write_text(text)
                try:
                    m.endpoint_file(f)
                    bad.append(text)
                except m.RpcFailure as e:
                    if "key123" in str(e) or "secret-host" in str(e):
                        bad.append(text)
            try:
                m.endpoint_file(Path(d) / "missing")
                bad.append("missing")
            except m.RpcFailure:
                pass
        self.assertEqual(bad, [])

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
    "endpoint_file_rejected_without_echo": ('if p.scheme not in ("http", "https") or not p.hostname or p.fragment:', 'if False:'),
    "finalized_checkpoint_in_numbered_view": ('if block(u, hex(f["number"]))["hash"] != f["hash"]:', 'if False:'),
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
