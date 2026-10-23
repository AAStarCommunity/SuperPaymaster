#!/usr/bin/env python3
"""Offline negative controls for SP's R-AMS engine probe; never sends RPC traffic.

Exit 1 means the reviewed gate accepted at least one invalid fixture. The source
must first be reviewed for import-time side effects. No SP files are modified.
"""
import argparse
import contextlib
import importlib.util
import io
import json
import os
import sys
from unittest.mock import patch

sys.dont_write_bytecode = True


def run_case(module, packet, case):
    def urlopen(request, timeout=None):
        req = json.loads(request.data)
        method, params = req["method"], req["params"]
        response = {"jsonrpc": "2.0", "id": req["id"]}
        if method == "eth_chainId":
            response["result"] = "0x1" if case == "wrong-chain" else "0xaa36a7"
        elif method == "eth_getBlockByNumber":
            response["result"] = {
                "hash": None if case == "null-block-hash" else "0x" + "ab" * 32,
                "number": params[0],
            }
        elif method == "eth_estimateGas":
            response["result"] = "0x186a0"
        elif method == "eth_call":
            gas = int(params[0]["gas"], 16)
            if case == "null-result":
                response["result"] = None
            elif case == "boolean-result":
                response["result"] = True
            elif case == "result-and-error":
                response.update(result="0x", error={"code": -32005, "message": "rate limit"})
            elif gas >= 100000:
                response["result"] = "0x"
            else:
                response["error"] = (
                    {"code": -32005, "message": "rate limit"}
                    if case == "rate-limit-as-gas-boundary"
                    else {"code": -32003, "message": "EVM error OutOfGas"}
                )
        else:
            raise AssertionError("Unexpected RPC method: " + method)
        return io.BytesIO(json.dumps(response).encode())

    output = io.StringIO()
    with patch.dict(os.environ, {
        "RPC_A": "http://fixture-a.invalid", "RPC_B": "http://fixture-b.invalid",
        "ENGINE": "http://fixture-engine.invalid", "BLOCK": "11969861",
    }), patch.object(sys, "argv", ["rams-engine-probe.py", packet]), \
         patch.object(module.urllib.request, "urlopen", urlopen), \
         contextlib.redirect_stdout(output), contextlib.redirect_stderr(io.StringIO()):
        try:
            module.main()
            status, exception = 0, None
        except SystemExit as error:
            status, exception = error.code, None
        except Exception as error:
            status, exception = "exception", type(error).__name__
    try:
        report = json.loads(output.getvalue())
    except json.JSONDecodeError:
        report = {}
    accepted = status == 0
    expected_acceptance = case == "valid-control"
    return {
        "case": case, "exit": status, "exception": exception,
        "accepted": accepted, "expectedAcceptance": expected_acceptance,
        "correct": accepted == expected_acceptance,
        "allMatch": report.get("allMatch"),
        "sameChainAndBlock": report.get("sameChainAndBlock"),
        "probeCount": len(report.get("probes", {})),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source")
    parser.add_argument("packet")
    args = parser.parse_args()
    spec = importlib.util.spec_from_file_location("reviewed_rams_probe", args.source)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    cases = ["valid-control", "null-result", "boolean-result", "result-and-error",
             "wrong-chain", "null-block-hash", "rate-limit-as-gas-boundary"]
    rows = [run_case(module, args.packet, case) for case in cases]
    print(json.dumps({"mode": "offline-mocked-rpc", "source": args.source,
                      "results": rows}, indent=2))
    return 0 if all(row["correct"] for row in rows) else 1


if __name__ == "__main__":
    sys.exit(main())
