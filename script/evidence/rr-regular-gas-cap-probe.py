# Discriminates "regular gas capped at TX_MAX_GAS_LIMIT - intrinsic" (EIP-8037) vs uncapped, using a pure-compute loop.
import json, sys, urllib.request, subprocess, time, signal
def rpc(u,m,p):
    r=json.loads(urllib.request.urlopen(urllib.request.Request(u,json.dumps({"jsonrpc":"2.0","id":1,"method":m,"params":p}).encode(),{"Content-Type":"application/json"}),timeout=120).read())
    return r
# loop: PUSH3 n; JUMPDEST; PUSH1 1; SWAP1; SUB; DUP1; PUSH1 4; JUMPI; STOP  -> ~ n * (3+3+3+3+10+1) gas, no state
def loop(n): return "0x62"+n.to_bytes(3,"big").hex()+"5b600190038060045700"
addr="0x000000000000000000000000000000000cc12500"
def probe(u, label, block):
    for n in (300_000, 700_000, 900_000):
        for gas in (2**24, 30_000_000):
            q={"to":addr,"gas":hex(gas),"data":"0x"}
            r=rpc(u,"eth_call",[q,block,{addr:{"code":loop(n)}}])
            e=rpc(u,"eth_estimateGas",[{"to":addr,"data":"0x"},block,{addr:{"code":loop(n)}}])
            print(label, "loopN",n,"gas",gas, "call:", "OK" if "result" in r else ("ERR "+str(r["error"].get("message"))[:70]), "| estimate:", int(e["result"],16) if "result" in e else ("ERR "+str(e["error"].get("message"))[:70]))
url=open(sys.argv[1]).read().strip(); mode=sys.argv[2]
if mode=="chain":
    bn=rpc(url,"eth_blockNumber",[])["result"]; probe(url,"SEPOLIA(reth)",bn)
else:
    p=subprocess.Popen([sys.argv[3],"--port","18971","--silent","--hardfork","amsterdam","--gas-limit","100000000"],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    try:
        time.sleep(3); probe("http://127.0.0.1:18971","ENGINE(nightly)","latest")
    finally:
        p.send_signal(signal.SIGTERM); p.wait()
