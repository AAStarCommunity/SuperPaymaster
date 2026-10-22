"""Tx-level deployment gas on a local anvil (calibrated nightly): for each CREATE transaction of
DeployLive.s.sol + DeployAPNTsCapped.s.sol (+ OZ TimelockController), in script order, with the
shipped profile.default (cancun) init code and constructor arguments of the same shape:
  estimate = eth_estimateGas, min = smallest gas limit for which eth_call succeeds (binary search),
  used = receipt gasUsed of the transaction actually sent with gas = estimate.
Only local anvil RPC; the anvil default account 0 is unlocked (no key handled here)."""
import json, sys, time, subprocess, urllib.request
URL, CODE, EPHEX = sys.argv[1], sys.argv[2], sys.argv[3]
CAST = "/tmp/fd/nightly/cast"
EP = "0x0000000071727De22E5E9d8BAf0edAc6f37da032"
def rpc(m, p):
    r = urllib.request.Request(URL, json.dumps({"jsonrpc":"2.0","id":1,"method":m,"params":p}).encode(), {"Content-Type":"application/json"})
    return json.load(urllib.request.urlopen(r))
def ok(m, p):
    o = rpc(m, p)
    if "error" in o: raise RuntimeError(f"{m}: {o['error']}")
    return o["result"]
def enc(sig, *a): return subprocess.check_output([CAST, "abi-encode", sig, *a], text=True, env={"FOUNDRY_DISABLE_NIGHTLY_WARNING":"1","PATH":"/usr/bin:/bin"}).strip()[2:]
def cd(sig, *a): return subprocess.check_output([CAST, "calldata", sig, *a], text=True, env={"FOUNDRY_DISABLE_NIGHTLY_WARNING":"1","PATH":"/usr/bin:/bin"}).strip()
def code(n): return open(f"{CODE}/{n}.hex").read().strip().removeprefix("0x")
A = ok("eth_accounts", [])[0]
print("client", ok("web3_clientVersion", []), "deployer", A)
ok("anvil_setCode", [EP, open(EPHEX).read().strip()])
def receipt(h):
    for _ in range(200):
        rc = ok("eth_getTransactionReceipt", [h])
        if rc: return rc
        time.sleep(0.05)
    raise RuntimeError("no receipt")
rows = []
def mingas(tx):
    lo, hi = 0, 200_000_000
    if "error" in rpc("eth_call", [dict(tx, gas=hex(hi)), "latest"]): return None
    while hi - lo > 1:
        mid = (lo + hi) // 2
        if "error" in rpc("eth_call", [dict(tx, gas=hex(mid)), "latest"]): lo = mid
        else: hi = mid
    return hi
def send(label, tx, kind):
    tx = dict(tx, **{"from": A})
    est = rpc("eth_estimateGas", [tx])
    est = int(est["result"], 16) if "result" in est else None
    mn = mingas(tx)
    g = est or 200_000_000
    rc = receipt(ok("eth_sendTransaction", [dict(tx, gas=hex(g))]))
    used = int(rc["gasUsed"], 16); st = int(rc["status"], 16)
    addr = rc.get("contractAddress")
    size = (len(ok("eth_getCode", [addr, "latest"])) - 2) // 2 if addr else 0
    nbytes = (len(tx["data"]) - 2) // 2
    rows.append((label, kind, nbytes, size, est, mn, used, st))
    print(f"{label:58s} {kind:6s} data {nbytes:>6d} B runtime {size:>6d} B  estimate {est if est is None else f'{est:,d}':>12}  min {mn if mn is None else f'{mn:,d}':>12}  used {used:>12,d}  status {st}", flush=True)
    if st != 1: raise RuntimeError(label + " failed")
    return addr
def create(n, args="", label=None): return send(label or n, {"data": "0x" + code(n) + args}, "CREATE")
def call(label, to, data): return send(label, {"to": to, "data": data}, "CALL")
dep = A
feed = create("MockFeed", label="MockFeed (test helper, not shipped)")
regImpl = create("Registry")
registry = create("ERC1967Proxy", enc("f(address,bytes)", regImpl, cd("initialize(address,address,address)", dep, "0x" + "0"*40, "0x" + "0"*40)), "ERC1967Proxy(Registry) + initialize")
f1 = create("xPNTsFactory", enc("f(address,address)", "0x" + "0"*40, registry))
gtoken = create("GTokenAuthorization", enc("f(uint256,address)", str(21_000_000 * 10**18), f1))
staking = create("GTokenStaking", enc("f(address,address,address)", gtoken, dep, registry))
create("MySBT", enc("f(address,address,address,address)", gtoken, staking, registry, dep))
spImpl = create("SuperPaymaster", enc("f(address,address,address)", EP, registry, feed), "SuperPaymaster impl (ctor creates SuperPaymasterAdmin)")
sp = create("ERC1967Proxy", enc("f(address,bytes)", spImpl, cd("initialize(address,address,address,uint256)", dep, "0x" + "0"*40, dep, "4200")), "ERC1967Proxy(SuperPaymaster) + initialize")
create("SuperPaymasterAdmin", enc("f(address,address,address)", EP, registry, feed), "SuperPaymasterAdmin standalone (breakdown only; inside SP impl row)")
tier = create("GlobalTierSource", enc("f(address)", registry))
aoa = create("AOAProtocolRegistry", enc("f(address)", dep))
ext = create("xPNTsTokenV2Ext", enc("f(address)", aoa))
v2impl = create("xPNTsTokenV2", enc("f(address,address)", aoa, ext))
kind = int(ok("eth_call", [{"to": aoa, "data": cd("KIND_TIER_SOURCE()")}, "latest"]), 16)
tierCode = ok("eth_getCode", [tier, "latest"])
tierHash = subprocess.check_output([CAST, "keccak", tierCode], text=True, env={"FOUNDRY_DISABLE_NIGHTLY_WARNING":"1","PATH":"/usr/bin:/bin"}).strip()
call("AOAProtocolRegistry.bootstrapApprove(KIND_TIER_SOURCE, codehash)", aoa, cd("bootstrapApprove(uint8,bytes32)", str(kind), tierHash))
create("xPNTsFactoryV2", enc("f(address,address,address,address)", sp, registry, v2impl, tier))
create("SuperPaymasterLens")
create("ReputationSystem", enc("f(address)", registry))
dvt = create("DVTValidator", enc("f(address)", registry))
create("BLSAggregator", enc("f(address,address,address)", registry, sp, dvt))
create("MicroPaymentChannel", enc("f(address)", dep))
create("PaymasterFactory")
pm = create("Paymaster", enc("f(address)", registry))
create("X402Facilitator", enc("f(address,address)", registry, f1))
tl = create("TimelockController", enc("f(uint256,address[],address[],address)", "172800", f"[{dep}]", f"[{dep}]", "0x" + "0"*40), "TimelockController (48h, 1 proposer, 1 executor, admin 0)")
create("PolicyRegistry", enc("f(address,address,address)", tl, dep, sp))
create("APNTsCapped", enc("f(string,string,uint256,address,address,address)", "AAStar PNTs", "aPNTs", str(300_000 * 10**18), dep, "0x00000000000000000000000000000000000A11CE", "0x00000000000000000000000000000000000A11CE"), "APNTsCapped (DeployAPNTsCapped)")
clone = "3d602d80600a3d3981f3363d3d373d3d3d363d73{}5af43d82803e903d91602b57fd5bf3"
send("EIP-1167 clone of xPNTsTokenV2 (raw)", {"data": "0x" + clone.format(v2impl[2:].lower())}, "CREATE")
send("EIP-1167 clone of Paymaster (raw)", {"data": "0x" + clone.format(pm[2:].lower())}, "CREATE")
json.dump(rows, open(sys.argv[4], "w"), indent=1)
