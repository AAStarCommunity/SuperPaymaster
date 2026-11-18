#!/usr/bin/env python3
# Fork-only. Replay the 97 txs exactly as replay_measure.py; before each TARGET tx, debug_traceCall it at the
# pre-state with gas = 2^24 + RES (large reservoir so no state gas spills into regular gas), structLogger.
#   regular_exec = (2^24 - firstStep.gas)           intrinsic regular
#                + (firstStep.gas - lastDepth1Step.gas)  execution regular incl. child frames
#                + 6*ceil(L/32)                    code-deposit hash (regular), L = returned runtime length
#   state        = (RES - firstStep.stateGasReservoir)  intrinsic state (new account)
#                + (firstStep.res - lastDepth1Step.res) execution state (SSTORE new slots, child CREATEs)
#                + 1530*L                          code-deposit state (CPSB 1530 inferred from probe)
#   check: regular + state - refund == traced total == mined gasUsed
import json, sys, time, urllib.request, math
url, runjson, out = sys.argv[1:4]; CAP = 1 << 24; CPSB = 1530
TARGETS = {1, 3, 7, 16, 24, 25, 30, 33, 97}
D = "0x51ac694981b6cea06aa6c51751c227aac5f6b8a3"
def rpc(m, p):
    r = json.load(urllib.request.urlopen(urllib.request.Request(url, json.dumps({"jsonrpc":"2.0","id":1,"method":m,"params":p}).encode(), {"content-type":"application/json"}), timeout=1800))
    if "error" in r: raise SystemExit(f"{m}: {r['error']}")
    return r["result"]
t = json.load(open(runjson))["transactions"]; res = []
for i, x in enumerate(t, 1):
    tx = x["transaction"]; data = tx.get("input") or tx.get("data") or "0x"
    req = {"from": D, "data": data, "nonce": tx["nonce"]}
    if tx.get("to"): req["to"] = tx["to"]
    est = int(rpc("eth_estimateGas", [req]), 16)
    if i in TARGETS:
        RES = 2 * est + 10_000_000
        tr = rpc("debug_traceCall", [dict(req, gas=hex(CAP + RES)), "latest", {"disableStack": True, "disableMemory": True, "disableStorage": True}])
        L = tr["structLogs"]; d1 = [s for s in L if s["depth"] == 1]; f, l = d1[0], d1[-1]
        rv = tr.get("returnValue") or ""; rv = rv[2:] if rv.startswith("0x") else rv
        codelen = len(rv) // 2 if x["transactionType"] == "CREATE" else 0
        reg_intr = CAP - f["gas"]; reg_exec = f["gas"] - l["gas"] - l.get("gasCost", 0) * 0
        st_intr = RES - f["stateGasReservoir"]; st_exec = f["stateGasReservoir"] - l["stateGasReservoir"]
        dep_reg = 6 * math.ceil(codelen / 32); dep_st = CPSB * codelen
        regular = reg_intr + reg_exec + dep_reg; state = st_intr + st_exec + dep_st
        refund = l.get("refund", 0)
        spilled = any(s["stateGasReservoir"] == 0 for s in d1)
        row = dict(i=i, name=(x.get("contractName") or "").replace(".default", ""), traced_total=tr["gas"], failed=tr["failed"],
                   steps=len(L), first={k: f[k] for k in ("op","gas","stateGasReservoir","refund")}, last={k: l[k] for k in ("op","gas","stateGasReservoir","refund")},
                   reserve=RES, codelen=codelen, reg_intrinsic=reg_intr, reg_exec=reg_exec, reg_deposit=dep_reg, st_intrinsic=st_intr, st_exec=st_exec, st_deposit=dep_st,
                   regular=regular, state=state, refund_last=refund, reservoir_ever_zero=spilled, est=est)
        res.append(row); print(json.dumps(row))
    s = rpc("eth_sendTransaction", [dict(req, gas=hex(est))])
    for _ in range(200):
        rc = rpc("eth_getTransactionReceipt", [s])
        if rc: break
        time.sleep(0.1)
    if rc["status"] != "0x1": raise SystemExit(f"STOP status {i}")
    if i in TARGETS: res[-1]["mined_gasUsed"] = int(rc["gasUsed"], 16); res[-1]["mined_hash"] = s
json.dump(res, open(out, "w"), indent=1); print("done", len(res))
