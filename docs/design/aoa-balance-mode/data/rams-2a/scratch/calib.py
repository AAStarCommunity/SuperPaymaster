import json, sys, urllib.request
URL = sys.argv[1]
def rpc(m, p):
    r = urllib.request.Request(URL, json.dumps({"jsonrpc":"2.0","id":1,"method":m,"params":p}).encode(), {"Content-Type":"application/json"})
    return json.load(urllib.request.urlopen(r))
acct = rpc("eth_accounts", [])["result"][0]
cases = [
 ("create data 0x00", {"data":"0x00"}, 207606),
 ("create data 0x6101006000f3", {"data":"0x6101006000f3"}, 599432),
 ("create data 0x600160005500", {"data":"0x600160005500"}, 317700),
 ("create data 0x6001600055600260005500", {"data":"0x6001600055600260005500"}, 320075),
 ("1 wei -> 0xa3..a3", {"to":"0x"+"a3"*20, "value":"0x1"}, 204600),
]
ok_all = True
print("client:", rpc("web3_clientVersion", [])["result"], "block:", int(rpc("eth_blockNumber",[])["result"],16))
for name, tx, exp in cases:
    def ok(g):
        t = dict(tx, **{"from":acct, "gas":hex(g)})
        r = rpc("eth_call", [t, "latest"])
        return "error" not in r, r
    lo, hi = 0, 30_000_000
    assert ok(hi)[0], ok(hi)[1]
    while hi - lo > 1:
        mid = (lo+hi)//2
        if ok(mid)[0]: hi = mid
        else: lo = mid
    est = rpc("eth_estimateGas", [dict(tx, **{"from":acct})]).get("result")
    eq = hi == exp; ok_all &= eq
    print(f"{name:40s} min={hi:>9d} expected={exp:>9d} diff={hi-exp:>+8d} {'MATCH' if eq else 'MISMATCH'} estimateGas={int(est,16) if est else None} fail_at_min-1={ok(hi-1)[1].get('error',{}).get('message')}")
print("ALL_MATCH" if ok_all else "NOT_ALL_MATCH")
