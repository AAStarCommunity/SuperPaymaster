#!/usr/bin/env python3
"""Offline adversarial controls for the three R-AMS gauges (no network). R2-F1 regression suite.

Covers cases beyond DSR's vendored tools (script/evidence/dsr-gate/): RPC faults whose message embeds
EVM wording, words ending in 'oog', transient faults inside a binary search, and (for capture) wrong
chain / malformed block / malformed typed results; HTTP 429 for the JS calibrator.
Exit 0 = every case behaved as expected. Run: python3 script/evidence/test_rams_gauges.py
"""
import contextlib, importlib.util, io, json, os, subprocess, sys, tempfile
from unittest.mock import patch

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
PACKET = os.path.join(ROOT, "docs", "release", "a3a-precheck-v4", "a3a-precheck.json")
OOG = {"code": -32003, "message": "EVM error OutOfGas"}
SNEAKY = {
    "embedded-revert": {"code": -32005, "message": "rate limit exceeded while processing execution reverted"},
    "word-oog": {"code": -32003, "message": "rate limit from upstream droog"},
    "fault-code-with-evm-text": {"code": -32603, "message": "EVM error OutOfGas"},
}


def load(name):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), os.path.join(HERE, name + ".py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def run_module(m, env, argv, urlopen):
    with patch.dict(os.environ, env), patch.object(sys, "argv", argv), \
         patch.object(m.urllib.request, "urlopen", urlopen), \
         contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        try:
            m.main()
            return 0
        except SystemExit as e:
            return e.code
        except Exception:
            return "exception"


# ---------------- engine probe ----------------
def probe(case):
    m = load("rams-engine-probe")
    state = {"calls": 0}

    def urlopen(request, timeout=None):
        q = json.loads(request.data)
        r = {"jsonrpc": "2.0", "id": q["id"]}
        meth, p = q["method"], q["params"]
        if meth == "eth_chainId":
            r["result"] = "0xaa36a7"
        elif meth == "eth_getBlockByNumber":
            r["result"] = {"hash": "0x" + "ab" * 32, "number": p[0]}
        elif meth == "eth_estimateGas":
            r["result"] = "0x186a0"
        elif meth == "eth_call":
            state["calls"] += 1
            gas = int(p[0]["gas"], 16)
            if case == "flaky-search" and gas >= 15_000_000 and state["calls"] in (2, 3):
                r["error"] = OOG                     # transient failure dressed as OOG in the first search
            elif gas >= 100_000:
                r["result"] = "0x"
            else:
                r["error"] = SNEAKY.get(case, OOG)
        else:
            raise AssertionError(meth)
        return io.BytesIO(json.dumps(r).encode())

    env = {"RPC_A": "http://a.invalid", "RPC_B": "http://b.invalid", "ENGINE": "http://e.invalid", "BLOCK": "11969861"}
    return run_module(m, env, ["rams-engine-probe.py", PACKET], urlopen)


# ---------------- capture ----------------
def capture(case):
    m = load("rams-capture")

    def urlopen(request, timeout=None):
        q = json.loads(request.data)
        r = {"jsonrpc": "2.0", "id": q["id"]}
        meth, p = q["method"], q["params"]
        if meth == "eth_chainId":
            r["result"] = {"chain-0x1": "0x1", "chain-banana": "banana"}.get(case, "0xaa36a7")
        elif meth == "eth_getBlockByNumber":
            h = {"hash-gg": "0x" + "gg" * 32, "hash-0X": "0X" + "ab" * 32}.get(case, "0x" + "ab" * 32)
            r["result"] = {"hash": h, "number": 1 if case == "number-int" else p[0], "timestamp": "0x1"}
        elif meth == "web3_clientVersion":
            r["result"] = "fixture/1"
        elif meth == "eth_config":
            r["error"] = {"code": -32601, "message": "method not found"}
        elif meth == "eth_getTransactionCount":
            r["result"] = "garbage" if case == "nonce-garbage" else "0x2f63"
        elif meth == "eth_estimateGas":
            r["result"] = True if case == "estimate-bool" else "0xbf2a"
        elif meth == "eth_call":
            gas = int(p[0]["gas"], 16) if "gas" in p[0] else 10**9
            if case == "call-null":
                r["result"] = None
            elif case in SNEAKY and gas < 2_000_000:
                r["error"] = SNEAKY[case]
            elif gas < 2_000_000:
                r["error"] = {"code": -32003, "message": "out of gas: gas required exceeds: 1792211"}
            else:
                r["result"] = "0x" + "00" * 32
        else:
            raise AssertionError(meth)
        return io.BytesIO(json.dumps(r).encode())

    env = {"RPC_A": "http://a.invalid", "RPC_B": "http://b.invalid", "BLOCK": "11969744"}
    return run_module(m, env, ["rams-capture.py", PACKET], urlopen)


# ---------------- calibrate (node) ----------------
MOCK = r"""
import { pathToFileURL } from 'node:url';
const [source, output, testCase] = process.argv.slice(2);
const T = new Map([['0x00',207606],['0x6101006000f3',599432],['0x600160005500',317700],['0x6001600055600260005500',320075]]);
let n = 0;
globalThis.fetch = async (_u, o) => {
  const q = JSON.parse(o.body); const r = {jsonrpc:'2.0', id:q.id};
  if (q.method === 'web3_clientVersion') r.result = 'anvil/mock';
  else if (q.method === 'eth_chainId') r.result = '0x7a69';
  else {
    const tx = q.params[0];
    const th = T.get(tx.data) ?? (tx.to === '0x' + 'a3'.repeat(20) ? 204600 : undefined);
    if (q.method === 'eth_estimateGas') r.result = '0x' + th.toString(16);
    else {
      n++;
      const g = Number(BigInt(tx.gas));
      if (testCase === 'flaky-search' && g >= 15000000 && (n === 2 || n === 3)) r.error = {code:-32003, message:'EVM error OutOfGas'};
      else if (g < th) r.error = testCase === 'embedded-revert' ? {code:-32005, message:'rate limit exceeded while processing execution reverted'}
                       : testCase === 'word-oog' ? {code:-32003, message:'rate limit from upstream droog'}
                       : {code:-32003, message:'EVM error OutOfGas'};
      else r.result = '0x';
    }
  }
  const status = testCase === 'http-429' ? 429 : 200;
  return {ok: status === 200, status, json: async () => r};
};
process.argv = [process.execPath, source, 'http://127.0.0.1:1', output];
await import(pathToFileURL(source).href);
"""


def calibrate(case):
    src = os.path.join(ROOT, "script", "b-layer", "ams-calibrate.mjs")
    with tempfile.TemporaryDirectory() as d:
        h = os.path.join(d, "mock.mjs")
        open(h, "w").write(MOCK)
        r = subprocess.run(["node", h, src, os.path.join(d, "o.json"), case], capture_output=True, text=True, timeout=60)
        return r.returncode


PLAN = [
    ("probe", probe, {"valid": 0, "embedded-revert": "nonzero", "word-oog": "nonzero",
                      "fault-code-with-evm-text": "nonzero", "flaky-search": "nonzero"}),
    ("capture", capture, {"valid": 0, "chain-0x1": 1, "chain-banana": 1, "hash-gg": 1, "hash-0X": 1,
                          "number-int": 1, "call-null": 1, "estimate-bool": 1, "nonce-garbage": 1,
                          "embedded-revert": 1, "word-oog": 1}),
    ("calibrate", calibrate, {"valid": 0, "http-429": "nonzero", "embedded-revert": "nonzero",
                              "word-oog": "nonzero", "flaky-search": "nonzero"}),
]


def main():
    bad = 0
    for name, fn, cases in PLAN:
        for case, want in cases.items():
            got = fn(case)
            ok = (got == 0) if want == 0 else (got != 0 if want == "nonzero" else got == want)
            print(f"{name:9s} {case:26s} exit {got!s:10s} want {want} {'ok' if ok else 'WRONG'}")
            bad += not ok
    print("PASS" if not bad else f"FAIL ({bad} wrong)")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
