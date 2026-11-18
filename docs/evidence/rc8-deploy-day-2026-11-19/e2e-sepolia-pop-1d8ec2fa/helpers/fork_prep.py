#!/usr/bin/env python3
# usage: fork_prep.py RPC snapshot|prep|revert ID|state   (fork-only rehearsal manipulation, logged)
import json, sys, urllib.request
url, act = sys.argv[1], sys.argv[2]
assert url.startswith("http://127.0.0.1:")
D = "0x51Ac694981b6CEa06aA6c51751C227aac5F6b8A3"
def rpc(m, p):
    r = json.load(urllib.request.urlopen(urllib.request.Request(url, json.dumps({"jsonrpc":"2.0","id":1,"method":m,"params":p}).encode(), {"content-type":"application/json"})))
    if "error" in r: raise SystemExit(f"{m}: {r['error']}")
    return r["result"]
def state():
    b = rpc("eth_getBlockByNumber", ["latest", False])
    print("state block", int(b["number"],16), "hash", b["hash"], "ts", int(b["timestamp"],16), "deployer nonce", int(rpc("eth_getTransactionCount",[D,"latest"]),16), "code", rpc("eth_getCode",[D,"latest"]))
if act == "snapshot": state(); print("snapshot", rpc("evm_snapshot", []))
elif act == "prep":
    ts = int(rpc("eth_getBlockByNumber", ["latest", False])["timestamp"],16)
    interval = int(sys.argv[3])
    print("anvil_setNextBlockTimestamp", ts + 1, rpc("anvil_setNextBlockTimestamp", [ts + 1]))
    print("anvil_setBlockTimestampInterval", interval, rpc("anvil_setBlockTimestampInterval", [interval]))
    print("anvil_impersonateAccount", D, rpc("anvil_impersonateAccount", [D]))
elif act == "revert":
    print("anvil_removeBlockTimestampInterval", rpc("anvil_removeBlockTimestampInterval", []))
    print("anvil_stopImpersonatingAccount", rpc("anvil_stopImpersonatingAccount", [D]))
    print("evm_revert", sys.argv[3], rpc("evm_revert", [sys.argv[3]])); state()
elif act == "state": state()
