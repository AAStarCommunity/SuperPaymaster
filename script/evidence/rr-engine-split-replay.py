import json, subprocess, sys, time, urllib.request, signal
url=open(sys.argv[1]).read().strip(); anvil=sys.argv[2]; h=sys.argv[3]
def rpc(u,m,p,t=300):
    r=json.loads(urllib.request.urlopen(urllib.request.Request(u,json.dumps({"jsonrpc":"2.0","id":1,"method":m,"params":p}).encode(),{"Content-Type":"application/json"}),timeout=t).read())
    if "error" in r: raise RuntimeError(m+" "+str(r["error"])[:150])
    return r["result"]
tx=rpc(url,"eth_getTransactionByHash",[h]); rc=rpc(url,"eth_getTransactionReceipt",[h]); n=int(tx["blockNumber"],16); idx=int(tx["transactionIndex"],16)
L="http://127.0.0.1:18961"
p=subprocess.Popen([anvil,"--fork-url",url,"--fork-block-number",str(n-1),"--port","18961","--silent","--hardfork","amsterdam","--no-mining","--order","fifo","--steps-tracing","--timeout","120000"],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
try:
    for _ in range(120):
        try: rpc(L,"eth_chainId",[]); break
        except Exception: time.sleep(0.5)
    blk=rpc(url,"eth_getBlockByNumber",[tx["blockNumber"],True]); rpc(L,"anvil_setNextBlockTimestamp",[int(blk["timestamp"],16)])
    last=None
    for t in blk["transactions"][:idx+1]:
        rpc(L,"anvil_impersonateAccount",[t["from"]])
        q={"from":t["from"],"gas":t["gas"],"value":t["value"],"input":t["input"],"nonce":t["nonce"]}
        if t.get("to"): q["to"]=t["to"]
        if t.get("maxFeePerGas"): q["maxFeePerGas"]=t["maxFeePerGas"]; q["maxPriorityFeePerGas"]=t["maxPriorityFeePerGas"]
        else: q["gasPrice"]=t["gasPrice"]
        last=rpc(L,"eth_sendTransaction",[q])
    rpc(L,"evm_mine",[])
    lr=rpc(L,"eth_getTransactionReceipt",[last])
    tr=rpc(L,"debug_traceTransaction",[last,{"disableMemory":True,"disableStack":True,"disableStorage":True}],t=600)
    s=tr["structLogs"]; res=[x.get("stateGasReservoir",0) for x in s]
    nz=[i for i,v in enumerate(res) if v]
    print(json.dumps({"tx":h,"chain_gasUsed":int(rc["gasUsed"],16),"engine_gasUsed":int(lr["gasUsed"],16),"txGas":int(tx["gas"],16),"to":tx.get("to"),"steps":len(s),"reservoir_first":res[:3],"reservoir_max":max(res) if res else None,"nonzero_steps":len(nz),"first_nonzero":s[nz[0]] if nz else None,"first_step":s[0] if s else None}, default=str))
finally:
    p.send_signal(signal.SIGTERM); p.wait()
