import json, sys, urllib.request
URL = sys.argv[1]; BIN = open(sys.argv[2]).read().strip()
def rpc(m, p):
    r = urllib.request.Request(URL, json.dumps({"jsonrpc":"2.0","id":1,"method":m,"params":p}).encode(), {"Content-Type":"application/json"})
    out = json.load(urllib.request.urlopen(r))
    if "error" in out: raise SystemExit(f"{m}: {out['error']}")
    return out["result"]
import time
def receipt(h):
    for _ in range(100):
        rc = rpc("eth_getTransactionReceipt", [h])
        if rc: return rc
        time.sleep(0.1)
    raise SystemExit("no receipt")
a = rpc("eth_accounts", [])[0]
print("client", rpc("web3_clientVersion", []))
h = rpc("eth_sendTransaction", [{"from": a, "data": "0x" + BIN, "gas": hex(15_000_000)}])
rc = receipt(h); probe = rc["contractAddress"]
print("deploy Probe(+Child) gasUsed", int(rc["gasUsed"], 16))
SEL = "0xa444f5e9"  # cast sig "run(uint256)"
def decode_logs(rc):
    out = []
    for lg in rc["logs"]:
        d = bytes.fromhex(lg["data"][2:])
        off = int.from_bytes(d[0:32], "big"); v = int.from_bytes(d[32:64], "big", signed=True)
        ln = int.from_bytes(d[off:off+32], "big"); k = d[off+32:off+32+ln].decode()
        out.append((k, v))
    return out
for i, g in enumerate([15_000_000, 16_777_216, 30_000_000]):
    data = SEL + (1000 * (i + 1)).to_bytes(32, "big").hex()
    try:
        h = rpc("eth_sendTransaction", [{"from": a, "to": probe, "data": data, "gas": hex(g)}])
    except SystemExit as e:
        print(f"tx gasLimit {g}: REJECTED {e}"); continue
    rc = receipt(h)
    print(f"--- tx gasLimit {g:>11,d} (reservoir = gasLimit - 2^24 if > 2^24): status {rc['status']} gasUsed {int(rc['gasUsed'],16):,d}")
    for k, v in decode_logs(rc): print(f"    {k:70s} {v:>10,d}")
