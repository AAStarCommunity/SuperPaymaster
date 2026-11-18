#!/usr/bin/env python3
# EIP-7825 positive control (fork only): 20M-gas infinite-loop CREATE from a throwaway impersonated sender,
# inside evm_snapshot/evm_revert. Expected: receipt status 0 with gasUsed capped at 16,777,216.
import json, sys, time, urllib.request
url = sys.argv[1]; assert url.startswith("http://127.0.0.1:")
S = "0x00000000000000000000000000000000c0ffee02"; INIT = "0x5b600056"  # JUMPDEST PUSH1 0 JUMP
def rpc(m, p):
    r = json.load(urllib.request.urlopen(urllib.request.Request(url, json.dumps({"jsonrpc":"2.0","id":1,"method":m,"params":p}).encode(), {"content-type":"application/json"})))
    if "error" in r: raise SystemExit(f"{m}: {r['error']}")
    return r["result"]
info = rpc("anvil_nodeInfo", []); h0 = rpc("eth_getBlockByNumber", ["latest", False])
print("hardFork", info.get("hardFork"), "block", int(h0["number"],16), "hash", h0["hash"], "blockAccessListHash", h0.get("blockAccessListHash"), "slotNumber", h0.get("slotNumber"))
print("command: eth_sendTransaction", json.dumps({"from": S, "data": INIT, "gas": hex(20_000_000)}), "bytecode", INIT, "(JUMPDEST PUSH1 0 JUMP)")
snap = rpc("evm_snapshot", []); rpc("anvil_setBalance", [S, hex(10**18)]); rpc("anvil_impersonateAccount", [S])
tx = rpc("eth_sendTransaction", [{"from": S, "data": INIT, "gas": hex(20_000_000)}])
rc = None
for _ in range(100):
    rc = rpc("eth_getTransactionReceipt", [tx])
    if rc: break
    time.sleep(0.2)
txo = rpc("eth_getTransactionByHash", [tx])
print("tx gasLimit", int(txo["gas"],16), "receipt status", rc["status"], "gasUsed", int(rc["gasUsed"],16), "contractAddress", rc.get("contractAddress"))
ok = rc["status"] == "0x0" and int(rc["gasUsed"],16) == 16_777_216
print("CONTROL", "PASS (capped at 16,777,216 and failed)" if ok else "FAIL (cap not enforced as expected)")
rpc("anvil_stopImpersonatingAccount", [S]); print("revert", rpc("evm_revert", [snap]))
h1 = rpc("eth_getBlockByNumber", ["latest", False]); print("after revert block", int(h1["number"],16), "hash", h1["hash"], "unchanged", h1["hash"] == h0["hash"])
sys.exit(0 if ok else 1)
