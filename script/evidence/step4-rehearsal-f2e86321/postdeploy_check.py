#!/usr/bin/env python3
"""Read-only post-deploy check of a DeployLive-built system against the rc.8 owner-table expectations.

Usage: postdeploy_check.py <rpc> <config.json> <deployer> <safe>
Prints one PASS/FAIL line per assertion and a summary. Nothing is sent: eth_call only.
"""
import json
import subprocess
import sys

RPC, CFG, DEPLOYER, SAFE = sys.argv[1], json.load(open(sys.argv[2])), sys.argv[3].lower(), sys.argv[4].lower()
results = []


LOCAL = {"keccak", "calldata", "sig", "abi-encode"}


def cast(*args):
    cmd = ["cast", *args] + ([] if args[0] in LOCAL else ["--rpc-url", RPC])
    r = subprocess.run(cmd, capture_output=True, text=True)
    return r.returncode, (r.stdout.strip() or r.stderr.strip())


def raw_call(frm, to, data):
    q = json.dumps({"from": frm, "to": to, "data": data})
    return cast("rpc", "eth_call", q, "latest")


def call(addr, sig, *args):
    rc, out = cast("call", addr, sig, *map(str, args))
    return out if rc == 0 else f"<revert: {out[:120]}>"


def check(name, ok, detail):
    results.append(ok)
    print(f"{'PASS' if ok else 'FAIL'}  {name} :: {detail}")


A = {k: v for k, v in CFG.items() if isinstance(v, str) and v.startswith("0x") and len(v) == 42}
agg, dvt, reg, sp, stk = A["blsAggregator"], A["dvtValidator"], A["registry"], A["superPaymaster"], A["staking"]
TL = A["timelockController"]

# 1. Owners: no system-internal contract may be owned by the deployer.
SYSTEM = ["superPaymaster", "registry", "staking", "gToken", "xPNTsFactoryV2", "aoaProtocolRegistry",
          "reputationSystem", "blsAggregator", "dvtValidator"]
LEGACY = ["xPNTsFactory", "paymasterFactory", "paymasterV4Impl", "microPaymentChannel", "x402Facilitator"]
for k in SYSTEM + LEGACY:
    o = call(A[k], "owner()(address)").lower()
    if k in SYSTEM:
        check(f"owner({k}) != deployer", o != DEPLOYER and not o.startswith("<"), o)
    else:
        print(f"INFO  owner({k}) [legacy, exception allowed] :: {o}")
for k in ("superPaymaster", "registry"):
    print(f"INFO  pendingOwner({k}) :: {call(A[k], 'pendingOwner()(address)')}")

# 2. Registry role owners.
T = "(uint256,uint256,uint32,uint32,uint32,uint32,uint16,bool,uint256,string,address)"
for r in ("COMMUNITY", "ENDUSER", "PAYMASTER_AOA", "PAYMASTER_SUPER", "DVT", "ANODE", "KMS"):
    rid = cast("keccak", r)[1]
    rc, raw = cast("call", reg, "getRoleConfig(bytes32)", rid)  # raw ABI: decode the static owner word
    words = [raw[2 + 64 * i: 2 + 64 * (i + 1)] for i in range((len(raw) - 2) // 64)]
    # word 0 = tuple offset; then minStake..minExitFee (9 words), string offset, owner
    owner = ("0x" + words[11][24:]).lower() if rc == 0 and len(words) > 11 else f"<undecodable {raw[:60]}>"
    check(f"roleConfigs[{r}].owner != deployer", not owner.startswith("<") and owner != DEPLOYER, owner)

# 3. Reputation sources.
check("isReputationSource(repSystem)", call(reg, "isReputationSource(address)(bool)", A["reputationSystem"]) == "true", "expected true")
check("isReputationSource(aggregator)", call(reg, "isReputationSource(address)(bool)", agg) == "true", "expected true")
check("isReputationSource(deployer) == false", call(reg, "isReputationSource(address)(bool)", DEPLOYER) == "false", "")

# 4. Non-owner privileges.
for name, addr, sig in (("SP.treasury", sp, "treasury()(address)"), ("staking.treasury", stk, "treasury()(address)"),
                        ("MySBT.daoMultisig", A["sbt"], "daoMultisig()(address)"),
                        ("aggregator.slashPolicyAdmin", agg, "slashPolicyAdmin()(address)"),
                        ("SP.guardian", sp, "guardian()(address)"),
                        ("PolicyRegistry.guardian", A["policyRegistry"], "guardian()(address)")):
    v = call(addr, sig).lower()
    check(f"{name} != deployer", v != DEPLOYER and not v.startswith("<"), v)
print(f"INFO  PolicyRegistry.timelock :: {call(A['policyRegistry'], 'timelock()(address)')}")
check("DVT.isValidator(deployer) == false", call(dvt, "isValidator(address)(bool)", DEPLOYER) == "false", "")

# 5. Timelock roles: the deployer holds none.
for role in ("PROPOSER_ROLE", "EXECUTOR_ROLE", "CANCELLER_ROLE", "DEFAULT_ADMIN_ROLE"):
    h = call(TL, f"{role}()(bytes32)")
    check(f"TL.{role}(deployer) == false", call(TL, "hasRole(bytes32,address)(bool)", h, DEPLOYER) == "false", "")
    print(f"INFO  TL.{role}(safe) :: {call(TL, 'hasRole(bytes32,address)(bool)', h, SAFE)}")
print(f"INFO  TL.minDelay :: {call(TL, 'getMinDelay()(uint256)')}")

# 6. Slasher / verifier / aggregator invariants.
check("authorizedSlashers(aggregator) == false", call(stk, "authorizedSlashers(address)(bool)", agg) == "false", "")
check("fraudProofVerifier == 0", call(agg, "fraudProofVerifier()(address)").lower() == "0x" + "0" * 40, "")
for k in SYSTEM + LEGACY:
    o = call(A[k], "owner()(address)").lower()
    check(f"owner({k}) != aggregator", o != agg.lower(), o)
bal = cast("balance", agg)[1]
check("aggregator ETH balance == 0", bal == "0", bal)
for t in ("gToken", "aPNTs", "pnts"):
    b = call(A[t], "balanceOf(address)(uint256)", agg).split()[0]
    check(f"aggregator {t} balance == 0", b == "0", b)
print(f"INFO  versions :: agg={call(agg, 'version()(string)')} dvt={call(dvt, 'version()(string)')} sp={call(sp, 'version()(string)')}")
for sig in ("minThreshold()(uint256)", "defaultThreshold()(uint256)"):
    print(f"INFO  agg.{sig.split('(')[0]} :: {call(agg, sig)}")

# 7. Generic-path denylist: the aggregator owner calling executeProposal with each blocked selector.
aggOwner = call(agg, "owner()(address)")
for sig, args in (("batchUpdateGlobalReputation(uint256,address[],uint256[],uint256,bytes)", ["1", "[]", "[]", "1", "0x01"]),
                  ("slash(address,uint256,string)", [DEPLOYER, "1", "x"]),
                  ("slashByDVT(address,bytes32,uint256,string)", [DEPLOYER, "0x" + "00" * 32, "1", "x"])):
    data = cast("calldata", sig, *args)[1]
    outer = cast("calldata", "executeProposal(uint256,address,bytes,uint256,bytes)", "1", reg, data, "3", "0x00")[1]
    rc, out = raw_call(aggOwner, agg, outer)
    sel = cast("sig", sig)[1]
    expect = cast("calldata", "ForbiddenGenericSelector(bytes4)", sel)[1]
    check(f"generic executeProposal({sig.split('(')[0]}) rejected with ForbiddenGenericSelector",
          rc != 0 and (expect[2:] in out or "ForbiddenGenericSelector" in out), out[:160])

print(f"\nSUMMARY {sum(results)} passed, {len(results) - sum(results)} failed, {len(results)} total")
