#!/usr/bin/env python3
"""Offline negative controls for SP's archived ams-calibrate.mjs.

Review the target's import-time behavior first. Its real fetch/parser/main are
exercised with synthetic RPC envelopes; no server, keys or network are used.
Exit 1 means at least one invalid fixture was accepted (or the control failed).
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile


MOCK = r"""
import { pathToFileURL } from 'node:url';
const [source, output, testCase] = process.argv.slice(2);
const thresholds = new Map([
  ['0x00', 207606], ['0x6101006000f3', 599432],
  ['0x600160005500', 317700], ['0x6001600055600260005500', 320075],
]);
globalThis.fetch = async (_url, options) => {
  const q = JSON.parse(options.body);
  const response = {jsonrpc: '2.0', id: q.id};
  if (q.method === 'web3_clientVersion') response.result = 'anvil/mock';
  else if (q.method === 'eth_chainId') response.result = testCase === 'wrong-chain' ? '0x1' : '0x7a69';
  else if (q.method === 'eth_call' || q.method === 'eth_estimateGas') {
    const tx = q.params[0];
    const threshold = thresholds.get(tx.data) ?? (tx.to === '0x' + 'a3'.repeat(20) ? 204600 : undefined);
    if (threshold === undefined) throw new Error('Unexpected probe');
    if (q.method === 'eth_estimateGas') response.result = '0x' + threshold.toString(16);
    else if (Number(BigInt(tx.gas)) < threshold) {
      response.error = testCase === 'rate-limit-as-boundary'
        ? {code: -32005, message: 'rate limit'}
        : {code: -32003, message: 'EVM error OutOfGas'};
    } else if (testCase === 'missing-result') {
      // A success envelope with neither result nor error is malformed.
    } else response.result = testCase === 'null-result' ? null : testCase === 'boolean-result' ? true : '0x';
  } else throw new Error('Unexpected RPC method: ' + q.method);
  if (testCase === 'wrong-envelope-id') response.id = -999;
  return {ok: true, status: 200, json: async () => response};
};
process.argv = [process.execPath, source, 'http://127.0.0.1:1', output];
await import(pathToFileURL(source).href);
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    args = parser.parse_args()
    source = args.source.resolve()
    cases = ["valid-control", "null-result", "boolean-result", "missing-result",
             "wrong-envelope-id", "wrong-chain", "rate-limit-as-boundary"]
    rows = []
    with tempfile.TemporaryDirectory(prefix="dsr-calibration-review-") as directory:
        root = Path(directory)
        harness = root / "mock.mjs"
        harness.write_text(MOCK)
        for case in cases:
            output = root / (case + ".json")
            run = subprocess.run(["node", str(harness), str(source), str(output), case],
                                 capture_output=True, text=True, timeout=30)
            report = json.loads(output.read_text()) if output.exists() else {}
            accepted = run.returncode == 0
            rows.append({"case": case, "exit": run.returncode,
                         "accepted": accepted, "expectedAcceptance": case == "valid-control",
                         "correct": accepted == (case == "valid-control"),
                         "reportedPass": report.get("pass"),
                         "probeCount": len(report.get("rows", []))})
    print(json.dumps({"mode": "offline-mocked-fetch", "sourceName": source.name,
                      "sourceSha256": hashlib.sha256(source.read_bytes()).hexdigest(),
                      "results": rows}, indent=2))
    return 0 if all(row["correct"] for row in rows) else 1


if __name__ == "__main__":
    raise SystemExit(main())
