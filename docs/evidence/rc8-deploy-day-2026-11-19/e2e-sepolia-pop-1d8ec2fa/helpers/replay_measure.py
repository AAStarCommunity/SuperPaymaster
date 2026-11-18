#!/usr/bin/env python3
# Fork-only gas measurement: replay the 97 dry-run txs in order from the impersonated deployer on the
# Amsterdam fork; per tx eth_estimateGas at the current state, send with gas=estimate, read receipt.
import json, sys, time, urllib.request
url, runjson, out = sys.argv[1], sys.argv[2], sys.argv[3]
assert url.startswith("http://127.0.0.1:")
CAP = 16_777_216
D = "0x51ac694981b6cea06aa6c51751c227aac5f6b8a3"
def rpc(m, p):
    r = json.load(urllib.request.urlopen(urllib.request.Request(url, json.dumps({"jsonrpc":"2.0","id":1,"method":m,"params":p}).encode(), {"content-type":"application/json"})))
    return r
SEL = {}
for s in ["updatePrice()","initialize(address,address,address)","setTreasury(address)","configureRole(bytes32,(uint256,uint256,uint32,uint32,uint32,uint32,uint32,bool,uint256,string,address,uint256))"]:
    pass
t = json.load(open(runjson))["transactions"]
rows = []
for i, x in enumerate(t, 1):
    tx = x["transaction"]; data = tx.get("input") or tx.get("data") or "0x"
    req = {"from": D, "data": data, "nonce": tx["nonce"]}
    if tx.get("to"): req["to"] = tx["to"]
    if tx.get("value") and int(tx["value"],16): req["value"] = tx["value"]
    est = rpc("eth_estimateGas", [req])
    if "error" in est:
        rows.append({"i": i, "error": est["error"]}); print("STOP estimate", i, est["error"]); break
    g = int(est["result"], 16)
    req["gas"] = hex(g)
    s = rpc("eth_sendTransaction", [req])
    if "error" in s:
        rows.append({"i": i, "est": g, "error": s["error"]}); print("STOP send", i, s["error"]); break
    rc = None
    for _ in range(100):
        rc = rpc("eth_getTransactionReceipt", [s["result"]]).get("result")
        if rc: break
        time.sleep(0.1)
    blk = rpc("eth_getBlockByNumber", [rc["blockNumber"], False])["result"]
    row = {"i": i, "nonce": int(tx["nonce"],16), "kind": x["transactionType"], "name": x.get("contractName") or "", "fn": x.get("function") or "",
           "selector": data[:10] if x["transactionType"] == "CALL" else "", "to": tx.get("to") or rc.get("contractAddress"),
           "simGasLimit": int(tx["gas"],16), "estimate": g, "gasUsed": int(rc["gasUsed"],16), "status": rc["status"],
           "block": int(rc["blockNumber"],16), "ts": int(blk["timestamp"],16), "hash": s["result"]}
    rows.append(row)
    if rc["status"] != "0x1": print("STOP status", i, row); break
json.dump(rows, open(out, "w"), indent=1)
print("replayed", len(rows), "ok", sum(1 for r in rows if r.get("status") == "0x1"))
