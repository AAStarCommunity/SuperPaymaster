#!/usr/bin/env python3
# Engine positive control: CREATE a 10-byte runtime contract from an impersonated throwaway sender,
# inside evm_snapshot/evm_revert so the fork's state and height are unchanged afterwards.
import json, sys, urllib.request
url = sys.argv[1]
SENDER = "0x00000000000000000000000000000000c0ffee01"
INIT = "0x600a600c600039600a6000f3602a60005260206000f3"
def rpc(m, p):
    r = json.load(urllib.request.urlopen(urllib.request.Request(url, json.dumps({"jsonrpc":"2.0","id":1,"method":m,"params":p}).encode(), {"content-type":"application/json"})))
    if "error" in r: raise SystemExit(f"{m}: {r['error']}")
    return r["result"]
h0 = rpc("eth_blockNumber", []); hash0 = rpc("eth_getBlockByNumber", [h0, False])["hash"]
snap = rpc("evm_snapshot", [])
rpc("anvil_setBalance", [SENDER, hex(10**18)]); rpc("anvil_impersonateAccount", [SENDER])
est = rpc("eth_estimateGas", [{"from": SENDER, "data": INIT}])
tx = rpc("eth_sendTransaction", [{"from": SENDER, "data": INIT, "gas": hex(2_000_000)}])
rc = rpc("eth_getTransactionReceipt", [tx])
print("estimateGas", int(est,16), "gasUsed", int(rc["gasUsed"],16), "status", rc["status"], "codeLen", (len(rpc("eth_getCode", [rc["contractAddress"], "latest"]))-2)//2)
rpc("anvil_stopImpersonatingAccount", [SENDER])
print("revert", rpc("evm_revert", [snap]))
h1 = rpc("eth_blockNumber", []); hash1 = rpc("eth_getBlockByNumber", [h1, False])["hash"]
print("height before/after", int(h0,16), int(h1,16), "hash unchanged", hash0 == hash1, "sender nonce after", int(rpc("eth_getTransactionCount", [SENDER, "latest"]),16))
