#!/usr/bin/env python3
"""R2-F3 positive control: does a local engine reproduce real Sepolia RR transactions (gasUsed > 2^24)?

Read-only against the archive RPC. For each tx: fork at block-1 on a local anvil, set the block timestamp,
replay every preceding tx of the block and then the target via impersonation, mine one block, and compare
gasUsed and status with the chain receipt. The local tx hash must differ from the chain hash (it is unsigned),
which shows the receipt came from local execution and not from the fork's remote fallback.

Usage: RPC_FILE=<file holding the archive URL> HF=amsterdam python3 rams-rr-replay.py <anvil> <out.json> <txhash>...
The URL is read from RPC_FILE and is never printed. Exit 0 always writes JSON; the verdict is in the file.
"""
import json, os, signal, subprocess, sys, time, urllib.request

url = open(os.environ["RPC_FILE"]).read().strip()
anvil, out_path, hashes = sys.argv[1], sys.argv[2], sys.argv[3:]
hf = os.environ.get("HF", "amsterdam")


def rpc(u, m, p):
    q = json.dumps({"jsonrpc": "2.0", "id": 1, "method": m, "params": p}).encode()
    r = json.loads(urllib.request.urlopen(urllib.request.Request(u, q, {"Content-Type": "application/json"}), timeout=120).read())
    if "error" in r:
        raise RuntimeError(f"{m}: {r['error'].get('code')} {str(r['error'].get('message'))[:120]}")
    return r["result"]


version = subprocess.run([anvil, "--version"], capture_output=True, text=True).stdout.strip().splitlines()[:2]
rows = []
for i, h in enumerate(hashes):
    tx = rpc(url, "eth_getTransactionByHash", [h])
    rc = rpc(url, "eth_getTransactionReceipt", [h])
    n, idx = int(tx["blockNumber"], 16), int(tx["transactionIndex"], 16)
    port = 18900 + i
    local = f"http://127.0.0.1:{port}"
    p = subprocess.Popen([anvil, "--fork-url", url, "--fork-block-number", str(n - 1), "--port", str(port),
                          "--silent", "--hardfork", hf, "--no-mining"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    row = {"tx": h, "block": n, "index": idx, "chain_gasUsed": int(rc["gasUsed"], 16), "chain_status": rc["status"]}
    try:
        for _ in range(120):
            try:
                rpc(local, "eth_chainId", [])
                break
            except Exception:
                time.sleep(0.5)
        else:
            raise RuntimeError("anvil did not start")
        blk = rpc(url, "eth_getBlockByNumber", [tx["blockNumber"], True])
        rpc(local, "anvil_setNextBlockTimestamp", [int(blk["timestamp"], 16)])
        sent = []
        for t in blk["transactions"][: idx + 1]:
            rpc(local, "anvil_impersonateAccount", [t["from"]])
            q = {"from": t["from"], "gas": t["gas"], "value": t["value"], "input": t["input"], "nonce": t["nonce"]}
            if t.get("to"):
                q["to"] = t["to"]
            if t.get("maxFeePerGas"):
                q["maxFeePerGas"], q["maxPriorityFeePerGas"] = t["maxFeePerGas"], t["maxPriorityFeePerGas"]
            else:
                q["gasPrice"] = t["gasPrice"]
            if t.get("accessList"):
                q["accessList"] = t["accessList"]
            try:
                sent.append(rpc(local, "eth_sendTransaction", [q]))
            except Exception as e:
                sent.append("ERR " + str(e)[:120])
        rpc(local, "evm_mine", [])
        lh = sent[-1]
        row["preceding_replay_errors"] = sum(1 for s in sent[:-1] if str(s).startswith("ERR"))
        if str(lh).startswith("ERR"):
            row.update(engine_gasUsed=None, engine_status=None, local_hash=None, error=lh, match=False)
        else:
            lr = rpc(local, "eth_getTransactionReceipt", [lh])
            row.update(engine_gasUsed=int(lr["gasUsed"], 16), engine_status=lr["status"], local_hash=lh,
                       local_hash_differs=lh.lower() != h.lower())
            row["match"] = row["engine_gasUsed"] == row["chain_gasUsed"] and lr["status"] == rc["status"] and row["local_hash_differs"]
    except Exception as e:
        row.update(error=str(e)[:200], match=False)
    finally:
        p.send_signal(signal.SIGTERM)
        p.wait()
    rows.append(row)

res = {"engine": version, "hardfork": hf, "n": len(rows), "matches": sum(r["match"] for r in rows), "rows": rows}
json.dump(res, open(out_path, "w"), indent=1)
print(f"{version[0] if version else anvil} hf={hf}: {res['matches']}/{res['n']} match")
