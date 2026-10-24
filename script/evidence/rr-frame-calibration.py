#!/usr/bin/env python3
"""R2-F3 engine calibration at FRAME level (not just receipt gasUsed).

For each real Sepolia RR tx: the archive node's debug_traceTransaction gives the first step's frame gas and
stateGasReservoir (EIP-8037: gas_left is capped at TX_MAX_GAS_LIMIT - intrinsic, the rest is the reservoir).
The engine replays the tx at block-1 with every preceding tx of the block in order (--order fifo) and its own
first-step gas/reservoir is compared. A match needs: receipt status and gasUsed equal, first-step gas equal,
first-step reservoir equal, and the target at the chain index in a local block that holds exactly the replayed
txs. Read-only; RPC from RPC_FILE, never printed.
Usage: RPC_FILE=<file> python3 rr-frame-calibration.py <anvil> <out.json> <txhash>...
"""
import json, os, signal, subprocess, sys, time, urllib.request
url = open(os.environ["RPC_FILE"]).read().strip()
anvil, out_path, hashes = sys.argv[1], sys.argv[2], sys.argv[3:]
def rpc(u, m, p, t=300):
    r = json.loads(urllib.request.urlopen(urllib.request.Request(u, json.dumps({"jsonrpc": "2.0", "id": 1, "method": m, "params": p}).encode(), {"Content-Type": "application/json"}), timeout=t).read())
    if "error" in r: raise RuntimeError(f"{m}: {r['error'].get('code')} {str(r['error'].get('message'))[:100]}")
    return r["result"]
OPT = {"disableMemory": True, "disableStack": True, "disableStorage": True}
version = subprocess.run([anvil, "--version"], capture_output=True, text=True).stdout.strip().splitlines()[:2]
rows = []
for i, h in enumerate(hashes):
    tx = rpc(url, "eth_getTransactionByHash", [h]); rc = rpc(url, "eth_getTransactionReceipt", [h])
    n, idx = int(tx["blockNumber"], 16), int(tx["transactionIndex"], 16)
    ch = rpc(url, "debug_traceTransaction", [h, dict(OPT, limit=1)])
    c0 = ch["structLogs"][0] if ch.get("structLogs") else {}
    row = {"tx": h, "block": n, "index": idx, "txGas": int(tx["gas"], 16), "chain": {"status": rc["status"], "gasUsed": int(rc["gasUsed"], 16),
           "firstGas": c0.get("gas"), "firstReservoir": c0.get("stateGasReservoir"), "executionGasUsed": ch.get("executionGasUsed"), "stateGasUsed": ch.get("stateGasUsed")}}
    port = 18930 + (i % 40); local = f"http://127.0.0.1:{port}"
    p = subprocess.Popen([anvil, "--fork-url", url, "--fork-block-number", str(n - 1), "--port", str(port), "--silent", "--hardfork", "amsterdam",
                          "--no-mining", "--order", "fifo", "--steps-tracing", "--timeout", "120000"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(240):
            try: rpc(local, "eth_chainId", []); break
            except Exception: time.sleep(0.5)
        blk = rpc(url, "eth_getBlockByNumber", [tx["blockNumber"], True]); rpc(local, "anvil_setNextBlockTimestamp", [int(blk["timestamp"], 16)])
        sent = []
        for t in blk["transactions"][: idx + 1]:
            rpc(local, "anvil_impersonateAccount", [t["from"]])
            q = {"from": t["from"], "gas": t["gas"], "value": t["value"], "input": t["input"], "nonce": t["nonce"]}
            if t.get("to"): q["to"] = t["to"]
            if t.get("maxFeePerGas"): q["maxFeePerGas"], q["maxPriorityFeePerGas"] = t["maxFeePerGas"], t["maxPriorityFeePerGas"]
            else: q["gasPrice"] = t["gasPrice"]
            if t.get("accessList"): q["accessList"] = t["accessList"]
            try: sent.append(rpc(local, "eth_sendTransaction", [q]))
            except Exception as e: sent.append("ERR " + str(e)[:80])
        rpc(local, "evm_mine", [])
        lh = sent[-1]
        lr = None
        for _ in range(240):
            lr = rpc(local, "eth_getTransactionReceipt", [lh]) if not str(lh).startswith("ERR") else None
            if lr or str(lh).startswith("ERR"): break
            time.sleep(0.25)
        lb = rpc(local, "eth_getBlockByNumber", [lr["blockNumber"], False]) if lr else {"transactions": []}
        ok_sent = [s for s in sent if not str(s).startswith("ERR")]
        lt = rpc(local, "debug_traceTransaction", [lh, dict(OPT, limit=1)], t=600) if lr else {}
        e0 = lt["structLogs"][0] if lt.get("structLogs") else {}
        row["engine"] = {"status": lr and lr["status"], "gasUsed": lr and int(lr["gasUsed"], 16), "firstGas": e0.get("gas"), "firstReservoir": e0.get("stateGasReservoir"),
                         "localIndex": lr and int(lr["transactionIndex"], 16), "sameOrder": [x.lower() for x in lb["transactions"]] == [x.lower() for x in ok_sent],
                         "precedingErrors": sum(1 for s in sent[:-1] if str(s).startswith("ERR"))}
    finally:
        p.send_signal(signal.SIGTERM); p.wait()
    c, e = row["chain"], row["engine"]
    row["match"] = {k: c[k] == e[k] for k in ("status", "gasUsed", "firstGas", "firstReservoir")}
    row["match"]["order"] = bool(e["sameOrder"]) and e["localIndex"] == idx and e["precedingErrors"] == 0
    row["strictMatch"] = all(row["match"].values())
    rows.append(row); print(h[:10], row["match"], flush=True)
res = {"engine": version, "n": len(rows), "strictMatches": sum(r["strictMatch"] for r in rows),
       "receiptOnlyMatches": sum(r["match"]["status"] and r["match"]["gasUsed"] for r in rows), "rows": rows}
json.dump(res, open(out_path, "w"), indent=1)
print(f"{version[0]}: strict {res['strictMatches']}/{res['n']}, receipt-only {res['receiptOnlyMatches']}/{res['n']}")
