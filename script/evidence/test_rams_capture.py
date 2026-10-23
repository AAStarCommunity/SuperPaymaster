#!/usr/bin/env python3
"""Offline negative controls for script/evidence/rams-capture.py (no network).

Modelled on DSR's scripts/gate/rams_probe_review.py: the real module's main() runs with a patched
urllib.request.urlopen. The valid fixture must exit 0; every malformed / faulty fixture must exit 1.
Exit status of this test: 0 = every case behaved as expected.
Run: python3 script/evidence/test_rams_capture.py
"""
import contextlib, importlib.util, io, json, os, sys
from unittest.mock import patch

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
PACKET = os.path.join(HERE, "..", "..", "docs", "release", "a3a-precheck-v4", "a3a-precheck.json")


def load():
    spec = importlib.util.spec_from_file_location("rams_capture", os.path.join(HERE, "rams-capture.py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def run(case):
    m = load()

    def urlopen(request, timeout=None):
        req = json.loads(request.data)
        method, rid = req["method"], req["id"]
        r = {"jsonrpc": "2.0", "id": rid}
        if case == "wrong-id":
            r["id"] = rid + 1000
        if method == "eth_chainId":
            r["result"] = None if case == "null-chain" else "0xaa36a7"
        elif method == "eth_getBlockByNumber":
            r["result"] = {"hash": None if case == "null-block-hash" else "0x" + "ab" * 32, "number": req["params"][0], "timestamp": "0x1"}
        elif method == "web3_clientVersion":
            r["result"] = "fixture/1"
        elif method == "eth_config":
            r["error"] = {"code": -32601, "message": "method not found"}
        elif method == "eth_getTransactionCount":
            r["result"] = "0x2f63"
        elif method == "eth_estimateGas":
            r["result"] = "0xbf2a"
            if case == "result-and-error":
                r["error"] = {"code": -32005, "message": "rate limit"}
        elif method == "eth_call":
            if case == "rate-limit-on-call":
                r["error"] = {"code": -32005, "message": "rate limit"}
            elif params_gas(req) < 2_000_000:
                r["error"] = {"code": -32003, "message": "out of gas: gas required exceeds: 1792211"}
            else:
                r["result"] = "0x" + "00" * 32
        else:
            raise AssertionError(method)
        if case == "transport":
            raise OSError("boom")
        return io.BytesIO(json.dumps(r).encode())

    out = io.StringIO()
    with patch.dict(os.environ, {"RPC_A": "http://a.invalid", "RPC_B": "http://b.invalid", "BLOCK": "11969744"}), \
         patch.object(sys, "argv", ["rams-capture.py", PACKET]), \
         patch.object(m.urllib.request, "urlopen", urlopen), \
         contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
        try:
            m.main()
            code = 0
        except SystemExit as e:
            code = e.code
    return code


def params_gas(req):
    p = req["params"][0]
    return int(p["gas"], 16) if isinstance(p, dict) and "gas" in p else 10**9


CASES = {"valid-control": 0, "null-chain": 1, "null-block-hash": 1, "wrong-id": 1,
         "result-and-error": 1, "rate-limit-on-call": 1, "transport": 1}


def main():
    bad = 0
    for case, want in CASES.items():
        got = run(case)
        print(f"{case}: exit {got} (want {want})")
        bad += got != want
    print("PASS" if not bad else f"FAIL ({bad} wrong)")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
